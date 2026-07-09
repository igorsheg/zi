const std = @import("std");
const Editor = @import("Editor.zig");
const glyphs = @import("glyphs.zig");
const screen = @import("screen.zig");

pub const prompt = "> ";
pub const popup_rows_max: usize = 8;
const fill_capacity = 4096;
const border_fill = glyphs.composer_horizontal ** fill_capacity;
const border_spaces = " " ** fill_capacity;

pub const PopupView = struct {
    rows: []const screen.Line = &.{},
    selected: usize = 0,
};

pub const PickerView = struct {
    rows: []const screen.Line = &.{},
    selected: ?usize = null,
};

pub const Snapshot = struct {
    status: []const u8 = "",
    composer_top_left: []const u8 = "",
    composer_top_right: []const u8 = "",
    composer_top_right_style: screen.Style = screen.text.muted,
    composer_bottom_left: []const u8 = "",
    composer_bottom_right: []const u8 = "",
    composer_bottom_right_style: screen.Style = screen.text.muted,
    scratch_text: []const u8 = "",
    transcript_lines: []const screen.Line = &.{},
    queue_lines: []const []const u8 = &.{},
    viewport_hint: []const u8 = "",
    editor: *const Editor,
    editor_border_style: screen.Style = screen.text.border,
    popup: ?PopupView = null,
    picker: ?PickerView = null,
};

pub fn compose(snapshot: Snapshot, width: u16, height: u16) error{ FrameFull, LineFull }!screen.Frame {
    var frame: screen.Frame = .{};
    if (height == 0) return frame;
    if (height == 1) {
        try appendEditorLine(&frame, snapshot.editor, 0, 0, width, snapshot.editor_border_style, false);
        return frame;
    }
    if (height == 2) {
        if (snapshot.status.len > 0) {
            try frame.appendLine(screen.singleSpanLine(snapshot.status, screen.text.muted));
        } else if (snapshot.queue_lines.len > 0 or snapshot.viewport_hint.len > 0) {
            const line = if (snapshot.viewport_hint.len > 0) snapshot.viewport_hint else snapshot.queue_lines[0];
            try frame.appendLine(screen.singleSpanLine(line, screen.text.muted));
        } else if (snapshot.transcript_lines.len > 0) {
            try appendTranscriptTail(&frame, snapshot.transcript_lines, 1);
        } else if (snapshot.scratch_text.len > 0) {
            try frame.appendLine(screen.singleSpanLine(tailLine(snapshot.scratch_text), screen.text.normal));
        } else {
            try frame.appendLine(.{});
        }
        try appendEditorLine(&frame, snapshot.editor, 1, 0, width, snapshot.editor_border_style, false);
        return frame;
    }

    const requested_queue_rows = queueRowCount(snapshot.queue_lines.len, snapshot.viewport_hint.len);
    const requested_status_rows: usize = if (snapshot.status.len > 0) 1 else 0;
    const top_chrome = clampedTopChromeRows(requested_queue_rows, requested_status_rows, height);
    const plan = rowPlan(snapshot.editor, snapshot.picker != null, top_chrome.queue_rows, top_chrome.status_rows, popupRowCount(snapshot), width, height);
    const bottom_rows = top_chrome.status_rows + plan.popup_rows + plan.editor_rows + plan.picker_rows;

    appendTranscriptTail(&frame, snapshot.transcript_lines, plan.transcript_rows) catch |err| return err;
    if (snapshot.scratch_text.len > 0 and frame.rows().len + top_chrome.queue_rows + bottom_rows < height) {
        try frame.appendLine(screen.singleSpanLine(tailLine(snapshot.scratch_text), screen.text.normal));
    }
    while (frame.rows().len + top_chrome.queue_rows + bottom_rows < height) try frame.appendLine(.{});

    var remaining_queue_rows = top_chrome.queue_rows;
    if (snapshot.viewport_hint.len > 0 and remaining_queue_rows > 0) {
        try frame.appendLine(screen.singleSpanLine(snapshot.viewport_hint, screen.text.muted));
        remaining_queue_rows -= 1;
    }
    for (snapshot.queue_lines[0..@min(snapshot.queue_lines.len, remaining_queue_rows)]) |line| try frame.appendLine(screen.singleSpanLine(line, screen.text.muted));
    if (top_chrome.status_rows > 0) try frame.appendLine(screen.singleSpanLine(snapshot.status, screen.text.muted));
    if (plan.editor_rows > 0) appendEditor(&frame, snapshot, @intCast(frame.rows().len), plan.editor_rows, width, useBorder(height, width) and plan.editor_rows >= 3) catch |err| return err;
    if (snapshot.picker) |picker| try appendPicker(&frame, picker, plan.picker_rows);
    if (snapshot.popup) |popup| try appendPopup(&frame, popup, plan.popup_rows);
    return frame;
}

