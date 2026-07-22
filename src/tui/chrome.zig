const std = @import("std");
const Editor = @import("Editor.zig");
const glyphs = @import("glyphs.zig");
const screen = @import("screen.zig");
const text_shimmer = @import("text_shimmer.zig");

pub const prompt = "";
pub const listbox_rows_max: usize = 8;
const attention_rows_max: usize = 4;
const fill_capacity = 4096;
const border_fill = glyphs.composer_horizontal ** fill_capacity;
const border_spaces = " " ** fill_capacity;

pub const ActivityEffect = enum { none, shimmer };

pub const ActivityView = struct {
    text: []const u8 = "",
    style: screen.Style = screen.text.muted,
    effect: ActivityEffect = .none,
    now_ns: u64 = 0,
};

pub const AttentionView = struct {
    viewport_hint: []const u8 = "",
    queue_lines: []const []const u8 = &.{},
};

pub const ComposerView = struct {
    editor: *const Editor,
    top_left: []const u8 = "",
    top_right: []const u8 = "",
    top_right_style: screen.Style = screen.text.muted,
    border_style: screen.Style = screen.text.border,
};

pub const ListboxRows = struct {
    rows: []const screen.Line = &.{},
    selected: ?usize = null,
};

pub const ListboxView = union(enum) {
    completion: ListboxRows,
    picker: ListboxRows,

    fn rows(self: ListboxView) ListboxRows {
        return switch (self) {
            .completion => |value| value,
            .picker => |value| value,
        };
    }
};

pub const FrameView = struct {
    transcript_lines: []const screen.Line = &.{},
    attention: AttentionView = .{},
    activity: ActivityView = .{},
    composer: ComposerView,
    listbox: ?ListboxView = null,
};

pub const ListboxMeasure = union(enum) {
    completion: usize,
    picker,
};

pub const PlanInput = struct {
    attention: AttentionView = .{},
    activity_open: bool = false,
    composer: *const Editor,
    listbox: ?ListboxMeasure = null,
};

pub const RowPlan = struct {
    transcript_rows: usize = 0,
    attention_rows: usize = 0,
    activity_rows: usize = 0,
    composer_rows: usize = 0,
    listbox_rows: usize = 0,

    pub fn totalRows(self: RowPlan) usize {
        return self.transcript_rows + self.attention_rows + self.activity_rows +
            self.composer_rows + self.listbox_rows;
    }
};

pub fn planRows(input: PlanInput, width: u16, height: u16) RowPlan {
    if (height == 0) return .{};
    if (height == 1) return .{ .composer_rows = 1 };

    const desired_activity_rows: usize = if (input.activity_open) 1 else 0;
    const desired_attention_rows = attentionRowCount(input.attention);
    if (height == 2) {
        const activity_rows = desired_activity_rows;
        const attention_rows: usize = if (activity_rows == 0 and desired_attention_rows > 0) 1 else 0;
        return .{
            .transcript_rows = if (activity_rows == 0 and attention_rows == 0) 1 else 0,
            .attention_rows = attention_rows,
            .activity_rows = activity_rows,
            .composer_rows = 1,
        };
    }

    const upper = clampedUpperRows(desired_attention_rows, desired_activity_rows, height);
    return rowPlan(
        input.composer,
        upper.attention_rows,
        upper.activity_rows,
        desiredListboxRows(input.listbox),
        width,
        height,
    );
}

pub fn compose(view: FrameView, plan: RowPlan, width: u16, height: u16) error{ FrameFull, LineFull }!screen.Frame {
    std.debug.assert(plan.totalRows() <= height);
    std.debug.assert(view.transcript_lines.len <= plan.transcript_rows);
    if (view.listbox) |listbox| std.debug.assert(listbox.rows().rows.len <= plan.listbox_rows);

    var frame: screen.Frame = .{};
    if (height == 0) return frame;
    const lower_rows = plan.attention_rows + plan.activity_rows + plan.composer_rows + plan.listbox_rows;

    try appendTranscriptTail(&frame, view.transcript_lines, plan.transcript_rows);
    while (frame.rows().len + lower_rows < height) try frame.appendLine(.{});
    try appendAttention(&frame, view.attention, plan.attention_rows);
    if (plan.activity_rows > 0) try appendActivityLine(&frame, view.activity);
    if (plan.composer_rows > 0) {
        try appendEditor(
            &frame,
            view.composer,
            @intCast(frame.rows().len),
            plan.composer_rows,
            width,
            useBorder(height, width) and plan.composer_rows >= 3,
        );
    }
    if (view.listbox) |listbox| try appendListbox(&frame, listbox, plan.listbox_rows);
    return frame;
}

