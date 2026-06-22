//! The prompt editor: one UTF-8 buffer plus a byte cursor. Storage stays a
//! flat buffer; visual wrapping and the cursor-visible window live in a cached
//! projection keyed by (revision, width), because status animation renders
//! frames far more often than the text changes.
//!
//! Callers pass valid UTF-8 (App sanitizes operational input first); that
//! contract is asserted, not error-handled. Operational overflow inserts the
//! largest UTF-8 prefix that fits and reports the dropped suffix.
const std = @import("std");
const text_mod = @import("text.zig");

const Composer = @This();

pub const buffer_size_bytes_max: usize = 16 * 1024;
pub const visible_rows_max: usize = 4;
pub const paste_line_threshold: usize = 10;
pub const paste_byte_threshold: usize = 1000;
pub const paste_payload_bytes_max: usize = 64 * 1024;
pub const paste_slots_max: usize = 8;

bytes: std.ArrayList(u8) = .empty,
cursor_byte_index: usize = 0,
vertical_target_col: ?usize = null,
first_visible_row: usize = 0,
revision: u64 = 0,
projection_cache: ?ProjectionCache = null,
pastes: std.ArrayList(Paste) = .empty,
next_paste_id: u32 = 1,

const Paste = struct {
    id: u32,
    marker: []u8,
    payload: []u8,
};

pub fn deinit(self: *Composer, gpa: std.mem.Allocator) void {
    self.clearPastes(gpa);
    self.pastes.deinit(gpa);
    self.bytes.deinit(gpa);
    self.* = undefined;
}

pub fn text(self: *const Composer) []const u8 {
    return self.bytes.items;
}

pub const InsertResult = enum { ok, inserted_truncated, rejected_full };
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
    const remaining = buffer_size_bytes_max - self.bytes.items.len;
    const inserted = text_mod.utf8Prefix(bytes, remaining);
    if (inserted.len == 0) return .rejected_full;
    try self.bytes.insertSlice(gpa, self.cursor_byte_index, inserted);
    self.cursor_byte_index += inserted.len;
    self.noteEdit();
    return if (inserted.len == bytes.len) .ok else .inserted_truncated;
}

