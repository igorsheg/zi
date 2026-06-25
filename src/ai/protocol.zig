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

pub fn isContextOverflowText(text: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(text, "rate limit") != null or
        std.ascii.indexOfIgnoreCase(text, "too many requests") != null) return false;
    const needles = [_][]const u8{
        "prompt is too long",
        "request_too_large",
        "input is too long for requested model",
        "exceeds the context window",
        "maximum context length",
        "input token count",
        "exceeds the maximum",
        "maximum prompt length",
        "reduce the length of the messages",
        "maximum allowed input length",
        "context length",
        "context window exceeds limit",
        "exceeded model token limit",
        "model_context_window_exceeded",
        "prompt too long",
        "context_length_exceeded",
        "context length exceeded",
        "too many tokens",
        "token limit exceeded",
    };
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(text, needle) != null) return true;
    }
    return (std.ascii.indexOfIgnoreCase(text, "context") != null and
        (std.ascii.indexOfIgnoreCase(text, "overflow") != null or
            std.ascii.indexOfIgnoreCase(text, "too large") != null or
            std.ascii.indexOfIgnoreCase(text, "maximum") != null or
            std.ascii.indexOfIgnoreCase(text, "length") != null)) or
        (std.ascii.indexOfIgnoreCase(text, "token") != null and
            std.ascii.indexOfIgnoreCase(text, "limit") != null and
            std.ascii.indexOfIgnoreCase(text, "exceed") != null);
}

pub const OperationalFailure = struct {
    pub const message_bytes_max = 512;
    pub const detail_bytes_max = 2048;

    category: Category,
    message: []const u8,
    detail: ?[]const u8 = null,
    retryable: Retryable = .unknown,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,

    pub const Category = enum {
        auth_missing,
        auth_rejected,
        rate_limited,
        context_overflow,
        provider_unavailable,
        transport,
        malformed_response,
        canceled,
        unknown,
    };

    pub const Retryable = enum {
        yes,
        no,
        unknown,
    };

    pub fn jsonStringify(self: OperationalFailure, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("category", stringify, jsonOperationalFailureCategory(self.category));
        try writeJsonField("message", stringify, self.message);
        if (self.detail) |detail| try writeJsonField("detail", stringify, detail);
        try writeJsonField("retryable", stringify, jsonOperationalFailureRetryable(self.retryable));
        if (self.provider) |provider| try writeJsonField("provider", stringify, provider);
        if (self.model) |model| try writeJsonField("model", stringify, model);
        try stringify.endObject();
    }
};

pub const StreamOptions = struct {
    temperature: ?f64 = null,
    max_tokens: ?u32 = null,
    reasoning: ?ThinkingLevel = null,
    api_key: ?[]const u8 = null,
    auth_extra: ?std.json.Value = null,
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

pub const ApiCredential = struct {
    api_key: []const u8,
    // Borrowed provider context used synchronously while opening a stream.
    auth_extra: ?std.json.Value = null,
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

    pub fn jsonStringify(self: TextContent, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("type", stringify, "text");
        try writeJsonField("text", stringify, self.text);
        if (self.text_signature) |signature| try writeJsonField("textSignature", stringify, signature);
        try stringify.endObject();
    }
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    thinking_signature: ?[]const u8 = null,
    redacted: bool = false,

    pub fn jsonStringify(self: ThinkingContent, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("type", stringify, "thinking");
        try writeJsonField("thinking", stringify, self.thinking);
        if (self.thinking_signature) |signature| try writeJsonField("thinkingSignature", stringify, signature);
        if (self.redacted) try writeJsonField("redacted", stringify, true);
        try stringify.endObject();
    }
};

pub const ImageContent = struct {
    data: []const u8,
    mime_type: []const u8,

    pub fn jsonStringify(self: ImageContent, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("type", stringify, "image");
        try writeJsonField("data", stringify, self.data);
        try writeJsonField("mimeType", stringify, self.mime_type);
        try stringify.endObject();
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
    thought_signature: ?[]const u8 = null,

    pub fn jsonStringify(self: ToolCall, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("type", stringify, "toolCall");
        try writeJsonField("id", stringify, self.id);
        try writeJsonField("name", stringify, self.name);
        try writeJsonField("arguments", stringify, self.arguments);
        if (self.thought_signature) |signature| try writeJsonField("thoughtSignature", stringify, signature);
        try stringify.endObject();
    }
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

        pub fn jsonStringify(self: Usage.Cost, stringify: *std.json.Stringify) !void {
            try stringify.beginObject();
            try writeJsonField("input", stringify, self.input);
            try writeJsonField("output", stringify, self.output);
            try writeJsonField("cacheRead", stringify, self.cache_read);
            try writeJsonField("cacheWrite", stringify, self.cache_write);
            try writeJsonField("total", stringify, self.total);
            try stringify.endObject();
        }
    };

    pub fn jsonStringify(self: Usage, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("input", stringify, self.input);
        try writeJsonField("output", stringify, self.output);
        try writeJsonField("cacheRead", stringify, self.cache_read);
        try writeJsonField("cacheWrite", stringify, self.cache_write);
        try writeJsonField("totalTokens", stringify, self.total_tokens);
        try writeJsonField("cost", stringify, self.cost);
        try stringify.endObject();
    }
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

    pub fn jsonStringify(self: UserContent, stringify: *std.json.Stringify) !void {
        switch (self) {
            .text => |text| try stringify.write(text),
            .image => |image| try stringify.write(image),
        }
    }
};

pub const AssistantContent = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    tool_call: ToolCall,

    pub fn jsonStringify(self: AssistantContent, stringify: *std.json.Stringify) !void {
        switch (self) {
            .text => |text| try stringify.write(text),
            .thinking => |thinking| try stringify.write(thinking),
            .tool_call => |tool_call| try stringify.write(tool_call),
        }
    }
};

