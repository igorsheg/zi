const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");
const app_mod = @import("App.zig");
const composer_mod = @import("composer.zig");
const markdown_projection = @import("markdown_projection.zig");
const slots_mod = @import("slots.zig");
const status_area = @import("status_area.zig");
const surface_mod = @import("surface.zig");
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
    suffix: []const u8 = "",
    show_prefix: bool,
    prefix_style: primitive.Style = .{},
    text_style: primitive.Style = .{},
    suffix_style: primitive.Style = .{},
    row_style: primitive.Style = .{},
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
        renderer.clearCursor();
        if (app.height > 0) try renderer.writeText(0, 0, "zi", app.theme.shell_label);
        const composer_rows = composerRows(app);
        const status_rows = statusRows(app);
        if (app.height > 0) {
            try drawTranscript(
                app,
                renderer,
                app.theme.transcript_text,
                transcriptVisibleRowsWithReserved(app.height, composer_rows + status_rows),
            );
            if (status_rows > 0 and app.height > composer_rows) {
                var views: [slots_mod.status_area_slot_count_max]slots_mod.SlotView = undefined;
                const count = app.slots.orderedSlot(.status_area, &views);
                if (count > 0) {
                    const y: u16 = @intCast(@as(usize, app.height) - composer_rows - 1);
                    try status_area.draw(renderer, app.theme, y, app.width, views[0..count], app.animation_tick);
                }
            }
            try drawComposer(app, renderer, composer_rows);
        }
        if (app.modal) |confirm| try drawConfirmModal(app, renderer, confirm);
    }
};

pub fn transcriptVisibleRows(height: u16) usize {
    return transcriptVisibleRowsWithReserved(height, 1);
}

pub fn transcriptVisibleRowsWithReserved(height: u16, reserved_rows: usize) usize {
    if (height == 0) return 0;
    const body_rows = height - 1;
    const reserved = @min(reserved_rows, body_rows);
    const available_rows = body_rows - reserved;
    return @min(available_rows, transcript_visual_rows_max);
}

pub fn statusRows(app: *app_mod.ProductApp) usize {
    return status_area.visibleRows(
        app.slots.count(.status_area) > 0,
        app.height,
        composerRows(app),
    );
}

pub fn composerRows(app: *app_mod.ProductApp) usize {
    const text_width = composerTextWidth(app.width);
    return @min(app.composer.visualRows(text_width), composer_mod.visible_rows_max) + 2;
}

fn composerTextWidth(width: u16) u16 {
    return if (width > 4) width - 4 else 1;
}

fn drawComposer(app: *app_mod.ProductApp, renderer: *infra.Renderer, composer_rows: usize) !void {
    if (composer_rows < 3 or app.height == 0 or app.width == 0) return;
    const height = @min(composer_rows, @as(usize, app.height));
    if (height < 3) return;
    const box_y: u16 = @intCast(@as(usize, app.height) - height);
    const box_height: u16 = @intCast(height);
    try drawComposerBorder(app, renderer, box_y, box_height);

    var rows: [composer_mod.visible_rows_max]composer_mod.ComposerVisualRow = undefined;
    const projection = app.composer.visibleRows(composerTextWidth(app.width), &rows);
    const visible_count = @min(projection.visible_count, height - 2);
    var index: usize = 0;
    while (index < visible_count) : (index += 1) {
        const y: u16 = @intCast(@as(usize, box_y) + 1 + index);
        try renderer.writeText(1, y, "> ", app.theme.composer_prompt);
        if (app.width > 3) try renderer.writeText(3, y, rows[index].text, app.theme.composer_text);
    }
    if (app.modal == null and projection.cursor_visible) {
        const cursor_y = @as(usize, box_y) + 1 + projection.cursor_visible_row;
        const cursor_x = 3 + projection.cursor_display_col;
        if (cursor_x < app.width and cursor_y < app.height) {
            renderer.setCursor(.{ .x = @intCast(cursor_x), .y = @intCast(cursor_y) });
        }
    }
}

