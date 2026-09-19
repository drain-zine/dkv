const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const constants = @import("../constants.zig");
const resp = @import("resp.zig");
const Store = @import("../storage/store.zig").Store;

/// Runs the whole commands sitting in a request buffer and writes their replies.
/// A reply that will not fit stops the loop with the command unconsumed, so the
/// caller can send what is buffered and call again: no reply is ever truncated.
pub const CommandLoop = struct {
    command: resp.Command = .{},

    /// Bytes the caller's request buffer holds. A partial command that fills it
    /// can never complete, so it is refused rather than waited on.
    request_size_max: u32,

    /// Encoded at compile time so refusing a client costs no loop and no buffer.
    pub const reject_busy_reply = blk: {
        var buffer: [64]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        resp.encode(&writer, .error_max_clients) catch unreachable;
        const encoded = writer.buffered();

        var reply: [encoded.len]u8 = undefined;
        @memcpy(&reply, encoded);
        break :blk reply;
    };

    pub const Outcome = struct {
        input_size_consumed: usize,
        close: bool,
    };

    const Stop = enum { input_exhausted, incomplete, response_full };

    pub fn process(
        self: *CommandLoop,
        store: *Store,
        input: []const u8,
        writer: *Io.Writer,
    ) Outcome {
        assert(input.len <= self.request_size_max);

        var input_size_consumed: usize = 0;
        const stop: Stop = commands: while (input_size_consumed < input.len) {
            const input_remaining = input[input_size_consumed..];
            resp.decode(input_remaining, &self.command) catch |err| switch (err) {
                error.Incomplete => break :commands .incomplete,
                error.Protocol, error.TooManyArguments, error.ArgumentTooLarge => {
                    if (!encodeReply(writer, .error_protocol)) break :commands .response_full;
                    return .{ .input_size_consumed = input_size_consumed, .close = true };
                },
            };
            assert(self.command.size > 0);
            assert(self.command.size <= input_remaining.len);

            if (self.execute(store)) |reply| {
                if (!encodeReply(writer, reply)) break :commands .response_full;
            }
            input_size_consumed += self.command.size;
        } else .input_exhausted;
        assert(input_size_consumed <= input.len);

        const input_size_left = input.len - input_size_consumed;
        if (stop == .incomplete and input_size_left == self.request_size_max) {
            if (encodeReply(writer, .error_request_too_large)) {
                return .{ .input_size_consumed = input_size_consumed, .close = true };
            }
        }

        return .{ .input_size_consumed = input_size_consumed, .close = false };
    }

    /// Leaves the writer exactly as it found it when the reply will not fit, so
    /// the caller can send what is buffered and encode the same reply again.
    fn encodeReply(writer: *Io.Writer, reply: resp.Reply) bool {
        const end_before = writer.end;
        resp.encode(writer, reply) catch {
            writer.end = end_before;
            return false;
        };
        return true;
    }

    /// Returns the reply to one command, or null for an empty inline line,
    /// which Redis also skips without a reply.
    fn execute(self: *CommandLoop, store: *Store) ?resp.Reply {
        const command = &self.command;
        if (command.argument_count == 0) return null;
        assert(command.argument_count <= constants.resp_argument_count_max);

        const name = command.name();
        const arguments = command.arguments[1..command.argument_count];

        if (std.ascii.eqlIgnoreCase(name, "PING")) {
            return switch (arguments.len) {
                0 => .pong,
                1 => .{ .bulk_string = arguments[0] },
                else => .{ .error_arity = "ping" },
            };
        }
        if (std.ascii.eqlIgnoreCase(name, "ECHO")) {
            if (arguments.len != 1) return .{ .error_arity = "echo" };
            return .{ .bulk_string = arguments[0] };
        }
        if (std.ascii.eqlIgnoreCase(name, "GET")) {
            if (arguments.len != 1) return .{ .error_arity = "get" };
            const value = store.get(arguments[0]) orelse return .null_value;
            return .{ .bulk_string = value };
        }
        if (std.ascii.eqlIgnoreCase(name, "SET")) {
            if (arguments.len != 2) return .{ .error_arity = "set" };
            store.put(arguments[0], arguments[1]);
            return .ok;
        }
        if (std.ascii.eqlIgnoreCase(name, "DEL")) {
            if (arguments.len == 0) return .{ .error_arity = "del" };
            var removed_count: u32 = 0;
            for (arguments) |key| {
                if (store.remove(key)) removed_count += 1;
            }
            assert(removed_count <= arguments.len);
            return .{ .integer = removed_count };
        }
        return .{ .error_unknown_command = name };
    }
};

const testing = std.testing;

const request_size_max_test = 4096;

