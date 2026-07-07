const std = @import("std");
const Editor = @import("Editor.zig");
const screen = @import("screen.zig");

pub const prompt = "> ";
const border_fill = "-" ** 512;
const border_spaces = " " ** 512;

pub const Snapshot = struct {
    status: []const u8 = "zi",
    scratch_text: []const u8 = "",
    transcript_lines: []const screen.Line = &.{},
    queue_lines: []const []const u8 = &.{},
    viewport_hint: []const u8 = "",
    editor: *const Editor,
    editor_border_style: screen.Style = screen.styles.muted,
};

pub fn compose(snapshot: Snapshot, width: u16, height: u16) error{ FrameFull, LineFull }!screen.Frame {
    var frame: screen.Frame = .{};
    if (height == 0) return frame;
    if (height == 1) {
        try appendEditorLine(&frame, snapshot.editor, 0, 0, width, snapshot.editor_border_style, false);
        return frame;
    }

    try frame.appendLine(screen.singleSpanLine(snapshot.status, screen.styles.muted));
    const editor_rows = editorRows(snapshot.editor, height, width);
    const queue_rows = queueRowCount(snapshot.queue_lines.len, snapshot.viewport_hint.len);
    const transcript_rows = transcriptRowCapacity(snapshot.editor, snapshot.queue_lines.len, snapshot.viewport_hint.len, width, height);

    appendTranscriptTail(&frame, snapshot.transcript_lines, transcript_rows) catch |err| return err;
    if (snapshot.scratch_text.len > 0 and frame.rows().len + queue_rows + editor_rows < height) {
        try frame.appendLine(screen.singleSpanLine(tailLine(snapshot.scratch_text), screen.styles.normal));
    }
    while (frame.rows().len + queue_rows + editor_rows < height) try frame.appendLine(.{});

    var remaining_queue_rows = queue_rows;
    if (snapshot.viewport_hint.len > 0 and remaining_queue_rows > 0) {
        try frame.appendLine(screen.singleSpanLine(snapshot.viewport_hint, screen.styles.muted));
        remaining_queue_rows -= 1;
    }
    for (snapshot.queue_lines[0..@min(snapshot.queue_lines.len, remaining_queue_rows)]) |line| try frame.appendLine(screen.singleSpanLine(line, screen.styles.muted));
    appendEditor(&frame, snapshot.editor, @intCast(height - editor_rows), editor_rows, width, snapshot.editor_border_style, useBorder(height, width)) catch |err| return err;
    return frame;
}

pub fn transcriptRowCapacity(editor: *const Editor, queue_line_count: usize, viewport_hint_len: usize, width: u16, height: u16) usize {
    if (height <= 1) return 0;
    const editor_rows = editorRows(editor, height, width);
    const queue_rows = queueRowCount(queue_line_count, viewport_hint_len);
    const fixed_rows = 1 + editor_rows + queue_rows;
    return if (height > fixed_rows) height - fixed_rows else 0;
}

fn queueRowCount(queue_line_count: usize, viewport_hint_len: usize) usize {
    const hint_rows: usize = if (viewport_hint_len > 0) 1 else 0;
    return @min(queue_line_count + hint_rows, @as(usize, 4));
}

fn appendTranscriptTail(frame: *screen.Frame, lines: []const screen.Line, rows: usize) error{FrameFull}!void {
    if (rows == 0) return;
    const start = lines.len - @min(lines.len, rows);
    for (lines[start..]) |line| try frame.appendLine(line);
}

fn tailLine(text: []const u8) []const u8 {
    if (text.len <= 80) return text;
    return text[text.len - 80 ..];
}

fn editorRows(editor: *const Editor, height: u16, width: u16) usize {
    const content_rows = editorContentRows(editor, height);
    return content_rows + if (useBorder(height, width)) @as(usize, 2) else 0;
}

