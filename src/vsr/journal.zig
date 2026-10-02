const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const constants = @import("../constants.zig");
const descriptor = @import("../io/descriptor.zig");
const message = @import("message.zig");

const Header = message.Header;
const Message = message.Message;

pub const Durability = enum { always, buffered, off };

pub const Options = struct {
    cluster: u32,
    durability: Durability = .always,
    discard_existing: bool = false,
};

pub const Recovered = struct {
    op: u64,
    view: u32,
    checksum: u128,
};

pub const ReadError = error{Corrupt};

pub const Journal = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    buffer: []u8,
    read_buffer: []u8,
    writer: Io.File.Writer,
    durability: Durability,
    cluster: u32,

    op: u64,
    op_durable: u64,
    checksum: u128,
    view: u32,

    offsets: []u64,
    size: u64,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn open(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        options: Options,
    ) !Journal {
        assert(options.durability != .off);

        const file = try dir.createFile(io, path, .{
            .read = true,
            .truncate = options.discard_existing,
        });
        errdefer file.close(io);
        if (options.discard_existing) try file.sync(io);

        const buffer = try gpa.alloc(u8, constants.journal_buffer_size);
        errdefer gpa.free(buffer);

        const read_buffer = try gpa.alloc(u8, constants.journal_buffer_size);
        errdefer gpa.free(read_buffer);

        const offsets = try gpa.alloc(u64, constants.journal_op_count_max);
        errdefer gpa.free(offsets);

        var scanner: Scanner = .init(file, io, read_buffer, options.cluster, offsets);
        defer scanner.deinit(gpa);
        try scanner.scan(gpa);

        if ((try file.stat(io)).size != scanner.valid_end) {
            try file.setLength(io, scanner.valid_end);
        }

        var journal: Journal = .{
            .gpa = gpa,
            .io = io,
            .file = file,
            .buffer = buffer,
            .read_buffer = read_buffer,
            .writer = file.writer(io, buffer),
            .durability = options.durability,
            .cluster = options.cluster,
            .op = scanner.op,
            .op_durable = scanner.op,
            .checksum = scanner.checksum,
            .view = scanner.view,
            .offsets = offsets,
            .size = scanner.valid_end,
        };
        try journal.writer.seekTo(scanner.valid_end);
        return journal;
    }

    pub fn close(self: *Journal) void {
        self.sync() catch {};
        self.file.close(self.io);
        self.gpa.free(self.buffer);
        self.gpa.free(self.read_buffer);
        self.gpa.free(self.offsets);
    }

    pub fn recovered(self: *const Journal) Recovered {
        return .{ .op = self.op, .view = self.view, .checksum = self.checksum };
    }

    // -----------------------------------------------------------------------
    // Appending
    // -----------------------------------------------------------------------

    pub fn append(self: *Journal, header: *const Header, body: []const u8) !void {
        assert(header.size == @sizeOf(Header) + body.len);
        assert(header.checksum == header.calculateChecksum());
        assert(header.cluster == self.cluster);
        assert(header.op == self.op + 1);
        assert(header.parent == self.checksum);
        assert(header.view >= self.view);

        if (header.op - 1 >= self.offsets.len) return error.JournalFull;

        const stream = &self.writer.interface;
        try stream.writeAll(std.mem.asBytes(header));
        try stream.writeAll(body);

        self.offsets[header.op - 1] = self.size;
        self.size += header.size;
        self.op = header.op;
        self.checksum = header.checksum;
        self.view = header.view;
    }

    // -----------------------------------------------------------------------
    // Durability
    // -----------------------------------------------------------------------

    pub fn needsSync(self: *const Journal) bool {
        assert(self.op_durable <= self.op);

        return self.durability == .always and self.op > self.op_durable;
    }

    pub fn sync(self: *Journal) !void {
        assert(self.op_durable <= self.op);

        try self.writer.flush();
        try descriptor.syncBarrier(self.file.handle);

        self.op_durable = self.op;
    }

    // -----------------------------------------------------------------------
    // Reading
    // -----------------------------------------------------------------------

    pub fn read(self: *Journal, op: u64, buffer: []align(@alignOf(Header)) u8) !Message {
        assert(op >= 1);
        assert(op <= self.op);
        assert(buffer.len >= constants.cluster_message_size_max);

        try self.writer.flush();

        var file_reader = self.file.reader(self.io, self.read_buffer);
        try file_reader.seekTo(self.offsets[op - 1]);
        const stream = &file_reader.interface;

        try stream.readSliceAll(buffer[0..@sizeOf(Header)]);

        const found: Message = .{ .buffer = buffer };
        const header = found.header();
        if (header.valid(self.cluster) != null) return error.Corrupt;
        if (header.op != op) return error.Corrupt;

        try stream.readSliceAll(buffer[@sizeOf(Header)..header.size]);

        if (found.valid(self.cluster) != null) return error.Corrupt;

        return .{ .buffer = buffer[0..header.size] };
    }

    // -----------------------------------------------------------------------
    // Truncating
    // -----------------------------------------------------------------------

    pub fn truncate(self: *Journal, op: u64) !void {
        assert(op <= self.op);

        if (op == self.op) return;

        const end = if (op == 0) 0 else self.offsets[op];

        try self.writer.flush();
        try self.file.setLength(self.io, end);
        try self.writer.seekTo(end);

        self.size = end;
        self.op = op;
        self.op_durable = @min(self.op_durable, op);
        self.checksum = if (op == 0) 0 else (try self.headerAt(self.offsets[op - 1])).checksum;
    }

    fn headerAt(self: *Journal, offset: u64) !Header {
        var file_reader = self.file.reader(self.io, self.read_buffer);
        try file_reader.seekTo(offset);

        var header: Header = undefined;
        try file_reader.interface.readSliceAll(std.mem.asBytes(&header));
        if (header.valid(self.cluster) != null) return error.Corrupt;

        return header;
    }
};

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

