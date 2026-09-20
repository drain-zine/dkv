const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const System = std.posix.system;

const constants = @import("constants.zig");
const EventLoop = @import("io/event_loop.zig").EventLoop;
const RecvError = @import("io/event_loop.zig").RecvError;
const SendError = @import("io/event_loop.zig").SendError;
const CommandLoop = @import("protocol/command_loop.zig").CommandLoop;
const Store = @import("storage/store.zig").Store;

const log = std.log.scoped(.connection);

pub const Connection = struct {
    state: State = .free,
    fd: System.fd_t = -1,
    event_loop: *EventLoop = undefined,
    store: *Store = undefined,
    command_loop: CommandLoop = undefined,

    request_buffer: []u8,
    request_size: u32 = 0,

    response_buffer: []u8,
    response_size: u32 = 0,
    response_size_sent: u32 = 0,
    commit_pending: bool = false,

    recv_completion: EventLoop.Completion = undefined,
    send_completion: EventLoop.Completion = undefined,
    recv_in_flight: bool = false,
    send_in_flight: bool = false,

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    pub const State = enum { free, open, closing };

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn open(self: *Connection, event_loop: *EventLoop, store: *Store, fd: System.fd_t) void {
        assert(self.state == .free);
        assert(self.fd == -1);
        assert(!self.recv_in_flight);
        assert(!self.send_in_flight);
        assert(fd > -1);

        self.state = .open;
        self.fd = fd;
        self.event_loop = event_loop;
        self.store = store;
        self.command_loop = .{ .request_size_max = @intCast(self.request_buffer.len) };
        self.request_size = 0;
        self.response_size = 0;
        self.response_size_sent = 0;
        self.commit_pending = false;
        self.recv_completion.state = .unused;
        self.send_completion.state = .unused;

        self.submitRecv();
    }

    pub fn isFinished(self: *const Connection) bool {
        return self.state == .free;
    }

    // -----------------------------------------------------------------------
    // Driving
    // -----------------------------------------------------------------------

    fn advance(self: *Connection) void {
        if (self.state == .open and
            self.request_size > 0 and
            self.response_size == 0)
        {
            self.processRequest();
        }

        if (self.hasPendingResponse() and !self.send_in_flight and !self.commit_pending) {
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

    pub fn releaseResponse(self: *Connection) void {
        self.commit_pending = false;
        self.advance();
    }

    // -----------------------------------------------------------------------
    // Receiving
    // -----------------------------------------------------------------------

    fn submitRecv(self: *Connection) void {
        assert(self.state == .open);
        assert(!self.recv_in_flight);
        assert(self.request_size < self.request_buffer.len);

        self.recv_in_flight = true;
        self.event_loop.recv(
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
        completion: *EventLoop.Completion,
        result: RecvError!usize,
    ) void {
        assert(completion == &self.recv_completion);
        assert(self.recv_in_flight);
        self.recv_in_flight = false;

        const received = result catch |err| {
            log.debug("recv failed: {s}", .{@errorName(err)});
            return self.beginClose();
        };
        if (received == 0) return self.beginClose();

        self.request_size += @intCast(received);
        assert(self.request_size <= self.request_buffer.len);

        self.advance();
    }

    // -----------------------------------------------------------------------
    // Running commands
    // -----------------------------------------------------------------------

    fn processRequest(self: *Connection) void {
        assert(self.state == .open);
        assert(self.request_size > 0);
        assert(self.response_size == 0);
        assert(self.response_size_sent == 0);

        const request = self.request_buffer[0..self.request_size];
        var writer: Io.Writer = .fixed(self.response_buffer);

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

        self.commit_pending = outcome.commit_required;
        if (outcome.close) self.state = .closing;
    }

    // -----------------------------------------------------------------------
    // Sending
    // -----------------------------------------------------------------------

    fn hasPendingResponse(self: *const Connection) bool {
        assert(self.response_size_sent <= self.response_size);
        return self.response_size_sent < self.response_size;
    }

    fn submitSend(self: *Connection) void {
        assert(self.state != .free);
        assert(!self.send_in_flight);
        assert(self.hasPendingResponse());
        assert(!self.commit_pending);

        self.send_in_flight = true;
        self.event_loop.send(
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
        completion: *EventLoop.Completion,
        result: SendError!usize,
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

        if (!self.hasPendingResponse()) {
            self.response_size = 0;
            self.response_size_sent = 0;
        }

        self.advance();
    }

    // -----------------------------------------------------------------------
    // Closing
    // -----------------------------------------------------------------------

    fn beginClose(self: *Connection) void {
        assert(self.state != .free);

        self.state = .closing;
        self.closeWhenDrained();
    }

    fn closeWhenDrained(self: *Connection) void {
        assert(self.state == .closing);

        if (self.hasPendingResponse()) return;
        if (self.recv_in_flight or self.send_in_flight) return;

        assert(self.fd > -1);
        self.event_loop.close(
            Connection,
            self,
            onClose,
            &self.send_completion,
            self.fd,
        );
        self.send_in_flight = true;
    }

    fn onClose(self: *Connection, completion: *EventLoop.Completion) void {
        assert(completion == &self.send_completion);
        assert(self.state == .closing);

        self.send_in_flight = false;
        self.state = .free;
        self.fd = -1;
        self.request_size = 0;
        self.response_size = 0;
        self.response_size_sent = 0;
        self.commit_pending = false;
    }
};
