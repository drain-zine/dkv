const std = @import("std");
const assert = std.debug.assert;
const StdIo = std.Io;

const constants = @import("constants.zig");
const Durability = @import("storage/wal.zig").Durability;

pub const Error = error{
    UnknownFlag,
    MissingValue,
    BadPort,
    BadReplica,
    BadAddress,
    BadDurability,
    TooManyAddresses,
    ReplicaOutOfRange,
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    dir_path: ?[]const u8 = null,
    durability: Durability = .always,

    replica: ?u8 = null,
    addresses: [constants.cluster_replica_count_max][]const u8 = undefined,
    address_count: u8 = 0,

    pub const usage =
        \\dkv [options]
        \\  --port=N                 client port (default 6379)
        \\  --dir=PATH               directory holding the log (default .)
        \\  --durability=always|never
        \\  --replica=N              this replica's index in the cluster
        \\  --addresses=A,B,C        every replica's address, in index order
        \\
    ;

    pub fn parse(arguments: *std.process.Args.Iterator) Error!Config {
        var self: Config = .{};
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
                else if (std.mem.eql(u8, text, "never"))
                    .never
                else
                    return error.BadDurability;
            } else if (value(argument, "--replica=")) |text| {
                self.replica = std.fmt.parseInt(u8, text, 10) catch return error.BadReplica;
            } else if (value(argument, "--addresses=")) |text| {
                try self.parseAddresses(text);
            } else {
                return error.UnknownFlag;
            }
        }

        if (self.replica) |index| {
            if (index >= self.address_count) return error.ReplicaOutOfRange;
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
            _ = StdIo.net.IpAddress.parseLiteral(address) catch return error.BadAddress;

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

/// Builds an argv vector the way the OS hands one over, so the tests drive the
/// same iterator `main` does rather than a stand-in.
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
}

test "every flag together" {
    const config = try parseSlice(&.{
        "dkv",
        "--port=7100",
        "--dir=/var/lib/dkv",
        "--durability=never",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000,10.0.1.3:7000",
        "--replica=2",
    });

    try testing.expectEqual(7100, config.port);
    try testing.expectEqualStrings("/var/lib/dkv", config.dir_path.?);
    try testing.expectEqual(.never, config.durability);
    try testing.expectEqual(3, config.address_count);
    try testing.expectEqualStrings("10.0.1.2:7000", config.peers()[1]);
    try testing.expectEqual(2, config.replica.?);
}

test "bad input is refused at startup" {
    try testing.expectError(error.UnknownFlag, parseSlice(&.{ "dkv", "--nope=1" }));
    try testing.expectError(error.BadPort, parseSlice(&.{ "dkv", "--port=99999" }));
    try testing.expectError(error.BadPort, parseSlice(&.{ "dkv", "--port=x" }));
    try testing.expectError(error.BadDurability, parseSlice(&.{ "dkv", "--durability=maybe" }));
    try testing.expectError(error.MissingValue, parseSlice(&.{ "dkv", "--dir=" }));
    try testing.expectError(error.BadAddress, parseSlice(&.{ "dkv", "--addresses=nonsense" }));
    try testing.expectError(error.BadAddress, parseSlice(&.{ "dkv", "--addresses=" }));
}

test "a replica index must name one of the addresses" {
    try testing.expectError(error.ReplicaOutOfRange, parseSlice(&.{
        "dkv",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000",
        "--replica=2",
    }));

    const config = try parseSlice(&.{
        "dkv",
        "--addresses=10.0.1.1:7000,10.0.1.2:7000",
        "--replica=1",
    });
    try testing.expectEqual(1, config.replica.?);
}
