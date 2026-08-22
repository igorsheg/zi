const std = @import("std");
const cell = @import("Cell.zig");
const GraphemeStore = @import("GraphemeStore.zig");
const Text = @import("Text.zig");

const Surface = @This();

pub const Color = cell.Color;
pub const Attributes = cell.Attributes;
pub const Style = cell.Style;
pub const Cell = cell.Cell;

pub const Cursor = struct {
    row: u16,
    column: u16,
    visible: bool = true,
};

pub const WriteResult = struct {
    next_column: u16,
    clipped: bool,
};

allocator: std.mem.Allocator,
rows: u16,
columns: u16,
cells: []Cell,
graphemes: GraphemeStore,
cursor: Cursor,

pub fn init(allocator: std.mem.Allocator, rows: u16, columns: u16) !Surface {
    if (rows == 0 or columns == 0) return error.InvalidDimensions;
    const cell_count = std.math.mul(usize, rows, columns) catch return error.InvalidDimensions;
    const cells = try allocator.alloc(Cell, cell_count);
    @memset(cells, .{});
    return .{
        .allocator = allocator,
        .rows = rows,
        .columns = columns,
        .cells = cells,
        .graphemes = GraphemeStore.init(allocator),
        .cursor = .{ .row = rows, .column = 1 },
    };
}

pub fn deinit(self: *Surface) void {
    self.graphemes.deinit();
    self.allocator.free(self.cells);
    self.* = undefined;
}

/// The returned surface owns an independent copy in `allocator`, including
/// every referenced grapheme.
pub fn clone(self: *const Surface, allocator: std.mem.Allocator) !Surface {
    var graphemes = try self.graphemes.clone(allocator);
    errdefer graphemes.deinit();
    const cells = try allocator.dupe(Cell, self.cells);
    return .{
        .allocator = allocator,
        .rows = self.rows,
        .columns = self.columns,
        .cells = cells,
        .graphemes = graphemes,
        .cursor = self.cursor,
    };
}

/// Returns a blank surface at new dimensions. Only the clamped cursor and its
/// visibility carry over, because terminal resize reflow cannot be inferred
/// from the old cell grid.
pub fn blankResizedClone(
    self: *const Surface,
    allocator: std.mem.Allocator,
    rows: u16,
    columns: u16,
) !Surface {
    var resized = try Surface.init(allocator, rows, columns);
    resized.cursor = .{
        .row = @min(self.cursor.row, rows),
        .column = @min(self.cursor.column, columns),
        .visible = self.cursor.visible,
    };
    return resized;
}

pub fn setCursor(self: *Surface, cursor: Cursor) !void {
    if (cursor.row == 0 or cursor.row > self.rows or
        cursor.column == 0 or cursor.column > self.columns)
    {
        return error.CursorOutOfBounds;
    }
    self.cursor = cursor;
}

/// Writes whole sanitized grapheme clusters. A cluster that does not fit is not
/// partially written, and its source bytes remain outside the frame.
pub fn writeText(
    self: *Surface,
    row: u16,
    start_column: u16,
    text: []const u8,
    style: Style,
) !WriteResult {
    if (row == 0 or row > self.rows or start_column == 0 or start_column > self.columns) {
        return error.OutOfBounds;
    }

    var column: usize = start_column;
    var iterator = Text.Iterator.init(text);
    var clipped = false;
    while (iterator.next()) |grapheme| {
        if (grapheme.kind == .line_break) {
            clipped = grapheme.endByte() < text.len;
            break;
        }
        if (grapheme.width == 0) continue;
        if (column > self.columns or grapheme.width > self.columns - column + 1) {
            clipped = true;
            break;
        }

        switch (grapheme.kind) {
            .tab => try self.writeBlankSpan(row, @intCast(column), grapheme.width, style),
            .text, .replacement => try self.writeGrapheme(
                row,
                @intCast(column),
                grapheme,
                style,
            ),
            .line_break => unreachable,
        }
        column += grapheme.width;
    }

    return .{
        .next_column = @intCast(@min(column, self.columns)),
        .clipped = clipped,
    };
}

pub fn displayWidth(text: []const u8) usize {
    return Text.displayWidth(text);
}

/// Compares rendered row content. Grapheme IDs are frame-local implementation
/// details, so equal byte sequences compare equal even when their IDs differ.
pub fn rowEqual(a: *const Surface, b: *const Surface, row: u16) bool {
    if (a.rows != b.rows or a.columns != b.columns) return false;
    const a_cells = a.rowCells(row) orelse return false;
    const b_cells = b.rowCells(row) orelse return false;
    for (a_cells, b_cells) |a_cell, b_cell| {
        if (!a_cell.sameGeometry(b_cell)) return false;
        const a_bytes = if (a_cell.grapheme) |id| a.graphemes.get(id) else null;
        const b_bytes = if (b_cell.grapheme) |id| b.graphemes.get(id) else null;
        if (a_bytes == null or b_bytes == null) {
            if (a_bytes != null or b_bytes != null) return false;
            continue;
        }
        if (!std.mem.eql(u8, a_bytes.?, b_bytes.?)) return false;
    }
    return true;
}

