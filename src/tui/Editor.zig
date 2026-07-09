const std = @import("std");
const vaxis = @import("vaxis");

pub const capacity = 4096;
pub const history_capacity = 100;
pub const undo_capacity = 32;
pub const kill_ring_capacity = 8;
pub const paste_marker_capacity = 16;
pub const paste_marker_threshold_chars = 1000;
pub const paste_marker_threshold_lines = 10;

buffer: [capacity]u8 = undefined,
len: usize = 0,
cursor: usize = 0,
undo: [undo_capacity]Snapshot = undefined,
undo_len: usize = 0,
history: [history_capacity]Snapshot = undefined,
history_len: usize = 0,
history_index: ?usize = null,
draft: Snapshot = .{},
kill_ring: [kill_ring_capacity]Snapshot = undefined,
kill_len: usize = 0,
paste_markers: [paste_marker_capacity]PasteMarker = undefined,
paste_marker_len: usize = 0,
next_paste_id: u32 = 1,
last_was_kill: bool = false,

const Editor = @This();

pub const Error = error{ EditorFull, InvalidUtf8 };

const Snapshot = struct {
    buffer: [capacity]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    fn set(self: *Snapshot, value: []const u8, cursor: usize) Error!void {
        if (value.len > capacity) return error.EditorFull;
        @memcpy(self.buffer[0..value.len], value);
        self.len = value.len;
        self.cursor = @min(cursor, value.len);
    }

    fn text(self: *const Snapshot) []const u8 {
        return self.buffer[0..self.len];
    }
};

const PasteMarker = struct {
    id: u32 = 0,
    marker: Snapshot = .{},
    text: Snapshot = .{},
};

pub const Token = struct { start: usize, end: usize, text: []const u8 };

pub fn text(self: *const Editor) []const u8 {
    return self.buffer[0..self.len];
}

pub fn cursorByte(self: *const Editor) usize {
    return self.cursor;
}

pub fn insert(self: *Editor, bytes: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (shouldCollapsePaste(bytes)) return self.insertPasteMarker(bytes);
    try self.recordUndo();
    try self.insertRaw(bytes);
    self.history_index = null;
    self.last_was_kill = false;
}

pub fn insertNewline(self: *Editor) Error!void {
    try self.insert("\n");
}

pub fn moveLeft(self: *Editor) bool {
    if (self.cursor == 0) return false;
    if (self.markerStartEndingAt(self.cursor)) |start| {
        self.cursor = start;
        return true;
    }
    self.cursor = self.prevGraphemeStart(self.cursor);
    return true;
}

pub fn moveRight(self: *Editor) bool {
    if (self.cursor == self.len) return false;
    if (self.markerAt(self.cursor)) |marker| {
        self.cursor += marker.marker.len;
        return true;
    }
    self.cursor = self.nextGraphemeEnd(self.cursor);
    return true;
}

pub fn moveWordLeft(self: *Editor) bool {
    if (self.cursor == 0) return false;
    var index = self.cursor;
    while (index > 0 and isSpace(self.buffer[self.prevScalarStart(index)])) index = self.prevScalarStart(index);
    while (index > 0 and !isSpace(self.buffer[self.prevScalarStart(index)])) index = self.prevScalarStart(index);
    self.cursor = index;
    return true;
}

pub fn moveWordRight(self: *Editor) bool {
    if (self.cursor == self.len) return false;
    var index = self.cursor;
    while (index < self.len and !isSpace(self.buffer[index])) index = self.nextScalarEnd(index);
    while (index < self.len and isSpace(self.buffer[index])) index = self.nextScalarEnd(index);
    self.cursor = index;
    return true;
}

pub fn moveHome(self: *Editor) void {
    self.cursor = self.lineStart(self.cursor);
}

pub fn moveEnd(self: *Editor) void {
    self.cursor = self.lineEnd(self.cursor);
}

pub fn moveBufferStart(self: *Editor) void {
    self.cursor = 0;
}

pub fn moveBufferEnd(self: *Editor) void {
    self.cursor = self.len;
}

pub fn backspace(self: *Editor) bool {
    if (self.cursor == 0) return false;
    const start = self.markerStartEndingAt(self.cursor) orelse self.prevGraphemeStart(self.cursor);
    self.recordUndo() catch return false;
    self.deleteRange(start, self.cursor);
    self.cursor = start;
    self.history_index = null;
    self.last_was_kill = false;
    return true;
}