fn appendAttention(
    frame: *screen.Frame,
    attention: AttentionView,
    rows: usize,
) error{ FrameFull, LineFull }!void {
    var remaining = rows;
    if (attention.viewport_hint.len > 0 and remaining > 0) {
        try frame.appendLine(screen.singleSpanLine(attention.viewport_hint, screen.text.muted));
        remaining -= 1;
    }
    for (attention.queue_lines[0..@min(attention.queue_lines.len, remaining)]) |line| {
        try frame.appendLine(screen.singleSpanLine(line, screen.text.muted));
    }
}

fn appendActivityLine(frame: *screen.Frame, activity: ActivityView) error{ FrameFull, LineFull }!void {
    var line: screen.Line = .{};
    switch (activity.effect) {
        .none => try line.append(.{ .text = activity.text, .style = activity.style }),
        .shimmer => try text_shimmer.append(
            &line,
            activity.text,
            activity.now_ns,
            .{ .base_style = activity.style },
        ),
    }
    try frame.appendLine(line);
}

const UpperRows = struct { attention_rows: usize, activity_rows: usize };

fn clampedUpperRows(attention_rows: usize, activity_rows: usize, height: u16) UpperRows {
    const max_non_composer = @as(usize, height) -| 1;
    const activity = @min(activity_rows, max_non_composer);
    const attention = @min(attention_rows, max_non_composer - activity);
    return .{ .attention_rows = attention, .activity_rows = activity };
}

fn rowPlan(
    editor: *const Editor,
    attention_rows: usize,
    activity_rows: usize,
    desired_listbox_rows: usize,
    width: u16,
    height: u16,
) RowPlan {
    var composer_rows = editorRows(editor, height, width);
    var listbox_rows = desired_listbox_rows;
    const upper_rows = activity_rows + attention_rows;
    const lower_budget = @as(usize, height) -| upper_rows;
    if (composer_rows > lower_budget) {
        composer_rows = lower_budget;
        listbox_rows = 0;
    } else {
        listbox_rows = @min(listbox_rows, lower_budget - composer_rows);
    }

    const fixed_rows = upper_rows + composer_rows + listbox_rows;
    return .{
        .transcript_rows = if (height > fixed_rows) height - fixed_rows else 0,
        .attention_rows = attention_rows,
        .activity_rows = activity_rows,
        .composer_rows = composer_rows,
        .listbox_rows = listbox_rows,
    };
}

fn attentionRowCount(attention: AttentionView) usize {
    const hint_rows: usize = if (attention.viewport_hint.len > 0) 1 else 0;
    return @min(attention.queue_lines.len + hint_rows, attention_rows_max);
}

fn desiredListboxRows(listbox: ?ListboxMeasure) usize {
    const value = listbox orelse return 0;
    return switch (value) {
        .completion => |row_count| @min(row_count, listbox_rows_max),
        .picker => listbox_rows_max,
    };
}

fn appendListbox(
    frame: *screen.Frame,
    listbox: ListboxView,
    rows: usize,
) error{ FrameFull, LineFull }!void {
    if (rows == 0) return;
    const values = listbox.rows();
    const start_len = frame.rows().len;
    for (values.rows[0..@min(rows, values.rows.len)], 0..) |source, index| {
        const selected = if (values.selected) |selected_index| index == selected_index else false;
        try appendListboxLine(frame, source, selected);
    }
    switch (listbox) {
        .completion => {},
        .picker => while (frame.rows().len - start_len < rows) try frame.appendLine(.{}),
    }
}

fn appendListboxLine(
    frame: *screen.Frame,
    source: screen.Line,
    selected: bool,
) error{ FrameFull, LineFull }!void {
    var line: screen.Line = .{ .row_style = screen.surface.composer };
    try line.append(.{
        .text = if (selected) glyphs.picker_selected else glyphs.picker_unselected,
        .style = if (selected) screen.text.accent else screen.text.muted,
    });
    for (source.spans()) |span| try line.append(span);
    try frame.appendLine(line);
}

fn appendTranscriptTail(frame: *screen.Frame, lines: []const screen.Line, rows: usize) error{FrameFull}!void {
    if (rows == 0) return;
    const start = lines.len - @min(lines.len, rows);
    for (lines[start..]) |line| try frame.appendLine(line);
}

fn editorRows(editor: *const Editor, height: u16, width: u16) usize {
    const bordered = useBorder(height, width);
    const content_rows = editorContentRows(editor, height, width, bordered);
    return content_rows + if (bordered) @as(usize, 2) else 0;
}

fn editorContentRows(editor: *const Editor, height: u16, width: u16, bordered: bool) usize {
    const content_rows = visualEditorLineCount(editor, composerTextColumns(width, bordered));
    const max_rows = @max(@as(usize, 1), @min(@as(usize, 5), (@as(usize, height) * 3) / 10));
    return @min(@max(@as(usize, 1), content_rows), max_rows);
}

