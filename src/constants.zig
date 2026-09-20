const std = @import("std");
const assert = std.debug.assert;

// ---------------------------------------------------------------------------
// RESP protocol
// ---------------------------------------------------------------------------

pub const resp_argument_count_max = 1024;

pub const resp_argument_size_max = 1024 * 1024;

pub const resp_inline_size_max = 64 * 1024;

pub const resp_command_size_max = 2 * 1024 * 1024;

pub const resp_reply_size_max = resp_argument_size_max + resp_argument_framing_size_max;
pub const resp_terminator_size = 2;

const resp_count_line_size_max = 1 + digitCount(resp_argument_count_max) + resp_terminator_size;

const resp_argument_framing_size_max =
    1 + digitCount(resp_argument_size_max) + 2 * resp_terminator_size;

pub const command_name_echo_size_max = 64;
pub const command_error_message_size_max = 128;

comptime {
    assert(resp_inline_size_max <= resp_command_size_max);

    assert(resp_count_line_size_max + resp_argument_framing_size_max +
        resp_argument_size_max + resp_inline_size_max <= resp_command_size_max);
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

pub const connection_count_max = 64;

pub const connection_request_buffer_size = resp_command_size_max;

pub const connection_response_buffer_size = resp_reply_size_max;
pub const connection_memory_max = 256 * 1024 * 1024;

comptime {
    assert(connection_count_max <= 256);

    assert(resp_reply_size_max <= connection_response_buffer_size);

    const connection_size = connection_request_buffer_size + connection_response_buffer_size;
    assert(connection_count_max * connection_size <= connection_memory_max);
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

pub const event_loop_wait_timeout_ms = 1000;

pub const io_in_flight_max = connection_count_max * 2 + 1;

pub const io_change_count_max = io_in_flight_max;
pub const io_event_count_max = io_in_flight_max;
pub const io_syscall_retry_max = 8;

pub const io_ring_capacity = 256;

comptime {
    assert(event_loop_wait_timeout_ms > 0);

    assert(io_ring_capacity >= io_in_flight_max);
    assert(io_ring_capacity & (io_ring_capacity - 1) == 0);
}

// ---------------------------------------------------------------------------
// Write-ahead log
// ---------------------------------------------------------------------------

pub const wal_buffer_size = 64 * 1024;

pub const wal_record_size_max = 16 * 1024 * 1024;

comptime {
    assert(resp_command_size_max <= wal_record_size_max);
}

fn digitCount(comptime value: u64) usize {
    return @as(usize, std.math.log10_int(value)) + 1;
}
