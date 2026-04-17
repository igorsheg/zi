const std = @import("std");
const protocol = @import("agent/protocol.zig");
const message_memory = @import("agent/message_memory.zig");
const run_control = @import("runtime/run_control.zig");

pub const ItemId = enum(u64) { _ };
pub const SemanticVersion = u64;

pub const QueuedUserMessageKind = enum {
    steering,
    follow_up,
};

/// Owned semantic snapshot of the transcript-visible conversation state.
///
/// Phase 1 of the projection refactor snapshots committed messages plus
/// queued user rows. Live active-assistant / tool-execution items land in
/// the cutover slices that remove delta-driven transcript mutation.
pub const ConversationSnapshot = struct {
    version: u64,
    items: []ConversationItem,

    pub fn clone(self: ConversationSnapshot, allocator: std.mem.Allocator) !ConversationSnapshot {
        const items = try allocator.alloc(ConversationItem, self.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit(allocator);
            allocator.free(items);
        }

        for (self.items, 0..) |item, i| {
            items[i] = try item.clone(allocator);
            initialized += 1;
        }

        return .{
            .version = self.version,
            .items = items,
        };
    }

    pub fn deinit(self: *ConversationSnapshot, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ConversationItem = union(enum) {
    committed_message: CommittedMessageItem,
    queued_user_message: QueuedUserMessageItem,

    pub fn clone(self: ConversationItem, allocator: std.mem.Allocator) !ConversationItem {
        return switch (self) {
            .committed_message => |item| .{ .committed_message = try item.clone(allocator) },
            .queued_user_message => |item| .{ .queued_user_message = try item.clone(allocator) },
        };
    }

    pub fn deinit(self: *ConversationItem, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .committed_message => |*item| item.deinit(allocator),
            .queued_user_message => |*item| item.deinit(allocator),
        }
    }

    pub fn itemId(self: ConversationItem) ItemId {
        return switch (self) {
            .committed_message => |item| item.item_id,
            .queued_user_message => |item| item.item_id,
        };
    }

    pub fn semanticVersion(self: ConversationItem) SemanticVersion {
        return switch (self) {
            .committed_message => |item| item.semantic_version,
            .queued_user_message => |item| item.semantic_version,
        };
    }
};

pub const CommittedMessageItem = struct {
    item_id: ItemId,
    semantic_version: SemanticVersion,
    message: protocol.AgentMessage,

    fn initClone(
        allocator: std.mem.Allocator,
        item_id: ItemId,
        semantic_version: SemanticVersion,
        message: protocol.AgentMessage,
    ) !CommittedMessageItem {
        return .{
            .item_id = item_id,
            .semantic_version = semantic_version,
            .message = try message_memory.cloneMessage(allocator, message),
        };
    }

    pub fn clone(self: CommittedMessageItem, allocator: std.mem.Allocator) !CommittedMessageItem {
        return initClone(allocator, self.item_id, self.semantic_version, self.message);
    }

    pub fn deinit(self: *CommittedMessageItem, allocator: std.mem.Allocator) void {
        message_memory.freeMessage(allocator, &self.message);
        self.* = undefined;
    }
};

pub const QueuedUserMessageItem = struct {
    item_id: ItemId,
    semantic_version: SemanticVersion,
    kind: QueuedUserMessageKind,
    text: []u8,

    fn initClone(
        allocator: std.mem.Allocator,
        item_id: ItemId,
        semantic_version: SemanticVersion,
        kind: QueuedUserMessageKind,
        text: []const u8,
    ) !QueuedUserMessageItem {
        return .{
            .item_id = item_id,
            .semantic_version = semantic_version,
            .kind = kind,
            .text = try allocator.dupe(u8, text),
        };
    }

    pub fn clone(self: QueuedUserMessageItem, allocator: std.mem.Allocator) !QueuedUserMessageItem {
        return initClone(allocator, self.item_id, self.semantic_version, self.kind, self.text);
    }

    pub fn deinit(self: *QueuedUserMessageItem, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const BuildInputs = struct {
    version: u64,
    messages: []const protocol.AgentMessage,
    steering: []const run_control.QueuedMessageText = &.{},
    follow_up: []const run_control.QueuedMessageText = &.{},
};

pub fn build(allocator: std.mem.Allocator, inputs: BuildInputs) !ConversationSnapshot {
    var items: std.ArrayList(ConversationItem) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    try items.ensureTotalCapacity(
        allocator,
        inputs.messages.len + inputs.steering.len + inputs.follow_up.len,
    );

    for (inputs.messages, 0..) |message, idx| {
        try items.append(allocator, .{ .committed_message = try CommittedMessageItem.initClone(
            allocator,
            committedMessageId(idx, message),
            committedMessageSemanticVersion(message),
            message,
        ) });
    }

    try appendQueuedItems(allocator, &items, .steering, inputs.steering);
    try appendQueuedItems(allocator, &items, .follow_up, inputs.follow_up);

    return .{
        .version = inputs.version,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn appendQueuedItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ConversationItem),
    kind: QueuedUserMessageKind,
    entries: []const run_control.QueuedMessageText,
) !void {
    for (entries, 0..) |entry, idx| {
        try items.append(allocator, .{ .queued_user_message = try QueuedUserMessageItem.initClone(
            allocator,
            queuedUserMessageId(kind, idx),
            queuedUserMessageSemanticVersion(entry.text),
            kind,
            entry.text,
        ) });
    }
}

fn committedMessageSemanticVersion(message: protocol.AgentMessage) SemanticVersion {
    _ = message;
    return 1;
}

fn committedMessageId(index: usize, message: protocol.AgentMessage) ItemId {
    var hasher = std.hash.Wyhash.init(0x434f_4e56_534e_4150);
    hasher.update("committed_message");
    std.hash.autoHash(&hasher, index);
    std.hash.autoHash(&hasher, messageTagCode(message));
    std.hash.autoHash(&hasher, messageTimestamp(message));
    return @enumFromInt(hasher.final());
}

fn queuedUserMessageId(kind: QueuedUserMessageKind, ordinal: usize) ItemId {
    var hasher = std.hash.Wyhash.init(0x5155_4555_4549_4401);
    hasher.update("queued_user_message");
    std.hash.autoHash(&hasher, @intFromEnum(kind));
    std.hash.autoHash(&hasher, ordinal);
    return @enumFromInt(hasher.final());
}

fn queuedUserMessageSemanticVersion(text: []const u8) SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x5155_4555_4556_4552);
    hasher.update(text);
    return hasher.final();
}

fn messageTagCode(message: protocol.AgentMessage) u8 {
    return switch (message) {
        .user => 1,
        .assistant => 2,
        .tool_result => 3,
        .compaction_summary => 4,
        .branch_summary => 5,
        .custom => 6,
    };
}

fn messageTimestamp(message: protocol.AgentMessage) i64 {
    return switch (message) {
        .user => |user| user.timestamp,
        .assistant => |assistant| assistant.timestamp,
        .tool_result => |tool_result| tool_result.timestamp,
        .compaction_summary => |summary| summary.timestamp,
        .branch_summary => |summary| summary.timestamp,
        .custom => |custom| custom.timestamp,
    };
}

const testing = std.testing;

fn makeUserMessage(text: []const u8, timestamp: i64) protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = timestamp,
    } };
}

