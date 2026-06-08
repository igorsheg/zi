const std = @import("std");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");

pub const Agent = @import("Agent.zig");
pub const loop = @import("loop.zig");

pub const max_tool_calls_per_turn = 32;
pub const max_tool_updates_per_batch = 256;

pub const EventSink = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, AgentEvent) anyerror!void,

    pub fn emit(self: EventSink, event: AgentEvent) anyerror!void {
        return self.call_fn(self.context, event);
    }
};

pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

pub const ToolRuntime = runtime.Runtime;

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

    pub fn jsonStringify(self: AgentMessage, stringify: *std.json.Stringify) !void {
        switch (self) {
            .user => |message| try stringify.write(message),
            .assistant => |message| try stringify.write(message),
            .tool_result => |message| try stringify.write(message),
            .custom => |message| {
                try stringify.beginObject();
                try writeJsonField("role", stringify, message.kind);
                try writeJsonField("payload", stringify, message.payload);
                try writeJsonField("timestamp", stringify, message.timestamp);
                try stringify.endObject();
            },
        }
    }
};

pub fn copyAgentMessage(allocator: std.mem.Allocator, source: AgentMessage) !AgentMessage {
    return switch (source) {
        .user => |message| .{ .user = .{
            .content = switch (message.content) {
                .string => |text| .{ .string = try allocator.dupe(u8, text) },
                .blocks => |blocks| .{ .blocks = try copyUserContentSlice(allocator, blocks) },
            },
            .timestamp = message.timestamp,
        } },
        .assistant => |message| .{ .assistant = try ai.owned.copyAssistantMessage(allocator, message) },
        .tool_result => |message| blk: {
            const tool_call_id = try allocator.dupe(u8, message.tool_call_id);
            errdefer allocator.free(tool_call_id);
            const tool_name = try allocator.dupe(u8, message.tool_name);
            errdefer allocator.free(tool_name);
            const content = try copyToolResultContentSlice(allocator, message.content);
            errdefer deinitToolResultContentSlice(allocator, content);
            const details = if (message.details) |details| try runtime.cloneJsonValue(allocator, details) else null;
            break :blk .{ .tool_result = .{
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .content = content,
                .details = details,
                .is_error = message.is_error,
                .timestamp = message.timestamp,
            } };
        },
        .custom => |message| blk: {
            const kind = try allocator.dupe(u8, message.kind);
            errdefer allocator.free(kind);
            const payload = try runtime.cloneJsonValue(allocator, message.payload);
            break :blk .{ .custom = .{
                .kind = kind,
                .payload = payload,
                .timestamp = message.timestamp,
            } };
        },
    };
}

pub fn copyAgentMessages(allocator: std.mem.Allocator, source: []const AgentMessage) ![]const AgentMessage {
    const cloned = try allocator.alloc(AgentMessage, source.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |message| deinitAgentMessage(allocator, message);
        allocator.free(cloned);
    }
    for (source, cloned) |message, *out| {
        out.* = try copyAgentMessage(allocator, message);
        initialized += 1;
    }
    return cloned;
}

pub fn deinitAgentMessage(allocator: std.mem.Allocator, message: AgentMessage) void {
    switch (message) {
        .user => |user| switch (user.content) {
            .string => |text| allocator.free(text),
            .blocks => |blocks| deinitUserContentSlice(allocator, blocks),
        },
        .assistant => |assistant| ai.owned.deinitAssistantMessage(allocator, assistant),
        .tool_result => |tool_result| {
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            deinitToolResultContentSlice(allocator, tool_result.content);
            if (tool_result.details) |details| runtime.freeJsonValue(allocator, details);
        },
        .custom => |custom| {
            allocator.free(custom.kind);
            runtime.freeJsonValue(allocator, custom.payload);
        },
    }
}

pub const AgentToolResult = struct {
    content: []const ai.ToolResultContent,
    details: ?std.json.Value = null,
    terminate: bool = false,

    pub fn jsonStringify(self: AgentToolResult, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("content", stringify, self.content);
        if (self.details) |details| try writeJsonField("details", stringify, details);
        if (self.terminate) try writeJsonField("terminate", stringify, true);
        try stringify.endObject();
    }
};

