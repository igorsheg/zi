const std = @import("std");
const protocol = @import("protocol.zig");

pub const OwnedAssistantMessage = struct {
    arena: std.heap.ArenaAllocator,
    value: protocol.AssistantMessage,

    pub fn clone(backing_allocator: std.mem.Allocator, source: protocol.AssistantMessage) !OwnedAssistantMessage {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const content = try cloneAssistantContentSlice(allocator, source.content);
        const api = try allocator.dupe(u8, source.api);
        const provider = try allocator.dupe(u8, source.provider);
        const model = try allocator.dupe(u8, source.model);
        const response_id = try cloneOptionalString(allocator, source.response_id);
        const error_message = try cloneOptionalString(allocator, source.error_message);

        return .{
            .arena = arena,
            .value = .{
                .content = content,
                .api = api,
                .provider = provider,
                .model = model,
                .response_id = response_id,
                .usage = source.usage,
                .stop_reason = source.stop_reason,
                .error_message = error_message,
                .timestamp = source.timestamp,
            },
        };
    }

    pub fn deinit(self: *OwnedAssistantMessage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn cloneAssistantContentSlice(
    allocator: std.mem.Allocator,
    source: []const protocol.AssistantContent,
) ![]const protocol.AssistantContent {
    const cloned = try allocator.alloc(protocol.AssistantContent, source.len);
    for (source, cloned) |content, *out| {
        out.* = try cloneAssistantContent(allocator, content);
    }
    return cloned;
}

fn cloneAssistantContent(
    allocator: std.mem.Allocator,
    source: protocol.AssistantContent,
) !protocol.AssistantContent {
    return switch (source) {
        .text => |text| .{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .text_signature = try cloneOptionalString(allocator, text.text_signature),
        } },
        .thinking => |thinking| .{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .thinking_signature = try cloneOptionalString(allocator, thinking.thinking_signature),
            .redacted = thinking.redacted,
        } },
        .tool_call => |tool_call| .{ .tool_call = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try cloneJsonValue(allocator, tool_call.arguments),
            .thought_signature = try cloneOptionalString(allocator, tool_call.thought_signature),
        } },
    };
}

fn cloneOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    return if (source) |value| try allocator.dupe(u8, value) else null;
}

fn cloneJsonValue(allocator: std.mem.Allocator, source: std.json.Value) !std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |array| blk: {
            var cloned: std.json.Array = .init(allocator);
            for (array.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned: std.json.ObjectMap = .empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try cloned.put(allocator, key, try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = cloned };
        },
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