fn useBorder(height: u16, width: u16) bool {
    return height >= 6 and width >= 4;
}

const VisualEditorLine = struct {
    editor_line_index: usize,
    wrap_index: usize,
    cursor_start: usize,
    start: usize,
    end: usize,
    line: []const u8,
};

pub const VerticalDirection = enum { up, down };

pub const VerticalCursorTarget = union(enum) {
    cursor: struct { byte: usize, preferred_column_cells: usize },
    history,
};

pub fn verticalCursorTarget(
    editor: *const Editor,
    width: u16,
    height: u16,
    direction: VerticalDirection,
    preferred_column_cells: ?usize,
) VerticalCursorTarget {
    const text_cols = composerTextColumns(width, useBorder(height, width));
    const total = visualEditorLineCount(editor, text_cols);
    const current_index = cursorVisualLineIndex(editor, text_cols);
    const current = visualEditorLineAt(editor, text_cols, current_index) orelse return .history;
    const cursor = editor.cursorLineCol();
    const current_end = @min(cursor.col, current.end);
    const current_column = if (current_end > current.start)
        screen.displayWidth(current.line[current.start..current_end])
    else
        0;
    const preferred = preferred_column_cells orelse current_column;
    const target_index = switch (direction) {
        .up => if (current_index == 0) return .history else current_index - 1,
        .down => if (current_index + 1 >= total) return .history else current_index + 1,
    };
    const target = visualEditorLineAt(editor, text_cols, target_index) orelse return .history;
    const line_offset = editor.lineByteOffset(target.editor_line_index);
    const byte = cursorByteAtDisplayColumn(editor, line_offset, target, preferred);
    return .{ .cursor = .{ .byte = byte, .preferred_column_cells = preferred } };
}

fn cursorByteAtDisplayColumn(
    editor: *const Editor,
    line_offset: usize,
    visual: VisualEditorLine,
    preferred_column_cells: usize,
) usize {
    var relative = visual.start;
    var column: usize = 0;
    while (relative < visual.end) {
        const absolute = line_offset + relative;
        const unit_end_absolute = @min(editor.cursorUnitEnd(absolute), line_offset + visual.end);
        const unit_end = unit_end_absolute - line_offset;
        if (unit_end <= relative) break;
        const next_column = column + screen.displayWidth(visual.line[relative..unit_end]);
        if (preferred_column_cells < next_column) {
            const before_distance = preferred_column_cells -| column;
            const after_distance = next_column - preferred_column_cells;
            return line_offset + if (before_distance <= after_distance) relative else unit_end;
        }
        if (preferred_column_cells == next_column) {
            if (unit_end == visual.end and visual.end < visual.line.len) return line_offset + relative;
            return line_offset + unit_end;
        }
        relative = unit_end;
        column = next_column;
    }
    if (visual.end < visual.line.len and visual.end > visual.start) {
        var previous = visual.start;
        var next = previous;
        while (next < visual.end) {
            previous = next;
            next = @min(editor.cursorUnitEnd(line_offset + next) - line_offset, visual.end);
            if (next <= previous) break;
        }
        return line_offset + previous;
    }
    return line_offset + visual.end;
}

fn composerTextColumns(width: u16, bordered: bool) usize {
    const content_width: usize = if (bordered) @as(usize, width) -| 2 else width;
    return content_width -| @min(screen.displayWidth(prompt), content_width);
}

fn visualEditorLineCount(editor: *const Editor, text_cols: usize) usize {
    var count: usize = 0;
    for (0..editor.lineCount()) |line_index| count += wrappedLineCount(editor.lineSlice(line_index), text_cols);
    return @max(@as(usize, 1), count);
}

fn wrappedLineCount(line: []const u8, text_cols: usize) usize {
    if (line.len == 0 or text_cols == 0) return 1;
    var count: usize = 0;
    var start: usize = 0;
    while (start < line.len) {
        const row_start = wrappedLineStart(line, start);
        if (row_start >= line.len) {
            count += 1;
            break;
        }
        start = wrappedLineEndProgress(line, row_start, text_cols);
        count += 1;
    }
    return @max(@as(usize, 1), count);
}

fn cursorVisualLineIndex(editor: *const Editor, text_cols: usize) usize {
    const cursor = editor.cursorLineCol();
    var absolute: usize = 0;
    for (0..editor.lineCount()) |line_index| {
        const line = editor.lineSlice(line_index);
        if (line_index == cursor.line) return absolute + wrappedLineIndexForCursor(line, text_cols, cursor.col);
        absolute += wrappedLineCount(line, text_cols);
    }
    return if (absolute == 0) 0 else absolute - 1;
}

