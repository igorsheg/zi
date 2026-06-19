//! The prompt editor: one UTF-8 buffer plus a byte cursor. Storage stays a
//! flat buffer; visual wrapping and the visible-tail window live in a cached
//! projection keyed by (revision, width), because status animation renders
//! frames far more often than the text changes.
//!
//! Callers pass valid UTF-8 (App sanitizes operational input first); that
//! contract is asserted, not error-handled. The only operational rejection
//! is the byte cap, surfaced as `InsertResult.rejected_full`.
const std = @import("std");
const text_mod = @import("text.zig");

const Composer = @This();

pub const buffer_size_bytes_max: usize = 16 * 1024;
pub const visible_rows_max: usize = 4;

bytes: std.ArrayList(u8) = .empty,
cursor_byte_index: usize = 0,
vertical_target_col: ?usize = null,
revision: u64 = 0,
projection_cache: ?ProjectionCache = null,

pub fn deinit(self: *Composer, gpa: std.mem.Allocator) void {
    self.bytes.deinit(gpa);
    self.* = undefined;
}

pub fn text(self: *const Composer) []const u8 {
    return self.bytes.items;
}

pub const InsertResult = enum { ok, rejected_full };
pub const VerticalDirection = enum { up, down };
pub const MoveVerticalResult = enum { moved, boundary };

