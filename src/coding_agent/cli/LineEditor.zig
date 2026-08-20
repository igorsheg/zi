const std = @import("std");

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
    if (self.cursor == 0) return;
    self.cursor -= 1;
    while (self.cursor > 0 and isContinuation(self.bytes.items[self.cursor])) self.cursor -= 1;
}

pub fn moveRight(self: *LineEditor) void {
    if (self.cursor >= self.bytes.items.len) return;
    self.cursor += 1;
    while (self.cursor < self.bytes.items.len and isContinuation(self.bytes.items[self.cursor])) {
        self.cursor += 1;
    }
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
    self.moveLeft();
    self.deleteRange(self.cursor, end);
}

pub fn deleteForward(self: *LineEditor) void {
    if (self.cursor >= self.bytes.items.len) return;
    const start = self.cursor;
    self.moveRight();
    const end = self.cursor;
    self.cursor = start;
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

/// Returns the number of Unicode scalars after the cursor. Renderers use this
/// only for cursor placement; invalid in-progress UTF-8 falls back to bytes.
pub fn suffixScalarCount(self: *const LineEditor) usize {
    const suffix = self.bytes.items[self.cursor..];
    if (!std.unicode.utf8ValidateSlice(suffix)) return suffix.len;
    return std.unicode.utf8CountCodepoints(suffix) catch suffix.len;
}

fn deleteRange(self: *LineEditor, start: usize, end: usize) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= self.bytes.items.len);
    const moved_len = self.bytes.items.len - end;
    @memmove(self.bytes.items[start..][0..moved_len], self.bytes.items[end..]);
    self.bytes.items.len -= end - start;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

test "line editor inserts and deletes at UTF-8 scalar boundaries" {
    var editor = LineEditor.init(std.testing.allocator, 32);
    defer editor.deinit();
    for ("aéz") |byte| try editor.insertByte(byte);
    try std.testing.expect(editor.validUtf8());
    editor.moveLeft();
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), editor.cursorByte());
    try editor.insertByte('!');
    try std.testing.expectEqualStrings("a!éz", editor.text());
    editor.deleteForward();
    try std.testing.expectEqualStrings("a!z", editor.text());
    editor.deleteBackward();
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

test "line editor reports suffix scalar count" {
    var editor = LineEditor.init(std.testing.allocator, 32);
    defer editor.deinit();
    try editor.replace("aéz");
    editor.moveLeft();
    editor.moveLeft();
    try std.testing.expectEqual(@as(usize, 2), editor.suffixScalarCount());
    editor.moveHome();
    try std.testing.expectEqual(@as(usize, 3), editor.suffixScalarCount());
}
