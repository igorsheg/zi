const std = @import("std");
const runtime = @import("../zistd/root.zig");

pub const Api = []const u8;
pub const Provider = []const u8;

pub const KnownApi = struct {
    pub const openai_completions = "openai-completions";
    pub const openai_responses = "openai-responses";
    pub const openai_codex_responses = "openai-codex-responses";
    pub const anthropic_messages = "anthropic-messages";
};

pub const KnownProvider = struct {
    pub const anthropic = "anthropic";
    pub const openai = "openai";
    pub const openai_codex = "openai-codex";
    pub const openrouter = "openrouter";
    pub const fireworks = "fireworks";
};
pub const Timestamp = i64;

pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const CacheRetention = enum {
    none,
    short,
    long,
};

pub const Transport = enum {
    sse,
    websocket,
    auto,
};

pub const ProviderResponse = struct {
    status: u16,
    headers: std.json.Value,
};

pub const StreamOptions = struct {
    temperature: ?f64 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: ?Transport = null,
    cache_retention: ?CacheRetention = null,
    session_id: ?[]const u8 = null,
    headers: ?std.json.Value = null,
    timeout_ms: ?u64 = null,
    max_retries: ?u32 = null,
    max_retry_delay_ms: ?u64 = null,
    metadata: ?std.json.Value = null,
};

pub const ThinkingBudgets = struct {
    minimal: ?u32 = null,
    low: ?u32 = null,
    medium: ?u32 = null,
    high: ?u32 = null,
};

pub const SimpleStreamOptions = struct {
    stream: StreamOptions = .{},
    reasoning: ?ThinkingLevel = null,
    thinking_budgets: ?ThinkingBudgets = null,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: Provider,
    base_url: []const u8,
    reasoning: bool,
    input: []const Input,
    cost: Cost,
    context_window: u64,
    max_tokens: u64,
    headers: ?std.json.Value = null,
    compat: ?std.json.Value = null,

    pub const Input = enum {
        text,
        image,
    };

    pub const Cost = struct {
        input: f64,
        output: f64,
        cache_read: f64,
        cache_write: f64,
    };
};

pub const StreamRequest = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    model: Model,
    context: Context,
    options: StreamOptions = .{},
    cancel_token: ?runtime.CancelToken = null,
};

pub const StreamFunction = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, StreamRequest) AssistantMessageEventStream,

    pub fn call(self: StreamFunction, request: StreamRequest) AssistantMessageEventStream {
        return self.call_fn(self.context, request);
    }
};

pub const TextSignatureV1 = struct {
    v: u8,
    id: []const u8,
    phase: ?Phase = null,

    pub const Phase = enum {
        commentary,
        final_answer,
    };
};

pub const TextContent = struct {
    text: []const u8,
    text_signature: ?[]const u8 = null,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    redacted: bool = false,
};

pub const ImageContent = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    thought_signature: ?[]const u8 = null,
};

pub const Usage = struct {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    total_tokens: u64,
    cost: Cost,

    pub const Cost = struct {
        input: f64,
        output: f64,
        cache_read: f64,
        cache_write: f64,
        total: f64,
    };
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    error_,
    aborted,
};

pub const UserContent = union(enum) {
    text: TextContent,
    image: ImageContent,
};

pub const AssistantContent = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    tool_call: ToolCall,
};

pub const ToolResultContent = union(enum) {
    text: TextContent,
    image: ImageContent,
};

pub const UserMessage = struct {
    content: Content,
    timestamp: Timestamp,

    pub const Content = union(enum) {
        string: []const u8,
        blocks: []const UserContent,
    };
};

pub const AssistantMessage = struct {
    content: []const AssistantContent,
    api: Api,
    provider: Provider,
    model: []const u8,
    response_id: ?[]const u8 = null,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: Timestamp,
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ToolResultContent,
    details: ?std.json.Value = null,
    is_error: bool,
    timestamp: Timestamp,
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};

pub const AssistantMessageEvent = union(enum) {
    start: Start,
    text_start: IndexedPartial,
    text_delta: TextDelta,
    text_end: TextEnd,
    thinking_start: IndexedPartial,
    thinking_delta: TextDelta,
    thinking_end: TextEnd,
    toolcall_start: IndexedPartial,
    toolcall_delta: TextDelta,
    toolcall_end: ToolCallEnd,
    done: Done,
    @"error": Error,

    pub const Start = struct {
        partial: AssistantMessage,
    };

    pub const IndexedPartial = struct {
        content_index: usize,
        partial: AssistantMessage,
    };

    pub const TextDelta = struct {
        content_index: usize,
        delta: []const u8,
        partial: AssistantMessage,
    };

    pub const TextEnd = struct {
        content_index: usize,
        content: []const u8,
        partial: AssistantMessage,
    };

    pub const ToolCallEnd = struct {
        content_index: usize,
        tool_call: ToolCall,
        partial: AssistantMessage,
    };

    pub const Done = struct {
        reason: DoneReason,
        message: AssistantMessage,
    };

    pub const Error = struct {
        reason: ErrorReason,
        @"error": AssistantMessage,
    };
};

