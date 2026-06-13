//! Frame painting policy. One rule keeps scrolling honest: visual-row
//! accounting and drawing both consume `buildItemRows`, the single producer
//! of an item's rows, so count-only and draw modes cannot drift.
//!
//! Per-item row counts are memoized in `Transcript.Item.layout`, keyed by
//! (item version, width, tools_expanded). Scroll math is therefore O(items)
//! and drawing is O(viewport): whole items above the scroll window are
//! skipped by their cached row count without re-wrapping their text.
const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("App.zig");
const Transcript = @import("Transcript.zig");
const Composer = @import("Composer.zig");
const markdown = @import("markdown.zig");
const shimmer = @import("shimmer.zig");
const status_mod = @import("status.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("theme.zig");

/// Hard cap on rows one item contributes to layout, applied identically to
/// counting and drawing. Bounds the draw scratch; a pathological item shows
/// its first `item_rows_max` rows.
pub const item_rows_max: usize = 512;

const transcript_top: u16 = 1; // row 0 is the shell header
const padding_x: u16 = 1;
const item_margin_bottom: usize = 1;
const tool_body_prefix = "│ ";
const tool_bottom_line = "╰───";
const hint_bytes_max: usize = 96;
const notice_bytes_max: usize = 96;
const title_bytes_max: usize = 160;

/// Bytes of formatted (non-borrowed) text one item can pin for its rows:
/// tool title, collapse hint, and omission notice. Static literals and
/// transcript text are borrowed and need no copy.
pub const generated_text_bytes_max: usize = 512;

pub const Row = struct {
    prefix: []const u8 = "",
    text: []const u8 = "",
    suffix: []const u8 = "",
    show_prefix: bool = false,
    prefix_style: theme_mod.Style = .{},
    text_style: theme_mod.Style = .{},
    suffix_style: theme_mod.Style = .{},
    row_style: theme_mod.Style = .{},
};

/// Draw scratch for one item's rows plus an arena for generated row text,
/// so no row ever borrows a dead stack buffer. Owned by the heap-pinned
/// Terminal (or a test); too large to put on the render stack.
pub const RowScratch = struct {
    rows: [item_rows_max]Row = undefined,
    text: [generated_text_bytes_max]u8 = undefined,
    text_len: usize = 0,
};

/// Copy formatted text into the scratch arena so the returned slice lives
/// until the next item build. Count-only mode borrows: the bytes are never
/// read, only measured.
fn internText(out: ?*RowScratch, bytes: []const u8) []const u8 {
    const scratch = out orelse return bytes;
    const available = scratch.text.len - scratch.text_len;
    const keep = @min(bytes.len, available);
    const dest = scratch.text[scratch.text_len..][0..keep];
    @memcpy(dest, bytes[0..keep]);
    scratch.text_len += keep;
    return dest;
}

/// Paint the whole frame into vaxis' screen. Infallible by design: the
/// fallible half of the render transaction is the terminal write that
/// follows in Terminal.renderIfDirty.
pub fn draw(app: *App, vx: *vaxis.Vaxis, scratch: *RowScratch) void {
    clampScroll(app);
    var painter = Painter.init(vx);
    painter.clear();
    if (app.width == 0 or app.height == 0) return;

    painter.writeText(0, 0, "zi", app.theme.shell_label);
    const composer_rows = composerRows(app);
    const status_rows = statusRows(app);
    drawTranscript(app, &painter, scratch, transcriptVisibleRows(app));
    if (status_rows > 0 and app.height > composer_rows) {
        const y: u16 = @intCast(@as(usize, app.height) - composer_rows - 1);
        drawStatusLine(app, &painter, y);
    }
    drawComposer(app, &painter, composer_rows);
}

pub fn clampScroll(app: *App) void {
    app.scroll_rows = @min(app.scroll_rows, transcriptScrollMax(app));
}

pub fn transcriptScrollMax(app: *App) usize {
    return transcriptTotalRows(app) -| transcriptVisibleRows(app);
}

pub fn transcriptVisibleRows(app: *App) usize {
    if (app.height == 0) return 0;
    const body_rows = @as(usize, app.height) - transcript_top;
    const reserved = @min(composerRows(app) + statusRows(app), body_rows);
    return body_rows - reserved;
}

pub fn transcriptTotalRows(app: *App) usize {
    var total: usize = 0;
    for (app.transcript.items.items) |*item| {
        total += itemRows(item, app.width, &app.theme, app.tools_expanded);
    }
    return total;
}

/// Memoized wrapped-row count for one item at (width, expanded).
fn itemRows(item: *Transcript.Item, width: u16, theme: *const theme_mod.Theme, expanded: bool) usize {
    if (item.layout.version == item.version and
        item.layout.width == width and
        item.layout.expanded == expanded)
    {
        return item.layout.rows;
    }
    var count: usize = 0;
    buildItemRows(null, &count, item, width, theme, expanded);
    item.layout = .{
        .rows = @intCast(count),
        .width = width,
        .expanded = expanded,
        .version = item.version,
    };
    return count;
}

pub fn statusRows(app: *App) usize {
    if (app.status.count(.status_line) == 0) return 0;
    if (app.height == 0) return 0;
    if (@as(usize, app.height) <= composerRows(app)) return 0;
    return 1;
}

pub fn composerRows(app: *App) usize {
    const text_width = composerTextWidth(app.width);
    return @min(app.composer.visualRows(text_width), Composer.visible_rows_max) + 2;
}

pub fn composerTextWidth(width: u16) u16 {
    return if (width > 4) width - 4 else 1;
}

// --- transcript ---

fn drawTranscript(app: *App, painter: *Painter, scratch: *RowScratch, visible_rows: usize) void {
    if (visible_rows == 0 or app.width == 0) return;
    const total = transcriptTotalRows(app);
    var skip_remaining = app.scroll_rows; // clamped by draw()
    const drawn = @min(total - skip_remaining, visible_rows);
    if (drawn == 0) return;

    var sink: RowSink = .{
        .painter = painter,
        .draw_remaining = drawn,
        .next_y = transcript_top + @as(u16, @intCast(drawn)) - 1,
    };
    var index = app.transcript.items.items.len;
    while (index > 0 and sink.draw_remaining > 0) {
        index -= 1;
        const item = &app.transcript.items.items[index];
        const rows = itemRows(item, app.width, &app.theme, app.tools_expanded);
        if (skip_remaining >= rows) {
            skip_remaining -= rows;
            continue;
        }
        sink.skip_remaining = skip_remaining;
        skip_remaining = 0;

        var count: usize = 0;
        buildItemRows(scratch, &count, item, app.width, &app.theme, app.tools_expanded);
        std.debug.assert(count == rows); // memo and fresh build must agree
        // Rows are built top-down; the sink consumes newest-first.
        var k = count;
        while (k > 0 and sink.draw_remaining > 0) {
            k -= 1;
            sink.emit(scratch.rows[k]);
        }
    }
}

const RowSink = struct {
    painter: *Painter,
    skip_remaining: usize = 0,
    draw_remaining: usize,
    next_y: u16,

    fn emit(self: *RowSink, row: Row) void {
        if (self.skip_remaining > 0) {
            self.skip_remaining -= 1;
            return;
        }
        if (self.draw_remaining == 0) return;
        self.painter.drawRow(self.next_y, row);
        self.draw_remaining -= 1;
        self.next_y -|= 1;
    }
};

/// The single producer of an item's visual rows, top-down, including the
/// margin row below the item. With `out == null` it only counts. Row count
/// is capped at `item_rows_max` in both modes so accounting cannot drift
/// from drawing.
fn buildItemRows(
    out: ?*RowScratch,
    count: *usize,
    item: *const Transcript.Item,
    width: u16,
    theme: *const theme_mod.Theme,
    expanded: bool,
) void {
    if (out) |scratch| scratch.text_len = 0;
    const style = itemStyle(item, theme);
    const padding = itemPaddingY(item);
    var index: usize = 0;
    while (index < padding) : (index += 1) putRow(out, count, .{ .row_style = style });

    switch (item.body) {
        .message => |*message| if (message.role == .assistant) {
            buildMarkdownRows(out, count, message.text.items, width, theme);
        } else {
            emitWrappedText(out, count, .{
                .prefix = rolePrefix(message.role),
                .text = message.text.items,
                .prefix_style = style,
                .text_style = style,
                .row_style = style,
                .inner_width = innerWidth(width),
            });
        },
        .status => |status| emitWrappedText(out, count, .{
            .prefix = statusPrefix(status.level),
            .text = status.text,
            .prefix_style = style,
            .text_style = style,
            .row_style = style,
            .inner_width = innerWidth(width),
        }),
        .tool => |*tool| buildToolRows(out, count, tool, width, theme, expanded),
    }

    index = 0;
    while (index < padding) : (index += 1) putRow(out, count, .{ .row_style = style });
    var margin: usize = 0;
    while (margin < item_margin_bottom) : (margin += 1) putRow(out, count, .{});
}

fn putRow(out: ?*RowScratch, count: *usize, row: Row) void {
    if (count.* >= item_rows_max) return;
    if (out) |scratch| scratch.rows[count.*] = row;
    count.* += 1;
}

fn itemPaddingY(item: *const Transcript.Item) usize {
    return switch (item.body) {
        .message => |message| if (message.role == .user) 1 else 0,
        else => 0,
    };
}

fn itemStyle(item: *const Transcript.Item, theme: *const theme_mod.Theme) theme_mod.Style {
    return switch (item.body) {
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

fn rolePrefix(role: Transcript.Role) []const u8 {
    return switch (role) {
        .user, .assistant => "",
        .system => "system: ",
        .thinking => "thinking: ",
    };
}

fn statusPrefix(level: Transcript.StatusLevel) []const u8 {
    return switch (level) {
        .info => "status: ",
        .warning => "warning: ",
        .err => "error: ",
    };
}

fn innerWidth(frame_width: u16) u16 {
    const total_padding = padding_x * 2;
    if (frame_width <= total_padding) return 0;
    return frame_width - total_padding;
}

fn buildMarkdownRows(
    out: ?*RowScratch,
    count: *usize,
    text: []const u8,
    width: u16,
    theme: *const theme_mod.Theme,
) void {
    const inner = innerWidth(width);
    var state: markdown.State = .{};
    var emitted_any = false;
    var lines: PhysicalLineIterator = .{ .text = text };
    while (lines.next()) |line| {
        const projected = markdown.classifyLine(&state, line, theme);
        emitWrappedText(out, count, .{
            .prefix = projected.prefix,
            .text = projected.text,
            .repeat_prefix = projected.repeat_prefix,
            .prefix_style = projected.prefix_style,
            .text_style = projected.text_style,
            .row_style = projected.row_style,
            .inner_width = inner,
        });
        emitted_any = true;
    }
    if (!emitted_any) putRow(out, count, .{ .row_style = theme.transcript_text });
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

fn buildToolRows(
    out: ?*RowScratch,
    count: *usize,
    tool: *const Transcript.Tool,
    width: u16,
    theme: *const theme_mod.Theme,
    expanded: bool,
) void {
    // Error rail tints the whole chrome red, matching pi-mono's failed tools.
    const rail = if (tool.status == .err) theme.status_error else theme.tool_chrome;
    const inner = innerWidth(width);

    var title_buffer: [title_bytes_max]u8 = undefined;
    putRow(out, count, .{
        .prefix = "╭─[",
        .text = internText(out, toolTitle(tool, &title_buffer)),
        .suffix = "]",
        .show_prefix = true,
        .prefix_style = rail,
        .text_style = theme.tool_title,
        .suffix_style = rail,
        .row_style = rail,
    });

    var notice_buffer: [notice_bytes_max]u8 = undefined;
    if (omissionNotice(tool, &notice_buffer)) |notice| {
        emitWrappedText(out, count, .{
            .prefix = tool_body_prefix,
            .text = internText(out, notice),
            .repeat_prefix = true,
            .prefix_style = rail,
            .text_style = rail,
            .row_style = rail,
            .inner_width = inner,
        });
    }

    if (toolBodyVisible(tool, expanded)) {
        buildToolBodyRows(out, count, tool, inner, rail, theme, expanded);
    }

    if (tool.footer.len > 0) {
        emitWrappedText(out, count, .{
            .prefix = tool_body_prefix,
            .text = tool.footer,
            .repeat_prefix = true,
            .prefix_style = rail,
            .text_style = theme.transcript_secondary,
            .row_style = theme.transcript_secondary,
            .inner_width = inner,
        });
    }

    putRow(out, count, .{ .text = tool_bottom_line, .text_style = rail, .row_style = rail });
}

/// Collapsed tools show a bounded window over the wrapped body rows: tail
/// tools keep the newest rows with an "earlier lines" hint above, head tools
/// keep the first rows with a "more lines" hint below. Rows are counted
/// after wrapping so the window is stable across widths, the same way scroll
/// accounting works.
fn buildToolBodyRows(
    out: ?*RowScratch,
    count: *usize,
    tool: *const Transcript.Tool,
    inner: u16,
    rail: theme_mod.Style,
    theme: *const theme_mod.Theme,
    expanded: bool,
) void {
    const body = tool.output.items;
    const prefix_width: u16 = @intCast(@min(text_mod.displayWidth(tool_body_prefix), inner));
    const body_rows_total = countWrappedRows(body, inner, prefix_width);
    const rows_max: usize = tool.collapse.rows_max;

    var options: WrapOptions = .{
        .prefix = tool_body_prefix,
        .text = body,
        .repeat_prefix = true,
        .prefix_style = rail,
        .text_style = theme.tool_output,
        .row_style = theme.tool_output,
        .inner_width = inner,
        .presentation = tool.presentation,
        .theme = theme,
    };

    if (expanded or body_rows_total <= rows_max) {
        emitWrappedText(out, count, options);
        return;
    }

    const hidden = body_rows_total - rows_max;
    var hint_buffer: [hint_bytes_max]u8 = undefined;
    const hint_row: Row = .{
        .prefix = tool_body_prefix,
        .text = internText(out, collapseHint(&hint_buffer, tool.collapse.mode, hidden)),
        .show_prefix = true,
        .prefix_style = rail,
        .text_style = theme.transcript_secondary,
        .suffix_style = theme.transcript_secondary,
        .row_style = theme.transcript_secondary,
    };

    switch (tool.collapse.mode) {
        .tail => {
            putRow(out, count, hint_row);
            options.window = .{ .skip = hidden, .limit = rows_max };
            emitWrappedText(out, count, options);
        },
        .head => {
            options.window = .{ .skip = 0, .limit = rows_max };
            emitWrappedText(out, count, options);
            putRow(out, count, hint_row);
        },
    }
}

const WrapWindow = struct {
    skip: usize = 0,
    limit: usize = std.math.maxInt(usize),
};

const WrapOptions = struct {
    prefix: []const u8,
    text: []const u8,
    repeat_prefix: bool = false,
    prefix_style: theme_mod.Style,
    text_style: theme_mod.Style,
    row_style: theme_mod.Style,
    inner_width: u16,
    window: WrapWindow = .{},
    presentation: ?Transcript.ToolPresentation = null,
    theme: ?*const theme_mod.Theme = null,
};

/// Wrap one text block (physical newlines included) into visual rows,
/// top-down. The first visual row shows the prefix; continuations repeat it
/// only when `repeat_prefix` is set. The first row wraps at
/// `inner - prefix_width`, continuations at full inner width.
fn emitWrappedText(out: ?*RowScratch, count: *usize, options: WrapOptions) void {
    const prefix_width: u16 = @intCast(@min(text_mod.displayWidth(options.prefix), options.inner_width));
    var start: usize = 0;
    var visual_index: usize = 0;
    var window_index: usize = 0;
    while (start < options.text.len) : (visual_index += 1) {
        const width = if (visual_index == 0) options.inner_width - prefix_width else options.inner_width;
        var row: Row = .{
            .prefix = options.prefix,
            .show_prefix = options.repeat_prefix or visual_index == 0,
            .prefix_style = options.prefix_style,
            .text_style = options.text_style,
            .suffix_style = options.text_style,
            .row_style = options.row_style,
        };
        if (width == 0) {
            emitWindowed(out, count, &window_index, options.window, row);
            continue;
        }
        const visual = text_mod.nextVisualLineBreak(options.text, start, width);
        if (visual.next == start) break;
        const line_style = bodyLineStyle(options, visual.start);
        row.text = options.text[visual.start..visual.end];
        row.text_style = line_style;
        row.suffix_style = line_style;
        if ((options.presentation orelse .generic) == .patch) row.row_style = line_style;
        emitWindowed(out, count, &window_index, options.window, row);
        start = visual.next;
    }
    if (options.text.len == 0) {
        emitWindowed(out, count, &window_index, options.window, .{
            .prefix = options.prefix,
            .show_prefix = true,
            .prefix_style = options.prefix_style,
            .text_style = options.text_style,
            .suffix_style = options.text_style,
            .row_style = options.row_style,
        });
    }
}

fn emitWindowed(out: ?*RowScratch, count: *usize, window_index: *usize, window: WrapWindow, row: Row) void {
    defer window_index.* += 1;
    if (window_index.* < window.skip) return;
    if (window_index.* - window.skip >= window.limit) return;
    putRow(out, count, row);
}

/// Visual rows `text` wraps to, ignoring styles. Must agree with
/// emitWrappedText's walk; both use nextVisualLineBreak with the same
/// first-row prefix reservation.
fn countWrappedRows(text: []const u8, inner: u16, prefix_width: u16) usize {
    if (text.len == 0) return 1;
    var rows: usize = 0;
    var start: usize = 0;
    var visual_index: usize = 0;
    while (start < text.len) : (visual_index += 1) {
        const width = if (visual_index == 0) inner - @min(prefix_width, inner) else inner;
        if (width == 0) {
            rows += 1;
            continue;
        }
        const visual = text_mod.nextVisualLineBreak(text, start, width);
        if (visual.next == start) break;
        rows += 1;
        start = visual.next;
    }
    return rows;
}

/// Patch bodies tint added/removed/hunk lines by their physical line start.
fn bodyLineStyle(options: WrapOptions, offset: usize) theme_mod.Style {
    if ((options.presentation orelse return options.text_style) != .patch) return options.text_style;
    const theme = options.theme orelse return options.text_style;
    const line_start = physicalLineStart(options.text, offset);
    if (line_start >= options.text.len) return options.text_style;
    if (std.mem.startsWith(u8, options.text[line_start..], "@@")) return theme.transcript_secondary;
    return switch (options.text[line_start]) {
        '+' => theme.diff_add,
        '-' => theme.diff_del,
        else => options.text_style,
    };
}

fn physicalLineStart(text: []const u8, offset: usize) usize {
    var pos = @min(offset, text.len);
    while (pos > 0 and text[pos - 1] != '\n') pos -= 1;
    return pos;
}

// The adapter formats the full pi-mono-style header into `title`
// ("$ cmd", "read path:1-20", ...); the tool name is only a fallback.
fn toolTitle(tool: *const Transcript.Tool, buffer: *[title_bytes_max]u8) []const u8 {
    if (tool.title.len == 0) return tool.name;
    if (tool.title.len <= buffer.len) return tool.title;
    return text_mod.utf8Prefix(tool.title, buffer.len);
}

fn toolBodyVisible(tool: *const Transcript.Tool, expanded: bool) bool {
    if (tool.output.items.len == 0) return false;
    return switch (tool.body_mode) {
        .visible => true,
        .hidden_on_success => expanded or tool.status != .success,
    };
}

/// Wording mirrors pi-mono: tail windows hide *earlier* lines, head windows
/// hide the *remaining* lines.
fn collapseHint(buffer: []u8, mode: Transcript.ToolCollapseMode, hidden_rows: usize) []const u8 {
    const result = switch (mode) {
        .tail => std.fmt.bufPrint(buffer, "... ({d} earlier lines, ctrl+o to expand)", .{hidden_rows}),
        .head => std.fmt.bufPrint(buffer, "... ({d} more lines, ctrl+o to expand)", .{hidden_rows}),
    };
    return result catch "... (ctrl+o to expand)";
}

fn omissionNotice(tool: *const Transcript.Tool, buffer: *[notice_bytes_max]u8) ?[]const u8 {
    if (tool.dropped_head_lines > 0) {
        return std.fmt.bufPrint(buffer, "· ··· {d} earlier lines", .{tool.dropped_head_lines}) catch
            "· ··· output omitted";
    }
    if (tool.dropped_head_bytes > 0) {
        return std.fmt.bufPrint(buffer, "· ··· {d} earlier bytes", .{tool.dropped_head_bytes}) catch
            "· ··· output omitted";
    }
    return null;
}

// --- status line ---

const status_separator = " · ";

fn statusShimmerConfig(theme: *const theme_mod.Theme) shimmer.Config {
    _ = theme;
    return .{
        .base_style = .{ .dim = true },
        .peak_style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bold = true },
    };
}

fn drawStatusLine(app: *App, painter: *Painter, y: u16) void {
    var views: [status_mod.entry_count_max]status_mod.View = undefined;
    const view_count = app.status.ordered(.status_line, views[0..]);
    if (view_count == 0 or app.width == 0) return;
    painter.fillRect(0, y, app.width, 1, .{});

    var x: u16 = 0;
    var rendered_any = false;
    for (views[0..view_count]) |view| {
        if (view.text.len == 0) continue;
        const remaining: usize = if (x < app.width) app.width - x else 0;
        if (remaining == 0) return;
        const separator_width: usize = if (rendered_any) text_mod.displayWidth(status_separator) else 0;
        if (separator_width >= remaining) return;
        const available = remaining - separator_width;
        const fitted = fitToWidth(view.text, available);
        if (fitted.len == 0) continue;

        if (rendered_any) {
            painter.writeText(x, y, status_separator, app.theme.transcript_secondary);
            x = advance(x, separator_width);
        }
        switch (view.effect) {
            .none => {
                painter.writeText(x, y, fitted, app.theme.transcript_secondary);
                x = advance(x, text_mod.displayWidth(fitted));
            },
            .shimmer => x = drawShimmerText(painter, x, y, fitted, app.now_ms, statusShimmerConfig(&app.theme)),
        }
        rendered_any = true;
    }
}

/// Longest grapheme-aligned prefix fitting in `available` display columns.
fn fitToWidth(text: []const u8, available: usize) []const u8 {
    if (text_mod.displayWidth(text) <= available) return text;
    var index: usize = 0;
    var used: usize = 0;
    while (index < text.len) {
        const grapheme = text_mod.nextGrapheme(text[index..]);
        if (grapheme.end == 0) break;
        if (used + grapheme.width > available) break;
        used += grapheme.width;
        index += grapheme.end;
    }
    return text[0..index];
}

fn drawShimmerText(
    painter: *Painter,
    x: u16,
    y: u16,
    text: []const u8,
    now_ms: i64,
    config: shimmer.Config,
) u16 {
    const phase = shimmer.phaseForMs(now_ms, config, text);
    var segments: [256]vaxis.Segment = undefined;
    var segment_count: usize = 0;
    var segment_x = x;
    var cursor_x = x;
    var visual_col: usize = 0;
    var index: usize = 0;
    while (index < text.len and cursor_x < painter.width) {
        const grapheme = text_mod.nextGrapheme(text[index..]);
        if (grapheme.end == 0) break;
        if (segment_count == segments.len) {
            painter.printSegments(segment_x, y, segments[0..segment_count]);
            segment_x = cursor_x;
            segment_count = 0;
        }
        segments[segment_count] = .{
            .text = text[index .. index + grapheme.end],
            .style = shimmer.styleForColumn(config, phase, visual_col),
        };
        segment_count += 1;
        cursor_x = advance(cursor_x, grapheme.width);
        visual_col += grapheme.width;
        index += grapheme.end;
    }
    painter.printSegments(segment_x, y, segments[0..segment_count]);
    return cursor_x;
}

fn advance(x: u16, width: usize) u16 {
    return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, x) + width));
}

