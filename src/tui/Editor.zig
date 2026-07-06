const std = @import("std");

pub const capacity = 4096;

buffer: [capacity]u8 = undefined,
len: usize = 0,
cursor: usize = 0,

const Editor = @This();

pub const Error = error{ EditorFull, InvalidUtf8 };

pub fn text(self: *const Editor) []const u8 {
    return self.buffer[0..self.len];
}

pub fn cursorByte(self: *const Editor) usize {
    return self.cursor;
}

pub fn insert(self: *Editor, bytes: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (bytes.len > capacity - self.len) return error.EditorFull; // bounded policy: reject.

    std.mem.copyBackwards(u8, self.buffer[self.cursor + bytes.len .. self.len + bytes.len], self.buffer[self.cursor..self.len]);
    @memcpy(self.buffer[self.cursor..][0..bytes.len], bytes);
    self.cursor += bytes.len;
    self.len += bytes.len;
}

pub fn moveLeft(self: *Editor) bool {
    if (self.cursor == 0) return false;
    self.cursor = self.prevScalarStart(self.cursor);
    return true;
}

pub fn moveRight(self: *Editor) bool {
    if (self.cursor == self.len) return false;
    self.cursor = self.nextScalarEnd(self.cursor);
    return true;
}

pub fn moveHome(self: *Editor) void {
    self.cursor = 0;
}

pub fn moveEnd(self: *Editor) void {
    self.cursor = self.len;
}

pub fn backspace(self: *Editor) bool {
    if (self.cursor == 0) return false;
    const start = self.prevScalarStart(self.cursor);
    self.deleteRange(start, self.cursor);
    self.cursor = start;
    return true;
}

pub fn deleteForward(self: *Editor) bool {
    if (self.cursor == self.len) return false;
    self.deleteRange(self.cursor, self.nextScalarEnd(self.cursor));
    return true;
}

pub fn clear(self: *Editor) void {
    self.len = 0;
    self.cursor = 0;
}

fn deleteRange(self: *Editor, start: usize, end: usize) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= self.len);
    std.mem.copyForwards(u8, self.buffer[start .. self.len - (end - start)], self.buffer[end..self.len]);
    self.len -= end - start;
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

test "editor inserts at cursor and moves by utf8 scalar" {
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

test "editor deletes previous and next scalars" {
    var editor: Editor = .{};
    try editor.insert("aéb");
    try std.testing.expect(editor.moveLeft());
    try std.testing.expect(editor.backspace());
    try std.testing.expectEqualStrings("ab", editor.text());
    editor.moveHome();
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
