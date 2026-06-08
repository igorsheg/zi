const std = @import("std");
const text_primitive = @import("../primitive/text.zig");

pub const buffer_size_bytes_max: usize = 16 * 1024;
pub const submit_size_bytes_max: usize = buffer_size_bytes_max;
pub const visible_rows_max: usize = 4;

pub const ComposerCommand = union(enum) {
    insert_utf8: []const u8,
    backspace,
    move_left,
    move_right,
    move_start,
    move_end,
    newline,
    clear,
    submit,
};

pub const ComposerBuffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    cursor_byte_index: usize = 0,

    pub fn deinit(self: *ComposerBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *ComposerBuffer) void {
        self.bytes.clearRetainingCapacity();
        self.cursor_byte_index = 0;
    }

    pub fn text(self: ComposerBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn apply(self: *ComposerBuffer, allocator: std.mem.Allocator, command: ComposerCommand) !?[]u8 {
        switch (command) {
            .insert_utf8 => |bytes| try self.insertUtf8(allocator, bytes),
            .backspace => self.backspace(),
            .move_left => self.moveLeft(),
            .move_right => self.moveRight(),
            .move_start => self.moveStart(),
            .move_end => self.moveEnd(),
            .newline => try self.insertUtf8(allocator, "\n"),
            .clear => self.clear(),
            .submit => return try self.takeSubmit(allocator),
        }
        return null;
    }

    pub fn insertUtf8(self: *ComposerBuffer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, bytes, '\r') == null) {
            try self.insertNormalized(allocator, bytes);
            return;
        }

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(allocator);
        try normalized.ensureTotalCapacity(allocator, bytes.len);
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            const byte = bytes[index];
            if (byte == '\r') {
                if (index + 1 < bytes.len and bytes[index + 1] == '\n') index += 1;
                normalized.appendAssumeCapacity('\n');
            } else {
                normalized.appendAssumeCapacity(byte);
            }
        }
        try self.insertNormalized(allocator, normalized.items);
    }

    fn insertNormalized(self: *ComposerBuffer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (self.bytes.items.len + bytes.len > buffer_size_bytes_max) return error.ComposerTooLarge;
        try self.bytes.insertSlice(allocator, self.cursor_byte_index, bytes);
        self.cursor_byte_index += bytes.len;
    }

    pub fn backspace(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        const start = text_primitive.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
        self.bytes.replaceRangeAssumeCapacity(start, self.cursor_byte_index - start, "");
        self.cursor_byte_index = start;
    }

    pub fn moveLeft(self: *ComposerBuffer) void {
        if (self.cursor_byte_index == 0) return;
        self.cursor_byte_index = text_primitive.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
    }

    pub fn moveRight(self: *ComposerBuffer) void {
        if (self.cursor_byte_index >= self.bytes.items.len) return;
        self.cursor_byte_index = text_primitive.nextGraphemeEnd(self.bytes.items, self.cursor_byte_index);
    }

    pub fn moveStart(self: *ComposerBuffer) void {
        self.cursor_byte_index = 0;
    }

    pub fn moveEnd(self: *ComposerBuffer) void {
        self.cursor_byte_index = self.bytes.items.len;
    }

    pub fn visualRows(self: ComposerBuffer, width: u16) usize {
        var view: [visible_rows_max]ComposerVisualRow = undefined;
        const projected = projectVisualRows(self, width, &view);
        return projected.total_rows;
    }

    pub fn visibleRows(self: ComposerBuffer, width: u16, out: *[visible_rows_max]ComposerVisualRow) ComposerProjection {
        return projectVisualRows(self, width, out);
    }

    pub fn takeSubmit(self: *ComposerBuffer, allocator: std.mem.Allocator) !?[]u8 {
        if (self.bytes.items.len == 0) return null;
        if (self.bytes.items.len > submit_size_bytes_max) return error.ComposerTooLarge;
        const owned = try allocator.dupe(u8, self.bytes.items);
        self.clear();
        return owned;
    }
};

pub const ComposerVisualRow = struct {
    text: []const u8,
};

pub const ComposerProjection = struct {
    first_visible_row: usize,
    visible_count: usize,
    total_rows: usize,
    cursor_visible: bool,
    cursor_visible_row: usize,
    cursor_display_col: usize,
};

