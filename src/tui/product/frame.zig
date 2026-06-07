const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");
const app_mod = @import("App.zig");
const transcript_mod = @import("transcript.zig");
const theme_mod = @import("theme.zig");
const transcript_projection = @import("transcript_projection.zig");

pub const size_cells_max: usize = 65_536;
const transcript_visual_rows_max: usize = 512;
const transcript_item_padding_x: u16 = 1;
const transcript_item_margin_bottom: usize = 1;
const generated_row_text_bytes_max: usize = 128;
const tool_notice_bytes_max: usize = 96;
const tool_chrome_line_bytes_max: usize = 160;

const TranscriptVisualRow = struct {
    prefix: []const u8,
    text: []const u8,
    show_prefix: bool,
    style: primitive.Style = .{},
    storage: [generated_row_text_bytes_max]u8 = undefined,
};

pub const Frame = struct {
    width: u16,
    height: u16,

    pub fn build(app: *app_mod.ProductApp, renderer: *infra.Renderer) !void {
        app.clampTranscriptScroll();
        if (renderer.next.width != app.width or renderer.next.height != app.height) {
            try renderer.resize(app.width, app.height);
        }
        renderer.next.clear();
        try drawShell(app, renderer);
    }
};

fn drawShell(app: *const app_mod.ProductApp, renderer: *infra.Renderer) !void {
    if (app.height > 0) try renderer.writeText(0, 0, "zi", app.theme.shell_label);
    if (app.height > 0) {
        try drawTranscript(app, renderer, app.theme.transcript_text, transcriptVisibleRows(app.height));
    }
    if (app.height > 0) {
        const composer_y = app.height - 1;
        try renderer.writeText(0, composer_y, "> ", app.theme.composer_prompt);
        if (app.width > 2) try renderer.writeText(2, composer_y, app.composer.text(), app.theme.composer_text);
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
        emitItemRowsNewestFirst(&sink, transcript.items.items[item_index], width, null);
    }
    return if (sink.total_emitted > visible_rows) sink.total_emitted - visible_rows else 0;
}

fn drawTranscript(app: *const app_mod.ProductApp, renderer: *infra.Renderer, _: primitive.Style, visible_rows: usize) !void {
    if (visible_rows == 0 or app.width == 0) return;
    const row_limit = @min(visible_rows, transcript_visual_rows_max);
    var rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var sink = TranscriptRowSink.store(&rows, row_limit, app.transcript_scroll_rows);

    var item_index = app.transcript.items.items.len;
    while (item_index > 0 and sink.row_count < row_limit) {
        item_index -= 1;
        emitItemRowsNewestFirst(&sink, app.transcript.items.items[item_index], app.width, &app.theme);
    }

    var draw_index = sink.row_count;
    var y: u16 = 1;
    while (draw_index > 0) : (y += 1) {
        draw_index -= 1;
        const row = rows[draw_index];
        try renderer.fillRect(0, y, renderer.next.width, 1, row.style);
        const text_origin = @min(transcript_item_padding_x, renderer.next.width);
        if (row.show_prefix) {
            try renderer.writeText(text_origin, y, row.prefix, row.style);
            const text_x = text_origin + primitive.text.displayWidth(row.prefix);
            if (text_x < renderer.next.width and row.text.len > 0) {
                try renderer.writeText(@intCast(text_x), y, row.text, row.style);
            }
        } else {
            try renderer.writeText(text_origin, y, row.text, row.style);
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
        style: primitive.Style,
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
            slot.style = style;
            self.row_count += 1;
        }
    }
};

fn emitItemRowsNewestFirst(
    sink: *TranscriptRowSink,
    item: transcript_mod.TranscriptItem,
    frame_width: u16,
    theme: ?*const theme_mod.Theme,
) void {
    const style = transcriptItemStyle(item, theme);
    // Transcript spacing has two concepts: padding is inside an item and uses
    // the item style; margin is between items and always uses default style.
    // Both are emitted as visual rows so scroll/count/draw stay identical.
    // Do not add adjacent-item collapse rules here; every item emits the same
    // trailing margin unless product policy changes explicitly.
    emitMarginBottomRows(sink);
    emitVerticalPaddingRows(sink, transcriptItemPaddingY(item), style);
    if (item == .tool) {
        emitToolRowsNewestFirst(sink, item.tool, frame_width, theme);
    } else {
        emitWrappedRowsNewestFirst(sink, transcript_projection.itemPrimary(item), frame_width, false, style);
    }
    emitVerticalPaddingRows(sink, transcriptItemPaddingY(item), style);
}

