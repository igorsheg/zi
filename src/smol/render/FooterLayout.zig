const std = @import("std");
const terminal_render = @import("../../terminal_render/root.zig");
const Surface = terminal_render.Surface;
const Text = terminal_render.Text;

const FooterLayout = @This();

pub const Band = struct {
    first_row: u16,
    row_count: u16,

    pub fn lastRow(self: Band) u16 {
        return self.first_row + self.row_count - 1;
    }
};

pub const VisualLine = struct {
    start_byte: usize,
    end_byte: usize,
    start_column: u16,
};

allocator: std.mem.Allocator,
columns: u16,
surface_rows: u16,
status: ?Band,
composer: Band,
lines: []VisualLine,
first_visible_line: usize,
cursor: Surface.Cursor,

pub fn init(
    allocator: std.mem.Allocator,
    terminal_rows: u16,
    columns: u16,
    text: []const u8,
    cursor_byte: usize,
    prompt_width: u16,
) !FooterLayout {
    if (terminal_rows == 0 or columns == 0) return error.InvalidDimensions;

    const first_indent = if (prompt_width < columns) prompt_width else 0;
    var lines: std.ArrayList(VisualLine) = .empty;
    defer lines.deinit(allocator);

    const bounded_cursor = @min(cursor_byte, text.len);
    var cursor_line: usize = 0;
    var cursor_column: u16 = first_indent + 1;
    var cursor_recorded = false;
    var line_start: usize = 0;
    var line_width: u16 = 0;
    var index: usize = 0;
    var graphemes = Text.Iterator.init(text);
    while (graphemes.next()) |grapheme| {
        const line_indent: u16 = if (lines.items.len == 0) first_indent else 0;
        const capacity = columns - line_indent;
        const glyph_width: u16 = grapheme.width;

        if (grapheme.kind == .line_break) {
            if (!cursor_recorded and bounded_cursor <= index) {
                cursor_line = lines.items.len;
                cursor_column = clampedCursorColumn(line_indent, line_width, columns);
                cursor_recorded = true;
            }
            try lines.append(allocator, .{
                .start_byte = line_start,
                .end_byte = index,
                .start_column = line_indent + 1,
            });
            index = grapheme.endByte();
            line_start = index;
            line_width = 0;
            continue;
        }

        if (glyph_width != 0 and line_width != 0 and glyph_width > capacity - line_width) {
            try lines.append(allocator, .{
                .start_byte = line_start,
                .end_byte = index,
                .start_column = line_indent + 1,
            });
            line_start = index;
            line_width = 0;
        }

        const current_indent: u16 = if (lines.items.len == 0) first_indent else 0;
        if (!cursor_recorded and bounded_cursor <= index) {
            cursor_line = lines.items.len;
            cursor_column = clampedCursorColumn(current_indent, line_width, columns);
            cursor_recorded = true;
        }
        line_width = @min(line_width + glyph_width, columns - current_indent);
        index = grapheme.endByte();
    }

    var final_indent: u16 = if (lines.items.len == 0) first_indent else 0;
    const final_capacity = columns - final_indent;
    if (!cursor_recorded and bounded_cursor == text.len and
        line_start != text.len and line_width == final_capacity)
    {
        try lines.append(allocator, .{
            .start_byte = line_start,
            .end_byte = text.len,
            .start_column = final_indent + 1,
        });
        line_start = text.len;
        line_width = 0;
        final_indent = 0;
    }
    if (!cursor_recorded) {
        cursor_line = lines.items.len;
        cursor_column = clampedCursorColumn(final_indent, line_width, columns);
    }
    try lines.append(allocator, .{
        .start_byte = line_start,
        .end_byte = text.len,
        .start_column = final_indent + 1,
    });

    const has_status = terminal_rows > 1;
    const max_composer_rows: usize = terminal_rows - @intFromBool(has_status);
    const visible_count = @min(lines.items.len, max_composer_rows);
    const first_visible_line = if (lines.items.len <= visible_count)
        0
    else if (cursor_line < visible_count)
        0
    else
        @min(cursor_line - visible_count + 1, lines.items.len - visible_count);
    const status: ?Band = if (has_status) .{ .first_row = 1, .row_count = 1 } else null;
    const composer_first_row: u16 = if (has_status) 2 else 1;
    const composer: Band = .{
        .first_row = composer_first_row,
        .row_count = @intCast(visible_count),
    };
    const owned_lines = try allocator.dupe(VisualLine, lines.items);

    return .{
        .allocator = allocator,
        .columns = columns,
        .surface_rows = composer.lastRow(),
        .status = status,
        .composer = composer,
        .lines = owned_lines,
        .first_visible_line = first_visible_line,
        .cursor = .{
            .row = composer.first_row + @as(u16, @intCast(cursor_line - first_visible_line)),
            .column = cursor_column,
        },
    };
}

