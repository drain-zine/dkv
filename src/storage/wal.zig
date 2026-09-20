const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crc32c = std.hash.crc.Crc32Iscsi;

const constants = @import("../constants.zig");
const descriptor = @import("../io/descriptor.zig");

// ---------------------------------------------------------------------------
// On-disk format
// ---------------------------------------------------------------------------

pub const Operation = enum(u8) { put = 1, remove = 2 };

pub const Header = extern struct {
    crc32c: u32,
    len: u32,
    seq: u64,
    op: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    key_len: u32,

    pub const prefix_size = @sizeOf(u32) * 2;

    pub const covered = @sizeOf(Header) - prefix_size;
};

comptime {
    assert(@sizeOf(Header) == 24);
}

// ---------------------------------------------------------------------------
// Recovered records
// ---------------------------------------------------------------------------

pub const Body = struct {
    seq: u64,
    op: Operation,
    key: []const u8,
    value: []const u8,
};

pub const Sink = struct {
    context: *anyopaque,
    apply_fn: *const fn (context: *anyopaque, body: Body) Error!void,

    pub const Error = error{OutOfMemory};

    pub fn from(comptime T: type, pointer: *T) Sink {
        comptime check(T);
        const erased = struct {
            fn apply(context: *anyopaque, body: Body) Error!void {
                const target: *T = @ptrCast(@alignCast(context));
                return target.apply(body);
            }
        };
        return .{ .context = pointer, .apply_fn = erased.apply };
    }

    pub fn apply(self: Sink, body: Body) Error!void {
        return self.apply_fn(self.context, body);
    }

    fn check(comptime T: type) void {
        const name = @typeName(T);
        if (!@hasDecl(T, "apply")) {
            @compileError(name ++ " cannot be a WAL sink: it has no `apply` method");
        }
        const Found = @TypeOf(T.apply);
        if (Found == fn (*T, Body) Error!void) return;

        if (@typeInfo(Found) != .@"fn") {
            @compileError(name ++ ".apply must be a method, found `" ++ @typeName(Found) ++ "`");
        }
        const params = @typeInfo(Found).@"fn".params;
        const self_ok = params.len == 2 and (params[0].type orelse void) == *T;
        const body_ok = params.len == 2 and (params[1].type orelse void) == Body;
        if (!self_ok or !body_ok) {
            @compileError(name ++ ".apply must take `(self: *" ++ name ++ ", body: wal.Body)`");
        }
        @compileError(name ++ ".apply must return `wal.Sink.Error!void`. " ++
            "Declare the error set explicitly rather than inferring it with `!void`.");
    }
};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub const Durability = enum {
    always,
    never,
};