pub const DoneReason = enum {
    stop,
    length,
    tool_use,
};

pub const ErrorReason = enum {
    aborted,
    error_,
};

pub const AssistantMessageEventStreamNextError = anyerror;
pub const AssistantMessageEventSinkEmitError = error{StreamEventBufferFull};

pub const AssistantMessageEventStream = struct {
    kind: Kind,

    pub const buffered_event_capacity = 256;

    const Kind = union(enum) {
        buffered: Buffered,
        custom: Custom,
    };

    const Buffered = struct {
        events: [buffered_event_capacity]AssistantMessageEvent = undefined,
        len: usize = 0,
        index: usize = 0,
        terminal_message: ?AssistantMessage = null,
    };

    pub const Custom = struct {
        context: ?*anyopaque,
        next_fn: *const fn (?*anyopaque, std.Io) anyerror!?AssistantMessageEvent,
        result_fn: *const fn (?*anyopaque) ?AssistantMessage,
        deinit_fn: ?*const fn (?*anyopaque) void = null,
    };

    pub fn initBuffered() AssistantMessageEventStream {
        return .{ .kind = .{ .buffered = .{} } };
    }

    pub fn initCustom(custom: Custom) AssistantMessageEventStream {
        return .{ .kind = .{ .custom = custom } };
    }

    pub fn sink(self: *AssistantMessageEventStream) AssistantMessageEventSink {
        std.debug.assert(self.kind == .buffered);
        return .{ .context = self, .emit_fn = emitBufferedFn };
    }

    pub fn next(self: *AssistantMessageEventStream, io: std.Io) anyerror!?AssistantMessageEvent {
        return switch (self.kind) {
            .buffered => |*buffered| nextBuffered(buffered),
            .custom => |custom| custom.next_fn(custom.context, io),
        };
    }

    pub fn result(self: *AssistantMessageEventStream) ?AssistantMessage {
        return switch (self.kind) {
            .buffered => |buffered| buffered.terminal_message,
            .custom => |custom| custom.result_fn(custom.context),
        };
    }

    pub fn deinit(self: *AssistantMessageEventStream) void {
        switch (self.kind) {
            .buffered => {},
            .custom => |custom| if (custom.deinit_fn) |deinit_fn| deinit_fn(custom.context),
        }
        self.* = undefined;
    }

    pub fn drain(
        comptime Handler: type,
        io: std.Io,
        self: *AssistantMessageEventStream,
        handler: *Handler,
    ) !AssistantMessage {
        defer self.deinit();
        while (try self.next(io)) |event| {
            try handler.onAssistantMessageEvent(event);
        }
        return self.result() orelse error.MissingResult;
    }

    fn emitBuffered(self: *AssistantMessageEventStream, event: AssistantMessageEvent) AssistantMessageEventSinkEmitError!void {
        const buffered = &self.kind.buffered;
        switch (event) {
            .done => |done| buffered.terminal_message = done.message,
            .@"error" => |err| buffered.terminal_message = err.@"error",
            else => {},
        }
        if (buffered.len >= buffered.events.len) return error.StreamEventBufferFull;
        buffered.events[buffered.len] = event;
        buffered.len += 1;
    }

    fn nextBuffered(buffered: *Buffered) ?AssistantMessageEvent {
        if (buffered.index >= buffered.len) return null;
        defer buffered.index += 1;
        return buffered.events[buffered.index];
    }

    fn emitBufferedFn(context: ?*anyopaque, _: std.Io, event: AssistantMessageEvent) AssistantMessageEventSinkEmitError!void {
        const self: *AssistantMessageEventStream = @ptrCast(@alignCast(context.?));
        try self.emitBuffered(event);
    }
};

