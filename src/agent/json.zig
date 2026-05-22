const std = @import("std");
const event = @import("event.zig");
const message = @import("message.zig");
const ai = @import("../ai/root.zig");

pub fn writeEvent(jw: *std.json.Stringify, value: event.AgentEvent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    switch (value) {
        .lifecycle => |lifecycle| switch (lifecycle) {
            .run_started => try jw.write("runStarted"),
            .turn_started => try jw.write("turnStarted"),
            .run_finished => |terminal| {
                try jw.write("runFinished");
                try jw.objectField("terminal");
                try writeRunTerminal(jw, terminal);
            },
            .turn_finished => |terminal| {
                try jw.write("turnFinished");
                try jw.objectField("terminal");
                try writeTurnTerminal(jw, terminal);
            },
        },
        .message => |message_event| switch (message_event) {
            .started => try jw.write("messageStarted"),
            .delta => |delta| {
                try jw.write("messageDelta");
                try jw.objectField("delta");
                try writeAssistantMessageEvent(jw, delta);
            },
            .finished => |assistant| {
                try jw.write("messageFinished");
                try jw.objectField("message");
                try writeAssistantMessageSummary(jw, assistant);
            },
        },
        .tool => |tool| switch (tool) {
            .started => |started| {
                try jw.write("toolStarted");
                try jw.objectField("opId");
                try jw.write(started.op_id);
                try jw.objectField("toolCallId");
                try jw.write(started.tool_call_id);
                try jw.objectField("toolName");
                try jw.write(started.tool_name);
            },
            .update => |update| {
                try jw.write("toolUpdate");
                try jw.objectField("opId");
                try jw.write(update.op_id);
                try jw.objectField("toolCallId");
                try jw.write(update.tool_call_id);
                try jw.objectField("toolName");
                try jw.write(update.tool_name);
                try jw.objectField("isError");
                try jw.write(update.partial_result.is_error);
                try jw.objectField("contentBlocks");
                try jw.write(update.partial_result.content.len);
            },
            .finished => |finished| {
                try jw.write("toolFinished");
                try jw.objectField("opId");
                try jw.write(finished.op_id);
                try jw.objectField("toolCallId");
                try jw.write(finished.tool_call_id);
                try jw.objectField("toolName");
                try jw.write(finished.tool_name);
                try jw.objectField("terminal");
                try jw.write(@tagName(finished.terminal));
            },
        },
    }
    try jw.endObject();
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

fn writeAssistantMessageSummary(jw: *std.json.Stringify, assistant: message.AssistantMessage) !void {
    try jw.beginObject();
    try jw.objectField("api");
    try jw.write(ai.protocol.apiToString(assistant.api));
    try jw.objectField("provider");
    try jw.write(ai.protocol.providerToString(assistant.provider));
    try jw.objectField("model");
    try jw.write(assistant.model);
    try jw.objectField("stopReason");
    try jw.write(ai.protocol.stopReasonToString(assistant.stop_reason));
    try jw.objectField("contentBlocks");
    try jw.write(assistant.content.len);
    try jw.endObject();
}

fn writeRunTerminal(jw: *std.json.Stringify, terminal: event.RunTerminal) !void {
    return writeTerminalTag(jw, switch (terminal) {
        .completed => "completed",
        .failed => "failed",
        .aborted => "aborted",
    });
}

fn writeTurnTerminal(jw: *std.json.Stringify, terminal: event.TurnTerminal) !void {
    return writeTerminalTag(jw, switch (terminal) {
        .completed => "completed",
        .failed => "failed",
        .aborted => "aborted",
    });
}

fn writeTerminalTag(jw: *std.json.Stringify, tag: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("status");
    try jw.write(tag);
    try jw.endObject();
}

test "writes run terminal event status" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try writeEvent(&jw, .{ .lifecycle = .{ .run_finished = .{ .aborted = .{ .messages = &.{} } } } });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "aborted") != null);
}

test "writes assistant text delta payload" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try writeEvent(&jw, .{ .message = .{ .delta = .{ .text_delta = .{ .content_index = 0, .delta = "hello" } } } });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "messageDelta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "textDelta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "hello") != null);
}
