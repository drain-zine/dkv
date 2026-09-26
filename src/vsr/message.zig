const std = @import("std");
const assert = std.debug.assert;

const checksum = @import("../checksum.zig");

pub const Header = extern struct {
    checksum: u128,
    checksum_body: u128,
    parent: u128,
    client: u128,
    cluster: u128,
    op: u64,
    commit: u64,
    size: u32,
    epoch: u32,
    view: u32,
    request: u32,
    replica: u8,
    command: u8,
    operation: u8,
    version: u8,
    reserved: [12]u8 = @splat(0),

    pub const prefix_size = @sizeOf(u128);

    pub const covered = @sizeOf(Header) - prefix_size;

    comptime {
        assert(@sizeOf(Header) == 128);
        assert(@alignOf(Header) == 16);
        assert(@offsetOf(Header, "checksum") == 0);

        var field_size_sum = 0;
        for (@typeInfo(Header).@"struct".fields) |field| field_size_sum += @sizeOf(field.type);
        assert(field_size_sum == @sizeOf(Header));
    }

    pub fn calculateChecksum(self: *const Header) u128 {
        return checksum.checksum(std.mem.asBytes(self)[prefix_size..]);
    }

    pub fn calculateChecksumBody(body: []const u8) u128 {
        return checksum.checksum(body);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a checksum covers the header's content, not its address" {
    var header: Header = std.mem.zeroes(Header);
    header.view = 7;

    const copy = header;
    try testing.expectEqual(header.calculateChecksum(), copy.calculateChecksum());
}

test "a checksum ignores the checksum field itself" {
    var header: Header = std.mem.zeroes(Header);
    header.op = 42;

    const expected = header.calculateChecksum();
    header.checksum = expected;

    try testing.expectEqual(expected, header.calculateChecksum());
}

test "every other bit of the header is covered" {
    var header: Header = std.mem.zeroes(Header);
    const expected = header.calculateChecksum();

    const bytes = std.mem.asBytes(&header);
    for (Header.prefix_size..bytes.len) |index| {
        for (0..8) |bit| {
            bytes[index] ^= @as(u8, 1) << @intCast(bit);
            try testing.expect(header.calculateChecksum() != expected);
            bytes[index] ^= @as(u8, 1) << @intCast(bit);
        }
    }
    try testing.expectEqual(expected, header.calculateChecksum());
}
