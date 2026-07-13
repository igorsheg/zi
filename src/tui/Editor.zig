const std = @import("std");
const vaxis = @import("vaxis");

pub const capacity = 4096;
pub const expanded_capacity = 128 * 1024;
pub const history_capacity = 100;
pub const undo_capacity = 32;
pub const kill_ring_capacity = 8;
pub const paste_marker_capacity = 16;
pub const paste_marker_threshold_chars = 1000;
pub const paste_marker_threshold_lines = 10;

allocator: ?std.mem.Allocator = null,
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
next_paste_id: MarkerId = 1,
last_was_kill: bool = false,

const Editor = @This();

pub const Error = error{ EditorFull, InvalidUtf8, PasteTooLarge, OutOfMemory };

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

pub const MarkerId = u32;

const PasteMarker = struct {
    id: MarkerId = 0,
    marker: Snapshot = .{},
    inline_text: Snapshot = .{},
    owned_text: ?[]u8 = null,

    fn text(self: *const PasteMarker) []const u8 {
        if (self.owned_text) |text_value| return text_value;
        return self.inline_text.text();
    }

    fn setText(self: *PasteMarker, allocator: ?std.mem.Allocator, value: []const u8) Error!void {
        if (value.len <= capacity) {
            try self.inline_text.set(value, value.len);
            return;
        }
        const gpa = allocator orelse return error.PasteTooLarge;
        self.owned_text = try gpa.dupe(u8, value);
    }

    fn deinit(self: *PasteMarker, allocator: ?std.mem.Allocator) void {
        if (self.owned_text) |text_value| allocator.?.free(text_value);
        self.* = .{};
    }
};

pub const Token = struct { start: usize, end: usize, text: []const u8 };

pub fn init(self: *Editor, allocator: std.mem.Allocator) void {
    std.debug.assert(self.allocator == null);
    self.allocator = allocator;
}

pub fn deinit(self: *Editor) void {
    while (self.paste_marker_len > 0) {
        self.paste_marker_len -= 1;
        self.paste_markers[self.paste_marker_len].deinit(self.allocator);
    }
    self.* = undefined;
}

pub fn text(self: *const Editor) []const u8 {
    return self.buffer[0..self.len];
}

pub fn cursorByte(self: *const Editor) usize {
    return self.cursor;
}

pub fn moveCursorTo(self: *Editor, byte: usize) bool {
    if (byte > self.len or !std.unicode.utf8ValidateSlice(self.buffer[0..byte])) return false;
    for (self.paste_markers[0..self.paste_marker_len]) |*marker| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, self.text(), start, marker.marker.text())) |found| {
            const end = found + marker.marker.len;
            if (byte > found and byte < end) return false;
            start = end;
        }
    }
    self.cursor = byte;
    return true;
}

pub fn insert(self: *Editor, bytes: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (bytes.len > capacity - self.len) return error.EditorFull;
    try self.recordUndo();
    try self.insertRaw(bytes);
    self.history_index = null;
    self.last_was_kill = false;
}