fn drawComposerBorder(
    app: *const app_mod.ProductApp,
    renderer: *infra.Renderer,
    y: u16,
    height: u16,
) !void {
    if (app.width < 2 or height < 2) return;
    try drawComposerBorderLine(app, renderer, y, true);
    if (app.width >= 4) {
        const inner_width = app.width - 2;
        if (app.slots.highestPriority(.composer_top_right)) |view| {
            const label_width = primitive.text.displayWidth(view.text);
            if (inner_width >= 2 + label_width) {
                const x = @as(usize, app.width) - 2 - label_width;
                try renderer.writeText(@intCast(x), y, view.text, app.theme.composer_slot);
            }
        }
    }
    try drawComposerBorderLine(app, renderer, y + height - 1, false);
    var row: u16 = y + 1;
    while (row + 1 < y + height) : (row += 1) {
        try renderer.writeText(0, row, primitive.chrome.BorderGlyphs.rounded.vertical, app.theme.composer_chrome);
        if (app.width > 1) {
            try renderer.writeText(
                app.width - 1,
                row,
                primitive.chrome.BorderGlyphs.rounded.vertical,
                app.theme.composer_chrome,
            );
        }
    }
}

fn drawComposerBorderLine(
    app: *const app_mod.ProductApp,
    renderer: *infra.Renderer,
    y: u16,
    top: bool,
) !void {
    const glyphs = primitive.chrome.BorderGlyphs.rounded;
    const left_corner = if (top) glyphs.top_left else glyphs.bottom_left;
    const right_corner = if (top) glyphs.top_right else glyphs.bottom_right;
    try renderer.writeText(0, y, left_corner, app.theme.composer_chrome);
    if (app.width > 1) try renderer.writeText(app.width - 1, y, right_corner, app.theme.composer_chrome);
    if (app.width > 2) {
        try primitive.chrome.drawHorizontalLine(
            &renderer.next,
            1,
            y,
            app.width - 2,
            glyphs.horizontal,
            app.theme.composer_chrome,
        );
    }
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

fn drawConfirmModal(app: *const app_mod.ProductApp, renderer: *infra.Renderer, confirm: surface_mod.Confirm) !void {
    if (app.width < 8 or app.height < 5) return;
    const modal_width = @min(app.width, @max(@as(u16, 24), app.width * 3 / 5));
    const modal_height: u16 = 5;
    const x = (app.width - modal_width) / 2;
    const y = (app.height - modal_height) / 2;

    try renderer.fillRect(0, 0, app.width, app.height, .{ .dim = true });
    try renderer.fillRect(x, y, modal_width, modal_height, .{});
    try renderer.writeText(x, y, "╭", app.theme.tool_chrome);
    try renderer.writeText(x + modal_width - 1, y, "╮", app.theme.tool_chrome);
    try renderer.writeText(x, y + modal_height - 1, "╰", app.theme.tool_chrome);
    try renderer.writeText(x + modal_width - 1, y + modal_height - 1, "╯", app.theme.tool_chrome);
    var xx: u16 = x + 1;
    while (xx + 1 < x + modal_width) : (xx += 1) {
        try renderer.writeText(xx, y, "─", app.theme.tool_chrome);
        try renderer.writeText(xx, y + modal_height - 1, "─", app.theme.tool_chrome);
    }
    var yy: u16 = y + 1;
    while (yy + 1 < y + modal_height) : (yy += 1) {
        try renderer.writeText(x, yy, "│", app.theme.tool_chrome);
        try renderer.writeText(x + modal_width - 1, yy, "│", app.theme.tool_chrome);
    }
    if (modal_width > 4) {
        try renderer.writeText(x + 2, y, confirm.title, app.theme.tool_title);
        try renderer.writeText(x + 2, y + 2, confirm.body, app.theme.transcript_text);
        const yes = if (confirm.selected_yes) "[Yes]" else " Yes ";
        const no = if (confirm.selected_yes) " No " else "[No]";
        const yes_width = primitive.text.displayWidth(yes);
        const no_width = primitive.text.displayWidth(no);
        const total_width = yes_width + 2 + no_width;
        const centered_offset = (@as(usize, modal_width) -| total_width) / 2;
        const start = if (total_width < modal_width) x + @as(u16, @intCast(centered_offset)) else x + 2;
        const yes_style = if (confirm.selected_yes) app.theme.status_accent else app.theme.transcript_secondary;
        const no_style = if (!confirm.selected_yes) app.theme.status_accent else app.theme.transcript_secondary;
        const button_y = y + modal_height - 2;
        try renderer.writeText(start, button_y, yes, yes_style);
        const no_x = @as(u16, @intCast(@min(
            @as(usize, std.math.maxInt(u16)),
            @as(usize, start) + yes_width + 2,
        )));
        try renderer.writeText(no_x, button_y, no, no_style);
    }
}

fn drawTranscript(
    app: *const app_mod.ProductApp,
    renderer: *infra.Renderer,
    _: primitive.Style,
    visible_rows: usize,
) !void {
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
        try renderer.fillRect(0, y, renderer.next.width, 1, row.row_style);
        var text_x: u16 = @min(transcript_item_padding_x, renderer.next.width);
        if (row.show_prefix and row.prefix.len > 0) {
            try renderer.writeText(text_x, y, row.prefix, row.prefix_style);
            text_x = advanceX(text_x, row.prefix);
        }
        if (text_x < renderer.next.width and row.text.len > 0) {
            try renderer.writeText(text_x, y, row.text, row.text_style);
            text_x = advanceX(text_x, row.text);
        }
        if (text_x < renderer.next.width and row.suffix.len > 0) {
            try renderer.writeText(text_x, y, row.suffix, row.suffix_style);
        }
    }
}

