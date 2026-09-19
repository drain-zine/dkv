//! The IO seam. Callers import this file and name `Io`, never a backend.

const builtin = @import("builtin");
const operation = @import("operation.zig");

pub const CompletionStatus = operation.CompletionStatus;
pub const Operation = operation.Operation;
pub const AcceptError = operation.AcceptError;
pub const RecvError = operation.RecvError;
pub const SendError = operation.SendError;
pub const RunError = operation.RunError;

/// The backend for this target, chosen at compile time.
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
    else => @compileError("dkv has no IO backend for " ++ @tagName(builtin.os.tag)),
};

/// Owned and embedded by callers, one per in-flight operation.
pub const Completion = Io.Completion;
