const std = @import("std");
const agent_protocol = @import("../../agent/types.zig");
const ai = @import("../../ai/root.zig");
const session_core = @import("../../session/root.zig");
const lua_runtime = @import("lua_runtime.zig");

const c = lua_runtime.c;

fn pushStringField(L: *c.lua_State, field: [:0]const u8, value: []const u8) void {
    _ = c.lua_pushlstring(L, value.ptr, value.len);
    c.lua_setfield(L, -2, field.ptr);
}

fn pushOptionalStringField(L: *c.lua_State, field: [:0]const u8, value: ?[]const u8) void {
    if (value) |s| _ = c.lua_pushlstring(L, s.ptr, s.len) else c.lua_pushnil(L);
    c.lua_setfield(L, -2, field.ptr);
}

fn pushBoolField(L: *c.lua_State, field: [:0]const u8, value: bool) void {
    c.lua_pushboolean(L, if (value) 1 else 0);
    c.lua_setfield(L, -2, field.ptr);
}

fn pushIntField(L: *c.lua_State, field: [:0]const u8, value: anytype) void {
    c.lua_pushinteger(L, @intCast(value));
    c.lua_setfield(L, -2, field.ptr);
}

fn pushNumberField(L: *c.lua_State, field: [:0]const u8, value: f64) void {
    c.lua_pushnumber(L, value);
    c.lua_setfield(L, -2, field.ptr);
}

fn apiToString(api: ai.protocol.Api) []const u8 {
    return switch (api) {
        .openai_completions => "openai_completions",
        .mistral_conversations => "mistral_conversations",
        .openai_responses => "openai_responses",
        .azure_openai_responses => "azure_openai_responses",
        .openai_codex_responses => "openai_codex_responses",
        .anthropic_messages => "anthropic_messages",
        .bedrock_converse_stream => "bedrock_converse_stream",
        .google_generative_ai => "google_generative_ai",
        .google_gemini_cli => "google_gemini_cli",
        .google_vertex => "google_vertex",
        .custom => |s| s,
    };
}

pub fn pushCostToLua(L: *c.lua_State, cost: ai.protocol.Usage.Cost) void {
    c.lua_createtable(L, 0, 7);
    pushNumberField(L, "input", cost.input);
    pushNumberField(L, "output", cost.output);
    pushNumberField(L, "cacheRead", cost.cache_read);
    pushNumberField(L, "cache_read", cost.cache_read);
    pushNumberField(L, "cacheWrite", cost.cache_write);
    pushNumberField(L, "cache_write", cost.cache_write);
    pushNumberField(L, "total", cost.total);
}

pub fn pushUsageToLua(L: *c.lua_State, usage: ai.protocol.Usage) void {
    c.lua_createtable(L, 0, 10);
    pushIntField(L, "input", usage.input);
    pushIntField(L, "output", usage.output);
    pushIntField(L, "cacheRead", usage.cache_read);
    pushIntField(L, "cache_read", usage.cache_read);
    pushIntField(L, "cacheWrite", usage.cache_write);
    pushIntField(L, "cache_write", usage.cache_write);
    pushIntField(L, "totalTokens", usage.total_tokens);
    pushIntField(L, "total_tokens", usage.total_tokens);
    pushCostToLua(L, usage.cost);
    c.lua_setfield(L, -2, "cost");
}

pub fn pushContextUsageToLua(L: *c.lua_State, usage: session_core.context_usage.ContextUsage) void {
    c.lua_createtable(L, 0, 3);
    if (usage.tokens) |tokens| c.lua_pushinteger(L, @intCast(tokens)) else c.lua_pushnil(L);
    c.lua_setfield(L, -2, "tokens");
    pushIntField(L, "context_window", usage.context_window);
    if (usage.percent) |percent| c.lua_pushnumber(L, percent) else c.lua_pushnil(L);
    c.lua_setfield(L, -2, "percent");
}

