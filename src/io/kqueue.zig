const std = @import("std");
const constants = @import("../constants.zig");
const op = @import("operation.zig");
const assert = std.debug.assert;
const System = std.posix.system;

const RingBuffer = @import("../ring_buffer.zig").RingBuffer;
const Completion = Kqueue.Completion;
const CompletionRing = RingBuffer(*Completion, constants.io_ring_capacity);

pub const Kqueue = struct {
    kqueue_fd: System.fd_t,
    submitted: CompletionRing,
    completed: CompletionRing,
    io_pending_count: u32,

    changes: [constants.io_change_count_max]System.Kevent,
    change_count: u32,
    events: [constants.io_event_count_max]System.Kevent,

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    pub const Completion = struct {
        state: op.CompletionStatus = .unused,
        operation: op.Operation,
        context: ?*anyopaque,
        callback: *const fn (kqueue: *Kqueue, completion: *Kqueue.Completion) void,
        try_operation: *const fn (completion: *Kqueue.Completion) Progress,
    };

    pub const InitError = error{
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        Unexpected,
    };

    const Arming = struct { fd: System.fd_t, filter: i16 };
    const Progress = enum { completed, io_pending };

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init() InitError!Kqueue {
        const kqueue_fd = System.kqueue();
        switch (std.posix.errno(kqueue_fd)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        assert(kqueue_fd > -1);

        return .{
            .kqueue_fd = kqueue_fd,
            .submitted = .{},
            .completed = .{},
            .io_pending_count = 0,
            .changes = undefined,
            .change_count = 0,
            .events = undefined,
        };
    }

    pub fn deinit(self: *Kqueue) void {
        assert(self.kqueue_fd > -1);
        assert(self.submitted.count == 0);
        assert(self.completed.count == 0);
        assert(self.io_pending_count == 0);
        assert(self.change_count == 0);

        _ = System.close(self.kqueue_fd);
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // Operations
    // -----------------------------------------------------------------------

    pub fn accept(
        self: *Kqueue,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (
            context: *Context,
            completion: *Kqueue.Completion,
            result: op.AcceptError!System.fd_t,
        ) void,
        completion: *Kqueue.Completion,
        listener_fd: System.fd_t,
    ) void {
        assert(listener_fd > -1);

        self.submitOperation(
            .accept,
            .{ .listener_fd = listener_fd, .result = undefined },
            Context,
            context,
            callback,
            completion,
            tryAccept,
        );
    }

    pub fn recv(
        self: *Kqueue,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (
            context: *Context,
            completion: *Kqueue.Completion,
            result: op.RecvError!usize,
        ) void,
        completion: *Kqueue.Completion,
        fd: System.fd_t,
        buffer: []u8,
    ) void {
        assert(fd > -1);
        assert(buffer.len > 0);

        self.submitOperation(
            .recv,
            .{ .fd = fd, .buffer = buffer, .result = undefined },
            Context,
            context,
            callback,
            completion,
            tryRecv,
        );
    }

    pub fn send(
        self: *Kqueue,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (
            context: *Context,
            completion: *Kqueue.Completion,
            result: op.SendError!usize,
        ) void,
        completion: *Kqueue.Completion,
        fd: System.fd_t,
        bytes: []const u8,
    ) void {
        assert(fd > -1);
        assert(bytes.len > 0);

        self.submitOperation(
            .send,
            .{ .fd = fd, .bytes = bytes, .result = undefined },
            Context,
            context,
            callback,
            completion,
            trySend,
        );
    }

    pub fn close(
        self: *Kqueue,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (context: *Context, completion: *Kqueue.Completion) void,
        completion: *Kqueue.Completion,
        fd: System.fd_t,
    ) void {
        assert(fd > -1);

        self.submitOperation(
            .close,
            .{ .fd = fd },
            Context,
            context,
            callback,
            completion,
            tryClose,
        );
    }

    // -----------------------------------------------------------------------
    // Event loop
    // -----------------------------------------------------------------------

    pub fn runForNs(self: *Kqueue, nanoseconds: u63) op.RunError!void {
        self.flushSubmitted();

        const nothing_can_wake_us = self.completed.count == 0 and
            self.io_pending_count == 0 and
            self.change_count == 0;
        if (nothing_can_wake_us) return;

        const collect_only = self.completed.count > 0;
        const timeout = timespecForNs(if (collect_only) 0 else nanoseconds);

        try self.waitForEvents(timeout);
        self.completeAll();
        assert(self.change_count == 0);
    }

    fn waitForEvents(self: *Kqueue, timeout: System.timespec) op.RunError!void {
        const event_count = try self.kevent(timeout);
        assert(self.change_count == 0);

        for (self.events[0..event_count]) |event| {
            const completion: *Kqueue.Completion = @ptrFromInt(event.udata);
            assert(completion.state == .io_pending);
            assert(self.io_pending_count > 0);

            completion.state = .submitted;
            self.submitted.push(completion);
            self.io_pending_count -= 1;
        }

        if (event_count > 0) self.flushSubmitted();
    }

    fn kevent(self: *Kqueue, timeout: System.timespec) op.RunError!u32 {
        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.kevent(
                self.kqueue_fd,
                &self.changes,
                @intCast(self.change_count),
                &self.events,
                @intCast(self.events.len),
                &timeout,
            );
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    self.change_count = 0;

                    const event_count: u32 = @intCast(rc);
                    assert(event_count <= self.events.len);
                    return event_count;
                },
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }

        return error.Unexpected;
    }

    fn completeAll(self: *Kqueue) void {
        const count = self.completed.count;

        for (0..count) |_| {
            const completion = self.completed.pop().?;
            assert(completion.state == .completed);

            completion.state = .unused;
            completion.callback(self, completion);
        }
    }

    fn timespecForNs(nanoseconds: u63) System.timespec {
        return .{
            .sec = nanoseconds / std.time.ns_per_s,
            .nsec = nanoseconds % std.time.ns_per_s,
        };
    }

    // -----------------------------------------------------------------------
    // Submission
    // -----------------------------------------------------------------------

    fn submitOperation(
        self: *Kqueue,
        comptime tag: std.meta.Tag(op.Operation),
        payload: @FieldType(op.Operation, @tagName(tag)),
        comptime Context: type,
        context: *Context,
        comptime callback: anytype,
        completion: *Kqueue.Completion,
        comptime try_operation: fn (completion: *Kqueue.Completion) Progress,
    ) void {
        const wrapper = struct {
            fn onComplete(_: *Kqueue, inner_completion: *Kqueue.Completion) void {
                const inner_context: *Context = @ptrCast(@alignCast(inner_completion.context.?));
                const inner_payload = &@field(inner_completion.operation, @tagName(tag));

                if (comptime @hasField(@TypeOf(inner_payload.*), "result")) {
                    callback(inner_context, inner_completion, inner_payload.result);
                } else {
                    callback(inner_context, inner_completion);
                }
            }
        }.onComplete;

        self.submit(
            completion,
            @unionInit(op.Operation, @tagName(tag), payload),
            Context,
            context,
            wrapper,
            try_operation,
        );
    }

    fn submit(
        self: *Kqueue,
        completion: *Kqueue.Completion,
        operation: op.Operation,
        comptime Context: type,
        context: *Context,
        callback: *const fn (kqueue: *Kqueue, completion: *Kqueue.Completion) void,
        try_operation: *const fn (completion: *Kqueue.Completion) Progress,
    ) void {
        assert(completion.state == .unused);

        completion.operation = operation;
        completion.context = context;
        completion.callback = callback;
        completion.try_operation = try_operation;
        completion.state = .submitted;
        self.submitted.push(completion);
    }

    fn flushSubmitted(self: *Kqueue) void {
        const count = self.submitted.count;

        for (0..count) |_| {
            const completion = self.submitted.pop().?;
            assert(completion.state == .submitted);

            switch (completion.try_operation(completion)) {
                .completed => {
                    completion.state = .completed;
                    self.completed.push(completion);
                },
                .io_pending => {
                    completion.state = .io_pending;
                    self.armCompletion(completion);
                    self.io_pending_count += 1;
                },
            }
        }
    }

    // -----------------------------------------------------------------------
    // Arming
    // -----------------------------------------------------------------------

    fn armCompletion(self: *Kqueue, completion: *Kqueue.Completion) void {
        assert(completion.state == .io_pending);
        assert(self.change_count < self.changes.len);

        const arming = armingFor(completion.operation);
        assert(arming.fd > -1);

        self.changes[self.change_count] = .{
            .ident = @intCast(arming.fd),
            .filter = arming.filter,
            .flags = System.EV.ADD | System.EV.ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @intFromPtr(completion),
        };
        self.change_count += 1;
    }

    fn armingFor(operation: op.Operation) Arming {
        return switch (operation) {
            .accept => |accept_operation| .{
                .fd = accept_operation.listener_fd,
                .filter = System.EVFILT.READ,
            },
            .recv => |recv_operation| .{
                .fd = recv_operation.fd,
                .filter = System.EVFILT.READ,
            },
            .send => |send_operation| .{
                .fd = send_operation.fd,
                .filter = System.EVFILT.WRITE,
            },
            .close => unreachable,
        };
    }

    // -----------------------------------------------------------------------
    // Syscalls
    // -----------------------------------------------------------------------

    fn tryAccept(completion: *Kqueue.Completion) Progress {
        const operation = &completion.operation.accept;

        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.accept(operation.listener_fd, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    configureAccepted(rc) catch |err| {
                        _ = System.close(rc);
                        operation.result = err;
                        return .completed;
                    };
                    operation.result = rc;
                    return .completed;
                },
                .INTR => continue,
                .AGAIN, .CONNABORTED => return .io_pending,
                .MFILE => {
                    operation.result = error.ProcessFdQuotaExceeded;
                    return .completed;
                },
                .NFILE, .NOMEM => {
                    operation.result = error.SystemResources;
                    return .completed;
                },
                else => |err| {
                    operation.result = std.posix.unexpectedErrno(err);
                    return .completed;
                },
            }
        }

        operation.result = error.Unexpected;
        return .completed;
    }

    fn tryRecv(completion: *Kqueue.Completion) Progress {
        const operation = &completion.operation.recv;

        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.read(operation.fd, operation.buffer.ptr, operation.buffer.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    operation.result = @intCast(rc);
                    return .completed;
                },
                .INTR => continue,
                .AGAIN => return .io_pending,
                .CONNRESET, .TIMEDOUT => {
                    operation.result = error.ConnectionResetByPeer;
                    return .completed;
                },
                else => |err| {
                    operation.result = std.posix.unexpectedErrno(err);
                    return .completed;
                },
            }
        }

        operation.result = error.Unexpected;
        return .completed;
    }

    fn trySend(completion: *Kqueue.Completion) Progress {
        const operation = &completion.operation.send;

        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.write(operation.fd, operation.bytes.ptr, operation.bytes.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    operation.result = @intCast(rc);
                    return .completed;
                },
                .INTR => continue,
                .AGAIN => return .io_pending,
                .PIPE => {
                    operation.result = error.BrokenPipe;
                    return .completed;
                },
                .CONNRESET, .TIMEDOUT => {
                    operation.result = error.ConnectionResetByPeer;
                    return .completed;
                },
                else => |err| {
                    operation.result = std.posix.unexpectedErrno(err);
                    return .completed;
                },
            }
        }

        operation.result = error.Unexpected;
        return .completed;
    }

    fn tryClose(completion: *Kqueue.Completion) Progress {
        _ = System.close(completion.operation.close.fd);
        return .completed;
    }

    // -----------------------------------------------------------------------
    // Socket setup
    // -----------------------------------------------------------------------

    fn configureAccepted(fd: System.fd_t) op.AcceptError!void {
        assert(fd > -1);

        try setNonBlocking(fd);
        try disableSigPipe(fd);
    }

    pub fn setNonBlocking(fd: System.fd_t) op.AcceptError!void {
        const flags = try fileFlags(fd);
        const nonblocking: usize = 1 << @bitOffsetOf(System.O, "NONBLOCK");

        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.fcntl(fd, System.F.SETFL, flags | nonblocking);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }

        return error.Unexpected;
    }

    fn fileFlags(fd: System.fd_t) op.AcceptError!usize {
        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.fcntl(fd, System.F.GETFL);
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }

        return error.Unexpected;
    }

    fn disableSigPipe(fd: System.fd_t) op.AcceptError!void {
        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.fcntl(fd, System.F.SETNOSIGPIPE, @as(c_int, 1));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }

        return error.Unexpected;
    }
};
