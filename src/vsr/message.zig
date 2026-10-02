const std = @import("std");
const assert = std.debug.assert;

const checksum = @import("../checksum.zig");
const constants = @import("../constants.zig");

pub const Command = enum(u8) {
    reserved = 0,
    request = 1,
    prepare = 2,
    prepare_ok = 3,
    commit = 4,
    reply = 5,
};

pub const Header = extern struct {
    checksum: u128,
    checksum_body: u128,
    parent: u128,
    op: u64,
    commit: u64,
    size: u32,
    view: u32,
    cluster: u32,
    replica: u8,
    command: u8,
    reserved: [18]u8 = @splat(0),

    pub const prefix_size = @sizeOf(u128);

    pub const covered = @sizeOf(Header) - prefix_size;

    comptime {
        assert(@sizeOf(Header) == constants.cluster_message_header_size);
        assert(@alignOf(Header) == 16);
        assert(@offsetOf(Header, "checksum") == 0);

        var field_size_sum = 0;
        for (@typeInfo(Header).@"struct".fields) |field| field_size_sum += @sizeOf(field.type);
        assert(field_size_sum == @sizeOf(Header));
    }

    pub const ValidationError = error{
        InvalidChecksum,
        InvalidBodyChecksum,
        InvalidCommand,
        InvalidCluster,
        InvalidReplica,
        InvalidSize,
        InvalidReserved,
        InvalidView,
        InvalidOp,
        InvalidCommit,
        InvalidParent,
        InvalidBodySize,
    };

    pub fn calculateChecksum(self: *const Header) u128 {
        return checksum.checksum(std.mem.asBytes(self)[prefix_size..]);
    }

    pub fn calculateChecksumBody(body: []const u8) u128 {
        return checksum.checksum(body);
    }

    pub fn setChecksums(self: *Header, body: []const u8) void {
        assert(self.command != @intFromEnum(Command.reserved));
        assert(self.size == @sizeOf(Header) + body.len);

        self.checksum_body = calculateChecksumBody(body);
        self.checksum = self.calculateChecksum();
    }

    pub fn valid(self: *const Header, cluster: u32) ?ValidationError {
        if (self.checksum != self.calculateChecksum()) return ValidationError.InvalidChecksum;
        if (self.cluster != cluster) return ValidationError.InvalidCluster;
        if (self.replica >= constants.cluster_replica_count_max) return ValidationError.InvalidReplica;
        if (self.size < @sizeOf(Header)) return ValidationError.InvalidSize;
        if (self.size > constants.cluster_message_size_max) return ValidationError.InvalidSize;
        for (self.reserved) |byte| {
            if (byte != 0) return ValidationError.InvalidReserved;
        }

        const command = std.enums.fromInt(Command, self.command) orelse {
            return ValidationError.InvalidCommand;
        };

        return switch (command) {
            .reserved => ValidationError.InvalidCommand,
            .request => validateRequest(self),
            .prepare => validatePrepare(self),
            .prepare_ok => validatePrepareOk(self),
            .commit => validateCommit(self),
            .reply => validateReply(self),
        };
    }

    fn bodySize(self: *const Header) u32 {
        assert(self.size >= @sizeOf(Header));

        return self.size - @sizeOf(Header);
    }

    fn validateRequest(self: *const Header) ?ValidationError {
        if (self.view != 0) return ValidationError.InvalidView;
        if (self.op != 0) return ValidationError.InvalidOp;
        if (self.commit != 0) return ValidationError.InvalidCommit;
        if (self.parent != 0) return ValidationError.InvalidParent;
        if (self.replica != 0) return ValidationError.InvalidReplica;
        if (self.bodySize() == 0) return ValidationError.InvalidBodySize;
        return null;
    }

    fn validatePrepare(self: *const Header) ?ValidationError {
        if (self.op == 0) return ValidationError.InvalidOp;
        if (self.commit >= self.op) return ValidationError.InvalidCommit;
        if (self.op > 1 and self.parent == 0) return ValidationError.InvalidParent;
        if (self.bodySize() == 0) return ValidationError.InvalidBodySize;
        return null;
    }

    fn validatePrepareOk(self: *const Header) ?ValidationError {
        if (self.op == 0) return ValidationError.InvalidOp;
        if (self.parent != 0) return ValidationError.InvalidParent;
        if (self.bodySize() != 0) return ValidationError.InvalidBodySize;
        return null;
    }

    fn validateCommit(self: *const Header) ?ValidationError {
        if (self.commit > self.op) return ValidationError.InvalidCommit;
        if (self.parent != 0) return ValidationError.InvalidParent;
        if (self.bodySize() != 0) return ValidationError.InvalidBodySize;
        return null;
    }

    fn validateReply(self: *const Header) ?ValidationError {
        if (self.op == 0) return ValidationError.InvalidOp;
        if (self.parent != 0) return ValidationError.InvalidParent;
        if (self.bodySize() == 0) return ValidationError.InvalidBodySize;
        return null;
    }
};