fn pushTextContent(L: *c.lua_State, text: ai.protocol.TextContent) void {
    c.lua_createtable(L, 0, 3);
    pushStringField(L, "type", "text");
    pushStringField(L, "text", text.text);
    pushOptionalStringField(L, "text_signature", text.text_signature);
}

fn pushImageContent(L: *c.lua_State, image: ai.protocol.ImageContent) void {
    c.lua_createtable(L, 0, 3);
    pushStringField(L, "type", "image");
    pushStringField(L, "data", image.data);
    pushStringField(L, "mime_type", image.mime_type);
}

pub fn pushAgentToolResultToLua(L: *c.lua_State, result: agent_protocol.AgentToolResult) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 5);
    c.lua_createtable(L, @intCast(result.content.len), 0);
    for (result.content, 0..) |block, i| {
        switch (block) {
            .text => |text| pushTextContent(L, text),
            .image => |image| pushImageContent(L, image),
        }
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "content");
    try lua_runtime.pushJsonValue(L, result.details);
    c.lua_setfield(L, -2, "details");
    try lua_runtime.pushJsonValue(L, result.presentation);
    c.lua_setfield(L, -2, "presentation");
    pushBoolField(L, "isError", result.is_error);
    pushBoolField(L, "is_error", result.is_error);
}

pub fn pushToolResultMessageToLua(L: *c.lua_State, tr: ai.protocol.ToolResultMessage) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 11);
    pushStringField(L, "role", "toolResult");
    pushStringField(L, "role_snake", "tool_result");
    pushStringField(L, "toolCallId", tr.tool_call_id);
    pushStringField(L, "tool_call_id", tr.tool_call_id);
    pushStringField(L, "toolName", tr.tool_name);
    pushStringField(L, "tool_name", tr.tool_name);
    c.lua_createtable(L, @intCast(tr.content.len), 0);
    for (tr.content, 0..) |block, i| {
        switch (block) {
            .text => |text| pushTextContent(L, text),
            .image => |image| pushImageContent(L, image),
        }
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "content");
    if (tr.details) |details| try lua_runtime.pushJsonValue(L, details) else c.lua_pushnil(L);
    c.lua_setfield(L, -2, "details");
    if (tr.presentation) |presentation| try lua_runtime.pushJsonValue(L, presentation) else c.lua_pushnil(L);
    c.lua_setfield(L, -2, "presentation");
    pushBoolField(L, "isError", tr.is_error);
    pushBoolField(L, "is_error", tr.is_error);
    pushIntField(L, "timestamp", tr.timestamp);
}

pub fn pushAssistantMessageToLua(L: *c.lua_State, assistant: ai.protocol.AssistantMessage) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 15);
    pushStringField(L, "role", "assistant");
    c.lua_createtable(L, @intCast(assistant.content.len), 0);
    var first_text: ?[]const u8 = null;
    for (assistant.content, 0..) |block, i| {
        switch (block) {
            .text => |text| { if (first_text == null) first_text = text.text; pushTextContent(L, text); },
            .thinking => |thinking| { c.lua_createtable(L, 0, 2); pushStringField(L, "type", "thinking"); pushStringField(L, "thinking", thinking.thinking); },
            .tool_call => |call| { c.lua_createtable(L, 0, 5); pushStringField(L, "type", "toolCall"); pushStringField(L, "toolCallId", call.id); pushStringField(L, "tool_call_id", call.id); pushStringField(L, "toolName", call.name); pushStringField(L, "tool_name", call.name); try lua_runtime.pushJsonValue(L, call.arguments); c.lua_setfield(L, -2, "args"); },
        }
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "content");
    pushStringField(L, "text", first_text orelse "");
    pushStringField(L, "api", apiToString(assistant.api));
    pushStringField(L, "provider", ai.json_util.providerToString(assistant.provider));
    pushStringField(L, "model", assistant.model);
    pushOptionalStringField(L, "responseId", assistant.response_id);
    pushOptionalStringField(L, "response_id", assistant.response_id);
    pushUsageToLua(L, assistant.usage);
    c.lua_setfield(L, -2, "usage");
    const stop = ai.json_util.stopReasonToString(assistant.stop_reason);
    pushStringField(L, "stopReason", stop);
    pushStringField(L, "stop_reason", stop);
    pushOptionalStringField(L, "errorMessage", assistant.error_message);
    pushOptionalStringField(L, "error_message", assistant.error_message);
    pushIntField(L, "timestamp", assistant.timestamp);
}

