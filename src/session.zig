const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const constants = @import("constants.zig");
const resp = @import("resp.zig");
const Store = @import("store.zig").Store;

pub const Session = struct {
    command: resp.Command = .{},
    closed: bool = false,

    pub const Outcome = struct {
        input_size_consumed: usize,
        close: bool,
    };

    pub fn process(
        session: *Session,
        store: *Store,
        input: []const u8,
        writer: *Io.Writer,
    ) Io.Writer.Error!Outcome {
        assert(!session.closed);
        assert(input.len <= constants.connection_request_buffer_size);

        var input_size_consumed: usize = 0;
        while (input_size_consumed < input.len) {
            const input_remaining = input[input_size_consumed..];
            resp.decode(input_remaining, &session.command) catch |err| switch (err) {
                error.Incomplete => break,
                error.Protocol, error.TooManyArguments, error.ArgumentTooLarge => {
                    return session.close(writer, .error_protocol, input_size_consumed);
                },
            };
            assert(session.command.size > 0);
            assert(session.command.size <= input_remaining.len);

            if (session.execute(store)) |reply| try resp.encode(writer, reply);
            input_size_consumed += session.command.size;
        }
        assert(input_size_consumed <= input.len);

        if (input.len - input_size_consumed == constants.connection_request_buffer_size) {
            return session.close(writer, .error_request_too_large, input_size_consumed);
        }
        return .{ .input_size_consumed = input_size_consumed, .close = false };
    }

    fn close(
        session: *Session,
        writer: *Io.Writer,
        reply: resp.Reply,
        input_size_consumed: usize,
    ) Io.Writer.Error!Outcome {
        assert(!session.closed);

        session.closed = true;
        try resp.encode(writer, reply);
        return .{ .input_size_consumed = input_size_consumed, .close = true };
    }

    /// Returns the reply to one command, or null for an empty inline line,
    /// which Redis also skips without a reply.
    fn execute(session: *Session, store: *Store) ?resp.Reply {
        const command = &session.command;
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

const Harness = struct {
    tmp: testing.TmpDir,
    store: Store,
    session: Session,

    fn init(harness: *Harness) !void {
        harness.tmp = testing.tmpDir(.{});
        errdefer harness.tmp.cleanup();

        harness.store = try Store.init(testing.allocator, testing.io, .{
            .dir = harness.tmp.dir,
            .wal = .{ .durability = .never },
        });
        harness.session = .{};
    }

    fn deinit(harness: *Harness) void {
        harness.store.deinit();
        harness.tmp.cleanup();
    }

    fn expectProcess(
        harness: *Harness,
        input: []const u8,
        replies_expected: []const u8,
        outcome_expected: Session.Outcome,
    ) !void {
        var reply_buffer: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&reply_buffer);

        const outcome = try harness.session.process(&harness.store, input, &writer);

        try testing.expectEqualStrings(replies_expected, writer.buffered());
        try testing.expectEqual(outcome_expected, outcome);
    }
};

test "pipelined commands reply in order and consume every byte" {
    var harness: Harness = undefined;
    try harness.init();
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
    try harness.init();
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
    try harness.init();
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
    try harness.init();
    defer harness.deinit();

    const input = "ping\r\n\r\nECHO hi\r\n";

    try harness.expectProcess(input, "+PONG\r\n$2\r\nhi\r\n", .{
        .input_size_consumed = input.len,
        .close = false,
    });
}

test "values are binary safe" {
    var harness: Harness = undefined;
    try harness.init();
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
    try harness.init();
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

test "command errors reply and keep the session open" {
    var harness: Harness = undefined;
    try harness.init();
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
    try harness.init();
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
    try harness.init();
    defer harness.deinit();

    const input = try testing.allocator.alloc(u8, constants.connection_request_buffer_size);
    defer testing.allocator.free(input);
    @memset(input, 'a');

    try harness.expectProcess(input, "-ERR Protocol error: request too large\r\n", .{
        .input_size_consumed = 0,
        .close = true,
    });
}
