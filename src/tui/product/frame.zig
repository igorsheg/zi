const std = @import("std");
const vaxis = @import("vaxis");
const wrap = @import("wrap.zig");
const app_mod = @import("App.zig");
const chrome = @import("chrome.zig");
const composer_mod = @import("composer.zig");
const draw_mod = @import("draw.zig");
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
    prefix_style: vaxis.Style = .{},
    text_style: vaxis.Style = .{},
    suffix_style: vaxis.Style = .{},
    row_style: vaxis.Style = .{},
    storage: [generated_row_text_bytes_max]u8 = undefined,
};

pub const Frame = struct {
    width: u16,
    height: u16,

    pub fn build(app: *app_mod.ProductApp, vx: *vaxis.Vaxis) !void {
        app.clampTranscriptScroll();
        var draw = draw_mod.Context.init(vx);
        draw.clear();
        if (app.height > 0) try draw.writeText(0, 0, "zi", app.theme.shell_label);
        const composer_rows = composerRows(app);
        const status_rows = statusRows(app);
        if (app.height > 0) {
            try drawTranscript(
                app,
                &draw,
                app.theme.transcript_text,
                transcriptVisibleRowsWithReserved(app.height, composer_rows + status_rows),
            );
            if (status_rows > 0 and app.height > composer_rows) {
                var views: [slots_mod.status_area_slot_count_max]slots_mod.SlotView = undefined;
                const count = app.slots.orderedSlot(.status_area, &views);
                if (count > 0) {
                    const y: u16 = @intCast(@as(usize, app.height) - composer_rows - 1);
                    try status_area.draw(&draw, app.theme, y, app.width, views[0..count], app.animation_tick);
                }
            }
            try drawComposer(app, &draw, composer_rows);
        }
        if (app.modal) |confirm| try drawConfirmModal(app, &draw, confirm);
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

fn drawComposer(app: *app_mod.ProductApp, renderer: anytype, composer_rows: usize) !void {
    if (composer_rows < 3 or app.height == 0 or app.width == 0) return;
    const height = @min(composer_rows, @as(usize, app.height));
    if (height < 3) return;
    const box_y: u16 = @intCast(@as(usize, app.height) - height);
    const box_height: u16 = @intCast(height);
    if (app.width >= 2 and box_height >= 2) {
        renderer.roundedBorder(0, box_y, app.width, box_height, app.theme.composer_chrome);
        if (app.width >= 4) {
            const inner_width = app.width - 2;
            if (app.slots.highestPriority(.composer_top_right)) |view| {
                const label_width = wrap.displayWidth(view.text);
                if (inner_width >= 2 + label_width) {
                    const x = @as(usize, app.width) - 2 - label_width;
                    try renderer.writeText(@intCast(x), box_y, view.text, app.theme.composer_slot);
                }
            }
        }
    }

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

pub fn transcriptScrollMax(
    transcript: transcript_mod.TranscriptBuffer,
    width: u16,
    visible_rows: usize,
    tools_expanded: bool,
) usize {
    if (width == 0 or visible_rows == 0) return 0;
    var sink = TranscriptRowSink.countOnly();
    var item_index = transcript.items.items.len;
    while (item_index > 0) {
        item_index -= 1;
        emitItemRowsNewestFirst(&sink, transcript.items.items[item_index], width, null, tools_expanded);
    }
    return if (sink.total_emitted > visible_rows) sink.total_emitted - visible_rows else 0;
}

fn drawConfirmModal(app: *const app_mod.ProductApp, renderer: anytype, confirm: surface_mod.Confirm) !void {
    if (app.width < 8 or app.height < 5) return;
    const modal_width = @min(app.width, @max(@as(u16, 24), app.width * 3 / 5));
    const modal_height: u16 = 5;
    const x = (app.width - modal_width) / 2;
    const y = (app.height - modal_height) / 2;

    try renderer.fillRect(0, 0, app.width, app.height, .{ .dim = true });
    try renderer.fillRect(x, y, modal_width, modal_height, .{});
    renderer.roundedBorder(x, y, modal_width, modal_height, app.theme.tool_chrome);
    if (modal_width > 4) {
        try renderer.writeText(x + 2, y, confirm.title, app.theme.tool_title);
        try renderer.writeText(x + 2, y + 2, confirm.body, app.theme.transcript_text);
        const yes = if (confirm.selected_yes) "[Yes]" else " Yes ";
        const no = if (confirm.selected_yes) " No " else "[No]";
        const yes_width = wrap.displayWidth(yes);
        const no_width = wrap.displayWidth(no);
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
    renderer: anytype,
    _: vaxis.Style,
    visible_rows: usize,
) !void {
    if (visible_rows == 0 or app.width == 0) return;
    const row_limit = @min(visible_rows, transcript_visual_rows_max);
    var rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var sink = TranscriptRowSink.store(&rows, row_limit, app.transcript_scroll_rows);

    var item_index = app.transcript.items.items.len;
    while (item_index > 0 and sink.row_count < row_limit) {
        item_index -= 1;
        emitItemRowsNewestFirst(
            &sink,
            app.transcript.items.items[item_index],
            app.width,
            &app.theme,
            app.tools_expanded,
        );
    }

    var draw_index = sink.row_count;
    var y: u16 = 1;
    while (draw_index > 0) : (y += 1) {
        draw_index -= 1;
        const row = rows[draw_index];
        try renderer.fillRect(0, y, renderer.width, 1, row.row_style);
        var text_x: u16 = @min(transcript_item_padding_x, renderer.width);
        if (row.show_prefix and row.prefix.len > 0) {
            try renderer.writeText(text_x, y, row.prefix, row.prefix_style);
            text_x = advanceX(text_x, row.prefix);
        }
        if (text_x < renderer.width and row.text.len > 0) {
            try renderer.writeText(text_x, y, row.text, row.text_style);
            text_x = advanceX(text_x, row.text);
        }
        if (text_x < renderer.width and row.suffix.len > 0) {
            try renderer.writeText(text_x, y, row.suffix, row.suffix_style);
        }
    }
}

fn advanceX(x: u16, text: []const u8) u16 {
    return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, x) + wrap.displayWidth(text)));
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
        style: vaxis.Style,
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
    tools_expanded: bool,
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
        emitToolRowsNewestFirst(sink, item.tool, frame_width, theme, tools_expanded);
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

fn emitVerticalPaddingRows(sink: *TranscriptRowSink, count: usize, style: vaxis.Style) void {
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
        const prefix_width: u16 = @intCast(@min(wrap.displayWidth(projected.prefix), inner_width));
        item_row_count += collectWrappedTranscriptLine(
            item_rows[item_row_count..],
            .{ .prefix = projected.prefix, .text = projected.text },
            inner_width,
            prefix_width,
            projected.repeat_prefix,
            projected.prefix_style,
            projected.text_style,
            projected.row_style,
            null,
            null,
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
    tools_expanded: bool,
) void {
    const fallback = theme_mod.Theme.codex();
    const resolved = theme orelse &fallback;
    // Error rail is red, matching pi-mono's error tint on failed tools.
    const rail_style = if (tool.status == .err) resolved.status_error else resolved.tool_chrome;

    const block: chrome.OpenBlock = .{};
    var bottom_buffer: [tool_chrome_line_bytes_max]u8 = undefined;
    const bottom = block.bottomLine(&bottom_buffer) catch "╰────";
    sink.emitGenerated("", bottom, false, rail_style);
    if (sink.full()) return;

    if (tool.footer.len > 0) {
        emitWrappedRowsNewestFirst(
            sink,
            .{ .prefix = block.bodyPrefix(), .text = tool.footer },
            frame_width,
            true,
            rail_style,
            resolved.transcript_secondary,
        );
        if (sink.full()) return;
    }

    const projected = transcript_projection.itemPrimary(.{ .tool = tool });
    if (transcript_projection.toolBodyVisible(tool, tools_expanded)) {
        emitToolBodyRowsNewestFirst(
            sink,
            .{ .prefix = block.bodyPrefix(), .text = projected.text },
            frame_width,
            tool.presentation,
            tool.collapse,
            tools_expanded,
            rail_style,
            resolved,
        );
        if (sink.full()) return;
    }
    if (tool.call_preview.len > 0) {
        emitWrappedRowsNewestFirst(
            sink,
            .{ .prefix = block.bodyPrefix(), .text = tool.call_preview },
            frame_width,
            true,
            rail_style,
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
            rail_style,
            rail_style,
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
        .prefix_style = rail_style,
        .text_style = resolved.tool_title,
        .suffix_style = rail_style,
        .row_style = rail_style,
    });
}

fn emitWrappedRowsNewestFirst(
    sink: *TranscriptRowSink,
    item: transcript_projection.RenderItem,
    frame_width: u16,
    repeat_prefix: bool,
    prefix_style: vaxis.Style,
    text_style: vaxis.Style,
) void {
    const inner_width = transcriptItemInnerWidth(frame_width);
    const prefix_width: u16 = @intCast(@min(wrap.displayWidth(item.prefix), inner_width));
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
        null,
        null,
    );
    var remaining = line_row_count;
    while (remaining > 0) {
        remaining -= 1;
        sink.emitBorrowed(line_rows[remaining]);
        if (sink.full()) return;
    }
}

// Collapsed tools show a bounded visual-row window over the body (pi-mono's
// sliding preview): tail tools keep the newest rows with a "... (N earlier
// lines, ctrl+o to expand)" hint above, head tools keep the first rows with a
// "... (N more lines, ...)" hint below. Expanded shows the full retained
// preview. Rows are counted after wrapping so the window is stable across
// widths, the same way scroll accounting works.
fn emitToolBodyRowsNewestFirst(
    sink: *TranscriptRowSink,
    item: transcript_projection.RenderItem,
    frame_width: u16,
    presentation: transcript_mod.TranscriptToolPresentation,
    collapse: transcript_mod.TranscriptToolCollapse,
    expanded: bool,
    rail_style: vaxis.Style,
    theme: *const theme_mod.Theme,
) void {
    const inner_width = transcriptItemInnerWidth(frame_width);
    const prefix_width: u16 = @intCast(@min(wrap.displayWidth(item.prefix), inner_width));
    var line_rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    const line_row_count = collectWrappedTranscriptLine(
        &line_rows,
        item,
        inner_width,
        prefix_width,
        true,
        rail_style,
        theme.tool_output,
        theme.tool_output,
        presentation,
        theme,
    );

    const rows_max: usize = collapse.rows_max;
    if (expanded or line_row_count <= rows_max) {
        var remaining = line_row_count;
        while (remaining > 0) {
            remaining -= 1;
            sink.emitBorrowed(line_rows[remaining]);
            if (sink.full()) return;
        }
        return;
    }

    const hidden_rows = line_row_count - rows_max;
    var hint_buffer: [96]u8 = undefined;
    const hint = transcript_projection.collapseHint(&hint_buffer, collapse.mode, hidden_rows);
    const window_start: usize = if (collapse.mode == .tail) hidden_rows else 0;
    const window_end = window_start + rows_max;

    if (collapse.mode == .head) {
        emitToolHintRow(sink, item.prefix, hint, rail_style, theme);
        if (sink.full()) return;
    }
    var remaining = window_end;
    while (remaining > window_start) {
        remaining -= 1;
        sink.emitBorrowed(line_rows[remaining]);
        if (sink.full()) return;
    }
    if (collapse.mode == .tail) emitToolHintRow(sink, item.prefix, hint, rail_style, theme);
}

fn emitToolHintRow(
    sink: *TranscriptRowSink,
    prefix: []const u8,
    hint: []const u8,
    rail_style: vaxis.Style,
    theme: *const theme_mod.Theme,
) void {
    sink.emitGeneratedParts(.{
        .prefix = prefix,
        .text = hint,
        .show_prefix = true,
        .prefix_style = rail_style,
        .text_style = theme.transcript_secondary,
        .suffix_style = theme.transcript_secondary,
        .row_style = theme.transcript_secondary,
    });
}

fn transcriptItemInnerWidth(frame_width: u16) u16 {
    const padding_width = transcript_item_padding_x * 2;
    if (frame_width <= padding_width) return 0;
    return frame_width - padding_width;
}

fn transcriptItemStyle(item: transcript_mod.TranscriptItem, theme: ?*const theme_mod.Theme) vaxis.Style {
    if (theme) |resolved| return transcriptItemStyleFromTheme(item, resolved);
    const fallback = theme_mod.Theme.codex();
    return transcriptItemStyleFromTheme(item, &fallback);
}

fn transcriptItemStyleFromTheme(item: transcript_mod.TranscriptItem, theme: *const theme_mod.Theme) vaxis.Style {
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
    prefix_style: vaxis.Style,
    text_style: vaxis.Style,
    row_style: vaxis.Style,
    presentation: ?transcript_mod.TranscriptToolPresentation,
    theme: ?*const theme_mod.Theme,
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
        const visual = wrap.nextVisualLineBreak(item.text, start, width);
        if (visual.next == start) break;
        const resolved_text_style = toolBodyLineStyle(presentation, theme, item.text, visual.start, text_style);
        const resolved_row_style = if ((presentation orelse .generic) == .patch) resolved_text_style else row_style;
        line_rows[line_row_count] = .{
            .prefix = item.prefix,
            .text = item.text[visual.start..visual.end],
            .show_prefix = repeat_prefix or visual_index == 0,
            .prefix_style = prefix_style,
            .text_style = resolved_text_style,
            .suffix_style = resolved_text_style,
            .row_style = resolved_row_style,
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

fn toolBodyLineStyle(
    presentation: ?transcript_mod.TranscriptToolPresentation,
    theme: ?*const theme_mod.Theme,
    text: []const u8,
    offset: usize,
    fallback: vaxis.Style,
) vaxis.Style {
    if ((presentation orelse return fallback) != .patch) return fallback;
    const resolved = theme orelse return fallback;
    const line_start = physicalLineStart(text, offset);
    if (line_start >= text.len) return fallback;
    if (std.mem.startsWith(u8, text[line_start..], "@@")) return resolved.transcript_secondary;
    return switch (text[line_start]) {
        '+' => resolved.diff_add,
        '-' => resolved.diff_del,
        else => fallback,
    };
}

fn physicalLineStart(text: []const u8, offset: usize) usize {
    var pos = @min(offset, text.len);
    while (pos > 0 and text[pos - 1] != '\n') pos -= 1;
    return pos;
}

pub fn checkSize(width: u16, height: u16) !void {
    const count = @as(usize, width) * height;
    if (count == 0) return error.EmptyFrame;
    if (count > size_cells_max) return error.FrameTooLarge;
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

test "collapsed tool body shows a bounded window with a hint row" {
    const allocator = std.testing.allocator;
    var transcript_buffer: transcript_mod.TranscriptBuffer = .{};
    defer transcript_buffer.deinit(allocator);

    try transcript_buffer.append(allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .collapse = .{ .mode = .tail, .rows_max = 5 },
        .title = "$ seq 8",
    } });
    try transcript_buffer.appendToolOutput(allocator, "call-1", "1\n2\n3\n4\n5\n6\n7\n8", 0, 0);
    const item = transcript_buffer.items.items[0];

    // Collapsed: margin + bottom + 5 window rows + hint + header.
    var collapsed = TranscriptRowSink.countOnly();
    emitItemRowsNewestFirst(&collapsed, item, 80, null, false);
    try std.testing.expectEqual(@as(usize, 9), collapsed.total_emitted);

    // Expanded: margin + bottom + all 8 body rows + header, no hint.
    var expanded = TranscriptRowSink.countOnly();
    emitItemRowsNewestFirst(&expanded, item, 80, null, true);
    try std.testing.expectEqual(@as(usize, 11), expanded.total_emitted);
}

test "head-collapsed tool body keeps the first rows" {
    const allocator = std.testing.allocator;
    var transcript_buffer: transcript_mod.TranscriptBuffer = .{};
    defer transcript_buffer.deinit(allocator);

    try transcript_buffer.append(allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "grep",
        .collapse = .{ .mode = .head, .rows_max = 2 },
    } });
    try transcript_buffer.appendToolOutput(allocator, "call-1", "a\nb\nc\nd", 0, 0);
    const item = transcript_buffer.items.items[0];

    var rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var sink = TranscriptRowSink.store(&rows, transcript_visual_rows_max, 0);
    emitItemRowsNewestFirst(&sink, item, 80, null, false);

    // Rows arrive newest-first: margin, bottom border, hint, window rows b then a, header.
    try std.testing.expect(std.mem.indexOf(u8, rows[2].text, "more lines") != null);
    try std.testing.expectEqualStrings("b", rows[3].text);
    try std.testing.expectEqualStrings("a", rows[4].text);
}

test "tool footer emits a body row" {
    const allocator = std.testing.allocator;
    var transcript_buffer: transcript_mod.TranscriptBuffer = .{};
    defer transcript_buffer.deinit(allocator);

    try transcript_buffer.append(allocator, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash" } });
    try transcript_buffer.replaceToolFooter(allocator, "call-1", "Took 1.2s");
    const item = transcript_buffer.items.items[0];

    var rows: [transcript_visual_rows_max]TranscriptVisualRow = undefined;
    var sink = TranscriptRowSink.store(&rows, transcript_visual_rows_max, 0);
    emitItemRowsNewestFirst(&sink, item, 80, null, false);
    try std.testing.expectEqualStrings("Took 1.2s", rows[2].text);
}
