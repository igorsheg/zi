const std = @import("std");
const runtime = @import("../runtime/root.zig");
const protocol = @import("protocol.zig");

pub const OwnedAssistantMessage = struct {
    arena: std.heap.ArenaAllocator,
    value: protocol.AssistantMessage,

    pub fn clone(backing_allocator: std.mem.Allocator, source: protocol.AssistantMessage) !OwnedAssistantMessage {
        var owned = try runtime.JsonOwned(protocol.AssistantMessage).initClone(
            backing_allocator,
            source,
            cloneAssistantMessage,
        );
        const value = owned.value;
        const arena = owned.takeArena();
        return .{ .arena = arena, .value = value };
    }

    pub fn deinit(self: *OwnedAssistantMessage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn cloneAssistantMessage(
    allocator: std.mem.Allocator,
    source: protocol.AssistantMessage,
) !protocol.AssistantMessage {
    const content = try cloneAssistantContentSlice(allocator, source.content);
    errdefer freeAssistantContentSlice(allocator, content);
    const api = try allocator.dupe(u8, source.api);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, source.provider);
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, source.model);
    errdefer allocator.free(model);
    const response_id = try cloneOptionalString(allocator, source.response_id);
    errdefer if (response_id) |value| allocator.free(value);
    const error_message = try cloneOptionalString(allocator, source.error_message);

    return .{
        .content = content,
        .api = api,
        .provider = provider,
        .model = model,
        .response_id = response_id,
        .usage = source.usage,
        .stop_reason = source.stop_reason,
        .error_message = error_message,
        .timestamp = source.timestamp,
    };
}

pub fn freeAssistantMessage(allocator: std.mem.Allocator, message: protocol.AssistantMessage) void {
    freeAssistantContentSlice(allocator, message.content);
    allocator.free(message.api);
    allocator.free(message.provider);
    allocator.free(message.model);
    if (message.response_id) |value| allocator.free(value);
    if (message.error_message) |value| allocator.free(value);
}

pub fn cloneAssistantMessageEvent(
    allocator: std.mem.Allocator,
    source: protocol.AssistantMessageEvent,
) !protocol.AssistantMessageEvent {
    return switch (source) {
        .start => |start| .{ .start = .{ .partial = try cloneAssistantMessage(allocator, start.partial) } },
        .text_start => |event| .{ .text_start = .{
            .content_index = event.content_index,
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .text_delta => |event| .{ .text_delta = .{
            .content_index = event.content_index,
            .delta = try allocator.dupe(u8, event.delta),
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .text_end => |event| .{ .text_end = .{
            .content_index = event.content_index,
            .content = try allocator.dupe(u8, event.content),
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .thinking_start => |event| .{ .thinking_start = .{
            .content_index = event.content_index,
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .thinking_delta => |event| .{ .thinking_delta = .{
            .content_index = event.content_index,
            .delta = try allocator.dupe(u8, event.delta),
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .thinking_end => |event| .{ .thinking_end = .{
            .content_index = event.content_index,
            .content = try allocator.dupe(u8, event.content),
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .toolcall_start => |event| .{ .toolcall_start = .{
            .content_index = event.content_index,
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .toolcall_delta => |event| .{ .toolcall_delta = .{
            .content_index = event.content_index,
            .delta = try allocator.dupe(u8, event.delta),
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .toolcall_end => |event| .{ .toolcall_end = .{
            .content_index = event.content_index,
            .tool_call = try cloneToolCall(allocator, event.tool_call),
            .partial = try cloneAssistantMessage(allocator, event.partial),
        } },
        .done => |done| .{ .done = .{
            .reason = done.reason,
            .message = try cloneAssistantMessage(allocator, done.message),
        } },
        .@"error" => |err| .{ .@"error" = .{
            .reason = err.reason,
            .@"error" = try cloneAssistantMessage(allocator, err.@"error"),
        } },
    };
}

fn cloneAssistantContentSlice(
    allocator: std.mem.Allocator,
    source: []const protocol.AssistantContent,
) ![]const protocol.AssistantContent {
    const cloned = try allocator.alloc(protocol.AssistantContent, source.len);
    var initialized: usize = 0;
    errdefer {
        freeAssistantContentItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (source, cloned) |content, *out| {
        out.* = try cloneAssistantContent(allocator, content);
        initialized += 1;
    }
    return cloned;
}

fn cloneAssistantContent(
    allocator: std.mem.Allocator,
    source: protocol.AssistantContent,
) !protocol.AssistantContent {
    return switch (source) {
        .text => |text| blk: {
            const text_copy = try allocator.dupe(u8, text.text);
            errdefer allocator.free(text_copy);
            const signature = try cloneOptionalString(allocator, text.text_signature);
            break :blk .{ .text = .{ .text = text_copy, .text_signature = signature } };
        },
        .thinking => |thinking| blk: {
            const thinking_copy = try allocator.dupe(u8, thinking.thinking);
            errdefer allocator.free(thinking_copy);
            const signature = try cloneOptionalString(allocator, thinking.thinking_signature);
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
            const signature = try cloneOptionalString(allocator, tool_call.thought_signature);
            break :blk .{ .tool_call = .{
                .id = id,
                .name = name,
                .arguments = arguments,
                .thought_signature = signature,
            } };
        },
    };
}

fn freeAssistantContentItems(allocator: std.mem.Allocator, source: []const protocol.AssistantContent) void {
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

fn freeAssistantContentSlice(allocator: std.mem.Allocator, source: []const protocol.AssistantContent) void {
    freeAssistantContentItems(allocator, source);
    allocator.free(source);
}

fn cloneOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator.dupe(u8, value) else null;
}

fn cloneToolCall(allocator: std.mem.Allocator, source: protocol.ToolCall) !protocol.ToolCall {
    return .{
        .id = try allocator.dupe(u8, source.id),
        .name = try allocator.dupe(u8, source.name),
        .arguments = try runtime.cloneJsonValue(allocator, source.arguments),
        .thought_signature = try cloneOptionalString(allocator, source.thought_signature),
    };
}

test "owned assistant message survives source text mutation" {
    var text_buffer = [_]u8{ 'h', 'e', 'y' };
    const source = assistantMessage(&.{.{ .text = .{ .text = &text_buffer } }});

    var owned = try OwnedAssistantMessage.clone(std.testing.allocator, source);
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

    var owned = try OwnedAssistantMessage.clone(std.testing.allocator, source);
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

    var owned = try OwnedAssistantMessage.clone(std.testing.allocator, source);
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
