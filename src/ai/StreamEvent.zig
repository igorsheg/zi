const Usage = @import("Usage.zig");

/// One borrowed event emitted synchronously by a provider stream.
pub const StreamEvent = union(enum) {
    text_delta: []const u8,
    tool_call_start: ToolCallStart,
    tool_call_delta: ToolCallDelta,
    tool_call_end: []const u8,
    reasoning_item: ReasoningItem,
    reasoning_delta: ?[]const u8,
    retry: Retry,
    progress: Progress,
    done: Done,
    failure: Failure,
};

pub const ToolCallStart = struct {
    id: []const u8,
    name: []const u8,
};

pub const ToolCallDelta = struct {
    id: []const u8,
    arguments_delta: []const u8,
};

pub const ReasoningItem = struct {
    opaque_json: []const u8,
};

pub const Retry = struct {
    attempt: u16,
    maximum_attempts: u16,
    delay_ms: u64,
    http_status: ?u16 = null,
    usage: ?Usage.StreamUsage = null,
};

pub const Progress = struct {
    processed_tokens: u64,
    total_tokens: u64,
    cached_tokens: u64,
};

pub const ResponseIdentity = struct {
    id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    route: ?[]const u8 = null,
};

pub const Done = struct {
    stop_reason: ?[]const u8 = null,
    usage: Usage.StreamUsage = .{},
    response: ResponseIdentity = .{},
};

pub const Failure = struct {
    message: []const u8,
    http_status: ?u16 = null,
    usage: ?Usage.StreamUsage = null,
    response: ?ResponseIdentity = null,
};
