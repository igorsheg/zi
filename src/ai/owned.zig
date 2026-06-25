const std = @import("std");
const runtime = @import("../runtime/root.zig");
const protocol = @import("protocol.zig");

pub const RetainedAssistantMessage = struct {
    arena: std.heap.ArenaAllocator,
    value: protocol.AssistantMessage,

    pub fn copy(backing_allocator: std.mem.Allocator, source: protocol.AssistantMessage) !RetainedAssistantMessage {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const value = try copyAssistantMessage(arena.allocator(), source);
        return .{ .arena = arena, .value = value };
    }

    pub fn deinit(self: *RetainedAssistantMessage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn copyAssistantMessage(
    allocator: std.mem.Allocator,
    source: protocol.AssistantMessage,
) !protocol.AssistantMessage {
    const content = try copyAssistantContentSlice(allocator, source.content);
    errdefer deinitAssistantContentSlice(allocator, content);
    const api = try allocator.dupe(u8, source.api);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, source.provider);
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, source.model);
    errdefer allocator.free(model);
    const response_id = try copyOptionalString(allocator, source.response_id);
    errdefer if (response_id) |value| allocator.free(value);
    const error_message = try copyOptionalString(allocator, source.error_message);
    errdefer if (error_message) |value| allocator.free(value);
    const operational_failure = try copyOptionalOperationalFailure(allocator, source.operational_failure);
    errdefer if (operational_failure) |failure| deinitOperationalFailure(allocator, failure);

    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .response_id = response_id,
        .usage = source.usage,
        .stop_reason = source.stop_reason,
        .error_message = error_message,
        .operational_failure = operational_failure,
        .timestamp = source.timestamp,
    };
}

pub fn deinitAssistantMessage(allocator: std.mem.Allocator, message: protocol.AssistantMessage) void {
    deinitAssistantContentSlice(allocator, message.content);
    allocator.free(message.api);
    allocator.free(message.provider);
    allocator.free(message.model);
    if (message.response_id) |value| allocator.free(value);
    if (message.error_message) |value| allocator.free(value);
    if (message.operational_failure) |failure| deinitOperationalFailure(allocator, failure);
}

fn copyOptionalOperationalFailure(
    allocator: std.mem.Allocator,
    source: ?protocol.OperationalFailure,
) !?protocol.OperationalFailure {
    const failure = source orelse return null;
    const message = try allocator.dupe(u8, failure.message);
    errdefer allocator.free(message);
    const detail = try copyOptionalString(allocator, failure.detail);
    errdefer if (detail) |value| allocator.free(value);
    const provider = try copyOptionalString(allocator, failure.provider);
    errdefer if (provider) |value| allocator.free(value);
    const model = try copyOptionalString(allocator, failure.model);
    errdefer if (model) |value| allocator.free(value);
    return .{
        .category = failure.category,
        .message = message,
        .detail = detail,
        .retryable = failure.retryable,
        .provider = provider,
        .model = model,
    };
}

fn deinitOperationalFailure(allocator: std.mem.Allocator, failure: protocol.OperationalFailure) void {
    allocator.free(failure.message);
    if (failure.detail) |value| allocator.free(value);
    if (failure.provider) |value| allocator.free(value);
    if (failure.model) |value| allocator.free(value);
}

