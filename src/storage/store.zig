const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const wal = @import("wal.zig");

pub const Startup = enum {
    replay,
    discard,
};

pub const Options = struct {
    dir: Io.Dir,
    wal_path: []const u8 = "dkv.wal",
    wal: wal.Options = .{},
    startup: Startup = .replay,
};

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    map: Map,
    wal: wal.Wal,

    const Map = std.StringHashMapUnmanaged([]const u8);

    const Replayer = struct {
        gpa: Allocator,
        map: *Map,

        pub fn apply(self: *Replayer, body: wal.Body) wal.Sink.Error!void {
            switch (body.op) {
                .put => try applyPut(self.gpa, self.map, body.key, body.value),
                .remove => _ = applyRemove(self.gpa, self.map, body.key),
            }
        }
    };

    pub fn init(gpa: Allocator, io: Io, options: Options) !Store {
        var map: Map = .empty;
        errdefer deinitMap(gpa, &map);

        var replayer: Replayer = .{ .gpa = gpa, .map = &map };
        const sink: ?wal.Sink = switch (options.startup) {
            .replay => .from(Replayer, &replayer),
            .discard => null,
        };

        var wal_options = options.wal;
        wal_options.discard_existing = options.startup == .discard;
        const log = try wal.Wal.open(gpa, io, options.dir, options.wal_path, wal_options, sink);

        return .{ .gpa = gpa, .io = io, .map = map, .wal = log };
    }

    pub fn deinit(self: *Store) void {
        self.wal.close();
        deinitMap(self.gpa, &self.map);
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) void {
        _ = self.wal.append(.put, key, value) catch |err| fatal("put: log append", err);
        applyPut(self.gpa, &self.map, key, value) catch |err| fatal("put: apply", err);
    }

    pub fn remove(self: *Store, key: []const u8) bool {
        _ = self.wal.append(.remove, key, "") catch |err| fatal("remove: log append", err);
        return applyRemove(self.gpa, &self.map, key);
    }

    pub fn needsCommit(self: *const Store) bool {
        return self.wal.needsSync();
    }

    pub fn commit(self: *Store) void {
        self.wal.sync() catch |err| fatal("commit", err);
    }

    fn applyPut(gpa: Allocator, map: *Map, key: []const u8, value: []const u8) !void {
        const owned_value = try gpa.dupe(u8, value);
        errdefer gpa.free(owned_value);

        const gop = try map.getOrPut(gpa, key);
        if (gop.found_existing) {
            gpa.free(gop.value_ptr.*);
        } else {
            errdefer _ = map.remove(key);
            gop.key_ptr.* = try gpa.dupe(u8, key);
        }
        gop.value_ptr.* = owned_value;
    }

    fn applyRemove(gpa: Allocator, map: *Map, key: []const u8) bool {
        const kv = map.fetchRemove(key) orelse return false;
        gpa.free(kv.key);
        gpa.free(kv.value);
        return true;
    }

    fn deinitMap(gpa: Allocator, map: *Map) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        map.deinit(gpa);
    }

    fn fatal(operation: []const u8, err: anyerror) noreturn {
        std.debug.panic("store {s} failed: {s}", .{ operation, @errorName(err) });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "put, get, remove, and survive a restart" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const options: Options = .{ .dir = tmp.dir };

    {
        var store = try Store.init(testing.allocator, io, options);
        defer store.deinit();

        store.put("a", "1");
        store.put("b", "2");
        store.put("a", "one");
        try testing.expectEqualStrings("one", store.get("a").?);
        try testing.expect(store.remove("b"));
        try testing.expect(!store.remove("b"));
        try testing.expectEqual(1, store.count());
    }

    var store = try Store.init(testing.allocator, io, options);
    defer store.deinit();
    try testing.expectEqual(1, store.count());
    try testing.expectEqualStrings("one", store.get("a").?);
    try testing.expectEqual(null, store.get("b"));
}

test "discard startup erases the log instead of hiding it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var store = try Store.init(testing.allocator, io, .{ .dir = tmp.dir });
        defer store.deinit();
        store.put("a", "1");
        store.put("b", "2");
    }

    {
        var store = try Store.init(testing.allocator, io, .{ .dir = tmp.dir, .startup = .discard });
        defer store.deinit();
        try testing.expectEqual(0, store.count());
        store.put("c", "3");
    }

    var store = try Store.init(testing.allocator, io, .{ .dir = tmp.dir });
    defer store.deinit();
    try testing.expectEqual(1, store.count());
    try testing.expectEqual(null, store.get("a"));
    try testing.expectEqualStrings("3", store.get("c").?);
}
