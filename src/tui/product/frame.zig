const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");
const app_mod = @import("App.zig");
const transcript_mod = @import("transcript.zig");
const transcript_projection = @import("transcript_projection.zig");

pub const size_cells_max: usize = 65_536;
const transcript_visual_rows_max: usize = 512;

const TranscriptVisualRow = struct {
    prefix: []const u8,
    text: []const u8,
    show_prefix: bool,
    storage: [128]u8 = undefined,
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
    var sink = TranscriptRowSink.countOnly();
    var item_index = transcript.items.items.len;
    while (item_index > 0) {
        item_index -= 1;
        emitItemRowsNewestFirst(&sink, transcript.items.items[item_index], width);
    }
    return if (sink.total_emitted > visible_rows) sink.total_emitted - visible_rows else 0;
}

fn drawTranscript(app: anytype, renderer: *infra.Renderer, style: primitive.Style, visible_rows: usize) !void {
    if (visible_rows == 0 or app.width == 0) return;
    const row_limit = @min(visible_rows, transcript_visual_rows_max);
    var rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var sink = TranscriptRowSink.store(&rows, row_limit, app.transcript_scroll_rows);

    var item_index = app.transcript.items.items.len;
    while (item_index > 0 and sink.row_count < row_limit) {
        item_index -= 1;
        emitItemRowsNewestFirst(&sink, app.transcript.items.items[item_index], app.width);
    }

    var draw_index = sink.row_count;
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

// Transcript scroll and rendering have one invariant: visual-row accounting and
// drawing must consume the same newest-first row stream.  Source transcript items
// may contain physical newlines, wrapping, and generated tool chrome, but scroll
// offsets are always measured after projection into visual rows.  Keep generated
// rows and wrapped text rows flowing through this sink so count-only and render
// modes cannot drift.
const TranscriptRowSink = struct {
    rows: ?*[transcript_visual_rows_max]TranscriptVisualRow,
    row_limit: usize,
    row_count: usize = 0,
    skip_remaining: usize = 0,
    total_emitted: usize = 0,

    fn countOnly() TranscriptRowSink {
        return .{ .rows = null, .row_limit = 0 };
    }

    fn store(
        rows: *[transcript_visual_rows_max]TranscriptVisualRow,
        row_limit: usize,
        skip_newest_rows: usize,
    ) TranscriptRowSink {
        return .{ .rows = rows, .row_limit = row_limit, .skip_remaining = skip_newest_rows };
    }

    fn full(self: TranscriptRowSink) bool {
        return self.rows != null and self.row_count >= self.row_limit;
    }

    fn emitBorrowed(self: *TranscriptRowSink, row: TranscriptVisualRow) void {
        self.total_emitted += 1;
        if (self.skip_remaining > 0) {
            self.skip_remaining -= 1;
            return;
        }
        if (self.rows) |rows| {
            if (self.row_count >= self.row_limit) return;
            rows[self.row_count] = row;
            self.row_count += 1;
        }
    }

    fn emitGenerated(
        self: *TranscriptRowSink,
        prefix: []const u8,
        text: []const u8,
        show_prefix: bool,
    ) void {
        self.total_emitted += 1;
        if (self.skip_remaining > 0) {
            self.skip_remaining -= 1;
            return;
        }
        if (self.rows) |rows| {
            if (self.row_count >= self.row_limit) return;
            const slot = &rows[self.row_count];
            const keep = @min(text.len, slot.storage.len);
            @memcpy(slot.storage[0..keep], text[0..keep]);
            slot.prefix = prefix;
            slot.text = slot.storage[0..keep];
            slot.show_prefix = show_prefix;
            self.row_count += 1;
        }
    }
};

fn emitItemRowsNewestFirst(
    sink: *TranscriptRowSink,
    item: transcript_mod.TranscriptItem,
    frame_width: u16,
) void {
    if (item == .tool) {
        emitToolRowsNewestFirst(sink, item.tool, frame_width);
        return;
    }
    emitWrappedRowsNewestFirst(sink, transcript_projection.itemPrimary(item), frame_width, false);
}

fn emitToolRowsNewestFirst(
    sink: *TranscriptRowSink,
    tool: transcript_mod.TranscriptTool,
    frame_width: u16,
) void {
    sink.emitGenerated("", "╰────", false);
    if (sink.full()) return;

    const projected = transcript_projection.itemPrimary(.{ .tool = tool });
    if (projected.text.len > 0) {
        emitWrappedRowsNewestFirst(sink, .{ .prefix = "│ ", .text = projected.text }, frame_width, true);
        if (sink.full()) return;
    }

    var notice_buffer: [96]u8 = undefined;
    if (transcript_projection.toolOmissionNotice(tool, &notice_buffer)) |notice| {
        emitWrappedRowsNewestFirst(sink, .{ .prefix = "│ ", .text = notice }, frame_width, true);
        if (sink.full()) return;
    }

    var title_buffer: [128]u8 = undefined;
    const title = transcript_projection.toolTitle(tool, &title_buffer);
    var top_buffer: [160]u8 = undefined;
    const top = primitive.chrome.openTopLine(&top_buffer, .rounded, title) catch "╭─[tool]";
    sink.emitGenerated("", top, false);
}

fn emitWrappedRowsNewestFirst(
    sink: *TranscriptRowSink,
    item: transcript_projection.RenderItem,
    frame_width: u16,
    repeat_prefix: bool,
) void {
    const prefix_width: u16 = @intCast(@min(primitive.text.displayWidth(item.prefix), frame_width));
    var line_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    const line_row_count = collectWrappedTranscriptLine(&line_rows, item, frame_width, prefix_width, repeat_prefix);
    var remaining = line_row_count;
    while (remaining > 0) {
        remaining -= 1;
        sink.emitBorrowed(line_rows[remaining]);
        if (sink.full()) return;
    }
}

fn collectWrappedTranscriptLine(
    line_rows: *[transcript_visual_rows_max]TranscriptVisualRow,
    item: transcript_projection.RenderItem,
    frame_width: u16,
    prefix_width: u16,
    repeat_prefix: bool,
) usize {
    var line_row_count: usize = 0;
    var start: usize = 0;
    var visual_index: usize = 0;
    while (start < item.text.len and line_row_count < line_rows.len) : (visual_index += 1) {
        const width = if (visual_index == 0) frame_width - prefix_width else frame_width;
        if (width == 0) {
            line_rows[line_row_count] = .{
                .prefix = item.prefix,
                .text = "",
                .show_prefix = repeat_prefix or visual_index == 0,
            };
            line_row_count += 1;
            continue;
        }
        const visual = primitive.text.nextVisualLineBreak(item.text, start, width);
        if (visual.next == start) break;
        line_rows[line_row_count] = .{
            .prefix = item.prefix,
            .text = item.text[visual.start..visual.end],
            .show_prefix = repeat_prefix or visual_index == 0,
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

fn expectCellGrapheme(buffer: anytype, x: u16, y: u16, text: []const u8) !void {
    const cell = try buffer.get(x, y);
    const rendered = cell.renderText() orelse return error.MissingCell;
    try std.testing.expectEqualStrings(text, rendered.slice());
}

fn expectGraphemeInColumn(buffer: anytype, x: u16, text: []const u8) !void {
    var y: u16 = 0;
    while (y < buffer.height) : (y += 1) {
        const cell = try buffer.get(x, y);
        const rendered = cell.renderText() orelse continue;
        if (std.mem.eql(u8, text, rendered.slice())) return;
    }
    return error.MissingCell;
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

test "frame renders typed tool rows with name and state" {
    var app = try app_mod.ProductApp.init(40, 12);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .event = .tool_execution_start,
    } });
    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-2",
        .name = "read",
        .event = .tool_execution_end,
    } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 12, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectGraphemeInColumn(renderer.next, 0, "╭");
    try expectCellText(renderer.next, 2, 1, "[bash]");
    try expectCellText(renderer.next, 2, 3, "[read]");
}

test "frame renders tool display text when present" {
    var app = try app_mod.ProductApp.init(60, 6);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .event = .tool_execution_start,
        .args_preview = "zig build test",
    } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 60, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectGraphemeInColumn(renderer.next, 0, "╭");
    try expectCellText(renderer.next, 2, 1, "[bash zig build test]");
}

