const std = @import("std");

const primitive = @import("../primitive/root.zig");

pub const ItemId = enum(u64) {
    _,
};

pub const ItemKind = enum {
    user_message,
    assistant_message,
    tool_call,
    tool_result,
    system_notice,
    error_notice,
};

pub const ItemState = enum {
    open,
    sealed,
};

pub const Item = struct {
    id: ItemId,
    kind: ItemKind,
    state: ItemState = .open,
    block_id: primitive.document.BlockId,
};

pub const Command = union(enum) {
    append_item: ItemKind,
    append_text: struct {
        item_id: ItemId,
        bytes: []const u8,
    },
    seal_item: ItemId,
};

pub const Transcript = struct {
    document: primitive.document.Document,
    items: std.ArrayListUnmanaged(Item) = .empty,
    next_item_id: u64 = 1,

    pub fn init(options: primitive.document.Options) Transcript {
        return .{ .document = primitive.document.Document.init(options) };
    }

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        self.document.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn apply(self: *Transcript, allocator: std.mem.Allocator, command: Command) !?ItemId {
        switch (command) {
            .append_item => |kind| return try self.appendItem(allocator, kind),
            .append_text => |payload| {
                const entry = self.itemPtr(payload.item_id) orelse return error.TranscriptItemNotFound;
                if (entry.state != .open) return error.TranscriptItemSealed;
                try self.document.appendText(allocator, entry.block_id, payload.bytes);
                return null;
            },
            .seal_item => |item_id| {
                const entry = self.itemPtr(item_id) orelse return error.TranscriptItemNotFound;
                entry.state = .sealed;
                try self.document.seal(entry.block_id);
                return null;
            },
        }
    }

    pub fn item(self: *const Transcript, id: ItemId) ?*const Item {
        for (self.items.items) |*candidate| {
            if (candidate.id == id) return candidate;
        }
        return null;
    }

    fn appendItem(self: *Transcript, allocator: std.mem.Allocator, kind: ItemKind) !ItemId {
        const block_id = try self.document.appendBlock(allocator);
        errdefer self.document.removeTailBlock(allocator, block_id) catch unreachable;
        const id: ItemId = @enumFromInt(self.next_item_id);
        try self.items.append(allocator, .{
            .id = id,
            .kind = kind,
            .block_id = block_id,
        });
        self.next_item_id += 1;
        return id;
    }

    fn itemPtr(self: *Transcript, id: ItemId) ?*Item {
        for (self.items.items) |*candidate| {
            if (candidate.id == id) return candidate;
        }
        return null;
    }
};

test "transcript streams assistant deltas into one block" {
    var transcript = Transcript.init(.{});
    defer transcript.deinit(std.testing.allocator);

    const item_id = (try transcript.apply(std.testing.allocator, .{ .append_item = .assistant_message })).?;
    _ = try transcript.apply(std.testing.allocator, .{ .append_text = .{ .item_id = item_id, .bytes = "hel" } });
    _ = try transcript.apply(std.testing.allocator, .{ .append_text = .{ .item_id = item_id, .bytes = "lo" } });

    const item = transcript.item(item_id).?;
    const block = transcript.document.block(item.block_id).?;
    try std.testing.expectEqualStrings("hello", block.bytes.items);
    try std.testing.expectEqual(@as(u64, 2), block.revision);
}

test "transcript rejects sealed item mutation" {
    var transcript = Transcript.init(.{});
    defer transcript.deinit(std.testing.allocator);

    const item_id = (try transcript.apply(std.testing.allocator, .{ .append_item = .user_message })).?;
    _ = try transcript.apply(std.testing.allocator, .{ .seal_item = item_id });
    try std.testing.expectError(
        error.TranscriptItemSealed,
        transcript.apply(std.testing.allocator, .{ .append_text = .{ .item_id = item_id, .bytes = "late" } }),
    );
}

test "transcript append is atomic when item allocation fails" {
    var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const failing_allocator = failing_allocator_state.allocator();
    var transcript = Transcript.init(.{});
    defer transcript.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.OutOfMemory,
        transcript.apply(failing_allocator, .{ .append_item = .assistant_message }),
    );

    try std.testing.expectEqual(@as(usize, 0), transcript.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), transcript.document.blocks.items.len);
    try std.testing.expectEqual(@as(u64, 1), transcript.next_item_id);
}
