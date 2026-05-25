const std = @import("std");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");

pub const Agent = @import("Agent.zig");
pub const loop = @import("loop.zig");

pub const max_tool_calls_per_turn = 32;
pub const max_tool_updates_per_batch = 256;

pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

pub const AgentToolCall = ai.ToolCall;

pub const BeforeToolCallResult = union(enum) {
    allow,
    block: []const u8,
};

pub const AfterToolCallResult = struct {
    content: ?[]const ai.ToolResultContent = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
    terminate: ?bool = null,
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const CustomAgentMessage = struct {
    kind: []const u8,
    payload: std.json.Value,
    timestamp: ai.Timestamp,
};

pub const AgentMessage = union(enum) {
    user: ai.UserMessage,
    assistant: ai.AssistantMessage,
    tool_result: ai.ToolResultMessage,
    custom: CustomAgentMessage,
};

pub const AgentToolResult = struct {
    content: []const ai.ToolResultContent,
    details: ?std.json.Value = null,
    terminate: bool = false,
};

pub const OwnedAgentToolResult = struct {
    allocator: std.mem.Allocator,
    result: AgentToolResult,

    pub fn deinit(self: *OwnedAgentToolResult) void {
        for (self.result.content) |content| freeToolResultContent(self.allocator, content);
        self.allocator.free(self.result.content);
        if (self.result.details) |details| freeJsonValue(self.allocator, details);
        self.* = undefined;
    }

    pub fn view(self: *const OwnedAgentToolResult) AgentToolResult {
        return self.result;
    }
};

pub fn freeToolResultContent(allocator: std.mem.Allocator, content: ai.ToolResultContent) void {
    switch (content) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |signature| allocator.free(signature);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    }
}

pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string, .string => |text| allocator.free(text),
        .array => |array| {
            for (array.items) |item| freeJsonValue(allocator, item);
            array.deinit();
        },
        .object => |object| {
            var owned = object;
            var iterator = owned.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            owned.deinit(allocator);
        },
    }
}

pub const PendingToolCalls = struct {
    ids: [max_tool_calls_per_turn][]const u8 = undefined,
    len: usize = 0,

    pub fn append(self: *PendingToolCalls, id: []const u8) error{TooManyToolCalls}!void {
        if (self.len == self.ids.len) return error.TooManyToolCalls;
        self.ids[self.len] = id;
        self.len += 1;
    }

    pub fn clear(self: *PendingToolCalls) void {
        self.len = 0;
    }

    pub fn remove(self: *PendingToolCalls, id: []const u8) void {
        for (self.ids[0..self.len], 0..) |pending_id, index| {
            if (std.mem.eql(u8, pending_id, id)) {
                const tail_start = index + 1;
                @memmove(self.ids[index .. self.len - 1], self.ids[tail_start..self.len]);
                self.len -= 1;
                return;
            }
        }
    }

    pub fn slice(self: *const PendingToolCalls) []const []const u8 {
        return self.ids[0..self.len];
    }
};

pub const AgentStatus = union(enum) {
    idle,
    running: Running,
    settling: Settling,
    failed: []const u8,

    pub const Running = struct {
        streaming_message: ?AgentMessage = null,
        pending_tool_calls: PendingToolCalls = .{},
    };

    pub const Settling = struct {
        messages: []const AgentMessage,
    };
};

pub const AgentState = struct {
    system_prompt: []const u8,
    model: ai.Model,
    thinking_level: ThinkingLevel,
    tools: []const AgentTool,
    messages: []const AgentMessage,
    status: AgentStatus = .idle,

    pub fn isStreaming(self: AgentState) bool {
        return switch (self.status) {
            .running, .settling => true,
            .idle, .failed => false,
        };
    }

    pub fn streamingMessage(self: AgentState) ?AgentMessage {
        return switch (self.status) {
            .running => |running| running.streaming_message,
            .idle, .settling, .failed => null,
        };
    }

    pub fn pendingToolCalls(self: AgentState) []const []const u8 {
        return switch (self.status) {
            .running => |*running| running.pending_tool_calls.slice(),
            .idle, .settling, .failed => &.{},
        };
    }

    pub fn errorMessage(self: AgentState) ?[]const u8 {
        return switch (self.status) {
            .failed => |message| message,
            .idle, .running, .settling => null,
        };
    }
};

