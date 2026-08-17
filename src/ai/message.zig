const usage = @import("usage.zig");

const std = @import("std");

pub const ModelIdentity = struct {
    provider: []const u8,
    model: []const u8,
};

pub const Image = struct {
    media_type: []const u8,
    source: Source,

    pub const Source = union(enum) {
        bytes: []const u8,
        url: []const u8,
    };
};

pub const UserContent = union(enum) {
    text: []const u8,
    image: Image,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json_schema: []const u8,
};

pub const ToolResult = struct {
    call_id: []const u8,
    name: []const u8,
    content: []const Content,
    outcome: Outcome,

    pub const Outcome = enum { success, failure };
};

pub const Content = union(enum) {
    text: []const u8,
    image: Image,
};

pub const RequestPart = union(enum) {
    user: UserContent,
    tool_result: ToolResult,
    retry_prompt: []const u8,
};

pub const RequestMessage = struct {
    parts: []const RequestPart,
};

pub const ProviderState = struct {
    provider: []const u8,
    protocol: []const u8,
    value: std.json.Value,
};

pub const TextPart = struct {
    text: []const u8,
    provider_state: ?ProviderState = null,
};

pub const ThinkingPart = struct {
    text: []const u8,
    provider_state: ?ProviderState = null,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    provider_state: ?ProviderState = null,
};

pub const ResponsePart = union(enum) {
    text: TextPart,
    thinking: ThinkingPart,
    tool_call: ToolCall,
};

pub const ResponseMessage = struct {
    parts: []const ResponsePart,
    identity: ModelIdentity,
    usage: usage.Usage = .{},
    finish: usage.Finish = .{},
};

pub const Message = union(enum) {
    request: RequestMessage,
    response: ResponseMessage,
};
