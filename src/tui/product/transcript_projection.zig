const std = @import("std");
const chrome = @import("chrome.zig");
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

// The adapter formats the full pi-mono-style header into `title`
// ("$ cmd", "read path:1-20", ...); the tool name is only a fallback.
pub fn toolTitle(tool: transcript.TranscriptTool, buffer: *[160]u8) []const u8 {
    if (tool.title.len == 0) return tool.name;
    return utf8Prefix(tool.title, buffer.len);
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

pub fn toolBodyVisible(tool: transcript.TranscriptTool, expanded: bool) bool {
    if (tool.output_preview.len == 0) return false;
    return switch (tool.body_mode) {
        .visible => true,
        .hidden_on_success => expanded or tool.status != .success,
    };
}

/// Hint row shown when the collapsed window hides body rows.
/// Wording mirrors pi-mono: tail windows hide *earlier* lines, head windows
/// hide the *remaining* lines.
pub fn collapseHint(
    buffer: []u8,
    mode: transcript.TranscriptToolCollapseMode,
    hidden_rows: usize,
) []const u8 {
    const result = switch (mode) {
        .tail => std.fmt.bufPrint(buffer, "... ({d} earlier lines, ctrl+o to expand)", .{hidden_rows}),
        .head => std.fmt.bufPrint(buffer, "... ({d} more lines, ctrl+o to expand)", .{hidden_rows}),
    };
    return result catch "... (ctrl+o to expand)";
}

pub fn toolOmissionNotice(tool: transcript.TranscriptTool, buffer: *[96]u8) ?[]const u8 {
    return chrome.elisionLine(
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