pub const Message = struct {
    buffer: []align(@alignOf(Header)) u8,

    pub fn header(self: Message) *Header {
        assert(self.buffer.len >= @sizeOf(Header));

        return @ptrCast(self.buffer.ptr);
    }

    pub fn body(self: Message) []u8 {
        const size = self.header().size;
        assert(size >= @sizeOf(Header));
        assert(size <= self.buffer.len);

        return self.buffer[@sizeOf(Header)..size];
    }

    pub fn setChecksums(self: Message) void {
        self.header().setChecksums(self.body());
    }

    pub fn valid(self: Message, cluster: u32) ?Header.ValidationError {
        const message_header = self.header();
        if (message_header.valid(cluster)) |invalid_header| return invalid_header;

        if (message_header.size > self.buffer.len) return Header.ValidationError.InvalidSize;

        if (message_header.checksum_body != Header.calculateChecksumBody(self.body())) {
            return Header.ValidationError.InvalidBodyChecksum;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectInvalid(expected: Header.ValidationError, actual: ?Header.ValidationError) !void {
    try testing.expect(actual != null);
    try testing.expectEqual(expected, actual.?);
}

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

test "set checksums covers the body, and the body checksum is covered in turn" {
    const body = "*1\r\n$4\r\nPING\r\n";

    var header: Header = std.mem.zeroes(Header);
    header.command = @intFromEnum(Command.prepare);
    header.op = 1;
    header.size = @sizeOf(Header) + body.len;
    header.setChecksums(body);

    try testing.expectEqual(Header.calculateChecksumBody(body), header.checksum_body);
    try testing.expectEqual(header.calculateChecksum(), header.checksum);

    var tampered = header;
    tampered.checksum_body = 0;
    try testing.expect(tampered.calculateChecksum() != tampered.checksum);
}

test "a header-only message carries the checksum of an empty body" {
    var header: Header = std.mem.zeroes(Header);
    header.command = @intFromEnum(Command.commit);
    header.size = @sizeOf(Header);
    header.setChecksums("");

    try testing.expectEqual(Header.calculateChecksumBody(""), header.checksum_body);
    try testing.expect(header.checksum_body != 0);
}

fn preparedHeader(body: []const u8) Header {
    var header: Header = std.mem.zeroes(Header);
    header.command = @intFromEnum(Command.prepare);
    header.op = 1;
    header.size = @sizeOf(Header) + @as(u32, @intCast(body.len));
    header.setChecksums(body);
    return header;
}

fn messaged(buffer: []align(@alignOf(Header)) u8, body: []const u8) Message {
    const message: Message = .{ .buffer = buffer[0 .. @sizeOf(Header) + body.len] };
    message.header().* = preparedHeader(body);
    @memcpy(message.buffer[@sizeOf(Header)..], body);
    message.setChecksums();
    return message;
}

fn seal(header: *Header) void {
    header.checksum = header.calculateChecksum();
}

const cluster_test: u32 = 0;

const body_test = "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n";

test "a well-formed prepare is valid" {
    var buffer: [256]u8 align(@alignOf(Header)) = undefined;
    const message = messaged(&buffer, body_test);

    try testing.expectEqual(null, message.header().valid(cluster_test));
    try testing.expectEqual(null, message.valid(cluster_test));
}

test "a corrupt header is caught before any other rule" {
    var header = preparedHeader(body_test);
    header.op = 0;
    header.command = @intFromEnum(Command.reserved);

    try expectInvalid(Header.ValidationError.InvalidChecksum, header.valid(cluster_test));
}

test "a corrupt body is caught by the body checksum alone" {
    var buffer: [256]u8 align(@alignOf(Header)) = undefined;
    const message = messaged(&buffer, body_test);

    try testing.expectEqual(null, message.valid(cluster_test));

    message.body()[0] ^= 1;
    try expectInvalid(Header.ValidationError.InvalidBodyChecksum, message.valid(cluster_test));

    message.body()[0] ^= 1;
    message.header().checksum_body = 0;
    seal(message.header());
    try expectInvalid(Header.ValidationError.InvalidBodyChecksum, message.valid(cluster_test));
}

test "the reserved command and unknown commands are refused" {
    var header = preparedHeader(body_test);
    header.command = @intFromEnum(Command.reserved);
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidCommand, header.valid(cluster_test));

    header.command = 200;
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidCommand, header.valid(cluster_test));
}

test "a nonzero reserved tail is refused" {
    var header = preparedHeader(body_test);
    header.reserved[17] = 1;
    seal(&header);

    try expectInvalid(Header.ValidationError.InvalidReserved, header.valid(cluster_test));
}

test "size must span the header and stay within the maximum" {
    var header = preparedHeader(body_test);
    header.size = @sizeOf(Header) - 1;
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidSize, header.valid(cluster_test));

    header.size = std.math.maxInt(u32);
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidSize, header.valid(cluster_test));
}

test "a replica index beyond the cluster is refused" {
    var header = preparedHeader(body_test);
    header.replica = 255;
    seal(&header);

    try expectInvalid(Header.ValidationError.InvalidReplica, header.valid(cluster_test));
}

test "a prepare needs an op, a parent once past the first, and a body" {
    var header = preparedHeader(body_test);
    header.op = 0;
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidOp, header.valid(cluster_test));

    header = preparedHeader(body_test);
    header.op = 2;
    header.parent = 0;
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidParent, header.valid(cluster_test));

    header = preparedHeader(body_test);
    header.parent = 0xabc;
    header.op = 2;
    header.commit = 2;
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidCommit, header.valid(cluster_test));

    header = preparedHeader("");
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidBodySize, header.valid(cluster_test));
}

test "header-only commands carry no body and no parent" {
    var header = preparedHeader(body_test);
    header.command = @intFromEnum(Command.prepare_ok);
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidBodySize, header.valid(cluster_test));

    header = std.mem.zeroes(Header);
    header.command = @intFromEnum(Command.commit);
    header.size = @sizeOf(Header);
    header.parent = 1;
    header.setChecksums("");
    try expectInvalid(Header.ValidationError.InvalidParent, header.valid(cluster_test));
}

test "a request carries no replication state" {
    var header = std.mem.zeroes(Header);
    header.command = @intFromEnum(Command.request);
    header.size = @sizeOf(Header) + body_test.len;
    header.setChecksums(body_test);
    try testing.expectEqual(null, header.valid(cluster_test));

    header.view = 3;
    seal(&header);
    try expectInvalid(Header.ValidationError.InvalidView, header.valid(cluster_test));
}
