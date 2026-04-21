const std = @import("std");

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

pub const CompactionStart = struct {
    reason: CompactionReason,
};

pub const CompactionResult = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    details: ?std.json.Value = null,
    from_hook: ?bool = null,
};

pub const CompactionEnd = struct {
    reason: CompactionReason,
    success: bool,
    result: ?CompactionResult = null,
    aborted: bool = false,
    will_retry: bool,
    error_message: ?[]const u8 = null,
};

pub const SessionEvent = union(enum) {
    auto_retry_start: RetryStart,
    auto_retry_wait_finished: void,
    auto_retry_end: RetryEnd,
    compaction_start: CompactionStart,
    compaction_end: CompactionEnd,
};
