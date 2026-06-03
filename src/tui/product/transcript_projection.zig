const std = @import("std");
const transcript = @import("transcript.zig");

pub const RenderItem = struct {
    prefix: []const u8,
    text: []const u8,
};

pub fn itemPrimary(item: transcript.TranscriptItem) RenderItem {
    return switch (item) {
        .message => |message| .{ .prefix = rolePrefix(message.role), .text = message.text },
        .status => |status| .{ .prefix = statusPrefix(status.level), .text = status.text },
        .tool => |tool| .{ .prefix = toolPrefix(tool.status), .text = toolText(tool) },
    };
}

pub fn toolOmissionNotice(tool: transcript.TranscriptTool, buffer: *[96]u8) ?[]const u8 {
    if (tool.output_truncated_head_lines > 0) {
        return std.fmt.bufPrint(
            buffer,
            "... {d} earlier lines omitted ...",
            .{tool.output_truncated_head_lines},
        ) catch "... output omitted ...";
    }
    if (tool.output_truncated_head_bytes > 0) {
        return std.fmt.bufPrint(
            buffer,
            "... {d} earlier bytes omitted ...",
            .{tool.output_truncated_head_bytes},
        ) catch "... output omitted ...";
    }
    return null;
}

fn rolePrefix(role: transcript.TranscriptRole) []const u8 {
    return switch (role) {
        .user => "user: ",
        .assistant => "assistant: ",
        .system => "system: ",
    };
}

fn statusPrefix(level: transcript.TranscriptStatusLevel) []const u8 {
    return switch (level) {
        .info => "status: ",
        .warning => "warning: ",
        .err => "error: ",
    };
}

fn toolPrefix(status: transcript.TranscriptToolStatus) []const u8 {
    return switch (status) {
        .started => "tool started: ",
        .completed => "tool completed: ",
        .failed => "tool failed: ",
    };
}

fn toolText(tool: transcript.TranscriptTool) []const u8 {
    if (tool.output_preview.len > 0) return tool.output_preview;
    if (tool.subject.len > 0) return tool.subject;
    return tool.name;
}

test "transcript projection uses tool output before subject" {
    const item: transcript.TranscriptItem = .{ .tool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("bash"),
        .status = .started,
        .summary = @constCast("started"),
        .subject = @constCast("zig build"),
        .output_preview = @constCast("test output"),
    } };
    const projected = itemPrimary(item);
    try std.testing.expectEqualStrings("tool started: ", projected.prefix);
    try std.testing.expectEqualStrings("test output", projected.text);
}

test "transcript projection formats omission notice" {
    const tool: transcript.TranscriptTool = .{
        .tool_call_id = @constCast("1"),
        .name = @constCast("bash"),
        .status = .started,
        .summary = @constCast("started"),
        .subject = @constCast("zig build"),
        .output_preview = @constCast("tail"),
        .output_truncated_head_lines = 42,
    };
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("... 42 earlier lines omitted ...", toolOmissionNotice(tool, &buffer).?);
}
