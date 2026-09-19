const std = @import("std");
const assert = std.debug.assert;
const StdIo = std.Io;
const Allocator = std.mem.Allocator;
const System = std.posix.system;

const constants = @import("constants.zig");
const io_module = @import("io/io.zig");
const Io = io_module.Io;
const Connection = @import("connection.zig").Connection;
const CommandLoop = @import("protocol/command_loop.zig").CommandLoop;
const Store = @import("storage/store.zig").Store;

const log = std.log.scoped(.server);

pub const Options = struct { host: []const u8, port: u16 };

/// Accepts connections and hands each one a slot. Everything after accept is
/// the connection's own business: the server never touches a descriptor again.
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

    /// All memory the server uses is allocated here, once.
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

    /// Submits the first accept. Separate from `init` because a completion
    /// stores the server's address, which only settles once `init` returns.
    pub fn start(self: *Server) void {
        assert(!self.accept_in_flight);

        self.submitAccept();
    }

    /// Frees everything and closes every descriptor still open. The event queue
    /// itself is left to the exiting process: a completion armed against a
    /// closed descriptor never fires, so there is nothing to drain it with.
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

    /// Serves until something goes wrong with the event queue itself. A failing
    /// client only ends its own connection.
    pub fn run(self: *Server) !void {
        const timeout = constants.event_loop_wait_timeout_ms * std.time.ns_per_ms;

        while (true) {
            try self.io.runForNs(timeout);
        }
    }

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
            // Running out of descriptors would spin: the listener stays ready,
            // so re-arming fails again immediately. Wait for a slot to free up.
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
            // Best effort: the refusal is worth a try, but never worth a retry.
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
