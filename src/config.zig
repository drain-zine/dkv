const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const constants = @import("constants.zig");
const Durability = @import("vsr/journal.zig").Durability;

pub const Error = error{
    UnknownFlag,
    MissingValue,
    BadPort,
    BadReplica,
    BadAddress,
    BadDurability,
    BadCluster,
    ClusterRequired,
    DurabilityOffInCluster,
    TooManyAddresses,
    ReplicaOutOfRange,
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    dir_path: ?[]const u8 = null,
    durability: Durability = .always,

    cluster: u32 = 0,
    replica: ?u8 = null,
    addresses: [constants.cluster_replica_count_max][]const u8 = undefined,
    address_count: u8 = 0,

    pub const usage =
        \\dkv [options]
        \\  --port=N                 client port (default 6379)
        \\  --dir=PATH               directory holding the log (default .)
        \\  --durability=always|buffered|off
        \\  --cluster=N              this cluster's id, the same on every replica
        \\  --replica=N              this replica's index in the cluster
        \\  --addresses=A,B,C        every replica's address, in index order
        \\
    ;

    pub fn parse(arguments: *std.process.Args.Iterator) Error!Config {
        var self: Config = .{};
        var cluster_given = false;
        _ = arguments.skip();

        while (arguments.next()) |argument| {
            if (value(argument, "--port=")) |text| {
                self.port = std.fmt.parseInt(u16, text, 10) catch return error.BadPort;
            } else if (value(argument, "--dir=")) |text| {
                if (text.len == 0) return error.MissingValue;
                self.dir_path = text;
            } else if (value(argument, "--durability=")) |text| {
                self.durability = if (std.mem.eql(u8, text, "always"))
                    .always
                else if (std.mem.eql(u8, text, "buffered"))
                    .buffered
                else if (std.mem.eql(u8, text, "off"))
                    .off
                else
                    return error.BadDurability;
            } else if (value(argument, "--cluster=")) |text| {
                self.cluster = std.fmt.parseInt(u32, text, 10) catch return error.BadCluster;
                cluster_given = true;
            } else if (value(argument, "--replica=")) |text| {
                self.replica = std.fmt.parseInt(u8, text, 10) catch return error.BadReplica;
            } else if (value(argument, "--addresses=")) |text| {
                try self.parseAddresses(text);
            } else {
                return error.UnknownFlag;
            }
        }

        if (self.address_count > 0 and !cluster_given) return error.ClusterRequired;

        if (self.replica) |index| {
            if (index >= self.address_count) return error.ReplicaOutOfRange;

            if (self.durability == .off) return error.DurabilityOffInCluster;
        }
        return self;
    }

    fn parseAddresses(self: *Config, text: []const u8) Error!void {
        self.address_count = 0;

        var listed = std.mem.splitScalar(u8, text, ',');
        while (listed.next()) |address| {
            if (address.len == 0) return error.BadAddress;
            if (self.address_count == constants.cluster_replica_count_max) {
                return error.TooManyAddresses;
            }
            _ = Io.net.IpAddress.parseLiteral(address) catch return error.BadAddress;

            self.addresses[self.address_count] = address;
            self.address_count += 1;
        }

        if (self.address_count == 0) return error.BadAddress;
    }

    pub fn peers(self: *const Config) []const []const u8 {
        return self.addresses[0..self.address_count];
    }

    fn value(argument: []const u8, flag: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, argument, flag)) return null;
        return argument[flag.len..];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseSlice(comptime arguments: []const [:0]const u8) Error!Config {
    const vector = comptime blk: {
        var pointers: [arguments.len][*:0]const u8 = undefined;
        for (arguments, 0..) |argument, index| pointers[index] = argument.ptr;
        break :blk pointers;
    };

    const args: std.process.Args = .{ .vector = &vector };
    var iterator = args.iterate();
    return Config.parse(&iterator);
}

test "defaults when nothing is passed" {
    const config = try parseSlice(&.{"dkv"});

    try testing.expectEqual(6379, config.port);
    try testing.expectEqual(.always, config.durability);
    try testing.expectEqual(null, config.dir_path);
    try testing.expectEqual(null, config.replica);
    try testing.expectEqual(0, config.address_count);
    try testing.expectEqual(0, config.cluster);
}

test "every flag together" {
    const config = try parseSlice(&.{
        "dkv",
        "--port=7100",
        "--dir=/var/lib/dkv",
        "--durability=buffered",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000,10.0.1.3:7000",
        "--replica=2",
        "--cluster=9",
    });

    try testing.expectEqual(7100, config.port);
    try testing.expectEqualStrings("/var/lib/dkv", config.dir_path.?);
    try testing.expectEqual(.buffered, config.durability);
    try testing.expectEqual(3, config.address_count);
    try testing.expectEqualStrings("10.0.1.2:7000", config.peers()[1]);
    try testing.expectEqual(2, config.replica.?);
    try testing.expectEqual(9, config.cluster);
}

test "bad input is refused at startup" {
    try testing.expectError(error.UnknownFlag, parseSlice(&.{ "dkv", "--nope=1" }));
    try testing.expectError(error.BadPort, parseSlice(&.{ "dkv", "--port=99999" }));
    try testing.expectError(error.BadPort, parseSlice(&.{ "dkv", "--port=x" }));
    try testing.expectError(error.BadDurability, parseSlice(&.{ "dkv", "--durability=maybe" }));
    try testing.expectError(error.BadDurability, parseSlice(&.{ "dkv", "--durability=never" }));
    try testing.expectError(error.MissingValue, parseSlice(&.{ "dkv", "--dir=" }));
    try testing.expectError(error.BadAddress, parseSlice(&.{ "dkv", "--addresses=nonsense" }));
    try testing.expectError(error.BadAddress, parseSlice(&.{ "dkv", "--addresses=" }));
    try testing.expectError(error.BadCluster, parseSlice(&.{ "dkv", "--cluster=x" }));
    try testing.expectError(error.BadCluster, parseSlice(&.{ "dkv", "--cluster=-1" }));
}

test "a cluster of more than one needs its id spelled out" {
    try testing.expectError(error.ClusterRequired, parseSlice(&.{
        "dkv",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000",
        "--replica=0",
    }));

    const config = try parseSlice(&.{
        "dkv",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000",
        "--replica=0",
        "--cluster=4",
    });
    try testing.expectEqual(4, config.cluster);
}

test "durability off is refused for a replica" {
    try testing.expectError(error.DurabilityOffInCluster, parseSlice(&.{
        "dkv",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000",
        "--replica=0",
        "--durability=off",
        "--cluster=1",
    }));

    const config = try parseSlice(&.{ "dkv", "--durability=off" });
    try testing.expectEqual(.off, config.durability);
}

test "a replica index must name one of the addresses" {
    try testing.expectError(error.ReplicaOutOfRange, parseSlice(&.{
        "dkv",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000",
        "--replica=2",
        "--cluster=1",
    }));

    const config = try parseSlice(&.{
        "dkv",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000",
        "--replica=1",
        "--cluster=1",
    });
    try testing.expectEqual(1, config.replica.?);
}