fn projectVisualRows(
    composer: ComposerBuffer,
    width: u16,
    out: *[visible_rows_max]ComposerVisualRow,
) ComposerProjection {
    const total = countVisualRows(composer.text(), width);
    const skip = if (total > visible_rows_max) total - visible_rows_max else 0;
    var collector: ComposerRowCollector = .{ .rows = out, .skip_remaining = skip };
    emitVisualRows(composer.text(), width, &collector);
    const cursor = cursorPosition(composer.text(), width, composer.cursor_byte_index);
    const cursor_visible = cursor.row >= skip and cursor.row < skip + collector.visible_count;
    return .{
        .first_visible_row = skip,
        .visible_count = collector.visible_count,
        .total_rows = total,
        .cursor_visible = cursor_visible,
        .cursor_visible_row = if (cursor_visible) cursor.row - skip else 0,
        .cursor_display_col = if (cursor_visible) cursor.col else 0,
    };
}

fn countVisualRows(bytes: []const u8, width: u16) usize {
    var collector: ComposerRowCollector = .{ .rows = null };
    emitVisualRows(bytes, width, &collector);
    return collector.total_rows;
}

const CursorPosition = struct {
    row: usize,
    col: usize,
};

fn cursorPosition(bytes: []const u8, width: u16, cursor: usize) CursorPosition {
    std.debug.assert(cursor <= bytes.len);
    if (bytes.len == 0) return .{ .row = 0, .col = 0 };
    const wrap_width = @max(width, 1);
    var row: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const line = text_primitive.nextVisualLineBreak(bytes, start, wrap_width);
        if (cursor >= line.start and cursor <= line.end) {
            return .{ .row = row, .col = text_primitive.displayWidth(bytes[line.start..cursor]) };
        }
        if (line.next == start) break;
        start = line.next;
        row += 1;
    }
    if (bytes[bytes.len - 1] == '\n' and cursor == bytes.len) return .{ .row = row, .col = 0 };
    return .{ .row = if (row == 0) 0 else row - 1, .col = 0 };
}

const ComposerRowCollector = struct {
    rows: ?*[visible_rows_max]ComposerVisualRow,
    skip_remaining: usize = 0,
    visible_count: usize = 0,
    total_rows: usize = 0,

    fn emit(self: *ComposerRowCollector, row: ComposerVisualRow) void {
        self.total_rows += 1;
        if (self.skip_remaining > 0) {
            self.skip_remaining -= 1;
            return;
        }
        if (self.rows) |rows| {
            if (self.visible_count >= rows.len) return;
            rows[self.visible_count] = row;
            self.visible_count += 1;
        }
    }
};

fn emitVisualRows(bytes: []const u8, width: u16, collector: *ComposerRowCollector) void {
    if (bytes.len == 0) {
        collector.emit(.{ .text = "" });
        return;
    }
    const wrap_width = @max(width, 1);
    var start: usize = 0;
    while (start < bytes.len) {
        const line = text_primitive.nextVisualLineBreak(bytes, start, wrap_width);
        if (line.next == start) break;
        collector.emit(.{ .text = bytes[line.start..line.end] });
        start = line.next;
    }
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') collector.emit(.{ .text = "" });
}

test "composer inserts utf8 moves and backspaces by grapheme" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "ao\u{0300}👩🏽‍🚀b");
    composer.moveLeft();
    composer.backspace();
    try std.testing.expectEqualStrings("ao\u{0300}b", composer.text());
    composer.backspace();
    try std.testing.expectEqualStrings("ab", composer.text());

    const submitted = (try composer.takeSubmit(std.testing.allocator)).?;
    defer std.testing.allocator.free(submitted);
    try std.testing.expectEqualStrings("ab", submitted);
    try std.testing.expectEqualStrings("", composer.text());
}

test "composer normalizes newlines and projects visible tail rows" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "one\r\ntwo\rthree");
    try std.testing.expectEqualStrings("one\ntwo\nthree", composer.text());
    try std.testing.expect(try composer.apply(std.testing.allocator, .newline) == null);
    try composer.insertUtf8(std.testing.allocator, "four");

    var rows: [visible_rows_max]ComposerVisualRow = undefined;
    const projection = composer.visibleRows(20, &rows);
    try std.testing.expectEqual(@as(usize, 4), projection.total_rows);
    try std.testing.expectEqual(@as(usize, 4), projection.visible_count);
    try std.testing.expectEqualStrings("one", rows[0].text);
    try std.testing.expectEqualStrings("four", rows[3].text);
}

