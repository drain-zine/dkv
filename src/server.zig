const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const System = std.posix.system;

const constants = @import("constants.zig");
const Session = @import("session.zig").Session;
const Store = @import("store.zig").Store;

const log = std.log.scoped(.server);

const listener_udata = constants.connection_count_max;

pub const ConnectionState = enum(u8) { free, open, closing };

pub const Connection = struct {
    session: Session,
    request_buffer: []u8,
    response_buffer: []u8,
    state: ConnectionState,
    fd: System.fd_t,
    request_size: u32, // bytes buffered in request_buffer
    response_size: u32, // bytes encoded into response_buffer
    response_size_sent: u32, // bytes of that already written
    writable_registered: bool, // whether EVFILT.WRITE is currently enabled
};

pub const Options = struct {
    address: Io.net.IpAddress,
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    store: *Store,
    listener: Io.net.Server,
    connections: []Connection,
    request_memory: []u8,
    response_memory: []u8,
    free_connection_index: u8 = 0,
    kqueue_fd: System.fd_t,

    pub fn init(gpa: Allocator, io: Io, store: *Store, options: Options) !Server {
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
                .session = .{},
                .request_buffer = request_memory[request_offset..][0..request_buffer_size],
                .response_buffer = response_memory[response_offset..][0..response_buffer_size],
                .state = .free,
            };
        }

        const listener = try options.address.listen(io, .{ .reuse_address = true });

        const kqueue_fd = System.kqueue();
        if (kqueue_fd < 0) return error.KqueueFailed;
        errdefer _ = System.close(kqueue_fd);

        const listener_fd = listener.socket.handle;
        try setNonBlocking(listener_fd);
        // try register(kqueue_fd, listener_fd, System.EVFILT.READ, System.EV.ADD, listener_udata);

        return .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .listener = listener,
            .connections = connections,
            .request_memory = request_memory,
            .response_memory = response_memory,
        };
    }

    pub fn deinit(server: *Server) void {
        server.gpa.free(server.connections);
        server.gpa.free(server.response_memory);
        server.gpa.free(server.request_memory);
        server.listener.deinit(server.io);
        System.close(server.kqueue_fd);
        server.* = undefined;
    }

    pub fn run(server: *Server) Io.net.Server.AcceptError!void {
        while (true) {
            const stream = server.listener.accept(server.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };

            defer stream.close(server.io);

            const connection = server.acquireConnection() orelse unreachable;
            defer server.releaseConnection(connection);

            server.serve(connection, stream) catch |err| {
                log.debug("connection closed: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn acquireConnection(server: *Server) ?*Connection {
        assert(server.free_connection_index > -1);
        assert(server.free_connection_index < constants.connection_count_max);

        var connection = &server.connections[server.free_connection_index];
        assert(connection.state == .free);
        connection.state = .open;
        connection.session.closed = false;
        server.free_connection_index += 1;

        return connection;
    }

    pub fn releaseConnection(server: *Server, connection: *Connection) void {
        assert(connection.state == .open);
        connection.state = .free;
        server.free_connection_index -= 1;
        assert(server.free_connection_index > -1);

        return;
    }

    fn serve(
        server: *Server,
        connection: *Connection,
        stream: Io.net.Stream,
    ) (Io.Reader.Error || Io.Writer.Error)!void {
        assert(connection.state == .open);

        var stream_reader = stream.reader(server.io, connection.request_buffer);
        var stream_writer = stream.writer(server.io, connection.response_buffer);
        const reader = &stream_reader.interface;
        const writer = &stream_writer.interface;

        assert(reader.buffer.len == constants.connection_request_buffer_size);

        while (true) {
            assert(reader.bufferedLen() < reader.buffer.len);
            try reader.fillMore();

            const outcome = try connection.session.process(server.store, reader.buffered(), writer);
            reader.toss(outcome.input_size_consumed);
            try writer.flush();
            if (outcome.close) return;
        }
    }

    fn setNonBlocking(fd: System.fd_t) !void {
        assert(fd > -1);

        const flags: usize = while (true) {
            const rc = System.fcntl(fd, System.F.GETFL);
            switch (std.posix.errno(rc)) {
                .SUCCESS => break @intCast(rc),
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        };

        const nonblocking: usize = 1 << @bitOffsetOf(System.O, "NONBLOCK");

        while (true) {
            const rc = System.fcntl(fd, System.F.SETFL, flags | nonblocking);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn disableSigPipe(fd: System.fd_t) !void {
        assert(fd > -1);

        while (true) {
            const rc = System.fcntl(fd, System.F.SETNOSIGPIPE, @as(c_int, 1));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn register(kqueue_fd: System.fd_t, fd: System.fd_t, filter: i16, flags: u16, udata: usize) !void {
        assert(kqueue_fd > -1);
        assert(fd > -1);

        const change: [1]System.Kevent = .{.{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        }};

        while (true) {
            const outcome = System.kevent(kqueue_fd, &change, 1, &.{}, 0, null);

            switch (std.posix.errno(outcome)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn wait(kqueue_fd: System.fd_t, events: []System.Kevent) !u32 {
        assert(kqueue_fd > -1);
        assert(events.len > 0);

        const timeout: System.timespec = .{
            .sec = constants.event_loop_wait_timeout_ms / std.time.ms_per_s,
            .nsec = (constants.event_loop_wait_timeout_ms % std.time.ms_per_s) * std.time.ns_per_ms,
        };

        while (true) {
            const rc = System.kevent(
                kqueue_fd,
                &.{},
                0,
                events.ptr,
                @intCast(events.len),
                &timeout,
            );

            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const event_count: u32 = @intCast(rc);
                    assert(event_count <= events.len);
                    return event_count;
                },
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }
};
