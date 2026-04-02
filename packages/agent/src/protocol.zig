const std = @import("std");
const ai = @import("ai");

// Re-export ai protocol for convenience
pub const Message = ai.protocol.Message;
pub const AssistantMessage = ai.protocol.AssistantMessage;
pub const AssistantMessageEvent = ai.protocol.AssistantMessageEvent;
pub const Model = ai.protocol.Model;
pub const Tool = ai.protocol.Tool;
pub const ToolCall = ai.protocol.ToolCall;
pub const TextContent = ai.protocol.TextContent;
pub const ImageContent = ai.protocol.ImageContent;
pub const ThinkingContent = ai.protocol.ThinkingContent;
pub const ToolResultMessage = ai.protocol.ToolResultMessage;
pub const Usage = ai.protocol.Usage;
pub const StopReason = ai.protocol.StopReason;
pub const StreamOptions = ai.protocol.StreamOptions;
pub const SimpleStreamOptions = ai.protocol.SimpleStreamOptions;

/// Thinking/reasoning level — extends ai.ThinkingLevel with "off".
/// pi-mono source: packages/agent/src/types.ts:220
pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

/// Tool execution mode.
/// pi-mono source: packages/agent/src/types.ts:35
pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

/// Agent message — union of LLM messages + custom app messages.
/// pi-mono source: packages/agent/src/types.ts:245
/// In zig, custom messages use a tagged union variant.
pub const AgentMessage = union(enum) {
    user: ai.protocol.UserMessage,
    assistant: ai.protocol.AssistantMessage,
    tool_result: ai.protocol.ToolResultMessage,
    custom: CustomMessage,

    pub const CustomMessage = struct {
        custom_type: []const u8,
        content: []const u8,
        details: ?std.json.Value = null,
        timestamp: i64,
    };
};

/// Tool result returned from tool execution.
/// pi-mono source: packages/agent/src/types.ts:281-286
pub const AgentToolResult = struct {
    content: []const ContentBlock,
    details: ?std.json.Value = null,

    pub const ContentBlock = union(enum) {
        text: TextContent,
        image: ImageContent,
    };
};

/// Callback for streaming tool execution updates.
pub const AgentToolUpdateCallback = *const fn (partial_result: AgentToolResult, ctx: ?*anyopaque) void;

/// Tool definition for the agent runtime.
/// Extends ai.Tool with execution capability.
/// pi-mono source: packages/agent/src/types.ts:292-307
pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    label: []const u8,
    parameters: std.json.Value,
    execute: *const fn (
        tool_call_id: []const u8,
        args: std.json.Value,
        signal: ?*anyopaque,
        on_update: ?AgentToolUpdateCallback,
        update_ctx: ?*anyopaque,
    ) AgentToolResult,
};

/// Agent context snapshot passed to the loop.
/// pi-mono source: packages/agent/src/types.ts:310-317
pub const AgentContext = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: ?[]const AgentTool = null,
};

/// Public agent state.
/// pi-mono source: packages/agent/src/types.ts:253-278
pub const AgentState = struct {
    system_prompt: []const u8 = "",
    model: Model = .{
        .id = "unknown",
        .name = "unknown",
        .api = .{ .custom = "unknown" },
        .provider = .{ .custom = "unknown" },
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
    },
    thinking_level: ThinkingLevel = .off,
    tools: []const AgentTool = &.{},
    messages: []const AgentMessage = &.{},
    is_streaming: bool = false,
    streaming_message: ?AgentMessage = null,
    error_message: ?[]const u8 = null,
};

/// Result from beforeToolCall hook.
/// pi-mono source: packages/agent/src/types.ts:46-49
pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
};

/// Context passed to beforeToolCall hook.
/// pi-mono source: packages/agent/src/types.ts:69-78
pub const BeforeToolCallContext = struct {
    assistant_message: AssistantMessage,
    tool_call: ToolCall,
    args: std.json.Value,
    context: AgentContext,
};

/// Result from afterToolCall hook — partial override.
/// pi-mono source: packages/agent/src/types.ts:62-66
pub const AfterToolCallResult = struct {
    content: ?[]const AgentToolResult.ContentBlock = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
};

/// Context passed to afterToolCall hook.
/// pi-mono source: packages/agent/src/types.ts:81-94
pub const AfterToolCallContext = struct {
    assistant_message: AssistantMessage,
    tool_call: ToolCall,
    args: std.json.Value,
    result: AgentToolResult,
    is_error: bool,
    context: AgentContext,
};

/// Agent events — emitted for UI/logging.
/// pi-mono source: packages/agent/src/types.ts:326-341
pub const AgentEvent = union(enum) {
    agent_start: void,
    agent_end: struct { messages: []const AgentMessage },
    turn_start: void,
    turn_end: struct { message: AgentMessage, tool_results: []const ToolResultMessage },
    message_start: struct { message: AgentMessage },
    message_update: struct { message: AgentMessage, assistant_message_event: AssistantMessageEvent },
    message_end: struct { message: AgentMessage },
    tool_execution_start: struct { tool_call_id: []const u8, tool_name: []const u8, args: std.json.Value },
    tool_execution_update: struct { tool_call_id: []const u8, tool_name: []const u8, args: std.json.Value, partial_result: ?AgentToolResult },
    tool_execution_end: struct { tool_call_id: []const u8, tool_name: []const u8, result: ?std.json.Value, is_error: bool },
};

/// Agent event callback.
pub const AgentEventSink = *const fn (event: AgentEvent, ctx: ?*anyopaque) void;
