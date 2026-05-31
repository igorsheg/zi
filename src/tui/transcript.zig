const std = @import("std");

pub const Transcript = struct {
    items: [items_max]Item = undefined,
    count: usize = 0,
    next_id: u64 = 1,
    bytes_used: usize = 0,
    active_assistant_id: ?ItemId = null,

    pub const items_max = 256;
    pub const bytes_max = 512 * 1024;
    pub const item_text_max = 64 * 1024;

    pub const ItemId = enum(u64) { _ };

    pub const Kind = enum {
        system,
        user,
        assistant,
        tool,
    };

    pub const Item = struct {
        id: ItemId,
        kind: Kind,
        text: []u8,
        revision: u64,

        fn deinit(allocator: std.mem.Allocator, self: *Item) void {
            allocator.free(self.text);
            self.* = undefined;
        }
    };

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        for (self.items[0..self.count]) |*item| Item.deinit(allocator, item);
        self.* = undefined;
    }

    pub fn append(self: *Transcript, allocator: std.mem.Allocator, kind: Kind, text: []const u8) !ItemId {
        try validateText(text);
        try self.ensureRoom(text.len);
        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);

        const id: ItemId = @enumFromInt(self.next_id);
        self.next_id += 1;
        self.items[self.count] = .{
            .id = id,
            .kind = kind,
            .text = owned_text,
            .revision = 1,
        };
        self.count += 1;
        self.bytes_used += owned_text.len;
        return id;
    }

    pub fn appendAssistantDelta(self: *Transcript, allocator: std.mem.Allocator, text: []const u8) !void {
        try validateText(text);
        if (self.active_assistant_id) |id| {
            const item = self.find(id) orelse {
                self.active_assistant_id = null;
                return self.appendAssistantDelta(allocator, text);
            };
            try self.appendToItem(allocator, item, text);
            return;
        }
        self.active_assistant_id = try self.append(allocator, .assistant, text);
    }

    pub fn finishAssistant(self: *Transcript, allocator: std.mem.Allocator, final_text: []const u8) !void {
        if (final_text.len == 0) {
            self.active_assistant_id = null;
            return;
        }
        if (self.active_assistant_id) |id| {
            if (self.find(id)) |item| {
                if (std.mem.eql(u8, item.text, final_text)) {
                    self.active_assistant_id = null;
                    return;
                }
                if (std.mem.startsWith(u8, final_text, item.text)) {
                    try self.appendToItem(allocator, item, final_text[item.text.len..]);
                    self.active_assistant_id = null;
                    return;
                }
                try self.replaceItemText(allocator, item, final_text);
                self.active_assistant_id = null;
                return;
            }
        }
        self.active_assistant_id = null;
        _ = try self.append(allocator, .assistant, final_text);
    }

    pub fn endAssistant(self: *Transcript) void {
        self.active_assistant_id = null;
    }

    fn appendToItem(self: *Transcript, allocator: std.mem.Allocator, item: *Item, text: []const u8) !void {
        if (item.text.len + text.len > item_text_max) return error.TranscriptItemTooLarge;
        try self.ensureRoom(text.len);
        const old_len = item.text.len;
        const updated = try allocator.realloc(item.text, old_len + text.len);
        @memcpy(updated[old_len..], text);
        item.text = updated;
        item.revision += 1;
        self.bytes_used += text.len;
    }

    fn replaceItemText(self: *Transcript, allocator: std.mem.Allocator, item: *Item, text: []const u8) !void {
        try validateText(text);
        if (text.len > item_text_max) return error.TranscriptItemTooLarge;
        const old_len = item.text.len;
        const new_total = self.bytes_used - old_len + text.len;
        if (new_total > bytes_max) return error.TranscriptFull;
        const owned_text = try allocator.dupe(u8, text);
        allocator.free(item.text);
        item.text = owned_text;
        item.revision += 1;
        self.bytes_used = new_total;
    }

    fn ensureRoom(self: Transcript, added: usize) !void {
        if (self.count >= items_max) return error.TranscriptFull;
        if (self.bytes_used + added > bytes_max) return error.TranscriptFull;
    }

    fn validateText(text: []const u8) !void {
        if (text.len > item_text_max) return error.TranscriptItemTooLarge;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    }

    fn find(self: *Transcript, id: ItemId) ?*Item {
        for (self.items[0..self.count]) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }
};

test "assistant deltas update one item" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendAssistantDelta(std.testing.allocator, "hel");
    try transcript.appendAssistantDelta(std.testing.allocator, "lo");
    try std.testing.expectEqual(@as(usize, 1), transcript.count);
    try std.testing.expectEqualStrings("hello", transcript.items[0].text);
}