fn clampedCursorColumn(indent: u16, width: u16, columns: u16) u16 {
    const unbounded = @as(u32, indent) + width + 1;
    return @intCast(@min(unbounded, columns));
}

pub fn deinit(self: *FooterLayout) void {
    self.allocator.free(self.lines);
    self.* = undefined;
}

pub fn visibleLines(self: *const FooterLayout) []const VisualLine {
    return self.lines[self.first_visible_line..][0..self.composer.row_count];
}

pub fn sourceLineIndex(self: *const FooterLayout, visible_index: usize) usize {
    std.debug.assert(visible_index < self.composer.row_count);
    return self.first_visible_line + visible_index;
}

test "layout wraps composer and places cursor by display cells" {
    var layout = try FooterLayout.init(std.testing.allocator, 8, 6, "ab界cd", 5, 2);
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines[0].start_byte);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[0].end_byte);
    try std.testing.expectEqual(@as(usize, 5), layout.lines[1].start_byte);
    try std.testing.expectEqual(@as(u16, 3), layout.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), layout.cursor.column);
}

test "layout never splits an emoji ZWJ grapheme" {
    const family = "👨‍👩‍👧‍👦";
    var layout = try FooterLayout.init(std.testing.allocator, 4, 4, family, family.len, 2);
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
    try std.testing.expectEqual(@as(usize, family.len), layout.lines[0].end_byte);
    try std.testing.expectEqual(@as(usize, family.len), layout.lines[1].start_byte);
    try std.testing.expectEqual(@as(u16, 3), layout.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), layout.cursor.column);
}

test "layout advances an end cursor past an exactly full row" {
    var layout = try FooterLayout.init(std.testing.allocator, 4, 6, "abcd", 4, 2);
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[1].start_byte);
    try std.testing.expectEqual(@as(usize, 4), layout.lines[1].end_byte);
    try std.testing.expectEqual(@as(u16, 3), layout.cursor.row);
    try std.testing.expectEqual(@as(u16, 1), layout.cursor.column);
}

test "layout keeps the cursor line visible in a bounded terminal" {
    var layout = try FooterLayout.init(std.testing.allocator, 3, 4, "abcdefghijkl", 12, 2);
    defer layout.deinit();
    try std.testing.expectEqual(@as(u16, 1), layout.status.?.row_count);
    try std.testing.expectEqual(@as(u16, 2), layout.composer.row_count);
    try std.testing.expectEqual(@as(usize, 2), layout.first_visible_line);
    try std.testing.expectEqual(@as(u16, 3), layout.cursor.row);
}

test "layout handles maximum terminal width without arithmetic overflow" {
    const columns = std.math.maxInt(u16);
    const text = try std.testing.allocator.alloc(u8, @as(usize, columns) + 1);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    text[columns] = 'b';

    var wrapped = try FooterLayout.init(std.testing.allocator, 3, columns, text, text.len, 0);
    defer wrapped.deinit();
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqual(@as(usize, columns), wrapped.lines[1].start_byte);

    text[columns] = '\n';
    var newline = try FooterLayout.init(std.testing.allocator, 3, columns, text, columns, 0);
    defer newline.deinit();
    try std.testing.expectEqual(columns, newline.cursor.column);
}

test "one-row terminal admits only a composer band" {
    var layout = try FooterLayout.init(std.testing.allocator, 1, 10, "draft", 5, 2);
    defer layout.deinit();
    try std.testing.expect(layout.status == null);
    try std.testing.expectEqual(@as(u16, 1), layout.surface_rows);
    try std.testing.expectEqual(@as(u16, 1), layout.composer.first_row);
}
