const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");
const app_mod = @import("App.zig");
const transcript_mod = @import("transcript.zig");

pub const size_cells_max: usize = 500_000;
const transcript_visual_rows_max: usize = 512;

const TranscriptRenderItem = struct {
    prefix: []const u8,
    text: []const u8,
};

const TranscriptVisualRow = struct {
    prefix: []const u8,
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
    for (transcript.items.items) |item| total_rows += countWrappedTranscriptRows(renderItem(item), width);
    return if (total_rows > visible_rows) total_rows - visible_rows else 0;
}

fn drawTranscript(app: anytype, renderer: *infra.Renderer, style: primitive.Style, visible_rows: usize) !void {
    if (visible_rows == 0 or app.width == 0) return;
    const row_limit = @min(visible_rows, transcript_visual_rows_max);
    var rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var row_count: usize = 0;
    var skipped_rows: usize = 0;

    var line_index = app.transcript.items.items.len;
    while (line_index > 0 and row_count < row_limit) {
        line_index -= 1;
        const item = renderItem(app.transcript.items.items[line_index]);
        const line_rows = countWrappedTranscriptRows(item, app.width);
        if (skipped_rows + line_rows <= app.transcript_scroll_rows) {
            skipped_rows += line_rows;
            continue;
        }
        appendWrappedTranscriptLine(
            &rows,
            &row_count,
            row_limit,
            item,
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
            try renderer.writeText(0, y, row.prefix, style);
            const text_x = primitive.text.displayWidth(row.prefix);
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
    item: TranscriptRenderItem,
    frame_width: u16,
    skip_newest_rows: usize,
) void {
    const prefix_width: u16 = @intCast(@min(primitive.text.displayWidth(item.prefix), frame_width));
    var line_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    const line_row_count = collectWrappedTranscriptLine(&line_rows, item, frame_width, prefix_width);
    var remaining = if (skip_newest_rows < line_row_count) line_row_count - skip_newest_rows else 0;

    while (remaining > 0 and row_count.* < row_limit) {
        remaining -= 1;
        rows[row_count.*] = line_rows[remaining];
        row_count.* += 1;
    }
}

fn countWrappedTranscriptRows(item: TranscriptRenderItem, frame_width: u16) usize {
    const prefix_width: u16 = @intCast(@min(primitive.text.displayWidth(item.prefix), frame_width));
    var line_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    return collectWrappedTranscriptLine(&line_rows, item, frame_width, prefix_width);
}

fn collectWrappedTranscriptLine(
    line_rows: *[transcript_visual_rows_max]TranscriptVisualRow,
    item: TranscriptRenderItem,
    frame_width: u16,
    prefix_width: u16,
) usize {
    var line_row_count: usize = 0;
    var start: usize = 0;
    var visual_index: usize = 0;
    while (start < item.text.len and line_row_count < line_rows.len) : (visual_index += 1) {
        const width = if (visual_index == 0) frame_width - prefix_width else frame_width;
        if (width == 0) {
            line_rows[line_row_count] = .{ .prefix = item.prefix, .text = "", .show_prefix = visual_index == 0 };
            line_row_count += 1;
            continue;
        }
        const visual = primitive.text.nextVisualLineBreak(item.text, start, width);
        if (visual.next == start) break;
        line_rows[line_row_count] = .{
            .prefix = item.prefix,
            .text = item.text[visual.start..visual.end],
            .show_prefix = visual_index == 0,
        };
        line_row_count += 1;
        start = visual.next;
    }
    if (item.text.len == 0 and line_row_count < line_rows.len) {
        line_rows[line_row_count] = .{ .prefix = item.prefix, .text = "", .show_prefix = true };
        line_row_count += 1;
    }
    return line_row_count;
}

fn renderItem(item: transcript_mod.TranscriptItem) TranscriptRenderItem {
    return switch (item) {
        .message => |message| .{ .prefix = rolePrefix(message.role), .text = message.text },
        .status => |status| .{ .prefix = statusPrefix(status.level), .text = status.text },
        .tool => |tool| .{ .prefix = "tool: ", .text = toolSummary(tool) },
    };
}

fn rolePrefix(role: transcript_mod.TranscriptRole) []const u8 {
    return switch (role) {
        .user => "user: ",
        .assistant => "assistant: ",
        .system => "system: ",
    };
}

fn statusPrefix(level: transcript_mod.TranscriptStatusLevel) []const u8 {
    return switch (level) {
        .info => "status: ",
        .warning => "warning: ",
        .err => "error: ",
    };
}

fn toolSummary(tool: transcript_mod.TranscriptTool) []const u8 {
    if (tool.summary.len > 0) return tool.summary;
    return switch (tool.status) {
        .started => "started",
        .completed => "completed",
        .failed => "failed",
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

fn appendFrameMessage(
    app: *app_mod.ProductApp,
    role: transcript_mod.TranscriptRole,
    text: []const u8,
) !void {
    try app.transcript.append(std.testing.allocator, .{
        .message = .{ .role = role, .text = text },
    });
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

    try appendFrameMessage(&app, .system, "old");
    try appendFrameMessage(&app, .user, "one");
    try appendFrameMessage(&app, .assistant, "two");
    try appendFrameMessage(&app, .system, "three");
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
    try appendFrameMessage(&app, .system, "hidden");

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 1, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);
    try expectCellText(renderer.next, 0, 0, "> ");
}

test "frame renders transcript hard newlines as visual rows" {
    var app = try app_mod.ProductApp.init(40, 6);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .assistant, "one\ntwo\n\nthree");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectCellText(renderer.next, 0, 1, "assistant: one");
    try expectCellText(renderer.next, 0, 2, "two");
    const blank = try renderer.next.get(0, 3);
    try std.testing.expectEqual(@as(?u21, null), blank.renderScalar());
    try expectCellText(renderer.next, 0, 4, "three");
}

test "frame scroll max counts hard newline visual rows" {
    var app = try app_mod.ProductApp.init(40, 5);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .assistant, "one\ntwo\nthree\nfour");
    try std.testing.expectEqual(
        @as(usize, 1),
        transcriptScrollMax(app.transcript, app.width, transcriptVisibleRows(app.height)),
    );
}

test "frame renders transcript scrolled by newest visual rows" {
    var app = try app_mod.ProductApp.init(40, 5);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .system, "old");
    try appendFrameMessage(&app, .user, "one");
    try appendFrameMessage(&app, .assistant, "two");
    try appendFrameMessage(&app, .system, "three");
    app.transcript_scroll_rows = 1;

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 5, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectCellText(renderer.next, 0, 1, "system: old");
    try expectCellText(renderer.next, 0, 2, "user: one");
    try expectCellText(renderer.next, 0, 3, "assistant: two");
}
