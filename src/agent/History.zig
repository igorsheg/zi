const std = @import("std");
const message = @import("../ai/message.zig");

const History = @This();

arena: std.heap.ArenaAllocator,
entries: std.ArrayList(message.Message) = .empty,

pub fn init(allocator: std.mem.Allocator) History {
    return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
}

pub fn deinit(self: *History) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn messages(self: *const History) []const message.Message {
    return self.entries.items;
}

pub fn appendRequest(self: *History, request: message.RequestMessage) error{OutOfMemory}!void {
    const memory = self.arena.allocator();
    const copy = try copyRequest(memory, request);
    try self.entries.append(memory, .{ .request = copy });
}

pub fn appendResponse(self: *History, response: message.ResponseMessage) error{OutOfMemory}!void {
    const memory = self.arena.allocator();
    const copy = try copyResponse(memory, response);
    try self.entries.append(memory, .{ .response = copy });
}

fn copyRequest(allocator: std.mem.Allocator, source: message.RequestMessage) !message.RequestMessage {
    const parts = try allocator.alloc(message.RequestPart, source.parts.len);
    for (source.parts, parts) |part, *copy| copy.* = switch (part) {
        .user => |user| .{ .user = switch (user) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .image => |image| .{ .image = try copyImage(allocator, image) },
        } },
        .tool_result => |result| .{ .tool_result = .{
            .call_id = try allocator.dupe(u8, result.call_id),
            .name = try allocator.dupe(u8, result.name),
            .content = try copyContent(allocator, result.content),
            .outcome = result.outcome,
        } },
        .retry_prompt => |text| .{ .retry_prompt = try allocator.dupe(u8, text) },
    };
    return .{ .parts = parts };
}

fn copyResponse(allocator: std.mem.Allocator, source: message.ResponseMessage) !message.ResponseMessage {
    const parts = try allocator.alloc(message.ResponsePart, source.parts.len);
    for (source.parts, parts) |part, *copy| copy.* = switch (part) {
        .text => |text| .{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .provider_state = if (text.provider_state) |state| try copyProviderState(allocator, state) else null,
        } },
        .thinking => |thinking| .{ .thinking = .{
            .text = try allocator.dupe(u8, thinking.text),
            .provider_state = if (thinking.provider_state) |state| try copyProviderState(allocator, state) else null,
        } },
        .tool_call => |call| .{ .tool_call = .{
            .id = try allocator.dupe(u8, call.id),
            .name = try allocator.dupe(u8, call.name),
            .arguments_json = try allocator.dupe(u8, call.arguments_json),
            .provider_state = if (call.provider_state) |state| try copyProviderState(allocator, state) else null,
        } },
    };
    return .{
        .parts = parts,
        .identity = .{
            .provider = try allocator.dupe(u8, source.identity.provider),
            .model = try allocator.dupe(u8, source.identity.model),
        },
        .usage = source.usage,
        .finish = .{
            .category = source.finish.category,
            .raw_reason = if (source.finish.raw_reason) |reason| try allocator.dupe(u8, reason) else null,
        },
    };
}

fn copyContent(allocator: std.mem.Allocator, source: []const message.Content) ![]const message.Content {
    const content = try allocator.alloc(message.Content, source.len);
    for (source, content) |item, *copy| copy.* = switch (item) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .image => |image| .{ .image = try copyImage(allocator, image) },
    };
    return content;
}

fn copyImage(allocator: std.mem.Allocator, source: message.Image) !message.Image {
    return .{
        .media_type = try allocator.dupe(u8, source.media_type),
        .source = switch (source.source) {
            .bytes => |bytes| .{ .bytes = try allocator.dupe(u8, bytes) },
            .url => |url| .{ .url = try allocator.dupe(u8, url) },
        },
    };
}

fn copyProviderState(allocator: std.mem.Allocator, source: message.ProviderState) !message.ProviderState {
    return .{
        .provider = try allocator.dupe(u8, source.provider),
        .protocol = try allocator.dupe(u8, source.protocol),
        .value = try copyJson(allocator, source.value),
    };
}

fn copyJson(allocator: std.mem.Allocator, source: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |value| array: {
            var copy = std.json.Array.init(allocator);
            for (value.items) |item| try copy.append(try copyJson(allocator, item));
            break :array .{ .array = copy };
        },
        .object => |value| object: {
            var copy: std.json.ObjectMap = .{};
            var iterator = value.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try copy.put(allocator, key, try copyJson(allocator, entry.value_ptr.*));
            }
            break :object .{ .object = copy };
        },
    };
}

test "history owns provider state JSON" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"token\":\"owned\"}",
        .{},
    );
    try history.appendResponse(.{
        .parts = &.{.{ .text = .{
            .text = "answer",
            .provider_state = .{
                .provider = "provider",
                .protocol = "protocol",
                .value = parsed.value,
            },
        } }},
        .identity = .{ .provider = "provider", .model = "model" },
        .finish = .{ .category = .stop },
    });
    parsed.deinit();

    const state = history.messages()[0].response.parts[0].text.provider_state.?;
    try std.testing.expectEqualStrings("owned", state.value.object.get("token").?.string);
}

test "history owns appended canonical messages" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    const user = try std.testing.allocator.dupe(u8, "read the file.");
    try history.appendRequest(.{ .parts = &.{.{ .user = .{ .text = user } }} });
    @memset(user, 'x');
    std.testing.allocator.free(user);

    const arguments = try std.testing.allocator.dupe(u8, "{\"path\":\"a\"}");
    try history.appendResponse(.{
        .parts = &.{.{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = arguments } }},
        .identity = .{ .provider = "script", .model = "test" },
        .finish = .{ .category = .tool_calls },
    });
    @memset(arguments, 'x');
    std.testing.allocator.free(arguments);

    try std.testing.expectEqual(@as(usize, 2), history.messages().len);
    try std.testing.expectEqualStrings("read the file.", history.messages()[0].request.parts[0].user.text);
    try std.testing.expectEqualStrings(
        "{\"path\":\"a\"}",
        history.messages()[1].response.parts[0].tool_call.arguments_json,
    );
}
