const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const System = std.posix.system;

const constants = @import("constants.zig");
const resp = @import("resp.zig");
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

pub const Options = struct { host: []const u8, port: u16 };

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    store: *Store,
    listener: Io.net.Server,
    connections: []Connection,
    request_memory: []u8,
    response_memory: []u8,
    free_connection_count: std.math.IntFittingRange(0, constants.connection_count_max) =
        constants.connection_count_max,
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
            connection.* = .{ .session = .{}, .request_buffer = request_memory[request_offset..][0..request_buffer_size], .response_buffer = response_memory[response_offset..][0..response_buffer_size], .state = .free, .fd = -1, .request_size = 0, .response_size = 0, .response_size_sent = 0, .writable_registered = false };
        }

        const address = try Io.net.IpAddress.parse(options.host, options.port);
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);

        const kqueue_fd = System.kqueue();
        if (kqueue_fd < 0) return error.KqueueFailed;
        errdefer _ = System.close(kqueue_fd);

        const listener_fd = listener.socket.handle;
        try setNonBlocking(listener_fd);
        try register(kqueue_fd, listener_fd, System.EVFILT.READ, System.EV.ADD, listener_udata);

        return .{ .gpa = gpa, .io = io, .store = store, .listener = listener, .connections = connections, .request_memory = request_memory, .response_memory = response_memory, .kqueue_fd = kqueue_fd };
    }

    pub fn deinit(server: *Server) void {
        server.gpa.free(server.connections);
        server.gpa.free(server.response_memory);
        server.gpa.free(server.request_memory);
        server.listener.deinit(server.io);
        _ = System.close(server.kqueue_fd);
        server.* = undefined;
    }

    pub fn run(server: *Server) !void {
        var events: [constants.connection_count_max + 1]System.Kevent = undefined;

        while (true) {
            const event_count = try wait(server.kqueue_fd, &events);

            for (events[0..event_count]) |event| {
                if (event.udata == listener_udata) {
                    server.acceptConnections();
                    continue;
                }

                assert(event.udata < constants.connection_count_max);
                const connection = &server.connections[event.udata];
                assert(connection.state != .free);
                if (event.filter == System.EVFILT.READ) {
                    server.readConnection(connection);
                }
            }

            for (server.connections) |*connection| {
                if (connection.state == .free) continue;
                if (connection.response_size_sent == connection.response_size) continue;
                server.flushConnection(connection);
            }

            for (server.connections) |*connection| {
                if (connection.state != .closing) continue;
                if (connection.response_size_sent < connection.response_size) continue;
                server.closeConnection(connection);
            }
        }
    }

    pub fn acquireConnection(server: *Server, fd: System.fd_t) ?*Connection {
        assert(fd > -1);
        assert(server.free_connection_count <= constants.connection_count_max);

        for (server.connections) |*connection| {
            if (connection.state != .free) continue;
            assert(server.free_connection_count > 0);
            assert(connection.fd == -1);

            connection.state = .open;
            connection.fd = fd;
            connection.request_size = 0;
            connection.response_size = 0;
            connection.response_size_sent = 0;
            connection.writable_registered = false;
            connection.session.closed = false;
            server.free_connection_count -= 1;
            return connection;
        }

        assert(server.free_connection_count == 0);
        return null;
    }

    pub fn releaseConnection(server: *Server, connection: *Connection) void {
        assert(connection.state == .closing);
        assert(server.free_connection_count < constants.connection_count_max);

        connection.state = .free;
        connection.fd = -1;
        connection.request_size = 0;
        connection.response_size = 0;
        connection.response_size_sent = 0;
        connection.writable_registered = false;
        server.free_connection_count += 1;
    }

    fn acceptConnections(server: *Server) void {
        const listener_fd = server.listener.socket.handle;

        for (0..constants.connection_count_max) |_| {
            const rc = System.accept(listener_fd, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => server.openConnection(rc),
                .INTR, .CONNABORTED => continue,
                .AGAIN => return,
                else => |err| {
                    log.warn("accept failed: errno {d}", .{@intFromEnum(err)});
                    return;
                },
            }
        }
    }

    fn openConnection(server: *Server, fd: System.fd_t) void {
        assert(fd > -1);

        const connection = server.acquireConnection(fd) orelse return rejectConnection(fd);
        const index = server.connectionIndex(connection);

        setNonBlocking(fd) catch |err| return server.abandonConnection(connection, err);
        disableSigPipe(fd) catch |err| return server.abandonConnection(connection, err);
        register(server.kqueue_fd, fd, System.EVFILT.READ, System.EV.ADD, index) catch |err| {
            return server.abandonConnection(connection, err);
        };
    }

    fn abandonConnection(server: *Server, connection: *Connection, err: anyerror) void {
        _ = server;
        assert(connection.state == .open);

        log.debug("connection setup failed: {s}", .{@errorName(err)});
        connection.state = .closing;
    }

    fn rejectConnection(fd: System.fd_t) void {
        assert(fd > -1);

        var reply_buffer: [64]u8 = undefined;
        var writer: Io.Writer = .fixed(&reply_buffer);
        resp.encode(&writer, .error_max_clients) catch unreachable;

        const reply = writer.buffered();
        _ = System.write(fd, reply.ptr, reply.len);
        _ = System.close(fd);
    }

    fn readConnection(server: *Server, connection: *Connection) void {
        if (connection.state != .open) return;
        assert(connection.request_size < connection.request_buffer.len);

        const unread = connection.request_buffer[connection.request_size..];
        const rc = System.read(connection.fd, unread.ptr, unread.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => return,
            else => {
                connection.state = .closing;
                return;
            },
        }
        if (rc == 0) {
            connection.state = .closing;
            return;
        }
        connection.request_size += @intCast(rc);

        const request = connection.request_buffer[0..connection.request_size];
        var writer: Io.Writer = .fixed(connection.response_buffer[connection.response_size..]);
        const outcome = connection.session.process(server.store, request, &writer) catch {
            log.debug("response buffer full, closing connection", .{});
            connection.state = .closing;
            return;
        };
        connection.response_size += @intCast(writer.buffered().len);
        assert(connection.response_size <= connection.response_buffer.len);

        const consumed = outcome.input_size_consumed;
        assert(consumed <= connection.request_size);
        const remaining = connection.request_size - consumed;
        std.mem.copyForwards(
            u8,
            connection.request_buffer[0..remaining],
            connection.request_buffer[consumed..connection.request_size],
        );
        connection.request_size = @intCast(remaining);

        if (outcome.close) connection.state = .closing;
    }

    fn flushConnection(server: *Server, connection: *Connection) void {
        assert(connection.state != .free);
        assert(connection.response_size_sent < connection.response_size);

        const pending_start = connection.response_size_sent;
        const pending = connection.response_buffer[pending_start..connection.response_size];
        const rc = System.write(connection.fd, pending.ptr, pending.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => connection.response_size_sent += @intCast(rc),
            .INTR, .AGAIN => {},
            else => {
                connection.response_size = 0;
                connection.response_size_sent = 0;
                connection.state = .closing;
                return;
            },
        }
        assert(connection.response_size_sent <= connection.response_size);

        const index = server.connectionIndex(connection);
        const kqueue_fd = server.kqueue_fd;
        const write_filter = System.EVFILT.WRITE;
        if (connection.response_size_sent == connection.response_size) {
            connection.response_size = 0;
            connection.response_size_sent = 0;
            if (!connection.writable_registered) return;

            connection.writable_registered = false;
            register(kqueue_fd, connection.fd, write_filter, System.EV.DELETE, index) catch {
                connection.state = .closing;
            };
        } else if (!connection.writable_registered) {
            register(kqueue_fd, connection.fd, write_filter, System.EV.ADD, index) catch {
                connection.state = .closing;
                return;
            };
            connection.writable_registered = true;
        }
    }

    fn closeConnection(server: *Server, connection: *Connection) void {
        assert(connection.state == .closing);
        assert(connection.response_size_sent == connection.response_size);
        assert(connection.fd > -1);

        _ = System.close(connection.fd);
        server.releaseConnection(connection);
    }

    fn connectionIndex(server: *const Server, connection: *const Connection) usize {
        const offset = @intFromPtr(connection) - @intFromPtr(server.connections.ptr);
        assert(offset % @sizeOf(Connection) == 0);

        const index = offset / @sizeOf(Connection);
        assert(index < server.connections.len);
        return index;
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