pub const AgentToolUpdateCallback = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, AgentToolResult) anyerror!void,

    pub fn call(self: AgentToolUpdateCallback, partial_result: AgentToolResult) anyerror!void {
        try self.call_fn(self.context, partial_result);
    }
};

pub const PrepareArgumentsHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (std.mem.Allocator, ?*anyopaque, std.json.Value) std.mem.Allocator.Error!std.json.Value,

    pub fn call(
        allocator: std.mem.Allocator,
        self: PrepareArgumentsHook,
        args: std.json.Value,
    ) std.mem.Allocator.Error!std.json.Value {
        return self.call_fn(allocator, self.context, args);
    }
};

pub const ExecuteToolHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        ?*anyopaque,
        runtime.CancelToken,
        []const u8,
        std.json.Value,
        ?AgentToolUpdateCallback,
    ) anyerror!OwnedAgentToolResult,

    pub fn call(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: ExecuteToolHook,
        token: runtime.CancelToken,
        tool_call_id: []const u8,
        params: std.json.Value,
        on_update: ?AgentToolUpdateCallback,
    ) anyerror!OwnedAgentToolResult {
        return self.call_fn(allocator, io, self.context, token, tool_call_id, params, on_update);
    }
};

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    label: []const u8,
    prepare_arguments: ?PrepareArgumentsHook = null,
    execute: ExecuteToolHook,
    execution_mode: ?ToolExecutionMode = null,

    pub fn asTool(self: AgentTool) ai.Tool {
        return .{
            .name = self.name,
            .description = self.description,
            .parameters = self.parameters,
        };
    }
};

pub const AgentContext = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: []const AgentTool = &.{},
};

pub const BeforeToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: AgentToolCall,
    args: std.json.Value,
    agent: AgentContext,
};

pub const AfterToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: AgentToolCall,
    args: std.json.Value,
    result: AgentToolResult,
    is_error: bool,
    agent: AgentContext,
};

pub const ConvertToLlmHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (
        std.mem.Allocator,
        ?*anyopaque,
        []const AgentMessage,
    ) std.mem.Allocator.Error![]const ai.Message,

    pub fn call(
        allocator: std.mem.Allocator,
        self: ConvertToLlmHook,
        messages: []const AgentMessage,
    ) std.mem.Allocator.Error![]const ai.Message {
        return self.call_fn(allocator, self.context, messages);
    }
};

pub const TransformContextHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (
        std.mem.Allocator,
        ?*anyopaque,
        runtime.CancelToken,
        []const AgentMessage,
    ) std.mem.Allocator.Error![]const AgentMessage,

    pub fn call(
        allocator: std.mem.Allocator,
        self: TransformContextHook,
        token: runtime.CancelToken,
        messages: []const AgentMessage,
    ) std.mem.Allocator.Error![]const AgentMessage {
        return self.call_fn(allocator, self.context, token, messages);
    }
};

pub const GetApiKeyHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (std.mem.Allocator, ?*anyopaque, ai.Provider) std.mem.Allocator.Error!?[]const u8,

    pub fn call(
        allocator: std.mem.Allocator,
        self: GetApiKeyHook,
        provider: ai.Provider,
    ) std.mem.Allocator.Error!?[]const u8 {
        return self.call_fn(allocator, self.context, provider);
    }
};

pub const GetMessagesHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (std.mem.Allocator, ?*anyopaque) std.mem.Allocator.Error![]const AgentMessage,

    pub fn call(
        allocator: std.mem.Allocator,
        self: GetMessagesHook,
    ) std.mem.Allocator.Error![]const AgentMessage {
        return self.call_fn(allocator, self.context);
    }
};

pub const BeforeToolCallHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, runtime.CancelToken, BeforeToolCallContext) BeforeToolCallResult,

    pub fn call(
        self: BeforeToolCallHook,
        token: runtime.CancelToken,
        context: BeforeToolCallContext,
    ) BeforeToolCallResult {
        return self.call_fn(self.context, token, context);
    }
};

pub const AfterToolCallHook = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, runtime.CancelToken, AfterToolCallContext) anyerror!?AfterToolCallResult,

    pub fn call(
        self: AfterToolCallHook,
        token: runtime.CancelToken,
        context: AfterToolCallContext,
    ) anyerror!?AfterToolCallResult {
        return self.call_fn(self.context, token, context);
    }
};

