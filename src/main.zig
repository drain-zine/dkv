const std = @import("std");
const Io = std.Io;

const Server = @import("server.zig").Server;
const Store = @import("store.zig").Store;

const log = std.log.scoped(.main);

const host = "127.0.0.1";
const port = 6379;

pub fn main(init: std.process.Init) !void {
    var store = try Store.init(init.gpa, init.io, .{ .dir = Io.Dir.cwd(), .startup = .replay });
    defer store.deinit();

    const address = try Io.net.IpAddress.parse(host, port);
    var server = try Server.init(init.gpa, init.io, &store, .{ .address = address });
    defer server.deinit();

    log.info("replayed {d} keys, listening on {s}:{d}", .{ store.count(), host, port });
    try server.run();
}

test {
    _ = @import("constants.zig");
    _ = @import("resp.zig");
    _ = @import("server.zig");
    _ = @import("session.zig");
    _ = @import("store.zig");
    _ = @import("wal.zig");
}
