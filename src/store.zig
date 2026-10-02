const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Store = struct {
    gpa: Allocator,
    map: Map,

    const Map = std.StringHashMapUnmanaged([]const u8);

    pub fn init(gpa: Allocator) !Store {
        var map: Map = .empty;
        errdefer deinitMap(gpa, &map);

        return .{
            .gpa = gpa,
            .map = map,
        };
    }

    pub fn deinit(self: *Store) void {
        deinitMap(self.gpa, &self.map);
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn put(self: *Store, key: []const u8, value: []const u8) void {
        const owned_value = self.gpa.dupe(u8, value) catch @panic("store: out of memory");

        const gop = self.map.getOrPut(self.gpa, key) catch @panic("store: out of memory");

        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch @panic("store: out of memory");
        }

        gop.value_ptr.* = owned_value;
    }

    pub fn remove(self: *Store, key: []const u8) bool {
        const kv = self.map.fetchRemove(key) orelse return false;
        self.gpa.free(kv.key);
        self.gpa.free(kv.value);
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
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "put, get and remove" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();

    try testing.expectEqual(0, store.count());
    try testing.expectEqual(null, store.get("a"));
    try testing.expect(!store.remove("a"));

    store.put("a", "1");
    store.put("b", "2");

    try testing.expectEqualStrings("1", store.get("a").?);
    try testing.expectEqual(2, store.count());
    try testing.expect(store.remove("a"));
    try testing.expect(!store.remove("a"));
    try testing.expectEqual(1, store.count());
}

test "a put over an existing key replaces its value" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();

    store.put("a", "1");
    store.put("a", "one");

    try testing.expectEqualStrings("one", store.get("a").?);
    try testing.expectEqual(1, store.count());
}

test "keys and values are owned, not borrowed" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();

    var key = [_]u8{ 'k', 'e', 'y' };
    var value = [_]u8{ 'v', 'a', 'l' };
    store.put(&key, &value);

    key[0] = 'x';
    value[0] = 'x';

    try testing.expectEqualStrings("val", store.get("key").?);
    try testing.expectEqual(null, store.get("xey"));
}

test "values are binary safe" {
    var store = try Store.init(testing.allocator);
    defer store.deinit();

    store.put("bin", "a\r\nb\x00c");
    try testing.expectEqualStrings("a\r\nb\x00c", store.get("bin").?);
}