fn wrappedLineIndexForCursor(line: []const u8, text_cols: usize, cursor_offset: usize) usize {
    if (line.len == 0 or text_cols == 0) return 0;
    var start: usize = 0;
    var index: usize = 0;
    while (start < line.len) {
        const row_start = wrappedLineStart(line, start);
        if (row_start >= line.len) {
            if (cursor_offset >= start) return index;
            break;
        }
        const end = wrappedLineEndProgress(line, row_start, text_cols);
        if ((cursor_offset >= start and cursor_offset < row_start) or
            cursor_offset < end or
            (cursor_offset == end and end == line.len)) return index;
        start = end;
        index += 1;
    }
    return if (index == 0) 0 else index - 1;
}

fn firstVisibleVisualLine(total: usize, cursor: usize, rows: usize) usize {
    if (rows == 0 or total <= rows) return 0;
    const clamped_cursor = @min(cursor, total - 1);
    if (clamped_cursor < rows) return 0;
    return @min(clamped_cursor - rows + 1, total - rows);
}

fn visualEditorLineAt(editor: *const Editor, text_cols: usize, target: usize) ?VisualEditorLine {
    var absolute: usize = 0;
    for (0..editor.lineCount()) |line_index| {
        const line = editor.lineSlice(line_index);
        if (line.len == 0 or text_cols == 0) {
            if (absolute == target) return .{ .editor_line_index = line_index, .wrap_index = 0, .cursor_start = 0, .start = 0, .end = line.len, .line = line };
            absolute += 1;
            continue;
        }
        var start: usize = 0;
        var wrap_index: usize = 0;
        while (start < line.len) {
            const row_start = wrappedLineStart(line, start);
            if (row_start >= line.len) {
                if (absolute == target) return .{ .editor_line_index = line_index, .wrap_index = wrap_index, .cursor_start = start, .start = line.len, .end = line.len, .line = line };
                absolute += 1;
                break;
            }
            const end = wrappedLineEndProgress(line, row_start, text_cols);
            if (absolute == target) return .{ .editor_line_index = line_index, .wrap_index = wrap_index, .cursor_start = start, .start = row_start, .end = end, .line = line };
            start = end;
            wrap_index += 1;
            absolute += 1;
        }
    }
    return null;
}

fn wrappedLineStart(line: []const u8, start: usize) usize {
    if (start == 0) return start;
    var index = start;
    while (index < line.len and isSoftWrapWhitespace(line[index])) : (index += 1) {}
    return index;
}

fn wrappedLineEndProgress(line: []const u8, start: usize, text_cols: usize) usize {
    const end = wrappedLineEnd(line, start, text_cols);
    if (end > start) return @min(end, line.len);
    return @min(line.len, start + screen.firstGraphemeEnd(line[start..]));
}

fn wrappedLineEnd(line: []const u8, start: usize, text_cols: usize) usize {
    if (start >= line.len) return line.len;
    if (text_cols == 0) return line.len;
    const hard_end = start + screen.sliceEndForColumns(line[start..], text_cols);
    if (hard_end == start or hard_end >= line.len) return hard_end;
    return softWrapEnd(line, start, hard_end) orelse hard_end;
}

fn softWrapEnd(line: []const u8, start: usize, hard_end: usize) ?usize {
    var last: ?usize = null;
    var index = start;
    while (index < hard_end) : (index += 1) {
        if (isSoftWrapBreakByte(line[index])) last = index + 1;
    }
    return last;
}

fn isSoftWrapWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isSoftWrapBreakByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '-', '/', '\\', '.', ',', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
}

fn appendEditor(
    frame: *screen.Frame,
    composer: ComposerView,
    start_row: u16,
    rows: usize,
    width: u16,
    bordered: bool,
) error{ FrameFull, LineFull }!void {
    const content_rows = rows - if (bordered) @as(usize, 2) else 0;
    const text_cols = composerTextColumns(width, bordered);
    const total_visual = visualEditorLineCount(composer.editor, text_cols);
    const cursor_visual = cursorVisualLineIndex(composer.editor, text_cols);
    const first_visual = firstVisibleVisualLine(total_visual, cursor_visual, content_rows);
    var row: u16 = start_row;
    if (bordered) {
        try frame.appendLine(borderLine(
            width,
            composer.border_style,
            true,
            composer.top_left,
            composer.top_right,
            composer.top_right_style,
        ));
        row += 1;
    }
    for (0..content_rows) |row_offset| {
        const visual = visualEditorLineAt(composer.editor, text_cols, first_visual + row_offset);
        try appendEditorVisualLine(
            frame,
            composer.editor,
            visual,
            row + @as(u16, @intCast(row_offset)),
            width,
            composer.border_style,
            bordered,
        );
    }
    if (bordered) {
        try frame.appendLine(borderLine(width, composer.border_style, false, "", "", screen.text.muted));
    }
}