pub fn copyToolResultContentSlice(
    allocator: std.mem.Allocator,
    source: []const ai.ToolResultContent,
) ![]const ai.ToolResultContent {
    const cloned = try allocator.alloc(ai.ToolResultContent, source.len);
    var initialized: usize = 0;
    errdefer {
        deinitToolResultContentItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (source, cloned) |content, *out| {
        out.* = switch (content) {
            .text => |text| blk: {
                const text_copy = try allocator.dupe(u8, text.text);
                errdefer allocator.free(text_copy);
                const signature = try copyOptionalString(allocator, text.text_signature);
                break :blk .{ .text = .{ .text = text_copy, .text_signature = signature } };
            },
            .image => |image| blk: {
                const data = try allocator.dupe(u8, image.data);
                errdefer allocator.free(data);
                const mime_type = try allocator.dupe(u8, image.mime_type);
                break :blk .{ .image = .{ .data = data, .mime_type = mime_type } };
            },
        };
        initialized += 1;
    }
    return cloned;
}

pub fn copyToolResultMessage(allocator: std.mem.Allocator, source: ai.ToolResultMessage) !ai.ToolResultMessage {
    const tool_call_id = try allocator.dupe(u8, source.tool_call_id);
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, source.tool_name);
    errdefer allocator.free(tool_name);
    const content = try copyToolResultContentSlice(allocator, source.content);
    errdefer deinitToolResultContentSlice(allocator, content);
    const details = if (source.details) |details| try runtime.cloneJsonValue(allocator, details) else null;
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .details = details,
        .is_error = source.is_error,
        .timestamp = source.timestamp,
    };
}

pub fn copyToolResultMessages(
    allocator: std.mem.Allocator,
    source: []const ai.ToolResultMessage,
) ![]const ai.ToolResultMessage {
    const cloned = try allocator.alloc(ai.ToolResultMessage, source.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |message| deinitToolResultMessage(allocator, message);
        allocator.free(cloned);
    }
    for (source, cloned) |message, *out| {
        out.* = try copyToolResultMessage(allocator, message);
        initialized += 1;
    }
    return cloned;
}

pub fn deinitToolResultMessage(allocator: std.mem.Allocator, message: ai.ToolResultMessage) void {
    allocator.free(message.tool_call_id);
    allocator.free(message.tool_name);
    deinitToolResultContentSlice(allocator, message.content);
    if (message.details) |details| runtime.freeJsonValue(allocator, details);
}

pub fn copyAgentToolResult(allocator: std.mem.Allocator, source: AgentToolResult) !AgentToolResult {
    return .{
        .content = try copyToolResultContentSlice(allocator, source.content),
        .details = if (source.details) |details| try runtime.cloneJsonValue(allocator, details) else null,
        .terminate = source.terminate,
    };
}

pub fn deinitAgentToolResult(allocator: std.mem.Allocator, result: AgentToolResult) void {
    deinitToolResultContentSlice(allocator, result.content);
    if (result.details) |details| runtime.freeJsonValue(allocator, details);
}

pub const ToolExecutionResult = struct {
    allocator: std.mem.Allocator,
    result: AgentToolResult,

    pub fn deinit(self: *ToolExecutionResult) void {
        for (self.result.content) |content| deinitToolResultContent(self.allocator, content);
        self.allocator.free(self.result.content);
        if (self.result.details) |details| deinitJsonValue(self.allocator, details);
        self.* = undefined;
    }

    pub fn view(self: *const ToolExecutionResult) AgentToolResult {
        return self.result;
    }
};

pub fn deinitToolResultContent(allocator: std.mem.Allocator, content: ai.ToolResultContent) void {
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

pub fn deinitToolResultContentSlice(allocator: std.mem.Allocator, source: []const ai.ToolResultContent) void {
    deinitToolResultContentItems(allocator, source);
    allocator.free(source);
}

fn deinitToolResultContentItems(allocator: std.mem.Allocator, source: []const ai.ToolResultContent) void {
    for (source) |content| deinitToolResultContent(allocator, content);
}

pub fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    runtime.freeJsonValue(allocator, value);
}

