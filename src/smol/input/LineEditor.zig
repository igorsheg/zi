const std = @import("std");
const Text = @import("../../terminal_render/root.zig").Text;

const LineEditor = @This();

pub const Error = error{
    OutOfMemory,
    InputTooLarge,
};

allocator: std.mem.Allocator,
bytes: std.ArrayList(u8) = .empty,
cursor: usize = 0,
max_bytes: usize,

pub fn init(allocator: std.mem.Allocator, max_bytes: usize) LineEditor {
    return .{ .allocator = allocator, .max_bytes = max_bytes };
}

pub fn deinit(self: *LineEditor) void {
    self.bytes.deinit(self.allocator);
    self.* = undefined;
}

pub fn text(self: *const LineEditor) []const u8 {
    return self.bytes.items;
}

pub fn cursorByte(self: *const LineEditor) usize {
    return self.cursor;
}

pub fn isEmpty(self: *const LineEditor) bool {
    return self.bytes.items.len == 0;
}

pub fn insertByte(self: *LineEditor, byte: u8) Error!void {
    if (self.bytes.items.len >= self.max_bytes) return error.InputTooLarge;
    try self.bytes.insert(self.allocator, self.cursor, byte);
    self.cursor += 1;
}

pub fn moveLeft(self: *LineEditor) void {
    self.cursor = Text.previousBoundary(self.bytes.items, self.cursor);
}

pub fn moveRight(self: *LineEditor) void {
    self.cursor = Text.nextBoundary(self.bytes.items, self.cursor);
}

pub fn moveHome(self: *LineEditor) void {
    self.cursor = 0;
}

pub fn moveEnd(self: *LineEditor) void {
    self.cursor = self.bytes.items.len;
}

pub fn deleteBackward(self: *LineEditor) void {
    if (self.cursor == 0) return;
    const end = self.cursor;
    self.cursor = Text.previousBoundary(self.bytes.items, self.cursor);
    self.deleteRange(self.cursor, end);
}

pub fn deleteForward(self: *LineEditor) void {
    if (self.cursor >= self.bytes.items.len) return;
    const start = self.cursor;
    const end = Text.nextBoundary(self.bytes.items, self.cursor);
    self.deleteRange(start, end);
}

pub fn clear(self: *LineEditor) void {
    self.bytes.clearRetainingCapacity();
    self.cursor = 0;
}

pub fn replace(self: *LineEditor, replacement: []const u8) Error!void {
    if (replacement.len > self.max_bytes) return error.InputTooLarge;
    try self.bytes.ensureTotalCapacity(self.allocator, replacement.len);
    self.bytes.clearRetainingCapacity();
    self.bytes.appendSliceAssumeCapacity(replacement);
    self.cursor = replacement.len;
}

pub fn validUtf8(self: *const LineEditor) bool {
    return std.unicode.utf8ValidateSlice(self.bytes.items);
}

fn deleteRange(self: *LineEditor, start: usize, end: usize) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= self.bytes.items.len);
    const moved_len = self.bytes.items.len - end;
    @memmove(self.bytes.items[start..][0..moved_len], self.bytes.items[end..]);
    self.bytes.items.len -= end - start;
}

test "line editor moves and deletes combining sequences as graphemes" {
    const combined = "e\u{301}";
    var editor = LineEditor.init(std.testing.allocator, 32);
    defer editor.deinit();
    try editor.replace("a" ++ combined ++ "z");

    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1 + combined.len), editor.cursorByte());
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.cursorByte());
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 1 + combined.len), editor.cursorByte());
    editor.deleteBackward();
    try std.testing.expectEqualStrings("az", editor.text());

    try editor.replace("a" ++ combined ++ "z");
    editor.moveHome();
    editor.moveRight();
    editor.deleteForward();
    try std.testing.expectEqualStrings("az", editor.text());
}

test "line editor moves and deletes emoji ZWJ families as graphemes" {
    const family = "👨‍👩‍👧‍👦";
    var editor = LineEditor.init(std.testing.allocator, 64);
    defer editor.deinit();
    try editor.replace("a" ++ family ++ "z");

    editor.moveHome();
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 1), editor.cursorByte());
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 1 + family.len), editor.cursorByte());
    editor.deleteBackward();
    try std.testing.expectEqualStrings("az", editor.text());
}

test "line editor moves and deletes regional-indicator flags as graphemes" {
    const flag = "🇺🇦";
    var editor = LineEditor.init(std.testing.allocator, 32);
    defer editor.deinit();
    try editor.replace("a" ++ flag ++ "z");

    editor.moveHome();
    editor.moveRight();
    editor.deleteForward();
    try std.testing.expectEqualStrings("az", editor.text());
}

test "line editor preserves byte editing for partial invalid UTF-8" {
    var editor = LineEditor.init(std.testing.allocator, 8);
    defer editor.deinit();
    for ([_]u8{ 'a', 0xf0, 0x9f, 'z' }) |byte| try editor.insertByte(byte);
    try std.testing.expect(!editor.validUtf8());

    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 3), editor.cursorByte());
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 2), editor.cursorByte());
    editor.deleteBackward();
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0x9f, 'z' }, editor.text());

    editor.moveHome();
    editor.moveRight();
    editor.deleteForward();
    try std.testing.expectEqualStrings("az", editor.text());
}

test "line editor replacement is transactional at its bound" {
    var editor = LineEditor.init(std.testing.allocator, 4);
    defer editor.deinit();
    try editor.replace("keep");
    try std.testing.expectError(error.InputTooLarge, editor.replace("larger"));
    try std.testing.expectEqualStrings("keep", editor.text());
    try std.testing.expectError(error.InputTooLarge, editor.insertByte('!'));
    try std.testing.expectEqualStrings("keep", editor.text());
}