pub fn transcriptRowCapacity(editor: *const Editor, queue_line_count: usize, viewport_hint_len: usize, width: u16, height: u16) usize {
    const top_chrome = clampedTopChromeRows(queueRowCount(queue_line_count, viewport_hint_len), 0, height);
    return transcriptRowCapacityFor(editor, false, top_chrome.queue_rows, 0, 0, width, height);
}

pub fn transcriptRowCapacityWithChrome(editor: *const Editor, picker_open: bool, queue_line_count: usize, viewport_hint_len: usize, popup_line_count: usize, status_open: bool, width: u16, height: u16) usize {
    const top_chrome = clampedTopChromeRows(queueRowCount(queue_line_count, viewport_hint_len), if (status_open) 1 else 0, height);
    return transcriptRowCapacityFor(editor, picker_open, top_chrome.queue_rows, top_chrome.status_rows, @min(popup_line_count, popup_rows_max), width, height);
}

pub fn popupCandidateCapacity(editor: *const Editor, queue_line_count: usize, viewport_hint_len: usize, status_open: bool, width: u16, height: u16) usize {
    const top_chrome = clampedTopChromeRows(queueRowCount(queue_line_count, viewport_hint_len), if (status_open) 1 else 0, height);
    return rowPlan(editor, false, top_chrome.queue_rows, top_chrome.status_rows, popup_rows_max, width, height).popup_rows;
}

pub fn pickerPanelCapacity(editor: *const Editor, queue_line_count: usize, viewport_hint_len: usize, status_open: bool, width: u16, height: u16) usize {
    const top_chrome = clampedTopChromeRows(queueRowCount(queue_line_count, viewport_hint_len), if (status_open) 1 else 0, height);
    return rowPlan(editor, true, top_chrome.queue_rows, top_chrome.status_rows, 0, width, height).picker_rows;
}

fn transcriptRowCapacityFor(editor: *const Editor, picker_open: bool, queue_rows: usize, status_rows: usize, popup_rows: usize, width: u16, height: u16) usize {
    if (height <= 1) return 0;
    return rowPlan(editor, picker_open, queue_rows, status_rows, popup_rows, width, height).transcript_rows;
}

const TopChromeRows = struct { queue_rows: usize, status_rows: usize };

fn clampedTopChromeRows(queue_rows: usize, status_rows: usize, height: u16) TopChromeRows {
    const max_non_editor = @as(usize, height) -| 1;
    const status = @min(status_rows, max_non_editor);
    const queue = @min(queue_rows, max_non_editor - status);
    return .{ .queue_rows = queue, .status_rows = status };
}

const RowPlan = struct {
    transcript_rows: usize,
    editor_rows: usize,
    popup_rows: usize,
    picker_rows: usize,
};

fn rowPlan(editor: *const Editor, picker_open: bool, queue_rows: usize, status_rows: usize, popup_rows: usize, width: u16, height: u16) RowPlan {
    var editor_rows_value = editorRows(editor, height, width);
    var popup_rows_value = popup_rows;
    var picker_rows_value = if (picker_open) pickerRows(height) else 0;

    const fixed_without_bottom = status_rows + queue_rows;
    const bottom_budget = @as(usize, height) -| fixed_without_bottom;
    if (editor_rows_value > bottom_budget) {
        editor_rows_value = bottom_budget;
        popup_rows_value = 0;
        picker_rows_value = 0;
    } else {
        var remaining = bottom_budget - editor_rows_value;
        if (popup_rows_value > remaining) popup_rows_value = remaining;
        remaining -= popup_rows_value;
        if (picker_rows_value > remaining) picker_rows_value = remaining;
    }

    const fixed_rows = fixed_without_bottom + editor_rows_value + popup_rows_value + picker_rows_value;
    return .{
        .transcript_rows = if (height > fixed_rows) height - fixed_rows else 0,
        .editor_rows = editor_rows_value,
        .popup_rows = popup_rows_value,
        .picker_rows = picker_rows_value,
    };
}

