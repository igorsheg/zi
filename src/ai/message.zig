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

/// Deep-copies a canonical message into storage released in bulk by the
/// caller. On failure, previously allocated bytes remain owned by `allocator`.
/// Use an arena or another bulk-lifetime allocator.
pub fn copyLeaky(allocator: std.mem.Allocator, source: Message) error{OutOfMemory}!Message {
    return switch (source) {
        .request => |request| .{ .request = try copyRequestLeaky(allocator, request) },
        .response => |response| .{ .response = try copyResponseLeaky(allocator, response) },
    };
}

pub fn copyRequestLeaky(
    allocator: std.mem.Allocator,
    source: RequestMessage,
) error{OutOfMemory}!RequestMessage {
    const parts = try allocator.alloc(RequestPart, source.parts.len);
    for (source.parts, parts) |part, *copy| copy.* = switch (part) {
        .user => |user| .{ .user = try copyUserContentLeaky(allocator, user) },
        .tool_result => |result| .{ .tool_result = try copyToolResultLeaky(allocator, result) },
        .retry_prompt => |text| .{ .retry_prompt = try allocator.dupe(u8, text) },
    };
    return .{ .parts = parts };
}

pub fn copyUserContentLeaky(
    allocator: std.mem.Allocator,
    source: UserContent,
) error{OutOfMemory}!UserContent {
    return switch (source) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .image => |image| .{ .image = try copyImageLeaky(allocator, image) },
    };
}

pub fn copyResponseLeaky(
    allocator: std.mem.Allocator,
    source: ResponseMessage,
) error{OutOfMemory}!ResponseMessage {
    const parts = try allocator.alloc(ResponsePart, source.parts.len);
    for (source.parts, parts) |part, *copy| copy.* = try copyResponsePartLeaky(allocator, part);
    return .{
        .parts = parts,
        .identity = try copyIdentityLeaky(allocator, source.identity),
        .usage = source.usage,
        .finish = .{
            .category = source.finish.category,
            .raw_reason = if (source.finish.raw_reason) |reason|
                try allocator.dupe(u8, reason)
            else
                null,
        },
    };
}

pub fn copyResponsePartLeaky(
    allocator: std.mem.Allocator,
    source: ResponsePart,
) error{OutOfMemory}!ResponsePart {
    return switch (source) {
        .text => |text| .{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .provider_state = if (text.provider_state) |state|
                try copyProviderStateLeaky(allocator, state)
            else
                null,
        } },
        .thinking => |thinking| .{ .thinking = .{
            .text = try allocator.dupe(u8, thinking.text),
            .provider_state = if (thinking.provider_state) |state|
                try copyProviderStateLeaky(allocator, state)
            else
                null,
        } },
        .tool_call => |call| .{ .tool_call = .{
            .id = try allocator.dupe(u8, call.id),
            .name = try allocator.dupe(u8, call.name),
            .arguments_json = try allocator.dupe(u8, call.arguments_json),
            .provider_state = if (call.provider_state) |state|
                try copyProviderStateLeaky(allocator, state)
            else
                null,
        } },
    };
}

pub fn copyToolResultLeaky(
    allocator: std.mem.Allocator,
    source: ToolResult,
) error{OutOfMemory}!ToolResult {
    return .{
        .call_id = try allocator.dupe(u8, source.call_id),
        .name = try allocator.dupe(u8, source.name),
        .content = try copyContentLeaky(allocator, source.content),
        .outcome = source.outcome,
    };
}

pub fn copyIdentityLeaky(
    allocator: std.mem.Allocator,
    source: ModelIdentity,
) error{OutOfMemory}!ModelIdentity {
    return .{
        .provider = try allocator.dupe(u8, source.provider),
        .model = try allocator.dupe(u8, source.model),
    };
}

fn copyContentLeaky(
    allocator: std.mem.Allocator,
    source: []const Content,
) error{OutOfMemory}![]const Content {
    const content = try allocator.alloc(Content, source.len);
    for (source, content) |item, *copy| copy.* = switch (item) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .image => |image| .{ .image = try copyImageLeaky(allocator, image) },
    };
    return content;
}

fn copyImageLeaky(allocator: std.mem.Allocator, source: Image) error{OutOfMemory}!Image {
    return .{
        .media_type = try allocator.dupe(u8, source.media_type),
        .source = switch (source.source) {
            .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
            .url => |url| .{ .url = try allocator.dupe(u8, url) },
        },
    };
}

fn copyProviderStateLeaky(
    allocator: std.mem.Allocator,
    source: ProviderState,
) error{OutOfMemory}!ProviderState {
    return .{
        .provider = try allocator.dupe(u8, source.provider),
        .protocol = try allocator.dupe(u8, source.protocol),
        .value = try copyJsonLeaky(allocator, source.value),
    };
}

fn copyJsonLeaky(
    allocator: std.mem.Allocator,
    source: std.json.Value,
) error{OutOfMemory}!std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |value| array: {
            var copy = std.json.Array.init(allocator);
            for (value.items) |item| try copy.append(try copyJsonLeaky(allocator, item));
            break :array .{ .array = copy };
        },
        .object => |value| object: {
            var copy: std.json.ObjectMap = .{};
            var iterator = value.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try copy.put(allocator, key, try copyJsonLeaky(allocator, entry.value_ptr.*));
            }
            break :object .{ .object = copy };
        },
    };
}

test "bulk copy owns every canonical message byte" {
    var source_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"token\":\"owned\"}",
        .{},
    );
    defer source_json.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const copy = try copyLeaky(arena.allocator(), .{ .response = .{
        .parts = &.{.{ .text = .{
            .text = "answer",
            .provider_state = .{
                .provider = "provider",
                .protocol = "protocol",
                .value = source_json.value,
            },
        } }},
        .identity = .{ .provider = "provider", .model = "model" },
        .finish = .{ .category = .stop, .raw_reason = "stop" },
    } });
    source_json.value.object.getPtr("token").?.* = .{ .string = "changed" };

    try std.testing.expectEqualStrings("answer", copy.response.parts[0].text.text);
    try std.testing.expectEqualStrings(
        "owned",
        copy.response.parts[0].text.provider_state.?.value.object.get("token").?.string,
    );
}