/// Insert a bracketed paste. Large payloads are kept out of the visible
/// composer buffer and represented by a generated marker that expands only
/// while its exact marker storage is still live.
pub fn insertPaste(self: *Composer, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!InsertResult {
    std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
    const normalized = try normalizedPaste(gpa, bytes);
    defer if (normalized.owned) |owned| gpa.free(owned);
    const paste = normalized.bytes;
    if (!isLargePaste(paste) or self.pastes.items.len >= paste_slots_max) return self.insertNormalized(gpa, paste);
    return self.insertPasteMarkerNormalized(gpa, paste);
}

/// Insert a bracketed-paste marker regardless of payload size. This is for
/// operational payloads that should stay out of the visible composer even when
/// their expansion is short, such as an image temp-file reference.
pub fn insertPasteMarker(self: *Composer, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!InsertResult {
    std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
    const normalized = try normalizedPaste(gpa, bytes);
    defer if (normalized.owned) |owned| gpa.free(owned);
    const paste = normalized.bytes;
    if (paste.len == 0) return .ok;
    if (self.pastes.items.len >= paste_slots_max) return self.insertNormalized(gpa, paste);
    return self.insertPasteMarkerNormalized(gpa, paste);
}

fn insertPasteMarkerNormalized(
    self: *Composer,
    gpa: std.mem.Allocator,
    paste: []const u8,
) error{OutOfMemory}!InsertResult {
    var marker_buffer: [64]u8 = undefined;
    const marker = makePasteMarker(&marker_buffer, self.next_paste_id, paste) catch unreachable;
    if (marker.len > buffer_size_bytes_max - self.bytes.items.len) return .rejected_full;

    const payload_copy = try gpa.dupe(u8, paste);
    errdefer gpa.free(payload_copy);
    const marker_copy = try gpa.dupe(u8, marker);
    errdefer gpa.free(marker_copy);
    try self.bytes.insertSlice(gpa, self.cursor_byte_index, marker_copy);
    errdefer self.bytes.replaceRangeAssumeCapacity(self.cursor_byte_index, marker_copy.len, "");
    try self.pastes.append(gpa, .{ .id = self.next_paste_id, .marker = marker_copy, .payload = payload_copy });
    self.next_paste_id +%= 1;
    if (self.next_paste_id == 0) self.next_paste_id = 1;
    self.cursor_byte_index += marker_copy.len;
    self.noteEdit();
    return .ok;
}

const NormalizedPaste = struct {
    bytes: []const u8,
    owned: ?[]u8 = null,
};

fn normalizedPaste(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!NormalizedPaste {
    if (std.mem.indexOfScalar(u8, bytes, '\r') == null) return .{ .bytes = bytes };
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(gpa);
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
    return .{ .bytes = normalized.items, .owned = try normalized.toOwnedSlice(gpa) };
}

fn isLargePaste(bytes: []const u8) bool {
    if (bytes.len > paste_byte_threshold) return true;
    var lines: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines > paste_line_threshold;
}

fn makePasteMarker(buffer: []u8, id: u32, bytes: []const u8) error{NoSpaceLeft}![]const u8 {
    var lines: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') lines += 1;
    }
    if (lines > paste_line_threshold) {
        return std.fmt.bufPrint(buffer, "[paste #{d} +{d} lines]", .{ id, lines });
    }
    return std.fmt.bufPrint(buffer, "[paste #{d} {d} bytes]", .{ id, bytes.len });
}

pub fn clear(self: *Composer) void {
    if (self.bytes.items.len == 0 and
        self.cursor_byte_index == 0 and
        self.vertical_target_col == null and
        self.first_visible_row == 0) return;
    self.bytes.clearRetainingCapacity();
    self.cursor_byte_index = 0;
    self.first_visible_row = 0;
    self.noteEdit();
}

pub fn clearAndFreePastes(self: *Composer, gpa: std.mem.Allocator) void {
    self.clear();
    self.clearPastes(gpa);
    self.next_paste_id = 1;
}

fn clearPastes(self: *Composer, gpa: std.mem.Allocator) void {
    for (self.pastes.items) |paste| {
        gpa.free(paste.marker);
        gpa.free(paste.payload);
    }
    self.pastes.clearRetainingCapacity();
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
    self.first_visible_row = 0;
    self.noteEdit();
}

pub fn submitSlice(self: *const Composer) ?[]const u8 {
    if (self.bytes.items.len == 0) return null;
    const trimmed = std.mem.trim(u8, self.bytes.items, " \t\n\r");
    return if (trimmed.len == 0) null else trimmed;
}

pub fn submitOwned(self: *const Composer, gpa: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
    const text_to_submit = self.submitSlice() orelse return null;
    if (self.pastes.items.len == 0) {
        const copy = try gpa.dupe(u8, text_to_submit);
        return copy;
    }

    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(gpa);
    var index: usize = 0;
    while (index < text_to_submit.len) {
        if (self.pasteAt(text_to_submit[index..])) |paste| {
            try expanded.appendSlice(gpa, paste.payload);
            index += paste.marker.len;
        } else {
            try expanded.append(gpa, text_to_submit[index]);
            index += 1;
        }
    }
    const trimmed = std.mem.trim(u8, expanded.items, " \t\n\r");
    if (trimmed.len == 0) return null;
    const copy = try gpa.dupe(u8, trimmed);
    return copy;
}

pub fn expandedTextOwned(self: *const Composer, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    if (self.pastes.items.len == 0) return gpa.dupe(u8, self.bytes.items);
    var expanded: std.ArrayList(u8) = .empty;
    errdefer expanded.deinit(gpa);
    var index: usize = 0;
    while (index < self.bytes.items.len) {
        if (self.pasteAt(self.bytes.items[index..])) |paste| {
            try expanded.appendSlice(gpa, paste.payload);
            index += paste.marker.len;
        } else {
            try expanded.append(gpa, self.bytes.items[index]);
            index += 1;
        }
    }
    return expanded.toOwnedSlice(gpa);
}

fn pasteAt(self: *const Composer, bytes: []const u8) ?Paste {
    for (self.pastes.items) |paste| {
        if (std.mem.startsWith(u8, bytes, paste.marker)) return paste;
    }
    return null;
}

const PasteSpan = struct {
    paste_index: usize,
    start: usize,
    end: usize,
};

fn pasteSpanContaining(self: *const Composer, byte_index: usize) ?PasteSpan {
    for (self.pastes.items, 0..) |paste, paste_index| {
        var search_start: usize = 0;
        while (std.mem.findPos(u8, self.bytes.items, search_start, paste.marker)) |start| {
            const end = start + paste.marker.len;
            if (byte_index >= start and byte_index < end) return .{
                .paste_index = paste_index,
                .start = start,
                .end = end,
            };
            search_start = end;
        }
    }
    return null;
}

fn removePasteSpan(self: *Composer, gpa: std.mem.Allocator, span: PasteSpan) void {
    self.bytes.replaceRangeAssumeCapacity(span.start, span.end - span.start, "");
    const paste = self.pastes.swapRemove(span.paste_index);
    gpa.free(paste.marker);
    gpa.free(paste.payload);
    self.cursor_byte_index = span.start;
    self.noteEdit();
}

pub fn backspace(self: *Composer, gpa: std.mem.Allocator) void {
    if (self.cursor_byte_index == 0) return;
    if (self.pasteSpanContaining(self.cursor_byte_index - 1)) |span| {
        self.removePasteSpan(gpa, span);
        return;
    }
    const start = text_mod.previousGraphemeStart(self.bytes.items, self.cursor_byte_index);
    self.bytes.replaceRangeAssumeCapacity(start, self.cursor_byte_index - start, "");
    self.cursor_byte_index = start;
    self.noteEdit();
}

pub fn deleteForward(self: *Composer, gpa: std.mem.Allocator) void {
    if (self.cursor_byte_index >= self.bytes.items.len) return;
    if (self.pasteSpanContaining(self.cursor_byte_index)) |span| {
        self.removePasteSpan(gpa, span);
        return;
    }
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
    cache.projection = projectVisualRows(self, width, self.first_visible_row, &cache.rows);
    self.first_visible_row = cache.projection.first_visible_row;
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

fn projectVisualRows(
    composer: *const Composer,
    width: u16,
    requested_first_visible_row: usize,
    out: *[visible_rows_max]VisualRow,
) Projection {
    std.debug.assert(composer.cursor_byte_index <= composer.text().len);
    const cursor = composer.cursorPosition(width);
    const visible_count = @min(cursor.total_rows, visible_rows_max);
    var first_visible_row = @min(requested_first_visible_row, cursor.total_rows - visible_count);
    if (cursor.row < first_visible_row) {
        first_visible_row = cursor.row;
    } else if (cursor.row >= first_visible_row + visible_count) {
        first_visible_row = cursor.row - visible_count + 1;
    }
    first_visible_row = @min(first_visible_row, cursor.total_rows - visible_count);
    fillVisibleRows(composer.text(), width, first_visible_row, visible_count, out);
    return .{
        .first_visible_row = first_visible_row,
        .visible_count = visible_count,
        .total_rows = cursor.total_rows,
        .cursor_visible = true,
        .cursor_visible_row = cursor.row - first_visible_row,
        .cursor_display_col = cursor.col,
    };
}

fn fillVisibleRows(
    bytes: []const u8,
    width: u16,
    first_visible_row: usize,
    visible_count: usize,
    out: *[visible_rows_max]VisualRow,
) void {
    if (visible_count == 0) return;
    if (bytes.len == 0) {
        out[0] = .{ .text = "" };
        return;
    }

    const wrap_width = @max(width, 1);
    var row: usize = 0;
    var written: usize = 0;
    var start: usize = 0;
    while (start < bytes.len and written < visible_count) {
        const line = text_mod.nextVisualLineBreak(bytes, start, wrap_width);
        if (line.next == start) break;
        if (row >= first_visible_row) {
            out[written] = .{ .text = bytes[line.start..line.end] };
            written += 1;
        }
        row += 1;
        start = line.next;
    }
    if (bytes[bytes.len - 1] == '\n' and written < visible_count and row >= first_visible_row) {
        out[written] = .{ .text = "" };
        written += 1;
    }
    std.debug.assert(written == visible_count);
}

test "insert normalizes CRLF and moves the cursor" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    try std.testing.expectEqual(InsertResult.ok, try composer.insert(gpa, "a\r\nb\rc"));
    try std.testing.expectEqualStrings("a\nb\nc", composer.text());
    try std.testing.expectEqual(composer.text().len, composer.cursor_byte_index);
}

test "insert fills the byte cap before rejecting overflow" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    const almost_big = try gpa.alloc(u8, buffer_size_bytes_max - 1);
    defer gpa.free(almost_big);
    @memset(almost_big, 'x');
    try std.testing.expectEqual(InsertResult.ok, try composer.insert(gpa, almost_big));
    try std.testing.expectEqual(InsertResult.inserted_truncated, try composer.insert(gpa, "yz"));
    try std.testing.expectEqual(buffer_size_bytes_max, composer.text().len);
    try std.testing.expectEqual('y', composer.text()[composer.text().len - 1]);
    try std.testing.expectEqual(InsertResult.rejected_full, try composer.insert(gpa, "z"));
}

test "deleteForward removes the grapheme under the cursor" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insert(gpa, "ab");
    composer.moveStart();
    composer.deleteForward(gpa);
    try std.testing.expectEqualStrings("b", composer.text());
}

