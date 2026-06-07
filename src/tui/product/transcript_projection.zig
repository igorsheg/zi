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
        .tool => |tool| .{ .prefix = "", .text = toolText(tool) },
    };
}

pub fn toolTitle(tool: transcript.TranscriptTool, buffer: *[160]u8) []const u8 {
    if (tool.title.len == 0) return tool.name;
    const separator = ": ";
    if (tool.name.len + separator.len >= buffer.len) return tool.name;
    const title_capacity = buffer.len - tool.name.len - separator.len;
    const title = utf8Prefix(tool.title, title_capacity);
    return std.fmt.bufPrint(buffer, "{s}: {s}", .{ tool.name, title }) catch tool.name;
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and (value[end] & 0xc0) == 0x80) : (end -= 1) {}
    return value[0..end];
}

pub fn toolHeader(tool: transcript.TranscriptTool) []const u8 {
    return switch (tool.status) {
        .pending => "running",
        .err => "error",
        .success => switch (tool.presentation) {
            .command => "stdout",
            .file => "file",
            .patch => "patch",
            .search, .directory, .generic => "tool",
        },
    };
}

pub fn toolBodyVisible(tool: transcript.TranscriptTool) bool {
    if (tool.output_preview.len == 0) return false;
    return switch (tool.body_mode) {
        .visible => true,
        .hidden_on_success => tool.status != .success,
    };
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
        .user, .assistant => "",
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

fn toolText(tool: transcript.TranscriptTool) []const u8 {
    return tool.output_preview;
}

test "transcript projection uses visible tool output" {
    const item: transcript.TranscriptItem = .{ .tool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("bash"),
        .presentation = .command,
        .status = .pending,
        .body_mode = .visible,
        .title = @constCast("$ zig build"),
        .call_preview = @constCast(""),
        .output_preview = @constCast("test output"),
    } };
    const projected = itemPrimary(item);
    try std.testing.expectEqualStrings("", projected.prefix);
    try std.testing.expectEqualStrings("test output", projected.text);
    var title_buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings("bash: $ zig build", toolTitle(item.tool, &title_buffer));
    try std.testing.expectEqualStrings("running", toolHeader(item.tool));
}

test "transcript projection truncates long tool title instead of dropping it" {
    var title: [512]u8 = undefined;
    @memset(&title, 'x');
    const tool: transcript.TranscriptTool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("bash"),
        .presentation = .command,
        .status = .pending,
        .body_mode = .visible,
        .title = &title,
        .call_preview = @constCast(""),
        .output_preview = @constCast(""),
    };
    var buffer: [160]u8 = undefined;
    const rendered = toolTitle(tool, &buffer);
    try std.testing.expectEqual(@as(usize, 160), rendered.len);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "bash: xxx"));
}

test "transcript projection hides successful read body" {
    const tool: transcript.TranscriptTool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("read"),
        .presentation = .file,
        .status = .success,
        .body_mode = .hidden_on_success,
        .title = @constCast("read src/main.zig"),
        .call_preview = @constCast(""),
        .output_preview = @constCast("file contents"),
    };
    try std.testing.expect(!toolBodyVisible(tool));
}

test "transcript projection formats omission notice" {
    const tool: transcript.TranscriptTool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("bash"),
        .presentation = .command,
        .status = .success,
        .body_mode = .visible,
        .title = @constCast("$ zig build"),
        .call_preview = @constCast(""),
        .output_preview = @constCast("tail"),
        .output_truncated_head_lines = 42,
    };
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("· ··· 42 earlier lines", toolOmissionNotice(tool, &buffer).?);
}