const Harness = struct {
    tmp: testing.TmpDir,
    store: Store,
    loop: CommandLoop,

    fn init(self: *Harness, request_size_max: u32) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        self.store = try Store.init(testing.allocator, testing.io, .{
            .dir = self.tmp.dir,
            .wal = .{ .durability = .never },
        });
        self.loop = .{ .request_size_max = request_size_max };
    }

    fn deinit(self: *Harness) void {
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn expectProcess(
        self: *Harness,
        input: []const u8,
        replies_expected: []const u8,
        outcome_expected: CommandLoop.Outcome,
    ) !void {
        var reply_buffer: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&reply_buffer);

        const outcome = self.loop.process(&self.store, input, &writer);

        try testing.expectEqualStrings(replies_expected, writer.buffered());
        try testing.expectEqual(outcome_expected, outcome);
    }
};

test "pipelined commands reply in order and consume every byte" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const input =
        "*1\r\n$4\r\nPING\r\n" ++
        "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" ++
        "*2\r\n$3\r\nGET\r\n$1\r\na\r\n";

    try harness.expectProcess(input, "+PONG\r\n+OK\r\n$1\r\n1\r\n", .{
        .input_size_consumed = input.len,
        .close = false,
    });
}

test "a split request replies only once it is complete" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const input = "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n";

    var prefix_size: usize = 0;
    while (prefix_size < input.len) : (prefix_size += 1) {
        try harness.expectProcess(input[0..prefix_size], "", .{
            .input_size_consumed = 0,
            .close = false,
        });
    }
    try harness.expectProcess(input, "+OK\r\n", .{
        .input_size_consumed = input.len,
        .close = false,
    });
}

test "a trailing partial command is left unconsumed" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const whole = "*1\r\n$4\r\nPING\r\n";
    const input = whole ++ "*2\r\n$3\r\nGET\r\n$1\r\nk";

    try harness.expectProcess(input, "+PONG\r\n", .{
        .input_size_consumed = whole.len,
        .close = false,
    });
}

test "inline commands run and empty lines are skipped" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const input = "ping\r\n\r\nECHO hi\r\n";

    try harness.expectProcess(input, "+PONG\r\n$2\r\nhi\r\n", .{
        .input_size_consumed = input.len,
        .close = false,
    });
}

test "values are binary safe" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const input =
        "*3\r\n$3\r\nSET\r\n$3\r\nbin\r\n$4\r\na\r\nb\r\n" ++
        "*2\r\n$3\r\nGET\r\n$3\r\nbin\r\n";

    try harness.expectProcess(input, "+OK\r\n$4\r\na\r\nb\r\n", .{
        .input_size_consumed = input.len,
        .close = false,
    });
}

test "GET on a missing key is null and DEL counts removed keys" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const input =
        "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" ++
        "*3\r\n$3\r\nDEL\r\n$1\r\na\r\n$1\r\nb\r\n" ++
        "*2\r\n$3\r\nGET\r\n$1\r\na\r\n";

    try harness.expectProcess(input, "+OK\r\n:1\r\n$-1\r\n", .{
        .input_size_consumed = input.len,
        .close = false,
    });
}

test "command errors reply and keep the connection open" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const input = "NOPE x\r\nGET\r\nPING\r\n";
    const replies =
        "-ERR unknown command 'NOPE'\r\n" ++
        "-ERR wrong number of arguments for 'get' command\r\n" ++
        "+PONG\r\n";

    try harness.expectProcess(input, replies, .{
        .input_size_consumed = input.len,
        .close = false,
    });
}

test "a protocol error replies once, ignores later bytes and closes" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const ping = "*1\r\n$4\r\nPING\r\n";
    const input = ping ++ "*1\r\n+OK\r\n" ++ ping;

    try harness.expectProcess(input, "+PONG\r\n-ERR Protocol error\r\n", .{
        .input_size_consumed = ping.len,
        .close = true,
    });
}

test "a partial request that fills the buffer closes" {
    var harness: Harness = undefined;
    try harness.init(64);
    defer harness.deinit();

    const input = "a" ** 64;

    try harness.expectProcess(input, "-ERR Protocol error: request too large\r\n", .{
        .input_size_consumed = 0,
        .close = true,
    });
}

test "a reply that will not fit is left for the next call" {
    var harness: Harness = undefined;
    try harness.init(request_size_max_test);
    defer harness.deinit();

    const ping = "*1\r\n$4\r\nPING\r\n";
    const echo = "*2\r\n$4\r\nECHO\r\n$2\r\nhi\r\n";
    const input = ping ++ echo;

    var reply_buffer_full: ["+PONG\r\n".len]u8 = undefined;
    var writer_full: Io.Writer = .fixed(&reply_buffer_full);
    const outcome_full = harness.loop.process(&harness.store, input, &writer_full);

    try testing.expectEqualStrings("+PONG\r\n", writer_full.buffered());
    try testing.expectEqual(CommandLoop.Outcome{
        .input_size_consumed = ping.len,
        .close = false,
    }, outcome_full);

    var reply_buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&reply_buffer);
    const outcome = harness.loop.process(&harness.store, input[ping.len..], &writer);

    try testing.expectEqualStrings("$2\r\nhi\r\n", writer.buffered());
    try testing.expectEqual(CommandLoop.Outcome{
        .input_size_consumed = echo.len,
        .close = false,
    }, outcome);
}
