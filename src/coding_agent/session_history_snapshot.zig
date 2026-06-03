const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const session_manager = @import("session_manager.zig");
const message_policy = @import("message_policy.zig");

pub const max_items: usize = 512;
pub const max_item_text_bytes: usize = 16 * 1024;
pub const max_total_text_bytes: usize = 128 * 1024;

pub const Role = enum { user, assistant, system };

pub const Item = struct {
    role: Role,
    text: []u8,
};

pub const Snapshot = struct {
    items: []Item,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item.text);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, manager: *const session_manager.SessionManager) !Snapshot {
    var items: std.ArrayList(Item) = .empty;
    errdefer deinitItems(allocator, items.items);
    var total_text_bytes: usize = 0;

    const start = if (manager.entries.items.len > max_items) manager.entries.items.len - max_items else 0;
    for (manager.entries.items[start..]) |entry| {
        if (entry != .message) continue;
        const maybe_item = try itemFromMessage(allocator, entry.message.message) orelse continue;
        errdefer allocator.free(maybe_item.text);
        if (maybe_item.text.len > max_item_text_bytes) return error.HistorySnapshotItemTooLarge;
        if (maybe_item.text.len > max_total_text_bytes - total_text_bytes) return error.HistorySnapshotTooLarge;
        try items.append(allocator, maybe_item);
        total_text_bytes += maybe_item.text.len;
    }

    return .{ .items = try items.toOwnedSlice(allocator) };
}

fn deinitItems(allocator: std.mem.Allocator, items: []const Item) void {
    for (items) |item| allocator.free(item.text);
}

fn itemFromMessage(allocator: std.mem.Allocator, message: agent.AgentMessage) !?Item {
    return switch (message) {
        .user => |user| if (message_policy.userText(user)) |text|
            .{ .role = .user, .text = try allocator.dupe(u8, text) }
        else
            null,
        .assistant => |assistant| try assistantItem(allocator, assistant),
        .tool_result, .custom => null,
    };
}

fn assistantItem(allocator: std.mem.Allocator, assistant: ai.AssistantMessage) !?Item {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    for (assistant.content) |content| {
        if (content != .text) continue;
        if (writer.written().len > 0) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(content.text.text);
    }

    if (writer.written().len == 0) {
        const error_message = assistant.error_message orelse return null;
        return .{ .role = .system, .text = try allocator.dupe(u8, error_message) };
    }

    return .{ .role = .assistant, .text = try writer.toOwnedSlice() };
}

fn zeroUsage() ai.Usage {
    return .{
        .input = 0,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .total_tokens = 0,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
    };
}

test "session history snapshot maps user and assistant text" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, ".", "s", "t");
    defer manager.deinit();

    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }, "t1");
    _ = try manager.appendMessage(.{ .assistant = .{
        .content = &.{.{ .text = .{ .text = "hi" } }},
        .api = ai.KnownApi.anthropic_messages,
        .provider = ai.KnownProvider.anthropic,
        .model = "m",
        .usage = zeroUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    } }, "t2");

    var snapshot = try build(std.testing.allocator, &manager);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(Role.user, snapshot.items[0].role);
    try std.testing.expectEqualStrings("hello", snapshot.items[0].text);
    try std.testing.expectEqual(Role.assistant, snapshot.items[1].role);
    try std.testing.expectEqualStrings("hi", snapshot.items[1].text);
}