fn advanceX(x: u16, text: []const u8) u16 {
    return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, x) + primitive.text.displayWidth(text)));
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
        self.emitGeneratedParts(.{
            .prefix = prefix,
            .text = text,
            .show_prefix = show_prefix,
            .prefix_style = style,
            .text_style = style,
            .suffix_style = style,
            .row_style = style,
        });
    }

    fn emitGeneratedParts(self: *TranscriptRowSink, row: TranscriptVisualRow) void {
        self.total_emitted += 1;
        if (self.skip_remaining > 0) {
            self.skip_remaining -= 1;
            return;
        }
        if (self.rows) |rows| {
            if (self.row_count >= self.row_limit) return;
            const slot = &rows[self.row_count];
            const keep = @min(row.text.len, slot.storage.len);
            @memcpy(slot.storage[0..keep], row.text[0..keep]);
            slot.prefix = row.prefix;
            slot.text = slot.storage[0..keep];
            slot.suffix = row.suffix;
            slot.show_prefix = row.show_prefix;
            slot.prefix_style = row.prefix_style;
            slot.text_style = row.text_style;
            slot.suffix_style = row.suffix_style;
            slot.row_style = row.row_style;
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
    } else if (item == .message and item.message.role == .assistant) {
        emitMarkdownRowsNewestFirst(sink, item.message.text, frame_width, theme);
    } else {
        emitWrappedRowsNewestFirst(sink, transcript_projection.itemPrimary(item), frame_width, false, style, style);
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

fn emitMarkdownRowsNewestFirst(
    sink: *TranscriptRowSink,
    text: []const u8,
    frame_width: u16,
    theme: ?*const theme_mod.Theme,
) void {
    const fallback = theme_mod.Theme.codex();
    const resolved = theme orelse &fallback;
    const inner_width = transcriptItemInnerWidth(frame_width);
    var markdown_state: markdown_projection.State = .{};
    var item_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var item_row_count: usize = 0;

    var iterator: PhysicalLineIterator = .{ .text = text };
    while (iterator.next()) |line| {
        var generated: [markdown_projection.generated_text_bytes_max]u8 = undefined;
        const projected = markdown_projection.classifyLine(&markdown_state, line, resolved, &generated);
        const prefix_width: u16 = @intCast(@min(primitive.text.displayWidth(projected.prefix), inner_width));
        item_row_count += collectWrappedTranscriptLine(
            item_rows[item_row_count..],
            .{ .prefix = projected.prefix, .text = projected.text },
            inner_width,
            prefix_width,
            projected.repeat_prefix,
            projected.prefix_style,
            projected.text_style,
            projected.row_style,
        );
        if (item_row_count >= item_rows.len) break;
    }
    if (text.len == 0 and item_row_count == 0) {
        item_rows[0] = .{
            .prefix = "",
            .text = "",
            .show_prefix = false,
            .prefix_style = resolved.transcript_text,
            .text_style = resolved.transcript_text,
            .suffix_style = resolved.transcript_text,
            .row_style = resolved.transcript_text,
        };
        item_row_count = 1;
    }

    var remaining = item_row_count;
    while (remaining > 0) {
        remaining -= 1;
        sink.emitBorrowed(item_rows[remaining]);
        if (sink.full()) return;
    }
}

const PhysicalLineIterator = struct {
    text: []const u8,
    start: usize = 0,
    emitted_trailing_empty: bool = false,

    fn next(self: *PhysicalLineIterator) ?[]const u8 {
        if (self.start >= self.text.len) {
            if (!self.emitted_trailing_empty and self.text.len > 0 and self.text[self.text.len - 1] == '\n') {
                self.emitted_trailing_empty = true;
                return "";
            }
            return null;
        }
        const end = std.mem.indexOfScalarPos(u8, self.text, self.start, '\n') orelse self.text.len;
        const line = self.text[self.start..end];
        self.start = if (end < self.text.len) end + 1 else end;
        return line;
    }
};

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
        emitWrappedRowsNewestFirst(
            sink,
            .{ .prefix = block.bodyPrefix(), .text = projected.text },
            frame_width,
            true,
            resolved.tool_chrome,
            resolved.tool_output,
        );
        if (sink.full()) return;
    }
    if (tool.call_preview.len > 0) {
        emitWrappedRowsNewestFirst(
            sink,
            .{ .prefix = block.bodyPrefix(), .text = tool.call_preview },
            frame_width,
            true,
            resolved.tool_chrome,
            resolved.tool_output,
        );
        if (sink.full()) return;
    }

    var notice_buffer: [tool_notice_bytes_max]u8 = undefined;
    if (transcript_projection.toolOmissionNotice(tool, &notice_buffer)) |notice| {
        emitWrappedRowsNewestFirst(
            sink,
            .{ .prefix = block.bodyPrefix(), .text = notice },
            frame_width,
            true,
            resolved.tool_chrome,
            resolved.tool_chrome,
        );
        if (sink.full()) return;
    }

    var title_text_buffer: [tool_chrome_line_bytes_max]u8 = undefined;
    const title_text = transcript_projection.toolTitle(tool, &title_text_buffer);
    sink.emitGeneratedParts(.{
        .prefix = "╭─[",
        .text = title_text,
        .suffix = "]",
        .show_prefix = true,
        .prefix_style = resolved.tool_chrome,
        .text_style = resolved.tool_title,
        .suffix_style = resolved.tool_chrome,
        .row_style = resolved.tool_chrome,
    });
}

