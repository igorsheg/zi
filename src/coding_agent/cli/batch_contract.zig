const std = @import("std");
const ai_protocol = @import("../../ai/protocol.zig");
const agent_protocol = @import("../../agent2/protocol.zig");
const session_protocol = @import("../../session/protocol.zig");

pub const TextModeResult = union(enum) {
    none,
    success: ai_protocol.AssistantMessage,
    failure: []const u8,
};

pub fn evaluateTextModeResult(allocator: std.mem.Allocator, messages: []const agent_protocol.AgentMessage) !TextModeResult {
    const assistant = lastAssistantMessage(messages) orelse return .none;
    return switch (assistant.stop_reason) {
        .@"error", .aborted => .{ .failure = if (assistant.error_message) |message|
            try allocator.dupe(u8, message)
        else
            try std.fmt.allocPrint(allocator, "Request {s}", .{@tagName(assistant.stop_reason)}) },
        else => .{ .success = assistant },
    };
}

pub fn writeAssistantText(writer: *std.io.Writer, assistant: ai_protocol.AssistantMessage) !void {
    for (assistant.content) |content| {
        switch (content) {
            .text => |text| try writer.print("{s}\n", .{text.text}),
            else => {},
        }
    }
}

pub fn writeJsonSessionPreamble(writer: *std.io.Writer, header: ?session_protocol.SessionHeader) !void {
    const session_header = header orelse return;
    var jw: std.json.Stringify = .{ .writer = writer };
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("session");
    try jw.objectField("version");
    try jw.write(session_header.version);
    try jw.objectField("id");
    try jw.write(session_header.id);
    try jw.objectField("timestamp");
    try jw.write(session_header.timestamp);
    try jw.objectField("cwd");
    try jw.write(session_header.cwd);
    if (session_header.parent_session) |parent_session| {
        try jw.objectField("parentSession");
        try jw.write(parent_session);
    }
    try jw.endObject();
    try writer.writeAll("\n");
}

fn lastAssistantMessage(messages: []const agent_protocol.AgentMessage) ?ai_protocol.AssistantMessage {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        switch (messages[i]) {
            .assistant => |assistant| return assistant,
            else => {},
        }
    }
    return null;
}

test "batch text mode prints only the final assistant text blocks" {
    const assistant = ai_protocol.AssistantMessage{
        .content = &.{
            .{ .thinking = .{ .thinking = "hidden" } },
            .{ .text = .{ .text = "final answer" } },
            .{ .text = .{ .text = "second paragraph" } },
        },
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-5",
        .usage = .{
            .input = 1,
            .output = 2,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 3,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const messages = [_]agent_protocol.AgentMessage{
        .{ .assistant = .{
            .content = &.{.{ .text = .{ .text = "draft" } }},
            .api = .openai_responses,
            .provider = .openai,
            .model = "gpt-5",
            .usage = assistant.usage,
            .stop_reason = .stop,
            .timestamp = 0,
        } },
        .{ .assistant = assistant },
    };

    const evaluation = try evaluateTextModeResult(std.testing.allocator, &messages);
    switch (evaluation) {
        .success => |final_assistant| {
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try writeAssistantText(&out.writer, final_assistant);
            const rendered = try out.toOwnedSlice();
            defer std.testing.allocator.free(rendered);
            try std.testing.expectEqualStrings("final answer\nsecond paragraph\n", rendered);
        },
        else => return error.UnexpectedTextModeResult,
    }
}

test "batch text mode failure comes from the final assistant state" {
    const errored = [_]agent_protocol.AgentMessage{.{ .assistant = .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-5",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = .@"error",
        .error_message = "provider failed",
        .timestamp = 0,
    } }};
    switch (try evaluateTextModeResult(std.testing.allocator, &errored)) {
        .failure => |message| {
            defer std.testing.allocator.free(message);
            try std.testing.expectEqualStrings("provider failed", message);
        },
        else => return error.UnexpectedTextModeResult,
    }

    const aborted = [_]agent_protocol.AgentMessage{.{ .assistant = .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-5",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = .aborted,
        .timestamp = 0,
    } }};
    switch (try evaluateTextModeResult(std.testing.allocator, &aborted)) {
        .failure => |message| {
            defer std.testing.allocator.free(message);
            try std.testing.expectEqualStrings("Request aborted", message);
        },
        else => return error.UnexpectedTextModeResult,
    }
}

test "batch json mode emits the session header line when present" {
    const header = session_protocol.SessionHeader{
        .id = "session-123",
        .timestamp = "2026-04-15T10:00:00.000Z",
        .cwd = "/tmp/project",
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeJsonSessionPreamble(&out.writer, header);
    try writeJsonSessionPreamble(&out.writer, null);

    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"type\":\"session\",\"version\":3,\"id\":\"session-123\",\"timestamp\":\"2026-04-15T10:00:00.000Z\",\"cwd\":\"/tmp/project\"}\n",
        rendered,
    );
}