pub fn deinitAssistantMessageEvent(allocator: std.mem.Allocator, event: protocol.AssistantMessageEvent) void {
    switch (event) {
        .start => |payload| deinitAssistantMessage(allocator, payload.partial),
        .text_start => |payload| deinitAssistantMessage(allocator, payload.partial),
        .text_delta => |payload| {
            allocator.free(payload.delta);
            deinitAssistantMessage(allocator, payload.partial);
        },
        .text_end => |payload| {
            allocator.free(payload.content);
            deinitAssistantMessage(allocator, payload.partial);
        },
        .thinking_start => |payload| deinitAssistantMessage(allocator, payload.partial),
        .thinking_delta => |payload| {
            allocator.free(payload.delta);
            deinitAssistantMessage(allocator, payload.partial);
        },
        .thinking_end => |payload| {
            allocator.free(payload.content);
            deinitAssistantMessage(allocator, payload.partial);
        },
        .toolcall_start => |payload| deinitAssistantMessage(allocator, payload.partial),
        .toolcall_delta => |payload| {
            allocator.free(payload.delta);
            deinitAssistantMessage(allocator, payload.partial);
        },
        .toolcall_end => |payload| {
            deinitToolCall(allocator, payload.tool_call);
            deinitAssistantMessage(allocator, payload.partial);
        },
        .done => |payload| deinitAssistantMessage(allocator, payload.message),
        .@"error" => |payload| deinitAssistantMessage(allocator, payload.@"error"),
    }
}

