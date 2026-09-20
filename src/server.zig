const std = @import("std");
const assert = std.debug.assert;
const StdIo = std.Io;
const Allocator = std.mem.Allocator;
const System = std.posix.system;

const constants = @import("constants.zig");
const io_module = @import("io/event.zig");
const Io = io_module.Io;
const Connection = @import("connection.zig").Connection;
const CommandLoop = @import("protocol/command_loop.zig").CommandLoop;
const Store = @import("storage/store.zig").Store;

const log = std.log.scoped(.server);

pub const Options = struct { host: []const u8, port: u16 };

pub const Server = struct {
    gpa: Allocator,
    std_io: StdIo,
    io: Io,
    store: *Store,

    listener: StdIo.net.Server,
    listener_fd: System.fd_t,

    connections: []Connection,
    request_memory: []u8,
    response_memory: []u8,

    accept_completion: Io.Completion = undefined,
    accept_in_flight: bool = false,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init(gpa: Allocator, std_io: StdIo, store: *Store, options: Options) !Server {
        const connection_count = constants.connection_count_max;
        const request_buffer_size = constants.connection_request_buffer_size;
        const response_buffer_size = constants.connection_response_buffer_size;

        const request_memory = try gpa.alloc(u8, connection_count * request_buffer_size);
        errdefer gpa.free(request_memory);

        const response_memory = try gpa.alloc(u8, connection_count * response_buffer_size);
        errdefer gpa.free(response_memory);

        const connections = try gpa.alloc(Connection, connection_count);
        errdefer gpa.free(connections);

        for (connections, 0..) |*connection, index| {
            const request_offset = index * request_buffer_size;
            const response_offset = index * response_buffer_size;
            connection.* = .{
                .request_buffer = request_memory[request_offset..][0..request_buffer_size],
                .response_buffer = response_memory[response_offset..][0..response_buffer_size],
            };
        }

        const address = try StdIo.net.IpAddress.parse(options.host, options.port);
        var listener = try address.listen(std_io, .{ .reuse_address = true });
        errdefer listener.deinit(std_io);

        const listener_fd = listener.socket.handle;
        try Io.setNonBlocking(listener_fd);

        const io = try Io.init();

        return .{
            .gpa = gpa,
            .std_io = std_io,
            .io = io,
            .store = store,
            .listener = listener,
            .listener_fd = listener_fd,
            .connections = connections,
            .request_memory = request_memory,
            .response_memory = response_memory,
        };
    }

    pub fn start(self: *Server) void {
        assert(!self.accept_in_flight);

        self.submitAccept();
    }

    pub fn deinit(self: *Server) void {
        for (self.connections) |*connection| {
            if (connection.fd > -1) _ = System.close(connection.fd);
        }

        self.listener.deinit(self.std_io);
        self.gpa.free(self.connections);
        self.gpa.free(self.response_memory);
        self.gpa.free(self.request_memory);
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // Serving
    // -----------------------------------------------------------------------

    pub fn run(self: *Server) !void {
        const timeout = constants.event_loop_wait_timeout_ms * std.time.ns_per_ms;

        while (true) {
            try self.io.runForNs(timeout);
            self.commit();
        }
    }

    fn commit(self: *Server) void {
        if (!self.store.needsCommit()) return;

        self.store.commit();

        for (self.connections) |*connection| {
            if (connection.commit_pending) connection.releaseResponse();
        }
    }

    // -----------------------------------------------------------------------
    // Accepting
    // -----------------------------------------------------------------------

    fn submitAccept(self: *Server) void {
        assert(!self.accept_in_flight);

        self.accept_in_flight = true;
        self.accept_completion.state = .unused;
        self.io.accept(
            Server,
            self,
            onAccept,
            &self.accept_completion,
            self.listener_fd,
        );
    }

    fn onAccept(
        self: *Server,
        completion: *Io.Completion,
        result: io_module.AcceptError!System.fd_t,
    ) void {
        assert(completion == &self.accept_completion);
        assert(self.accept_in_flight);
        self.accept_in_flight = false;

        const fd = result catch |err| {
            switch (err) {
                error.ProcessFdQuotaExceeded, error.SystemResources => {
                    log.warn("accept deferred: {s}", .{@errorName(err)});
                    return;
                },
                else => {
                    log.debug("accept failed: {s}", .{@errorName(err)});
                    self.submitAccept();
                    return;
                },
            }
        };

        if (self.acquireConnection()) |connection| {
            connection.open(&self.io, self.store, fd);
        } else {
            log.warn("no free connection slot, refusing client", .{});
            const reply = &CommandLoop.reject_busy_reply;
            _ = System.write(fd, reply, reply.len);
            _ = System.close(fd);
        }

        self.submitAccept();
    }

    fn acquireConnection(self: *Server) ?*Connection {
        for (self.connections) |*connection| {
            if (connection.isFinished()) return connection;
        }

        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    tmp: testing.TmpDir,
    store: Store,
    server: Server,

    const pass_timeout_ns = 1 * std.time.ns_per_ms;
    const pass_count_max = 2000;

    fn init(self: *Harness) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        self.store = try Store.init(testing.allocator, testing.io, .{
            .dir = self.tmp.dir,
            .wal = .{ .durability = .never },
        });
        errdefer self.store.deinit();

        self.server = try Server.init(testing.allocator, testing.io, &self.store, .{
            .host = "127.0.0.1",
            .port = 0,
        });
        self.server.start();
    }

    fn deinit(self: *Harness) void {
        _ = System.close(self.server.io.kqueue_fd);
        self.server.deinit();
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn run(self: *Harness, pass_count: usize) void {
        for (0..pass_count) |_| self.server.io.runForNs(pass_timeout_ns) catch unreachable;
    }

    fn connect(self: *Harness) !System.fd_t {
        const address = self.server.listener.socket.address;
        const stream = try address.connect(testing.io, .{ .mode = .stream });

        try Io.setNonBlocking(stream.socket.handle);
        return stream.socket.handle;
    }

    fn send(self: *Harness, fd: System.fd_t, bytes: []const u8) void {
        var size_sent: usize = 0;

        for (0..pass_count_max) |_| {
            if (size_sent == bytes.len) return;

            const rc = System.write(fd, bytes.ptr + size_sent, bytes.len - size_sent);
            switch (std.posix.errno(rc)) {
                .SUCCESS => size_sent += @intCast(rc),
                .AGAIN => self.run(1),
                else => unreachable,
            }
        }

        unreachable;
    }

    fn expectReply(self: *Harness, fd: System.fd_t, expected: []const u8) !void {
        const buffer = try testing.allocator.alloc(u8, expected.len);
        defer testing.allocator.free(buffer);

        var size_received: usize = 0;
        for (0..pass_count_max) |_| {
            if (size_received == expected.len) break;

            const rc = System.read(fd, buffer.ptr + size_received, expected.len - size_received);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    size_received += @intCast(rc);
                },
                .AGAIN => self.run(1),
                else => unreachable,
            }
        }

        try testing.expectEqualStrings(expected, buffer[0..size_received]);
    }
};

test "a client is accepted and replied to over a real socket" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "PING\r\n");
    try harness.expectReply(client, "+PONG\r\n");
}

test "a value set over the wire reads back" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n");
    try harness.expectReply(client, "+OK\r\n");

    harness.send(client, "*2\r\n$3\r\nGET\r\n$1\r\na\r\n");
    try harness.expectReply(client, "$1\r\n1\r\n");
}

test "pipelined commands reply in order" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(
        client,
        "*1\r\n$4\r\nPING\r\n" ++
            "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" ++
            "*2\r\n$3\r\nGET\r\n$1\r\na\r\n",
    );

    try harness.expectReply(client, "+PONG\r\n+OK\r\n$1\r\n1\r\n");
}

test "two clients are served independently" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const first = try harness.connect();
    defer _ = System.close(first);
    const second = try harness.connect();
    defer _ = System.close(second);

    harness.send(first, "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$2\r\nhi\r\n");
    try harness.expectReply(first, "+OK\r\n");

    harness.send(second, "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n");
    try harness.expectReply(second, "$2\r\nhi\r\n");

    harness.send(first, "PING\r\n");
    try harness.expectReply(first, "+PONG\r\n");
}
