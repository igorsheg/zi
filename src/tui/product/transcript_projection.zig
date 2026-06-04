const std = @import("std");
const primitive = @import("../primitive/root.zig");
const transcript = @import("transcript.zig");

pub const RenderItem = struct {
    prefix: []const u8,
    text: []const u8,
};

pub fn itemPrimary(item: transcript.TranscriptItem) RenderItem {
    return switch (item) {
        .message => |message| .{ .prefix = rolePrefix(message.role), .text = message.text },
        .status => |status| .{ .prefix = statusPrefix(status.level), .text = status.text },
        .tool => |tool| .{ .prefix = toolPrefix(tool.event), .text = toolText(tool) },
    };
}

pub fn toolTitle(tool: transcript.TranscriptTool, buffer: *[128]u8) []const u8 {
    if (tool.args_preview.len == 0) return tool.name;
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ tool.name, tool.args_preview }) catch tool.name;
}

pub fn toolOmissionNotice(tool: transcript.TranscriptTool, buffer: *[96]u8) ?[]const u8 {
    return primitive.chrome.elisionLine(
        buffer,
        tool.output_truncated_head_lines,
        tool.output_truncated_head_bytes,
    ) catch "· ··· output omitted";
}

fn rolePrefix(role: transcript.TranscriptRole) []const u8 {
    return switch (role) {
        .user => "user: ",
        .assistant => "assistant: ",
        .system => "system: ",
        .thinking => "thinking: ",
    };
}

fn statusPrefix(level: transcript.TranscriptStatusLevel) []const u8 {
    return switch (level) {
        .info => "status: ",
        .warning => "warning: ",
        .err => "error: ",
    };
}

fn toolPrefix(_: transcript.TranscriptToolEvent) []const u8 {
    return "";
}

fn toolText(tool: transcript.TranscriptTool) []const u8 {
    return tool.output_preview;
}

test "transcript projection uses tool output before args_preview" {
    const item: transcript.TranscriptItem = .{ .tool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("bash"),
        .event = .tool_execution_start,
        .args_preview = @constCast("zig build"),
        .output_preview = @constCast("test output"),
    } };
    const projected = itemPrimary(item);
    try std.testing.expectEqualStrings("", projected.prefix);
    try std.testing.expectEqualStrings("test output", projected.text);
}

test "transcript projection formats omission notice" {
    const tool: transcript.TranscriptTool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("bash"),
        .event = .tool_execution_start,
        .args_preview = @constCast("zig build"),
        .output_preview = @constCast("tail"),
        .output_truncated_head_lines = 42,
    };
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("· ··· 42 earlier lines", toolOmissionNotice(tool, &buffer).?);
}
