//! The vocabulary shared by every IO backend: what can be asked for, and what
//! comes back. Imports nothing from the backends or the facade, so the IO
//! files form a stack rather than a cycle.

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
