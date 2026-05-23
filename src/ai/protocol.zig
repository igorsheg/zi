const std = @import("std");
const runtime = @import("../runtime/root.zig");

pub const Api = []const u8;
pub const Provider = []const u8;
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

pub const AssistantMessageEventStream = struct {
    pipe: Pipe,

    const Pipe = runtime.EventPipe(AssistantMessageEvent, AssistantMessage);

    pub fn init(buffer: []AssistantMessageEvent) AssistantMessageEventStream {
        return .{ .pipe = Pipe.init(buffer) };
    }

    pub fn sink(self: *AssistantMessageEventStream) AssistantMessageEventSink {
        return .{ .pipe = self.pipe.sink() };
    }

    pub fn next(self: *AssistantMessageEventStream, io: std.Io) Pipe.NextError!?AssistantMessageEvent {
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
    pipe: AssistantMessageEventStream.Pipe.Sink,

    pub fn emit(
        self: AssistantMessageEventSink,
        io: std.Io,
        event: AssistantMessageEvent,
    ) AssistantMessageEventStream.Pipe.EmitError!void {
        switch (event) {
            .done => |done| try self.pipe.emitTerminal(io, event, done.message),
            .@"error" => |err| try self.pipe.emitTerminal(io, event, err.@"error"),
            else => try self.pipe.emit(io, event),
        }
    }
};

test "assistant stream derives terminal message from done event" {
    const message = emptyAssistantMessage(.stop);
    const event: AssistantMessageEvent = .{ .done = .{ .reason = .stop, .message = message } };
    var buffer: [1]AssistantMessageEvent = undefined;
    var stream = AssistantMessageEventStream.init(&buffer);
    const sink = stream.sink();

    try sink.emit(std.Io.failing, event);

    const received = try stream.next(std.Io.failing);
    try std.testing.expect(received.? == .done);
    try std.testing.expectEqual(@as(?AssistantMessage, message), stream.result());
    try std.testing.expectEqual(@as(?AssistantMessageEvent, null), try stream.next(std.Io.failing));
}

test "assistant stream drains events and returns result" {
    const message = emptyAssistantMessage(.stop);
    const event: AssistantMessageEvent = .{ .done = .{ .reason = .stop, .message = message } };
    var buffer: [1]AssistantMessageEvent = undefined;
    var stream = AssistantMessageEventStream.init(&buffer);
    const sink = stream.sink();
    var handler: CountingHandler = .{};

    try sink.emit(std.Io.failing, event);

    const result_message = try AssistantMessageEventStream.drain(CountingHandler, std.Io.failing, &stream, &handler);
    try std.testing.expectEqual(@as(usize, 1), handler.event_count);
    try std.testing.expectEqual(message, result_message);
}

test "assistant stream derives terminal message from error event" {
    var message = emptyAssistantMessage(.aborted);
    message.error_message = "aborted";
    const event: AssistantMessageEvent = .{ .@"error" = .{ .reason = .aborted, .@"error" = message } };
    var buffer: [1]AssistantMessageEvent = undefined;
    var stream = AssistantMessageEventStream.init(&buffer);
    const sink = stream.sink();

    try sink.emit(std.Io.failing, event);

    const received = try stream.next(std.Io.failing);
    try std.testing.expect(received.? == .@"error");
    try std.testing.expectEqual(@as(?AssistantMessage, message), stream.result());
}

const CountingHandler = struct {
    event_count: usize = 0,

    fn onAssistantMessageEvent(self: *CountingHandler, _: AssistantMessageEvent) !void {
        self.event_count += 1;
    }
};

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