fn appendEditorVisualLine(frame: *screen.Frame, editor: *const Editor, maybe_visual: ?VisualEditorLine, row: u16, width: u16, border_style: screen.Style, bordered: bool) error{ FrameFull, LineFull }!void {
    var builder = screen.LineBuilder.init(if (bordered) screen.surface.composer else screen.surface.transparent);
    const visual = maybe_visual orelse VisualEditorLine{ .editor_line_index = 0, .wrap_index = 0, .cursor_start = 0, .start = 0, .end = 0, .line = "" };
    const prefix = if (visual.editor_line_index == 0 and visual.wrap_index == 0) prompt else "";
    const text = visual.line[visual.start..visual.end];
    const content_width: usize = if (bordered) @as(usize, width) -| 2 else width;
    var remaining = content_width;

    if (bordered) _ = try builder.appendText(glyphs.composer_vertical, border_style);
    const prefix_cols = try builder.appendClipped(prefix, remaining, screen.text.accent);
    remaining -|= prefix_cols;
    const text_width = try builder.appendClipped(text, remaining, screen.text.normal);
    remaining -|= text_width;
    if (bordered) {
        _ = try builder.appendFill(spaceFill(remaining), remaining, screen.text.normal);
        _ = try builder.appendText(glyphs.composer_vertical, border_style);
    }
    try frame.appendLine(builder.finish());

    if (maybe_visual) |visible| {
        const cursor = editor.cursorLineCol();
        if (cursor.line == visible.editor_line_index and cursorInVisualLine(visible, cursor.col)) {
            const cursor_end = @min(cursor.col, visible.end);
            const cursor_text = if (cursor_end > visible.start) visible.line[visible.start..cursor_end] else "";
            const content_cursor_col = @min(prefix_cols + screen.displayWidth(cursor_text), content_width);
            const raw_col = (if (bordered) @as(usize, 1) else 0) + content_cursor_col;
            const max_col: usize = if (width == 0) 0 else width - 1;
            frame.cursor = .{ .col = @intCast(@min(raw_col, max_col)), .row = row };
        }
    }
}