pub fn pushAgentMessageToLua(L: *c.lua_State, message: agent_protocol.AgentMessage) lua_runtime.ConvertError!void {
    switch (message) {
        .assistant => |assistant| try pushAssistantMessageToLua(L, assistant),
        .tool_result => |tr| try pushToolResultMessageToLua(L, tr),
        .user => |user| { c.lua_createtable(L, 0, 3); pushStringField(L, "role", "user"); switch (user.content) { .text => |text| pushStringField(L, "text", text), .blocks => {}, } pushIntField(L, "timestamp", user.timestamp); },
        else => { c.lua_createtable(L, 0, 1); pushStringField(L, "role", @tagName(message)); },
    }
}

pub fn pushAgentEventToLua(L: *c.lua_State, event: agent_protocol.AgentEvent) lua_runtime.ConvertError!void {
    c.lua_createtable(L, 0, 8);
    pushStringField(L, "type", @tagName(event));
    switch (event) {
        .agent_start, .turn_start => {},
        .agent_end => |e| { c.lua_createtable(L, @intCast(e.messages.len), 0); for (e.messages, 0..) |m, i| { try pushAgentMessageToLua(L, m); c.lua_rawseti(L, -2, @intCast(i + 1)); } c.lua_setfield(L, -2, "messages"); },
        .turn_end => |e| { try pushAgentMessageToLua(L, e.message); c.lua_setfield(L, -2, "message"); c.lua_createtable(L, @intCast(e.tool_results.len), 0); for (e.tool_results, 0..) |tr, i| { try pushToolResultMessageToLua(L, tr); c.lua_rawseti(L, -2, @intCast(i + 1)); } c.lua_setfield(L, -2, "toolResults"); },
        .message_start => |e| { try pushAgentMessageToLua(L, e.message); c.lua_setfield(L, -2, "message"); },
        .message_update => |e| { try pushAgentMessageToLua(L, e.message); c.lua_setfield(L, -2, "message"); pushStringField(L, "update_kind", @tagName(e.assistant_message_event)); },
        .message_end => |e| { try pushAgentMessageToLua(L, e.message); c.lua_setfield(L, -2, "message"); },
        .tool_execution_start => |e| { pushStringField(L, "toolCallId", e.tool_call_id); pushStringField(L, "tool_call_id", e.tool_call_id); pushStringField(L, "toolName", e.tool_name); pushStringField(L, "tool_name", e.tool_name); try lua_runtime.pushJsonValue(L, e.args); c.lua_setfield(L, -2, "args"); },
        .tool_execution_update => |e| { pushStringField(L, "toolCallId", e.tool_call_id); pushStringField(L, "tool_call_id", e.tool_call_id); pushStringField(L, "toolName", e.tool_name); pushStringField(L, "tool_name", e.tool_name); try lua_runtime.pushJsonValue(L, e.args); c.lua_setfield(L, -2, "args"); if (e.partial_result) |pr| try pushAgentToolResultToLua(L, pr) else c.lua_pushnil(L); c.lua_setfield(L, -2, "partialResult"); },
        .tool_execution_end => |e| { pushStringField(L, "toolCallId", e.tool_call_id); pushStringField(L, "tool_call_id", e.tool_call_id); pushStringField(L, "toolName", e.tool_name); pushStringField(L, "tool_name", e.tool_name); try pushAgentToolResultToLua(L, e.result); c.lua_setfield(L, -2, "result"); pushBoolField(L, "isError", e.is_error); pushBoolField(L, "is_error", e.is_error); },
    }
}
