const std = @import("std");
const assert = std.debug.assert;

const constants = @import("../constants.zig");

const terminator = "\r\n";

pub const Prefix = enum(u8) {
    simple_string = '+',
    simple_error = '-',
    integer = ':',
    bulk_string = '$',
    array = '*',
    null_value = '_',
    boolean = '#',
    double = ',',
    big_number = '(',
    bulk_error = '!',
    verbatim_string = '=',
    map = '%',
    attribute = '|',
    set = '~',
};

comptime {
    assert(terminator.len == constants.resp_terminator_size);
    assert(1 + constants.command_error_message_size_max + terminator.len <=
        constants.resp_reply_size_max);
}

pub const Command = struct {
    arguments: [constants.resp_argument_count_max][]const u8 = undefined,
    argument_count: u32 = 0,

    size: u32 = 0,

    pub fn name(self: *const Command) []const u8 {
        return self.arguments[0];
    }
};

pub const DecodeError = error{
    Incomplete,
    Protocol,
    TooManyArguments,
    ArgumentTooLarge,
};

pub fn decode(input: []const u8, command: *Command) DecodeError!void {
    command.argument_count = 0;

    if (input.len == 0) return error.Incomplete;
    if (input[0] != @intFromEnum(Prefix.array)) return decodeInline(input, command);
    return decodeArray(input, command);
}

fn decodeInline(input: []const u8, command: *Command) DecodeError!void {
    const line, const size = try readLine(input, 0);
    if (line.len > constants.resp_inline_size_max) return error.Protocol;

    var argument_count: u32 = 0;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    while (tokens.next()) |token| {
        if (argument_count == constants.resp_argument_count_max) return error.TooManyArguments;
        command.arguments[argument_count] = token;
        argument_count += 1;
    }

    command.argument_count = argument_count;
    command.size = @intCast(size);
}

fn decodeArray(input: []const u8, command: *Command) DecodeError!void {
    var offset: usize = 0;
    const count_line, offset = try readLine(input, offset);
    const argument_count = std.fmt.parseInt(usize, count_line[1..], 10) catch
        return error.Protocol;
    if (argument_count > constants.resp_argument_count_max) return error.TooManyArguments;

    for (0..argument_count) |argument_index| {
        const size_line, offset = try readLine(input, offset);
        if (size_line.len == 0 or size_line[0] != @intFromEnum(Prefix.bulk_string)) {
            return error.Protocol;
        }
        const argument_size = std.fmt.parseInt(usize, size_line[1..], 10) catch
            return error.Protocol;
        if (argument_size > constants.resp_argument_size_max) return error.ArgumentTooLarge;

        const argument_end = offset + argument_size;
        if (argument_end + terminator.len > input.len) return error.Incomplete;

        const argument_terminator = input[argument_end .. argument_end + terminator.len];
        if (!std.mem.eql(u8, argument_terminator, terminator)) return error.Protocol;

        command.arguments[argument_index] = input[offset..argument_end];
        offset = argument_end + terminator.len;
    }

    command.argument_count = @intCast(argument_count);
    command.size = @intCast(offset);
}

fn readLine(input: []const u8, offset: usize) DecodeError!struct { []const u8, usize } {
    const line_end = std.mem.findPosLinear(u8, input, offset, terminator) orelse
        return error.Incomplete;
    return .{ input[offset..line_end], line_end + terminator.len };
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub const Reply = union(enum) {
    ok,
    pong,
    null_value,
    integer: i64,
    bulk_string: []const u8,
    error_protocol,
    error_request_too_large,
    error_arity: []const u8,
    error_unknown_command: []const u8,
    error_max_clients,
};

pub fn encode(writer: *std.Io.Writer, reply: Reply) std.Io.Writer.Error!void {
    switch (reply) {
        .ok => try encodeSimpleString(writer, "OK"),
        .pong => try encodeSimpleString(writer, "PONG"),
        .null_value => try encodeNull(writer),
        .integer => |value| try encodeInteger(writer, value),
        .bulk_string => |value| try encodeBulkString(writer, value),
        .error_protocol => try encodeError(writer, "ERR Protocol error"),
        .error_request_too_large => {
            try encodeError(writer, "ERR Protocol error: request too large");
        },
        .error_arity => |name| {
            try encodeErrorNamed(writer, "ERR wrong number of arguments for '{s}' command", name);
        },
        .error_unknown_command => |name| {
            try encodeErrorNamed(writer, "ERR unknown command '{s}'", name);
        },
        .error_max_clients => try encodeError(writer, "ERR max number of clients reached"),
    }
}

fn encodeErrorNamed(
    writer: *std.Io.Writer,
    comptime format: []const u8,
    name: []const u8,
) std.Io.Writer.Error!void {
    comptime assert(format.len + constants.command_name_echo_size_max <=
        constants.command_error_message_size_max);

    const name_echo = name[0..@min(name.len, constants.command_name_echo_size_max)];
    var message_buffer: [constants.command_error_message_size_max]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, format, .{name_echo}) catch unreachable;
    try encodeError(writer, message);
}

