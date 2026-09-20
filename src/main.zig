const std = @import("std");
const Io = std.Io;

const Config = @import("config.zig").Config;
const Server = @import("server.zig").Server;
const Store = @import("storage/store.zig").Store;

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    defer arguments.deinit();

    const config = Config.parse(&arguments) catch |err| {
        log.err("{s}\n\n{s}", .{ @errorName(err), Config.usage });
        return err;
    };

    var dir = Io.Dir.cwd();
    if (config.dir_path) |path| dir = try dir.openDir(init.io, path, .{});

    var store = try Store.init(init.gpa, init.io, .{
        .dir = dir,
        .startup = .replay,
        .wal = .{ .durability = config.durability },
    });
    defer store.deinit();

    var server = try Server.init(init.gpa, init.io, &store, .{
        .host = config.host,
        .port = config.port,
    });
    defer server.deinit();
    server.start();

    log.info("replayed {d} keys, listening on {s}:{d}, durability {s}", .{
        store.count(),
        config.host,
        config.port,
        @tagName(config.durability),
    });
    if (config.replica) |index| {
        log.info("replica {d} of {d}", .{ index, config.address_count });
    }

    try server.run();
}

test {
    _ = @import("config.zig");
    _ = @import("connection.zig");
    _ = @import("constants.zig");
    _ = @import("ring_buffer.zig");
    _ = @import("server.zig");

    _ = @import("io/descriptor.zig");
    _ = @import("io/kqueue.zig");
    _ = @import("protocol/command_loop.zig");
    _ = @import("protocol/resp.zig");
    _ = @import("storage/store.zig");
    _ = @import("storage/wal.zig");
}