pub const AgentLoopConfig = struct {
    model: ai.Model,
    options: ai.SimpleStreamOptions = .{},
    stream: ai.StreamFunction,
    convert_to_llm: ConvertToLlmHook,
    transform_context: ?TransformContextHook = null,
    get_api_key: ?GetApiKeyHook = null,
    get_steering_messages: ?GetMessagesHook = null,
    get_follow_up_messages: ?GetMessagesHook = null,
    tool_execution: ToolExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallHook = null,
    after_tool_call: ?AfterToolCallHook = null,
};

pub const AgentEvent = union(enum) {
    agent_start,
    agent_end: AgentEnd,
    turn_start,
    turn_end: TurnEnd,
    message_start: MessageEvent,
    message_update: MessageUpdate,
    message_end: MessageEvent,
    tool_execution_start: ToolExecutionStart,
    tool_execution_update: ToolExecutionUpdate,
    tool_execution_end: ToolExecutionEnd,

    pub const AgentEnd = struct {
        messages: []const AgentMessage,
    };

    pub const TurnEnd = struct {
        message: AgentMessage,
        tool_results: []const ai.ToolResultMessage,
    };

    pub const MessageEvent = struct {
        message: AgentMessage,
    };

    pub const MessageUpdate = struct {
        message: AgentMessage,
        assistant_message_event: ai.AssistantMessageEvent,
    };

    pub const ToolExecutionStart = struct {
        tool_call_id: []const u8,
        tool_name: []const u8,
        args: std.json.Value,
    };

    pub const ToolExecutionUpdate = struct {
        tool_call_id: []const u8,
        tool_name: []const u8,
        args: std.json.Value,
        partial_result: AgentToolResult,
    };

    pub const ToolExecutionEnd = struct {
        tool_call_id: []const u8,
        tool_name: []const u8,
        result: AgentToolResult,
        is_error: bool,
    };
};

pub fn toAiThinkingLevel(level: ThinkingLevel) ?ai.ThinkingLevel {
    return switch (level) {
        .off => null,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

test "agent module tests are reachable" {
    _ = Agent;
    _ = loop;
}

test "thinking level off maps to absent ai reasoning" {
    try std.testing.expectEqual(@as(?ai.ThinkingLevel, null), toAiThinkingLevel(.off));
    try std.testing.expectEqual(ai.ThinkingLevel.high, toAiThinkingLevel(.high).?);
}

test "pending tool calls are bounded" {
    var pending: PendingToolCalls = .{};

    for (0..max_tool_calls_per_turn) |index| {
        const id = if (index == 0) "first" else "next";
        try pending.append(id);
    }

    try std.testing.expectError(error.TooManyToolCalls, pending.append("overflow"));
    try std.testing.expectEqual(@as(usize, max_tool_calls_per_turn), pending.slice().len);
}

test "agent state encodes streaming as status" {
    const state: AgentState = .{
        .system_prompt = "system",
        .model = emptyModel(),
        .thinking_level = .off,
        .tools = &.{},
        .messages = &.{},
        .status = .{ .running = .{} },
    };

    try std.testing.expect(state.isStreaming());
    try std.testing.expectEqual(@as(?[]const u8, null), state.errorMessage());
}

test "agent tool exposes llm tool shape" {
    const tool: AgentTool = .{
        .name = "read",
        .description = "Read a file",
        .parameters = .{ .object = .{} },
        .label = "Read",
        .execute = .{ .call_fn = testExecuteTool },
    };

    const llm_tool = tool.asTool();

    try std.testing.expectEqualStrings("read", llm_tool.name);
    try std.testing.expectEqualStrings("Read a file", llm_tool.description);
}

fn testExecuteTool(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    _: ?AgentToolUpdateCallback,
) anyerror!OwnedAgentToolResult {
    return .{ .allocator = allocator, .result = .{ .content = try allocator.alloc(ai.ToolResultContent, 0) } };
}

fn emptyModel() ai.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = ai.KnownApi.openai_responses,
        .provider = ai.KnownProvider.openai,
        .base_url = "https://example.test",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
    };
}
