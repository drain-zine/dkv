const std = @import("std");
const assert = std.debug.assert;
const StdIo = std.Io;
const System = std.posix.system;

const constants = @import("constants.zig");
const io_module = @import("io/io.zig");
const Io = io_module.Io;
const CommandLoop = @import("protocol/command_loop.zig").CommandLoop;
const Store = @import("storage/store.zig").Store;

const log = std.log.scoped(.connection);

/// One client. Owns its descriptor, its buffers and the two completions it
/// keeps in flight, so the server never touches a descriptor after accept.
///
/// Completions are embedded, so a connection must not move while an operation
/// is in flight. The server's slots are allocated once and never resized.
pub const Connection = struct {
    state: State = .free,
    fd: System.fd_t = -1,
    io: *Io = undefined,
    store: *Store = undefined,
    command_loop: CommandLoop = undefined,

    request_buffer: []u8,
    request_size: u32 = 0,

    response_buffer: []u8,
    response_size: u32 = 0,
    response_size_sent: u32 = 0,

    recv_completion: Io.Completion = undefined,
    send_completion: Io.Completion = undefined,
    recv_in_flight: bool = false,
    send_in_flight: bool = false,

    pub const State = enum { free, open, closing };

    /// Takes over `fd` and starts reading from it.
    pub fn open(self: *Connection, io: *Io, store: *Store, fd: System.fd_t) void {
        // `io` and `store` outlive every connection: the server owns both.
        assert(self.state == .free);
        assert(self.fd == -1);
        assert(!self.recv_in_flight);
        assert(!self.send_in_flight);
        assert(fd > -1);

        self.state = .open;
        self.fd = fd;
        self.io = io;
        self.store = store;
        self.command_loop = .{ .request_size_max = @intCast(self.request_buffer.len) };
        self.request_size = 0;
        self.response_size = 0;
        self.response_size_sent = 0;
        self.recv_completion.state = .unused;
        self.send_completion.state = .unused;

        self.submitRecv();
    }

    /// True once the descriptor is closed and both completions are back, so
    /// the server may hand this slot to another client.
    pub fn isFinished(self: *const Connection) bool {
        return self.state == .free;
    }

    fn submitRecv(self: *Connection) void {
        assert(self.state == .open);
        assert(!self.recv_in_flight);
        assert(self.request_size < self.request_buffer.len);

        self.recv_in_flight = true;
        self.io.recv(
            Connection,
            self,
            onRecv,
            &self.recv_completion,
            self.fd,
            self.request_buffer[self.request_size..],
        );
    }

    fn onRecv(
        self: *Connection,
        completion: *Io.Completion,
        result: io_module.RecvError!usize,
    ) void {
        assert(completion == &self.recv_completion);
        assert(self.recv_in_flight);
        self.recv_in_flight = false;

        const received = result catch |err| {
            log.debug("recv failed: {s}", .{@errorName(err)});
            return self.beginClose();
        };
        // Zero bytes means the peer shut its side down, not an error.
        if (received == 0) return self.beginClose();

        self.request_size += @intCast(received);
        assert(self.request_size <= self.request_buffer.len);

        self.resume_();
    }

    /// Runs whatever whole commands have arrived, keeping any partial command
    /// for the next read. Replies that do not fit are left for a later call,
    /// once what is already encoded has been sent.
    fn processRequest(self: *Connection) void {
        assert(self.state == .open);
        assert(self.request_size > 0);
        assert(self.response_size == 0);
        assert(self.response_size_sent == 0);

        const request = self.request_buffer[0..self.request_size];
        var writer: StdIo.Writer = .fixed(self.response_buffer);

        const outcome = self.command_loop.process(self.store, request, &writer);

        self.response_size = @intCast(writer.buffered().len);
        assert(self.response_size <= self.response_buffer.len);

        const consumed: u32 = @intCast(outcome.input_size_consumed);
        assert(consumed <= self.request_size);

        const remaining = self.request_size - consumed;
        std.mem.copyForwards(
            u8,
            self.request_buffer[0..remaining],
            self.request_buffer[consumed..self.request_size],
        );
        self.request_size = remaining;

        if (outcome.close) self.state = .closing;
    }

    /// Keeps the connection moving: run what has arrived, send what is pending,
    /// read more if there is room, and close once a closing connection has
    /// drained. A reply held back for want of room is encoded here, one drained
    /// response buffer at a time.
    fn resume_(self: *Connection) void {
        if (self.state == .open and
            self.request_size > 0 and
            self.response_size == 0)
        {
            self.processRequest();
        }

        if (self.hasPendingResponse() and !self.send_in_flight) {
            self.submitSend();
        }

        switch (self.state) {
            .open => {
                const room = self.request_size < self.request_buffer.len;
                if (room and !self.recv_in_flight) self.submitRecv();
            },
            .closing => self.closeWhenDrained(),
            .free => {},
        }
    }

    fn hasPendingResponse(self: *const Connection) bool {
        assert(self.response_size_sent <= self.response_size);
        return self.response_size_sent < self.response_size;
    }

    fn submitSend(self: *Connection) void {
        assert(self.state != .free);
        assert(!self.send_in_flight);
        assert(self.hasPendingResponse());

        self.send_in_flight = true;
        self.io.send(
            Connection,
            self,
            onSend,
            &self.send_completion,
            self.fd,
            self.response_buffer[self.response_size_sent..self.response_size],
        );
    }

    fn onSend(
        self: *Connection,
        completion: *Io.Completion,
        result: io_module.SendError!usize,
    ) void {
        assert(completion == &self.send_completion);
        assert(self.send_in_flight);
        self.send_in_flight = false;

        const sent = result catch |err| {
            log.debug("send failed: {s}", .{@errorName(err)});
            self.response_size = 0;
            self.response_size_sent = 0;
            return self.beginClose();
        };

        self.response_size_sent += @intCast(sent);
        assert(self.response_size_sent <= self.response_size);

        // Everything queued has gone out, so the buffer starts again.
        if (!self.hasPendingResponse()) {
            self.response_size = 0;
            self.response_size_sent = 0;
        }

        self.resume_();
    }

    fn beginClose(self: *Connection) void {
        assert(self.state != .free);

        self.state = .closing;
        self.closeWhenDrained();
    }

    /// A closing connection still sends what it has already encoded, so a
    /// protocol error reaches the client before the descriptor goes away.
    fn closeWhenDrained(self: *Connection) void {
        assert(self.state == .closing);

        if (self.hasPendingResponse()) return;
        if (self.recv_in_flight or self.send_in_flight) return;

        assert(self.fd > -1);
        self.io.close(
            Connection,
            self,
            onClose,
            &self.send_completion,
            self.fd,
        );
        self.send_in_flight = true;
    }

    fn onClose(self: *Connection, completion: *Io.Completion) void {
        assert(completion == &self.send_completion);
        assert(self.state == .closing);

        self.send_in_flight = false;
        self.state = .free;
        self.fd = -1;
        self.request_size = 0;
        self.response_size = 0;
        self.response_size_sent = 0;
    }
};