pub fn deleteForward(self: *Editor) bool {
    if (self.cursor == self.len) return false;
    const end = if (self.markerAt(self.cursor)) |marker| self.cursor + marker.marker.len else self.nextGraphemeEnd(self.cursor);
    self.recordUndo() catch return false;
    self.deleteRange(self.cursor, end);
    self.history_index = null;
    self.last_was_kill = false;
    return true;
}

pub fn killToEnd(self: *Editor) bool {
    var end = self.lineEnd(self.cursor);
    if (end == self.cursor and end < self.len and self.buffer[end] == '\n') end += 1;
    if (end == self.cursor) return false;
    return self.killRange(self.cursor, end);
}

pub fn killToStart(self: *Editor) bool {
    const start = self.lineStart(self.cursor);
    if (start == self.cursor) return false;
    return self.killRange(start, self.cursor);
}

pub fn killWordBack(self: *Editor) bool {
    if (self.cursor == 0) return false;
    var start = self.cursor;
    while (start > 0 and isSpace(self.buffer[self.prevScalarStart(start)])) start = self.prevScalarStart(start);
    while (start > 0 and !isSpace(self.buffer[self.prevScalarStart(start)])) start = self.prevScalarStart(start);
    if (start == self.cursor) return false;
    return self.killRange(start, self.cursor);
}

pub fn yank(self: *Editor) Error!void {
    if (self.kill_len == 0) return;
    try self.insert(self.kill_ring[self.kill_len - 1].text());
}

pub fn undoLast(self: *Editor) bool {
    if (self.undo_len == 0) return false;
    const snap = self.undo[self.undo_len - 1];
    self.undo_len -= 1;
    @memcpy(self.buffer[0..snap.len], snap.text());
    self.len = snap.len;
    self.cursor = snap.cursor;
    self.history_index = null;
    self.last_was_kill = false;
    return true;
}

pub fn clear(self: *Editor) void {
    self.len = 0;
    self.cursor = 0;
    self.history_index = null;
    self.last_was_kill = false;
}

pub fn expandedText(self: *const Editor, out: []u8) Error![]const u8 {
    var written: usize = 0;
    var index: usize = 0;
    while (index < self.len) {
        if (self.markerAt(index)) |marker| {
            if (marker.text.len > out.len - written) return error.EditorFull;
            @memcpy(out[written..][0..marker.text.len], marker.text.text());
            written += marker.text.len;
            index += marker.marker.len;
            continue;
        }
        if (written == out.len) return error.EditorFull;
        out[written] = self.buffer[index];
        written += 1;
        index += 1;
    }
    return out[0..written];
}

pub fn pushHistory(self: *Editor, text_value: []const u8) void {
    if (text_value.len == 0) return;
    if (self.history_len > 0 and std.mem.eql(u8, self.history[self.history_len - 1].text(), text_value)) return;
    if (self.history_len == history_capacity) {
        std.mem.copyForwards(Snapshot, self.history[0 .. history_capacity - 1], self.history[1..history_capacity]);
        self.history_len -= 1;
    }
    self.history[self.history_len].set(text_value, text_value.len) catch return;
    self.history_len += 1;
}

pub fn historyPrev(self: *Editor) bool {
    if (self.history_len == 0) return false;
    if (self.history_index == null) {
        self.draft.set(self.text(), self.cursor) catch return false;
        self.history_index = self.history_len - 1;
    } else if (self.history_index.? > 0) {
        self.history_index.? -= 1;
    }
    self.restoreSnapshot(self.history[self.history_index.?]);
    return true;
}

pub fn historyNext(self: *Editor) bool {
    const index = self.history_index orelse return false;
    if (index + 1 < self.history_len) {
        self.history_index = index + 1;
        self.restoreSnapshot(self.history[self.history_index.?]);
    } else {
        self.history_index = null;
        self.restoreSnapshot(self.draft);
    }
    return true;
}

