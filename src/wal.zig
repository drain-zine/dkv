//! Write-ahead log.
//!
//! On-disk format: a sequence of records, each a fixed `Header` followed by
//! `key_len` bytes of key and the remaining bytes of value. The CRC covers
//! everything after the `len` field. Replay stops at the first record that is
//! short, has impossible lengths, or fails its CRC; that point is the torn
//! tail from a crash and gets truncated on the next `open`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crc32c = std.hash.crc.Crc32Iscsi;

const constants = @import("constants.zig");

pub const Operation = enum(u8) { PUT = 1, REMOVE = 2 };
pub const Durability = enum {
    /// Every append is flushed and synced before it returns.
    always,
    /// Appends are buffered; the log is synced at most once per second,
    /// checked lazily on the next append. Up to one second of acknowledged
    /// writes can be lost on crash.
    everysec,
    /// Never synced explicitly. Flushed only when the buffer fills or on close.
    never,
};
pub const Header = extern struct {
    crc32c: u32,
    /// Number of bytes after this field: the rest of the header plus the body.
    len: u32,
    seq: u64,
    /// `Operation` as a raw byte so a corrupt value can be rejected on read.
    op: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    key_len: u32,

    /// Bytes of the header that are covered by `len` and by the CRC.
    pub const covered = @sizeOf(Header) - 8;
};

comptime {
    std.debug.assert(@sizeOf(Header) == 24);
}

/// A decoded record. Slices point into a buffer owned by the `Reader` and are
/// only valid until its next call.
pub const Body = struct {
    seq: u64,
    op: Operation,
    key: []const u8,
    value: []const u8,
};