pub const ToolResultContent = union(enum) {
    text: TextContent,
    image: ImageContent,

    pub fn jsonStringify(self: ToolResultContent, stringify: *std.json.Stringify) !void {
        switch (self) {
            .text => |text| try stringify.write(text),
            .image => |image| try stringify.write(image),
        }
    }
};

pub const UserMessage = struct {
    content: Content,
    timestamp: Timestamp,

    pub const Content = union(enum) {
        string: []const u8,
        blocks: []const UserContent,

        pub fn jsonStringify(self: Content, stringify: *std.json.Stringify) !void {
            switch (self) {
                .string => |text| try stringify.write(text),
                .blocks => |blocks| try stringify.write(blocks),
            }
        }
    };

    pub fn jsonStringify(self: UserMessage, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("role", stringify, "user");
        try writeJsonField("content", stringify, self.content);
        try writeJsonField("timestamp", stringify, self.timestamp);
        try stringify.endObject();
    }
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
    operational_failure: ?OperationalFailure = null,
    timestamp: Timestamp,

    pub fn jsonStringify(self: AssistantMessage, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("role", stringify, "assistant");
        try writeJsonField("content", stringify, self.content);
        try writeJsonField("api", stringify, self.api);
        try writeJsonField("provider", stringify, self.provider);
        try writeJsonField("model", stringify, self.model);
        if (self.response_id) |id| try writeJsonField("responseId", stringify, id);
        try writeJsonField("usage", stringify, self.usage);
        try writeJsonField("stopReason", stringify, jsonStopReason(self.stop_reason));
        if (self.error_message) |message| try writeJsonField("errorMessage", stringify, message);
        if (self.operational_failure) |failure| try writeJsonField("operationalFailure", stringify, failure);
        try writeJsonField("timestamp", stringify, self.timestamp);
        try stringify.endObject();
    }
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ToolResultContent,
    details: ?std.json.Value = null,
    is_error: bool,
    timestamp: Timestamp,

    pub fn jsonStringify(self: ToolResultMessage, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("role", stringify, "toolResult");
        try writeJsonField("toolCallId", stringify, self.tool_call_id);
        try writeJsonField("toolName", stringify, self.tool_name);
        try writeJsonField("content", stringify, self.content);
        if (self.details) |details| try writeJsonField("details", stringify, details);
        try writeJsonField("isError", stringify, self.is_error);
        try writeJsonField("timestamp", stringify, self.timestamp);
        try stringify.endObject();
    }
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,

    pub fn jsonStringify(self: Message, stringify: *std.json.Stringify) !void {
        switch (self) {
            .user => |message| try stringify.write(message),
            .assistant => |message| try stringify.write(message),
            .tool_result => |message| try stringify.write(message),
        }
    }
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

    pub fn jsonStringify(self: AssistantMessageEvent, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        switch (self) {
            .start => |payload| {
                try writeJsonField("type", stringify, "start");
                try writeJsonField("partial", stringify, payload.partial);
            },
            .text_start => |payload| try writeIndexedPartial("text_start", stringify, payload),
            .text_delta => |payload| try writeTextDelta("text_delta", stringify, payload),
            .text_end => |payload| try writeTextEnd("text_end", stringify, payload),
            .thinking_start => |payload| try writeIndexedPartial("thinking_start", stringify, payload),
            .thinking_delta => |payload| try writeTextDelta("thinking_delta", stringify, payload),
            .thinking_end => |payload| try writeTextEnd("thinking_end", stringify, payload),
            .toolcall_start => |payload| try writeIndexedPartial("toolcall_start", stringify, payload),
            .toolcall_delta => |payload| try writeTextDelta("toolcall_delta", stringify, payload),
            .toolcall_end => |payload| {
                try writeJsonField("type", stringify, "toolcall_end");
                try writeJsonField("contentIndex", stringify, payload.content_index);
                try writeJsonField("toolCall", stringify, payload.tool_call);
                try writeJsonField("partial", stringify, payload.partial);
            },
            .done => |payload| {
                try writeJsonField("type", stringify, "done");
                try writeJsonField("reason", stringify, jsonDoneReason(payload.reason));
                try writeJsonField("message", stringify, payload.message);
            },
            .@"error" => |payload| {
                try writeJsonField("type", stringify, "error");
                try writeJsonField("reason", stringify, jsonErrorReason(payload.reason));
                try writeJsonField("error", stringify, payload.@"error");
            },
        }
        try stringify.endObject();
    }
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

fn writeJsonField(comptime name: []const u8, stringify: *std.json.Stringify, value: anytype) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn writeIndexedPartial(
    comptime event_type: []const u8,
    stringify: *std.json.Stringify,
    payload: AssistantMessageEvent.IndexedPartial,
) !void {
    try writeJsonField("type", stringify, event_type);
    try writeJsonField("contentIndex", stringify, payload.content_index);
    try writeJsonField("partial", stringify, payload.partial);
}

fn writeTextDelta(
    comptime event_type: []const u8,
    stringify: *std.json.Stringify,
    payload: AssistantMessageEvent.TextDelta,
) !void {
    try writeJsonField("type", stringify, event_type);
    try writeJsonField("contentIndex", stringify, payload.content_index);
    try writeJsonField("delta", stringify, payload.delta);
    try writeJsonField("partial", stringify, payload.partial);
}

fn writeTextEnd(
    comptime event_type: []const u8,
    stringify: *std.json.Stringify,
    payload: AssistantMessageEvent.TextEnd,
) !void {
    try writeJsonField("type", stringify, event_type);
    try writeJsonField("contentIndex", stringify, payload.content_index);
    try writeJsonField("content", stringify, payload.content);
    try writeJsonField("partial", stringify, payload.partial);
}

fn jsonStopReason(reason: StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_ => "error",
        .aborted => "aborted",
    };
}

