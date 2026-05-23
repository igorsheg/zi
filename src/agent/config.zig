const std = @import("std");
const ai = @import("../ai/root.zig");
const message = @import("message.zig");
const tool = @import("../ai/root.zig").tool;

pub const StreamHook = ai.hooks.StreamHook;
pub const ConvertMessagesHook = ai.hooks.ConvertMessagesHook;
pub const TransformContextHook = ai.hooks.TransformContextHook;

pub const BeforeToolCallHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, context: BeforeToolCallContext) bool,

    pub fn allow(self: BeforeToolCallHook, context: BeforeToolCallContext) bool {
        return self.call_fn(self.ctx, context);
    }
};

pub const BeforeToolCallContext = struct {
    assistant_message: message.AssistantMessage,
    tool_call: message.ToolCall,
    args: @import("../json/value.zig").BorrowedValue, // ziglint-ignore: Z028
    context_messages: []const message.AgentMessage,
    signal: @import("../runtime/cancel.zig").Token, // ziglint-ignore: Z028
};

pub const AfterToolCallHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, context: AfterToolCallContext) void,

    pub fn apply(self: AfterToolCallHook, context: AfterToolCallContext) void {
        self.call_fn(self.ctx, context);
    }
};

pub const AfterToolCallContext = struct {
    assistant_message: message.AssistantMessage,
    tool_call: message.ToolCall,
    args: @import("../json/value.zig").BorrowedValue, // ziglint-ignore: Z028
    result: *tool.AgentToolResult,
    is_error: bool,
    context_messages: []const message.AgentMessage,
    signal: @import("../runtime/cancel.zig").Token, // ziglint-ignore: Z028
};

pub const MessageSourceHook = struct {
    ctx: ?*anyopaque = null,
    call_fn: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) error{OutOfMemory}![]const message.AgentMessage,

    pub fn call(self: MessageSourceHook, allocator: std.mem.Allocator) error{OutOfMemory}![]const message.AgentMessage {
        return self.call_fn(self.ctx, allocator);
    }
};

pub const RunConfig = struct {
    model: message.Model,
    stream: StreamHook,
    convert_messages: ConvertMessagesHook,
    transform_context: ?TransformContextHook = null,
    tool_execution: tool.ExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallHook = null,
    after_tool_call: ?AfterToolCallHook = null,
    steering_messages: ?MessageSourceHook = null,
    follow_up_messages: ?MessageSourceHook = null,
    io: std.Io,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    api_key: ?[]const u8 = null,
    cache_retention: ?ai.protocol.CacheRetention = null,
    session_id: ?[]const u8 = null,
    max_retry_delay_ms: ?u64 = null,
    thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
    transport: ?ai.protocol.Transport = null,
    reasoning: ?ai.protocol.ThinkingLevel = null,

    pub fn streamOptions(self: RunConfig) ai.protocol.SimpleStreamOptions {
        return .{
            .base = .{
                .io = self.io,
                .temperature = self.temperature,
                .max_tokens = self.max_tokens,
                .api_key = self.api_key,
                .cache_retention = self.cache_retention,
                .session_id = self.session_id,
                .max_retry_delay_ms = self.max_retry_delay_ms,
                .transport = self.transport,
            },
            .thinking_budgets = self.thinking_budgets,
            .reasoning = self.reasoning,
        };
    }
};

pub const RunBackend = struct {
    stream: StreamHook,
    convert_messages: ConvertMessagesHook,
    transform_context: ?TransformContextHook = null,
    tool_execution: tool.ExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallHook = null,
    after_tool_call: ?AfterToolCallHook = null,
    io: std.Io,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    api_key: ?[]const u8 = null,
    cache_retention: ?ai.protocol.CacheRetention = null,
    session_id: ?[]const u8 = null,
    max_retry_delay_ms: ?u64 = null,
    thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
    transport: ?ai.protocol.Transport = null,

    pub fn runConfig(self: RunBackend, model: message.Model, reasoning: ?ai.protocol.ThinkingLevel) RunConfig {
        return .{
            .model = model,
            .stream = self.stream,
            .convert_messages = self.convert_messages,
            .transform_context = self.transform_context,
            .tool_execution = self.tool_execution,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .io = self.io,
            .temperature = self.temperature,
            .max_tokens = self.max_tokens,
            .api_key = self.api_key,
            .cache_retention = self.cache_retention,
            .session_id = self.session_id,
            .max_retry_delay_ms = self.max_retry_delay_ms,
            .thinking_budgets = self.thinking_budgets,
            .transport = self.transport,
            .reasoning = reasoning,
        };
    }
};
