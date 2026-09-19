const std = @import("std");
const assert = std.debug.assert;

/// Fixed-capacity FIFO. Storage lives inside the struct, so nothing is
/// allocated and elements never move. `capacity` must be a power of two, which
/// makes wrapping a mask rather than a division.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime assert(capacity > 0);
    comptime assert(capacity & (capacity - 1) == 0);

    return struct {
        entries: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,

        const Self = @This();
        const index_mask = capacity - 1;

        pub const capacity_max = capacity;

        pub fn push(self: *Self, entry: T) void {
            assert(self.count < capacity);

            self.entries[(self.head + self.count) & index_mask] = entry;
            self.count += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;

            const entry = self.entries[self.head];
            self.head = (self.head + 1) & index_mask;
            self.count -= 1;

            return entry;
        }

        /// Moves every entry into `out`, oldest first, leaving the ring empty.
        /// Entries pushed after this call land behind them.
        pub fn drain(self: *Self, out: []T) []T {
            const count = self.count;
            assert(out.len >= count);

            for (0..count) |index| out[index] = self.pop().?;
            assert(self.count == 0);

            return out[0..count];
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "pushes come back in order" {
    var ring: RingBuffer(u32, 4) = .{};

    ring.push(1);
    ring.push(2);
    ring.push(3);

    try testing.expectEqual(@as(usize, 3), ring.count);
    try testing.expectEqual(@as(u32, 1), ring.pop().?);
    try testing.expectEqual(@as(u32, 2), ring.pop().?);
    try testing.expectEqual(@as(u32, 3), ring.pop().?);
    try testing.expectEqual(@as(?u32, null), ring.pop());
}

test "indexes wrap far past the capacity" {
    var ring: RingBuffer(u32, 4) = .{};

    var round: u32 = 0;
    while (round < 4 * 100) : (round += 1) {
        ring.push(round);
        try testing.expectEqual(round, ring.pop().?);
    }
    try testing.expectEqual(@as(usize, 0), ring.count);
}

test "a full ring still wraps correctly" {
    var ring: RingBuffer(u32, 4) = .{};

    for (0..4) |value| ring.push(@intCast(value));
    try testing.expectEqual(@as(usize, 4), ring.count);

    // Drop the two oldest, then refill the space they freed.
    try testing.expectEqual(@as(u32, 0), ring.pop().?);
    try testing.expectEqual(@as(u32, 1), ring.pop().?);
    ring.push(4);
    ring.push(5);

    try testing.expectEqual(@as(u32, 2), ring.pop().?);
    try testing.expectEqual(@as(u32, 3), ring.pop().?);
    try testing.expectEqual(@as(u32, 4), ring.pop().?);
    try testing.expectEqual(@as(u32, 5), ring.pop().?);
}

test "drain empties the ring, oldest first" {
    var ring: RingBuffer(u32, 8) = .{};

    for (0..5) |value| ring.push(@intCast(value));

    var out: [8]u32 = undefined;
    const drained = ring.drain(&out);

    try testing.expectEqual(@as(usize, 5), drained.len);
    for (drained, 0..) |value, index| try testing.expectEqual(@as(u32, @intCast(index)), value);
    try testing.expectEqual(@as(usize, 0), ring.count);
    try testing.expectEqual(@as(?u32, null), ring.pop());
}

test "holds pointers as well as values" {
    var values = [_]u32{ 10, 20 };
    var ring: RingBuffer(*u32, 2) = .{};

    ring.push(&values[0]);
    ring.push(&values[1]);

    try testing.expectEqual(&values[0], ring.pop().?);
    try testing.expectEqual(&values[1], ring.pop().?);
}