// --- composer ---

fn drawComposer(app: *App, painter: *Painter, composer_rows: usize) void {
    if (composer_rows < 3 or app.height == 0 or app.width == 0) return;
    const height = @min(composer_rows, @as(usize, app.height));
    if (height < 3) return;
    const box_y: u16 = @intCast(@as(usize, app.height) - height);
    const box_height: u16 = @intCast(height);
    if (app.width >= 2 and box_height >= 2) {
        painter.roundedBorder(0, box_y, app.width, box_height, app.theme.composer_chrome);
        if (app.width >= 4) {
            const inner = app.width - 2;
            if (app.status.highestPriority(.composer_corner)) |view| {
                const label_width = text_mod.displayWidth(view.text);
                if (inner >= 2 + label_width) {
                    const x = @as(usize, app.width) - 2 - label_width;
                    painter.writeText(@intCast(x), box_y, view.text, app.theme.composer_slot);
                }
            }
        }
    }

    var rows: [Composer.visible_rows_max]Composer.VisualRow = undefined;
    const projection = app.composer.visibleRows(composerTextWidth(app.width), &rows);
    const visible_count = @min(projection.visible_count, height - 2);
    var index: usize = 0;
    while (index < visible_count) : (index += 1) {
        const y: u16 = @intCast(@as(usize, box_y) + 1 + index);
        painter.writeText(1, y, "> ", app.theme.composer_prompt);
        if (app.width > 3) painter.writeText(3, y, rows[index].text, app.theme.composer_text);
    }
    if (projection.cursor_visible) {
        const cursor_y = @as(usize, box_y) + 1 + projection.cursor_visible_row;
        const cursor_x = 3 + projection.cursor_display_col;
        if (cursor_x < app.width and cursor_y < app.height) {
            painter.setCursor(@intCast(cursor_x), @intCast(cursor_y));
        }
    }
}