fn queueRowCount(queue_line_count: usize, viewport_hint_len: usize) usize {
    const hint_rows: usize = if (viewport_hint_len > 0) 1 else 0;
    return @min(queue_line_count + hint_rows, @as(usize, 4));
}

fn popupRowCount(snapshot: Snapshot) usize {
    return if (snapshot.popup) |popup| @min(popup.rows.len, popup_rows_max) else 0;
}

fn pickerRows(_: u16) usize {
    return popup_rows_max;
}

fn appendPopup(frame: *screen.Frame, popup: PopupView, rows: usize) error{ FrameFull, LineFull }!void {
    for (popup.rows[0..@min(rows, popup.rows.len)], 0..) |source, index| {
        try appendSelectableLine(frame, source, index == popup.selected);
    }
}

fn appendPicker(frame: *screen.Frame, picker: PickerView, rows: usize) error{ FrameFull, LineFull }!void {
    if (rows == 0) return;
    const start_len = frame.rows().len;
    for (picker.rows[0..@min(rows, picker.rows.len)], 0..) |source, index| {
        const selected = if (picker.selected) |selected_index| index == selected_index else false;
        try appendSelectableLine(frame, source, selected);
    }
    while (frame.rows().len - start_len < rows) try frame.appendLine(.{});
}

