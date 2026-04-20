const agent_mod = @import("../agent3/root.zig");

pub const RetryStart = struct {
    attempt: u32,
    max_attempts: u32,
    delay_ms: u64,
    error_message: []const u8,
};

pub const RetryEnd = struct {
    success: bool,
    attempt: u32,
    final_error: ?[]const u8 = null,
};

pub const CompactionReason = enum {
    overflow,
    threshold,
    manual,
};

pub const CompactionEnd = struct {
    reason: CompactionReason,
    success: bool,
    will_retry: bool,
    error_message: ?[]const u8 = null,
};

pub const SessionEvent = union(enum) {
    agent: agent_mod.protocol.AgentEvent,
    auto_retry_start: RetryStart,
    auto_retry_wait_finished: void,
    auto_retry_end: RetryEnd,
    compaction_end: CompactionEnd,
};
