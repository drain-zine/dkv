const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const constants = @import("../constants.zig");
const resp = @import("resp.zig");

pub const Pipeline = struct {
    command: resp.Command = .{},

    request_size_max: u32,

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    pub const Outcome = struct {
        input_size_consumed: usize,
        close: bool,
        reply_after_op: u64 = 0,
    };

    const Executed = struct {
        reply: ?resp.Reply,
        op: u64 = 0,
    };

    const Verb = enum {
        ping,
        echo,
        get,
        set,
        del,

        fn parse(name: []const u8) ?Verb {
            if (std.ascii.eqlIgnoreCase(name, "PING")) return .ping;
            if (std.ascii.eqlIgnoreCase(name, "ECHO")) return .echo;
            if (std.ascii.eqlIgnoreCase(name, "GET")) return .get;
            if (std.ascii.eqlIgnoreCase(name, "SET")) return .set;
            if (std.ascii.eqlIgnoreCase(name, "DEL")) return .del;
            return null;
        }

        fn write(verb: Verb) bool {
            return switch (verb) {
                .set, .del => true,
                .ping, .echo, .get => false,
            };
        }

        fn arityError(verb: Verb, argument_count: usize) ?resp.Reply {
            const ok = switch (verb) {
                .ping => argument_count <= 1,
                .echo, .get => argument_count == 1,
                .set => argument_count == 2,
                .del => argument_count >= 1,
            };
            if (ok) return null;

            return .{ .error_arity = switch (verb) {
                .ping => "ping",
                .echo => "echo",
                .get => "get",
                .set => "set",
                .del => "del",
            } };
        }
    };

    const Stop = enum { input_exhausted, incomplete, response_full, protocol_error };

    // -----------------------------------------------------------------------
    // Canned replies
    // -----------------------------------------------------------------------

    pub const reject_busy_reply = blk: {
        var buffer: [64]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        resp.encode(&writer, .error_max_clients) catch unreachable;
        const encoded = writer.buffered();

        var reply: [encoded.len]u8 = undefined;
        @memcpy(&reply, encoded);
        break :blk reply;
    };

    // -----------------------------------------------------------------------
    // Running
    // -----------------------------------------------------------------------

    pub fn process(
        self: *Pipeline,
        comptime Context: type,
        context: *Context,
        input: []const u8,
        writer: *Io.Writer,
    ) Outcome {
        assert(input.len <= self.request_size_max);

        var close = false;
        var reply_after_op: u64 = 0;
        var input_size_consumed: usize = 0;
        const stop: Stop = commands: while (input_size_consumed < input.len) {
            const input_remaining = input[input_size_consumed..];
            resp.decode(input_remaining, &self.command) catch |err| switch (err) {
                error.Incomplete => break :commands .incomplete,
                error.Protocol, error.TooManyArguments, error.ArgumentTooLarge => {
                    if (!encodeReply(writer, .error_protocol)) break :commands .response_full;
                    close = true;
                    break :commands .protocol_error;
                },
            };
            assert(self.command.size > 0);
            assert(self.command.size <= input_remaining.len);

            const command_bytes = input_remaining[0..self.command.size];
            const executed = self.execute(Context, context, command_bytes);
            if (executed.reply) |reply| {
                if (!encodeReply(writer, reply)) break :commands .response_full;
            }
            if (executed.op > reply_after_op) reply_after_op = executed.op;
            input_size_consumed += self.command.size;
        } else .input_exhausted;
        assert(input_size_consumed <= input.len);

        const input_size_left = input.len - input_size_consumed;
        if (stop == .incomplete and input_size_left == self.request_size_max) {
            if (encodeReply(writer, .error_request_too_large)) close = true;
        }

        return .{
            .input_size_consumed = input_size_consumed,
            .close = close,
            .reply_after_op = reply_after_op,
        };
    }

    fn encodeReply(writer: *Io.Writer, reply: resp.Reply) bool {
        const end_before = writer.end;
        resp.encode(writer, reply) catch {
            writer.end = end_before;
            return false;
        };
        return true;
    }

    // -----------------------------------------------------------------------
    // Executing
    // -----------------------------------------------------------------------

    fn execute(
        self: *Pipeline,
        comptime Context: type,
        context: *Context,
        command_bytes: []const u8,
    ) Executed {
        const command = &self.command;
        if (command.argument_count == 0) return .{ .reply = null };
        assert(command.argument_count <= constants.resp_argument_count_max);

        const name = command.name();
        const arguments = command.arguments[1..command.argument_count];

        const verb = Verb.parse(name) orelse {
            return .{ .reply = .{ .error_unknown_command = name } };
        };
        if (Verb.arityError(verb, arguments.len)) |reply| return .{ .reply = reply };

        const op = if (verb.write()) context.prepare(command_bytes) else 0;

        return .{ .op = op, .reply = switch (verb) {
            .ping => if (arguments.len == 0) .pong else .{ .bulk_string = arguments[0] },
            .echo => .{ .bulk_string = arguments[0] },
            .get => if (context.get(arguments[0])) |value|
                resp.Reply{ .bulk_string = value }
            else
                resp.Reply.null_value,
            .set => set: {
                context.put(arguments[0], arguments[1]);
                break :set resp.Reply.ok;
            },
            .del => del: {
                var removed_count: u32 = 0;
                for (arguments) |key| {
                    if (context.remove(key)) removed_count += 1;
                }
                assert(removed_count <= arguments.len);
                break :del resp.Reply{ .integer = removed_count };
            },
        } };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const request_size_max_test = 4096;

const Store = @import("../store.zig").Store;

const Fake = struct {
    store: Store,
    op: u64 = 0,

    fn prepare(self: *Fake, body: []const u8) u64 {
        assert(body.len > 0);

        self.op += 1;
        return self.op;
    }

    fn get(self: *const Fake, key: []const u8) ?[]const u8 {
        return self.store.get(key);
    }

    fn put(self: *Fake, key: []const u8, value: []const u8) void {
        self.store.put(key, value);
    }

    fn remove(self: *Fake, key: []const u8) bool {
        return self.store.remove(key);
    }
};

const Harness = struct {
    context: Fake,
    pipeline: Pipeline,

    fn init(self: *Harness, request_size_max: u32) !void {
        self.context = .{ .store = try Store.init(testing.allocator) };
        self.pipeline = .{ .request_size_max = request_size_max };
    }

    fn deinit(self: *Harness) void {
        self.context.store.deinit();
    }

    fn expectProcess(
        self: *Harness,
        input: []const u8,
        replies_expected: []const u8,
        outcome_expected: Pipeline.Outcome,
    ) !void {
        var reply_buffer: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&reply_buffer);

        const outcome = self.pipeline.process(Fake, &self.context, input, &writer);

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
        .reply_after_op = 1,
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
        .reply_after_op = 1,
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
        .reply_after_op = 1,
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
        .reply_after_op = 2,
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
    const outcome_full = harness.pipeline.process(Fake, &harness.context, input, &writer_full);

    try testing.expectEqualStrings("+PONG\r\n", writer_full.buffered());
    try testing.expectEqual(Pipeline.Outcome{
        .input_size_consumed = ping.len,
        .close = false,
    }, outcome_full);

    var reply_buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&reply_buffer);
    const outcome = harness.pipeline.process(Fake, &harness.context, input[ping.len..], &writer);

    try testing.expectEqualStrings("$2\r\nhi\r\n", writer.buffered());
    try testing.expectEqual(Pipeline.Outcome{
        .input_size_consumed = echo.len,
        .close = false,
    }, outcome);
}