fn appendSelectableLine(frame: *screen.Frame, source: screen.Line, selected: bool) error{ FrameFull, LineFull }!void {
    var line: screen.Line = .{ .row_style = if (selected) screen.surface.selected else screen.surface.composer };
    try line.append(.{ .text = if (selected) glyphs.picker_selected else glyphs.picker_unselected, .style = if (selected) screen.text.accent else screen.text.muted });
    for (source.spans()) |span| try line.append(span);
    try frame.appendLine(line);
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
fn appendEditor(frame: *screen.Frame, snapshot: Snapshot, start_row: u16, rows: usize, width: u16, bordered: bool) error{ FrameFull, LineFull }!void {
    const content_rows = rows - if (bordered) @as(usize, 2) else 0;
    const line_count = snapshot.editor.lineCount();
    const first_line = if (line_count > content_rows) line_count - content_rows else 0;
    var row: u16 = start_row;
    const border_style = snapshot.editor_border_style;
    if (bordered) {
        try frame.appendLine(borderLine(width, border_style, true, snapshot.composer_top_left, snapshot.composer_top_right, snapshot.composer_top_right_style));
        row += 1;
    }
    for (0..content_rows) |row_offset| {
        try appendEditorLine(frame, snapshot.editor, row + @as(u16, @intCast(row_offset)), first_line + row_offset, width, border_style, bordered);
    }
    if (bordered) try frame.appendLine(borderLine(width, border_style, false, snapshot.composer_bottom_left, snapshot.composer_bottom_right, snapshot.composer_bottom_right_style));
}

fn appendEditorLine(frame: *screen.Frame, editor: *const Editor, row: u16, editor_line_index: usize, width: u16, border_style: screen.Style, bordered: bool) error{ FrameFull, LineFull }!void {
    var builder = screen.LineBuilder.init(if (bordered) screen.surface.composer else screen.surface.transparent);
    const prefix = if (editor_line_index == 0) prompt else "  ";
    const text = editor.lineSlice(editor_line_index);
    const content_width: usize = if (bordered) width -| 2 else width;
    var remaining = content_width;

    if (bordered) _ = try builder.appendText(glyphs.composer_vertical, border_style);
    const prefix_cols = try builder.appendClipped(prefix, remaining, if (bordered) screen.text.accent else screen.text.accent);
    remaining -|= prefix_cols;
    const text_cols = try builder.appendClipped(text, remaining, screen.text.normal);
    remaining -|= text_cols;
    if (bordered) {
        _ = try builder.appendFill(spaceFill(remaining), remaining, screen.text.normal);
        _ = try builder.appendText(glyphs.composer_vertical, border_style);
    }
    try frame.appendLine(builder.finish());

    const cursor = editor.cursorLineCol();
    if (cursor.line == editor_line_index) {
        const cursor_text = text[0..@min(cursor.col, text.len)];
        const content_cursor_col = @min(prefix_cols + screen.displayWidth(cursor_text), content_width);
        const raw_col = (if (bordered) @as(usize, 1) else 0) + content_cursor_col;
        const max_col: usize = if (width == 0) 0 else width - 1;
        frame.cursor = .{ .col = @intCast(@min(raw_col, max_col)), .row = row };
    }
}

fn borderLine(width: u16, border_style: screen.Style, top: bool, left_label: []const u8, right_label: []const u8, right_style: screen.Style) screen.Line {
    var builder = screen.LineBuilder.init(screen.surface.composer);
    if (width == 0) return builder.finish();
    const left_corner = if (top) glyphs.composer_top_left else glyphs.composer_bottom_left;
    const right_corner = if (top) glyphs.composer_top_right else glyphs.composer_bottom_right;
    _ = builder.appendText(left_corner, border_style) catch unreachable;
    if (width == 1) return builder.finish();

    const inner = @as(usize, width) - 2;
    const left_label_width = screen.displayWidth(left_label);
    const right_label_width = screen.displayWidth(right_label);
    const left_limit = if (right_label_width > 0) inner / 2 else inner -| 2;
    const left_budget = if (left_label_width > 0 and inner >= 3) @min(left_label_width, left_limit) else 0;
    const left_total = if (left_budget > 0) left_budget + 2 else 0;
    const right_available = inner -| left_total;
    const right_budget = if (right_label_width > 0 and right_available >= 3) @min(right_label_width, right_available - 2) else 0;
    const right_total = if (right_budget > 0) right_budget + 2 else 0;

    if (left_budget > 0) {
        _ = builder.appendText(" ", border_style) catch unreachable;
        _ = builder.appendClipped(left_label, left_budget, screen.text.muted) catch unreachable;
        _ = builder.appendText(" ", border_style) catch unreachable;
    }
    const fill_cols = inner -| left_total -| right_total;
    _ = builder.appendFill(horizontalFill(fill_cols), fill_cols, border_style) catch unreachable;
    if (right_budget > 0) {
        _ = builder.appendText(" ", border_style) catch unreachable;
        _ = builder.appendClipped(right_label, right_budget, right_style) catch unreachable;
        _ = builder.appendText(" ", border_style) catch unreachable;
    }
    _ = builder.appendText(right_corner, border_style) catch unreachable;
    return builder.finish();
}

fn horizontalFill(cols: usize) []const u8 {
    const bytes = @min(border_fill.len, cols * glyphs.composer_horizontal.len);
    return border_fill[0..bytes];
}

fn spaceFill(cols: usize) []const u8 {
    return border_spaces[0..@min(border_spaces.len, cols)];
}

test "chrome composes status and editor rows" {
    var editor: Editor = .{};
    try editor.insert("hello");
    var frame = try compose(.{ .status = "ready", .editor = &editor }, 80, 3);

    try std.testing.expectEqual(@as(usize, 3), frame.rows().len);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("ready", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("> hello", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 7), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor.?.row);
}

test "chrome uses two-row spare row for transcript when no status" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const transcript = [_]screen.Line{screen.singleSpanLine("streaming", screen.text.normal)};
    const frame = try compose(.{ .transcript_lines = &transcript, .editor = &editor }, 80, 2);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("streaming", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("> draft", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 7), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 1), frame.cursor.?.row);
}

test "chrome renders transcript and queue lines above editor" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const transcript = [_]screen.Line{screen.singleSpanLine("streaming", screen.text.normal)};
    const queues = [_][]const u8{"steering: next"};
    const frame = try compose(.{ .status = "ready", .transcript_lines = &transcript, .queue_lines = &queues, .editor = &editor }, 80, 8);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("streaming", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("steering: next", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("ready", frame.rows()[4].copyText(&buffer));
    try std.testing.expect(std.mem.startsWith(u8, frame.rows()[6].copyText(&buffer), "│> draft"));
}

test "chrome clamps cursor to frame width" {
    var editor: Editor = .{};
    try editor.insert("hello");
    const frame = try compose(.{ .editor = &editor }, 4, 2);

    try std.testing.expectEqual(@as(u16, 3), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 1), frame.cursor.?.row);
}

test "chrome renders bordered editor with supplied border style" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const frame = try compose(.{ .editor = &editor, .editor_border_style = screen.text.error_ }, 20, 6);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("╭──────────────────╮", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("│> draft           │", frame.rows()[4].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 8), frame.cursor.?.col);
    try std.testing.expect(std.meta.eql(frame.rows()[3].spans()[0].style.fg, screen.text.error_.fg));
}