fn transcriptItemPaddingY(item: transcript_mod.TranscriptItem) usize {
    return switch (item) {
        .message => |message| if (message.role == .user) 1 else 0,
        else => 0,
    };
}

fn emitMarginBottomRows(sink: *TranscriptRowSink) void {
    var index: usize = 0;
    while (index < transcript_item_margin_bottom) : (index += 1) sink.emitGenerated("", "", false, .{});
}

fn emitVerticalPaddingRows(sink: *TranscriptRowSink, count: usize, style: primitive.Style) void {
    var index: usize = 0;
    while (index < count) : (index += 1) sink.emitGenerated("", "", false, style);
}

fn emitToolRowsNewestFirst(
    sink: *TranscriptRowSink,
    tool: transcript_mod.TranscriptTool,
    frame_width: u16,
    theme: ?*const theme_mod.Theme,
) void {
    const fallback = theme_mod.Theme.codex();
    const resolved = theme orelse &fallback;

    const block: primitive.chrome.OpenBlock = .{};
    var bottom_buffer: [tool_chrome_line_bytes_max]u8 = undefined;
    const bottom = block.bottomLine(&bottom_buffer) catch "╰────";
    sink.emitGenerated("", bottom, false, resolved.tool_chrome);
    if (sink.full()) return;

    const projected = transcript_projection.itemPrimary(.{ .tool = tool });
    if (transcript_projection.toolBodyVisible(tool)) {
        emitWrappedRowsNewestFirst(sink, .{ .prefix = block.bodyPrefix(), .text = projected.text }, frame_width, true, resolved.tool_output);
        if (sink.full()) return;
    }
    if (tool.call_preview.len > 0) {
        emitWrappedRowsNewestFirst(sink, .{ .prefix = block.bodyPrefix(), .text = tool.call_preview }, frame_width, true, resolved.tool_output);
        if (sink.full()) return;
    }

    var notice_buffer: [tool_notice_bytes_max]u8 = undefined;
    if (transcript_projection.toolOmissionNotice(tool, &notice_buffer)) |notice| {
        emitWrappedRowsNewestFirst(sink, .{ .prefix = block.bodyPrefix(), .text = notice }, frame_width, true, resolved.tool_chrome);
        if (sink.full()) return;
    }

    var title_buffer: [tool_chrome_line_bytes_max]u8 = undefined;
    const title = transcript_projection.toolTitle(tool, &title_buffer);
    sink.emitGenerated("", title, false, resolved.tool_title);
}

fn emitWrappedRowsNewestFirst(
    sink: *TranscriptRowSink,
    item: transcript_projection.RenderItem,
    frame_width: u16,
    repeat_prefix: bool,
    style: primitive.Style,
) void {
    const inner_width = transcriptItemInnerWidth(frame_width);
    const prefix_width: u16 = @intCast(@min(primitive.text.displayWidth(item.prefix), inner_width));
    var line_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    const line_row_count = collectWrappedTranscriptLine(
        &line_rows,
        item,
        inner_width,
        prefix_width,
        repeat_prefix,
        style,
    );
    var remaining = line_row_count;
    while (remaining > 0) {
        remaining -= 1;
        sink.emitBorrowed(line_rows[remaining]);
        if (sink.full()) return;
    }
}

fn transcriptItemInnerWidth(frame_width: u16) u16 {
    const padding_width = transcript_item_padding_x * 2;
    if (frame_width <= padding_width) return 0;
    return frame_width - padding_width;
}

fn transcriptItemStyle(item: transcript_mod.TranscriptItem, theme: ?*const theme_mod.Theme) primitive.Style {
    if (theme) |resolved| return transcriptItemStyleFromTheme(item, resolved);
    const fallback = theme_mod.Theme.codex();
    return transcriptItemStyleFromTheme(item, &fallback);
}

fn transcriptItemStyleFromTheme(item: transcript_mod.TranscriptItem, theme: *const theme_mod.Theme) primitive.Style {
    return switch (item) {
        .message => |message| switch (message.role) {
            .user => theme.transcript_user,
            .assistant => theme.transcript_text,
            .system, .thinking => theme.transcript_secondary,
        },
        .status => |status| switch (status.level) {
            .info => theme.status_accent,
            .warning => theme.status_warning,
            .err => theme.status_error,
        },
        .tool => theme.tool_chrome,
    };
}

