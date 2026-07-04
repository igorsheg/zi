const std = @import("std");

const coding_agent = @import("../../coding_agent/root.zig");
const tui = @import("../../tui/root.zig");

const vm = coding_agent.view_model;

const retry_reason_bytes_max: usize = 64;

pub const Copy = struct {
    text: []const u8,
    level: tui.notify.Level,
};

pub fn noticeCopy(buffer: []u8, notice: vm.Notice) Copy {
    _ = buffer;
    const raw = notice.text.slice();
    const text = if (raw.len > 0) raw else defaultText(notice.semantic);
    return .{ .text = text, .level = levelFor(notice) };
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

fn defaultText(semantic: vm.NoticeSemantic) []const u8 {
    return switch (semantic) {
        .generic => "notice",
        .notices_dropped => "some notices were dropped",
        .operation_failed => "Operation failed",
        .retry_start => "retrying",
        .retry_end => "retry finished",
        .queue_full => "prompt queue full",
        .terminal_bell => "terminal bell",
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

test "queue full rejection uses bounded friendly text" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("prompt queue full (128)", queueFull(&buffer, 128));
}

test "retry status includes bounded reason" {
    var buffer: [128]u8 = undefined;
    const text = retryStatus(&buffer, 2, 3, 250, "provider overloaded");
    try std.testing.expectEqualStrings("retry 2/3 in 250ms: provider overloaded", text);
}