const Scanner = struct {
    file_reader: Io.File.Reader,
    cluster: u32,
    offsets: []u64,
    body: std.ArrayList(u8),

    valid_end: u64 = 0,
    op: u64 = 0,
    checksum: u128 = 0,
    view: u32 = 0,

    fn init(file: Io.File, io: Io, buffer: []u8, cluster: u32, offsets: []u64) Scanner {
        return .{
            .file_reader = file.reader(io, buffer),
            .cluster = cluster,
            .offsets = offsets,
            .body = .empty,
        };
    }

    fn deinit(self: *Scanner, gpa: Allocator) void {
        self.body.deinit(gpa);
    }

    fn scan(self: *Scanner, gpa: Allocator) !void {
        const stream = &self.file_reader.interface;

        while (true) {
            var header: Header = undefined;
            stream.readSliceAll(std.mem.asBytes(&header)) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };

            if (header.valid(self.cluster) != null) return;
            if (header.op != self.op + 1) return;
            if (header.parent != self.checksum) return;
            if (header.view < self.view) return;
            if (header.op - 1 >= self.offsets.len) return;

            const body_size = header.size - @sizeOf(Header);
            const body = (try self.readBody(gpa, body_size)) orelse return;

            if (header.checksum_body != Header.calculateChecksumBody(body)) return;

            self.offsets[header.op - 1] = self.valid_end;
            self.valid_end += header.size;
            self.op = header.op;
            self.checksum = header.checksum;
            self.view = header.view;
        }
    }

    fn readBody(self: *Scanner, gpa: Allocator, body_size: u32) !?[]u8 {
        const stream = &self.file_reader.interface;

        if (body_size <= stream.buffer.len) {
            return stream.take(body_size) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
        }

        try self.body.resize(gpa, body_size);
        stream.readSliceAll(self.body.items) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        return self.body.items;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const cluster_test: u32 = 7;
const body_a = "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n";
const body_b = "*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1\r\n2\r\n";
const body_c = "*2\r\n$3\r\nDEL\r\n$1\r\na\r\n";

fn prepared(op: u64, parent: u128, view: u32, body: []const u8) Header {
    var header: Header = std.mem.zeroes(Header);
    header.command = @intFromEnum(message.Command.prepare);
    header.cluster = cluster_test;
    header.op = op;
    header.commit = op - 1;
    header.parent = parent;
    header.view = view;
    header.size = @sizeOf(Header) + @as(u32, @intCast(body.len));
    header.setChecksums(body);
    return header;
}

fn appendPrepare(log: *Journal, body: []const u8) !Header {
    const header = prepared(log.op + 1, log.checksum, log.view, body);
    try log.append(&header, body);
    return header;
}

const options_test: Options = .{ .cluster = cluster_test };

test "appends survive a reopen, and read returns what was appended" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var last: Header = undefined;
    {
        var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
        defer log.close();

        _ = try appendPrepare(&log, body_a);
        _ = try appendPrepare(&log, body_b);
        last = try appendPrepare(&log, body_c);
        try log.sync();
    }

    var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
    defer log.close();

    try testing.expectEqual(3, log.recovered().op);
    try testing.expectEqual(last.checksum, log.recovered().checksum);

    const big = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(@alignOf(Header)),
        constants.cluster_message_size_max,
    );
    defer testing.allocator.free(big);

    const first = try log.read(1, big);
    try testing.expectEqualStrings(body_a, first.body());
    try testing.expectEqual(1, first.header().op);

    const third = try log.read(3, big);
    try testing.expectEqualStrings(body_c, third.body());
    try testing.expectEqual(last.checksum, third.header().checksum);
}

