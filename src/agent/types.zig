const std = @import("std");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");

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
pub const Token = @import("../zio/root.zig").cancel.Token;
pub const SimpleStreamOptions = ai.protocol.SimpleStreamOptions;

pub const StreamHook = struct {
    func: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        model: Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        callback: ai.provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void,
    ctx: ?*anyopaque = null,

    pub fn call(
        self: StreamHook,
        allocator: std.mem.Allocator,
        model: Model,
        context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        callback: ai.provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        self.func(self.ctx, allocator, model, context, options, callback, callback_ctx);
    }
};

pub const ConvertToLlmHook = struct {
    func: *const fn (
        allocator: std.mem.Allocator,
        messages: []const AgentMessage,
        ctx: ?*anyopaque,
    ) error{OutOfMemory}![]const ai.protocol.Message,
    ctx: ?*anyopaque = null,

    pub fn call(self: ConvertToLlmHook, allocator: std.mem.Allocator, messages: []const AgentMessage) error{OutOfMemory}![]const ai.protocol.Message {
        return self.func(allocator, messages, self.ctx);
    }
};

pub const TransformContextHook = struct {
    func: *const fn (
        allocator: std.mem.Allocator,
        messages: []const AgentMessage,
        signal: Token,
        ctx: ?*anyopaque,
    ) []const AgentMessage,
    ctx: ?*anyopaque = null,

    pub fn call(self: TransformContextHook, allocator: std.mem.Allocator, messages: []const AgentMessage, signal: Token) []const AgentMessage {
        return self.func(allocator, messages, signal, self.ctx);
    }
};