fn emitWrappedRowsNewestFirst(
    sink: *TranscriptRowSink,
    item: transcript_projection.RenderItem,
    frame_width: u16,
    repeat_prefix: bool,
    prefix_style: primitive.Style,
    text_style: primitive.Style,
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
        prefix_style,
        text_style,
        text_style,
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
    line_rows: []TranscriptVisualRow,
    item: transcript_projection.RenderItem,
    inner_width: u16,
    prefix_width: u16,
    repeat_prefix: bool,
    prefix_style: primitive.Style,
    text_style: primitive.Style,
    row_style: primitive.Style,
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
                .prefix_style = prefix_style,
                .text_style = text_style,
                .suffix_style = text_style,
                .row_style = row_style,
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
            .prefix_style = prefix_style,
            .text_style = text_style,
            .suffix_style = text_style,
            .row_style = row_style,
        };
        line_row_count += 1;
        start = visual.next;
    }
    if (item.text.len == 0 and line_row_count < line_rows.len) {
        line_rows[line_row_count] = .{
            .prefix = item.prefix,
            .text = "",
            .show_prefix = true,
            .prefix_style = prefix_style,
            .text_style = text_style,
            .suffix_style = text_style,
            .row_style = row_style,
        };
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

fn expectTextInColumn(buffer: anytype, start_x: u16, text: []const u8) !void {
    var y: u16 = 0;
    while (y < buffer.height) : (y += 1) {
        var x = start_x;
        while (x < buffer.width) : (x += 1) {
            if (cellTextEquals(buffer, x, y, text)) return;
        }
    }
    return error.MissingCell;
}

fn cellTextEquals(buffer: anytype, x: u16, y: u16, text: []const u8) bool {
    if (@as(usize, x) + text.len > buffer.width) return false;
    for (text, 0..) |byte, index| {
        const cell = buffer.get(@intCast(@as(usize, x) + index), y) catch return false;
        if (cell.renderScalar() != byte) return false;
    }
    return true;
}

test "frame renders newest transcript lines and preserves composer row" {
    var app = try app_mod.ProductApp.init(40, 7);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .system, "old");
    try appendFrameMessage(&app, .user, "one");
    try appendFrameMessage(&app, .assistant, "two");
    try appendFrameMessage(&app, .system, "three");
    try app.composer.insertUtf8(std.testing.allocator, "draft");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 7, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 0, 0, "zi");
    try expectTextInColumn(renderer.next, 1, "system: three");
    try expectCellGrapheme(renderer.next, 0, 4, "╭");
    try expectCellText(renderer.next, 1, 5, "> ");
    try expectCellText(renderer.next, 3, 5, "draft");

    const absent = try renderer.next.get(0, 1);
    try std.testing.expect(absent.renderScalar() != 'o');
}

