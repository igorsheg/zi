/// AgentEvent JSON serialization for --mode json output.
/// Produces one JSON object per event, matching pi-mono's wire format.
/// pi-mono: session.subscribe(event => JSON.stringify(event)) in print-mode.ts:82-86
///
/// Delegates message body serialization to session/json.zig (shared writers).
const std = @import("std");
const protocol = @import("types.zig");
const session_json = @import("../session/json.zig");
const ai = @import("../ai/root.zig");

const Stringify = std.json.Stringify;

pub fn writeAgentEvent(writer: *std.Io.Writer, event: protocol.AgentEvent) !void {
    var jw: Stringify = .{ .writer = writer };

    try jw.beginObject();

    switch (event) {
        .agent_start => {
            try jw.objectField("type");
            try jw.write("agent_start");
        },
        .agent_end => |payload| {
            try jw.objectField("type");
            try jw.write("agent_end");
            try jw.objectField("messages");
            try jw.beginArray();
            for (payload.messages) |msg| {
                try session_json.writeAgentMessage(&jw, msg);
            }
            try jw.endArray();
        },
        .turn_start => {
            try jw.objectField("type");
            try jw.write("turn_start");
        },
        .turn_end => |payload| {
            try jw.objectField("type");
            try jw.write("turn_end");
            try jw.objectField("message");
            try session_json.writeAgentMessage(&jw, payload.message);
            try jw.objectField("toolResults");
            try jw.beginArray();
            for (payload.tool_results) |tr| {
                try writeToolResultMessage(&jw, tr);
            }
            try jw.endArray();
        },
        .message_start => |payload| {
            try jw.objectField("type");
            try jw.write("message_start");
            try jw.objectField("message");
            try session_json.writeAgentMessage(&jw, payload.message);
        },
        .message_update => |payload| {
            try jw.objectField("type");
            try jw.write("message_update");
            try jw.objectField("message");
            try session_json.writeAgentMessage(&jw, payload.message);
            try jw.objectField("assistantMessageEvent");
            try writeAssistantMessageEvent(&jw, payload.assistant_message_event);
        },
        .message_end => |payload| {
            try jw.objectField("type");
            try jw.write("message_end");
            try jw.objectField("message");
            try session_json.writeAgentMessage(&jw, payload.message);
        },
        .tool_execution_start => |payload| {
            try jw.objectField("type");
            try jw.write("tool_execution_start");
            try jw.objectField("toolCallId");
            try jw.write(payload.tool_call_id);
            try jw.objectField("toolName");
            try jw.write(payload.tool_name);
            try jw.objectField("args");
            try jw.write(payload.args);
        },
        .tool_execution_update => |payload| {
            try jw.objectField("type");
            try jw.write("tool_execution_update");
            try jw.objectField("toolCallId");
            try jw.write(payload.tool_call_id);
            try jw.objectField("toolName");
            try jw.write(payload.tool_name);
            try jw.objectField("args");
            try jw.write(payload.args);
            if (payload.partial_result) |pr| {
                try jw.objectField("partialResult");
                try writeAgentToolResult(&jw, pr);
            }
        },
        .tool_execution_end => |payload| {
            try jw.objectField("type");
            try jw.write("tool_execution_end");
            try jw.objectField("toolCallId");
            try jw.write(payload.tool_call_id);
            try jw.objectField("toolName");
            try jw.write(payload.tool_name);
            try jw.objectField("result");
            try writeAgentToolResult(&jw, payload.result);
            try jw.objectField("isError");
            try jw.write(payload.is_error);
        },
    }

    try jw.endObject();
}

fn writeAssistantMessageEvent(jw: *Stringify, event: ai.protocol.AssistantMessageEvent) !void {
    try jw.beginObject();
    switch (event) {
        .start => |payload| {
            try jw.objectField("type");
            try jw.write("start");
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .text_start => |payload| {
            try jw.objectField("type");
            try jw.write("text_start");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .text_delta => |payload| {
            try jw.objectField("type");
            try jw.write("text_delta");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("delta");
            try jw.write(payload.delta);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .text_end => |payload| {
            try jw.objectField("type");
            try jw.write("text_end");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("content");
            try jw.write(payload.content);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .thinking_start => |payload| {
            try jw.objectField("type");
            try jw.write("thinking_start");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .thinking_delta => |payload| {
            try jw.objectField("type");
            try jw.write("thinking_delta");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("delta");
            try jw.write(payload.delta);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .thinking_end => |payload| {
            try jw.objectField("type");
            try jw.write("thinking_end");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("content");
            try jw.write(payload.content);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .toolcall_start => |payload| {
            try jw.objectField("type");
            try jw.write("toolcall_start");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .toolcall_delta => |payload| {
            try jw.objectField("type");
            try jw.write("toolcall_delta");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("delta");
            try jw.write(payload.delta);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .toolcall_end => |payload| {
            try jw.objectField("type");
            try jw.write("toolcall_end");
            try jw.objectField("contentIndex");
            try jw.write(payload.content_index);
            try jw.objectField("toolCall");
            try session_json.writeToolCallBlock(jw, payload.tool_call);
            try jw.objectField("partial");
            try session_json.writeAssistantMessage(jw, payload.partial);
        },
        .done => |payload| {
            try jw.objectField("type");
            try jw.write("done");
            try jw.objectField("reason");
            try jw.write(@tagName(payload.reason));
            try jw.objectField("message");
            try session_json.writeAssistantMessage(jw, payload.message);
        },
        .@"error" => |payload| {
            try jw.objectField("type");
            try jw.write("error");
            try jw.objectField("reason");
            try jw.write(@tagName(payload.reason));
            try jw.objectField("error");
            try session_json.writeAssistantMessage(jw, payload.@"error");
        },
    }
    try jw.endObject();
}

fn writeAgentToolResult(jw: *Stringify, result: protocol.AgentToolResult) !void {
    try jw.beginObject();
    try jw.objectField("content");
    try jw.beginArray();
    for (result.content) |block| {
        switch (block) {
            .text => |tc| try session_json.writeTextBlock(jw, tc),
            .image => |ic| try session_json.writeImageBlock(jw, ic),
        }
    }
    try jw.endArray();
    try jw.objectField("isError");
    try jw.write(result.is_error);
    if (result.details != .null) {
        try jw.objectField("details");
        try jw.write(result.details);
    }
    if (result.presentation != .null) {
        try jw.objectField("presentation");
        try jw.write(result.presentation);
    }
    try jw.endObject();
}

fn writeToolResultMessage(jw: *Stringify, msg: ai.protocol.ToolResultMessage) !void {
    try session_json.writeToolResultMessage(jw, msg);
}