fn cursorInVisualLine(visual: VisualEditorLine, cursor_offset: usize) bool {
    if (cursor_offset < visual.cursor_start or cursor_offset > visual.end) return false;
    return cursor_offset < visual.end or visual.end == visual.line.len;
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

fn composeForTest(view: FrameView, width: u16, height: u16) error{ FrameFull, LineFull }!screen.Frame {
    const listbox_measure: ?ListboxMeasure = if (view.listbox) |listbox| switch (listbox) {
        .completion => |rows| .{ .completion = rows.rows.len },
        .picker => .picker,
    } else null;
    const plan = planRows(.{
        .attention = view.attention,
        .activity_open = view.activity.text.len > 0,
        .composer = view.composer.editor,
        .listbox = listbox_measure,
    }, width, height);
    return compose(view, plan, width, height);
}

test "vertical cursor targets hard lines and preserves preferred display column" {
    var editor: Editor = .{};
    try editor.insert("abcdef\nxy\n123456");

    const first_up = verticalCursorTarget(&editor, 40, 10, .up, null).cursor;
    try std.testing.expectEqual(@as(usize, 9), first_up.byte);
    try std.testing.expectEqual(@as(usize, 6), first_up.preferred_column_cells);
    try std.testing.expect(editor.moveCursorTo(first_up.byte));

    const second_up = verticalCursorTarget(&editor, 40, 10, .up, first_up.preferred_column_cells).cursor;
    try std.testing.expectEqual(@as(usize, 6), second_up.byte);
    try std.testing.expect(editor.moveCursorTo(second_up.byte));
    try std.testing.expect(verticalCursorTarget(&editor, 40, 10, .up, second_up.preferred_column_cells) == .history);
}

test "vertical cursor targets soft wraps with wide and combining graphemes" {
    var editor: Editor = .{};
    try editor.insert("a界b界c界d");

    const up = verticalCursorTarget(&editor, 6, 10, .up, null).cursor;
    try std.testing.expectEqual(@as(usize, 8), up.byte);
    try std.testing.expectEqual(@as(usize, 3), up.preferred_column_cells);
    try std.testing.expect(editor.moveCursorTo(up.byte));
    const up_again = verticalCursorTarget(&editor, 6, 10, .up, up.preferred_column_cells).cursor;
    try std.testing.expectEqual(@as(usize, 4), up_again.byte);

    editor.clear();
    try editor.insert("e\u{301}xye\u{301}xy");
    const combining_up = verticalCursorTarget(&editor, 6, 10, .up, null).cursor;
    try std.testing.expect(std.unicode.utf8ValidateSlice(editor.text()[0..combining_up.byte]));
}

test "vertical cursor keeps paste markers atomic" {
    var editor: Editor = .{};
    _ = try editor.insertMarker("[paste #1 +20 lines]", "expanded");
    try editor.insert("\nend");
    const up = verticalCursorTarget(&editor, 40, 10, .up, null).cursor;
    try std.testing.expectEqual(@as(usize, 0), up.byte);
    try std.testing.expect(editor.moveCursorTo(up.byte));
    try std.testing.expect(!editor.moveCursorTo(2));
}

test "chrome row plan is authoritative across pathological dimensions" {
    var editor: Editor = .{};
    try editor.insert("one\ntwo\nthree");
    const widths = [_]u16{ 0, 1, 2, 3, 10, 80 };
    const heights = [_]u16{ 0, 1, 2, 3, 6, 12, screen.row_capacity };
    const queues = [_][]const u8{ "steering: one", "follow-up: two", "alt+q edits queued messages" };
    const listboxes = [_]?ListboxMeasure{ null, .{ .completion = listbox_rows_max }, .picker };
    for (widths) |width| {
        for (heights) |height| {
            for (listboxes) |listbox| {
                const plan = planRows(.{
                    .attention = .{ .viewport_hint = "↓ 2 new lines", .queue_lines = &queues },
                    .activity_open = true,
                    .composer = &editor,
                    .listbox = listbox,
                }, width, height);
                try std.testing.expect(plan.totalRows() <= height);
                if (height > 0) try std.testing.expectEqual(@as(usize, height), plan.totalRows());
                try std.testing.expect(plan.attention_rows <= attention_rows_max);
                try std.testing.expect(plan.activity_rows <= 1);
                try std.testing.expect(plan.listbox_rows <= listbox_rows_max);
            }
        }
    }
}

test "chrome composes Activity and Composer regions" {
    var editor: Editor = .{};
    try editor.insert("hello");
    const frame = try composeForTest(.{
        .activity = .{ .text = "ready" },
        .composer = .{ .editor = &editor },
    }, 80, 3);

    try std.testing.expectEqual(@as(usize, 3), frame.rows().len);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("ready", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("hello", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 5), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor.?.row);
}

test "chrome composes shimmer Activity as bounded spans" {
    var editor: Editor = .{};
    const frame = try composeForTest(.{
        .activity = .{
            .text = "Working…",
            .style = screen.shimmer.base,
            .effect = .shimmer,
            .now_ns = 6 * 32 * std.time.ns_per_ms,
        },
        .composer = .{ .editor = &editor },
    }, 80, 3);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Working…", frame.rows()[1].copyText(&buffer));
    try std.testing.expect(frame.rows()[1].spans().len > 1);
}

test "chrome uses two-row spare row for Transcript when Activity is absent" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const transcript = [_]screen.Line{screen.singleSpanLine("streaming", screen.text.normal)};
    const frame = try composeForTest(.{
        .transcript_lines = &transcript,
        .composer = .{ .editor = &editor },
    }, 80, 2);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("streaming", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("draft", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 5), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 1), frame.cursor.?.row);
}

