const std = @import("std");

const coding_agent = @import("../../coding_agent/root.zig");
const tui = @import("../../tui/root.zig");

const vm = coding_agent.view_model;

const retry_reason_bytes_max: usize = 64;

pub const notify_key_cancel: tui.notify.Key = 1;
pub const notify_key_recovery: tui.notify.Key = 2;
pub const notify_key_operation_failure: tui.notify.Key = 4;
pub const notify_key_retry: tui.notify.Key = 5;

pub const Copy = struct {
    text: []const u8,
    level: tui.notify.Level,
    annote: ?[]const u8 = null,
    tone: ?tui.status.Tone = null,
    ttl_ms: ?i64 = null,
    key: ?tui.notify.Key = null,
};

pub fn noticeCopy(buffer: []u8, notice: vm.Notice) Copy {
    const raw = notice.text.slice();
    var copy = if (notice.failure_category) |category| failureCategoryCopy(category) else semanticCopy(notice.semantic);
    copy.text = if (raw.len > 0) raw else copy.text;
    if (copy.level == .debug) copy.level = levelFor(notice);
    if (copy.key == null) copy.key = @intCast(@min(notice.id, std.math.maxInt(u32)));
    _ = buffer;
    return copy;
}

pub fn retryStatus(
    buffer: []u8,
    attempt: u32,
    max_attempts: u32,
    delay_ms: u64,
    reason_raw: []const u8,
) []const u8 {
    const reason = tui.text.utf8Prefix(reason_raw, retry_reason_bytes_max);
    if (reason.len == 0) {
        return std.fmt.bufPrint(
            buffer,
            "retry {d}/{d} in {d}ms",
            .{ attempt, max_attempts, delay_ms },
        ) catch "retrying";
    }
    return std.fmt.bufPrint(buffer, "retry {d}/{d} in {d}ms: {s}", .{
        attempt,
        max_attempts,
        delay_ms,
        reason,
    }) catch "retrying";
}

pub fn queueFull(buffer: []u8, capacity: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "prompt queue full ({d})", .{capacity}) catch "prompt queue full";
}

fn semanticCopy(semantic: vm.NoticeSemantic) Copy {
    return switch (semantic) {
        .generic => .{ .text = "notice", .level = .debug },
        .notices_dropped => .{ .text = "some notices were dropped", .level = .warning },
        .operation_failed => .{
            .text = "Operation failed",
            .level = .err,
            .annote = "error",
            .tone = .err,
            .ttl_ms = 10_000,
            .key = notify_key_operation_failure,
        },
        .retry_start => .{
            .text = "retrying",
            .level = .warning,
            .annote = "retry",
            .tone = .warning,
            .ttl_ms = 5_000,
            .key = notify_key_retry,
        },
        .retry_end => .{
            .text = "retry failed",
            .level = .err,
            .annote = "retry",
            .tone = .err,
            .ttl_ms = 10_000,
            .key = notify_key_retry,
        },
        .queue_full => .{ .text = "prompt queue full", .level = .warning, .annote = null, .tone = .warning },
        .command_queue_full => .{ .text = "command queue full", .level = .warning, .annote = null, .tone = .warning },
        .cancel_requested => .{
            .text = "cancel requested",
            .level = .info,
            .annote = "",
            .tone = .canceled,
            .ttl_ms = 3_000,
            .key = notify_key_cancel,
        },
        .cancel_done => .{
            .text = "canceled",
            .level = .info,
            .annote = "",
            .tone = .canceled,
            .ttl_ms = 3_000,
            .key = notify_key_cancel,
        },
        .recovering_event_gap => .{
            .text = "recovering event gap",
            .level = .warning,
            .annote = null,
            .tone = .warning,
            .ttl_ms = 10_000,
            .key = notify_key_recovery,
        },
        .terminal_bell => .{ .text = "terminal bell", .level = .info },
    };
}

fn failureCategoryCopy(category: vm.NoticeFailureCategory) Copy {
    return switch (category) {
        .auth_missing => failure("Missing provider credentials", "auth", .err, .err, 15_000),
        .auth_rejected => failure("Provider rejected credentials", "auth", .err, .err, 15_000),
        .rate_limited => failure("Provider rate limit exceeded", "rate", .warning, .warning, 10_000),
        .context_overflow => failure("Request exceeds model context window", "context", .warning, .warning, 12_000),
        .provider_unavailable => failure("Provider service unavailable", "provider", .warning, .warning, 10_000),
        .transport => failure("Network request failed", "network", .warning, .warning, 10_000),
        .malformed_response => failure("Provider response could not be read", "provider", .err, .err, 10_000),
        .canceled => failure("Canceled", "cancel", .info, .canceled, 3_000),
        .unknown => failure("Operation failed", "error", .err, .err, 10_000),
    };
}

fn failure(
    text: []const u8,
    annote: []const u8,
    level: tui.notify.Level,
    tone: tui.status.Tone,
    ttl_ms: i64,
) Copy {
    return .{
        .text = text,
        .level = level,
        .annote = annote,
        .tone = tone,
        .ttl_ms = ttl_ms,
        .key = notify_key_operation_failure,
    };
}

fn levelFor(notice: vm.Notice) tui.notify.Level {
    return switch (notice.severity) {
        .info => .info,
        .warn => .warning,
        .err => .err,
    };
}

test "notice copy uses semantic fallback and severity" {
    const notice: vm.Notice = .{ .severity = .err, .semantic = .operation_failed };
    var buffer: [128]u8 = undefined;
    const copy = noticeCopy(&buffer, notice);
    try std.testing.expectEqualStrings("Operation failed", copy.text);
    try std.testing.expectEqual(tui.notify.Level.err, copy.level);
}

test "notice copy keeps engine detail text" {
    var notice: vm.Notice = .{ .severity = .warn, .semantic = .queue_full };
    notice.text.set("operation already active");
    var buffer: [128]u8 = undefined;
    const copy = noticeCopy(&buffer, notice);
    try std.testing.expectEqualStrings("operation already active", copy.text);
    try std.testing.expectEqual(tui.notify.Level.warning, copy.level);
}

test "operation failure categories carry old notify semantics" {
    const notice: vm.Notice = .{ .severity = .warn, .semantic = .operation_failed, .failure_category = .rate_limited };
    var buffer: [128]u8 = undefined;
    const copy = noticeCopy(&buffer, notice);
    try std.testing.expectEqualStrings("Provider rate limit exceeded", copy.text);
    try std.testing.expectEqualStrings("rate", copy.annote.?);
    try std.testing.expectEqual(@as(i64, 10_000), copy.ttl_ms.?);
    try std.testing.expectEqual(tui.status.Tone.warning, copy.tone.?);
    try std.testing.expectEqual(notify_key_operation_failure, copy.key.?);
}

test "queue full rejection uses bounded friendly text" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("prompt queue full (128)", queueFull(&buffer, 128));
}

test "retry status includes bounded reason" {
    var buffer: [128]u8 = undefined;
    const text = retryStatus(&buffer, 2, 3, 250, "provider overloaded");
    try std.testing.expectEqualStrings("retry 2/3 in 250ms: provider overloaded", text);
}