pub fn rowCells(self: *const Surface, row: u16) ?[]const Cell {
    if (row == 0 or row > self.rows) return null;
    const start = @as(usize, row - 1) * self.columns;
    return self.cells[start..][0..self.columns];
}

pub fn graphemeBytes(self: *const Surface, cell_value: Cell) ?[]const u8 {
    const id = cell_value.grapheme orelse return null;
    return self.graphemes.get(id);
}

pub fn lastOccupiedColumn(self: *const Surface, row: u16) u16 {
    const cells = self.rowCells(row) orelse return 0;
    var index = cells.len;
    while (index > 0) {
        index -= 1;
        if (!cells[index].isBlank()) return @intCast(index + 1);
    }
    return 0;
}

/// Applies a physical upward terminal scroll to the cell grid. The cursor does
/// not move, matching an upward scroll operation at the terminal boundary.
pub fn scrollUp(self: *Surface, row_count: u32) void {
    const rows_to_scroll: usize = @intCast(@min(row_count, @as(u32, self.rows)));
    if (rows_to_scroll == 0) return;
    const cell_count = rows_to_scroll * self.columns;
    @memmove(self.cells[0 .. self.cells.len - cell_count], self.cells[cell_count..]);
    @memset(self.cells[self.cells.len - cell_count ..], .{});
}

fn writeBlankSpan(self: *Surface, row: u16, column: u16, width: u8, style: Style) !void {
    for (0..width) |offset| {
        const target_column = column + @as(u16, @intCast(offset));
        self.clearSpanAt(row, target_column);
        self.cells[self.cellIndex(row, target_column).?] = .{ .style = style };
    }
}

fn writeGrapheme(
    self: *Surface,
    row: u16,
    column: u16,
    grapheme: Text.Grapheme,
    style: Style,
) !void {
    const id = try self.graphemes.put(grapheme.bytes);
    for (0..grapheme.width) |offset| {
        self.clearSpanAt(row, column + @as(u16, @intCast(offset)));
    }

    self.cells[self.cellIndex(row, column).?] = .{
        .grapheme = id,
        .width = grapheme.width,
        .style = style,
    };
    for (1..grapheme.width) |offset| {
        const target_column = column + @as(u16, @intCast(offset));
        self.cells[self.cellIndex(row, target_column).?] = .{
            .width = 0,
            .lead_offset = @intCast(offset),
            .style = style,
        };
    }
}

/// Clearing a continuation clears its lead and every continuation. This keeps
/// cell geometry valid when a write begins in the middle of a wide cluster.
fn clearSpanAt(self: *Surface, row: u16, column: u16) void {
    var lead_column = column;
    const index = self.cellIndex(row, column).?;
    const target = self.cells[index];
    if (target.lead_offset != 0) lead_column -= target.lead_offset;
    const lead = self.cells[self.cellIndex(row, lead_column).?];
    const span_width = if (lead.grapheme != null and lead.width > 0) lead.width else 1;
    for (0..span_width) |offset| {
        const clear_column = lead_column + @as(u16, @intCast(offset));
        if (clear_column > self.columns) break;
        self.cells[self.cellIndex(row, clear_column).?] = .{};
    }
}

fn cellIndex(self: *const Surface, row: u16, column: u16) ?usize {
    if (row == 0 or row > self.rows or column == 0 or column > self.columns) return null;
    return @as(usize, row - 1) * self.columns + column - 1;
}

test "surface stores ZWJ graphemes as one wide span" {
    const family = "👨‍👩‍👧‍👦";
    var surface = try Surface.init(std.testing.allocator, 1, 4);
    defer surface.deinit();

    const result = try surface.writeText(1, 1, family, .{});
    try std.testing.expectEqual(@as(u16, 3), result.next_column);
    try std.testing.expectEqual(@as(u8, 2), surface.cells[0].width);
    try std.testing.expectEqual(@as(u8, 1), surface.cells[1].lead_offset);
    try std.testing.expectEqualStrings(family, surface.graphemes.get(surface.cells[0].grapheme.?).?);
}

test "overwriting a wide-cell continuation clears the complete old span" {
    var surface = try Surface.init(std.testing.allocator, 1, 4);
    defer surface.deinit();
    _ = try surface.writeText(1, 1, "界", .{});
    _ = try surface.writeText(1, 2, "x", .{});

    try std.testing.expect(surface.cells[0].isBlank());
    try std.testing.expectEqualStrings("x", surface.graphemes.get(surface.cells[1].grapheme.?).?);
    try std.testing.expectEqual(@as(u8, 0), surface.cells[1].lead_offset);
}