test "frame renders user messages without label and fills background" {
    var app = try app_mod.ProductApp.init(20, 7);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .user, "hello");

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 7, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectTextInColumn(renderer.next, 1, "hello");
}

test "frame renders assistant messages without label and transparent background" {
    var app = try app_mod.ProductApp.init(20, 7);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .assistant, "hello");

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 7, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectTextInColumn(renderer.next, 1, "hello");
}

test "frame renders assistant markdown heading" {
    var app = try app_mod.ProductApp.init(40, 6);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .assistant, "# Title");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "Title");
    try std.testing.expect((try renderer.next.get(1, 1)).style.eql(app.theme.status_accent));
}

test "frame renders assistant markdown quote and code fence" {
    var app = try app_mod.ProductApp.init(40, 10);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .assistant, "> quoted\n```zig\n# not heading\n```");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 10, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectGraphemeInColumn(renderer.next, 1, "│");
    try expectTextInColumn(renderer.next, 3, "quoted");
    try expectTextInColumn(renderer.next, 3, "# not heading");
}

test "frame renders assistant markdown list marker" {
    var app = try app_mod.ProductApp.init(40, 6);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .assistant, "- item");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 1, 1, "- ");
    try expectCellText(renderer.next, 3, 1, "item");
    try std.testing.expect((try renderer.next.get(1, 1)).style.eql(app.theme.status_accent));
}

test "frame keeps transcript out of tiny heights" {
    var app = try app_mod.ProductApp.init(20, 1);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .system, "hidden");

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 1, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);
    try expectCellText(renderer.next, 0, 0, "zi");
}