test "a torn tail is dropped and the file truncated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var good_size: u64 = 0;
    {
        var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
        defer log.close();

        _ = try appendPrepare(&log, body_a);
        _ = try appendPrepare(&log, body_b);
        try log.sync();
        good_size = (try log.file.stat(testing.io)).size;

        try log.writer.interface.writeAll("garbage that is not a header");
        try log.writer.flush();
    }

    var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
    defer log.close();

    try testing.expectEqual(2, log.recovered().op);
    try testing.expectEqual(good_size, (try log.file.stat(testing.io)).size);
}

test "a broken parent chain stops replay even when each record is valid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
        defer log.close();

        _ = try appendPrepare(&log, body_a);

        const forked = prepared(2, 0xdeadbeef, 0, body_b);
        try log.writer.interface.writeAll(std.mem.asBytes(&forked));
        try log.writer.interface.writeAll(body_b);
        try log.writer.flush();
    }

    var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
    defer log.close();

    try testing.expectEqual(1, log.recovered().op);
}

test "truncate keeps the op, drops what follows, and the next append chains" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var second: Header = undefined;
    {
        var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
        defer log.close();

        _ = try appendPrepare(&log, body_a);
        second = try appendPrepare(&log, body_b);
        _ = try appendPrepare(&log, body_c);
        try log.sync();

        try log.truncate(2);
        try testing.expectEqual(2, log.op);
        try testing.expectEqual(second.checksum, log.checksum);

        _ = try appendPrepare(&log, body_c);
        try log.sync();
    }

    var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
    defer log.close();

    try testing.expectEqual(3, log.recovered().op);

    const big = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(@alignOf(Header)),
        constants.cluster_message_size_max,
    );
    defer testing.allocator.free(big);
    const third = try log.read(3, big);
    try testing.expectEqualStrings(body_c, third.body());
    try testing.expectEqual(second.checksum, third.header().parent);
}

test "always defers the barrier, and one sync covers every append before it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", options_test);
    defer log.close();

    try testing.expect(!log.needsSync());

    _ = try appendPrepare(&log, body_a);
    _ = try appendPrepare(&log, body_b);
    try testing.expect(log.needsSync());
    try testing.expectEqual(0, log.op_durable);

    try log.sync();
    try testing.expectEqual(2, log.op_durable);
    try testing.expect(!log.needsSync());
}

test "buffered never asks for a barrier" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var log = try Journal.open(testing.allocator, testing.io, tmp.dir, "test.journal", .{
        .cluster = cluster_test,
        .durability = .buffered,
    });
    defer log.close();

    _ = try appendPrepare(&log, body_a);
    try testing.expect(!log.needsSync());
}