pub fn copyAssistantMessageEvent(
    allocator: std.mem.Allocator,
    source: protocol.AssistantMessageEvent,
) !protocol.AssistantMessageEvent {
    return switch (source) {
        .start => |start| .{ .start = .{ .partial = try copyAssistantMessage(allocator, start.partial) } },
        .text_start => |event| .{ .text_start = .{
            .content_index = event.content_index,
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .text_delta => |event| .{ .text_delta = .{
            .content_index = event.content_index,
            .delta = try allocator.dupe(u8, event.delta),
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .text_end => |event| .{ .text_end = .{
            .content_index = event.content_index,
            .content = try allocator.dupe(u8, event.content),
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .thinking_start => |event| .{ .thinking_start = .{
            .content_index = event.content_index,
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .thinking_delta => |event| .{ .thinking_delta = .{
            .content_index = event.content_index,
            .delta = try allocator.dupe(u8, event.delta),
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .thinking_end => |event| .{ .thinking_end = .{
            .content_index = event.content_index,
            .content = try allocator.dupe(u8, event.content),
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .toolcall_start => |event| .{ .toolcall_start = .{
            .content_index = event.content_index,
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .toolcall_delta => |event| .{ .toolcall_delta = .{
            .content_index = event.content_index,
            .delta = try allocator.dupe(u8, event.delta),
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .toolcall_end => |event| .{ .toolcall_end = .{
            .content_index = event.content_index,
            .tool_call = try copyToolCall(allocator, event.tool_call),
            .partial = try copyAssistantMessage(allocator, event.partial),
        } },
        .done => |done| .{ .done = .{
            .reason = done.reason,
            .message = try copyAssistantMessage(allocator, done.message),
        } },
        .@"error" => |err| .{ .@"error" = .{
            .reason = err.reason,
            .@"error" = try copyAssistantMessage(allocator, err.@"error"),
        } },
    };
}

pub fn copyAssistantContentSlice(
    allocator: std.mem.Allocator,
    source: []const protocol.AssistantContent,
) ![]const protocol.AssistantContent {
    const cloned = try allocator.alloc(protocol.AssistantContent, source.len);
    var initialized: usize = 0;
    errdefer {
        deinitAssistantContentItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (source, cloned) |content, *out| {
        out.* = try copyAssistantContent(allocator, content);
        initialized += 1;
    }
    return cloned;
}

pub fn copyAssistantContent(
    allocator: std.mem.Allocator,
    source: protocol.AssistantContent,
) !protocol.AssistantContent {
    return switch (source) {
        .text => |text| blk: {
            const text_copy = try allocator.dupe(u8, text.text);
            errdefer allocator.free(text_copy);
            const signature = try copyOptionalString(allocator, text.text_signature);
            break :blk .{ .text = .{ .text = text_copy, .text_signature = signature } };
        },
        .thinking => |thinking| blk: {
            const thinking_copy = try allocator.dupe(u8, thinking.thinking);
            errdefer allocator.free(thinking_copy);
            const signature = try copyOptionalString(allocator, thinking.thinking_signature);
            break :blk .{ .thinking = .{
                .thinking = thinking_copy,
                .thinking_signature = signature,
                .redacted = thinking.redacted,
            } };
        },
        .tool_call => |tool_call| blk: {
            const id = try allocator.dupe(u8, tool_call.id);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, tool_call.name);
            errdefer allocator.free(name);
            const arguments = try runtime.cloneJsonValue(allocator, tool_call.arguments);
            errdefer runtime.freeJsonValue(allocator, arguments);
            const signature = try copyOptionalString(allocator, tool_call.thought_signature);
            break :blk .{ .tool_call = .{
                .id = id,
                .name = name,
                .arguments = arguments,
                .thought_signature = signature,
            } };
        },
    };
}

pub fn deinitAssistantContentItems(allocator: std.mem.Allocator, source: []const protocol.AssistantContent) void {
    for (source) |content| switch (content) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |value| allocator.free(value);
        },
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |value| allocator.free(value);
        },
        .tool_call => |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            runtime.freeJsonValue(allocator, tool_call.arguments);
            if (tool_call.thought_signature) |value| allocator.free(value);
        },
    };
}

pub fn deinitAssistantContentSlice(allocator: std.mem.Allocator, source: []const protocol.AssistantContent) void {
    deinitAssistantContentItems(allocator, source);
    allocator.free(source);
}

fn copyOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator.dupe(u8, value) else null;
}

pub fn deinitToolCall(allocator: std.mem.Allocator, tool_call: protocol.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    runtime.freeJsonValue(allocator, tool_call.arguments);
    if (tool_call.thought_signature) |value| allocator.free(value);
}

fn copyToolCall(allocator: std.mem.Allocator, source: protocol.ToolCall) !protocol.ToolCall {
    return .{
        .id = try allocator.dupe(u8, source.id),
        .name = try allocator.dupe(u8, source.name),
        .arguments = try runtime.cloneJsonValue(allocator, source.arguments),
        .thought_signature = try copyOptionalString(allocator, source.thought_signature),
    };
}

test "owned assistant message survives source text mutation" {
    var text_buffer = [_]u8{ 'h', 'e', 'y' };
    const source = assistantMessage(&.{.{ .text = .{ .text = &text_buffer } }});

    var owned = try RetainedAssistantMessage.copy(std.testing.allocator, source);
    defer owned.deinit();
    text_buffer[0] = 'b';

    try std.testing.expectEqualStrings("hey", owned.value.content[0].text.text);
}

test "owned assistant message clones nested tool call json strings" {
    var argument_buffer = [_]u8{ 'o', 'n', 'e' };
    var arguments = try jsonObjectWithString(std.testing.allocator, "text", &argument_buffer);
    defer arguments.deinit(std.testing.allocator);
    const source = assistantMessage(&.{.{ .tool_call = .{
        .id = "tool-1",
        .name = "echo",
        .arguments = .{ .object = arguments },
    } }});

    var owned = try RetainedAssistantMessage.copy(std.testing.allocator, source);
    defer owned.deinit();
    argument_buffer[0] = 'd';

    const text = owned.value.content[0].tool_call.arguments.object.get("text").?.string;
    try std.testing.expectEqualStrings("one", text);
}

test "owned assistant message clones optional metadata strings" {
    var response_id = [_]u8{ 'r', '1' };
    var error_message = [_]u8{ 'b', 'o', 'o', 'm' };
    var source = assistantMessage(&.{});
    source.response_id = &response_id;
    source.error_message = &error_message;

    var owned = try RetainedAssistantMessage.copy(std.testing.allocator, source);
    defer owned.deinit();
    response_id[0] = 'x';
    error_message[0] = 'z';

    try std.testing.expectEqualStrings("r1", owned.value.response_id.?);
    try std.testing.expectEqualStrings("boom", owned.value.error_message.?);
}

fn assistantMessage(content: []const protocol.AssistantContent) protocol.AssistantMessage {
    return .{
        .content = content,
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn jsonObjectWithString(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try object.put(allocator, key, .{ .string = value });
    return object;
}