test "frame renders status area between transcript and composer" {
    var app = try app_mod.ProductApp.init(30, 6);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .system, "visible");
    try app.slots.set(std.testing.allocator, .{
        .slot = .status_area,
        .id = 1,
        .priority = 10,
        .text = "model: faux",
    });

    var renderer = try infra.Renderer.init(std.testing.allocator, 30, 6, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellText(renderer.next, 0, 2, "model: faux");
    try expectCellGrapheme(renderer.next, 0, 3, "╭");
    try std.testing.expectEqual(@as(usize, 1), statusRows(&app));
}

test "frame omits status area on tiny terminal" {
    var app = try app_mod.ProductApp.init(20, 3);
    defer app.deinit(std.testing.allocator);
    try app.slots.set(std.testing.allocator, .{
        .slot = .status_area,
        .id = 1,
        .text = "status",
    });

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 3, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try std.testing.expectEqual(@as(usize, 0), statusRows(&app));
    try expectCellGrapheme(renderer.next, 0, 0, "╭");
}

test "frame renders composer top border slot with slot style" {
    var app = try app_mod.ProductApp.init(30, 3);
    defer app.deinit(std.testing.allocator);
    try app.slots.set(std.testing.allocator, .{ .slot = .composer_top_right, .id = 1, .text = "TR" });

    var renderer = try infra.Renderer.init(std.testing.allocator, 30, 3, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellGrapheme(renderer.next, 0, 0, "╭");
    try expectCellGrapheme(renderer.next, 29, 0, "╮");
    try expectCellGrapheme(renderer.next, 0, 2, "╰");
    try expectCellGrapheme(renderer.next, 29, 2, "╯");
    try expectCellText(renderer.next, 26, 0, "TR");
    try std.testing.expect((try renderer.next.get(1, 0)).style.eql(app.theme.composer_chrome));
    try std.testing.expect((try renderer.next.get(26, 0)).style.eql(app.theme.composer_slot));
}

test "frame drops composer border label when it does not fit" {
    var app = try app_mod.ProductApp.init(10, 3);
    defer app.deinit(std.testing.allocator);
    try app.slots.set(std.testing.allocator, .{ .slot = .composer_top_right, .id = 1, .text = "toolong" });

    var renderer = try infra.Renderer.init(std.testing.allocator, 10, 3, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellGrapheme(renderer.next, 0, 0, "╭");
    try expectCellGrapheme(renderer.next, 9, 0, "╮");
    try expectCellGrapheme(renderer.next, 2, 0, "─");
    try std.testing.expect((try renderer.next.get(2, 0)).style.eql(app.theme.composer_chrome));
}

test "frame places composer border slot label by display width" {
    var app = try app_mod.ProductApp.init(12, 3);
    defer app.deinit(std.testing.allocator);
    try app.slots.set(std.testing.allocator, .{ .slot = .composer_top_right, .id = 1, .text = "中" });

    var renderer = try infra.Renderer.init(std.testing.allocator, 12, 3, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellGrapheme(renderer.next, 8, 0, "中");
}

test "frame projects composer cursor into bordered composer" {
    var app = try app_mod.ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);
    try app.composer.insertUtf8(std.testing.allocator, "a中b");
    app.composer.moveLeft();

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 4, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try std.testing.expectEqual(@as(?infra.renderer.Cursor, .{ .x = 6, .y = 2 }), renderer.next_cursor);
}

test "frame hides composer cursor while modal is active" {
    var app = try app_mod.ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);
    try app.composer.insertUtf8(std.testing.allocator, "abc");
    _ = try app.apply(std.testing.allocator, .{ .open_confirm = .{ .id = 1, .title = "T", .body = "B" } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 4, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try std.testing.expect(renderer.next_cursor == null);
}

test "frame renders multiline composer inside border" {
    var app = try app_mod.ProductApp.init(40, 8);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .system, "visible");
    try app.composer.insertUtf8(std.testing.allocator, "one\ntwo\nthree");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 8, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellGrapheme(renderer.next, 0, 3, "╭");
    try expectCellText(renderer.next, 1, 4, "> ");
    try expectCellText(renderer.next, 3, 4, "one");
    try expectCellText(renderer.next, 3, 5, "two");
    try expectCellText(renderer.next, 3, 6, "three");
    try std.testing.expectEqual(
        @as(usize, 2),
        transcriptVisibleRowsWithReserved(app.height, composerRows(&app)),
    );
}

test "frame renders confirm modal above base frame" {
    var app = try app_mod.ProductApp.init(40, 10);
    defer app.deinit(std.testing.allocator);
    try appendFrameMessage(&app, .system, "base");
    _ = try app.apply(std.testing.allocator, .{ .open_confirm = .{ .id = 1, .title = "Confirm", .body = "Proceed?" } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 10, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectCellGrapheme(renderer.next, 8, 2, "╭");
    try expectCellText(renderer.next, 10, 2, "Confirm");
    try expectCellText(renderer.next, 10, 4, "Proceed?");
    try expectCellText(renderer.next, 14, 5, "[Yes]");
}

test "frame skips confirm modal safely on tiny viewports" {
    var app = try app_mod.ProductApp.init(7, 4);
    defer app.deinit(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .open_confirm = .{ .id = 1, .title = "Confirm", .body = "Proceed?" } });

    var renderer = try infra.Renderer.init(std.testing.allocator, 7, 4, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);
    try expectCellGrapheme(renderer.next, 0, 1, "╭");
}

test "frame renders transcript hard newlines as visual rows" {
    var app = try app_mod.ProductApp.init(40, 8);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .assistant, "one\ntwo\n\nthree");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 8, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectTextInColumn(renderer.next, 1, "two");
    const blank = try renderer.next.get(0, 2);
    try std.testing.expectEqual(@as(?u21, null), blank.renderScalar());
    try expectTextInColumn(renderer.next, 1, "three");
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

    try expectCellGrapheme(renderer.next, 1, 1, "╭");
    try expectCellText(renderer.next, 3, 1, "[bash]");
    try expectCellGrapheme(renderer.next, 1, 4, "╭");
    try expectCellText(renderer.next, 3, 4, "[read]");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(4, 1)).style.eql(app.theme.tool_title));
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

    try expectCellGrapheme(renderer.next, 1, 1, "╭");
    try expectCellText(renderer.next, 3, 1, "[bash: zig build test]");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(4, 1)).style.eql(app.theme.tool_title));
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

    try expectCellGrapheme(renderer.next, 1, 1, "╭");
    try expectCellText(renderer.next, 3, 1, "[bash]");
    try expectCellText(renderer.next, 3, 2, "out");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(4, 1)).style.eql(app.theme.tool_title));
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
    var app = try app_mod.ProductApp.init(40, 7);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try app.transcript.appendToolOutput(std.testing.allocator, "call-1", "one\ntwo", 0, 0);
    app.transcript_scroll_rows = 1;

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 7, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectGraphemeInColumn(renderer.next, 3, "─");
}

test "frame renders updated tool row once" {
    var app = try app_mod.ProductApp.init(40, 8);
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

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 8, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try std.testing.expectEqual(@as(usize, 1), app.transcript.items.items.len);
    try expectCellGrapheme(renderer.next, 1, 1, "╭");
    try expectCellText(renderer.next, 3, 1, "[bash]");
    try expectGraphemeInColumn(renderer.next, 1, "╰");
    try std.testing.expect((try renderer.next.get(4, 1)).style.eql(app.theme.tool_title));
}

test "frame renders transcript scrolled by newest visual rows" {
    var app = try app_mod.ProductApp.init(40, 7);
    defer app.deinit(std.testing.allocator);

    try appendFrameMessage(&app, .system, "old");
    try appendFrameMessage(&app, .user, "one");
    try appendFrameMessage(&app, .assistant, "two");
    try appendFrameMessage(&app, .system, "three");
    app.transcript_scroll_rows = 1;

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 7, size_cells_max);
    defer renderer.deinit();
    try Frame.build(&app, &renderer);

    try expectTextInColumn(renderer.next, 1, "system: three");
}
