const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const System = std.posix.system;

const constants = @import("constants.zig");
const EventLoop = @import("io/event_loop.zig").EventLoop;
const AcceptError = @import("io/event_loop.zig").AcceptError;
const Connection = @import("connection.zig").Connection;
const CommandLoop = @import("protocol/command_loop.zig").CommandLoop;
const Store = @import("storage/store.zig").Store;

const log = std.log.scoped(.server);

pub const Options = struct { host: []const u8, port: u16 };

pub const Server = struct {
    gpa: Allocator,
    std_io: Io,
    event_loop: EventLoop,
    store: *Store,

    listener: Io.net.Server,
    listener_fd: System.fd_t,

    connections: []Connection,
    request_memory: []u8,
    response_memory: []u8,

    accept_completion: EventLoop.Completion = undefined,
    accept_in_flight: bool = false,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init(gpa: Allocator, std_io: Io, store: *Store, options: Options) !Server {
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

        const address = try Io.net.IpAddress.parse(options.host, options.port);
        var listener = try address.listen(std_io, .{ .reuse_address = true });
        errdefer listener.deinit(std_io);

        const listener_fd = listener.socket.handle;
        try EventLoop.setNonBlocking(listener_fd);

        const event_loop = try EventLoop.init();

        return .{
            .gpa = gpa,
            .std_io = std_io,
            .event_loop = event_loop,
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
            try self.event_loop.runForNs(timeout);
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
        self.event_loop.accept(
            Server,
            self,
            onAccept,
            &self.accept_completion,
            self.listener_fd,
        );
    }

    fn onAccept(
        self: *Server,
        completion: *EventLoop.Completion,
        result: AcceptError!System.fd_t,
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
            connection.open(&self.event_loop, self.store, fd);
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
    tmp: ?testing.TmpDir,
    store: Store,
    server: Server,

    const pass_timeout_ns = 1 * std.time.ns_per_ms;
    const pass_count_max = 4000;

    fn init(self: *Harness) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.?.cleanup();

        try self.listen(self.tmp.?.dir);
    }

    /// The caller owns the directory, so two servers can run over one log.
    fn initIn(self: *Harness, dir: Io.Dir) !void {
        self.tmp = null;
        try self.listen(dir);
    }

    fn listen(self: *Harness, dir: Io.Dir) !void {
        self.store = try Store.init(testing.allocator, testing.io, .{
            .dir = dir,
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
        self.server.event_loop.shutdown();
        self.server.deinit();
        self.store.deinit();
        if (self.tmp) |*tmp| tmp.cleanup();
    }

    fn run(self: *Harness, pass_count: usize) void {
        for (0..pass_count) |_| self.server.event_loop.runForNs(pass_timeout_ns) catch unreachable;
    }

    fn connect(self: *Harness) !System.fd_t {
        const address = self.server.listener.socket.address;
        const stream = try address.connect(testing.io, .{ .mode = .stream });

        try EventLoop.setNonBlocking(stream.socket.handle);
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

    /// Reads a `$N\r\n<body>\r\n` reply without building a second copy of the
    /// body to compare against.
    fn expectBulk(self: *Harness, fd: System.fd_t, value: []const u8) !void {
        var header: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&header, "${d}\r\n", .{value.len});
        try self.expectReply(fd, prefix);
        try self.expectReply(fd, value);
        try self.expectReply(fd, "\r\n");
    }

    /// Drains until the peer closes, which is how a protocol error ends.
    fn expectClosed(self: *Harness, fd: System.fd_t, expected: []const u8) !void {
        const buffer = try testing.allocator.alloc(u8, expected.len + 64);
        defer testing.allocator.free(buffer);

        var size_received: usize = 0;
        for (0..pass_count_max) |_| {
            const rc = System.read(fd, buffer.ptr + size_received, buffer.len - size_received);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    size_received += @intCast(rc);
                },
                .AGAIN => self.run(1),
                else => break,
            }
        }

        try testing.expectEqualStrings(expected, buffer[0..size_received]);
    }

    fn openConnections(self: *Harness, clients: []System.fd_t) !void {
        for (clients) |*client| {
            client.* = try self.connect();
            self.send(client.*, "PING\r\n");
            try self.expectReply(client.*, "+PONG\r\n");
        }
    }
};

fn bigValue(byte: u8) ![]u8 {
    const value = try testing.allocator.alloc(u8, constants.resp_argument_size_max);
    @memset(value, byte);
    return value;
}

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

test "a command split byte by byte still runs" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    const request = "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n";
    for (request) |byte| {
        harness.send(client, &[_]u8{byte});
        harness.run(1);
    }

    try harness.expectReply(client, "+OK\r\n");
}

test "inline commands and empty lines over the wire" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "PING\r\n\r\nSET hello world\r\nGET hello\r\n");
    try harness.expectReply(client, "+PONG\r\n+OK\r\n$5\r\nworld\r\n");
}

test "a value holding the terminator survives the round trip" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "*3\r\n$3\r\nSET\r\n$3\r\nbin\r\n$4\r\na\r\nb\r\n");
    try harness.expectReply(client, "+OK\r\n");

    harness.send(client, "*2\r\n$3\r\nGET\r\n$3\r\nbin\r\n");
    try harness.expectReply(client, "$4\r\na\r\nb\r\n");
}

