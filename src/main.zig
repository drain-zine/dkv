const std = @import("std");
const Io = std.Io;

const Config = @import("config.zig").Config;
const Server = @import("server.zig").Server;
const Replica = @import("vsr/replica.zig").Replica;

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

    var replica = try Replica.init(init.gpa, init.io, .{
        .dir = dir,
        .cluster = config.cluster,
        .durability = config.durability,
        .replica = config.replica orelse 0,
    });
    defer replica.deinit();

    try replica.replay();

    var server = try Server.init(init.gpa, init.io, &replica, .{
        .host = config.host,
        .port = config.port,
    });
    defer server.deinit();
    server.start();

    log.info("replayed {d} keys, listening on {s}:{d}, durability {s}", .{
        replica.count(),
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
    _ = @import("checksum.zig");
    _ = @import("config.zig");
    _ = @import("connection.zig");
    _ = @import("constants.zig");
    _ = @import("ring_buffer.zig");
    _ = @import("store.zig");
    _ = @import("server.zig");

    _ = @import("io/descriptor.zig");
    _ = @import("io/kqueue.zig");
    _ = @import("protocol/pipeline.zig");
    _ = @import("protocol/resp.zig");
    _ = @import("vsr/journal.zig");
    _ = @import("vsr/replica.zig");
    _ = @import("vsr/message.zig");
}
