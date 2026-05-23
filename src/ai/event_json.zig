const std = @import("std");
const event = @import("root.zig").protocol;
const message = event;

pub fn writeEvent(jw: *std.json.Stringify, value: event.AgentEvent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    switch (value) {
        .agent_start => try jw.write("agent_start"),
        .agent_end => |terminal| {
            try jw.write("agent_end");
            try jw.objectField("status");
            try jw.write(@tagName(terminal));
        },
        .turn_start => try jw.write("turn_start"),
        .turn_end => |terminal| {
            try jw.write("turn_end");
            try jw.objectField("status");
            try jw.write(@tagName(terminal));
        },
        .message_start => try jw.write("message_start"),
        .message_update => |update| {
            try jw.write("message_update");
            try jw.objectField("delta");
            try writeAssistantMessageEvent(jw, update.assistant_message_event);
        },
        .message_end => |end| {
            try jw.write("message_end");
            try jw.objectField("messageRole");
            try jw.write(@tagName(end.message));
        },
        .tool_execution_start => |started| {
            try jw.write("tool_execution_start");
            try writeToolIds(jw, started.op_id, started.tool_call_id, started.tool_name);
        },
        .tool_execution_update => |update| {
            try jw.write("tool_execution_update");
            try writeToolIds(jw, update.op_id, update.tool_call_id, update.tool_name);
            try jw.objectField("isError");
            try jw.write(update.partial_result.is_error);
        },
        .tool_execution_end => |end| {
            try jw.write("tool_execution_end");
            try writeToolIds(jw, end.op_id, end.tool_call_id, end.tool_name);
            try jw.objectField("isError");
            try jw.write(end.is_error);
        },
    }
    try jw.endObject();
}

fn writeToolIds(jw: *std.json.Stringify, op_id: u64, tool_call_id: []const u8, tool_name: []const u8) !void {
    try jw.objectField("opId");
    try jw.write(op_id);
    try jw.objectField("toolCallId");
    try jw.write(tool_call_id);
    try jw.objectField("toolName");
    try jw.write(tool_name);
}

fn writeAssistantMessageEvent(jw: *std.json.Stringify, value: message.AssistantMessageEvent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    switch (value) {
        .start => try jw.write("start"),
        .text_start => |payload| try writeIndexedEvent(jw, "textStart", payload.content_index),
        .text_delta => |payload| {
            try writeIndexedEvent(jw, "textDelta", payload.content_index);
            try jw.objectField("delta");
            try jw.write(payload.delta);
        },
        .text_end => |payload| {
            try writeIndexedEvent(jw, "textEnd", payload.content_index);
            try jw.objectField("content");
            try jw.write(payload.content);
        },
        .thinking_start => |payload| try writeIndexedEvent(jw, "thinkingStart", payload.content_index),
        .thinking_delta => |payload| {
            try writeIndexedEvent(jw, "thinkingDelta", payload.content_index);
            try jw.objectField("delta");
            try jw.write(payload.delta);
        },
        .thinking_end => |payload| {
            try writeIndexedEvent(jw, "thinkingEnd", payload.content_index);
            try jw.objectField("content");
            try jw.write(payload.content);
        },
        .toolcall_start => |payload| try writeIndexedEvent(jw, "toolCallStart", payload.content_index),
        .toolcall_delta => |payload| {
            try writeIndexedEvent(jw, "toolCallDelta", payload.content_index);
            try jw.objectField("delta");
            try jw.write(payload.delta);
        },
        .toolcall_end => |payload| {
            try writeIndexedEvent(jw, "toolCallEnd", payload.content_index);
            try jw.objectField("toolCallId");
            try jw.write(payload.tool_call.id);
            try jw.objectField("toolName");
            try jw.write(payload.tool_call.name);
            try jw.objectField("arguments");
            try jw.write(payload.tool_call.arguments.borrowed());
        },
        .done => |payload| {
            try jw.write("done");
            try jw.objectField("reason");
            try jw.write(@tagName(payload.reason));
        },
        .@"error" => |payload| {
            try jw.write("error");
            try jw.objectField("reason");
            try jw.write(@tagName(payload.reason));
            if (payload.@"error".error_message) |err| {
                try jw.objectField("message");
                try jw.write(err);
            }
        },
    }
    try jw.endObject();
}

fn writeIndexedEvent(jw: *std.json.Stringify, event_type: []const u8, content_index: usize) !void {
    try jw.write(event_type);
    try jw.objectField("contentIndex");
    try jw.write(content_index);
}

test "writes agent end event" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try writeEvent(&jw, .{ .agent_end = .{ .completed = .{ .messages = &.{} } } });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "agent_end") != null);
}

test "writes assistant text delta payload" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try writeEvent(&jw, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{ .content_index = 0, .delta = "hello" } } } }); // ziglint-ignore: Z024
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "message_update") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "textDelta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "hello") != null);
}
