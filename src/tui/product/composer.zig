const std = @import("std");
const vaxis = @import("vaxis");

pub const CompletionState = union(enum) {
    closed,
    open: Open,

    pub const Open = struct {
        trigger: u8,
        query_start: usize,
        selected_index: usize = 0,
    };
};

pub const Composer = struct {
    pub const input_bytes_max = 64 * 1024;
    pub const insert_bytes_max = 4096;

    input: std.ArrayList(u8) = .empty,
    cursor_byte_index: usize = 0,
    revision: u64 = 0,
    completion: CompletionState = .closed,

    pub fn deinit(self: *Composer, allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.* = undefined;
    }

    pub fn insert(self: *Composer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (bytes.len > insert_bytes_max) return error.ComposerInsertTooLarge;
        if (self.input.items.len + bytes.len > input_bytes_max) return error.ComposerFull;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        std.debug.assert(self.cursor_byte_index <= self.input.items.len);

        try self.input.insertSlice(allocator, self.cursor_byte_index, bytes);
        self.cursor_byte_index += bytes.len;
        self.revision += 1;
        std.debug.assert(std.unicode.utf8ValidateSlice(self.input.items));
        self.updateCompletion();
    }

    pub fn clear(self: *Composer, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.input.clearRetainingCapacity();
        self.cursor_byte_index = 0;
        self.completion = .closed;
        self.revision += 1;
    }

    pub fn backspace(self: *Composer) bool {
        if (self.cursor_byte_index == 0) return false;
        std.debug.assert(self.cursor_byte_index <= self.input.items.len);

        const index = previousGraphemeStart(self.input.items[0..self.cursor_byte_index]);

        self.input.replaceRangeAssumeCapacity(index, self.cursor_byte_index - index, &.{});
        self.cursor_byte_index = index;
        self.revision += 1;
        self.updateCompletion();
        return true;
    }

    pub fn text(self: *const Composer) []const u8 {
        return self.input.items;
    }

    fn updateCompletion(self: *Composer) void {
        self.completion = .closed;
        if (self.cursor_byte_index == 0) return;

        var index = self.cursor_byte_index;
        while (index > 0) {
            index -= 1;
            const byte = self.input.items[index];
            if (byte == ' ' or byte == '\n' or byte == '\t') return;
            if (byte == '@' or byte == '/') {
                self.completion = .{ .open = .{
                    .trigger = byte,
                    .query_start = index + 1,
                } };
                return;
            }
        }
    }
};

fn previousGraphemeStart(bytes: []const u8) usize {
    std.debug.assert(bytes.len > 0);

    var iter = vaxis.unicode.graphemeIterator(bytes);
    var start: usize = 0;
    var previous_start: usize = 0;
    var last_width: u16 = 1;
    while (iter.next()) |grapheme| {
        previous_start = start;
        start = grapheme.start;
        last_width = vaxis.gwidth.gwidth(grapheme.bytes(bytes), .unicode);
    }
    if (start > 0 and last_width == 0) return previous_start;
    return start;
}

test "composer opens completion on file and command triggers" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insert(std.testing.allocator, "@src");
    try std.testing.expectEqualStrings("@src", composer.text());
    try std.testing.expectEqual(@as(u8, '@'), composer.completion.open.trigger);

    composer.clear(std.testing.allocator);
    try composer.insert(std.testing.allocator, "/model");
    try std.testing.expectEqual(@as(u8, '/'), composer.completion.open.trigger);
}

test "composer backspace removes the previous grapheme" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insert(std.testing.allocator, "a");
    try composer.insert(std.testing.allocator, "é");

    try std.testing.expect(composer.backspace());
    try std.testing.expectEqualStrings("a", composer.text());
    try std.testing.expect(composer.backspace());
    try std.testing.expectEqualStrings("", composer.text());
    try std.testing.expect(!composer.backspace());
}

test "composer backspace removes base and combining mark together" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insert(std.testing.allocator, "a");
    try composer.insert(std.testing.allocator, "e\u{0301}");

    try std.testing.expect(composer.backspace());
    try std.testing.expectEqualStrings("a", composer.text());
    try std.testing.expectEqual(@as(usize, 1), composer.cursor_byte_index);
}

test "composer backspace folds trailing zero-width cluster into previous grapheme" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insert(std.testing.allocator, "ae");
    try composer.insert(std.testing.allocator, "\u{0301}");

    try std.testing.expect(composer.backspace());
    try std.testing.expectEqualStrings("a", composer.text());
    try std.testing.expectEqual(@as(usize, 1), composer.cursor_byte_index);
}

test "composer rejects invalid utf8 before mutation" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insert(std.testing.allocator, "ok");
    try std.testing.expectError(error.InvalidUtf8, composer.insert(std.testing.allocator, "\x80"));

    try std.testing.expectEqualStrings("ok", composer.text());
    try std.testing.expectEqual(@as(usize, 2), composer.cursor_byte_index);
    try std.testing.expectEqual(@as(u64, 1), composer.revision);
}
