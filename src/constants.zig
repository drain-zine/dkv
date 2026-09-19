const std = @import("std");
const assert = std.debug.assert;

// ---------------------------------------------------------------------------
// RESP protocol
// ---------------------------------------------------------------------------
pub const resp_argument_count_max = 1024;

/// Bytes in one argument, and so the largest key or value a client can store.
pub const resp_argument_size_max = 1024 * 1024;

/// Bytes in one inline command line, as typed into telnet or netcat.
pub const resp_inline_size_max = 64 * 1024;

/// Bytes of one whole command on the wire, framing included. A partial command
/// that reaches this size can never complete, so the connection is closed.
pub const resp_command_size_max = 2 * 1024 * 1024;

/// Bytes of the largest single reply: a bulk string holding a maximum argument.
pub const resp_reply_size_max = resp_argument_size_max + resp_argument_framing_size_max;

/// Bytes in the `\r\n` that ends every header line and follows every body.
pub const resp_terminator_size = 2;

/// Bytes of the longest `*N\r\n` line.
const resp_count_line_size_max = 1 + digitCount(resp_argument_count_max) + resp_terminator_size;

/// Bytes of framing around one maximum argument: `$N\r\n` before, `\r\n` after.
const resp_argument_framing_size_max =
    1 + digitCount(resp_argument_size_max) + 2 * resp_terminator_size;

pub const command_name_echo_size_max = 64;
pub const command_error_message_size_max = 128;

comptime {
    assert(resp_inline_size_max <= resp_command_size_max);

    // Room for the count line, one maximum argument, and an inline line's worth
    // of other arguments, such as the key beside a maximum value.
    assert(resp_count_line_size_max + resp_argument_framing_size_max +
        resp_argument_size_max + resp_inline_size_max <= resp_command_size_max);
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

/// Clients served at once. Each costs one file descriptor and one set of
/// buffers. macOS defaults to 256 descriptors per process.
pub const connection_count_max = 64;

/// Holds a whole command before it runs, because decoded arguments are slices
/// into this buffer rather than copies.
pub const connection_request_buffer_size = resp_command_size_max;

/// Holds at least one maximum reply, so a reply never has to be split across
/// writes.
pub const connection_response_buffer_size = resp_reply_size_max;

/// Upper bound on every connection buffer together. All of it is allocated
/// once at startup.
pub const connection_memory_max = 256 * 1024 * 1024;

comptime {
    assert(connection_count_max <= 256);

    // A reply is only ever encoded into an empty response buffer, so the
    // largest one must fit or a connection could never make progress.
    assert(resp_reply_size_max <= connection_response_buffer_size);

    const connection_size = connection_request_buffer_size + connection_response_buffer_size;
    assert(connection_count_max * connection_size <= connection_memory_max);
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

/// Longest single wait for kqueue events. Bounds how long an idle loop sleeps,
/// so periodic work such as group commit still runs without traffic.
pub const event_loop_wait_timeout_ms = 1000;

/// One receive and one send per connection, plus the accept.
pub const io_in_flight_max = connection_count_max * 2 + 1;

/// Registrations submitted in one `kevent` call: at most one per operation
/// waiting on readiness.
pub const io_change_count_max = io_in_flight_max;

/// Events collected from one `kevent` call.
pub const io_event_count_max = io_in_flight_max;

/// A syscall interrupted by a signal is retried this many times before it is
/// reported as a failure. Bounds every retry loop in the IO backends.
pub const io_syscall_retry_max = 8;

/// Ring capacity, a power of two so wrapping is a mask rather than a division.
pub const io_ring_capacity = 256;

comptime {
    // A zero timeout would turn the idle loop into a busy spin.
    assert(event_loop_wait_timeout_ms > 0);

    assert(io_ring_capacity >= io_in_flight_max);
    assert(io_ring_capacity & (io_ring_capacity - 1) == 0);
}

// ---------------------------------------------------------------------------
// Write-ahead log
// ---------------------------------------------------------------------------

/// Write buffer size. Appends larger than this are written straight through.
pub const wal_buffer_size = 64 * 1024;

/// Any record claiming a body larger than this is treated as corruption.
pub const wal_record_size_max = 16 * 1024 * 1024;

comptime {
    // A record holds the key and value of one command, so every accepted
    // command must fit in a record.
    assert(resp_command_size_max <= wal_record_size_max);
}

fn digitCount(comptime value: u64) usize {
    return @as(usize, std.math.log10_int(value)) + 1;
}