pub fn lineCount(self: *const Editor) usize {
    if (self.len == 0) return 1;
    var count: usize = 1;
    for (self.text()) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

pub fn lineSlice(self: *const Editor, line_index: usize) []const u8 {
    var current: usize = 0;
    var start: usize = 0;
    while (current < line_index) : (current += 1) {
        const next = std.mem.indexOfScalarPos(u8, self.text(), start, '\n') orelse return "";
        start = next + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, self.text(), start, '\n') orelse self.len;
    return self.buffer[start..end];
}

pub fn cursorLineCol(self: *const Editor) struct { line: usize, col: usize } {
    var line: usize = 0;
    var line_start: usize = 0;
    var index: usize = 0;
    while (index < self.cursor) : (index += 1) {
        if (self.buffer[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    return .{ .line = line, .col = self.cursor - line_start };
}

pub fn currentToken(self: *const Editor) ?Token {
    if (self.cursor > self.len) return null;
    var start = self.cursor;
    while (start > 0 and !isSpace(self.buffer[start - 1])) start -= 1;
    var end = self.cursor;
    while (end < self.len and !isSpace(self.buffer[end])) end += 1;
    if (start == end) return null;
    return .{ .start = start, .end = end, .text = self.buffer[start..end] };
}

pub fn replaceToken(self: *Editor, token: Token, replacement: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
    if (token.start > token.end or token.end > self.len) return error.InvalidUtf8;
    if (self.len - (token.end - token.start) + replacement.len > capacity) return error.EditorFull;
    try self.recordUndo();
    self.deleteRange(token.start, token.end);
    self.cursor = token.start;
    try self.insertRaw(replacement);
    self.history_index = null;
    self.last_was_kill = false;
}

pub fn endsWithBackslash(self: *const Editor) bool {
    return self.len > 0 and self.buffer[self.len - 1] == '\\';
}

pub fn removeTrailingBackslash(self: *Editor) bool {
    if (!self.endsWithBackslash()) return false;
    self.recordUndo() catch return false;
    self.deleteRange(self.len - 1, self.len);
    if (self.cursor > self.len) self.cursor = self.len;
    self.last_was_kill = false;
    return true;
}

pub fn insertPasteMarker(self: *Editor, bytes: []const u8) Error!void {
    var marker_text: [64]u8 = undefined;
    const line_count = countLines(bytes);
    const marker = std.fmt.bufPrint(&marker_text, "[paste #{d} +{d} lines]", .{ self.next_paste_id, line_count }) catch return error.EditorFull;
    try self.insertMarker(marker, bytes);
}

pub fn insertMarker(self: *Editor, marker: []const u8, expansion: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(marker)) return error.InvalidUtf8;
    if (!std.unicode.utf8ValidateSlice(expansion)) return error.InvalidUtf8;
    if (marker.len == 0) return;
    if (self.paste_marker_len == paste_marker_capacity) return error.EditorFull;
    try self.recordUndo();
    const slot = &self.paste_markers[self.paste_marker_len];
    slot.id = self.next_paste_id;
    try slot.marker.set(marker, marker.len);
    try slot.text.set(expansion, expansion.len);
    self.paste_marker_len += 1;
    self.next_paste_id +%= 1;
    try self.insertRaw(marker);
    self.last_was_kill = false;
}

fn markerAt(self: *const Editor, index: usize) ?*const PasteMarker {
    for (self.paste_markers[0..self.paste_marker_len]) |*marker| {
        if (index + marker.marker.len <= self.len and std.mem.eql(u8, self.buffer[index..][0..marker.marker.len], marker.marker.text())) return marker;
    }
    return null;
}

fn markerStartEndingAt(self: *const Editor, index: usize) ?usize {
    for (self.paste_markers[0..self.paste_marker_len]) |*marker| {
        if (index < marker.marker.len) continue;
        const start = index - marker.marker.len;
        if (std.mem.eql(u8, self.buffer[start..index], marker.marker.text())) return start;
    }
    return null;
}

fn shouldCollapsePaste(bytes: []const u8) bool {
    if (bytes.len <= paste_marker_threshold_chars and countLines(bytes) <= paste_marker_threshold_lines) return false;
    return std.mem.indexOfScalar(u8, bytes, '\n') != null;
}

fn countLines(bytes: []const u8) usize {
    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn insertRaw(self: *Editor, bytes: []const u8) Error!void {
    if (bytes.len > capacity - self.len) return error.EditorFull; // bounded policy: reject.
    std.mem.copyBackwards(u8, self.buffer[self.cursor + bytes.len .. self.len + bytes.len], self.buffer[self.cursor..self.len]);
    @memcpy(self.buffer[self.cursor..][0..bytes.len], bytes);
    self.cursor += bytes.len;
    self.len += bytes.len;
}

fn deleteRange(self: *Editor, start: usize, end: usize) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= self.len);
    std.mem.copyForwards(u8, self.buffer[start .. self.len - (end - start)], self.buffer[end..self.len]);
    self.len -= end - start;
}

fn killRange(self: *Editor, start: usize, end: usize) bool {
    self.recordUndo() catch return false;
    self.pushKill(self.buffer[start..end]);
    self.deleteRange(start, end);
    self.cursor = start;
    self.history_index = null;
    self.last_was_kill = true;
    return true;
}

fn pushKill(self: *Editor, killed: []const u8) void {
    if (killed.len == 0) return;
    if (self.last_was_kill and self.kill_len > 0) {
        const last = &self.kill_ring[self.kill_len - 1];
        if (killed.len <= capacity - last.len) {
            @memcpy(last.buffer[last.len..][0..killed.len], killed);
            last.len += killed.len;
            last.cursor = last.len;
            return;
        }
    }
    if (self.kill_len == kill_ring_capacity) {
        std.mem.copyForwards(Snapshot, self.kill_ring[0 .. kill_ring_capacity - 1], self.kill_ring[1..kill_ring_capacity]);
        self.kill_len -= 1;
    }
    self.kill_ring[self.kill_len].set(killed, killed.len) catch return;
    self.kill_len += 1;
}

fn recordUndo(self: *Editor) Error!void {
    if (self.undo_len == undo_capacity) {
        std.mem.copyForwards(Snapshot, self.undo[0 .. undo_capacity - 1], self.undo[1..undo_capacity]);
        self.undo_len -= 1;
    }
    try self.undo[self.undo_len].set(self.text(), self.cursor);
    self.undo_len += 1;
}

fn restoreSnapshot(self: *Editor, snap: Snapshot) void {
    @memcpy(self.buffer[0..snap.len], snap.text());
    self.len = snap.len;
    self.cursor = snap.cursor;
    self.last_was_kill = false;
}

fn lineStart(self: *const Editor, from: usize) usize {
    if (from == 0) return 0;
    var index = from;
    while (index > 0) : (index -= 1) {
        if (self.buffer[index - 1] == '\n') return index;
    }
    return 0;
}

fn lineEnd(self: *const Editor, from: usize) usize {
    var index = from;
    while (index < self.len and self.buffer[index] != '\n') : (index += 1) {}
    return index;
}

fn prevGraphemeStart(self: *const Editor, from: usize) usize {
    var iter = vaxis.unicode.graphemeIterator(self.buffer[0..from]);
    var last: usize = 0;
    while (iter.next()) |grapheme| last = grapheme.start;
    return last;
}

fn nextGraphemeEnd(self: *const Editor, from: usize) usize {
    var iter = vaxis.unicode.graphemeIterator(self.buffer[from..self.len]);
    const grapheme = iter.next() orelse return self.len;
    return from + grapheme.start + grapheme.len;
}

fn prevScalarStart(self: *const Editor, from: usize) usize {
    var index = from - 1;
    while (index > 0 and isContinuationByte(self.buffer[index])) : (index -= 1) {}
    return index;
}

fn nextScalarEnd(self: *const Editor, from: usize) usize {
    var index = from + 1;
    while (index < self.len and isContinuationByte(self.buffer[index])) : (index += 1) {}
    return index;
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

test "editor inserts at cursor and moves by grapheme" {
    var editor: Editor = .{};
    try editor.insert("ab");
    try editor.insert("é");
    try std.testing.expectEqualStrings("abé", editor.text());

    try std.testing.expect(editor.moveLeft());
    try std.testing.expectEqual(@as(usize, 2), editor.cursorByte());
    try editor.insert("c");
    try std.testing.expectEqualStrings("abcé", editor.text());
    try std.testing.expect(editor.moveRight());
    try std.testing.expectEqual(editor.text().len, editor.cursorByte());
}

test "editor deletes previous and next graphemes" {
    var editor: Editor = .{};
    try editor.insert("aéb");
    try std.testing.expect(editor.moveLeft());
    try std.testing.expect(editor.backspace());
    try std.testing.expectEqualStrings("ab", editor.text());
    editor.moveBufferStart();
    try std.testing.expect(editor.deleteForward());
    try std.testing.expectEqualStrings("b", editor.text());
}

test "editor rejects invalid utf8 and overflow" {
    var editor: Editor = .{};
    try std.testing.expectError(error.InvalidUtf8, editor.insert(&.{0xff}));

    try editor.insert(&([1]u8{'x'} ** capacity));
    try std.testing.expectError(error.EditorFull, editor.insert("x"));
    editor.clear();
    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expectEqual(@as(usize, 0), editor.cursorByte());
}

test "editor supports multiline kill yank undo and history" {
    var editor: Editor = .{};
    try editor.insert("one two");
    try std.testing.expect(editor.killWordBack());
    try std.testing.expectEqualStrings("one ", editor.text());
    try editor.yank();
    try std.testing.expectEqualStrings("one two", editor.text());
    try std.testing.expect(editor.undoLast());
    try std.testing.expectEqualStrings("one ", editor.text());

    editor.pushHistory("first");
    editor.pushHistory("second");
    try std.testing.expect(editor.historyPrev());
    try std.testing.expectEqualStrings("second", editor.text());
    try std.testing.expect(editor.historyPrev());
    try std.testing.expectEqualStrings("first", editor.text());
    try std.testing.expect(editor.historyNext());
    try std.testing.expectEqualStrings("second", editor.text());
}

test "editor collapses and expands large paste markers" {
    var editor: Editor = .{};
    const paste = "line\n" ** 12;
    try editor.insert(paste);
    try std.testing.expect(std.mem.startsWith(u8, editor.text(), "[paste #1 +13 lines]"));
    var out: [capacity]u8 = undefined;
    const expanded = try editor.expandedText(&out);
    try std.testing.expectEqualStrings(paste, expanded);
}

test "editor inserts forced marker with hidden expansion" {
    var editor: Editor = .{};
    try editor.insertMarker("[image #1 png 1 KiB]", "@/tmp/zi-clipboard-test.png");
    try std.testing.expectEqualStrings("[image #1 png 1 KiB]", editor.text());
    var out: [capacity]u8 = undefined;
    const expanded = try editor.expandedText(&out);
    try std.testing.expectEqualStrings("@/tmp/zi-clipboard-test.png", expanded);
}

test "editor treats paste marker as one cursor unit" {
    var editor: Editor = .{};
    const paste = "line\n" ** 12;
    try editor.insert(paste);
    const marker_len = editor.text().len;
    try std.testing.expect(editor.moveLeft());
    try std.testing.expectEqual(@as(usize, 0), editor.cursorByte());
    try std.testing.expect(editor.moveRight());
    try std.testing.expectEqual(marker_len, editor.cursorByte());
    try std.testing.expect(editor.backspace());
    try std.testing.expectEqualStrings("", editor.text());
}

test "editor ctrl-k kills newline at eol and coalesces consecutive kills" {
    var editor: Editor = .{};
    try editor.insert("one\ntwo");
    editor.moveBufferStart();
    editor.moveEnd();
    try std.testing.expect(editor.killToEnd());
    try std.testing.expectEqualStrings("onetwo", editor.text());
    try std.testing.expect(editor.killToEnd());
    try std.testing.expectEqualStrings("one", editor.text());
    try editor.yank();
    try std.testing.expectEqualStrings("one\ntwo", editor.text());
}

test "editor exposes lines and cursor position" {
    var editor: Editor = .{};
    try editor.insert("one\ntwo");
    try std.testing.expectEqual(@as(usize, 2), editor.lineCount());
    try std.testing.expectEqualStrings("two", editor.lineSlice(1));
    const cursor = editor.cursorLineCol();
    try std.testing.expectEqual(@as(usize, 1), cursor.line);
    try std.testing.expectEqual(@as(usize, 3), cursor.col);
}

test "editor replaces current token for completion" {
    var editor: Editor = .{};
    try editor.insert("run @sr now");
    _ = editor.moveWordLeft();
    _ = editor.moveWordLeft();
    const token = editor.currentToken().?;
    try std.testing.expectEqualStrings("@sr", token.text);
    try editor.replaceToken(token, "@src/main.zig");
    try std.testing.expectEqualStrings("run @src/main.zig now", editor.text());
}