fn makeCompactionSummary(summary: []const u8, timestamp: i64) protocol.AgentMessage {
    return .{ .compaction_summary = .{
        .summary = summary,
        .tokens_before = 123,
        .timestamp = timestamp,
    } };
}

fn freeQueuedInputs(allocator: std.mem.Allocator, entries: []run_control.QueuedMessageText) void {
    for (entries) |entry| allocator.free(entry.text);
}

test "build clones committed messages and queued rows into owned snapshot" {
    const messages = [_]protocol.AgentMessage{
        makeUserMessage("hello", 1),
        makeCompactionSummary("summary", 2),
    };

    var steering = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "steer") },
    };

    var follow_up = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "follow") },
    };

    var snapshot = try build(testing.allocator, .{
        .version = 7,
        .messages = &messages,
        .steering = &steering,
        .follow_up = &follow_up,
    });
    defer snapshot.deinit(testing.allocator);

    freeQueuedInputs(testing.allocator, &steering);
    freeQueuedInputs(testing.allocator, &follow_up);

    try testing.expectEqual(@as(u64, 7), snapshot.version);
    try testing.expectEqual(@as(usize, 4), snapshot.items.len);
    try testing.expect(snapshot.items[0] == .committed_message);
    try testing.expect(snapshot.items[1] == .committed_message);
    try testing.expect(snapshot.items[2] == .queued_user_message);
    try testing.expect(snapshot.items[3] == .queued_user_message);
    try testing.expectEqualStrings("hello", snapshot.items[0].committed_message.message.user.content.text);
    try testing.expectEqualStrings("summary", snapshot.items[1].committed_message.message.compaction_summary.summary);
    try testing.expectEqual(QueuedUserMessageKind.steering, snapshot.items[2].queued_user_message.kind);
    try testing.expectEqualStrings("steer", snapshot.items[2].queued_user_message.text);
    try testing.expectEqual(QueuedUserMessageKind.follow_up, snapshot.items[3].queued_user_message.kind);
    try testing.expectEqualStrings("follow", snapshot.items[3].queued_user_message.text);
}