pub fn insertPaste(self: *Editor, bytes: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (shouldCollapsePaste(bytes)) return self.insertPasteMarker(bytes);
    return self.insert(bytes);
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

pub fn markerPosition(self: *const Editor, marker_id: MarkerId) ?usize {
    const marker = self.markerById(marker_id) orelse return null;
    return std.mem.indexOf(u8, self.text(), marker.marker.text());
}

/// Search all bounded editor replay surfaces for an owned marker.
pub fn containsMarkerInReplay(self: *const Editor, marker_id: MarkerId) bool {
    const marker = self.markerById(marker_id) orelse return false;
    const marker_text = marker.marker.text();
    if (std.mem.indexOf(u8, self.text(), marker_text) != null) return true;
    for (self.undo[0..self.undo_len]) |snapshot| {
        if (std.mem.indexOf(u8, snapshot.text(), marker_text) != null) return true;
    }
    for (self.history[0..self.history_len]) |snapshot| {
        if (std.mem.indexOf(u8, snapshot.text(), marker_text) != null) return true;
    }
    if (std.mem.indexOf(u8, self.draft.text(), marker_text) != null) return true;
    for (self.kill_ring[0..self.kill_len]) |snapshot| {
        if (std.mem.indexOf(u8, snapshot.text(), marker_text) != null) return true;
    }
    return false;
}

/// Remove an owned marker from every bounded replay surface while retaining
/// its definition so an external owner can later restore a captured draft.
pub fn discardMarkerReplay(self: *Editor, marker_id: MarkerId) void {
    const marker = self.markerById(marker_id) orelse return;
    const marker_text = marker.marker.text();
    removeAll(self.buffer[0..], &self.len, &self.cursor, marker_text);
    for (self.undo[0..self.undo_len]) |*snapshot| removeAllFromSnapshot(snapshot, marker_text);
    for (self.history[0..self.history_len]) |*snapshot| removeAllFromSnapshot(snapshot, marker_text);
    removeAllFromSnapshot(&self.draft, marker_text);
    for (self.kill_ring[0..self.kill_len]) |*snapshot| removeAllFromSnapshot(snapshot, marker_text);
    self.history_index = null;
    self.last_was_kill = false;
}

/// Remove an owned marker from replay state and release its definition.
pub fn forgetMarker(self: *Editor, marker_id: MarkerId) void {
    const marker_index = self.markerIndexById(marker_id) orelse return;
    self.discardMarkerReplay(marker_id);
    const last = self.paste_marker_len - 1;
    var removed = self.paste_markers[marker_index];
    if (marker_index != last) self.paste_markers[marker_index] = self.paste_markers[last];
    self.paste_marker_len -= 1;
    removed.deinit(self.allocator);
    self.history_index = null;
    self.last_was_kill = false;
}

pub fn commitSubmission(self: *Editor) void {
    self.len = 0;
    self.cursor = 0;
    self.undo_len = 0;
    self.draft.len = 0;
    self.history_index = null;
    self.last_was_kill = false;
    self.collectUnusedMarkers();
}

pub fn expandedTextLength(self: *const Editor) usize {
    var written: usize = 0;
    var index: usize = 0;
    while (index < self.len) {
        if (self.markerAt(index)) |marker| {
            written += marker.text().len;
            index += marker.marker.len;
        } else {
            written += 1;
            index += 1;
        }
    }
    return written;
}

pub fn allocExpandedText(self: *const Editor, allocator: std.mem.Allocator) ![]u8 {
    const out = try allocator.alloc(u8, self.expandedTextLength());
    errdefer allocator.free(out);
    const expanded = try self.expandedText(out);
    std.debug.assert(expanded.len == out.len);
    return out;
}

pub fn expandedText(self: *const Editor, out: []u8) Error![]const u8 {
    var written: usize = 0;
    var index: usize = 0;
    while (index < self.len) {
        if (self.markerAt(index)) |marker| {
            const expansion = marker.text();
            if (expansion.len > out.len - written) return error.EditorFull;
            @memcpy(out[written..][0..expansion.len], expansion);
            written += expansion.len;
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
    if (self.history_len == history_capacity) self.evictOldestHistory();
    self.history[self.history_len].set(text_value, text_value.len) catch return;
    self.history_len += 1;
    self.collectUnusedMarkers();
}

pub fn clearHistory(self: *Editor) void {
    self.history_len = 0;
    self.history_index = null;
    self.draft.len = 0;
    self.collectUnusedMarkers();
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

pub fn lineByteOffset(self: *const Editor, line_index: usize) usize {
    var current: usize = 0;
    var start: usize = 0;
    while (current < line_index) : (current += 1) {
        const next = std.mem.indexOfScalarPos(u8, self.text(), start, '\n') orelse return self.len;
        start = next + 1;
    }
    return start;
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
    return self.replaceRange(token.start, token.end, replacement, replacement.len);
}

pub fn replaceRange(
    self: *Editor,
    start: usize,
    end: usize,
    replacement: []const u8,
    cursor_offset: usize,
) Error!void {
    if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
    if (start > end or end > self.len or cursor_offset > replacement.len) return error.InvalidUtf8;
    if (!std.unicode.utf8ValidateSlice(replacement[0..cursor_offset])) return error.InvalidUtf8;
    if (self.len - (end - start) + replacement.len > capacity) return error.EditorFull;
    try self.recordUndo();
    self.deleteRange(start, end);
    self.cursor = start;
    try self.insertRaw(replacement);
    self.cursor = start + cursor_offset;
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

pub fn cursorUnitEnd(self: *const Editor, byte: usize) usize {
    if (byte >= self.len) return self.len;
    if (self.markerAt(byte)) |marker| return byte + marker.marker.len;
    return self.nextGraphemeEnd(byte);
}

pub fn insertPasteMarker(self: *Editor, bytes: []const u8) Error!void {
    var marker_text: [64]u8 = undefined;
    const line_count = countLines(bytes);
    const marker = if (line_count > paste_marker_threshold_lines)
        std.fmt.bufPrint(&marker_text, "[paste #{d} +{d} lines]", .{ self.next_paste_id, line_count }) catch return error.EditorFull
    else
        std.fmt.bufPrint(&marker_text, "[paste #{d} {d} chars]", .{ self.next_paste_id, countCodepoints(bytes) }) catch return error.EditorFull;
    _ = try self.insertMarker(marker, bytes);
}

pub fn insertMarker(self: *Editor, marker: []const u8, expansion: []const u8) Error!MarkerId {
    if (!std.unicode.utf8ValidateSlice(marker)) return error.InvalidUtf8;
    if (!std.unicode.utf8ValidateSlice(expansion)) return error.InvalidUtf8;
    if (marker.len == 0) return error.InvalidUtf8;
    self.collectUnusedMarkers();
    while (self.paste_marker_len == paste_marker_capacity and self.history_len > 0) self.evictOldestHistory();
    if (self.paste_marker_len == paste_marker_capacity or marker.len > capacity - self.len) return error.EditorFull;
    const current_expanded_len = self.expandedTextLength();
    if (expansion.len > expanded_capacity -| current_expanded_len) return error.PasteTooLarge;

    const marker_id = self.next_paste_id;
    const slot = &self.paste_markers[self.paste_marker_len];
    slot.* = .{ .id = marker_id };
    errdefer slot.deinit(self.allocator);
    try slot.marker.set(marker, marker.len);
    try slot.setText(self.allocator, expansion);
    try self.recordUndo();
    try self.insertRaw(marker);
    self.paste_marker_len += 1;
    self.next_paste_id +%= 1;
    self.history_index = null;
    self.last_was_kill = false;
    return marker_id;
}

fn markerIndexById(self: *const Editor, marker_id: MarkerId) ?usize {
    for (self.paste_markers[0..self.paste_marker_len], 0..) |marker, index| {
        if (marker.id == marker_id) return index;
    }
    return null;
}

fn markerById(self: *const Editor, marker_id: MarkerId) ?*const PasteMarker {
    const index = self.markerIndexById(marker_id) orelse return null;
    return &self.paste_markers[index];
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

fn removeAllFromSnapshot(snapshot: *Snapshot, needle: []const u8) void {
    removeAll(snapshot.buffer[0..], &snapshot.len, &snapshot.cursor, needle);
}

fn removeAll(buffer: []u8, len: *usize, cursor: *usize, needle: []const u8) void {
    var search_from: usize = 0;
    while (std.mem.findPos(u8, buffer[0..len.*], search_from, needle)) |start| {
        const end = start + needle.len;
        @memmove(buffer[start .. len.* - needle.len], buffer[end..len.*]);
        len.* -= needle.len;
        if (cursor.* >= end) {
            cursor.* -= needle.len;
        } else if (cursor.* > start) {
            cursor.* = start;
        }
        search_from = start;
    }
}

fn shouldCollapsePaste(bytes: []const u8) bool {
    return bytes.len > paste_marker_threshold_chars or countLines(bytes) > paste_marker_threshold_lines;
}

fn countCodepoints(bytes: []const u8) usize {
    return std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
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

fn evictOldestHistory(self: *Editor) void {
    std.debug.assert(self.history_len > 0);
    std.mem.copyForwards(Snapshot, self.history[0 .. self.history_len - 1], self.history[1..self.history_len]);
    self.history_len -= 1;
    self.history_index = null;
    self.collectUnusedMarkers();
}

fn collectUnusedMarkers(self: *Editor) void {
    var index: usize = 0;
    while (index < self.paste_marker_len) {
        const marker_id = self.paste_markers[index].id;
        if (self.containsMarkerInReplay(marker_id)) {
            index += 1;
            continue;
        }
        const last = self.paste_marker_len - 1;
        var removed = self.paste_markers[index];
        if (index != last) self.paste_markers[index] = self.paste_markers[last];
        self.paste_marker_len -= 1;
        removed.deinit(self.allocator);
    }
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
    try editor.insertPaste(paste);
    try std.testing.expect(std.mem.startsWith(u8, editor.text(), "[paste #1 +13 lines]"));
    var out: [capacity]u8 = undefined;
    const expanded = try editor.expandedText(&out);
    try std.testing.expectEqualStrings(paste, expanded);
}

test "editor owns and expands paste larger than visible capacity" {
    var editor: Editor = .{};
    editor.init(std.testing.allocator);
    defer editor.deinit();

    const paste = try std.testing.allocator.alloc(u8, 17 * 1024);
    defer std.testing.allocator.free(paste);
    @memset(paste, 'x');
    try editor.insertPaste(paste);
    try std.testing.expect(std.mem.startsWith(u8, editor.text(), "[paste #1 17408 chars]"));

    const expanded = try editor.allocExpandedText(std.testing.allocator);
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualSlices(u8, paste, expanded);

    editor.pushHistory(editor.text());
    editor.commitSubmission();
    try std.testing.expect(editor.historyPrev());
    const recalled = try editor.allocExpandedText(std.testing.allocator);
    defer std.testing.allocator.free(recalled);
    try std.testing.expectEqualSlices(u8, paste, recalled);
}

test "editor rejects paste beyond expanded bound transactionally" {
    var editor: Editor = .{};
    editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.insert("draft");

    const paste = try std.testing.allocator.alloc(u8, expanded_capacity + 1);
    defer std.testing.allocator.free(paste);
    @memset(paste, 'x');
    try std.testing.expectError(error.PasteTooLarge, editor.insertPaste(paste));
    try std.testing.expectEqualStrings("draft", editor.text());
}

test "editor inserts forced marker with neutral expansion" {
    var editor: Editor = .{};
    _ = try editor.insertMarker("[Image #1]", "[Image #1]");
    try std.testing.expectEqualStrings("[Image #1]", editor.text());
    var out: [capacity]u8 = undefined;
    const expanded = try editor.expandedText(&out);
    try std.testing.expectEqualStrings("[Image #1]", expanded);
}

test "editor forgets a semantic marker from replay state" {
    var editor: Editor = .{};
    try editor.insert("before ");
    const marker_id = try editor.insertMarker("[Image #1]", "[Image #1]");
    editor.pushHistory(editor.text());
    try std.testing.expect(editor.backspace());
    try std.testing.expect(editor.undoLast());

    editor.discardMarkerReplay(marker_id);
    try std.testing.expectEqualStrings("before ", editor.text());
    editor.pushHistory("[Image #1]");
    try std.testing.expect(editor.historyPrev());
    try std.testing.expectEqualStrings("[Image #1]", editor.text());

    editor.forgetMarker(marker_id);
    try std.testing.expectEqualStrings("", editor.text());
    while (editor.undoLast()) try std.testing.expect(std.mem.indexOf(u8, editor.text(), "[Image #1]") == null);
}

test "editor treats paste marker as one cursor unit" {
    var editor: Editor = .{};
    const paste = "line\n" ** 12;
    try editor.insertPaste(paste);
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

test "editor range replacement sets cursor inside quoted completion" {
    var editor: Editor = .{};
    try editor.insert("see @my later");
    try editor.replaceRange(4, 7, "@\"my folder/\"", 12);
    try std.testing.expectEqualStrings("see @\"my folder/\" later", editor.text());
    try std.testing.expectEqual(@as(usize, 16), editor.cursorByte());
}
