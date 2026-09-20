const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const System = std.posix.system;

const constants = @import("../constants.zig");

pub const Handle = std.posix.fd_t;

pub const Error = error{Unexpected};

const darwin = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => true,
    else => false,
};

pub fn syncBarrier(fd: Handle) Error!void {
    assert(fd > -1);

    if (darwin) {
        for (0..constants.io_syscall_retry_max) |_| {
            const rc = System.fcntl(fd, System.F.FULLFSYNC, @as(c_int, 0));
            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => break,
            }
        }
    }

    return sync(fd);
}

fn sync(fd: Handle) Error!void {
    for (0..constants.io_syscall_retry_max) |_| {
        const rc = System.fsync(fd);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    return error.Unexpected;
}
