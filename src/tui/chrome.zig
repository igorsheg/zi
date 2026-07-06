const std = @import("std");
const Editor = @import("Editor.zig");
const screen = @import("screen.zig");

pub const prompt = "> ";

pub const Snapshot = struct {
    status: []const u8 = "zi",
    scratch_text: []const u8 = "",
    editor: *const Editor,
};

pub fn compose(snapshot: Snapshot, width: u16, height: u16) error{ FrameFull, LineFull }!screen.Frame {
    var frame: screen.Frame = .{};
    if (height == 0) return frame;
    if (height == 1) {
        try appendEditorLine(&frame, snapshot.editor, 0, width);
        return frame;
    }

    try frame.appendLine(screen.singleSpanLine(snapshot.status, screen.styles.muted));
    var row: u16 = 1;
    if (snapshot.scratch_text.len > 0 and row + 1 < height) {
        try frame.appendLine(screen.singleSpanLine(tailLine(snapshot.scratch_text), screen.styles.normal));
        row += 1;
    }
    while (row + 1 < height) : (row += 1) {
        try frame.appendLine(.{});
    }
    try appendEditorLine(&frame, snapshot.editor, height - 1, width);
    return frame;
}

fn tailLine(text: []const u8) []const u8 {
    if (text.len <= 80) return text;
    return text[text.len - 80 ..];
}

fn appendEditorLine(frame: *screen.Frame, editor: *const Editor, row: u16, width: u16) error{ FrameFull, LineFull }!void {
    var line: screen.Line = .{};
    try line.append(.{ .text = prompt, .style = screen.styles.accent });
    try line.append(.{ .text = editor.text() });
    try frame.appendLine(line);

    const raw_col = prompt.len + editor.cursorByte();
    const max_col: usize = if (width == 0) 0 else width - 1;
    frame.cursor = .{ .col = @intCast(@min(raw_col, max_col)), .row = row };
}

test "chrome composes status and editor rows" {
    var editor: Editor = .{};
    try editor.insert("hello");
    var frame = try compose(.{ .status = "ready", .editor = &editor }, 80, 3);

    try std.testing.expectEqual(@as(usize, 3), frame.rows().len);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ready", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("> hello", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 7), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor.?.row);
}

test "chrome renders scratch flood tail above editor" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const frame = try compose(.{ .status = "ready", .scratch_text = "streaming", .editor = &editor }, 80, 4);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ready", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("streaming", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("> draft", frame.rows()[3].copyText(&buffer));
}

test "chrome clamps cursor to frame width" {
    var editor: Editor = .{};
    try editor.insert("hello");
    const frame = try compose(.{ .editor = &editor }, 4, 1);

    try std.testing.expectEqual(@as(u16, 3), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 0), frame.cursor.?.row);
}
