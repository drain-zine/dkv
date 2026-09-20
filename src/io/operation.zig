const std = @import("std");
const System = std.posix.system;

pub const CompletionStatus = enum { unused, submitted, io_pending, completed };

pub const Operation = union(enum) {
    accept: struct { listener_fd: System.fd_t, result: AcceptError!System.fd_t },
    recv: struct { fd: System.fd_t, buffer: []u8, result: RecvError!usize },
    send: struct { fd: System.fd_t, bytes: []const u8, result: SendError!usize },
    close: struct { fd: System.fd_t },
};

pub const AcceptError = error{ ProcessFdQuotaExceeded, SystemResources, Unexpected };
pub const RecvError = error{ ConnectionResetByPeer, Unexpected };
pub const SendError = error{ ConnectionResetByPeer, BrokenPipe, Unexpected };
pub const RunError = error{Unexpected};