/// Insert at the cursor. CR and CRLF normalize to LF so terminal enter/paste
/// variants produce one newline encoding.
pub fn insert(self: *Composer, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!InsertResult {
    std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
    if (std.mem.indexOfScalar(u8, bytes, '\r') == null) return self.insertNormalized(gpa, bytes);

    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(gpa);
    try normalized.ensureTotalCapacity(gpa, bytes.len);
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
    return self.insertNormalized(gpa, normalized.items);
}

fn insertNormalized(self: *Composer, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!InsertResult {
    if (bytes.len == 0) return .ok;
    if (self.bytes.items.len + bytes.len > buffer_size_bytes_max) return .rejected_full;
    try self.bytes.insertSlice(gpa, self.cursor_byte_index, bytes);
    self.cursor_byte_index += bytes.len;
    self.noteEdit();
    return .ok;
}

pub fn clear(self: *Composer) void {
    if (self.bytes.items.len == 0 and self.cursor_byte_index == 0 and self.vertical_target_col == null) return;
    self.bytes.clearRetainingCapacity();
    self.cursor_byte_index = 0;
    self.noteEdit();
}

pub fn replaceText(self: *Composer, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!void {
    try self.replaceTextAtCursor(gpa, bytes, bytes.len);
}

pub fn replaceTextAtCursor(
    self: *Composer,
    gpa: std.mem.Allocator,
    bytes: []const u8,
    cursor_byte_index: usize,
) error{OutOfMemory}!void {
    std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
    std.debug.assert(bytes.len <= buffer_size_bytes_max);
    std.debug.assert(cursor_byte_index <= bytes.len);

    try self.bytes.ensureTotalCapacity(gpa, bytes.len);
    self.bytes.clearRetainingCapacity();
    self.bytes.appendSliceAssumeCapacity(bytes);
    self.cursor_byte_index = cursor_byte_index;
    self.noteEdit();
}

pub fn submitSlice(self: *const Composer) ?[]const u8 {
    if (self.bytes.items.len == 0) return null;
    const trimmed = std.mem.trim(u8, self.bytes.items, " \t\n\r");
    return if (trimmed.len == 0) null else trimmed;
}

pub fn backspace(self: *Composer) void {
    if (self.cursor_byte_index == 0) return;
    const start = text_mod.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
    self.bytes.replaceRangeAssumeCapacity(start, self.cursor_byte_index - start, "");
    self.cursor_byte_index = start;
    self.noteEdit();
}

pub fn deleteForward(self: *Composer) void {
    if (self.cursor_byte_index >= self.bytes.items.len) return;
    const end = text_mod.nextGraphemeEnd(self.bytes.items, self.cursor_byte_index);
    self.bytes.replaceRangeAssumeCapacity(self.cursor_byte_index, end - self.cursor_byte_index, "");
    self.noteEdit();
}

pub fn moveLeft(self: *Composer) void {
    if (self.cursor_byte_index == 0) return;
    self.cursor_byte_index = text_mod.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
    self.noteEdit();
}

pub fn moveRight(self: *Composer) void {
    if (self.cursor_byte_index >= self.bytes.items.len) return;
    self.cursor_byte_index = text_mod.nextGraphemeEnd(self.bytes.items, self.cursor_byte_index);
    self.noteEdit();
}

pub fn moveStart(self: *Composer) void {
    if (self.cursor_byte_index == 0) return;
    self.cursor_byte_index = 0;
    self.noteEdit();
}

pub fn moveEnd(self: *Composer) void {
    if (self.cursor_byte_index == self.bytes.items.len) return;
    self.cursor_byte_index = self.bytes.items.len;
    self.noteEdit();
}

pub fn moveVertical(self: *Composer, width: u16, direction: VerticalDirection) MoveVerticalResult {
    const current = self.cursorPosition(width);
    const target_row = switch (direction) {
        .up => if (current.row == 0) return .boundary else current.row - 1,
        .down => if (current.row + 1 >= current.total_rows) return .boundary else current.row + 1,
    };
    const target_col = self.vertical_target_col orelse current.col;
    const target_index = self.byteIndexAtRowCol(width, target_row, target_col);
    if (target_index == self.cursor_byte_index) return .boundary;
    self.vertical_target_col = target_col;
    self.cursor_byte_index = target_index;
    self.bumpRevision();
    return .moved;
}

pub fn visualRows(self: *Composer, width: u16) usize {
    return self.cachedProjection(width).projection.total_rows;
}

pub fn visibleRows(self: *Composer, width: u16, out: *[visible_rows_max]VisualRow) Projection {
    const cached = self.cachedProjection(width);
    @memcpy(out[0..cached.projection.visible_count], cached.rows[0..cached.projection.visible_count]);
    return cached.projection;
}

const CursorLocation = struct {
    row: usize,
    col: usize,
    total_rows: usize,
};

fn cursorPosition(self: *const Composer, width: u16) CursorLocation {
    std.debug.assert(self.cursor_byte_index <= self.bytes.items.len);
    const bytes = self.bytes.items;
    if (bytes.len == 0) return .{ .row = 0, .col = 0, .total_rows = 1 };

    const wrap_width = @max(width, 1);
    var found_row: usize = 0;
    var found_col: usize = 0;
    var found = false;
    var total_rows: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const line = text_mod.nextVisualLineBreak(bytes, start, wrap_width);
        if (line.next == start) break;
        if (!found and self.cursor_byte_index >= line.start and self.cursor_byte_index <= line.end) {
            found_row = total_rows;
            found_col = if (self.cursor_byte_index == line.end)
                line.width
            else
                text_mod.displayWidth(bytes[line.start..self.cursor_byte_index]);
            found = true;
        }
        total_rows += 1;
        start = line.next;
    }
    if (bytes[bytes.len - 1] == '\n') {
        if (!found and self.cursor_byte_index == bytes.len) {
            found_row = total_rows;
            found_col = 0;
            found = true;
        }
        total_rows += 1;
    }
    if (!found) {
        found_row = if (total_rows == 0) 0 else total_rows - 1;
        found_col = 0;
    }
    return .{ .row = found_row, .col = found_col, .total_rows = @max(total_rows, 1) };
}

fn byteIndexAtRowCol(self: *const Composer, width: u16, target_row: usize, target_col: usize) usize {
    const bytes = self.bytes.items;
    if (bytes.len == 0) return 0;

    const wrap_width = @max(width, 1);
    var row: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const line = text_mod.nextVisualLineBreak(bytes, start, wrap_width);
        if (line.next == start) break;
        if (row == target_row) return byteIndexForDisplayCol(bytes, line.start, line.end, target_col);
        row += 1;
        start = line.next;
    }
    if (bytes[bytes.len - 1] == '\n' and row == target_row) return bytes.len;
    return bytes.len;
}

fn byteIndexForDisplayCol(bytes: []const u8, start: usize, end: usize, target_col: usize) usize {
    var index = start;
    var col: usize = 0;
    while (index < end) {
        const grapheme = text_mod.nextGrapheme(bytes[index..end]);
        if (grapheme.end == 0) break;
        const next_col = col + grapheme.width;
        if (next_col > target_col) return index;
        index += grapheme.end;
        col = next_col;
    }
    return end;
}

fn cachedProjection(self: *Composer, width: u16) ProjectionCache {
    if (self.projection_cache) |cache| {
        if (cache.revision == self.revision and cache.width == width) return cache;
    }
    var cache: ProjectionCache = .{
        .revision = self.revision,
        .width = width,
        .rows = undefined,
        .projection = undefined,
    };
    cache.projection = projectVisualRows(self, width, &cache.rows);
    self.projection_cache = cache;
    return cache;
}

fn noteEdit(self: *Composer) void {
    self.vertical_target_col = null;
    self.bumpRevision();
}

fn bumpRevision(self: *Composer) void {
    self.revision +%= 1;
    self.projection_cache = null;
}

pub const VisualRow = struct {
    text: []const u8,
};

const ProjectionCache = struct {
    revision: u64,
    width: u16,
    projection: Projection,
    rows: [visible_rows_max]VisualRow,
};

pub const Projection = struct {
    first_visible_row: usize,
    visible_count: usize,
    total_rows: usize,
    cursor_visible: bool,
    cursor_visible_row: usize,
    cursor_display_col: usize,
};

fn projectVisualRows(composer: *const Composer, width: u16, out: *[visible_rows_max]VisualRow) Projection {
    std.debug.assert(composer.cursor_byte_index <= composer.text().len);
    var builder: ProjectionBuilder = .{ .out = out, .cursor_byte_index = composer.cursor_byte_index };
    builder.project(composer.text(), width);
    return builder.finish();
}

const CursorPosition = struct {
    row: usize = 0,
    col: usize = 0,
    found: bool = false,
};

const ProjectionBuilder = struct {
    out: *[visible_rows_max]VisualRow,
    cursor_byte_index: usize,
    total_rows: usize = 0,
    cursor: CursorPosition = .{},

    fn project(self: *ProjectionBuilder, bytes: []const u8, width: u16) void {
        if (bytes.len == 0) {
            self.cursor = .{ .row = 0, .col = 0, .found = true };
            self.emit(.{ .text = "" });
            return;
        }

        const wrap_width = @max(width, 1);
        var start: usize = 0;
        while (start < bytes.len) {
            const line = text_mod.nextVisualLineBreak(bytes, start, wrap_width);
            if (line.next == start) break;
            self.captureCursor(bytes, line);
            self.emit(.{ .text = bytes[line.start..line.end] });
            start = line.next;
        }
        if (bytes[bytes.len - 1] == '\n') {
            if (self.cursor_byte_index == bytes.len) self.cursor = .{
                .row = self.total_rows,
                .col = 0,
                .found = true,
            };
            self.emit(.{ .text = "" });
        }
    }

    fn captureCursor(self: *ProjectionBuilder, bytes: []const u8, line: text_mod.VisualLineBreak) void {
        if (self.cursor.found) return;
        if (self.cursor_byte_index < line.start or self.cursor_byte_index > line.end) return;
        const col = if (self.cursor_byte_index == line.end)
            line.width
        else
            text_mod.displayWidth(bytes[line.start..self.cursor_byte_index]);
        self.cursor = .{ .row = self.total_rows, .col = col, .found = true };
    }

    fn emit(self: *ProjectionBuilder, row: VisualRow) void {
        self.out[self.total_rows % visible_rows_max] = row;
        self.total_rows += 1;
    }

    fn finish(self: *ProjectionBuilder) Projection {
        if (!self.cursor.found) self.cursor = .{
            .row = if (self.total_rows == 0) 0 else self.total_rows - 1,
            .col = 0,
            .found = true,
        };
        const visible_count = @min(self.total_rows, visible_rows_max);
        const first_visible_row = self.total_rows - visible_count;
        self.rotateVisibleRows(first_visible_row, visible_count);
        const cursor_visible = self.cursor.row >= first_visible_row and
            self.cursor.row < first_visible_row + visible_count;
        return .{
            .first_visible_row = first_visible_row,
            .visible_count = visible_count,
            .total_rows = self.total_rows,
            .cursor_visible = cursor_visible,
            .cursor_visible_row = if (cursor_visible) self.cursor.row - first_visible_row else 0,
            .cursor_display_col = if (cursor_visible) self.cursor.col else 0,
        };
    }

    /// The emit ring stores rows modulo capacity; reorder so out[0..count]
    /// is the visible window oldest-first.
    fn rotateVisibleRows(self: *ProjectionBuilder, first_visible_row: usize, visible_count: usize) void {
        var ordered: [visible_rows_max]VisualRow = undefined;
        var index: usize = 0;
        while (index < visible_count) : (index += 1) {
            ordered[index] = self.out[(first_visible_row + index) % visible_rows_max];
        }
        @memcpy(self.out[0..visible_count], ordered[0..visible_count]);
    }
};

test "insert normalizes CRLF and moves the cursor" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    try std.testing.expectEqual(InsertResult.ok, try composer.insert(gpa, "a\r\nb\rc"));
    try std.testing.expectEqualStrings("a\nb\nc", composer.text());
    try std.testing.expectEqual(composer.text().len, composer.cursor_byte_index);
}

