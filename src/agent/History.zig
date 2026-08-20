const std = @import("std");
const message = @import("../ai/message.zig");

const History = @This();
const max_messages = 65_536;

allocator: std.mem.Allocator,
entries: std.ArrayList(message.Message) = .empty,
arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,

pub const Error = error{ OutOfMemory, SessionTooLarge };

pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    value: message.Message,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn publish(self: *Prepared, history: *History) void {
        history.entries.appendAssumeCapacity(self.value);
        history.arenas.appendAssumeCapacity(self.arena);
        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator) History {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *History) void {
    for (self.arenas.items) |*arena| arena.deinit();
    self.arenas.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.* = undefined;
}

pub fn messages(self: *const History) []const message.Message {
    return self.entries.items;
}

pub fn prepare(self: *History, value: message.Message) Error!Prepared {
    if (self.entries.items.len >= max_messages) return error.SessionTooLarge;
    self.entries.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
    self.arenas.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    const copy = try message.copyLeaky(memory, value);
    return .{ .arena = arena, .value = copy };
}

pub fn append(self: *History, value: message.Message) Error!void {
    var prepared = try self.prepare(value);
    prepared.publish(self);
}

pub fn appendRequest(self: *History, request: message.RequestMessage) Error!void {
    return self.append(.{ .request = request });
}

pub fn appendResponse(self: *History, response: message.ResponseMessage) Error!void {
    return self.append(.{ .response = response });
}

/// Removes a suffix from provider context and releases its owned storage.
pub fn truncate(self: *History, new_len: usize) void {
    std.debug.assert(new_len <= self.entries.items.len);
    for (self.arenas.items[new_len..]) |*arena| arena.deinit();
    self.entries.shrinkRetainingCapacity(new_len);
    self.arenas.shrinkRetainingCapacity(new_len);
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

test "history truncation releases a provider-context suffix" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.appendRequest(.{ .parts = &.{.{ .user = .{ .text = "question" } }} });
    try history.appendResponse(.{
        .parts = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
        .identity = .{ .provider = "script", .model = "truncate" },
        .finish = .{ .category = .tool_calls },
    });

    history.truncate(1);
    try std.testing.expectEqual(@as(usize, 1), history.messages().len);
    try std.testing.expectEqualStrings("question", history.messages()[0].request.parts[0].user.text);
}

test "prepared history remains invisible until infallible publication" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    const source = try std.testing.allocator.dupe(u8, "prepared request");
    defer std.testing.allocator.free(source);

    var prepared = try history.prepare(.{ .request = .{
        .parts = &.{.{ .user = .{ .text = source } }},
    } });
    try std.testing.expectEqual(@as(usize, 0), history.messages().len);
    @memset(source, 'x');
    prepared.publish(&history);

    try std.testing.expectEqual(@as(usize, 1), history.messages().len);
    try std.testing.expectEqualStrings(
        "prepared request",
        history.messages()[0].request.parts[0].user.text,
    );
}

fn appendForAllocationFailure(allocator: std.mem.Allocator) !void {
    var history = History.init(allocator);
    defer history.deinit();
    try history.appendRequest(.{ .parts = &.{.{ .user = .{ .text = "question" } }} });
    try history.appendResponse(.{
        .parts = &.{.{ .tool_call = .{
            .id = "call-1",
            .name = "read",
            .arguments_json = "{\"path\":\"README.md\"}",
            .provider_state = .{
                .provider = "openai",
                .protocol = "openai-responses",
                .value = .{ .string = "opaque" },
            },
        } }},
        .identity = .{ .provider = "openai", .model = "gpt-test" },
        .finish = .{ .category = .tool_calls },
    });
}

test "history preparation settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        appendForAllocationFailure,
        .{},
    );
}
