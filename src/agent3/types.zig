const std = @import("std");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");
const AbortSignal = @import("../abort_signal.zig").AbortSignal;

pub const Message = ai.protocol.Message;
pub const AssistantMessage = ai.protocol.AssistantMessage;
pub const AssistantMessageEvent = ai.protocol.AssistantMessageEvent;
pub const Model = ai.protocol.Model;
pub const Tool = ai.protocol.Tool;
pub const ToolCall = ai.protocol.ToolCall;
pub const TextContent = ai.protocol.TextContent;
pub const ImageContent = ai.protocol.ImageContent;
pub const ToolResultMessage = ai.protocol.ToolResultMessage;
pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn toAi(self: ThinkingLevel) ?ai.protocol.ThinkingLevel {
        return switch (self) {
            .off => null,
            .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh => .xhigh,
        };
    }
};

pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

pub const AgentToolCall = ToolCall;

pub const CustomMessage = struct {
    role: []const u8,
    payload: std.json.Value,
    timestamp: i64,

    pub fn clone(self: CustomMessage, allocator: std.mem.Allocator) !CustomMessage {
        return .{
            .role = try allocator.dupe(u8, self.role),
            .payload = try json_util.cloneJsonValue(allocator, self.payload),
            .timestamp = self.timestamp,
        };
    }

    pub fn free(self: *CustomMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        json_util.freeJsonValue(allocator, self.payload);
        self.* = undefined;
    }
};

pub const AgentMessage = union(enum) {
    user: ai.protocol.UserMessage,
    assistant: ai.protocol.AssistantMessage,
    tool_result: ai.protocol.ToolResultMessage,
    custom: CustomMessage,

    pub fn clone(self: AgentMessage, allocator: std.mem.Allocator) !AgentMessage {
        return switch (self) {
            .user => |user| .{ .user = try cloneUserMessage(allocator, user) },
            .assistant => |assistant| .{ .assistant = try cloneAssistantMessage(allocator, assistant) },
            .tool_result => |tool_result| .{ .tool_result = try cloneToolResultMessage(allocator, tool_result) },
            .custom => |custom| .{ .custom = try custom.clone(allocator) },
        };
    }

    pub fn free(self: *AgentMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .user => |*user| freeUserMessage(allocator, user),
            .assistant => |*assistant| freeAssistantMessage(allocator, assistant),
            .tool_result => |*tool_result| freeToolResultMessage(allocator, tool_result),
            .custom => |*custom| custom.free(allocator),
        }
    }
};

pub fn cloneMessages(allocator: std.mem.Allocator, messages: []const AgentMessage) ![]AgentMessage {
    const owned = try allocator.alloc(AgentMessage, messages.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |*message| message.free(allocator);
        allocator.free(owned);
    }

    for (messages, 0..) |message, i| {
        owned[i] = try message.clone(allocator);
        initialized += 1;
    }
    return owned;
}

pub fn freeMessages(allocator: std.mem.Allocator, messages: []AgentMessage) void {
    for (messages) |*message| message.free(allocator);
    allocator.free(messages);
}

pub const AgentState = struct {
    system_prompt: []const u8 = "",
    model: Model,
    thinking_level: ThinkingLevel = .off,
    tools: []const AgentTool = &.{},
    messages: []const AgentMessage = &.{},
    is_streaming: bool = false,
    streaming_message: ?AgentMessage = null,
    pending_tool_calls: []const []const u8 = &.{},
    error_message: ?[]const u8 = null,
};