pub const AssistantMessageEventSink = struct {
    context: ?*anyopaque,
    emit_fn: *const fn (?*anyopaque, std.Io, AssistantMessageEvent) AssistantMessageEventSinkEmitError!void,

    pub fn emit(
        self: AssistantMessageEventSink,
        io: std.Io,
        event: AssistantMessageEvent,
    ) AssistantMessageEventSinkEmitError!void {
        try self.emit_fn(self.context, io, event);
    }

    pub fn endDone(
        self: AssistantMessageEventSink,
        io: std.Io,
        reason: DoneReason,
        message: AssistantMessage,
    ) AssistantMessageEventSinkEmitError!void {
        try self.emit(io, .{ .done = .{ .reason = reason, .message = message } });
    }

    pub fn endError(
        self: AssistantMessageEventSink,
        io: std.Io,
        reason: ErrorReason,
        message: AssistantMessage,
    ) AssistantMessageEventSinkEmitError!void {
        try self.emit(io, .{ .@"error" = .{ .reason = reason, .@"error" = message } });
    }

    pub fn endAborted(
        self: AssistantMessageEventSink,
        io: std.Io,
        message: AssistantMessage,
    ) AssistantMessageEventSinkEmitError!void {
        std.debug.assert(message.stop_reason == .aborted);
        try self.endError(io, .aborted, message);
    }
};


pub fn emptyAssistantMessageFromRequest(
    request: StreamRequest,
    stop_reason: StopReason,
    error_message: ?[]const u8,
) AssistantMessage {
    return .{
        .content = &.{},
        .api = request.model.api,
        .provider = request.model.provider,
        .model = request.model.id,
        .usage = emptyUsage(),
        .stop_reason = stop_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
}

pub fn emptyUsage() Usage {
    return .{
        .input = 0,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .total_tokens = 0,
        .cost = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total = 0,
        },
    };
}

test "stream function calls provider implementation with request" {
    var calls: usize = 0;
    const request: StreamRequest = .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = emptyModel(),
        .context = .{ .messages = &.{} },
    };
    const stream_function: StreamFunction = .{
        .context = &calls,
        .call_fn = testStreamFunction,
    };

    var stream = stream_function.call(request);

    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(?AssistantMessage, null), stream.result());
}

test "known api and provider names stay wire strings" {
    try std.testing.expectEqualStrings("openai-responses", KnownApi.openai_responses);
    try std.testing.expectEqualStrings("anthropic", KnownProvider.anthropic);
}

test "assistant stream derives terminal message from done event" {
    const message = emptyAssistantMessage(.stop);
    var stream = AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    try sink.endDone(std.Io.failing, .stop, message);

    const received = try stream.next(std.Io.failing);
    try std.testing.expect(received.? == .done);
    try std.testing.expectEqual(@as(?AssistantMessage, message), stream.result());
    try std.testing.expectEqual(@as(?AssistantMessageEvent, null), try stream.next(std.Io.failing));
}

test "assistant stream drains events and returns result" {
    const message = emptyAssistantMessage(.stop);
    var stream = AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();
    var handler: CountingHandler = .{};

    try sink.endDone(std.Io.failing, .stop, message);

    const result_message = try AssistantMessageEventStream.drain(CountingHandler, std.Io.failing, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), handler.event_count);
    try std.testing.expectEqual(message, result_message);
}

test "assistant stream derives terminal message from error event" {
    var message = emptyAssistantMessage(.aborted);
    message.error_message = "aborted";
    var stream = AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    try sink.endAborted(std.Io.failing, message);

    const received = try stream.next(std.Io.failing);
    try std.testing.expect(received.? == .@"error");
    try std.testing.expectEqual(@as(?AssistantMessage, message), stream.result());
}

test "empty assistant message from request preserves provider identity" {
    const request: StreamRequest = .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = emptyModel(),
        .context = .{ .messages = &.{} },
    };

    const message = emptyAssistantMessageFromRequest(request, .aborted, "aborted");

    try std.testing.expectEqualStrings(KnownApi.openai_responses, message.api);
    try std.testing.expectEqualStrings(KnownProvider.openai, message.provider);
    try std.testing.expectEqualStrings("test-model", message.model);
    try std.testing.expectEqual(StopReason.aborted, message.stop_reason);
    try std.testing.expectEqualStrings("aborted", message.error_message.?);
}

const CountingHandler = struct {
    event_count: usize = 0,

    fn onAssistantMessageEvent(self: *CountingHandler, _: AssistantMessageEvent) !void {
        self.event_count += 1;
    }
};

fn testStreamFunction(context: ?*anyopaque, request: StreamRequest) AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    _ = request;
    return AssistantMessageEventStream.initBuffered();
}

fn emptyModel() Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = KnownApi.openai_responses,
        .provider = KnownProvider.openai,
        .base_url = "https://example.test",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{
            .input = 1,
            .output = 2,
            .cache_read = 0.5,
            .cache_write = 1.5,
        },
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

fn emptyAssistantMessage(stop_reason: StopReason) AssistantMessage {
    return .{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = stop_reason,
        .timestamp = 0,
    };
}