// --- painter ---

/// Thin policy adapter over the vaxis window for one frame. Not a drawing
/// substrate: vaxis owns cells, diffing, and encoding.
const Painter = struct {
    vx: *vaxis.Vaxis,
    width: u16,
    height: u16,

    fn init(vx: *vaxis.Vaxis) Painter {
        return .{ .vx = vx, .width = vx.screen.width, .height = vx.screen.height };
    }

    fn clear(self: *Painter) void {
        self.vx.window().clear();
        self.vx.window().hideCursor();
    }

    fn writeText(self: *Painter, x: u16, y: u16, bytes: []const u8, style: theme_mod.Style) void {
        if (x >= self.width or y >= self.height or bytes.len == 0) return;
        const segment = vaxis.Segment{ .text = bytes, .style = style };
        _ = self.vx.window().print(&.{segment}, .{ .col_offset = x, .row_offset = y, .wrap = .none });
    }

    fn printSegments(self: *Painter, x: u16, y: u16, segments: []const vaxis.Segment) void {
        if (x >= self.width or y >= self.height or segments.len == 0) return;
        _ = self.vx.window().print(segments, .{ .col_offset = x, .row_offset = y, .wrap = .none });
    }

    fn fillRect(self: *Painter, x: u16, y: u16, w: u16, h: u16, style: theme_mod.Style) void {
        if (x >= self.width or y >= self.height) return;
        const max_w = @min(w, self.width - x);
        const max_h = @min(h, self.height - y);
        var win = self.vx.window().child(.{
            .x_off = @intCast(x),
            .y_off = @intCast(y),
            .width = max_w,
            .height = max_h,
        });
        win.fill(.{ .style = style });
    }

    fn roundedBorder(self: *Painter, x: u16, y: u16, w: u16, h: u16, style: theme_mod.Style) void {
        if (x >= self.width or y >= self.height) return;
        const max_w = @min(w, self.width - x);
        const max_h = @min(h, self.height - y);
        _ = self.vx.window().child(.{
            .x_off = @intCast(x),
            .y_off = @intCast(y),
            .width = max_w,
            .height = max_h,
            .border = .{ .where = .all, .style = style, .glyphs = .single_rounded },
        });
    }

    fn setCursor(self: *Painter, x: u16, y: u16) void {
        if (x >= self.width or y >= self.height) return;
        self.vx.window().showCursor(x, y);
    }

    fn drawRow(self: *Painter, y: u16, row: Row) void {
        self.fillRect(0, y, self.width, 1, row.row_style);
        var x: u16 = @min(padding_x, self.width);
        if (row.show_prefix and row.prefix.len > 0) {
            self.writeText(x, y, row.prefix, row.prefix_style);
            x = advance(x, text_mod.displayWidth(row.prefix));
        }
        if (x < self.width and row.text.len > 0) {
            self.writeText(x, y, row.text, row.text_style);
            x = advance(x, text_mod.displayWidth(row.text));
        }
        if (x < self.width and row.suffix.len > 0) {
            self.writeText(x, y, row.suffix, row.suffix_style);
        }
    }
};

