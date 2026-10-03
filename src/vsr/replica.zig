const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const constants = @import("../constants.zig");
const journal = @import("journal.zig");
const message = @import("message.zig");
const Pipeline = @import("../protocol/pipeline.zig").Pipeline;
const Store = @import("../store.zig").Store;

const Header = message.Header;
const Journal = journal.Journal;

const log = std.log.scoped(.replica);

pub const Options = struct {
    cluster: u32 = 0,
    replica: u8 = 0,
    dir: Io.Dir,
    path: []const u8 = "dkv.journal",
    durability: journal.Durability = .always,
    discard_existing: bool = false,
};

pub const Replica = struct {
    gpa: Allocator,
    io: Io,

    cluster: u32,
    replica: u8,
    durability: journal.Durability,
    view: u32,
    commit_number: u64,

    journal: ?Journal,
    store: Store,
    message_buffer: []align(@alignOf(Header)) u8,

    /// Set while the log is being replayed through the pipeline: a record that
    /// is already in the journal must not be appended again.
    replaying: bool,
    pending_replay: bool,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init(gpa: Allocator, io: Io, options: Options) !Replica {
        assert(options.replica < constants.cluster_replica_count_max);

        var store = try Store.init(gpa);
        errdefer store.deinit();

        const message_buffer = try gpa.alignedAlloc(
            u8,
            .fromByteUnits(@alignOf(Header)),
            constants.cluster_message_size_max,
        );
        errdefer gpa.free(message_buffer);

        var self: Replica = .{
            .gpa = gpa,
            .io = io,
            .cluster = options.cluster,
            .replica = options.replica,
            .durability = options.durability,
            .view = 0,
            .commit_number = 0,
            .journal = null,
            .store = store,
            .message_buffer = message_buffer,
            .replaying = false,
            .pending_replay = false,
        };

        if (options.durability != .off) {
            self.journal = try Journal.open(gpa, io, options.dir, options.path, .{
                .cluster = options.cluster,
                .durability = options.durability,
                .discard_existing = options.discard_existing,
            });
            const recovered = self.journal.?.recovered();
            self.commit_number = recovered.op;
            self.view = recovered.view;
            self.pending_replay = recovered.op > 0;
        }

        return self;
    }

    pub fn deinit(self: *Replica) void {
        if (self.journal) |*log_file| log_file.close();
        self.store.deinit();
        self.gpa.free(self.message_buffer);
    }

    /// Feeds every logged prepare back through the pipeline, so one dispatcher
    /// defines what a command means for a client and for a restart.
    pub fn replay(self: *Replica) !void {
        const log_file = &(self.journal orelse return);

        self.replaying = true;
        defer self.replaying = false;

        var pipeline: Pipeline = .{ .request_size_max = constants.resp_command_size_max };

        var op_next: u64 = 1;
        while (op_next <= log_file.op) : (op_next += 1) {
            const record = try log_file.read(op_next, self.message_buffer);
            const body = record.body();

            var reply_buffer: [64]u8 = undefined;
            var writer: Io.Writer = .fixed(&reply_buffer);

            const outcome = pipeline.process(Replica, self, body, &writer);
            assert(outcome.input_size_consumed == body.len);
            assert(!outcome.close);
        }

        self.pending_replay = false;
    }

    // -----------------------------------------------------------------------
    // Replicating
    // -----------------------------------------------------------------------

    /// The highest op this replica holds. The journal owns it whenever there is
    /// one; with `off` every prepare commits at once, so the commit number is
    /// the only counter.
    pub fn op(self: *const Replica) u64 {
        if (self.journal) |*log_file| return log_file.op;
        return self.commit_number;
    }

    pub fn prepare(self: *Replica, body: []const u8) u64 {
        assert(body.len > 0);
        assert(body.len <= constants.cluster_message_body_size_max);
        assert(self.commit_number <= self.op());
        assert(self.replaying or !self.pending_replay);

        if (self.replaying) return self.op();

        const log_file = &(self.journal orelse {
            assert(self.durability == .off);

            self.commit_number += 1;
            return self.commit_number;
        });

        var header: Header = std.mem.zeroes(Header);
        header.cluster = self.cluster;
        header.replica = self.replica;
        header.command = @intFromEnum(message.Command.prepare);
        header.view = self.view;
        header.op = log_file.op + 1;
        header.commit = self.commit_number;
        header.parent = log_file.checksum;
        header.size = @sizeOf(Header) + @as(u32, @intCast(body.len));
        header.setChecksums(body);

        log_file.append(&header, body) catch |err| fatal("prepare", err);
        assert(log_file.op == header.op);

        if (self.durability != .always) self.commit_number = header.op;

        return header.op;
    }

    pub fn needsCommit(self: *const Replica) bool {
        if (self.journal) |*log_file| return log_file.needsSync();
        return false;
    }

    pub fn commit(self: *Replica) void {
        const log_file = &(self.journal orelse return);

        log_file.sync() catch |err| fatal("commit", err);

        assert(log_file.op_durable <= log_file.op);
        self.commit_number = log_file.op_durable;
    }

    // -----------------------------------------------------------------------
    // State machine
    // -----------------------------------------------------------------------

    pub fn get(self: *const Replica, key: []const u8) ?[]const u8 {
        return self.store.get(key);
    }

    pub fn put(self: *Replica, key: []const u8, value: []const u8) void {
        self.store.put(key, value);
    }

    pub fn remove(self: *Replica, key: []const u8) bool {
        return self.store.remove(key);
    }

    pub fn count(self: *const Replica) usize {
        return self.store.count();
    }

    fn fatal(operation: []const u8, err: anyerror) noreturn {
        std.debug.panic("replica {s} failed: {s}", .{ operation, @errorName(err) });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const set_a = "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n";
const set_b = "*3\r\n$3\r\nSET\r\n$1\r\nb\r\n$1\r\n2\r\n";
const del_a = "*2\r\n$3\r\nDEL\r\n$1\r\na\r\n";

test "a committed write is recovered as an op, awaiting replay" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var replica = try Replica.init(testing.allocator, testing.io, .{ .dir = tmp.dir });
        defer replica.deinit();

        try testing.expectEqual(1, replica.prepare(set_a));
        replica.put("a", "1");
        try testing.expect(replica.needsCommit());
        try testing.expectEqual(0, replica.commit_number);

        replica.commit();
        try testing.expectEqual(1, replica.commit_number);
        try testing.expect(!replica.needsCommit());
    }

    var replica = try Replica.init(testing.allocator, testing.io, .{ .dir = tmp.dir });
    defer replica.deinit();

    try testing.expectEqual(1, replica.op());
    try testing.expectEqual(1, replica.commit_number);
    try testing.expect(replica.pending_replay);
    try testing.expectEqual(0, replica.count());
}