pub const AgentToolResult = struct {
    content: []const ContentBlock,
    details: std.json.Value = .null,

    pub const ContentBlock = union(enum) {
        text: TextContent,
        image: ImageContent,
    };

    pub fn clone(self: AgentToolResult, allocator: std.mem.Allocator) !AgentToolResult {
        const content = try allocator.alloc(ContentBlock, self.content.len);
        var initialized: usize = 0;
        errdefer {
            for (content[0..initialized]) |block| freeToolResultContentBlock(allocator, block);
            allocator.free(content);
        }

        for (self.content, 0..) |block, i| {
            content[i] = switch (block) {
                .text => |text| .{ .text = try cloneTextContent(allocator, text) },
                .image => |image| .{ .image = try cloneImageContent(allocator, image) },
            };
            initialized += 1;
        }

        return .{
            .content = content,
            .details = try json_util.cloneJsonValue(allocator, self.details),
        };
    }

    pub fn free(self: *const AgentToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |block| freeToolResultContentBlock(allocator, block);
        allocator.free(self.content);
        json_util.freeJsonValue(allocator, self.details);
    }
};

pub const AgentToolUpdateCallback = *const fn (partial_result: AgentToolResult, ctx: ?*anyopaque) void;

pub const AgentTool = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    ctx: ?*anyopaque = null,
    prepare_arguments: ?*const fn (allocator: std.mem.Allocator, args: std.json.Value) anyerror!std.json.Value = null,
    execute: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        args: std.json.Value,
        signal: AbortSignal,
        on_update: ?AgentToolUpdateCallback,
        on_update_ctx: ?*anyopaque,
    ) anyerror!AgentToolResult,
};

pub const AgentContext = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: ?[]const AgentTool = null,
};

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const AfterToolCallResult = struct {
    content: ?[]const AgentToolResult.ContentBlock = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
};

pub const BeforeToolCallContext = struct {
    assistant_message: AssistantMessage,
    tool_call: AgentToolCall,
    args: std.json.Value,
    context: AgentContext,
};

pub const AfterToolCallContext = struct {
    assistant_message: AssistantMessage,
    tool_call: AgentToolCall,
    args: std.json.Value,
    result: AgentToolResult,
    is_error: bool,
    context: AgentContext,
};

pub const StreamFn = struct {
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
        self: StreamFn,
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
    func: *const fn (allocator: std.mem.Allocator, messages: []const AgentMessage, ctx: ?*anyopaque) []const ai.protocol.Message,
    ctx: ?*anyopaque = null,

    pub fn call(self: ConvertToLlmHook, allocator: std.mem.Allocator, messages: []const AgentMessage) []const ai.protocol.Message {
        return self.func(allocator, messages, self.ctx);
    }
};

pub const TransformContextHook = struct {
    func: *const fn (allocator: std.mem.Allocator, messages: []const AgentMessage, signal: AbortSignal, ctx: ?*anyopaque) []const AgentMessage,
    ctx: ?*anyopaque = null,

    pub fn call(self: TransformContextHook, allocator: std.mem.Allocator, messages: []const AgentMessage, signal: AbortSignal) []const AgentMessage {
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

pub const BeforeToolCallHook = struct {
    func: *const fn (input: BeforeToolCallContext, signal: AbortSignal, ctx: ?*anyopaque) ?BeforeToolCallResult,
    ctx: ?*anyopaque = null,

    pub fn call(self: BeforeToolCallHook, input: BeforeToolCallContext, signal: AbortSignal) ?BeforeToolCallResult {
        return self.func(input, signal, self.ctx);
    }
};

pub const AfterToolCallHook = struct {
    func: *const fn (input: AfterToolCallContext, signal: AbortSignal, ctx: ?*anyopaque) ?AfterToolCallResult,
    ctx: ?*anyopaque = null,

    pub fn call(self: AfterToolCallHook, input: AfterToolCallContext, signal: AbortSignal) ?AfterToolCallResult {
        return self.func(input, signal, self.ctx);
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
    stream_fn: StreamFn,
    convert_to_llm: ConvertToLlmHook,
    stream_options: ai.protocol.SimpleStreamOptions = .{},
    transform_context: ?TransformContextHook = null,
    get_api_key: ?GetApiKeyHook = null,
    get_steering_messages: ?GetMessagesHook = null,
    get_follow_up_messages: ?GetMessagesHook = null,
    tool_execution: ToolExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallHook = null,
    after_tool_call: ?AfterToolCallHook = null,
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
    tool_execution_update: struct { tool_call_id: []const u8, tool_name: []const u8, args: std.json.Value, partial_result: AgentToolResult },
    tool_execution_end: struct { tool_call_id: []const u8, tool_name: []const u8, result: AgentToolResult, is_error: bool },
};

pub const AgentEventSink = *const fn (event: AgentEvent, ctx: ?*anyopaque) void;

fn cloneUserMessage(allocator: std.mem.Allocator, message: ai.protocol.UserMessage) !ai.protocol.UserMessage {
    return .{
        .content = try cloneUserContent(allocator, message.content),
        .timestamp = message.timestamp,
    };
}

fn freeUserMessage(allocator: std.mem.Allocator, message: *ai.protocol.UserMessage) void {
    freeUserContent(allocator, &message.content);
    message.* = undefined;
}

pub fn cloneUserContent(
    allocator: std.mem.Allocator,
    content: ai.protocol.UserMessage.UserMessageContent,
) !ai.protocol.UserMessage.UserMessageContent {
    return switch (content) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .blocks => |blocks| .{ .blocks = try cloneUserBlocks(allocator, blocks) },
    };
}

pub fn freeUserContent(
    allocator: std.mem.Allocator,
    content: *ai.protocol.UserMessage.UserMessageContent,
) void {
    switch (content.*) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| freeUserBlock(allocator, block);
            allocator.free(blocks);
        },
    }
    content.* = undefined;
}