test "insert rejects past the byte cap without mutating" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    const big = try gpa.alloc(u8, buffer_size_bytes_max);
    defer gpa.free(big);
    @memset(big, 'x');
    try std.testing.expectEqual(InsertResult.ok, try composer.insert(gpa, big));
    try std.testing.expectEqual(InsertResult.rejected_full, try composer.insert(gpa, "y"));
    try std.testing.expectEqual(buffer_size_bytes_max, composer.text().len);
}

test "deleteForward removes the grapheme under the cursor" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insert(gpa, "ab");
    composer.moveStart();
    composer.deleteForward();
    try std.testing.expectEqualStrings("b", composer.text());
}

test "vertical movement follows wrapped rows" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insert(gpa, "abcdef");
    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(3, .up));
    try std.testing.expectEqual(@as(usize, 3), composer.cursor_byte_index);
    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(3, .down));
    try std.testing.expectEqual(@as(usize, 6), composer.cursor_byte_index);
}

test "vertical movement preserves the desired display column across short rows" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insert(gpa, "abcdef\ngh\nijklmn");
    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(6, .up));
    try std.testing.expectEqual(@as(usize, 9), composer.cursor_byte_index);
    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(6, .up));
    try std.testing.expectEqual(@as(usize, 6), composer.cursor_byte_index);
}

test "projection cache invalidates on edit and tracks the cursor" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insert(gpa, "hello world");
    try std.testing.expectEqual(@as(usize, 2), composer.visualRows(6));

    var rows: [visible_rows_max]VisualRow = undefined;
    var projection = composer.visibleRows(6, &rows);
    try std.testing.expect(projection.cursor_visible);

    composer.backspace();
    projection = composer.visibleRows(6, &rows);
    try std.testing.expectEqualStrings("worl", rows[projection.visible_count - 1].text);
}

test "trailing newline emits an empty row with the cursor on it" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insert(gpa, "a\n");
    var rows: [visible_rows_max]VisualRow = undefined;
    const projection = composer.visibleRows(10, &rows);
    try std.testing.expectEqual(@as(usize, 2), projection.total_rows);
    try std.testing.expectEqual(@as(usize, 1), projection.cursor_visible_row);
    try std.testing.expectEqual(@as(usize, 0), projection.cursor_display_col);
}
