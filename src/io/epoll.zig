const std = @import("std");
const constants = @import("../constants.zig");
const op = @import("operation.zig");
const assert = std.debug.assert;
const System = std.posix.system;

const RingBuffer = @import("../ring_buffer.zig").RingBuffer;
const Completion = Epoll.Completion;
const CompletionRing = RingBuffer(*Completion, constants.io_ring_capacity);

pub const Epoll = struct {
    epoll_fd: System.fd_t,
    submitted: CompletionRing,
    completed: CompletionRing,
    io_pending_count: u32,

    events: [constants.io_event_count_max]System.epoll_event,
    registrations: [constants.io_registration_count_max]Registration,
    changes: [constants.io_change_count_max]System.fd_t,
    change_count: u32,

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    pub const Completion = struct {
        state: op.CompletionStatus = .unused,
        operation: op.Operation,
        context: ?*anyopaque,
        callback: *const fn (epoll: *Epoll, completion: *Epoll.Completion) void,
        try_operation: *const fn (completion: *Epoll.Completion) Progress,
        woken: bool = false,
    };

    pub const InitError = error{
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
        Unexpected,
    };

    /// epoll holds one entry per descriptor, not one per operation, so a
    /// receive and a send on the same socket share a registration and are told
    /// apart by the event mask that comes back.
    const Registration = struct {
        recv: ?*Epoll.Completion = null,
        send: ?*Epoll.Completion = null,
        /// The mask the kernel currently holds, so an unchanged one costs
        /// nothing.
        registered: u32 = 0,
        dirty: bool = false,
    };

    const Progress = enum { completed, io_pending };

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init() InitError!Epoll {
        const rc = System.epoll_create1(System.EPOLL.CLOEXEC);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }

        const epoll_fd: System.fd_t = @intCast(rc);
        assert(epoll_fd > -1);

        return .{
            .epoll_fd = epoll_fd,
            .submitted = .{},
            .completed = .{},
            .io_pending_count = 0,
            .events = undefined,
            .registrations = [_]Registration{.{}} ** constants.io_registration_count_max,
            .changes = undefined,
            .change_count = 0,
        };
    }

    /// Drops the queue without draining it. An armed completion has nothing to
    /// cancel it, so `deinit`'s invariants cannot hold at an abrupt stop.
    pub fn shutdown(self: *Epoll) void {
        assert(self.epoll_fd > -1);

        _ = System.close(self.epoll_fd);
    }

    pub fn deinit(self: *Epoll) void {
        assert(self.epoll_fd > -1);
        assert(self.submitted.count == 0);
        assert(self.completed.count == 0);
        assert(self.io_pending_count == 0);
        assert(self.change_count == 0);

        _ = System.close(self.epoll_fd);
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // Operations
    // -----------------------------------------------------------------------

    pub fn accept(
        self: *Epoll,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (
            context: *Context,
            completion: *Epoll.Completion,
            result: op.AcceptError!System.fd_t,
        ) void,
        completion: *Epoll.Completion,
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
        self: *Epoll,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (
            context: *Context,
            completion: *Epoll.Completion,
            result: op.RecvError!usize,
        ) void,
        completion: *Epoll.Completion,
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
        self: *Epoll,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (
            context: *Context,
            completion: *Epoll.Completion,
            result: op.SendError!usize,
        ) void,
        completion: *Epoll.Completion,
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
        self: *Epoll,
        comptime Context: type,
        context: *Context,
        comptime callback: fn (context: *Context, completion: *Epoll.Completion) void,
        completion: *Epoll.Completion,
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

    pub fn runForNs(self: *Epoll, nanoseconds: u63) op.RunError!void {
        self.flushSubmitted();
        try self.flushChanges();

        const nothing_can_wake_us = self.completed.count == 0 and self.io_pending_count == 0;
        if (nothing_can_wake_us) return;

        const collect_only = self.completed.count > 0;
        const timeout_ms: i32 = if (collect_only) 0 else millisecondsForNs(nanoseconds);

        try self.waitForEvents(timeout_ms);
        self.completeAll();
    }

    fn waitForEvents(self: *Epoll, timeout_ms: i32) op.RunError!void {
        const event_count = try self.epollWait(timeout_ms);

        for (self.events[0..event_count]) |event| {
            const fd = event.data.fd;
            const registration = &self.registrations[registrationIndex(fd)];

            // An error or a hangup wakes both directions: the syscall itself
            // reports what went wrong.
            const failed = event.events & (System.EPOLL.ERR | System.EPOLL.HUP) != 0;
            const readable = failed or event.events & System.EPOLL.IN != 0;
            const writable = failed or event.events & System.EPOLL.OUT != 0;

            if (readable) {
                if (registration.recv) |completion| {
                    registration.recv = null;
                    self.wake(completion);
                }
            }
            if (writable) {
                if (registration.send) |completion| {
                    registration.send = null;
                    self.wake(completion);
                }
            }

            self.markDirty(fd, registration);
        }

        if (event_count > 0) self.flushSubmitted();
    }

    fn wake(self: *Epoll, completion: *Epoll.Completion) void {
        assert(completion.state == .io_pending);
        assert(self.io_pending_count > 0);

        completion.state = .submitted;
        completion.woken = true;
        self.submitted.push(completion);
        self.io_pending_count -= 1;
    }

    fn epollWait(self: *Epoll, timeout_ms: i32) op.RunError!u32 {
        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.epoll_wait(
                self.epoll_fd,
                &self.events,
                @intCast(self.events.len),
                timeout_ms,
            );
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
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

    fn completeAll(self: *Epoll) void {
        const count = self.completed.count;

        for (0..count) |_| {
            const completion = self.completed.pop().?;
            assert(completion.state == .completed);

            completion.state = .unused;
            completion.callback(self, completion);
        }
    }

    fn millisecondsForNs(nanoseconds: u63) i32 {
        const milliseconds = nanoseconds / std.time.ns_per_ms;
        return std.math.cast(i32, milliseconds) orelse std.math.maxInt(i32);
    }

    // -----------------------------------------------------------------------
    // Submission
    // -----------------------------------------------------------------------

    fn submitOperation(
        self: *Epoll,
        comptime tag: std.meta.Tag(op.Operation),
        payload: @FieldType(op.Operation, @tagName(tag)),
        comptime Context: type,
        context: *Context,
        comptime callback: anytype,
        completion: *Epoll.Completion,
        comptime try_operation: fn (completion: *Epoll.Completion) Progress,
    ) void {
        const wrapper = struct {
            fn onComplete(_: *Epoll, inner_completion: *Epoll.Completion) void {
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
        self: *Epoll,
        completion: *Epoll.Completion,
        operation: op.Operation,
        comptime Context: type,
        context: *Context,
        callback: *const fn (epoll: *Epoll, completion: *Epoll.Completion) void,
        try_operation: *const fn (completion: *Epoll.Completion) Progress,
    ) void {
        assert(completion.state == .unused);

        completion.operation = operation;
        completion.context = context;
        completion.callback = callback;
        completion.try_operation = try_operation;
        completion.state = .submitted;
        completion.woken = false;
        self.submitted.push(completion);
    }

    fn flushSubmitted(self: *Epoll) void {
        const count = self.submitted.count;

        for (0..count) |_| {
            const completion = self.submitted.pop().?;
            assert(completion.state == .submitted);

            const woken = completion.woken;
            completion.woken = false;

            if (woken or likelyReady(completion.operation)) {
                switch (completion.try_operation(completion)) {
                    .completed => {
                        // A closed descriptor loses its registration in the
                        // kernel, so drop ours before the number is reused.
                        switch (completion.operation) {
                            .close => |closing| self.forget(closing.fd),
                            else => {},
                        }
                        completion.state = .completed;
                        self.completed.push(completion);
                    },
                    .io_pending => self.markPending(completion),
                }
            } else {
                self.markPending(completion);
            }
        }
    }

    /// Whether to run the syscall before registering. A receive is submitted
    /// just after a reply goes out, while the client is still reading it, so
    /// the socket is empty by construction and an eager read almost always
    /// fails. Sends hold bytes for a buffer that has room, and accepts run
    /// against a backlog, so both almost always succeed.
    fn likelyReady(operation: op.Operation) bool {
        return switch (operation) {
            .accept, .send, .close => true,
            .recv => false,
        };
    }

    fn markPending(self: *Epoll, completion: *Epoll.Completion) void {
        completion.state = .io_pending;

        const fd = descriptorFor(completion.operation);
        const registration = &self.registrations[registrationIndex(fd)];

        switch (completion.operation) {
            .accept, .recv => {
                assert(registration.recv == null);
                registration.recv = completion;
            },
            .send => {
                assert(registration.send == null);
                registration.send = completion;
            },
            .close => unreachable,
        }

        self.markDirty(fd, registration);
        self.io_pending_count += 1;
    }

    // -----------------------------------------------------------------------
    // Arming
    // -----------------------------------------------------------------------

    fn markDirty(self: *Epoll, fd: System.fd_t, registration: *Registration) void {
        if (registration.dirty) return;

        assert(self.change_count < self.changes.len);
        self.changes[self.change_count] = fd;
        self.change_count += 1;
        registration.dirty = true;
    }

    /// Arming waits until the end of a pass. A descriptor taken and re-armed
    /// within the same pass — an ordinary request and reply — settles on the
    /// mask it already held, so it costs no syscall at all.
    fn flushChanges(self: *Epoll) op.RunError!void {
        for (self.changes[0..self.change_count]) |fd| {
            const registration = &self.registrations[registrationIndex(fd)];
            registration.dirty = false;

            var desired: u32 = 0;
            if (registration.recv != null) desired |= System.EPOLL.IN;
            if (registration.send != null) desired |= System.EPOLL.OUT;
            if (desired == registration.registered) continue;

            try self.control(fd, desired, registration.registered);
            registration.registered = desired;
        }

        self.change_count = 0;
    }

    fn control(self: *Epoll, fd: System.fd_t, desired: u32, registered: u32) op.RunError!void {
        if (desired == 0) {
            switch (self.epollControl(System.EPOLL.CTL_DEL, fd, null)) {
                // Already out of the set, which is what was wanted either way.
                .SUCCESS, .NOENT, .BADF => return,
                else => return error.Unexpected,
            }
        }

        var event: System.epoll_event = .{ .events = desired, .data = .{ .fd = fd } };
        const action: u32 = if (registered == 0) System.EPOLL.CTL_ADD else System.EPOLL.CTL_MOD;

        // Descriptor numbers are reused, so recover rather than trust what was
        // last recorded. A second failure is a real one.
        const recovery: u32 = switch (self.epollControl(action, fd, &event)) {
            .SUCCESS => return,
            .EXIST => System.EPOLL.CTL_MOD,
            .NOENT => System.EPOLL.CTL_ADD,
            else => return error.Unexpected,
        };

        switch (self.epollControl(recovery, fd, &event)) {
            .SUCCESS => return,
            else => return error.Unexpected,
        }
    }

    fn epollControl(
        self: *Epoll,
        action: u32,
        fd: System.fd_t,
        event: ?*System.epoll_event,
    ) std.posix.E {
        return std.posix.errno(System.epoll_ctl(self.epoll_fd, action, fd, event));
    }

    fn forget(self: *Epoll, fd: System.fd_t) void {
        const registration = &self.registrations[registrationIndex(fd)];
        assert(registration.recv == null);
        assert(registration.send == null);

        registration.registered = 0;
    }

    fn descriptorFor(operation: op.Operation) System.fd_t {
        return switch (operation) {
            .accept => |accept_operation| accept_operation.listener_fd,
            .recv => |recv_operation| recv_operation.fd,
            .send => |send_operation| send_operation.fd,
            .close => unreachable,
        };
    }

    fn registrationIndex(fd: System.fd_t) usize {
        assert(fd > -1);
        assert(@as(usize, @intCast(fd)) < constants.io_registration_count_max);

        return @intCast(fd);
    }

    // -----------------------------------------------------------------------
    // Syscalls
    // -----------------------------------------------------------------------

    fn tryAccept(completion: *Epoll.Completion) Progress {
        const operation = &completion.operation.accept;

        for (0..constants.io_syscall_retry_max) |_| {
            // Linux does not inherit the listener's flags, so the descriptor is
            // made non-blocking as it is accepted.
            const rc = System.accept4(operation.listener_fd, null, null, System.SOCK.NONBLOCK);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    operation.result = @intCast(rc);
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

    fn tryRecv(completion: *Epoll.Completion) Progress {
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

    fn trySend(completion: *Epoll.Completion) Progress {
        const operation = &completion.operation.send;

        for (0..constants.io_syscall_retry_max) |_| {
            // `MSG_NOSIGNAL` rather than `write`, so a closed peer returns
            // EPIPE instead of killing the process with SIGPIPE.
            const rc = System.sendto(
                operation.fd,
                operation.bytes.ptr,
                operation.bytes.len,
                System.MSG.NOSIGNAL,
                null,
                0,
            );
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

    fn tryClose(completion: *Epoll.Completion) Progress {
        _ = System.close(completion.operation.close.fd);
        return .completed;
    }

    // -----------------------------------------------------------------------
    // Socket setup
    // -----------------------------------------------------------------------

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
            const rc = System.fcntl(fd, System.F.GETFL, @as(usize, 0));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }

        return error.Unexpected;
    }
};