fn cloneAssistantMessage(allocator: std.mem.Allocator, message: ai.protocol.AssistantMessage) !ai.protocol.AssistantMessage {
    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, message.content.len);
    var initialized: usize = 0;
    errdefer {
        for (content[0..initialized]) |block| freeAssistantContentBlock(allocator, block);
        allocator.free(content);
    }

    for (message.content, 0..) |block, i| {
        content[i] = switch (block) {
            .text => |text| .{ .text = try cloneTextContent(allocator, text) },
            .thinking => |thinking| .{ .thinking = try cloneThinkingContent(allocator, thinking) },
            .tool_call => |tool_call| .{ .tool_call = try cloneToolCall(allocator, tool_call) },
        };
        initialized += 1;
    }

    var api = try cloneApi(allocator, message.api);
    errdefer freeApi(allocator, &api);
    var provider = try cloneProvider(allocator, message.provider);
    errdefer freeProvider(allocator, &provider);
    const model = try allocator.dupe(u8, message.model);
    errdefer allocator.free(model);
    const response_id = if (message.response_id) |response_id| try allocator.dupe(u8, response_id) else null;
    errdefer if (response_id) |owned| allocator.free(owned);
    const error_message = if (message.error_message) |error_message| try allocator.dupe(u8, error_message) else null;
    errdefer if (error_message) |owned| allocator.free(owned);
    const failure = if (message.failure) |failure| try cloneFailure(allocator, failure) else null;
    errdefer if (failure) |owned| freeFailure(allocator, owned);

    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .response_id = response_id,
        .usage = message.usage,
        .stop_reason = message.stop_reason,
        .error_message = error_message,
        .failure = failure,
        .timestamp = message.timestamp,
    };
}

fn freeAssistantMessage(allocator: std.mem.Allocator, message: *ai.protocol.AssistantMessage) void {
    for (message.content) |block| freeAssistantContentBlock(allocator, block);
    allocator.free(message.content);
    freeApi(allocator, &message.api);
    freeProvider(allocator, &message.provider);
    allocator.free(message.model);
    if (message.response_id) |response_id| allocator.free(response_id);
    if (message.error_message) |error_message| allocator.free(error_message);
    if (message.failure) |failure| freeFailure(allocator, failure);
    message.* = undefined;
}

