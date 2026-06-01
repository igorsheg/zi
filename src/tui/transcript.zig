const std = @import("std");

pub const Transcript = struct {
    items: [items_max]Item = undefined,
    count: usize = 0,
    next_id: u64 = 1,
    bytes_used: usize = 0,
    content_version: u64 = 0,
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
        std.debug.assert(self.count < items_max);
        self.count += 1;
        std.debug.assert(self.bytes_used <= bytes_max - owned_text.len);
        self.bytes_used += owned_text.len;
        self.bumpContentVersion();
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
        const item_byte_count = std.math.add(usize, item.text.len, text.len) catch
            return error.TranscriptItemTooLarge;
        if (item_byte_count > item_text_max) return error.TranscriptItemTooLarge;
        try self.ensureRoom(text.len);
        const old_len = item.text.len;
        const updated = try allocator.realloc(item.text, item_byte_count);
        @memcpy(updated[old_len..], text);
        item.text = updated;
        item.revision += 1;
        std.debug.assert(self.bytes_used <= bytes_max - text.len);
        self.bytes_used += text.len;
        self.bumpContentVersion();
    }

    fn replaceItemText(self: *Transcript, allocator: std.mem.Allocator, item: *Item, text: []const u8) !void {
        try validateText(text);
        if (text.len > item_text_max) return error.TranscriptItemTooLarge;
        const old_len = item.text.len;
        std.debug.assert(self.bytes_used >= old_len);
        const bytes_without_item = self.bytes_used - old_len;
        const new_total = std.math.add(usize, bytes_without_item, text.len) catch
            return error.TranscriptFull;
        if (new_total > bytes_max) return error.TranscriptFull;
        const owned_text = try allocator.dupe(u8, text);
        allocator.free(item.text);
        item.text = owned_text;
        item.revision += 1;
        self.bytes_used = new_total;
        self.bumpContentVersion();
    }

    fn ensureRoom(self: *const Transcript, added: usize) !void {
        if (self.count >= items_max) return error.TranscriptFull;
        const byte_count = std.math.add(usize, self.bytes_used, added) catch
            return error.TranscriptFull;
        if (byte_count > bytes_max) return error.TranscriptFull;
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

    fn bumpContentVersion(self: *Transcript) void {
        self.content_version = std.math.add(u64, self.content_version, 1) catch
            @panic("transcript content version overflow");
    }
};

pub const TranscriptView = struct {
    row_offset_from_tail: usize = 0,
    follow_tail: bool = true,
    observed_content_version: u64 = 0,

    pub const scroll_rows_per_command = 3;

    pub fn sync(self: *TranscriptView, transcript: *const Transcript) void {
        if (self.observed_content_version == transcript.content_version) return;
        self.observed_content_version = transcript.content_version;
        if (self.follow_tail) self.row_offset_from_tail = 0;
        if (self.row_offset_from_tail > transcript.count) self.row_offset_from_tail = transcript.count;
    }

    pub fn scrollUp(self: *TranscriptView, transcript: *const Transcript) void {
        const offset = std.math.add(usize, self.row_offset_from_tail, scroll_rows_per_command) catch
            transcript.count;
        self.row_offset_from_tail = @min(offset, transcript.count);
        self.follow_tail = self.row_offset_from_tail == 0;
        self.observed_content_version = transcript.content_version;
    }

    pub fn scrollDown(self: *TranscriptView) void {
        self.row_offset_from_tail -|= scroll_rows_per_command;
        self.follow_tail = self.row_offset_from_tail == 0;
    }

    pub fn itemForViewportRowFromBottom(
        self: TranscriptView,
        transcript: *const Transcript,
        row_from_bottom: usize,
    ) ?Transcript.Item {
        const tail_row = std.math.add(usize, self.row_offset_from_tail, row_from_bottom) catch
            return null;
        if (tail_row >= transcript.count) return null;
        const item_index = transcript.count - 1 - tail_row;
        std.debug.assert(item_index < transcript.count);
        return transcript.items[item_index];
    }
};

test "assistant deltas update one item" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendAssistantDelta(std.testing.allocator, "hel");
    try transcript.appendAssistantDelta(std.testing.allocator, "lo");
    try std.testing.expectEqual(@as(usize, 1), transcript.count);
    try std.testing.expectEqualStrings("hello", transcript.items[0].text);
    try std.testing.expectEqual(@as(u64, 2), transcript.content_version);
}

test "transcript rejects append past item byte bound" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendAssistantDelta(std.testing.allocator, "a" ** Transcript.item_text_max);
    try std.testing.expectError(
        error.TranscriptItemTooLarge,
        transcript.appendAssistantDelta(std.testing.allocator, "b"),
    );
    try std.testing.expectEqual(@as(usize, Transcript.item_text_max), transcript.items[0].text.len);
}

test "transcript view follows tail and can scroll older items" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);
    var view: TranscriptView = .{};

    _ = try transcript.append(std.testing.allocator, .system, "one");
    _ = try transcript.append(std.testing.allocator, .system, "two");
    _ = try transcript.append(std.testing.allocator, .system, "three");
    _ = try transcript.append(std.testing.allocator, .system, "four");
    view.sync(&transcript);

    try std.testing.expectEqualStrings("four", view.itemForViewportRowFromBottom(&transcript, 0).?.text);
    view.scrollUp(&transcript);
    try std.testing.expectEqualStrings("one", view.itemForViewportRowFromBottom(&transcript, 0).?.text);
    view.scrollDown();
    try std.testing.expectEqualStrings("four", view.itemForViewportRowFromBottom(&transcript, 0).?.text);
}