test "clone owns grapheme bytes and row equality ignores store IDs" {
    var original = try Surface.init(std.testing.allocator, 1, 4);
    defer original.deinit();
    _ = try original.writeText(1, 1, "界", .{});
    var copy = try original.clone(std.testing.allocator);
    defer copy.deinit();
    try std.testing.expect(rowEqual(&original, &copy, 1));

    var equivalent = try Surface.init(std.testing.allocator, 1, 4);
    defer equivalent.deinit();
    _ = try equivalent.writeText(1, 1, "x", .{});
    _ = try equivalent.writeText(1, 1, "界", .{});
    try std.testing.expect(original.cells[0].grapheme.? != equivalent.cells[0].grapheme.?);
    try std.testing.expect(rowEqual(&original, &equivalent, 1));
}

test "blank resized clone forgets cells and clamps the retained cursor" {
    var original = try Surface.init(std.testing.allocator, 3, 6);
    defer original.deinit();
    _ = try original.writeText(1, 1, "shell", .{});
    try original.setCursor(.{ .row = 3, .column = 6, .visible = false });

    var resized = try original.blankResizedClone(std.testing.allocator, 2, 4);
    defer resized.deinit();
    try std.testing.expectEqual(@as(u16, 2), resized.rows);
    try std.testing.expectEqual(@as(u16, 4), resized.columns);
    const expected_cursor: Cursor = .{ .row = 2, .column = 4, .visible = false };
    try std.testing.expectEqual(expected_cursor, resized.cursor);
    for (resized.cells) |value| try std.testing.expect(value.isBlank());
    try std.testing.expectEqualStrings("s", original.graphemeBytes(original.cells[0]).?);
}

test "scroll up moves complete rows and blanks the released tail" {
    var surface = try Surface.init(std.testing.allocator, 4, 4);
    defer surface.deinit();
    _ = try surface.writeText(1, 1, "one", .{});
    _ = try surface.writeText(2, 1, "two", .{});
    _ = try surface.writeText(3, 1, "界", .{});
    try surface.setCursor(.{ .row = 4, .column = 3 });

    surface.scrollUp(2);
    try std.testing.expectEqualStrings("界", surface.graphemeBytes(surface.rowCells(1).?[0]).?);
    try std.testing.expectEqual(@as(u8, 1), surface.rowCells(1).?[1].lead_offset);
    for (surface.rowCells(2).?) |value| try std.testing.expect(value.isBlank());
    for (surface.rowCells(3).?) |value| try std.testing.expect(value.isBlank());
    for (surface.rowCells(4).?) |value| try std.testing.expect(value.isBlank());
    const expected_cursor: Cursor = .{ .row = 4, .column = 3 };
    try std.testing.expectEqual(expected_cursor, surface.cursor);
}

test "scroll up clamps movement to surface height" {
    var surface = try Surface.init(std.testing.allocator, 2, 3);
    defer surface.deinit();
    _ = try surface.writeText(2, 1, "x", .{});

    surface.scrollUp(std.math.maxInt(u32));
    for (surface.cells) |value| try std.testing.expect(value.isBlank());
}

test "surface clips whole graphemes at the row boundary" {
    var surface = try Surface.init(std.testing.allocator, 1, 2);
    defer surface.deinit();
    const result = try surface.writeText(1, 1, "a界", .{});

    try std.testing.expect(result.clipped);
    try std.testing.expectEqual(@as(u16, 2), result.next_column);
    try std.testing.expectEqualStrings("a", surface.graphemes.get(surface.cells[0].grapheme.?).?);
    try std.testing.expect(surface.cells[1].isBlank());
}

test "surface writes the rightmost cell at maximum dimensions without overflow" {
    var surface = try Surface.init(std.testing.allocator, 1, std.math.maxInt(u16));
    defer surface.deinit();
    const result = try surface.writeText(1, std.math.maxInt(u16), "x!", .{});
    try std.testing.expect(result.clipped);
    try std.testing.expectEqual(std.math.maxInt(u16), result.next_column);
    try std.testing.expectEqualStrings(
        "x",
        surface.graphemeBytes(surface.cells[surface.cells.len - 1]).?,
    );
}

test "surface relies on text sanitation for controls and invalid UTF-8" {
    var surface = try Surface.init(std.testing.allocator, 1, 8);
    defer surface.deinit();
    _ = try surface.writeText(1, 1, "a\x1bb\xff", .{});

    try std.testing.expectEqualStrings("�", surface.graphemes.get(surface.cells[1].grapheme.?).?);
    try std.testing.expectEqualStrings("�", surface.graphemes.get(surface.cells[3].grapheme.?).?);
}
