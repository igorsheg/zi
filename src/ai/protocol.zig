const std = @import("std");
const runtime = @import("../runtime/root.zig");

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
    event_buffer: []AssistantMessageEvent,
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

const AssistantEventPipe = runtime.EventPipe(AssistantMessageEvent, AssistantMessage);

pub const AssistantMessageEventStreamNextError = AssistantEventPipe.NextError;
pub const AssistantMessageEventSinkEmitError = AssistantEventPipe.EmitError;

pub const AssistantMessageEventStream = struct {
    pipe: AssistantEventPipe,

    pub fn init(buffer: []AssistantMessageEvent) AssistantMessageEventStream {
        return .{ .pipe = AssistantEventPipe.init(buffer) };
    }

    pub fn sink(self: *AssistantMessageEventStream) AssistantMessageEventSink {
        return .{ .pipe = self.pipe.sink() };
    }

    pub fn next(self: *AssistantMessageEventStream, io: std.Io) AssistantEventPipe.NextError!?AssistantMessageEvent {
        return self.pipe.stream().next(io);
    }

    pub fn result(self: *AssistantMessageEventStream) ?AssistantMessage {
        return self.pipe.stream().result();
    }

    pub fn drain(
        comptime Handler: type,
        io: std.Io,
        self: *AssistantMessageEventStream,
        handler: *Handler,
    ) !AssistantMessage {
        while (try self.next(io)) |event| {
            try handler.onAssistantMessageEvent(event);
        }
        return self.result() orelse error.MissingResult;
    }
};

pub const AssistantMessageEventSink = struct {
    pipe: AssistantEventPipe.Sink,

    pub fn emit(
        self: AssistantMessageEventSink,
        io: std.Io,
        event: AssistantMessageEvent,
    ) AssistantEventPipe.EmitError!void {
        switch (event) {
            .done => |done| try self.pipe.end(io, event, done.message),
            .@"error" => |err| try self.pipe.end(io, event, err.@"error"),
            else => try self.pipe.emit(io, event),
        }
    }

    pub fn endDone(
        self: AssistantMessageEventSink,
        io: std.Io,
        reason: DoneReason,
        message: AssistantMessage,
    ) AssistantEventPipe.EmitError!void {
        try self.pipe.end(io, .{ .done = .{ .reason = reason, .message = message } }, message);
    }

    pub fn endError(
        self: AssistantMessageEventSink,
        io: std.Io,
        reason: ErrorReason,
        message: AssistantMessage,
    ) AssistantEventPipe.EmitError!void {
        try self.pipe.end(io, .{ .@"error" = .{ .reason = reason, .@"error" = message } }, message);
    }

    pub fn endAborted(
        self: AssistantMessageEventSink,
        io: std.Io,
        message: AssistantMessage,
    ) AssistantEventPipe.EmitError!void {
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
    var event_buffer: [1]AssistantMessageEvent = undefined;
    var calls: usize = 0;
    const request: StreamRequest = .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = emptyModel(),
        .context = .{ .messages = &.{} },
        .event_buffer = &event_buffer,
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
    var buffer: [1]AssistantMessageEvent = undefined;
    var stream = AssistantMessageEventStream.init(&buffer);
    const sink = stream.sink();

    try sink.endDone(std.Io.failing, .stop, message);

    const received = try stream.next(std.Io.failing);
    try std.testing.expect(received.? == .done);
    try std.testing.expectEqual(@as(?AssistantMessage, message), stream.result());
    try std.testing.expectEqual(@as(?AssistantMessageEvent, null), try stream.next(std.Io.failing));
}

test "assistant stream drains events and returns result" {
    const message = emptyAssistantMessage(.stop);
    var buffer: [1]AssistantMessageEvent = undefined;
    var stream = AssistantMessageEventStream.init(&buffer);
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
    var buffer: [1]AssistantMessageEvent = undefined;
    var stream = AssistantMessageEventStream.init(&buffer);
    const sink = stream.sink();

    try sink.endAborted(std.Io.failing, message);

    const received = try stream.next(std.Io.failing);
    try std.testing.expect(received.? == .@"error");
    try std.testing.expectEqual(@as(?AssistantMessage, message), stream.result());
}

test "empty assistant message from request preserves provider identity" {
    var event_buffer: [1]AssistantMessageEvent = undefined;
    const request: StreamRequest = .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = emptyModel(),
        .context = .{ .messages = &.{} },
        .event_buffer = &event_buffer,
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
    return AssistantMessageEventStream.init(request.event_buffer);
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