pub const GetMessagesHook = struct {
    func: *const fn (allocator: std.mem.Allocator, ctx: ?*anyopaque) []const AgentMessage,
    ctx: ?*anyopaque = null,

    pub fn call(self: GetMessagesHook, allocator: std.mem.Allocator) []const AgentMessage {
        return self.func(allocator, self.ctx);
    }
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

pub const ToolExecutionAffinity = enum {
    agent_thread,
    worker_thread,
};

pub const AgentToolCall = ToolCall;

pub const AgentMessage = union(enum) {
    user: ai.protocol.UserMessage,
    assistant: ai.protocol.AssistantMessage,
    tool_result: ai.protocol.ToolResultMessage,

    compaction_summary: CompactionSummaryMessage,

    branch_summary: BranchSummaryMessage,

    custom: CustomMessage,

    pub const CompactionSummaryMessage = struct {
        summary: []const u8,
        tokens_before: u64,
        timestamp: i64,
    };

    pub const BranchSummaryMessage = struct {
        summary: []const u8,
        from_id: []const u8,
        timestamp: i64,
    };

    pub const CustomContent = union(enum) {
        text: []const u8,
        blocks: []const ai.protocol.UserMessage.UserMessageContent.Block,
    };

    pub const CustomMessage = struct {
        custom_type: []const u8,
        content: CustomContent,
        display: bool = false,
        details: ?std.json.Value = null,
        timestamp: i64,
    };
};

pub const AgentToolResult = struct {
    content: []const ContentBlock,
    details: std.json.Value = .null,
    presentation: std.json.Value = .null,
    is_error: bool = false,

    pub const ContentBlock = union(enum) {
        text: TextContent,
        image: ImageContent,
    };

    pub fn clone(self: AgentToolResult, allocator: std.mem.Allocator) !AgentToolResult {
        const content = try allocator.alloc(ContentBlock, self.content.len);
        var initialized: usize = 0;
        errdefer {
            for (content[0..initialized]) |block| switch (block) {
                .text => |t| {
                    allocator.free(t.text);
                    if (t.text_signature) |sig| allocator.free(sig);
                },
                .image => |img| {
                    allocator.free(img.data);
                    allocator.free(img.mime_type);
                },
            };
            allocator.free(content);
        }

        for (self.content, 0..) |block, i| {
            content[i] = switch (block) {
                .text => |t| .{ .text = .{
                    .text = try allocator.dupe(u8, t.text),
                    .text_signature = if (t.text_signature) |sig| try allocator.dupe(u8, sig) else null,
                } },
                .image => |img| .{ .image = .{
                    .data = try allocator.dupe(u8, img.data),
                    .mime_type = try allocator.dupe(u8, img.mime_type),
                } },
            };
            initialized += 1;
        }

        const details = try json_util.cloneJsonValue(allocator, self.details);
        errdefer json_util.freeJsonValue(allocator, details);
        const presentation = try json_util.cloneJsonValue(allocator, self.presentation);

        return .{
            .content = content,
            .details = details,
            .presentation = presentation,
            .is_error = self.is_error,
        };
    }

    pub fn free(self: AgentToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |block| switch (block) {
            .text => |t| {
                allocator.free(t.text);
                if (t.text_signature) |sig| allocator.free(sig);
            },
            .image => |img| {
                allocator.free(img.data);
                allocator.free(img.mime_type);
            },
        };
        allocator.free(self.content);
        json_util.freeJsonValue(allocator, self.details);
        json_util.freeJsonValue(allocator, self.presentation);
    }
};

pub const AgentToolUpdateCallback = *const fn (partial_result: AgentToolResult, ctx: ?*anyopaque) void;

pub const AgentToolExecution = union(enum) {
    ready: AgentToolResult,
    pending: Pending,

    pub const Pending = struct {
        ptr: *anyopaque,
        wait: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, signal: Token, on_update: ?AgentToolUpdateCallback, update_ctx: ?*anyopaque) AgentToolResult,
        cancel: ?*const fn (ptr: *anyopaque) void = null,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,

        pub fn await(self: Pending, allocator: std.mem.Allocator, signal: Token, on_update: ?AgentToolUpdateCallback, update_ctx: ?*anyopaque) AgentToolResult {
            return self.wait(self.ptr, allocator, signal, on_update, update_ctx);
        }

        pub fn requestCancel(self: Pending) void {
            if (self.cancel) |f| f(self.ptr);
        }

        pub fn free(self: Pending, allocator: std.mem.Allocator) void {
            if (self.deinit) |f| f(self.ptr, allocator);
        }
    };
};

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    label: []const u8,
    display_call: ?[]const u8 = null,
    parameters: std.json.Value,

    ctx: ?*anyopaque = null,
    affinity: ToolExecutionAffinity = .agent_thread,

    prepare_arguments: ?*const fn (allocator: std.mem.Allocator, args: std.json.Value) anyerror!std.json.Value = null,
    execute: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        args: std.json.Value,
        signal: Token,
        on_update: ?AgentToolUpdateCallback,
        update_ctx: ?*anyopaque,
    ) AgentToolExecution,

    pub fn start(
        self: AgentTool,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        args: std.json.Value,
        signal: Token,
        on_update: ?AgentToolUpdateCallback,
        update_ctx: ?*anyopaque,
    ) AgentToolExecution {
        return self.execute(self.ctx, allocator, tool_call_id, args, signal, on_update, update_ctx);
    }
};

pub const AgentContext = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: ?[]const AgentTool = null,
};

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
    pending_tool_calls: []const []const u8 = &.{},
    error_message: ?[]const u8 = null,
};

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
    args: ?std.json.Value = null,
};

pub const BeforeToolCallContext = struct {
    assistant_message: AssistantMessage,
    tool_call: ToolCall,
    args: std.json.Value,
    context: AgentContext,
};

pub const AfterToolCallResult = struct {
    content: ?[]const AgentToolResult.ContentBlock = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
};

pub const AfterToolCallContext = struct {
    assistant_message: AssistantMessage,
    tool_call: ToolCall,
    args: std.json.Value,
    result: AgentToolResult,
    is_error: bool,
    context: AgentContext,
};

pub const BeforeToolCallHook = struct {
    func: *const fn (ctx_arg: BeforeToolCallContext, signal: Token, hook_ctx: ?*anyopaque) ?BeforeToolCallResult,
    ctx: ?*anyopaque = null,

    pub fn call(self: BeforeToolCallHook, context: BeforeToolCallContext, signal: Token) ?BeforeToolCallResult {
        return self.func(context, signal, self.ctx);
    }
};

