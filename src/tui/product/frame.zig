const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");
const app_mod = @import("App.zig");
const transcript_mod = @import("transcript.zig");

pub const size_cells_max: usize = 500_000;
const transcript_visual_rows_max: usize = 512;

const TranscriptVisualRow = struct {
    role: transcript_mod.TranscriptRole,
    text: []const u8,
    show_prefix: bool,
};

pub const Frame = struct {
    width: u16,
    height: u16,

    pub fn build(app: anytype, renderer: *infra.Renderer) !void {
        if (renderer.next.width != app.width or renderer.next.height != app.height) {
            try renderer.resize(app.width, app.height);
        }
        renderer.next.clear();
        try drawShell(app, renderer);
    }
};

fn drawShell(app: anytype, renderer: *infra.Renderer) !void {
    const label_style: primitive.Style = .{ .fg = .{ .indexed = 8 }, .bold = true };
    const composer_style: primitive.Style = .{};
    const transcript_style: primitive.Style = .{ .fg = .{ .indexed = 7 } };

    if (app.height > 0) try renderer.writeText(0, 0, "zi", label_style);
    if (app.height > 0) {
        try drawTranscript(app, renderer, transcript_style, transcriptVisibleRows(app.height));
    }
    if (app.height > 0) {
        const composer_y = app.height - 1;
        try renderer.writeText(0, composer_y, "> ", label_style);
        if (app.width > 2) try renderer.writeText(2, composer_y, app.composer.text(), composer_style);
    }
}

pub fn transcriptVisibleRows(height: u16) usize {
    if (height == 0) return 0;
    const composer_y = height - 1;
    const available_rows: usize = if (composer_y > 1) composer_y - 1 else 0;
    return @min(available_rows, transcript_visual_rows_max);
}

pub fn transcriptScrollMax(transcript: transcript_mod.TranscriptBuffer, width: u16, visible_rows: usize) usize {
    if (width == 0 or visible_rows == 0) return 0;
    var total_rows: usize = 0;
    for (transcript.lines.items) |line| total_rows += countWrappedTranscriptRows(line, width);
    return if (total_rows > visible_rows) total_rows - visible_rows else 0;
}

fn drawTranscript(app: anytype, renderer: *infra.Renderer, style: primitive.Style, visible_rows: usize) !void {
    if (visible_rows == 0 or app.width == 0) return;
    const row_limit = @min(visible_rows, transcript_visual_rows_max);
    var rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var row_count: usize = 0;
    var skipped_rows: usize = 0;

    var line_index = app.transcript.lines.items.len;
    while (line_index > 0 and row_count < row_limit) {
        line_index -= 1;
        const line = app.transcript.lines.items[line_index];
        const line_rows = countWrappedTranscriptRows(line, app.width);
        if (skipped_rows + line_rows <= app.transcript_scroll_rows) {
            skipped_rows += line_rows;
            continue;
        }
        appendWrappedTranscriptLine(
            &rows,
            &row_count,
            row_limit,
            line,
            app.width,
            app.transcript_scroll_rows - skipped_rows,
        );
        skipped_rows = app.transcript_scroll_rows;
    }

    var draw_index = row_count;
    var y: u16 = 1;
    while (draw_index > 0) : (y += 1) {
        draw_index -= 1;
        const row = rows[draw_index];
        if (row.show_prefix) {
            const prefix = rolePrefix(row.role);
            try renderer.writeText(0, y, prefix, style);
            const text_x = primitive.text.displayWidth(prefix);
            if (text_x < renderer.next.width and row.text.len > 0) {
                try renderer.writeText(@intCast(text_x), y, row.text, style);
            }
        } else {
            try renderer.writeText(0, y, row.text, style);
        }
    }
}

fn appendWrappedTranscriptLine(
    rows: *[transcript_visual_rows_max]TranscriptVisualRow,
    row_count: *usize,
    row_limit: usize,
    line: transcript_mod.TranscriptLine,
    frame_width: u16,
    skip_newest_rows: usize,
) void {
    const prefix = rolePrefix(line.role);
    const prefix_width: u16 = @intCast(@min(primitive.text.displayWidth(prefix), frame_width));
    var line_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    const line_row_count = collectWrappedTranscriptLine(&line_rows, line, frame_width, prefix_width);
    var remaining = if (skip_newest_rows < line_row_count) line_row_count - skip_newest_rows else 0;

    while (remaining > 0 and row_count.* < row_limit) {
        remaining -= 1;
        rows[row_count.*] = line_rows[remaining];
        row_count.* += 1;
    }
}