test "chrome composer border labels are display-column aligned" {
    var editor: Editor = .{};
    const frame = try compose(.{
        .editor = &editor,
        .composer_top_left = "~/workspace/dev/personal/zi",
        .composer_top_right = "ctx 0.0% ↑0 ↓0 tokens · gpt-5.5 · thinking:off",
    }, 100, 6);

    var buffer: [256]u8 = undefined;
    const top = frame.rows()[3].copyText(&buffer);
    try std.testing.expectEqual(@as(usize, 100), frame.rows()[3].cellWidth());
    try std.testing.expect(std.mem.startsWith(u8, top, "╭ ~/workspace/dev/personal/zi "));
    try std.testing.expect(std.mem.endsWith(u8, top, "╮"));
}

test "chrome bordered editor uses display columns for fill and cursor" {
    var editor: Editor = .{};
    try editor.insert("λ🙂");
    const frame = try compose(.{ .editor = &editor }, 20, 6);

    var buffer: [128]u8 = undefined;
    const row = frame.rows()[4].copyText(&buffer);
    try std.testing.expectEqual(@as(usize, 20), frame.rows()[4].cellWidth());
    try std.testing.expect(std.mem.startsWith(u8, row, "│> λ🙂"));
    try std.testing.expect(std.mem.endsWith(u8, row, "│"));
    try std.testing.expectEqual(@as(u16, 6), frame.cursor.?.col);
}

test "chrome renders picker with main selection marker" {
    var editor: Editor = .{};
    const rows = [_]screen.Line{
        screen.singleSpanLine("alpha", screen.text.normal),
        screen.singleSpanLine("beta", screen.text.normal),
    };
    const frame = try compose(.{
        .status = "ready",
        .editor = &editor,
        .picker = .{ .rows = &rows, .selected = 1 },
    }, 80, 10);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("  alpha", frame.rows()[4].copyText(&buffer));
    try std.testing.expectEqualStrings("› beta", frame.rows()[5].copyText(&buffer));
    try std.testing.expect(std.mem.startsWith(u8, frame.rows()[2].copyText(&buffer), "│> "));
    try std.testing.expect(std.meta.eql(frame.rows()[5].row_style.bg, screen.surface.selected.bg));
}

test "chrome renders completion popup with main selection marker" {
    var editor: Editor = .{};
    try editor.insert("@m");
    const rows = [_]screen.Line{
        screen.singleSpanLine("main.zig", screen.text.normal),
        screen.singleSpanLine("module.zig", screen.text.normal),
    };
    const frame = try compose(.{
        .status = "ready",
        .editor = &editor,
        .popup = .{ .rows = &rows, .selected = 1 },
    }, 80, 9);

    var buffer: [128]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, frame.rows()[5].copyText(&buffer), "│> @m"));
    try std.testing.expectEqualStrings("  main.zig", frame.rows()[7].copyText(&buffer));
    try std.testing.expectEqualStrings("› module.zig", frame.rows()[8].copyText(&buffer));
    try std.testing.expect(std.meta.eql(frame.rows()[8].row_style.bg, screen.surface.selected.bg));
}

test "chrome protects composer under small queued/status chrome" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const queues = [_][]const u8{ "steering: one", "follow-up: two", "follow-up: three" };
    const frame = try compose(.{ .status = "Working…", .queue_lines = &queues, .editor = &editor }, 40, 3);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("steering: one", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("Working…", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("> draft", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 7), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor.?.row);
}

test "chrome picker keeps eighth visible candidate" {
    var editor: Editor = .{};
    const rows = [_]screen.Line{
        screen.singleSpanLine("item0", screen.text.normal),
        screen.singleSpanLine("item1", screen.text.normal),
        screen.singleSpanLine("item2", screen.text.normal),
        screen.singleSpanLine("item3", screen.text.normal),
        screen.singleSpanLine("item4", screen.text.normal),
        screen.singleSpanLine("item5", screen.text.normal),
        screen.singleSpanLine("item6", screen.text.normal),
        screen.singleSpanLine("item7", screen.text.normal),
    };
    const frame = try compose(.{
        .editor = &editor,
        .picker = .{ .rows = &rows, .selected = 7 },
    }, 80, 30);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("› item7", frame.rows()[29].copyText(&buffer));
    try std.testing.expect(std.meta.eql(frame.rows()[29].row_style.bg, screen.surface.selected.bg));
}