/// Receives every record recovered by `Wal.open`. Build one with `Sink.from`.
///
/// This is a type-erased interface in the style of `std.mem.Allocator`: a
/// context pointer plus a function pointer, so `open` takes a concrete type
/// and a sink can be absent at runtime.
pub const Sink = struct {
    context: *anyopaque,
    apply_fn: *const fn (context: *anyopaque, body: Body) Error!void,

    pub const Error = error{OutOfMemory};

    /// Wraps `pointer`, whose type must declare
    /// `pub fn apply(self: *T, body: Body) Sink.Error!void`.
    /// Anything else is rejected at compile time with a message naming `T`.
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

    /// Hands one record to the wrapped value. The `Body` slices are only
    /// valid for the duration of this call.
    pub fn apply(sink: Sink, body: Body) Error!void {
        return sink.apply_fn(sink.context, body);
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

pub const Options = struct {
    durability: Durability = .always,
    /// Truncate an existing log to empty on open instead of recovering it.
    discard_existing: bool = false,
};

/// Reads records sequentially from the start of a log file.
pub const Reader = struct {
    file_reader: Io.File.Reader,
    body: std.ArrayList(u8),
    gpa: Allocator,
    /// Offset just past the last good record.
    valid_end: u64 = 0,
    /// Sequence number of the last good record, 0 if none.
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

    /// Returns null at the end of valid data. Real IO failures are errors.
    pub fn next(self: *Reader) !?Body {
        const r = &self.file_reader.interface;

        const header: Header = (r.takeStructPointer(Header) catch |err| switch (err) {
            error.EndOfStream => return null, // short header: torn tail
            else => return err,
        }).*;

        if (header.len < Header.covered) return null;
        const body_len = header.len - Header.covered;
        if (body_len > constants.wal_record_size_max or header.key_len > body_len) return null;

        const body: []const u8 = if (body_len <= r.buffer.len) r.take(body_len) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        } else blk: {
            try self.body.resize(self.gpa, body_len);
            r.readSliceAll(self.body.items) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            break :blk self.body.items;
        };

        var hash = Crc32c.init();
        hash.update(std.mem.asBytes(&header)[8..]);
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
};

pub const Wal = struct {
    file: Io.File,
    io: Io,
    gpa: Allocator,
    buffer: []u8,
    writer: Io.File.Writer,
    next_seq: u64,
    durability: Durability,
    last_sync: Io.Timestamp,

    /// Opens or creates the log at `path` relative to `dir`, replays every
    /// valid record into `sink`, truncates any torn tail, and positions the
    /// writer to append.
    ///
    /// Pass `null` as `sink` to recover the log position without applying
    /// the records anywhere.
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
        // Make the truncation durable before anything new is acknowledged.
        if (options.discard_existing) try file.sync(io);

        const buffer = try gpa.alloc(u8, constants.wal_buffer_size);
        errdefer gpa.free(buffer);

        // Recovery pass. Reuse the write buffer for reading since the writer
        // has not started yet.
        var reader = Reader.init(file, io, buffer, gpa);
        defer reader.deinit();
        while (try reader.next()) |body| {
            if (sink) |target| try target.apply(body);
        }

        // Drop any torn tail so a plain sequential read never sees it.
        const size = (try file.stat(io)).size;
        if (size != reader.valid_end) try file.setLength(io, reader.valid_end);

        var self: Wal = .{
            .file = file,
            .io = io,
            .gpa = gpa,
            .buffer = buffer,
            .writer = file.writer(io, buffer),
            .next_seq = reader.last_seq + 1,
            .durability = options.durability,
            .last_sync = Io.Timestamp.now(io, .awake),
        };
        try self.writer.seekTo(reader.valid_end);
        return self;
    }

    pub fn close(self: *Wal) void {
        self.writer.flush() catch {};
        if (self.durability != .always) self.file.sync(self.io) catch {};
        self.file.close(self.io);
        self.gpa.free(self.buffer);
    }

    /// Writes one record and returns its sequence number. With `.always`
    /// durability the record is on disk when this returns. On error nothing
    /// should be applied to the in-memory state.
    pub fn append(self: *Wal, op: Operation, key: []const u8, value: []const u8) !u64 {
        const seq = self.next_seq;

        var header: Header = .{
            .crc32c = 0,
            .len = @intCast(Header.covered + key.len + value.len),
            .seq = seq,
            .op = @intFromEnum(op),
            .key_len = @intCast(key.len),
        };

        var hash = Crc32c.init();
        hash.update(std.mem.asBytes(&header)[8..]);
        hash.update(key);
        hash.update(value);
        header.crc32c = hash.final();

        const w = &self.writer.interface;
        try w.writeAll(std.mem.asBytes(&header));
        try w.writeAll(key);
        try w.writeAll(value);

        switch (self.durability) {
            .always => try self.sync(),
            .everysec => {
                const now = Io.Timestamp.now(self.io, .awake);
                if (self.last_sync.durationTo(now).nanoseconds >= std.time.ns_per_s) try self.sync();
            },
            .never => {},
        }

        self.next_seq += 1;
        return seq;
    }

    /// Pushes buffered records to the OS and asks the OS to push them to disk.
    pub fn sync(self: *Wal) !void {
        try self.writer.flush();
        try self.file.sync(self.io);
        self.last_sync = Io.Timestamp.now(self.io, .awake);
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
        const a = self.arena.allocator();
        try self.entries.append(a, .{
            .seq = body.seq,
            .op = body.op,
            .key = try a.dupe(u8, body.key),
            .value = try a.dupe(u8, body.value),
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
        try testing.expectEqual(1, try wal.append(.PUT, "a", "1"));
        try testing.expectEqual(2, try wal.append(.PUT, "bb", "two words"));
        try testing.expectEqual(3, try wal.append(.REMOVE, "a", ""));
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

    try testing.expectEqual(4, wal.next_seq);
    const e = collector.entries.items;
    try testing.expectEqual(3, e.len);
    try testing.expectEqual(.PUT, e[0].op);
    try testing.expectEqualStrings("a", e[0].key);
    try testing.expectEqualStrings("1", e[0].value);
    try testing.expectEqualStrings("two words", e[1].value);
    try testing.expectEqual(.REMOVE, e[2].op);
    try testing.expectEqual(3, e[2].seq);
}

test "torn tail is dropped and truncated" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var good_size: u64 = 0;
    {
        var wal = try Wal.open(testing.allocator, io, tmp.dir, "test.wal", .{}, null);
        defer wal.close();
        _ = try wal.append(.PUT, "a", "1");
        _ = try wal.append(.PUT, "b", "2");
        try wal.sync();
        good_size = (try wal.file.stat(io)).size;

        // Simulate a crash mid-write: a header with a plausible length but
        // no body behind it, then some garbage.
        const w = &wal.writer.interface;
        const half: Header = .{ .crc32c = 0, .len = Header.covered + 100, .seq = 3, .op = 1, .key_len = 1 };
        try w.writeAll(std.mem.asBytes(&half));
        try w.writeAll("garbage");
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
    try testing.expectEqual(3, wal.next_seq);
    try testing.expectEqual(good_size, (try wal.file.stat(io)).size);

    // Appending after recovery lands right after the last good record.
    try testing.expectEqual(3, try wal.append(.PUT, "c", "3"));
}

test "corrupted byte in the middle stops replay there" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var wal = try Wal.open(testing.allocator, io, tmp.dir, "test.wal", .{}, null);
        defer wal.close();
        _ = try wal.append(.PUT, "a", "1");
        _ = try wal.append(.PUT, "b", "2");
        _ = try wal.append(.PUT, "c", "3");
    }

    // Flip a byte inside the second record's value.
    {
        const file = try tmp.dir.openFile(io, "test.wal", .{ .mode = .read_write });
        defer file.close(io);
        const offset = 2 * @sizeOf(Header) + 1 + 1; // second record's value byte
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
    try testing.expectEqual(2, wal.next_seq);
}
