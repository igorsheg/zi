const std = @import("std");
const agent = @import("../agent/root.zig");

pub const text_bytes_max: usize = 160;

pub const VisibleLine = struct {
    text: []const u8,
};

pub fn lineFromAgentEvent(buffer: *[text_bytes_max]u8, event: agent.AgentEvent) ?VisibleLine {
    return switch (event) {
        .tool_execution_start => |payload| format("tool {s} started", buffer, .{payload.tool_name}),
        .tool_execution_end => |payload| if (payload.is_error)
            format("tool {s} failed", buffer, .{payload.tool_name})
        else
            format("tool {s} completed", buffer, .{payload.tool_name}),
        .tool_execution_update => null,
        else => null,
    };
}

fn format(comptime fmt: []const u8, buffer: *[text_bytes_max]u8, args: anytype) VisibleLine {
    const text = std.fmt.bufPrint(buffer, fmt, args) catch blk: {
        const fallback = "tool status unavailable";
        @memcpy(buffer[0..fallback.len], fallback);
        break :blk buffer[0..fallback.len];
    };
    return .{ .text = text };
}

test "public display formats tool start and end lines" {
    var buffer: [text_bytes_max]u8 = undefined;
    const start = lineFromAgentEvent(&buffer, .{ .tool_execution_start = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .args = .null,
    } }).?;
    try std.testing.expectEqualStrings("tool bash started", start.text);

    const ok = lineFromAgentEvent(&buffer, .{ .tool_execution_end = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .result = .{ .content = &.{} },
        .is_error = false,
    } }).?;
    try std.testing.expectEqualStrings("tool bash completed", ok.text);

    const failed = lineFromAgentEvent(&buffer, .{ .tool_execution_end = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .result = .{ .content = &.{} },
        .is_error = true,
    } }).?;
    try std.testing.expectEqualStrings("tool bash failed", failed.text);
}

test "public display ignores tool updates" {
    var buffer: [text_bytes_max]u8 = undefined;
    try std.testing.expect(lineFromAgentEvent(&buffer, .{ .tool_execution_update = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .args = .null,
        .partial_result = .{ .content = &.{} },
    } }) == null);
}