test "composer visible rows keep newest tail" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "1\n2\n3\n4\n5");
    var rows: [visible_rows_max]ComposerVisualRow = undefined;
    const projection = composer.visibleRows(20, &rows);
    try std.testing.expectEqual(@as(usize, 5), projection.total_rows);
    try std.testing.expectEqual(@as(usize, 1), projection.first_visible_row);
    try std.testing.expectEqualStrings("2", rows[0].text);
    try std.testing.expectEqualStrings("5", rows[3].text);
}

// Composer wrapping follows display rows, not physical newlines. This keeps the
// future editor contract honest: storage remains one UTF-8 buffer, while the
// render projection owns visual wrapping and tail selection.
test "composer visible rows wrap long lines and keep newest visual tail" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "abcde12345XYZ");
    var rows: [visible_rows_max]ComposerVisualRow = undefined;
    const projection = composer.visibleRows(5, &rows);
    try std.testing.expectEqual(@as(usize, 3), projection.total_rows);
    try std.testing.expectEqual(@as(usize, 0), projection.first_visible_row);
    try std.testing.expectEqualStrings("abcde", rows[0].text);
    try std.testing.expectEqualStrings("12345", rows[1].text);
    try std.testing.expectEqualStrings("XYZ", rows[2].text);
}

test "composer visible rows do not split wide graphemes" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "ab中cd");
    var rows: [visible_rows_max]ComposerVisualRow = undefined;
    const projection = composer.visibleRows(3, &rows);
    try std.testing.expectEqual(@as(usize, 3), projection.total_rows);
    try std.testing.expectEqualStrings("ab", rows[0].text);
    try std.testing.expectEqualStrings("中c", rows[1].text);
    try std.testing.expectEqualStrings("d", rows[2].text);
}

test "composer visible rows tail wrapped output" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "111\n222\n333\n444\n55555");
    var rows: [visible_rows_max]ComposerVisualRow = undefined;
    const projection = composer.visibleRows(3, &rows);
    try std.testing.expectEqual(@as(usize, 6), projection.total_rows);
    try std.testing.expectEqual(@as(usize, 2), projection.first_visible_row);
    try std.testing.expectEqualStrings("333", rows[0].text);
    try std.testing.expectEqualStrings("555", rows[2].text);
    try std.testing.expectEqualStrings("55", rows[3].text);
}

test "composer projection reports visible cursor display column" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "a中b");
    composer.moveLeft();

    var rows: [visible_rows_max]ComposerVisualRow = undefined;
    const projection = composer.visibleRows(20, &rows);
    try std.testing.expect(projection.cursor_visible);
    try std.testing.expectEqual(@as(usize, 0), projection.cursor_visible_row);
    try std.testing.expectEqual(@as(usize, 3), projection.cursor_display_col);
}

test "composer projection reports cursor on visible tail row" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insertUtf8(std.testing.allocator, "one\ntwo\nthree\nfour\nfive");

    var rows: [visible_rows_max]ComposerVisualRow = undefined;
    const projection = composer.visibleRows(20, &rows);
    try std.testing.expect(projection.cursor_visible);
    try std.testing.expectEqual(@as(usize, 3), projection.cursor_visible_row);
    try std.testing.expectEqual(@as(usize, 4), projection.cursor_display_col);
}

test "composer command contract owns editing and submit" {
    var composer: ComposerBuffer = .{};
    defer composer.deinit(std.testing.allocator);

    try std.testing.expect(try composer.apply(std.testing.allocator, .{ .insert_utf8 = "ab" }) == null);
    try std.testing.expect(try composer.apply(std.testing.allocator, .move_start) == null);
    try std.testing.expect(try composer.apply(std.testing.allocator, .{ .insert_utf8 = "中" }) == null);
    try std.testing.expectEqualStrings("中ab", composer.text());
    try std.testing.expect(try composer.apply(std.testing.allocator, .move_end) == null);
    try std.testing.expect(try composer.apply(std.testing.allocator, .backspace) == null);
    try std.testing.expectEqualStrings("中a", composer.text());

    const submitted = (try composer.apply(std.testing.allocator, .submit)).?;
    defer std.testing.allocator.free(submitted);
    try std.testing.expectEqualStrings("中a", submitted);
    try std.testing.expectEqualStrings("", composer.text());
}