fn encodeSimpleString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    assert(std.mem.findAny(u8, value, terminator) == null);

    try writer.writeByte(@intFromEnum(Prefix.simple_string));
    try writer.writeAll(value);
    try writer.writeAll(terminator);
}

fn encodeError(writer: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
    assert(message.len > 0);

    try writer.writeByte(@intFromEnum(Prefix.simple_error));
    for (message) |byte| {
        const byte_safe: u8 = if (byte == '\r' or byte == '\n') ' ' else byte;
        try writer.writeByte(byte_safe);
    }
    try writer.writeAll(terminator);
}

fn encodeInteger(writer: *std.Io.Writer, value: i64) std.Io.Writer.Error!void {
    try writer.print(":{d}" ++ terminator, .{value});
}

fn encodeBulkString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.print("${d}" ++ terminator, .{value.len});
    try writer.writeAll(value);
    try writer.writeAll(terminator);
}

fn encodeNull(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("$-1" ++ terminator);
}

fn encodeArrayHeader(writer: *std.Io.Writer, count: u32) std.Io.Writer.Error!void {
    try writer.print("*{d}" ++ terminator, .{count});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "one command with no arguments" {
    var command: Command = .{};
    const input = "*1\r\n$4\r\nPING\r\n";

    try decode(input, &command);

    try testing.expectEqual(1, command.argument_count);
    try testing.expectEqualStrings("PING", command.arguments[0]);
    try testing.expectEqual(input.len, command.size);
}

test "one command with arguments" {
    var command: Command = .{};
    const input = "*3\r\n$3\r\nSET\r\n$5\r\nmykey\r\n$7\r\nmyvalue\r\n";

    try decode(input, &command);

    try testing.expectEqual(3, command.argument_count);
    try testing.expectEqualStrings("SET", command.arguments[0]);
    try testing.expectEqualStrings("mykey", command.arguments[1]);
    try testing.expectEqualStrings("myvalue", command.arguments[2]);
    try testing.expectEqual(input.len, command.size);
}

test "arguments are binary safe and may be empty" {
    var command: Command = .{};

    try decode("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$4\r\na\r\nb\r\n", &command);
    try testing.expectEqualStrings("a\r\nb", command.arguments[2]);

    try decode("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n", &command);
    try testing.expectEqualStrings("", command.arguments[2]);
}

test "a command split across reads is incomplete until its last byte" {
    const input = "*2\r\n$3\r\nGET\r\n$5\r\nmykey\r\n";

    var prefix_size: usize = 0;
    while (prefix_size < input.len) : (prefix_size += 1) {
        var command: Command = .{};
        try testing.expectError(error.Incomplete, decode(input[0..prefix_size], &command));
    }

    var command: Command = .{};
    try decode(input, &command);
    try testing.expectEqualStrings("mykey", command.arguments[1]);
}

test "pipelined commands are decoded one at a time" {
    const input =
        "*1\r\n$4\r\nPING\r\n" ++
        "*2\r\n$3\r\nGET\r\n$1\r\na\r\n" ++
        "*1\r\n$4\r\nPING\r\n";

    var command: Command = .{};
    var names: [8][]const u8 = undefined;
    var decoded_count: usize = 0;
    var offset: usize = 0;

    while (offset < input.len) {
        try decode(input[offset..], &command);
        try testing.expect(command.size > 0);
        try testing.expect(decoded_count < names.len);
        names[decoded_count] = command.arguments[0];
        decoded_count += 1;
        offset += command.size;
    }

    try testing.expectEqual(3, decoded_count);
    try testing.expectEqual(input.len, offset);
    try testing.expectEqualStrings("PING", names[0]);
    try testing.expectEqualStrings("GET", names[1]);
    try testing.expectEqualStrings("PING", names[2]);
}

test "a trailing partial command is left for the next read" {
    const whole = "*1\r\n$4\r\nPING\r\n";
    const input = whole ++ "*2\r\n$3\r\nGET\r\n$5\r\nmy";

    var command: Command = .{};
    try decode(input, &command);
    try testing.expectEqual(whole.len, command.size);

    try testing.expectError(error.Incomplete, decode(input[command.size..], &command));
}

test "broken framing is a protocol error, so the connection must close" {
    var command: Command = .{};

    try testing.expectError(error.Protocol, decode("*1\r\n+OK\r\n", &command));
    try testing.expectError(error.Protocol, decode("*-1\r\n", &command));
    try testing.expectError(error.Protocol, decode("*1\r\n$-1\r\n", &command));
    try testing.expectError(error.Protocol, decode("*x\r\n", &command));
    try testing.expectError(error.Protocol, decode("*1\r\n$3\r\nPINGGG\r\n", &command));
}

test "limits are rejected rather than trusted" {
    var command: Command = .{};

    try testing.expectError(error.TooManyArguments, decode("*9999\r\n", &command));
    try testing.expectError(error.ArgumentTooLarge, decode("*1\r\n$99999999\r\n", &command));
}

test "inline commands" {
    var command: Command = .{};
    const input = "ECHO hello world\r\n";

    try decode(input, &command);

    try testing.expectEqual(3, command.argument_count);
    try testing.expectEqualStrings("ECHO", command.arguments[0]);
    try testing.expectEqualStrings("world", command.arguments[2]);
    try testing.expectEqual(input.len, command.size);
}

test "simple string replies" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encode(&writer, .ok);
    try encode(&writer, .pong);

    try testing.expectEqualStrings("+OK\r\n+PONG\r\n", writer.buffered());
}

