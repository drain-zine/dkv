const builtin = @import("builtin");
const operation = @import("operation.zig");

pub const CompletionStatus = operation.CompletionStatus;
pub const Operation = operation.Operation;
pub const AcceptError = operation.AcceptError;
pub const RecvError = operation.RecvError;
pub const SendError = operation.SendError;
pub const RunError = operation.RunError;

pub const Io = switch (builtin.os.tag) {
    .macos,
    .ios,
    .tvos,
    .watchos,
    .visionos,
    .driverkit,
    .maccatalyst,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    => @import("kqueue.zig").Kqueue,
    .linux => @import("epoll.zig").Epoll,
    else => @compileError("dkv has no IO backend for " ++ @tagName(builtin.os.tag)),
};

pub const Completion = Io.Completion;