fn collectWrappedTranscriptLine(
    line_rows: *[transcript_visual_rows_max]TranscriptVisualRow,
    item: transcript_projection.RenderItem,
    inner_width: u16,
    prefix_width: u16,
    repeat_prefix: bool,
    style: primitive.Style,
) usize {
    var line_row_count: usize = 0;
    var start: usize = 0;
    var visual_index: usize = 0;
    while (start < item.text.len and line_row_count < line_rows.len) : (visual_index += 1) {
        const width = if (visual_index == 0) inner_width - prefix_width else inner_width;
        if (width == 0) {
            line_rows[line_row_count] = .{
                .prefix = item.prefix,
                .text = "",
                .show_prefix = repeat_prefix or visual_index == 0,
                .style = style,
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
            .style = style,
        };
        line_row_count += 1;
        start = visual.next;
    }
    if (item.text.len == 0 and line_row_count < line_rows.len) {
        line_rows[line_row_count] = .{ .prefix = item.prefix, .text = "", .show_prefix = true, .style = style };
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
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 0, 0, "zi");
    try expectCellText(renderer.next, 1, 2, "system: three");
    try expectCellText(renderer.next, 0, 4, "> draft");

    const absent = try renderer.next.get(0, 1);
    try std.testing.expect(absent.renderScalar() != 'o');
}

test "frame renders user messages without label and fills background" {
    var app = try app_mod.ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .user, "hello");

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 5, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "hello");
    try std.testing.expect((try renderer.next.get(0, 1)).style.eql(app.theme.transcript_user));
    try std.testing.expect((try renderer.next.get(19, 1)).style.eql(app.theme.transcript_user));
}

test "frame renders assistant messages without label and transparent background" {
    var app = try app_mod.ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .assistant, "hello");

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 5, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "hello");
    try std.testing.expect((try renderer.next.get(0, 1)).style.eql(app.theme.transcript_text));
}

test "frame keeps transcript out of tiny heights" {
    var app = try app_mod.ProductApp.init(20, 1);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .system, "hidden");

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 1, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);
    try expectCellText(renderer.next, 0, 0, "> ");
}

test "frame renders transcript hard newlines as visual rows" {
    var app = try app_mod.ProductApp.init(40, 6);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .assistant, "one\ntwo\n\nthree");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "two");
    const blank = try renderer.next.get(1, 2);
    try std.testing.expectEqual(@as(?u21, null), blank.renderScalar());
    try expectCellText(renderer.next, 1, 3, "three");
}

test "frame scroll max counts hard newline visual rows" {
    var app = try app_mod.ProductApp.init(40, 5);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .assistant, "one\ntwo\nthree\nfour");
    try std.testing.expectEqual(
        @as(usize, 2),
        transcriptScrollMax(app.transcript, app.width, transcriptVisibleRows(app.height)),
    );
}

test "frame renders typed tool rows with name and state" {
    var app = try app_mod.ProductApp.init(40, 12);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-2",
        .name = "read",
        .status = .success,
    } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 12, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "bash");
    try expectCellText(renderer.next, 1, 4, "read");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(1, 1)).style.eql(app.theme.tool_title));
}

test "frame renders tool display text when present" {
    var app = try app_mod.ProductApp.init(60, 8);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
        .presentation = .command,
        .title = "zig build test",
    } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 60, 8, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "bash: zig build test");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(1, 1)).style.eql(app.theme.tool_title));
}

test "frame renders tool title bold and tool output dim" {
    var app = try app_mod.ProductApp.init(40, 10);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try app.transcript.appendToolOutput(std.testing.allocator, "call-1", "out", 0, 0);

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 10, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "bash");
    try expectCellText(renderer.next, 3, 2, "out");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(1, 1)).style.eql(app.theme.tool_title));
    try std.testing.expect((try renderer.next.get(3, 2)).style.eql(app.theme.tool_output));
}

test "tool visual row count includes chrome output and omission notice" {
    var app = try app_mod.ProductApp.init(40, 4);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try app.transcript.appendToolOutput(std.testing.allocator, "call-1", "one\ntwo", 0, 3);

    try std.testing.expectEqual(@as(usize, 5), transcriptScrollMax(app.transcript, app.width, 1));
    try std.testing.expectEqual(@as(usize, 4), transcriptScrollMax(app.transcript, app.width, 2));
}

test "tool scroll skips newest row before tool block" {
    var app = try app_mod.ProductApp.init(40, 4);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try app.transcript.appendToolOutput(std.testing.allocator, "call-1", "one\ntwo", 0, 0);
    app.transcript_scroll_rows = 1;

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 4, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellGrapheme(renderer.next, 3, 2, "─");
}

test "frame renders updated tool row once" {
    var app = try app_mod.ProductApp.init(40, 6);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .presentation = .command,
        .status = .success,
    } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try std.testing.expectEqual(@as(usize, 1), app.transcript.items.items.len);
    try expectCellText(renderer.next, 1, 1, "bash");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(1, 1)).style.eql(app.theme.tool_title));
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
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 3, "system: three");
}