test "chrome renders Transcript Attention Activity and Composer in screen order" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const transcript = [_]screen.Line{screen.singleSpanLine("streaming", screen.text.normal)};
    const queues = [_][]const u8{"steering: next"};
    const frame = try composeForTest(.{
        .transcript_lines = &transcript,
        .attention = .{ .queue_lines = &queues },
        .activity = .{ .text = "ready" },
        .composer = .{ .editor = &editor },
    }, 80, 8);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("streaming", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("steering: next", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("ready", frame.rows()[4].copyText(&buffer));
    try std.testing.expect(std.mem.startsWith(u8, frame.rows()[6].copyText(&buffer), "│draft"));
}

test "Attention consumes zero rows when absent and keeps queue order" {
    var editor: Editor = .{};
    const empty = planRows(.{ .composer = &editor }, 80, 8);
    try std.testing.expectEqual(@as(usize, 0), empty.attention_rows);

    const queues = [_][]const u8{
        "steering: one",
        "follow-up: two",
        "alt+q edits queued messages",
    };
    const frame = try composeForTest(.{
        .attention = .{ .queue_lines = &queues },
        .composer = .{ .editor = &editor },
    }, 80, 8);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("steering: one", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqualStrings("follow-up: two", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("alt+q edits queued messages", frame.rows()[4].copyText(&buffer));
}

test "Attention is capped and viewport hint displaces the action hint" {
    var editor: Editor = .{};
    const queues = [_][]const u8{
        "steering: one",
        "follow-up: two",
        "follow-up: three",
        "alt+q edits queued messages",
    };
    const frame = try composeForTest(.{
        .attention = .{ .viewport_hint = "↓ 2 new lines", .queue_lines = &queues },
        .composer = .{ .editor = &editor },
    }, 80, 8);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("↓ 2 new lines", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("steering: one", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqualStrings("follow-up: two", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("follow-up: three", frame.rows()[4].copyText(&buffer));
    for (frame.rows()) |row| {
        try std.testing.expect(std.mem.indexOf(u8, row.copyText(&buffer), "alt+q") == null);
    }
}

test "chrome region matrix protects Transcript and Composer" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const transcript = [_]screen.Line{screen.singleSpanLine("transcript", screen.text.normal)};
    const queues = [_][]const u8{"steering: next"};
    const completion_rows = [_]screen.Line{screen.singleSpanLine("completion", screen.text.normal)};
    const picker_rows = [_]screen.Line{screen.singleSpanLine("picker", screen.text.normal)};
    const cases = [_]struct {
        height: u16,
        attention: AttentionView = .{},
        activity: ActivityView = .{},
        listbox: ?ListboxView = null,
    }{
        .{ .height = 2 },
        .{ .height = 6, .activity = .{ .text = "working" } },
        .{ .height = 8, .attention = .{ .queue_lines = &queues } },
        .{ .height = 8, .attention = .{ .viewport_hint = "↓ 2 new lines" } },
        .{ .height = 10, .listbox = .{ .completion = .{ .rows = &completion_rows } } },
        .{ .height = 14, .listbox = .{ .picker = .{ .rows = &picker_rows } } },
        .{
            .height = 16,
            .attention = .{ .viewport_hint = "↓ 2 new lines", .queue_lines = &queues },
            .activity = .{ .text = "working" },
            .listbox = .{ .completion = .{ .rows = &completion_rows } },
        },
    };

    for (cases) |case| {
        const frame = try composeForTest(.{
            .transcript_lines = &transcript,
            .attention = case.attention,
            .activity = case.activity,
            .composer = .{ .editor = &editor },
            .listbox = case.listbox,
        }, 40, case.height);
        try std.testing.expectEqual(@as(usize, case.height), frame.rows().len);
        try std.testing.expect(frame.cursor != null);
        try std.testing.expect(frame.cursor.?.row < case.height);
        var buffer: [128]u8 = undefined;
        try std.testing.expectEqualStrings("transcript", frame.rows()[0].copyText(&buffer));
        var found_editor = false;
        for (frame.rows()) |row| {
            if (std.mem.indexOf(u8, row.copyText(&buffer), "draft") != null) found_editor = true;
        }
        try std.testing.expect(found_editor);
    }
}

test "chrome clamps Composer cursor to frame width" {
    var editor: Editor = .{};
    try editor.insert("hello");
    const frame = try composeForTest(.{ .composer = .{ .editor = &editor } }, 4, 2);

    try std.testing.expectEqual(@as(u16, 1), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 1), frame.cursor.?.row);
}

test "chrome renders bordered Composer with supplied border style" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const frame = try composeForTest(.{
        .composer = .{ .editor = &editor, .border_style = screen.text.error_ },
    }, 20, 6);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("╭──────────────────╮", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("│draft             │", frame.rows()[4].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 6), frame.cursor.?.col);
    try std.testing.expect(std.meta.eql(frame.rows()[3].spans()[0].style.fg, screen.text.error_.fg));
}

test "chrome Composer metadata is display-column aligned" {
    var editor: Editor = .{};
    const frame = try composeForTest(.{
        .composer = .{
            .editor = &editor,
            .top_left = "~/workspace/dev/personal/zi",
            .top_right = "ctx 10%/259k • gpt-5.5 (low)",
        },
    }, 100, 6);

    var buffer: [256]u8 = undefined;
    const top = frame.rows()[3].copyText(&buffer);
    try std.testing.expectEqual(@as(usize, 100), frame.rows()[3].cellWidth());
    try std.testing.expect(std.mem.startsWith(u8, top, "╭ ~/workspace/dev/personal/zi "));
    try std.testing.expect(std.mem.endsWith(u8, top, "╮"));
}

test "chrome bordered Composer uses display columns for fill and cursor" {
    var editor: Editor = .{};
    try editor.insert("λ🙂");
    const frame = try composeForTest(.{ .composer = .{ .editor = &editor } }, 20, 6);

    var buffer: [128]u8 = undefined;
    const row = frame.rows()[4].copyText(&buffer);
    try std.testing.expectEqual(@as(usize, 20), frame.rows()[4].cellWidth());
    try std.testing.expect(std.mem.startsWith(u8, row, "│λ🙂"));
    try std.testing.expect(std.mem.endsWith(u8, row, "│"));
    try std.testing.expectEqual(@as(u16, 4), frame.cursor.?.col);
}

test "chrome wraps Composer input by display columns" {
    var editor: Editor = .{};
    try editor.insert("hello my good friend");
    const frame = try composeForTest(.{ .composer = .{ .editor = &editor } }, 20, 10);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("│hello my good     │", frame.rows()[7].copyText(&buffer));
    try std.testing.expectEqualStrings("│friend            │", frame.rows()[8].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 7), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 8), frame.cursor.?.row);
}

test "chrome keeps wrapped Composer cursor visible" {
    var editor: Editor = .{};
    try editor.insert("abcdefgh ijklmnop qrstuvwx yz");
    editor.moveBufferStart();
    const frame = try composeForTest(.{ .composer = .{ .editor = &editor } }, 12, 20);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("│abcdefgh  │", frame.rows()[15].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 1), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 15), frame.cursor.?.row);
}