// --- tests ---

const testing_gpa = std.testing.allocator;

fn countItem(app: *App, index: usize) usize {
    const item = &app.transcript.items.items[index];
    return itemRows(item, app.width, &app.theme, app.tools_expanded);
}

test "collapsed tool body shows a bounded window with a hint row" {
    var app = App.init(80, 24);
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .collapse = .{ .mode = .tail, .rows_max = 5 },
        .title = "$ seq 8",
    } });
    _ = try app.transcript.appendToolOutput(testing_gpa, "call-1", "1\n2\n3\n4\n5\n6\n7\n8", 0, 0);

    // Collapsed: header + hint + 5 window rows + bottom + margin.
    try std.testing.expectEqual(@as(usize, 9), countItem(&app, 0));

    // Expanded: header + all 8 body rows + bottom + margin, no hint.
    app.tools_expanded = true;
    try std.testing.expectEqual(@as(usize, 11), countItem(&app, 0));
}

test "head-collapsed tool keeps the first rows with the hint below" {
    var app = App.init(80, 24);
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "grep",
        .collapse = .{ .mode = .head, .rows_max = 2 },
    } });
    _ = try app.transcript.appendToolOutput(testing_gpa, "call-1", "a\nb\nc\nd", 0, 0);

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    // Top-down: header, window rows a/b, hint, bottom, margin.
    try std.testing.expectEqualStrings("a", scratch.rows[1].text);
    try std.testing.expectEqualStrings("b", scratch.rows[2].text);
    try std.testing.expect(std.mem.indexOf(u8, scratch.rows[3].text, "more lines") != null);
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "memoized item rows match a fresh build and invalidate on mutation" {
    var app = App.init(60, 24);
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .message = .{
        .role = .assistant,
        .text = "first line\nsecond line that should wrap when narrow",
    } });

    const memoized = countItem(&app, 0);
    var fresh: usize = 0;
    buildItemRows(null, &fresh, &app.transcript.items.items[0], app.width, &app.theme, false);
    try std.testing.expectEqual(fresh, memoized);

    // Mutation invalidates: extending the message changes the row count.
    _ = try app.transcript.append(testing_gpa, .{ .message = .{
        .role = .assistant,
        .text = "\nthird line",
        .mode = .extend_previous_assistant_message,
    } });
    try std.testing.expectEqual(memoized + 1, countItem(&app, 0));

    // Width change recomputes rather than serving the stale width.
    app.width = 20;
    var narrow_fresh: usize = 0;
    buildItemRows(null, &narrow_fresh, &app.transcript.items.items[0], app.width, &app.theme, false);
    try std.testing.expectEqual(narrow_fresh, countItem(&app, 0));
}