fn copyUserContentSlice(allocator: std.mem.Allocator, source: []const ai.UserContent) ![]const ai.UserContent {
    const cloned = try allocator.alloc(ai.UserContent, source.len);
    var initialized: usize = 0;
    errdefer {
        deinitUserContentItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (source, cloned) |content, *out| {
        out.* = switch (content) {
            .text => |text| blk: {
                const text_copy = try allocator.dupe(u8, text.text);
                errdefer allocator.free(text_copy);
                const signature = try copyOptionalString(allocator, text.text_signature);
                break :blk .{ .text = .{ .text = text_copy, .text_signature = signature } };
            },
            .image => |image| blk: {
                const data = try allocator.dupe(u8, image.data);
                errdefer allocator.free(data);
                const mime_type = try allocator.dupe(u8, image.mime_type);
                break :blk .{ .image = .{ .data = data, .mime_type = mime_type } };
            },
        };
        initialized += 1;
    }
    return cloned;
}

fn deinitUserContentSlice(allocator: std.mem.Allocator, source: []const ai.UserContent) void {
    deinitUserContentItems(allocator, source);
    allocator.free(source);
}

fn deinitUserContentItems(allocator: std.mem.Allocator, source: []const ai.UserContent) void {
    for (source) |content| switch (content) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |value| allocator.free(value);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    };
}

fn copyOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator.dupe(u8, value) else null;
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
        *ToolRuntime,
        ?*anyopaque,
        runtime.CancelToken,
        []const u8,
        std.json.Value,
        ?AgentToolUpdateCallback,
    ) anyerror!ToolExecutionResult,

    pub fn call(
        allocator: std.mem.Allocator,
        io: std.Io,
        zio_runtime: *ToolRuntime,
        self: ExecuteToolHook,
        token: runtime.CancelToken,
        tool_call_id: []const u8,
        params: std.json.Value,
        on_update: ?AgentToolUpdateCallback,
    ) anyerror!ToolExecutionResult {
        return self.call_fn(allocator, io, zio_runtime, self.context, token, tool_call_id, params, on_update);
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
    tool_call: ai.ToolCall,
    args: std.json.Value,
    agent: AgentContext,
};