fn cloneToolResultMessage(allocator: std.mem.Allocator, message: ai.protocol.ToolResultMessage) !ai.protocol.ToolResultMessage {
    const content = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, message.content.len);
    var initialized: usize = 0;
    errdefer {
        for (content[0..initialized]) |block| freeAiToolResultContentBlock(allocator, block);
        allocator.free(content);
    }

    for (message.content, 0..) |block, i| {
        content[i] = switch (block) {
            .text => |text| .{ .text = try cloneTextContent(allocator, text) },
            .image => |image| .{ .image = try cloneImageContent(allocator, image) },
        };
        initialized += 1;
    }

    const tool_call_id = try allocator.dupe(u8, message.tool_call_id);
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, message.tool_name);
    errdefer allocator.free(tool_name);
    const details = if (message.details) |details| try json_util.cloneJsonValue(allocator, details) else null;
    errdefer if (details) |owned| json_util.freeJsonValue(allocator, owned);

    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = details,
        .is_error = message.is_error,
        .timestamp = message.timestamp,
    };
}

fn freeToolResultMessage(allocator: std.mem.Allocator, message: *ai.protocol.ToolResultMessage) void {
    allocator.free(message.tool_call_id);
    allocator.free(message.tool_name);
    for (message.content) |block| freeAiToolResultContentBlock(allocator, block);
    allocator.free(message.content);
    if (message.details) |details| json_util.freeJsonValue(allocator, details);
    message.* = undefined;
}

fn cloneUserBlocks(
    allocator: std.mem.Allocator,
    blocks: []const ai.protocol.UserMessage.UserMessageContent.Block,
) ![]ai.protocol.UserMessage.UserMessageContent.Block {
    const owned = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, blocks.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |block| freeUserBlock(allocator, block);
        allocator.free(owned);
    }

    for (blocks, 0..) |block, i| {
        owned[i] = switch (block) {
            .text => |text| .{ .text = try cloneTextContent(allocator, text) },
            .image => |image| .{ .image = try cloneImageContent(allocator, image) },
        };
        initialized += 1;
    }
    return owned;
}

fn freeUserBlock(allocator: std.mem.Allocator, block: ai.protocol.UserMessage.UserMessageContent.Block) void {
    switch (block) {
        .text => |text| freeTextContent(allocator, text),
        .image => |image| freeImageContent(allocator, image),
    }
}

fn cloneTextContent(allocator: std.mem.Allocator, text: ai.protocol.TextContent) !ai.protocol.TextContent {
    const owned_text = try allocator.dupe(u8, text.text);
    errdefer allocator.free(owned_text);
    const owned_sig = if (text.text_signature) |sig| try allocator.dupe(u8, sig) else null;
    errdefer if (owned_sig) |sig| allocator.free(sig);
    return .{
        .text = owned_text,
        .text_signature = owned_sig,
    };
}

fn freeTextContent(allocator: std.mem.Allocator, text: ai.protocol.TextContent) void {
    allocator.free(text.text);
    if (text.text_signature) |sig| allocator.free(sig);
}

fn cloneThinkingContent(allocator: std.mem.Allocator, thinking: ai.protocol.ThinkingContent) !ai.protocol.ThinkingContent {
    const owned_thinking = try allocator.dupe(u8, thinking.thinking);
    errdefer allocator.free(owned_thinking);
    const owned_sig = if (thinking.thinking_signature) |sig| try allocator.dupe(u8, sig) else null;
    errdefer if (owned_sig) |sig| allocator.free(sig);
    return .{
        .thinking = owned_thinking,
        .thinking_signature = owned_sig,
        .redacted = thinking.redacted,
    };
}

fn freeThinkingContent(allocator: std.mem.Allocator, thinking: ai.protocol.ThinkingContent) void {
    allocator.free(thinking.thinking);
    if (thinking.thinking_signature) |sig| allocator.free(sig);
}

fn cloneImageContent(allocator: std.mem.Allocator, image: ai.protocol.ImageContent) !ai.protocol.ImageContent {
    const data = try allocator.dupe(u8, image.data);
    errdefer allocator.free(data);
    const mime_type = try allocator.dupe(u8, image.mime_type);
    errdefer allocator.free(mime_type);
    return .{
        .data = data,
        .mime_type = mime_type,
    };
}

fn freeImageContent(allocator: std.mem.Allocator, image: ai.protocol.ImageContent) void {
    allocator.free(image.data);
    allocator.free(image.mime_type);
}