pub const Options = struct {
    durability: Durability = .always,
    discard_existing: bool = false,
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

pub const Reader = struct {
    file_reader: Io.File.Reader,
    body: std.ArrayList(u8),
    gpa: Allocator,
    valid_end: u64 = 0,
    last_seq: u64 = 0,

    pub fn init(file: Io.File, io: Io, buffer: []u8, gpa: Allocator) Reader {
        return .{
            .file_reader = file.reader(io, buffer),
            .body = .empty,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.body.deinit(self.gpa);
    }

    pub fn next(self: *Reader) !?Body {
        const stream = &self.file_reader.interface;

        const header: Header = (stream.takeStructPointer(Header) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        }).*;

        if (header.len < Header.covered) return null;
        const body_len = header.len - Header.covered;
        if (body_len > constants.wal_record_size_max) return null;
        if (header.key_len > body_len) return null;

        const body = (try self.readBody(body_len)) orelse return null;

        var hash = Crc32c.init();
        hash.update(std.mem.asBytes(&header)[Header.prefix_size..]);
        hash.update(body);
        if (hash.final() != header.crc32c) return null;

        const op = std.enums.fromInt(Operation, header.op) orelse return null;

        self.valid_end += @sizeOf(Header) + body_len;
        self.last_seq = header.seq;
        return .{
            .seq = header.seq,
            .op = op,
            .key = body[0..header.key_len],
            .value = body[header.key_len..],
        };
    }

    fn readBody(self: *Reader, body_len: u32) !?[]const u8 {
        const stream = &self.file_reader.interface;

        if (body_len <= stream.buffer.len) {
            return stream.take(body_len) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
        }

        try self.body.resize(self.gpa, body_len);
        stream.readSliceAll(self.body.items) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        return self.body.items;
    }
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

pub const Wal = struct {
    file: Io.File,
    io: Io,
    gpa: Allocator,
    buffer: []u8,
    writer: Io.File.Writer,
    durability: Durability,

    last_seq: u64 = 0,
    last_durable_seq: u64 = 0,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn open(
        gpa: Allocator,
        io: Io,
        dir: Io.Dir,
        path: []const u8,
        options: Options,
        sink: ?Sink,
    ) !Wal {
        const file = try dir.createFile(io, path, .{
            .read = true,
            .truncate = options.discard_existing,
        });
        errdefer file.close(io);
        if (options.discard_existing) try file.sync(io);

        const buffer = try gpa.alloc(u8, constants.wal_buffer_size);
        errdefer gpa.free(buffer);

        var reader = Reader.init(file, io, buffer, gpa);
        defer reader.deinit();
        while (try reader.next()) |body| {
            if (sink) |target| try target.apply(body);
        }

        const size = (try file.stat(io)).size;
        if (size != reader.valid_end) try file.setLength(io, reader.valid_end);

        var wal: Wal = .{
            .file = file,
            .io = io,
            .gpa = gpa,
            .buffer = buffer,
            .writer = file.writer(io, buffer),
            .durability = options.durability,
            .last_seq = reader.last_seq,
            .last_durable_seq = reader.last_seq,
        };
        try wal.writer.seekTo(reader.valid_end);
        return wal;
    }

    pub fn close(self: *Wal) void {
        self.sync() catch {};
        self.file.close(self.io);
        self.gpa.free(self.buffer);
    }

    // -----------------------------------------------------------------------
    // Appending
    // -----------------------------------------------------------------------

    pub fn append(self: *Wal, op: Operation, key: []const u8, value: []const u8) !u64 {
        assert(Header.covered + key.len + value.len <= constants.wal_record_size_max);

        const seq = self.last_seq + 1;

        var header: Header = .{
            .crc32c = 0,
            .len = @intCast(Header.covered + key.len + value.len),
            .seq = seq,
            .op = @intFromEnum(op),
            .key_len = @intCast(key.len),
        };

        var hash = Crc32c.init();
        hash.update(std.mem.asBytes(&header)[Header.prefix_size..]);
        hash.update(key);
        hash.update(value);
        header.crc32c = hash.final();

        const stream = &self.writer.interface;
        try stream.writeAll(std.mem.asBytes(&header));
        try stream.writeAll(key);
        try stream.writeAll(value);

        self.last_seq = seq;
        return seq;
    }

    // -----------------------------------------------------------------------
    // Durability
    // -----------------------------------------------------------------------

    pub fn needsSync(self: *const Wal) bool {
        assert(self.last_durable_seq <= self.last_seq);

        return self.durability == .always and self.last_seq > self.last_durable_seq;
    }

    pub fn sync(self: *Wal) !void {
        assert(self.last_durable_seq <= self.last_seq);

        try self.writer.flush();
        try descriptor.syncBarrier(self.file.handle);

        self.last_durable_seq = self.last_seq;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Collector = struct {
    entries: std.ArrayList(Body) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init(gpa: Allocator) Collector {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(self: *Collector) void {
        self.arena.deinit();
    }

    pub fn apply(self: *Collector, body: Body) Sink.Error!void {
        const arena = self.arena.allocator();
        try self.entries.append(arena, .{
            .seq = body.seq,
            .op = body.op,
            .key = try arena.dupe(u8, body.key),
            .value = try arena.dupe(u8, body.value),
        });
    }
};

test "append then replay" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var wal = try Wal.open(testing.allocator, io, tmp.dir, "test.wal", .{}, null);
        defer wal.close();
        try testing.expectEqual(1, try wal.append(.put, "a", "1"));
        try testing.expectEqual(2, try wal.append(.put, "bb", "two words"));
        try testing.expectEqual(3, try wal.append(.remove, "a", ""));
    }

    var collector = Collector.init(testing.allocator);
    defer collector.deinit();
    var wal = try Wal.open(
        testing.allocator,
        io,
        tmp.dir,
        "test.wal",
        .{},
        .from(Collector, &collector),
    );
    defer wal.close();

    try testing.expectEqual(3, wal.last_seq);
    const entries = collector.entries.items;
    try testing.expectEqual(3, entries.len);
    try testing.expectEqual(.put, entries[0].op);
    try testing.expectEqualStrings("a", entries[0].key);
    try testing.expectEqualStrings("1", entries[0].value);
    try testing.expectEqualStrings("two words", entries[1].value);
    try testing.expectEqual(.remove, entries[2].op);
    try testing.expectEqual(3, entries[2].seq);
}

test "torn tail is dropped and truncated" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var good_size: u64 = 0;
    {
        var wal = try Wal.open(testing.allocator, io, tmp.dir, "test.wal", .{}, null);
        defer wal.close();
        _ = try wal.append(.put, "a", "1");
        _ = try wal.append(.put, "b", "2");
        try wal.sync();
        good_size = (try wal.file.stat(io)).size;

        const stream = &wal.writer.interface;
        const header_torn: Header = .{
            .crc32c = 0,
            .len = Header.covered + 100,
            .seq = 3,
            .op = 1,
            .key_len = 1,
        };
        try stream.writeAll(std.mem.asBytes(&header_torn));
        try stream.writeAll("garbage");
    }

    var collector = Collector.init(testing.allocator);
    defer collector.deinit();
    var wal = try Wal.open(
        testing.allocator,
        io,
        tmp.dir,
        "test.wal",
        .{},
        .from(Collector, &collector),
    );
    defer wal.close();

    try testing.expectEqual(2, collector.entries.items.len);
    try testing.expectEqual(2, wal.last_seq);
    try testing.expectEqual(good_size, (try wal.file.stat(io)).size);

    try testing.expectEqual(3, try wal.append(.put, "c", "3"));
}

test "corrupted byte in the middle stops replay there" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var wal = try Wal.open(testing.allocator, io, tmp.dir, "test.wal", .{}, null);
        defer wal.close();
        _ = try wal.append(.put, "a", "1");
        _ = try wal.append(.put, "b", "2");
        _ = try wal.append(.put, "c", "3");
    }

    {
        const file = try tmp.dir.openFile(io, "test.wal", .{ .mode = .read_write });
        defer file.close(io);
        const offset = 2 * @sizeOf(Header) + 1 + 1;
        try file.writePositionalAll(io, "X", offset);
    }

    var collector = Collector.init(testing.allocator);
    defer collector.deinit();
    var wal = try Wal.open(
        testing.allocator,
        io,
        tmp.dir,
        "test.wal",
        .{},
        .from(Collector, &collector),
    );
    defer wal.close();

    try testing.expectEqual(1, collector.entries.items.len);
    try testing.expectEqual(1, wal.last_seq);
}

test "always defers the barrier, and one sync covers every append before it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var wal = try Wal.open(testing.allocator, io, tmp.dir, "test.wal", .{}, null);
    defer wal.close();

    try testing.expect(!wal.needsSync());

    _ = try wal.append(.put, "a", "1");
    _ = try wal.append(.put, "b", "2");

    try testing.expectEqual(2, wal.last_seq);
    try testing.expectEqual(0, wal.last_durable_seq);
    try testing.expect(wal.needsSync());

    try wal.sync();

    try testing.expectEqual(2, wal.last_durable_seq);
    try testing.expect(!wal.needsSync());
}