fn editorContentRows(editor: *const Editor, height: u16) usize {
    const content_rows = editor.lineCount();
    const max_rows = @max(@as(usize, 1), @min(@as(usize, 5), (@as(usize, height) * 3) / 10));
    return @min(@max(@as(usize, 1), content_rows), max_rows);
}

fn useBorder(height: u16, width: u16) bool {
    return height >= 6 and width >= 4;
}

fn appendEditor(frame: *screen.Frame, editor: *const Editor, start_row: u16, rows: usize, width: u16, border_style: screen.Style, bordered: bool) error{ FrameFull, LineFull }!void {
    const content_rows = rows - if (bordered) @as(usize, 2) else 0;
    const line_count = editor.lineCount();
    const first_line = if (line_count > content_rows) line_count - content_rows else 0;
    var row: u16 = start_row;
    if (bordered) {
        try frame.appendLine(borderLine(width, border_style));
        row += 1;
    }
    for (0..content_rows) |row_offset| {
        try appendEditorLine(frame, editor, row + @as(u16, @intCast(row_offset)), first_line + row_offset, width, border_style, bordered);
    }
    if (bordered) try frame.appendLine(borderLine(width, border_style));
}

fn appendEditorLine(frame: *screen.Frame, editor: *const Editor, row: u16, editor_line_index: usize, width: u16, border_style: screen.Style, bordered: bool) error{ FrameFull, LineFull }!void {
    var line: screen.Line = .{};
    const prefix = if (editor_line_index == 0) prompt else "  ";
    if (bordered) try line.append(.{ .text = "|", .style = border_style });
    try line.append(.{ .text = prefix, .style = screen.styles.accent });
    const text = editor.lineSlice(editor_line_index);
    try line.append(.{ .text = text });
    if (bordered) {
        const used = 1 + prefix.len + text.len;
        if (width > used + 1) try line.append(.{ .text = border_spaces[0..@min(border_spaces.len, width - used - 1)] });
        try line.append(.{ .text = "|", .style = border_style });
    }
    try frame.appendLine(line);

    const cursor = editor.cursorLineCol();
    if (cursor.line == editor_line_index) {
        const raw_col = (if (bordered) @as(usize, 1) else 0) + prefix.len + cursor.col;
        const max_col: usize = if (width == 0) 0 else width - 1;
        frame.cursor = .{ .col = @intCast(@min(raw_col, max_col)), .row = row };
    }
}

fn borderLine(width: u16, style: screen.Style) screen.Line {
    var line: screen.Line = .{};
    line.append(.{ .text = "+", .style = style }) catch unreachable;
    if (width > 2) line.append(.{ .text = border_fill[0..@min(border_fill.len, width - 2)], .style = style }) catch unreachable;
    if (width > 1) line.append(.{ .text = "+", .style = style }) catch unreachable;
    return line;
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

test "chrome renders transcript and queue lines above editor" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const transcript = [_]screen.Line{screen.singleSpanLine("streaming", screen.styles.normal)};
    const queues = [_][]const u8{"steering: next"};
    const frame = try compose(.{ .status = "ready", .transcript_lines = &transcript, .queue_lines = &queues, .editor = &editor }, 80, 5);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ready", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("streaming", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("steering: next", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("> draft", frame.rows()[4].copyText(&buffer));
}

test "chrome clamps cursor to frame width" {
    var editor: Editor = .{};
    try editor.insert("hello");
    const frame = try compose(.{ .editor = &editor }, 4, 1);

    try std.testing.expectEqual(@as(u16, 3), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 0), frame.cursor.?.row);
}

test "chrome renders bordered editor with supplied border style" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const frame = try compose(.{ .editor = &editor, .editor_border_style = screen.styles.error_ }, 20, 6);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("+------------------+", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("|> draft           |", frame.rows()[4].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 8), frame.cursor.?.col);
    try std.testing.expect(std.meta.eql(frame.rows()[3].spans()[0].style.fg, screen.styles.error_.fg));
}
