const std = @import("std");

pub const TranscriptItemId = enum(u64) {
    _,
};

pub const Kind = enum {
    system,
    user_message,
    assistant_message,
    tool_call,
    custom,
};

pub const Durability = enum {
    ephemeral,
    persistent,
};

pub const Payload = union(enum) {
    text: []u8,
    custom: Custom,

    pub const Custom = struct {
        custom_type: []u8,
        data_json: []u8,
    };
};

pub const TranscriptItem = struct {
    id: TranscriptItemId,
    kind: Kind,
    durability: Durability,
    revision: u64,
    created_ns: i128,
    payload: Payload,

    pub fn deinit(self: *TranscriptItem, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .text => |bytes| allocator.free(bytes),
            .custom => |payload| {
                allocator.free(payload.custom_type);
                allocator.free(payload.data_json);
            },
        }
        self.* = undefined;
    }
};

pub const Store = struct {
    pub const item_count_max = 4096;
    pub const text_bytes_max = 64 * 1024;
    pub const custom_type_bytes_max = 128;
    pub const custom_payload_bytes_max = 64 * 1024;

    allocator: std.mem.Allocator,
    items: [item_count_max]TranscriptItem = undefined,
    item_count: usize = 0,
    next_id: u64 = 1,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        var index: usize = 0;
        while (index < self.item_count) : (index += 1) {
            self.items[index].deinit(self.allocator);
        }
        self.* = undefined;
    }

    pub fn appendText(
        self: *Store,
        kind: Kind,
        durability: Durability,
        text: []const u8,
        created_ns: i128,
    ) !TranscriptItemId {
        std.debug.assert(kind != .custom);
        if (self.item_count == self.items.len) return error.TranscriptStoreFull;
        if (text.len > text_bytes_max) return error.TranscriptTextTooLarge;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;

        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        return self.appendOwned(.{
            .kind = kind,
            .durability = durability,
            .created_ns = created_ns,
            .payload = .{ .text = owned },
        });
    }

    pub fn appendTextToItem(self: *Store, id: TranscriptItemId, text: []const u8) !void {
        if (text.len == 0) return;
        if (text.len > text_bytes_max) return error.TranscriptTextTooLarge;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;

        const item = self.get(id) orelse return error.TranscriptItemNotFound;
        std.debug.assert(item.kind != .custom);
        const current = item.payload.text;
        if (current.len + text.len > text_bytes_max) return error.TranscriptTextTooLarge;

        const combined = try self.allocator.realloc(current, current.len + text.len);
        @memcpy(combined[current.len..], text);
        self.revision += 1;
        item.revision = self.revision;
        item.payload = .{ .text = combined };
    }

    pub fn appendCustom(
        self: *Store,
        durability: Durability,
        custom_type: []const u8,
        data_json: []const u8,
        created_ns: i128,
    ) !TranscriptItemId {
        if (self.item_count == self.items.len) return error.TranscriptStoreFull;
        if (custom_type.len == 0 or custom_type.len > custom_type_bytes_max) return error.InvalidCustomTranscriptType;
        if (data_json.len > custom_payload_bytes_max) return error.CustomTranscriptPayloadTooLarge;
        if (!std.unicode.utf8ValidateSlice(custom_type)) return error.InvalidUtf8;
        if (!std.unicode.utf8ValidateSlice(data_json)) return error.InvalidUtf8;

        const owned_type = try self.allocator.dupe(u8, custom_type);
        errdefer self.allocator.free(owned_type);
        const owned_data = try self.allocator.dupe(u8, data_json);
        errdefer self.allocator.free(owned_data);
        return self.appendOwned(.{
            .kind = .custom,
            .durability = durability,
            .created_ns = created_ns,
            .payload = .{ .custom = .{
                .custom_type = owned_type,
                .data_json = owned_data,
            } },
        });
    }

    fn appendOwned(self: *Store, partial: struct {
        kind: Kind,
        durability: Durability,
        created_ns: i128,
        payload: Payload,
    }) TranscriptItemId {
        const id: TranscriptItemId = @enumFromInt(self.next_id);
        self.next_id += 1;
        self.revision += 1;
        self.items[self.item_count] = .{
            .id = id,
            .kind = partial.kind,
            .durability = partial.durability,
            .revision = self.revision,
            .created_ns = partial.created_ns,
            .payload = partial.payload,
        };
        self.item_count += 1;
        return id;
    }

    pub fn get(self: *Store, id: TranscriptItemId) ?*TranscriptItem {
        var index: usize = 0;
        while (index < self.item_count) : (index += 1) {
            if (self.items[index].id == id) return &self.items[index];
        }
        return null;
    }
};

test "transcript store owns ephemeral and persistent custom items" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const id = try store.appendCustom(.persistent, "todo", "{\"done\":false}", 7);
    const item = store.get(id).?;
    try std.testing.expectEqual(Kind.custom, item.kind);
    try std.testing.expectEqual(Durability.persistent, item.durability);
    try std.testing.expectEqualStrings("todo", item.payload.custom.custom_type);
    try std.testing.expectEqualStrings("{\"done\":false}", item.payload.custom.data_json);
}

test "transcript item accumulates text without adding items" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const id = try store.appendText(.assistant_message, .ephemeral, "hel", 0);
    try store.appendTextToItem(id, "lo");
    try std.testing.expectEqual(@as(usize, 1), store.item_count);
    try std.testing.expectEqualStrings("hello", store.get(id).?.payload.text);
}

test "transcript store rejects invalid utf8 before mutation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectError(error.InvalidUtf8, store.appendText(.user_message, .persistent, "\x80", 0));
    try std.testing.expectEqual(@as(usize, 0), store.item_count);
    try std.testing.expectEqual(@as(u64, 0), store.revision);

    const id = try store.appendText(.assistant_message, .ephemeral, "ok", 0);
    try std.testing.expectError(error.InvalidUtf8, store.appendTextToItem(id, "\x80"));
    try std.testing.expectEqualStrings("ok", store.get(id).?.payload.text);
    try std.testing.expectEqual(@as(u64, 1), store.revision);

    try std.testing.expectError(error.InvalidUtf8, store.appendCustom(.persistent, "\x80", "{}", 0));
    try std.testing.expectError(error.InvalidUtf8, store.appendCustom(.persistent, "bad", "\x80", 0));
    try std.testing.expectEqual(@as(usize, 1), store.item_count);
}