fn countWrappedTranscriptRows(line: transcript_mod.TranscriptLine, frame_width: u16) usize {
    const prefix = rolePrefix(line.role);
    const prefix_width: u16 = @intCast(@min(primitive.text.displayWidth(prefix), frame_width));
    var line_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    return collectWrappedTranscriptLine(&line_rows, line, frame_width, prefix_width);
}

fn collectWrappedTranscriptLine(
    line_rows: *[transcript_visual_rows_max]TranscriptVisualRow,
    line: transcript_mod.TranscriptLine,
    frame_width: u16,
    prefix_width: u16,
) usize {
    var line_row_count: usize = 0;
    var start: usize = 0;
    var visual_index: usize = 0;
    while (start < line.text.len and line_row_count < line_rows.len) : (visual_index += 1) {
        const width = if (visual_index == 0) frame_width - prefix_width else frame_width;
        if (width == 0) {
            line_rows[line_row_count] = .{ .role = line.role, .text = "", .show_prefix = visual_index == 0 };
            line_row_count += 1;
            continue;
        }
        const visual = primitive.text.nextVisualLine(line.text, start, width);
        if (visual.end == start) break;
        line_rows[line_row_count] = .{
            .role = line.role,
            .text = line.text[visual.start..visual.end],
            .show_prefix = visual_index == 0,
        };
        line_row_count += 1;
        start = visual.end;
    }
    if (line.text.len == 0 and line_row_count < line_rows.len) {
        line_rows[line_row_count] = .{ .role = line.role, .text = "", .show_prefix = true };
        line_row_count += 1;
    }
    return line_row_count;
}

fn rolePrefix(role: transcript_mod.TranscriptRole) []const u8 {
    return switch (role) {
        .user => "user: ",
        .assistant => "assistant: ",
        .system => "system: ",
    };
}

pub fn checkSize(width: u16, height: u16) !void {
    const count = @as(usize, width) * height;
    if (count == 0) return error.EmptyFrame;
    if (count > size_cells_max) return error.FrameTooLarge;
}

test "frame rejects impossible sizes" {
    try std.testing.expectError(error.EmptyFrame, checkSize(0, 24));
    try std.testing.expectError(error.FrameTooLarge, checkSize(1000, 1000));
}

fn expectCellText(buffer: anytype, x: u16, y: u16, text: []const u8) !void {
    for (text, 0..) |byte, index| {
        const cell = try buffer.get(@intCast(@as(usize, x) + index), y);
        try std.testing.expectEqual(@as(?u21, byte), cell.renderScalar());
    }
}

test "frame renders newest transcript lines and preserves composer row" {
    var app = try app_mod.ProductApp.init(40, 5);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "old" });
    try app.transcript.append(std.testing.allocator, .{ .role = .user, .text = "one" });
    try app.transcript.append(std.testing.allocator, .{ .role = .assistant, .text = "two" });
    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "three" });
    try app.composer.insertUtf8(std.testing.allocator, "draft");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 5, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectCellText(renderer.next, 0, 0, "zi");
    try expectCellText(renderer.next, 0, 1, "user: one");
    try expectCellText(renderer.next, 0, 2, "assistant: two");
    try expectCellText(renderer.next, 0, 3, "system: three");
    try expectCellText(renderer.next, 0, 4, "> draft");

    const absent = try renderer.next.get(0, 1);
    try std.testing.expect(absent.renderScalar() != 'o');
}

test "frame keeps transcript out of tiny heights" {
    var app = try app_mod.ProductApp.init(20, 1);
    defer app.deinit(std.testing.allocator);
    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "hidden" });

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 1, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);
    try expectCellText(renderer.next, 0, 0, "> ");
}

test "frame renders transcript scrolled by newest visual rows" {
    var app = try app_mod.ProductApp.init(40, 5);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "old" });
    try app.transcript.append(std.testing.allocator, .{ .role = .user, .text = "one" });
    try app.transcript.append(std.testing.allocator, .{ .role = .assistant, .text = "two" });
    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "three" });
    app.transcript_scroll_rows = 1;

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 5, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectCellText(renderer.next, 0, 1, "system: old");
    try expectCellText(renderer.next, 0, 2, "user: one");
    try expectCellText(renderer.next, 0, 3, "assistant: two");
}