test "chrome wraps Composer input by unicode cell width" {
    var editor: Editor = .{};
    try editor.insert("λ🙂abcdef");
    const frame = try composeForTest(.{ .composer = .{ .editor = &editor } }, 10, 10);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("│λ🙂abcde│", frame.rows()[7].copyText(&buffer));
    try std.testing.expectEqualStrings("│f       │", frame.rows()[8].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 2), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 8), frame.cursor.?.row);
}

test "chrome renders picker Listbox with shared selection marker" {
    var editor: Editor = .{};
    const rows = [_]screen.Line{
        screen.singleSpanLine("alpha", screen.text.normal),
        screen.singleSpanLine("beta", screen.text.normal),
    };
    const frame = try composeForTest(.{
        .activity = .{ .text = "ready" },
        .composer = .{ .editor = &editor },
        .listbox = .{ .picker = .{ .rows = &rows, .selected = 1 } },
    }, 80, 10);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("  alpha", frame.rows()[4].copyText(&buffer));
    try std.testing.expectEqualStrings("› beta", frame.rows()[5].copyText(&buffer));
    try std.testing.expect(std.mem.startsWith(u8, frame.rows()[2].copyText(&buffer), "│"));
    try std.testing.expect(std.meta.eql(frame.rows()[5].row_style.bg, screen.surface.composer.bg));
}

test "chrome renders completion Listbox with shared selection marker" {
    var editor: Editor = .{};
    try editor.insert("@m");
    const rows = [_]screen.Line{
        screen.singleSpanLine("main.zig", screen.text.normal),
        screen.singleSpanLine("module.zig", screen.text.normal),
    };
    const frame = try composeForTest(.{
        .activity = .{ .text = "ready" },
        .composer = .{ .editor = &editor },
        .listbox = .{ .completion = .{ .rows = &rows, .selected = 1 } },
    }, 80, 9);

    var buffer: [128]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, frame.rows()[5].copyText(&buffer), "│@m"));
    try std.testing.expectEqualStrings("  main.zig", frame.rows()[7].copyText(&buffer));
    try std.testing.expectEqualStrings("› module.zig", frame.rows()[8].copyText(&buffer));
    try std.testing.expect(std.meta.eql(frame.rows()[8].row_style.bg, screen.surface.composer.bg));
}

test "chrome protects Activity and Composer under constrained Attention" {
    var editor: Editor = .{};
    try editor.insert("draft");
    const queues = [_][]const u8{ "steering: one", "follow-up: two", "follow-up: three" };
    const frame = try composeForTest(.{
        .attention = .{ .queue_lines = &queues },
        .activity = .{ .text = "Working…" },
        .composer = .{ .editor = &editor },
    }, 40, 3);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("steering: one", frame.rows()[0].copyText(&buffer));
    try std.testing.expectEqualStrings("Working…", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("draft", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 5), frame.cursor.?.col);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor.?.row);
}

test "chrome picker Listbox reserves eight rows" {
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
    const frame = try composeForTest(.{
        .composer = .{ .editor = &editor },
        .listbox = .{ .picker = .{ .rows = &rows, .selected = 7 } },
    }, 80, 30);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("› item7", frame.rows()[29].copyText(&buffer));
    try std.testing.expect(std.meta.eql(frame.rows()[29].row_style.bg, screen.surface.composer.bg));
}

test "chrome picker Listbox renders non-selectable empty state" {
    var editor: Editor = .{};
    const rows = [_]screen.Line{screen.singleSpanLine("no matches", screen.text.muted)};
    const frame = try composeForTest(.{
        .composer = .{ .editor = &editor },
        .listbox = .{ .picker = .{ .rows = &rows, .selected = null } },
    }, 40, 12);

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("  no matches", frame.rows()[4].copyText(&buffer));
}