test "command errors reply and leave the connection open" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "NOPE x\r\n");
    try harness.expectReply(client, "-ERR unknown command 'NOPE'\r\n");

    harness.send(client, "GET\r\n");
    try harness.expectReply(client, "-ERR wrong number of arguments for 'get' command\r\n");

    harness.send(client, "PING\r\n");
    try harness.expectReply(client, "+PONG\r\n");
}

test "a one megabyte value round-trips" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const value = try bigValue('v');
    defer testing.allocator.free(value);

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "*3\r\n$3\r\nSET\r\n$3\r\nbig\r\n$1048576\r\n");
    harness.send(client, value);
    harness.send(client, "\r\n");
    try harness.expectReply(client, "+OK\r\n");

    harness.send(client, "*2\r\n$3\r\nGET\r\n$3\r\nbig\r\n");
    try harness.expectBulk(client, value);
}

test "a small reply follows a reply that needed many writes" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const value = try bigValue('z');
    defer testing.allocator.free(value);

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "*3\r\n$3\r\nSET\r\n$3\r\nbig\r\n$1048576\r\n");
    harness.send(client, value);
    harness.send(client, "\r\n");
    try harness.expectReply(client, "+OK\r\n");

    harness.send(client, "*2\r\n$3\r\nGET\r\n$3\r\nbig\r\n");
    try harness.expectBulk(client, value);

    harness.send(client, "PING\r\n");
    try harness.expectReply(client, "+PONG\r\n");
}

test "a set and a get of one megabyte pipelined in one write" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const value = try bigValue('p');
    defer testing.allocator.free(value);

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "*3\r\n$3\r\nSET\r\n$3\r\nbig\r\n$1048576\r\n");
    harness.send(client, value);
    harness.send(client, "\r\n*2\r\n$3\r\nGET\r\n$3\r\nbig\r\n");

    try harness.expectReply(client, "+OK\r\n");
    try harness.expectBulk(client, value);
}

test "a protocol error replies once and then closes" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "*1\r\n+OK\r\n*1\r\n$4\r\nPING\r\n");
    try harness.expectClosed(client, "-ERR Protocol error\r\n");
}

test "the slot is reused after a protocol error closed it" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const doomed = try harness.connect();
    harness.send(doomed, "*1\r\n+OK\r\n");
    try harness.expectClosed(doomed, "-ERR Protocol error\r\n");
    _ = System.close(doomed);
    harness.run(4);

    const client = try harness.connect();
    defer _ = System.close(client);
    harness.send(client, "PING\r\n");
    try harness.expectReply(client, "+PONG\r\n");
}

test "a client that vanishes mid-command does not disturb the server" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const abrupt = try harness.connect();
    harness.send(abrupt, "*2\r\n$3\r\nGET\r\n$5\r\nhal");
    harness.run(2);
    _ = System.close(abrupt);
    harness.run(4);

    const client = try harness.connect();
    defer _ = System.close(client);
    harness.send(client, "PING\r\n");
    try harness.expectReply(client, "+PONG\r\n");
}

test "many clients pipelining at once are all answered" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var clients: [20]System.fd_t = undefined;
    for (&clients) |*client| client.* = try harness.connect();
    defer for (clients) |client| {
        _ = System.close(client);
    };

    const batch = "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n" ++ "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n";
    for (clients) |client| harness.send(client, batch ** 8);

    for (clients) |client| {
        try harness.expectReply(client, ("+OK\r\n$1\r\nv\r\n") ** 8);
    }
}

test "every slot fills, the next client is refused, and slots come back" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var clients: [constants.connection_count_max]System.fd_t = undefined;
    try harness.openConnections(&clients);

    const refused = try harness.connect();
    try harness.expectClosed(refused, "-ERR max number of clients reached\r\n");
    _ = System.close(refused);

    for (clients) |client| _ = System.close(client);
    harness.run(8);

    const client = try harness.connect();
    defer _ = System.close(client);
    harness.send(client, "PING\r\n");
    try harness.expectReply(client, "+PONG\r\n");
}

test "data written over the wire survives a restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var harness: Harness = undefined;
        try harness.initIn(tmp.dir);
        defer harness.deinit();

        const client = try harness.connect();
        defer _ = System.close(client);

        harness.send(client, "*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\ntom\r\n");
        try harness.expectReply(client, "+OK\r\n");
        harness.send(client, "*2\r\n$3\r\nDEL\r\n$4\r\nname\r\n");
        try harness.expectReply(client, ":1\r\n");
        harness.send(client, "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n");
        try harness.expectReply(client, "+OK\r\n");
    }

    var harness: Harness = undefined;
    try harness.initIn(tmp.dir);
    defer harness.deinit();

    const client = try harness.connect();
    defer _ = System.close(client);

    harness.send(client, "*2\r\n$3\r\nGET\r\n$1\r\na\r\n");
    try harness.expectReply(client, "$1\r\n1\r\n");

    harness.send(client, "*2\r\n$3\r\nGET\r\n$4\r\nname\r\n");
    try harness.expectReply(client, "$-1\r\n");
}