pub const AfterToolCallHook = struct {
    func: *const fn (ctx_arg: AfterToolCallContext, signal: Token, hook_ctx: ?*anyopaque) ?AfterToolCallResult,
    ctx: ?*anyopaque = null,

    pub fn call(self: AfterToolCallHook, context: AfterToolCallContext, signal: Token) ?AfterToolCallResult {
        return self.func(context, signal, self.ctx);
    }
};

pub const OnPayloadHook = struct {
    func: *const fn (allocator: std.mem.Allocator, payload: std.json.Value, model: Model, ctx: ?*anyopaque) std.json.Value,
    ctx: ?*anyopaque = null,

    pub fn call(self: OnPayloadHook, allocator: std.mem.Allocator, payload: std.json.Value, model: Model) std.json.Value {
        return self.func(allocator, payload, model, self.ctx);
    }
};

pub const GetApiKeyHook = struct {
    func: *const fn (provider: []const u8, ctx: ?*anyopaque) ?[]const u8,
    ctx: ?*anyopaque = null,

    pub fn call(self: GetApiKeyHook, provider: []const u8) ?[]const u8 {
        return self.func(provider, self.ctx);
    }
};

pub const AgentLoopConfig = struct {
    model: Model,
    stream: StreamHook,
    convert_to_llm: ConvertToLlmHook,
    transform_context: ?TransformContextHook = null,
    get_steering_messages: ?GetMessagesHook = null,
    get_follow_up_messages: ?GetMessagesHook = null,
    skip_initial_steering_poll: bool = false,
    tool_execution: ToolExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallHook = null,
    after_tool_call: ?AfterToolCallHook = null,
    on_payload: ?OnPayloadHook = null,

    io: std.Io = std.Options.debug_io,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    api_key: ?[]const u8 = null,
    cache_retention: ?ai.protocol.CacheRetention = null,
    session_id: ?[]const u8 = null,
    max_retry_delay_ms: ?u64 = null,
    thinking_budgets: ?ai.protocol.ThinkingBudgets = null,
    transport: ?ai.protocol.Transport = null,
    reasoning: ?ai.protocol.ThinkingLevel = null,
    get_api_key: ?GetApiKeyHook = null,

    pub fn buildStreamOptions(self: *const AgentLoopConfig) ai.protocol.SimpleStreamOptions {
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
    tool_execution_end: struct { tool_call_id: []const u8, tool_name: []const u8, result: AgentToolResult, is_error: bool },
};

pub const AgentEventSink = *const fn (event: AgentEvent, ctx: ?*anyopaque) void;

test "AgentToolResult clone+free round-trip with text content" {
    const allocator = std.testing.allocator;

    const original = AgentToolResult{
        .content = &.{
            .{ .text = .{ .text = "hello world", .text_signature = "sig123" } },
        },
        .is_error = true,
    };

    const cloned = try original.clone(allocator);
    defer cloned.free(allocator);

    try std.testing.expectEqualStrings("hello world", cloned.content[0].text.text);
    try std.testing.expectEqualStrings("sig123", cloned.content[0].text.text_signature.?);
    try std.testing.expect(cloned.is_error);
    try std.testing.expect(cloned.content.ptr != original.content.ptr);
    try std.testing.expect(cloned.content[0].text.text.ptr != original.content[0].text.text.ptr);
}

test "AgentToolResult clone+free round-trip with image content" {
    const allocator = std.testing.allocator;

    const original = AgentToolResult{
        .content = &.{
            .{ .image = .{ .data = "base64data", .mime_type = "image/png" } },
        },
    };

    const cloned = try original.clone(allocator);
    defer cloned.free(allocator);

    try std.testing.expectEqualStrings("base64data", cloned.content[0].image.data);
    try std.testing.expectEqualStrings("image/png", cloned.content[0].image.mime_type);
    try std.testing.expect(cloned.content[0].image.data.ptr != original.content[0].image.data.ptr);
}

test "AgentToolResult clone+free with json details" {
    const allocator = std.testing.allocator;

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "key", .{ .string = "value" });
    defer {
        var m = obj;
        m.deinit(allocator);
    }

    const original = AgentToolResult{
        .content = &.{},
        .details = .{ .object = obj },
    };

    const cloned = try original.clone(allocator);
    defer cloned.free(allocator);

    const val = cloned.details.object.get("key").?;
    try std.testing.expectEqualStrings("value", val.string);
}