test "errors cannot break the framing" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encode(&writer, .{ .error_arity = "get" });
    try testing.expectEqualStrings(
        "-ERR wrong number of arguments for 'get' command\r\n",
        writer.buffered(),
    );

    writer = .fixed(&buffer);
    try encode(&writer, .{ .error_unknown_command = "a\r\nb" });
    try testing.expectEqualStrings("-ERR unknown command 'a  b'\r\n", writer.buffered());
}

test "echoed command names are bounded" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encode(&writer, .{ .error_unknown_command = "x" ** 1000 });

    try testing.expectEqualStrings(
        "-ERR unknown command '" ++ "x" ** constants.command_name_echo_size_max ++ "'\r\n",
        writer.buffered(),
    );
}

test "protocol errors" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encode(&writer, .error_protocol);
    try encode(&writer, .error_request_too_large);

    try testing.expectEqualStrings(
        "-ERR Protocol error\r\n-ERR Protocol error: request too large\r\n",
        writer.buffered(),
    );
}

test "integers, including negative and extremes" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encode(&writer, .{ .integer = 0 });
    try encode(&writer, .{ .integer = 42 });
    try encode(&writer, .{ .integer = -1 });
    try encode(&writer, .{ .integer = std.math.minInt(i64) });

    try testing.expectEqualStrings(
        ":0\r\n:42\r\n:-1\r\n:-9223372036854775808\r\n",
        writer.buffered(),
    );
}

test "bulk strings are length prefixed and binary safe" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encode(&writer, .{ .bulk_string = "hello" });
    try encode(&writer, .{ .bulk_string = "" });
    try encode(&writer, .{ .bulk_string = "a\r\nb" });

    try testing.expectEqualStrings("$5\r\nhello\r\n$0\r\n\r\n$4\r\na\r\nb\r\n", writer.buffered());
}

test "null is distinct from an empty bulk string" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encode(&writer, .null_value);
    try encode(&writer, .{ .bulk_string = "" });

    try testing.expectEqualStrings("$-1\r\n$0\r\n\r\n", writer.buffered());
}

test "a full buffer is an error, not a truncated success" {
    var buffer: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try testing.expectError(error.WriteFailed, encode(&writer, .{ .bulk_string = "hello" }));
}

test "an encoded request decodes to the same arguments" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const arguments = [_][]const u8{ "SET", "key", "a\r\nb", "" };

    try encodeArrayHeader(&writer, arguments.len);
    for (arguments) |argument| try encodeBulkString(&writer, argument);

    var command: Command = .{};
    try decode(writer.buffered(), &command);

    try testing.expectEqual(arguments.len, command.argument_count);
    for (arguments, command.arguments[0..command.argument_count]) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
    try testing.expectEqual(writer.buffered().len, command.size);
}