test "build keeps stable ids for repeated inputs and bumps queued semantic version on text change" {
    const messages = [_]protocol.AgentMessage{makeUserMessage("hello", 1)};

    var steering_a = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "draft") },
    };
    defer freeQueuedInputs(testing.allocator, &steering_a);
    var snapshot_a = try build(testing.allocator, .{
        .version = 1,
        .messages = &messages,
        .steering = &steering_a,
    });
    defer snapshot_a.deinit(testing.allocator);

    var steering_b = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "draft") },
    };
    defer freeQueuedInputs(testing.allocator, &steering_b);
    var snapshot_b = try build(testing.allocator, .{
        .version = 2,
        .messages = &messages,
        .steering = &steering_b,
    });
    defer snapshot_b.deinit(testing.allocator);

    try testing.expectEqual(@intFromEnum(snapshot_a.items[0].itemId()), @intFromEnum(snapshot_b.items[0].itemId()));
    try testing.expectEqual(snapshot_a.items[0].semanticVersion(), snapshot_b.items[0].semanticVersion());
    try testing.expectEqual(@intFromEnum(snapshot_a.items[1].itemId()), @intFromEnum(snapshot_b.items[1].itemId()));
    try testing.expectEqual(snapshot_a.items[1].semanticVersion(), snapshot_b.items[1].semanticVersion());

    var steering_c = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "revised") },
    };
    defer freeQueuedInputs(testing.allocator, &steering_c);
    var snapshot_c = try build(testing.allocator, .{
        .version = 3,
        .messages = &messages,
        .steering = &steering_c,
    });
    defer snapshot_c.deinit(testing.allocator);

    try testing.expectEqual(@intFromEnum(snapshot_a.items[1].itemId()), @intFromEnum(snapshot_c.items[1].itemId()));
    try testing.expect(snapshot_a.items[1].semanticVersion() != snapshot_c.items[1].semanticVersion());
}

test "conversation snapshot clone deep copies items" {
    const messages = [_]protocol.AgentMessage{makeUserMessage("hello", 1)};
    var steering = [_]run_control.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "draft") },
    };
    defer freeQueuedInputs(testing.allocator, &steering);

    var original = try build(testing.allocator, .{
        .version = 9,
        .messages = &messages,
        .steering = &steering,
    });

    var cloned = try original.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);

    original.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 9), cloned.version);
    try testing.expectEqual(@as(usize, 2), cloned.items.len);
    try testing.expectEqualStrings("hello", cloned.items[0].committed_message.message.user.content.text);
    try testing.expectEqualStrings("draft", cloned.items[1].queued_user_message.text);
}
