const std = @import("std");
const Io = std.Io;

const Server = @import("server.zig").Server;
const Store = @import("storage/store.zig").Store;

const log = std.log.scoped(.main);

const host = "127.0.0.1";
const port = 6379;

pub fn main(init: std.process.Init) !void {
    var store = try Store.init(init.gpa, init.io, .{ .dir = Io.Dir.cwd(), .startup = .replay });
    defer store.deinit();

    var server = try Server.init(init.gpa, init.io, &store, .{ .host = host, .port = port });
    defer server.deinit();
    server.start();

    log.info("replayed {d} keys, listening on {s}:{d}", .{ store.count(), host, port });
    try server.run();
}

test {
    _ = @import("connection.zig");
    _ = @import("constants.zig");
    _ = @import("ring_buffer.zig");
    _ = @import("server.zig");

    _ = @import("io/kqueue.zig");
    _ = @import("protocol/command_loop.zig");
    _ = @import("protocol/resp.zig");
    _ = @import("storage/store.zig");
    _ = @import("storage/wal.zig");
}
