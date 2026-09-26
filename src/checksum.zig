const std = @import("std");
const Aegis = std.crypto.auth.aegis.Aegis128LMac_128;

const key = [_]u8{0x00} ** Aegis.key_length;

pub fn checksum(bytes: []const u8) u128 {
    var stream = Stream.init();
    stream.update(bytes);
    return stream.final();
}

pub const Stream = struct {
    aegis: Aegis,

    pub fn init() Stream {
        return .{ .aegis = Aegis.init(&key) };
    }

    pub fn update(self: *Stream, bytes: []const u8) void {
        self.aegis.update(bytes);
    }

    pub fn final(self: *Stream) u128 {
        var tag: [Aegis.mac_length]u8 = undefined;
        self.aegis.final(&tag);
        return @bitCast(tag);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "known answers" {
    try testing.expectEqual(0x635037dbb2b81e9bf114d2092a5aa1ad, checksum(""));
    try testing.expectEqual(0x08c4f98fda45b58b781cea77185cba37, checksum("dkv"));
    try testing.expectEqual(0xf44c3e69255e55715ca7742eb6fa0d2e, checksum("a" ** 1024));
}

test "a stream matches one call over the joined bytes" {
    var stream = Stream.init();
    stream.update("dk");
    stream.update("v");

    try testing.expectEqual(checksum("dkv"), stream.final());
}

test "a single flipped bit changes the checksum" {
    var bytes = [_]u8{0} ** 64;
    const expected = checksum(&bytes);

    for (0..bytes.len * 8) |bit| {
        bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        try testing.expect(checksum(&bytes) != expected);
        bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
    }
    try testing.expectEqual(expected, checksum(&bytes));
}