test "scroll max accounts for composer and status reservations" {
    var app = App.init(40, 10);
    defer app.deinit(testing_gpa);

    var index: usize = 0;
    while (index < 20) : (index += 1) {
        _ = try app.transcript.append(testing_gpa, .{ .message = .{ .role = .assistant, .text = "row" } });
    }
    const total = transcriptTotalRows(&app);
    try std.testing.expectEqual(@as(usize, 40), total); // text row + margin row each
    const visible = transcriptVisibleRows(&app);
    try std.testing.expectEqual(total - visible, transcriptScrollMax(&app));

    // A status contribution reserves one more row.
    _ = app.status.set(.{ .slot = .status_line, .id = 1, .text = "working" });
    try std.testing.expectEqual(visible - 1, transcriptVisibleRows(&app));
}

test "vaxis screen receives the frame" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 30, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(30, 8);
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "hello vaxis",
    } } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try expectScreenText(vx.window(), 0, 0, "zi");
    try expectScreenText(vx.window(), 1, 1, "hello vaxis");
}

test "scrolled frame draws older rows and clamps to max" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);
    try vx.resize(testing_gpa, &writer, .{ .cols = 30, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(30, 8);
    defer app.deinit(testing_gpa);
    var index: usize = 0;
    var label: [16]u8 = undefined;
    while (index < 10) : (index += 1) {
        const line = try std.fmt.bufPrint(&label, "line-{d}", .{index});
        _ = try app.transcript.append(testing_gpa, .{ .message = .{ .role = .assistant, .text = line } });
    }

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);

    app.scroll_rows = 10_000; // clamps to max instead of blanking
    draw(&app, &vx, scratch);
    try expectScreenText(vx.window(), 1, 1, "line-0");
}

fn expectScreenText(window: vaxis.Window, x: u16, y: u16, expected: []const u8) !void {
    var col = x;
    var index: usize = 0;
    while (index < expected.len) : (index += 1) {
        const cell = window.readCell(col, y) orelse return error.MissingCell;
        try std.testing.expectEqualStrings(expected[index .. index + 1], cell.char.grapheme);
        col += 1;
    }
}