pub const AfterToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: ai.ToolCall,
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
    call_fn: *const fn (std.mem.Allocator, ?*anyopaque, ai.Provider) anyerror!?[]const u8,

    pub fn call(
        allocator: std.mem.Allocator,
        self: GetApiKeyHook,
        provider: ai.Provider,
    ) anyerror!?[]const u8 {
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

pub fn copyAgentEvent(allocator: std.mem.Allocator, event: AgentEvent) !AgentEvent {
    return switch (event) {
        .message_start => |payload| .{ .message_start = .{
            .message = try copyAgentMessage(allocator, payload.message),
        } },
        .message_update => |payload| .{ .message_update = .{
            .assistant_message_event = try ai.owned.copyAssistantMessageEvent(
                allocator,
                payload.assistant_message_event,
            ),
        } },
        .message_end => |payload| .{ .message_end = .{ .message = try copyAgentMessage(allocator, payload.message) } },
        .turn_end => |payload| .{ .turn_end = .{
            .message = try copyAgentMessage(allocator, payload.message),
            .tool_results = try copyToolResultMessages(allocator, payload.tool_results),
        } },
        .agent_end => |payload| .{ .agent_end = .{ .messages = try copyAgentMessages(allocator, payload.messages) } },
        .tool_execution_start => |payload| .{ .tool_execution_start = .{
            .tool_call_id = try allocator.dupe(u8, payload.tool_call_id),
            .tool_name = try allocator.dupe(u8, payload.tool_name),
            .args = try runtime.cloneJsonValue(allocator, payload.args),
        } },
        .tool_execution_update => |payload| .{ .tool_execution_update = .{
            .tool_call_id = try allocator.dupe(u8, payload.tool_call_id),
            .tool_name = try allocator.dupe(u8, payload.tool_name),
            .args = try runtime.cloneJsonValue(allocator, payload.args),
            .partial_result = try copyAgentToolResult(allocator, payload.partial_result),
        } },
        .tool_execution_end => |payload| .{ .tool_execution_end = .{
            .tool_call_id = try allocator.dupe(u8, payload.tool_call_id),
            .tool_name = try allocator.dupe(u8, payload.tool_name),
            .result = try copyAgentToolResult(allocator, payload.result),
            .is_error = payload.is_error,
        } },
        .agent_start, .turn_start => event,
    };
}

pub fn deinitAgentEvent(allocator: std.mem.Allocator, event: AgentEvent) void {
    switch (event) {
        .message_start => |payload| deinitAgentMessage(allocator, payload.message),
        .message_update => |payload| {
            ai.owned.deinitAssistantMessageEvent(allocator, payload.assistant_message_event);
        },
        .message_end => |payload| deinitAgentMessage(allocator, payload.message),
        .turn_end => |payload| {
            deinitAgentMessage(allocator, payload.message);
            for (payload.tool_results) |message| deinitToolResultMessage(allocator, message);
            allocator.free(payload.tool_results);
        },
        .agent_end => |payload| {
            for (payload.messages) |message| deinitAgentMessage(allocator, message);
            allocator.free(payload.messages);
        },
        .tool_execution_start => |payload| {
            allocator.free(payload.tool_call_id);
            allocator.free(payload.tool_name);
            runtime.freeJsonValue(allocator, payload.args);
        },
        .tool_execution_update => |payload| {
            allocator.free(payload.tool_call_id);
            allocator.free(payload.tool_name);
            runtime.freeJsonValue(allocator, payload.args);
            deinitAgentToolResult(allocator, payload.partial_result);
        },
        .tool_execution_end => |payload| {
            allocator.free(payload.tool_call_id);
            allocator.free(payload.tool_name);
            deinitAgentToolResult(allocator, payload.result);
        },
        .agent_start, .turn_start => {},
    }
}

pub fn assistantEventPartial(event: ai.AssistantMessageEvent) ai.AssistantMessage {
    return switch (event) {
        .start => |payload| payload.partial,
        .text_start => |payload| payload.partial,
        .text_delta => |payload| payload.partial,
        .text_end => |payload| payload.partial,
        .thinking_start => |payload| payload.partial,
        .thinking_delta => |payload| payload.partial,
        .thinking_end => |payload| payload.partial,
        .toolcall_start => |payload| payload.partial,
        .toolcall_delta => |payload| payload.partial,
        .toolcall_end => |payload| payload.partial,
        .done => |payload| payload.message,
        .@"error" => |payload| payload.@"error",
    };
}

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

    pub fn jsonStringify(self: AgentEvent, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        switch (self) {
            .agent_start => try writeJsonField("type", stringify, "agent_start"),
            .agent_end => |payload| {
                try writeJsonField("type", stringify, "agent_end");
                try writeJsonField("messages", stringify, payload.messages);
            },
            .turn_start => try writeJsonField("type", stringify, "turn_start"),
            .turn_end => |payload| {
                try writeJsonField("type", stringify, "turn_end");
                try writeJsonField("message", stringify, payload.message);
                try writeJsonField("toolResults", stringify, payload.tool_results);
            },
            .message_start => |payload| {
                try writeJsonField("type", stringify, "message_start");
                try writeJsonField("message", stringify, payload.message);
            },
            .message_update => |payload| {
                try writeJsonField("type", stringify, "message_update");
                try writeJsonField("assistantMessageEvent", stringify, payload.assistant_message_event);
            },
            .message_end => |payload| {
                try writeJsonField("type", stringify, "message_end");
                try writeJsonField("message", stringify, payload.message);
            },
            .tool_execution_start => |payload| {
                try writeJsonField("type", stringify, "tool_execution_start");
                try writeJsonField("toolCallId", stringify, payload.tool_call_id);
                try writeJsonField("toolName", stringify, payload.tool_name);
                try writeJsonField("args", stringify, payload.args);
            },
            .tool_execution_update => |payload| {
                try writeJsonField("type", stringify, "tool_execution_update");
                try writeJsonField("toolCallId", stringify, payload.tool_call_id);
                try writeJsonField("toolName", stringify, payload.tool_name);
                try writeJsonField("args", stringify, payload.args);
                try writeJsonField("partialResult", stringify, payload.partial_result);
            },
            .tool_execution_end => |payload| {
                try writeJsonField("type", stringify, "tool_execution_end");
                try writeJsonField("toolCallId", stringify, payload.tool_call_id);
                try writeJsonField("toolName", stringify, payload.tool_name);
                try writeJsonField("result", stringify, payload.result);
                try writeJsonField("isError", stringify, payload.is_error);
            },
        }
        try stringify.endObject();
    }
};

fn writeJsonField(comptime name: []const u8, stringify: *std.json.Stringify, value: anytype) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

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
    _: *ToolRuntime,
    _: ?*anyopaque,
    _: runtime.CancelToken,
    _: []const u8,
    _: std.json.Value,
    _: ?AgentToolUpdateCallback,
) anyerror!ToolExecutionResult {
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