test "buffered commits without a barrier, off keeps no journal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var replica = try Replica.init(testing.allocator, testing.io, .{
            .dir = tmp.dir,
            .durability = .buffered,
        });
        defer replica.deinit();

        try testing.expectEqual(1, replica.prepare(set_a));
        try testing.expectEqual(1, replica.commit_number);
        try testing.expect(!replica.needsCommit());
    }

    var replica = try Replica.init(testing.allocator, testing.io, .{
        .dir = tmp.dir,
        .durability = .off,
    });
    defer replica.deinit();

    try testing.expectEqual(null, replica.journal);
    try testing.expectEqual(0, replica.count());
    try testing.expectEqual(1, replica.prepare(set_a));
    try testing.expectEqual(1, replica.commit_number);
    try testing.expect(!replica.needsCommit());
}

test "replay rebuilds the keyspace through the same dispatcher" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var replica = try Replica.init(testing.allocator, testing.io, .{ .dir = tmp.dir });
        defer replica.deinit();

        _ = replica.prepare(set_a);
        replica.put("a", "1");
        _ = replica.prepare(set_b);
        replica.put("b", "2");
        _ = replica.prepare(del_a);
        _ = replica.remove("a");
        replica.commit();
    }

    var replica = try Replica.init(testing.allocator, testing.io, .{ .dir = tmp.dir });
    defer replica.deinit();

    try testing.expectEqual(3, replica.op());
    try testing.expect(replica.pending_replay);
    try testing.expectEqual(0, replica.count());

    try replica.replay();

    try testing.expect(!replica.pending_replay);
    try testing.expectEqual(1, replica.count());
    try testing.expectEqual(null, replica.get("a"));
    try testing.expectEqualStrings("2", replica.get("b").?);
}