test "tool visual row count includes chrome output and omission notice" {
    var app = try app_mod.ProductApp.init(40, 4);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .event = .tool_execution_start,
    } });
    try app.transcript.appendToolOutput(std.testing.allocator, "call-1", "one\ntwo", 0, 3);

    try std.testing.expectEqual(@as(usize, 4), transcriptScrollMax(app.transcript, app.width, 1));
    try std.testing.expectEqual(@as(usize, 3), transcriptScrollMax(app.transcript, app.width, 2));
}

test "tool scroll skips newest rows once across whole block" {
    var app = try app_mod.ProductApp.init(40, 4);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .event = .tool_execution_start,
    } });
    try app.transcript.appendToolOutput(std.testing.allocator, "call-1", "one\ntwo", 0, 0);
    app.transcript_scroll_rows = 1;

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 4, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectCellText(renderer.next, 2, 1, "one");
    try expectCellText(renderer.next, 2, 2, "two");
}

test "frame renders updated tool row once" {
    var app = try app_mod.ProductApp.init(40, 6);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .event = .tool_execution_start,
    } });
    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .event = .tool_execution_end,
    } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try std.testing.expectEqual(@as(usize, 1), app.transcript.items.items.len);
    try expectGraphemeInColumn(renderer.next, 0, "╭");
    try expectCellText(renderer.next, 2, 1, "[bash]");
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