fn cloneToolCall(allocator: std.mem.Allocator, tool_call: ai.protocol.ToolCall) !ai.protocol.ToolCall {
    const id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(name);
    const arguments = try json_util.cloneJsonValue(allocator, tool_call.arguments);
    errdefer json_util.freeJsonValue(allocator, arguments);
    const thought_signature = if (tool_call.thought_signature) |sig| try allocator.dupe(u8, sig) else null;
    errdefer if (thought_signature) |sig| allocator.free(sig);
    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
        .thought_signature = thought_signature,
    };
}

fn freeToolCall(allocator: std.mem.Allocator, tool_call: ai.protocol.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    json_util.freeJsonValue(allocator, tool_call.arguments);
    if (tool_call.thought_signature) |sig| allocator.free(sig);
}

fn freeAssistantContentBlock(allocator: std.mem.Allocator, block: ai.protocol.AssistantMessage.AssistantContentBlock) void {
    switch (block) {
        .text => |text| freeTextContent(allocator, text),
        .thinking => |thinking| freeThinkingContent(allocator, thinking),
        .tool_call => |tool_call| freeToolCall(allocator, tool_call),
    }
}

fn freeAiToolResultContentBlock(allocator: std.mem.Allocator, block: ai.protocol.ToolResultMessage.ContentBlock) void {
    switch (block) {
        .text => |text| freeTextContent(allocator, text),
        .image => |image| freeImageContent(allocator, image),
    }
}

fn freeToolResultContentBlock(allocator: std.mem.Allocator, block: AgentToolResult.ContentBlock) void {
    switch (block) {
        .text => |text| freeTextContent(allocator, text),
        .image => |image| freeImageContent(allocator, image),
    }
}

fn cloneApi(allocator: std.mem.Allocator, api: ai.protocol.Api) !ai.protocol.Api {
    return switch (api) {
        .custom => |value| .{ .custom = try allocator.dupe(u8, value) },
        else => api,
    };
}

fn freeApi(allocator: std.mem.Allocator, api: *ai.protocol.Api) void {
    switch (api.*) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

fn cloneProvider(allocator: std.mem.Allocator, provider: ai.protocol.Provider) !ai.protocol.Provider {
    return switch (provider) {
        .custom => |value| .{ .custom = try allocator.dupe(u8, value) },
        else => provider,
    };
}

fn freeProvider(allocator: std.mem.Allocator, provider: *ai.protocol.Provider) void {
    switch (provider.*) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

fn cloneFailure(allocator: std.mem.Allocator, failure: ai.protocol.NormalizedFailure) !ai.protocol.NormalizedFailure {
    const provider_code = if (failure.provider_code) |code| try allocator.dupe(u8, code) else null;
    errdefer if (provider_code) |code| allocator.free(code);
    const provider_type = if (failure.provider_type) |value| try allocator.dupe(u8, value) else null;
    errdefer if (provider_type) |value| allocator.free(value);
    return .{
        .kind = failure.kind,
        .http_status = failure.http_status,
        .provider_code = provider_code,
        .provider_type = provider_type,
        .retry_after_ms = failure.retry_after_ms,
    };
}

fn freeFailure(allocator: std.mem.Allocator, failure: ai.protocol.NormalizedFailure) void {
    if (failure.provider_code) |code| allocator.free(code);
    if (failure.provider_type) |value| allocator.free(value);
}

test "AgentMessage clone round-trips custom payload" {
    const allocator = std.testing.allocator;

    var map = std.json.ObjectMap.init(allocator);
    defer map.deinit();
    try map.put("kind", .{ .string = "note" });

    var message: AgentMessage = .{ .custom = .{
        .role = "note",
        .payload = .{ .object = map },
        .timestamp = 1,
    } };

    var cloned = try message.clone(allocator);
    defer cloned.free(allocator);

    try std.testing.expect(cloned == .custom);
    try std.testing.expectEqualStrings("note", cloned.custom.role);
    try std.testing.expect(cloned.custom.payload == .object);
}