fn jsonDoneReason(reason: DoneReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
    };
}

fn jsonOperationalFailureCategory(category: OperationalFailure.Category) []const u8 {
    return switch (category) {
        .auth_missing => "authMissing",
        .auth_rejected => "authRejected",
        .rate_limited => "rateLimited",
        .context_overflow => "contextOverflow",
        .provider_unavailable => "providerUnavailable",
        .transport => "transport",
        .malformed_response => "malformedResponse",
        .canceled => "canceled",
        .unknown => "unknown",
    };
}

fn jsonOperationalFailureRetryable(retryable: OperationalFailure.Retryable) []const u8 {
    return switch (retryable) {
        .yes => "yes",
        .no => "no",
        .unknown => "unknown",
    };
}

fn jsonErrorReason(reason: ErrorReason) []const u8 {
    return switch (reason) {
        .aborted => "aborted",
        .error_ => "error",
    };
}

// anyerror is deliberate: next() bottoms out in provider transport code
// (HTTP, SSE, process), whose failure sets are open-ended. Callers do not
// branch on these errors — the loop converts any stream failure into a
// terminal assistant message, and retry classification happens on that
// message, not on the error value.
pub const AssistantMessageEventStreamNextError = anyerror;
pub const AssistantMessageEventSinkEmitError = error{StreamEventBufferFull};