test "backspace removes a paste marker and its stored payload" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insertPaste(gpa, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11");
    try std.testing.expectEqualStrings("[paste #1 +11 lines]", composer.text());
    try std.testing.expectEqual(@as(usize, 1), composer.pastes.items.len);

    composer.backspace(gpa);

    try std.testing.expectEqualStrings("", composer.text());
    try std.testing.expectEqual(@as(usize, 0), composer.pastes.items.len);
}

test "deleteForward removes a paste marker and its stored payload" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insertPaste(gpa, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11");
    composer.moveStart();
    composer.deleteForward(gpa);

    try std.testing.expectEqualStrings("", composer.text());
    try std.testing.expectEqual(@as(usize, 0), composer.pastes.items.len);
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

    composer.backspace(gpa);
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

test "visible rows scroll only when cursor leaves the composer window" {
    const gpa = std.testing.allocator;
    var composer: Composer = .{};
    defer composer.deinit(gpa);

    _ = try composer.insert(gpa, "a\nb\nc\nd\ne\nf");
    var rows: [visible_rows_max]VisualRow = undefined;
    var projection = composer.visibleRows(10, &rows);
    try std.testing.expectEqual(@as(usize, 2), projection.first_visible_row);
    try std.testing.expectEqualStrings("c", rows[0].text);
    try std.testing.expectEqualStrings("f", rows[3].text);
    try std.testing.expectEqual(@as(usize, 3), projection.cursor_visible_row);

    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(10, .up));
    projection = composer.visibleRows(10, &rows);
    try std.testing.expectEqual(@as(usize, 2), projection.first_visible_row);
    try std.testing.expectEqual(@as(usize, 2), projection.cursor_visible_row);

    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(10, .up));
    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(10, .up));
    projection = composer.visibleRows(10, &rows);
    try std.testing.expectEqual(@as(usize, 2), projection.first_visible_row);
    try std.testing.expectEqual(@as(usize, 0), projection.cursor_visible_row);

    try std.testing.expectEqual(MoveVerticalResult.moved, composer.moveVertical(10, .up));
    projection = composer.visibleRows(10, &rows);
    try std.testing.expectEqual(@as(usize, 1), projection.first_visible_row);
    try std.testing.expectEqualStrings("b", rows[0].text);
    try std.testing.expectEqual(@as(usize, 0), projection.cursor_visible_row);
}