pub const AssistantMessageEventStream = struct {
    kind: Kind,

    /// The buffered variant is for tests and short synthetic streams only:
    /// it holds at most `buffered_event_capacity` pre-recorded events and
    /// fails emit with StreamEventBufferFull beyond that. Real providers
    /// stream thousands of delta events and must use `initCustom`, which
    /// pulls events on demand.
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

    fn emitBuffered(
        self: *AssistantMessageEventStream,
        event: AssistantMessageEvent,
    ) AssistantMessageEventSinkEmitError!void {
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

    fn emitBufferedFn(
        _: std.Io,
        context: ?*anyopaque,
        event: AssistantMessageEvent,
    ) AssistantMessageEventSinkEmitError!void {
        const self: *AssistantMessageEventStream = @ptrCast(@alignCast(context.?));
        try self.emitBuffered(event);
    }
};

pub const AssistantMessageEventSink = struct {
    context: ?*anyopaque,
    emit_fn: *const fn (std.Io, ?*anyopaque, AssistantMessageEvent) AssistantMessageEventSinkEmitError!void,

    pub fn emit(
        self: AssistantMessageEventSink,
        io: std.Io,
        event: AssistantMessageEvent,
    ) AssistantMessageEventSinkEmitError!void {
        try self.emit_fn(io, self.context, event);
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

// Golden wire shapes. The jsonStringify implementations hand-write their
// camelCase keys, so a renamed struct field cannot drift silently: this test
// pins the full encoding of every message role with all optionals set.
test "message wire shapes are pinned" {
    const assistant: Message = .{ .assistant = .{
        .content = &.{
            .{ .text = .{ .text = "hi", .text_signature = "sig-t" } },
            .{ .thinking = .{ .thinking = "hm", .thinking_signature = "sig-k", .redacted = true } },
            .{ .tool_call = .{
                .id = "call-1",
                .name = "bash",
                .arguments = .{ .object = .empty },
                .thought_signature = "sig-c",
            } },
        },
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .response_id = "resp-1",
        .usage = .{
            .input = 1,
            .output = 2,
            .cache_read = 3,
            .cache_write = 4,
            .total_tokens = 10,
            .cost = .{ .input = 0.5, .output = 1.5, .cache_read = 0.25, .cache_write = 0.75, .total = 3 },
        },
        .stop_reason = .tool_use,
        .error_message = "boom",
        .timestamp = 7,
    } };
    const user: Message = .{ .user = .{
        .content = .{ .blocks = &.{
            .{ .text = .{ .text = "look" } },
            .{ .image = .{ .data = "QUJD", .mime_type = "image/png" } },
        } },
        .timestamp = 8,
    } };
    const tool_result: Message = .{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .content = &.{.{ .text = .{ .text = "ok" } }},
        .is_error = false,
        .timestamp = 9,
    } };

    try expectWireShape(assistant, "{\"role\":\"assistant\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"hi\",\"textSignature\":\"sig-t\"}," ++
        "{\"type\":\"thinking\",\"thinking\":\"hm\",\"thinkingSignature\":\"sig-k\",\"redacted\":true}," ++
        "{\"type\":\"toolCall\",\"id\":\"call-1\",\"name\":\"bash\",\"arguments\":{}," ++
        "\"thoughtSignature\":\"sig-c\"}]," ++
        "\"api\":\"test-api\",\"provider\":\"test-provider\",\"model\":\"test-model\"," ++
        "\"responseId\":\"resp-1\"," ++
        "\"usage\":{\"input\":1,\"output\":2,\"cacheRead\":3,\"cacheWrite\":4,\"totalTokens\":10," ++
        "\"cost\":{\"input\":0.5,\"output\":1.5,\"cacheRead\":0.25,\"cacheWrite\":0.75,\"total\":3}}," ++
        "\"stopReason\":\"toolUse\",\"errorMessage\":\"boom\",\"timestamp\":7}");
    try expectWireShape(user, "{\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"look\"}," ++
        "{\"type\":\"image\",\"data\":\"QUJD\",\"mimeType\":\"image/png\"}],\"timestamp\":8}");
    try expectWireShape(tool_result, "{\"role\":\"toolResult\",\"toolCallId\":\"call-1\"," ++
        "\"toolName\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]," ++
        "\"isError\":false,\"timestamp\":9}");
}

fn expectWireShape(value: anytype, expected: []const u8) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    try std.testing.expectEqualStrings(expected, output.written());
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
