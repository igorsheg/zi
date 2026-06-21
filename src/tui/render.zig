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
const Greeter = @import("Greeter.zig");
const Picker = @import("Picker.zig");
const glyphs = @import("glyphs.zig");
const input_mod = @import("input.zig");
const markdown = @import("markdown.zig");
const notify_mod = @import("notify.zig");
const shimmer = @import("shimmer.zig");
const shuffle_text = @import("shuffle_text.zig");
const status_mod = @import("status.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("theme.zig");

/// Hard cap on rows one item contributes to layout, applied identically to
/// counting and drawing. Bounds the draw scratch; a pathological item shows
/// its first `item_rows_max` rows.
pub const item_rows_max: usize = 512;

const transcript_top: u16 = 0;
const padding_x: u16 = 1;
const item_margin_bottom: usize = 1;
const hint_bytes_max: usize = 96;
const notice_bytes_max: usize = 96;
const title_bytes_max: usize = 160;
const footer_bytes_max: usize = 256;

/// Bytes of formatted (non-borrowed) text one frame can pin for vaxis cells:
/// tool titles, collapse hints, and omission notices. Static literals and
/// transcript text are borrowed and need no copy.
pub const generated_text_bytes_max: usize = 16 * 1024;

pub const RowSegment = struct {
    text: []const u8,
    style: theme_mod.Style,
};

pub const Row = struct {
    prefix: []const u8 = "",
    text: []const u8 = "",
    segments: []const RowSegment = &.{},
    show_prefix: bool = false,
    prefix_style: theme_mod.Style = .{},
    text_style: theme_mod.Style = .{},
    row_style: theme_mod.Style = .{},
};

/// Draw scratch for one item's rows plus an arena for generated row text,
/// so no row ever borrows a dead stack buffer. Owned by the heap-pinned
/// Terminal (or a test); too large to put on the render stack.
pub const RowScratch = struct {
    rows: [item_rows_max]Row = undefined,
    text: [generated_text_bytes_max]u8 = undefined,
    text_len: usize = 0,
    segments: [item_rows_max * 2]RowSegment = undefined,
    segment_len: usize = 0,

    fn reset(self: *RowScratch) void {
        self.text_len = 0;
        self.segment_len = 0;
    }
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

fn internSegments(out: ?*RowScratch, segments: []const RowSegment) []const RowSegment {
    const scratch = out orelse return &.{};
    const available = scratch.segments.len - scratch.segment_len;
    const keep = @min(segments.len, available);
    const dest = scratch.segments[scratch.segment_len..][0..keep];
    @memcpy(dest, segments[0..keep]);
    scratch.segment_len += keep;
    return dest;
}

/// Paint the whole frame into vaxis' screen. Infallible by design: the
/// fallible half of the render transaction is the terminal write that
/// follows in Terminal.renderIfDirty.
pub fn draw(app: *App, vx: *vaxis.Vaxis, scratch: *RowScratch) void {
    scratch.reset();
    var painter = Painter.init(vx);
    painter.clear(app.theme.app_bg);
    if (app.width == 0 or app.height == 0) return;

    const composer_rows = composerRows(app);
    const picker_rows = pickerRows(app);
    const status_rows = statusRows(app);
    const greeter_rows = greeterRows(app);
    drawTranscript(app, &painter, scratch, transcriptVisibleRows(app));
    if (greeter_rows > 0) {
        const y: u16 = @intCast(@as(usize, app.height) - picker_rows - composer_rows - status_rows - greeter_rows);
        drawGreeter(app, &painter, y);
    }
    if (status_rows > 0 and @as(usize, app.height) > composer_rows + picker_rows) {
        const y: u16 = @intCast(@as(usize, app.height) - picker_rows - composer_rows - 1);
        drawStatusLine(app, &painter, y);
    }
    drawNotifyOverlay(app, &painter, scratch, composer_rows, picker_rows, status_rows);
    drawComposer(app, &painter, composer_rows, picker_rows);
    if (app.visiblePicker()) |picker| {
        drawPicker(app, picker, &painter, picker_rows, app.visiblePickerFocusesFilter());
    }
}

fn clampedScrollRows(app: *App) usize {
    return @min(app.viewport.scroll_rows, transcriptScrollMax(app));
}

pub fn transcriptScrollMax(app: *App) usize {
    return transcriptTotalRows(app) -| transcriptVisibleRows(app);
}

pub fn transcriptVisibleRows(app: *App) usize {
    if (app.height == 0) return 0;
    const body_rows = @as(usize, app.height) - transcript_top;
    const reserved = @min(composerRows(app) + statusRows(app) + pickerRows(app) + greeterRows(app), body_rows);
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
    const count = if (item.body == .message and item.body.message.role == .assistant)
        cachedAssistantMarkdownRows(item, width, theme)
    else blk: {
        var rows: usize = 0;
        buildItemRows(null, &rows, item, width, theme, expanded);
        break :blk rows;
    };
    item.layout.rows = @intCast(count);
    item.layout.width = width;
    item.layout.expanded = expanded;
    item.layout.version = item.version;
    return count;
}

fn cachedAssistantMarkdownRows(item: *Transcript.Item, width: u16, theme: *const theme_mod.Theme) usize {
    std.debug.assert(item.body == .message);
    std.debug.assert(item.body.message.role == .assistant);
    const text = item.body.message.text.items;
    const stable_end = markdownStableEnd(text);
    if (item.layout.markdown_width != width or item.layout.markdown_stable_end > stable_end) {
        item.layout.markdown_width = width;
        item.layout.markdown_stable_end = 0;
        item.layout.markdown_stable_rows = 0;
        item.layout.markdown_fence = .none;
    }

    const inner = innerWidth(width);
    var rows: usize = item.layout.markdown_stable_rows;
    var state = markdownStateFromCache(item.layout.markdown_fence);
    var start = item.layout.markdown_stable_end;
    while (start < stable_end and rows < item_rows_max) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse stable_end;
        addMarkdownLineRows(null, &rows, &state, text[start..end], inner, theme);
        start = if (end < stable_end) end + 1 else end;
    }
    item.layout.markdown_stable_end = stable_end;
    item.layout.markdown_stable_rows = @intCast(@min(rows, item_rows_max));
    item.layout.markdown_fence = cacheFenceFromState(state);

    if (rows >= item_rows_max) return item_rows_max;
    var tail_count: usize = 0;
    buildAssistantMarkdownTailRows(null, &tail_count, item, width, theme);
    return @min(rows + tail_count, item_rows_max);
}

fn buildAssistantMarkdownTailRows(
    out: ?*RowScratch,
    count: *usize,
    item: *const Transcript.Item,
    width: u16,
    theme: *const theme_mod.Theme,
) void {
    std.debug.assert(item.body == .message);
    std.debug.assert(item.body.message.role == .assistant);
    if (out) |scratch| scratch.reset();
    const text = item.body.message.text.items;
    const stable_end = @min(item.layout.markdown_stable_end, text.len);
    var state = markdownStateFromCache(item.layout.markdown_fence);
    const inner = innerWidth(width);
    if (stable_end < text.len) {
        var tail_lines: PhysicalLineIterator = .{ .text = text[stable_end..] };
        while (tail_lines.next()) |line| {
            addMarkdownLineRows(out, count, &state, line, inner, theme);
            if (count.* >= item_rows_max) return;
        }
    } else if (text.len == 0 or text[text.len - 1] == '\n') {
        addMarkdownLineRows(out, count, &state, "", inner, theme);
    }
    var margin: usize = 0;
    while (margin < item_margin_bottom and count.* < item_rows_max) : (margin += 1) putRow(out, count, .{});
}

fn addMarkdownLineRows(
    out: ?*RowScratch,
    rows: *usize,
    state: *markdown.State,
    line: []const u8,
    inner: u16,
    theme: *const theme_mod.Theme,
) void {
    emitMarkdownProjection(out, rows, markdown.classifyLine(state, line, theme), inner, theme);
}

fn emitMarkdownProjection(
    out: ?*RowScratch,
    rows: *usize,
    projected: markdown.Projection,
    inner: u16,
    theme: *const theme_mod.Theme,
) void {
    if (!projected.parse_inline) {
        emitWrappedText(out, rows, .{
            .prefix = projected.prefix,
            .continuation_prefix = projected.continuation_prefix,
            .text = projected.text,
            .repeat_prefix = projected.repeat_prefix,
            .prefix_style = projected.prefix_style,
            .text_style = projected.text_style,
            .row_style = projected.row_style,
            .inner_width = inner,
        });
        return;
    }
    emitWrappedInlineMarkdown(out, rows, .{
        .prefix = projected.prefix,
        .continuation_prefix = projected.continuation_prefix,
        .text = projected.text,
        .repeat_prefix = projected.repeat_prefix,
        .prefix_style = projected.prefix_style,
        .text_style = projected.text_style,
        .row_style = projected.row_style,
        .inner_width = inner,
        .theme = theme,
    });
}

const InlineMarkdownOptions = struct {
    prefix: []const u8,
    continuation_prefix: []const u8 = "",
    text: []const u8,
    repeat_prefix: bool = false,
    prefix_style: theme_mod.Style,
    text_style: theme_mod.Style,
    row_style: theme_mod.Style,
    inner_width: u16,
    theme: *const theme_mod.Theme,
};

const InlineRowBuilder = struct {
    out: ?*RowScratch,
    count: *usize,
    options: InlineMarkdownOptions,
    visual_index: usize = 0,
    row_width: u16 = 0,
    row_limit: u16 = 0,
    row_segment_start: usize = 0,
    row_segment_len: usize = 0,
    row_raw_start: usize = 0,
    row_raw_end: usize = 0,
    row_has_text: bool = false,
    row_dropped_segments: bool = false,
    row_started: bool = false,

    fn emitSpan(self: *InlineRowBuilder, span: markdown.InlineSpan) void {
        var start: usize = 0;
        while (start < span.text.len and self.count.* < item_rows_max) {
            self.ensureRow(span.raw_start);
            if (self.row_limit == 0) {
                self.flush();
                return;
            }
            if (self.row_width >= self.row_limit) {
                self.flush();
                continue;
            }
            const remaining: u16 = self.row_limit - self.row_width;
            const visual = text_mod.nextVisualLineBreak(span.text, start, remaining);
            if (visual.next == start) break;
            const piece = span.text[visual.start..visual.end];
            if (piece.len > 0) self.appendSegment(piece, span.style);
            self.row_width += @intCast(@min(visual.width, remaining));
            self.markRaw(span.raw_start, span.raw_end);
            start = visual.next;
            if (start < span.text.len) self.flush();
        }
    }

    fn finish(self: *InlineRowBuilder) void {
        if (!self.row_started) {
            self.ensureRow(0);
            self.flush();
            return;
        }
        self.flush();
    }

    fn ensureRow(self: *InlineRowBuilder, raw_start: usize) void {
        if (self.row_started) return;
        self.row_started = true;
        self.row_width = 0;
        const prefix = self.currentPrefix();
        self.row_limit = self.options.inner_width - @as(u16, @intCast(@min(
            text_mod.displayWidth(prefix),
            self.options.inner_width,
        )));
        self.row_raw_start = raw_start;
        self.row_raw_end = raw_start;
        self.row_has_text = false;
        self.row_dropped_segments = false;
        if (self.out) |scratch| self.row_segment_start = scratch.segment_len;
        self.row_segment_len = 0;
    }

    fn appendSegment(self: *InlineRowBuilder, bytes: []const u8, style: theme_mod.Style) void {
        self.row_has_text = true;
        const scratch = self.out orelse return;
        if (self.row_segment_len > 0) {
            const last = &scratch.segments[scratch.segment_len - 1];
            const last_end = @intFromPtr(last.text.ptr) + last.text.len;
            if (last_end == @intFromPtr(bytes.ptr) and theme_mod.Style.eql(last.style, style)) {
                last.text = last.text.ptr[0 .. last.text.len + bytes.len];
                return;
            }
        }
        if (scratch.segment_len >= scratch.segments.len) {
            self.row_dropped_segments = true;
            return;
        }
        scratch.segments[scratch.segment_len] = .{ .text = bytes, .style = style };
        scratch.segment_len += 1;
        self.row_segment_len += 1;
    }

    fn markRaw(self: *InlineRowBuilder, start: usize, end: usize) void {
        if (!self.row_has_text) self.row_raw_start = start;
        self.row_raw_end = @max(self.row_raw_end, end);
    }

    fn flush(self: *InlineRowBuilder) void {
        if (!self.row_started or self.count.* >= item_rows_max) return;
        const prefix = self.currentPrefix();
        var row: Row = .{
            .prefix = prefix,
            .show_prefix = prefix.len > 0,
            .prefix_style = self.options.prefix_style,
            .text_style = self.options.text_style,
            .row_style = self.options.row_style,
        };
        if (self.out) |scratch| {
            if (self.row_dropped_segments) {
                scratch.segment_len = self.row_segment_start;
                row.text = self.options.text[self.row_raw_start..@min(self.row_raw_end, self.options.text.len)];
            } else {
                row.segments = scratch.segments[self.row_segment_start..scratch.segment_len];
            }
        }
        putRow(self.out, self.count, row);
        self.visual_index += 1;
        self.row_started = false;
    }

    fn currentPrefix(self: *const InlineRowBuilder) []const u8 {
        if (self.visual_index == 0 or self.options.repeat_prefix) return self.options.prefix;
        return self.options.continuation_prefix;
    }
};

fn emitWrappedInlineMarkdown(out: ?*RowScratch, count: *usize, options: InlineMarkdownOptions) void {
    var builder: InlineRowBuilder = .{ .out = out, .count = count, .options = options };
    var index: usize = 0;
    while (markdown.nextInlineSpan(options.text, &index, options.text_style, options.theme)) |span| {
        builder.emitSpan(span);
        if (count.* >= item_rows_max) return;
    }
    builder.finish();
}

fn markdownStableEnd(text: []const u8) usize {
    var index = text.len;
    while (index > 0) {
        index -= 1;
        if (text[index] == '\n') return index + 1;
    }
    return 0;
}

fn markdownStateFromCache(fence: Transcript.MarkdownFence) markdown.State {
    return .{ .fence = switch (fence) {
        .none => .none,
        .backtick => .backtick,
        .tilde => .tilde,
    } };
}

fn cacheFenceFromState(state: markdown.State) Transcript.MarkdownFence {
    return switch (state.fence) {
        .none => .none,
        .backtick => .backtick,
        .tilde => .tilde,
    };
}

pub fn statusRows(app: *App) usize {
    if (app.status.count(.status_line) == 0) return 0;
    if (app.height == 0) return 0;
    if (@as(usize, app.height) <= composerRows(app) + pickerRows(app)) return 0;
    return 1;
}

pub fn greeterRows(app: *App) usize {
    if (app.greeter == null or app.transcript.items.items.len != 0) return 0;
    if (app.height == 0) return 0;
    const rows = Greeter.row_count;
    const occupied = composerRows(app) + pickerRows(app) + statusRows(app);
    if (@as(usize, app.height) < occupied + rows) return 0;
    return rows;
}

pub fn composerRows(app: *App) usize {
    const text_width = composerTextWidth(app.width);
    return @min(app.composer.visualRows(text_width), Composer.visible_rows_max) + 2;
}

pub fn pickerRows(app: *App) usize {
    const picker = app.visiblePicker() orelse return 0;
    if (app.height < 4) return 0;
    const match_count = picker.matchCount();
    const footer_rows: usize = if (picker.isTruncated()) 1 else 0;
    const body_rows = if (picker.minVisibleRows() > 0)
        picker.minVisibleRows()
    else
        @min(@max(match_count, 1), Picker.visible_rows_max) + footer_rows;
    // Picker is chromeless: no border, no title. Modal pickers still need a
    // filter input row; inline completions borrow the composer as their filter.
    const chrome_rows: usize = if (app.visiblePickerFocusesFilter()) 1 else 0;
    // Keep at least a one-line composer box and its border budget visible;
    // the picker is below the composer and yields first on tiny terminals.
    const rows_max = @as(usize, app.height) -| 3;
    return @min(body_rows + chrome_rows, rows_max);
}

pub fn composerTextWidth(width: u16) u16 {
    return if (width > 2) width - 2 else 1;
}

// --- transcript ---

fn drawTranscript(app: *App, painter: *Painter, scratch: *RowScratch, visible_rows: usize) void {
    if (visible_rows == 0 or app.width == 0) return;
    const total = transcriptTotalRows(app);
    var skip_remaining = clampedScrollRows(app);
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
        const skip_from_bottom = skip_remaining;
        skip_remaining = 0;
        const draw_end = rows - skip_from_bottom;
        const draw_start = draw_end - @min(draw_end, sink.draw_remaining);
        if (tryDrawAssistantTailWindow(app, scratch, item, draw_start, draw_end, &sink)) continue;

        sink.skip_remaining = skip_from_bottom;
        var count: usize = 0;
        buildItemRowsFrame(scratch, &count, item, app.width, &app.theme, app.tools_expanded);
        std.debug.assert(count == rows); // memo and fresh build must agree
        // Rows are built top-down; the sink consumes newest-first.
        var k = count;
        while (k > 0 and sink.draw_remaining > 0) {
            k -= 1;
            sink.emit(scratch.rows[k]);
        }
    }
}

fn tryDrawAssistantTailWindow(
    app: *App,
    scratch: *RowScratch,
    item: *const Transcript.Item,
    draw_start: usize,
    draw_end: usize,
    sink: *RowSink,
) bool {
    if (item.body != .message or item.body.message.role != .assistant) return false;
    const stable_rows: usize = item.layout.markdown_stable_rows;
    if (stable_rows == 0 or draw_start < stable_rows) return false;

    var tail_count: usize = 0;
    buildAssistantMarkdownTailRows(scratch, &tail_count, item, app.width, &app.theme);
    if (draw_end - stable_rows > tail_count) return false;

    const tail_start = draw_start - stable_rows;
    var tail_index = draw_end - stable_rows;
    while (tail_index > tail_start and sink.draw_remaining > 0) {
        tail_index -= 1;
        sink.emit(scratch.rows[tail_index]);
    }
    return true;
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
    if (out) |scratch| scratch.reset();
    buildItemRowsFrame(out, count, item, width, theme, expanded);
}

fn buildItemRowsFrame(
    out: ?*RowScratch,
    count: *usize,
    item: *const Transcript.Item,
    width: u16,
    theme: *const theme_mod.Theme,
    expanded: bool,
) void {
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
        .custom => |custom| buildCustomRows(out, count, custom, width, theme),
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
        .custom => theme.transcript_text,
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

fn buildCustomRows(
    out: ?*RowScratch,
    count: *usize,
    custom: Transcript.Custom,
    width: u16,
    theme: *const theme_mod.Theme,
) void {
    const inner = innerWidth(width);
    if (custom.title.len > 0) {
        emitWrappedText(out, count, .{
            .prefix = "",
            .text = custom.title,
            .prefix_style = theme.status_accent,
            .text_style = theme.status_accent,
            .row_style = theme.transcript_text,
            .inner_width = inner,
        });
        putRow(out, count, .{ .row_style = theme.transcript_text });
    }
    switch (custom.format) {
        .plain => emitWrappedText(out, count, .{
            .prefix = "",
            .text = custom.text,
            .prefix_style = theme.transcript_text,
            .text_style = theme.transcript_text,
            .row_style = theme.transcript_text,
            .inner_width = inner,
        }),
        .markdown => buildMarkdownRows(out, count, custom.text, width, theme),
    }
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
        if (count.* >= item_rows_max) return;
        emitMarkdownProjection(out, count, markdown.classifyLine(&state, line, theme), inner, theme);
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
    // Error/cancel rail tints only the result/body chrome; the title stays plain.
    const rail = toolRail(tool.status, theme);
    const inner = innerWidth(width);

    var title_buffer: [title_bytes_max]u8 = undefined;
    const title_available = width -| padding_x;
    const title = internText(out, fitToWidth(toolTitle(tool, expanded, &title_buffer), title_available));
    putRow(out, count, .{
        .text = title,
        .segments = toolTitleSegments(out, tool, title, theme),
        .text_style = theme.tool_title,
    });

    var notice_buffer: [notice_bytes_max]u8 = undefined;
    const notice = omissionNotice(tool, &notice_buffer);
    const has_body_chrome = notice != null or toolBodyVisible(tool, expanded);
    if (has_body_chrome) putRow(out, count, .{ .text = glyphs.tool_top_line, .text_style = rail, .row_style = rail });

    if (notice) |text| {
        emitWrappedText(out, count, .{
            .prefix = glyphs.tool_body_prefix,
            .text = internText(out, text),
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

    if (has_body_chrome) {
        putRow(out, count, .{ .text = glyphs.tool_bottom_line, .text_style = rail, .row_style = rail });
    }

    if (tool.footer.len > 0) {
        var footer_buffer: [footer_bytes_max]u8 = undefined;
        const footer_available = width -| padding_x;
        const footer = internText(out, fitToWidth(toolFooter(tool, &footer_buffer), footer_available));
        putRow(out, count, .{
            .text = footer,
            .text_style = theme.transcript_secondary,
            .row_style = theme.transcript_secondary,
        });
    }
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
    const prefix_width: u16 = @intCast(@min(text_mod.displayWidth(glyphs.tool_body_prefix), inner));
    const body_rows_total = countWrappedRows(body, inner, prefix_width);
    const rows_max: usize = tool.collapse.rows_max;

    var options: WrapOptions = .{
        .prefix = glyphs.tool_body_prefix,
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
        .prefix = glyphs.tool_body_prefix,
        .text = internText(out, collapseHint(&hint_buffer, tool.collapse.mode, hidden)),
        .show_prefix = true,
        .prefix_style = rail,
        .text_style = theme.transcript_secondary,
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
    continuation_prefix: []const u8 = "",
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
    var start: usize = 0;
    var visual_index: usize = 0;
    var window_index: usize = 0;
    while (start < options.text.len) : (visual_index += 1) {
        if (count.* >= item_rows_max) return;
        const prefix = wrapPrefix(options, visual_index);
        const prefix_width: u16 = @intCast(@min(text_mod.displayWidth(prefix), options.inner_width));
        const width = options.inner_width - prefix_width;
        var row: Row = .{
            .prefix = prefix,
            .show_prefix = prefix.len > 0,
            .prefix_style = options.prefix_style,
            .text_style = options.text_style,
            .row_style = options.row_style,
        };
        if (width == 0) {
            emitWindowed(out, count, &window_index, options.window, row);
            return;
        }
        const visual = text_mod.nextVisualLineBreak(options.text, start, width);
        if (visual.next == start) break;
        const line_style = bodyLineStyle(options, visual.start);
        row.text = options.text[visual.start..visual.end];
        row.text_style = line_style;
        if ((options.presentation orelse .generic) == .patch) row.row_style = line_style;
        emitWindowed(out, count, &window_index, options.window, row);
        start = visual.next;
    }
    if (options.text.len == 0 and count.* < item_rows_max) {
        const prefix = wrapPrefix(options, 0);
        emitWindowed(out, count, &window_index, options.window, .{
            .prefix = prefix,
            .show_prefix = prefix.len > 0,
            .prefix_style = options.prefix_style,
            .text_style = options.text_style,
            .row_style = options.row_style,
        });
    }
}

fn wrapPrefix(options: WrapOptions, visual_index: usize) []const u8 {
    if (visual_index == 0 or options.repeat_prefix) return options.prefix;
    return options.continuation_prefix;
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
            return rows;
        }
        const visual = text_mod.nextVisualLineBreak(text, start, width);
        if (visual.next == start) break;
        rows += 1;
        start = visual.next;
    }
    return rows;
}

/// Tool notices and patch bodies tint by their physical line start.
fn bodyLineStyle(options: WrapOptions, offset: usize) theme_mod.Style {
    const theme = options.theme orelse return options.text_style;
    const line_start = physicalLineStart(options.text, offset);
    if (line_start >= options.text.len) return options.text_style;
    if (isToolWarningLine(options.text[line_start..])) return theme.status_warning;
    if ((options.presentation orelse .generic) != .patch) return options.text_style;
    if (std.mem.startsWith(u8, options.text[line_start..], "@@")) return theme.transcript_secondary;
    return switch (options.text[line_start]) {
        '+' => theme.diff_add,
        '-' => theme.diff_del,
        else => options.text_style,
    };
}

fn isToolWarningLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "[Truncated:") or
        std.mem.startsWith(u8, line, "[First line") or
        std.mem.startsWith(u8, line, "[Line ") or
        std.mem.startsWith(u8, line, "[Showing ") or
        std.mem.startsWith(u8, line, "[Write omitted") or
        std.mem.startsWith(u8, line, "[File omitted");
}

fn physicalLineStart(text: []const u8, offset: usize) usize {
    var pos = @min(offset, text.len);
    while (pos > 0 and text[pos - 1] != '\n') pos -= 1;
    return pos;
}

// The adapter formats the full pi-mono-style title into `title`
// ("$ cmd", "read path:1-20", ...); the tool name is only a fallback.
fn toolTitle(tool: *const Transcript.Tool, expanded: bool, buffer: *[title_bytes_max]u8) []const u8 {
    const title = if (!expanded and tool.compact_title.len > 0) tool.compact_title else tool.title;
    const base = if (title.len == 0) tool.name else title;
    if (tool.status == .canceled) {
        const suffix = " (canceled)";
        const clipped = text_mod.utf8Prefix(base, buffer.len -| suffix.len);
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ clipped, suffix }) catch suffix;
    }
    if (base.len <= buffer.len) return base;
    return text_mod.utf8Prefix(base, buffer.len);
}

fn toolRail(status: Transcript.ToolStatus, theme: *const theme_mod.Theme) theme_mod.Style {
    return switch (status) {
        .err => theme.status_error,
        .canceled => theme.transcript_secondary,
        .pending, .success => theme.tool_chrome,
    };
}

fn toolTitleSegments(
    out: ?*RowScratch,
    tool: *const Transcript.Tool,
    title: []const u8,
    theme: *const theme_mod.Theme,
) []const RowSegment {
    if (title.len == 0) return &.{};
    var parts: [8]RowSegment = undefined;
    var count: usize = 0;
    const first_space = std.mem.findScalar(u8, title, ' ') orelse {
        parts[count] = .{ .text = title, .style = theme.tool_title };
        count += 1;
        return internSegments(out, parts[0..count]);
    };
    addTitleSegment(&parts, &count, title[0..first_space], theme.tool_title);
    addTitleSegment(&parts, &count, title[first_space .. first_space + 1], theme.transcript_secondary);
    const rest = title[first_space + 1 ..];

    if (std.mem.endsWith(u8, title, " (ctrl+o to expand)")) {
        addHintedTitleRest(&parts, &count, rest, theme);
    } else switch (tool.presentation) {
        .file, .patch => addFileTitleRest(&parts, &count, rest, theme),
        .command => addCommandTitleRest(&parts, &count, rest, theme),
        .generic => addTitleSegment(&parts, &count, rest, theme.tool_title),
    }
    return internSegments(out, parts[0..count]);
}

fn addTitleSegment(
    parts: *[8]RowSegment,
    count: *usize,
    text: []const u8,
    style: theme_mod.Style,
) void {
    if (text.len == 0 or count.* == parts.len) return;
    parts[count.*] = .{ .text = text, .style = style };
    count.* += 1;
}

fn addHintedTitleRest(parts: *[8]RowSegment, count: *usize, rest: []const u8, theme: *const theme_mod.Theme) void {
    const hint = " (ctrl+o to expand)";
    const body = rest[0 .. rest.len - hint.len];
    addFileTitleRest(parts, count, body, theme);
    addTitleSegment(parts, count, hint, theme.transcript_secondary);
}

fn addFileTitleRest(parts: *[8]RowSegment, count: *usize, rest: []const u8, theme: *const theme_mod.Theme) void {
    if (lineRangeStart(rest)) |range_start| {
        addTitleSegment(parts, count, rest[0..range_start], theme.status_accent);
        addTitleSegment(parts, count, rest[range_start..], theme.status_warning);
    } else {
        addTitleSegment(parts, count, rest, theme.status_accent);
    }
}

fn addCommandTitleRest(parts: *[8]RowSegment, count: *usize, rest: []const u8, theme: *const theme_mod.Theme) void {
    const timeout = " (timeout ";
    if (std.mem.findLast(u8, rest, timeout)) |index| {
        addTitleSegment(parts, count, rest[0..index], theme.tool_title);
        addTitleSegment(parts, count, rest[index..], theme.transcript_secondary);
    } else {
        addTitleSegment(parts, count, rest, theme.tool_title);
    }
}

fn lineRangeStart(text: []const u8) ?usize {
    const colon = std.mem.findScalarLast(u8, text, ':') orelse return null;
    if (colon + 1 >= text.len or !std.ascii.isDigit(text[colon + 1])) return null;
    for (text[colon + 1 ..]) |byte| {
        if (!std.ascii.isDigit(byte) and byte != '-') return null;
    }
    return colon;
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

fn toolFooter(tool: *const Transcript.Tool, buffer: *[footer_bytes_max]u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeByte('[') catch return "";
    const max_body = buffer.len -| 2;
    writer.writeAll(text_mod.utf8Prefix(tool.footer, max_body)) catch return "";
    writer.writeByte(']') catch return "";
    return writer.buffered();
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

// --- greeter ---

const greeter_logo = [_][]const u8{
    "  ░▀▀█░▀█▀",
    "  ░▄▀░░░█░",
    "  ░▀▀▀░▀▀▀",
};

fn drawGreeter(app: *App, painter: *Painter, y: u16) void {
    const greeter = if (app.greeter) |*value| value else return;
    var row: usize = 0;
    while (row < Greeter.row_count) : (row += 1) {
        const row_y: u16 = @intCast(@as(usize, y) + row);
        if (row_y >= app.height) return;
        painter.writeText(0, row_y, greeter_logo[row], app.theme.transcript_secondary);
        const text = switch (row) {
            0 => greeter.titleSlice(),
            1 => greeter.subtitleSlice(),
            else => "",
        };
        if (text.len == 0) continue;
        const text_x = advance(0, text_mod.displayWidth(greeter_logo[row]) + 3);
        if (text_x >= app.width) continue;
        const available = @as(usize, app.width) - text_x;
        painter.writeText(text_x, row_y, fitToWidth(text, available), app.theme.transcript_secondary);
    }
}

// --- status line ---

fn statusShimmerConfig(theme: *const theme_mod.Theme) shimmer.Config {
    return .{
        .base_style = theme.shimmer_base,
        .peak_style = theme.shimmer_peak,
    };
}

fn drawStatusLine(app: *App, painter: *Painter, y: u16) void {
    if (app.width == 0) return;
    painter.fillRect(0, y, app.width, 1, app.theme.app_bg);
    _ = drawPersistentStatusLine(app, painter, y);
}

fn drawPersistentStatusLine(app: *App, painter: *Painter, y: u16) u16 {
    var views: [status_mod.entry_count_max]status_mod.View = undefined;
    const view_count = app.status.ordered(.status_line, views[0..]);
    var x: u16 = 0;
    var rendered_any = false;
    for (views[0..view_count]) |view| {
        if (view.text.len == 0) continue;
        const remaining: usize = if (x < app.width) app.width - x else 0;
        if (remaining == 0) return x;
        const separator_width: usize = if (rendered_any) text_mod.displayWidth(glyphs.status_separator) else 0;
        if (separator_width >= remaining) return x;
        const available = remaining - separator_width;
        const fitted = fitToWidth(view.text, available);
        if (fitted.len == 0) continue;

        if (rendered_any) {
            painter.writeText(x, y, glyphs.status_separator, app.theme.transcript_secondary);
            x = advance(x, separator_width);
        }
        switch (view.effect) {
            .none => {
                painter.writeText(x, y, fitted, statusToneStyle(view.tone, &app.theme));
                x = advance(x, text_mod.displayWidth(fitted));
            },
            .shimmer => x = drawShimmerText(painter, x, y, fitted, app.now_ms, statusShimmerConfig(&app.theme)),
            .shuffle => x = drawShuffleText(
                painter,
                x,
                y,
                fitted,
                app.now_ms,
                view.started_ms,
                statusToneStyle(view.tone, &app.theme),
            ),
        }
        rendered_any = true;
    }
    return x;
}

fn drawNotifyOverlay(
    app: *App,
    painter: *Painter,
    scratch: *RowScratch,
    composer_rows: usize,
    picker_rows: usize,
    status_rows: usize,
) void {
    var views: [notify_mod.item_count_max]notify_mod.View = undefined;
    const view_count = app.notify.ordered(app.now_ms, views[0..]);
    if (view_count == 0 or app.width == 0) return;

    const reserved_bottom = composer_rows + picker_rows;
    if (@as(usize, app.height) <= reserved_bottom) return;
    const base_y = @as(usize, app.height) - reserved_bottom - 1;
    const status_left = if (status_rows > 0) statusLineWidth(app) else 0;
    var text_buffer: [notify_mod.text_bytes_max + notify_mod.annote_bytes_max + 32]u8 = undefined;

    for (views[0..view_count], 0..) |view, index| {
        if (index > base_y) return;
        const y: u16 = @intCast(base_y - index);
        const left_limit = if (index == 0 and status_left > 0)
            @min(@as(usize, app.width), status_left + text_mod.displayWidth(glyphs.status_separator))
        else
            0;
        if (left_limit >= app.width) continue;

        const text = formatNotifyText(&text_buffer, scratch, view);
        const fitted = fitToWidth(text, app.width - left_limit);
        if (fitted.len == 0) continue;
        const width = text_mod.displayWidth(fitted);
        const x = @as(usize, app.width) - width;
        painter.fillRect(@intCast(x), y, @intCast(width), 1, app.theme.app_bg);
        _ = drawShuffleText(
            painter,
            @intCast(x),
            y,
            fitted,
            app.now_ms,
            view.started_ms,
            statusToneStyle(view.tone, &app.theme),
        );
    }
}

fn statusLineWidth(app: *App) usize {
    var views: [status_mod.entry_count_max]status_mod.View = undefined;
    const view_count = app.status.ordered(.status_line, views[0..]);
    var width: usize = 0;
    var rendered_any = false;
    for (views[0..view_count]) |view| {
        if (view.text.len == 0) continue;
        if (rendered_any) width += text_mod.displayWidth(glyphs.status_separator);
        width += text_mod.displayWidth(view.text);
        rendered_any = true;
    }
    return @min(width, app.width);
}

fn formatNotifyText(buffer: []u8, scratch: *RowScratch, view: notify_mod.View) []const u8 {
    if (view.count > 1 and view.annote.len > 0) {
        const text = std.fmt.bufPrint(
            buffer,
            "({d}x) {s} {s}",
            .{ view.count, view.message, view.annote },
        ) catch return view.message;
        return internText(scratch, text);
    }
    if (view.count > 1) {
        const text = std.fmt.bufPrint(buffer, "({d}x) {s}", .{ view.count, view.message }) catch return view.message;
        return internText(scratch, text);
    }
    if (view.annote.len > 0) {
        const text = std.fmt.bufPrint(buffer, "{s} {s}", .{ view.message, view.annote }) catch return view.message;
        return internText(scratch, text);
    }
    return view.message;
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

fn statusToneStyle(tone: status_mod.Tone, theme: *const theme_mod.Theme) theme_mod.Style {
    return switch (tone) {
        .secondary => theme.transcript_secondary,
        .accent => theme.status_accent,
        .canceled => theme.status_canceled,
        .warning => theme.status_warning,
        .err => theme.status_error,
    };
}

fn drawShuffleText(
    painter: *Painter,
    x: u16,
    y: u16,
    text: []const u8,
    now_ms: i64,
    start_ms: i64,
    style: theme_mod.Style,
) u16 {
    const config: shuffle_text.Config = .{};
    const span_count = shuffle_text.countSpans(text);
    var cursor_x = x;
    var index: usize = 0;
    var span_index: usize = 0;
    while (shuffle_text.nextSpan(text, index)) |span| {
        if (cursor_x >= painter.width) break;
        const rendered = shuffle_text.renderedSpan(config, text, span, span_index, span_count, now_ms, start_ms);
        painter.writeText(cursor_x, y, rendered, style);
        cursor_x = advance(cursor_x, text_mod.displayWidth(rendered));
        index = span.start + span.len;
        span_index += 1;
    }
    return cursor_x;
}

fn advance(x: u16, width: usize) u16 {
    return @intCast(@min(@as(usize, std.math.maxInt(u16)), @as(usize, x) + width));
}

// --- composer ---

fn drawComposer(app: *App, painter: *Painter, composer_rows: usize, bottom_reserved: usize) void {
    if (composer_rows < 3 or app.height == 0 or app.width == 0) return;
    const available_bottom = @as(usize, app.height) -| bottom_reserved;
    const height = @min(composer_rows, available_bottom);
    if (height < 3) return;
    const box_y: u16 = @intCast(available_bottom - height);
    const box_height: u16 = @intCast(height);
    if (app.width >= 2 and box_height >= 2) {
        painter.roundedBorder(0, box_y, app.width, box_height, app.theme.composer_chrome);
        if (app.width >= 4) {
            drawComposerSlots(app, painter, box_y, .composer_left, .composer_right);
            drawComposerSlots(
                app,
                painter,
                @intCast(@as(usize, box_y) + height - 1),
                .composer_bottom_left,
                .composer_bottom_right,
            );
        }
    }

    var rows: [Composer.visible_rows_max]Composer.VisualRow = undefined;
    const projection = app.composer.visibleRows(composerTextWidth(app.width), &rows);
    const visible_count = @min(projection.visible_count, height - 2);
    var index: usize = 0;
    while (index < visible_count) : (index += 1) {
        const y: u16 = @intCast(@as(usize, box_y) + 1 + index);
        if (app.width > 2) painter.writeText(1, y, rows[index].text, app.theme.composer_text);
    }
    if (projection.cursor_visible) {
        const cursor_y = @as(usize, box_y) + 1 + projection.cursor_visible_row;
        const cursor_x = 1 + projection.cursor_display_col;
        if (cursor_x < app.width and cursor_y < app.height) {
            painter.setCursor(@intCast(cursor_x), @intCast(cursor_y));
        }
    }
}

fn drawComposerSlots(
    app: *App,
    painter: *Painter,
    y: u16,
    left_slot: status_mod.Slot,
    right_slot: status_mod.Slot,
) void {
    const inner = app.width - 2;
    const left_x: usize = 2;
    var right_start: usize = @as(usize, app.width) - 2;
    var right_visible = false;
    if (app.status.highestPriority(right_slot)) |view| {
        const label_width = text_mod.displayWidth(view.text);
        if (inner >= 2 + label_width) {
            right_start = @as(usize, app.width) - 2 - label_width;
            painter.writeText(@intCast(right_start), y, view.text, app.theme.composer_slot);
            right_visible = true;
        }
    }
    if (app.status.highestPriority(left_slot)) |view| {
        const available = if (right_visible)
            right_start -| (left_x + 1)
        else
            @as(usize, app.width) -| (left_x + 2);
        const label = fitToWidth(view.text, available);
        if (label.len > 0) painter.writeText(@intCast(left_x), y, label, app.theme.composer_slot);
    }
}

// --- picker ---

fn drawPicker(app: *App, picker: *const Picker, painter: *Painter, rows_reserved: usize, focus_filter: bool) void {
    if (app.width < 4 or app.height < 4) return;

    const match_count = picker.matchCount();
    const chrome_rows: usize = if (focus_filter) 1 else 0;
    const footer_rows: usize = if (picker.isTruncated()) 1 else 0;
    if (rows_reserved < chrome_rows + 1) return;
    const body_rows = rows_reserved - chrome_rows;
    const item_rows = if (body_rows > footer_rows) body_rows - footer_rows else body_rows;
    const box_width: u16 = app.width;
    const x: u16 = 0;
    const y: u16 = @intCast(@as(usize, app.height) - rows_reserved);

    // Clear the area behind the picker so it does not composite over the
    // transcript. Row background and text roles are separate so selection can
    // highlight the full row instead of only printed glyph cells.
    painter.fillRect(x, y, box_width, @intCast(rows_reserved), app.theme.picker_row);

    const inner_width = if (box_width > 2) @as(usize, box_width) - 2 else 1;
    const item_start_row: usize = if (focus_filter) 1 else 0;
    if (focus_filter) {
        const query = fitToWidth(picker.querySlice(), inner_width);
        painter.writeText(x + 1, y, query, app.theme.picker_filter);
        painter.setCursor(advance(x + 1, text_mod.displayWidth(query)), y);
    }

    if (match_count == 0) {
        painter.writeText(
            x + 1,
            @intCast(@as(usize, y) + item_start_row),
            "no matches",
            app.theme.picker_empty,
        );
        return;
    }

    const selected_ordinal = picker.selectedOrdinal() orelse 0;
    const first_ordinal = if (selected_ordinal >= item_rows) selected_ordinal - item_rows + 1 else 0;
    var row: usize = 0;
    while (row < item_rows) : (row += 1) {
        const item_index = picker.nthMatchIndex(first_ordinal + row) orelse break;
        const item = picker.itemAt(item_index);
        const selected = picker.selectedIndex() orelse std.math.maxInt(usize);
        const is_selected = item_index == selected;
        const row_y: u16 = @intCast(@as(usize, y) + item_start_row + row);
        const marker = if (is_selected) glyphs.picker_selected else glyphs.picker_unselected;
        const row_style = if (is_selected) app.theme.picker_selected_row else app.theme.picker_row;
        const item_style = if (is_selected) app.theme.picker_selected_item else app.theme.picker_item;
        const detail_style = if (is_selected) app.theme.picker_selected_detail else app.theme.picker_detail;
        painter.fillRect(x, row_y, box_width, 1, row_style);
        painter.writeText(x + 1, row_y, marker, item_style);
        switch (picker.layout) {
            .line => drawLinePickerItem(app, painter, item, x, row_y, inner_width, item_style, detail_style),
            .two_column => drawTwoColumnPickerItem(app, painter, item, x, row_y, inner_width, item_style, detail_style),
            .four_column => drawFourColumnPickerItem(app, painter, item, x, row_y, inner_width, item_style, detail_style),
        }
    }

    if (footer_rows > 0) {
        const footer_y: u16 = @intCast(@as(usize, y) + rows_reserved - 1);
        const message = if (picker.omittedCount() > 0)
            "results truncated; keep typing"
        else
            "scan truncated; keep typing";
        painter.writeText(x + 1, footer_y, fitToWidth(message, inner_width), app.theme.picker_detail);
    }
}

fn drawLinePickerItem(
    app: *App,
    painter: *Painter,
    item: *const Picker.OwnedItem,
    x: u16,
    row_y: u16,
    inner_width: usize,
    item_style: theme_mod.Style,
    detail_style: theme_mod.Style,
) void {
    _ = app;
    const label_x = x + 3;
    const label_width = inner_width -| 2;
    const label = fitToWidth(item.labelSlice(), label_width);
    painter.writeText(label_x, row_y, label, item_style);
    const used = text_mod.displayWidth(label) + 2;
    const detail = item.detailSlice();
    if (detail.len > 0 and used + 2 < inner_width) {
        const detail_x = advance(x + 1, used + 2);
        painter.writeText(detail_x, row_y, fitToWidth(detail, inner_width - used - 2), detail_style);
    }
}

fn drawTwoColumnPickerItem(
    app: *App,
    painter: *Painter,
    item: *const Picker.OwnedItem,
    x: u16,
    row_y: u16,
    inner_width: usize,
    item_style: theme_mod.Style,
    detail_style: theme_mod.Style,
) void {
    _ = app;
    const label_x = x + 3;
    const content_width = inner_width -| 2;
    if (content_width == 0) return;

    const detail = item.detailSlice();
    if (detail.len == 0 or content_width < 24) {
        painter.writeText(label_x, row_y, fitToWidth(item.labelSlice(), content_width), item_style);
        return;
    }

    const detail_width = @min(@as(usize, 28), @max(@as(usize, 12), content_width / 3));
    const gap_width: usize = 2;
    if (content_width <= detail_width + gap_width) {
        painter.writeText(label_x, row_y, fitToWidth(item.labelSlice(), content_width), item_style);
        return;
    }

    const label_width = content_width - detail_width - gap_width;
    drawPickerCell(painter, label_x, row_y, item.labelSlice(), label_width, .left, item_style);
    drawPickerCell(painter, advance(label_x, label_width + gap_width), row_y, detail, detail_width, .left, detail_style);
}

fn drawFourColumnPickerItem(
    app: *App,
    painter: *Painter,
    item: *const Picker.OwnedItem,
    x: u16,
    row_y: u16,
    inner_width: usize,
    item_style: theme_mod.Style,
    detail_style: theme_mod.Style,
) void {
    const start_x = x + 3;
    const content_width = inner_width -| 2;
    if (content_width == 0) return;
    if (content_width < 44) {
        drawTwoColumnPickerItem(app, painter, item, x, row_y, inner_width, item_style, detail_style);
        return;
    }

    const gap: usize = 2;
    const detail_width: usize = 16;
    const meta_width: usize = 8;
    const aux_width: usize = 10;
    const fixed = detail_width + meta_width + aux_width + gap * 3;
    if (content_width <= fixed) {
        drawTwoColumnPickerItem(app, painter, item, x, row_y, inner_width, item_style, detail_style);
        return;
    }

    const label_width = content_width - fixed;
    var cell_x = start_x;
    drawPickerCell(painter, cell_x, row_y, item.labelSlice(), label_width, .left, item_style);
    cell_x = advance(cell_x, label_width + gap);
    drawPickerCell(painter, cell_x, row_y, item.detailSlice(), detail_width, .left, detail_style);
    cell_x = advance(cell_x, detail_width + gap);
    drawPickerCell(painter, cell_x, row_y, item.metaSlice(), meta_width, .right, detail_style);
    cell_x = advance(cell_x, meta_width + gap);
    drawPickerCell(painter, cell_x, row_y, item.auxSlice(), aux_width, .left, detail_style);
}

const PickerCellAlign = enum { left, right };

fn drawPickerCell(
    painter: *Painter,
    x: u16,
    y: u16,
    text: []const u8,
    width: usize,
    alignment: PickerCellAlign,
    style: theme_mod.Style,
) void {
    if (width == 0 or text.len == 0) return;
    const clipped = fitToWidth(text, width);
    const used = text_mod.displayWidth(clipped);
    const offset = switch (alignment) {
        .left => 0,
        .right => width -| used,
    };
    painter.writeText(advance(x, offset), y, clipped, style);
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

    fn clear(self: *Painter, style: theme_mod.Style) void {
        self.vx.window().clear();
        self.vx.window().hideCursor();
        self.fillRect(0, 0, self.width, self.height, style);
    }

    fn writeText(self: *Painter, x: u16, y: u16, bytes: []const u8, style: theme_mod.Style) void {
        if (x >= self.width or y >= self.height or bytes.len == 0) return;
        const segment: vaxis.Segment = .{ .text = bytes, .style = style };
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
        if (row.segments.len > 0) {
            for (row.segments) |segment| {
                if (x >= self.width) break;
                self.writeText(x, y, segment.text, segment.style);
                x = advance(x, text_mod.displayWidth(segment.text));
            }
        } else if (x < self.width and row.text.len > 0) {
            self.writeText(x, y, row.text, row.text_style);
            x = advance(x, text_mod.displayWidth(row.text));
        }
    }
};

// --- tests ---

const testing_gpa = std.testing.allocator;

fn countItem(app: *App, index: usize) usize {
    const item = &app.transcript.items.items[index];
    return itemRows(item, app.width, &app.theme, app.tools_expanded);
}

test "wrapped row counting terminates when width is zero" {
    try std.testing.expectEqual(@as(usize, 1), countWrappedRows("abc", 0, 0));
    try std.testing.expectEqual(@as(usize, 1), countWrappedRows("abc", 1, 1));
}

test "collapsed tool body shows a bounded window with a hint row" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .collapse = .{ .mode = .tail, .rows_max = 5 },
        .title = "$ seq 8",
    } });
    _ = try app.transcript.appendToolOutput(testing_gpa, "call-1", "1\n2\n3\n4\n5\n6\n7\n8", 0, 0);

    // Collapsed: title + top + hint + 5 window rows + bottom + margin.
    try std.testing.expectEqual(@as(usize, 10), countItem(&app, 0));

    // Expanded: title + top + all 8 body rows + bottom + margin, no hint.
    app.tools_expanded = true;
    try std.testing.expectEqual(@as(usize, 12), countItem(&app, 0));
}

test "head-collapsed tool keeps the first rows with the hint below" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "custom",
        .collapse = .{ .mode = .head, .rows_max = 2 },
    } });
    _ = try app.transcript.appendToolOutput(testing_gpa, "call-1", "a\nb\nc\nd", 0, 0);

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    // Top-down: title, top border, window rows a/b, hint, bottom, margin.
    try std.testing.expectEqualStrings(glyphs.tool_top_line, scratch.rows[1].text);
    try std.testing.expectEqualStrings("a", scratch.rows[2].text);
    try std.testing.expectEqualStrings("b", scratch.rows[3].text);
    try std.testing.expect(std.mem.indexOf(u8, scratch.rows[4].text, "more lines") != null);
    try std.testing.expectEqual(@as(usize, 7), count);
}

test "tool warning body lines use warning style" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "custom",
        .title = "custom output",
    } });
    _ = try app.transcript.appendToolOutput(
        testing_gpa,
        "call-1",
        "src/main.zig:1: foo\n[Truncated: output clipped]",
        0,
        0,
    );

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    try std.testing.expectEqualStrings(glyphs.tool_top_line, scratch.rows[1].text);
    try std.testing.expectEqualStrings("src/main.zig:1: foo", scratch.rows[2].text);
    try std.testing.expectEqual(app.theme.tool_output, scratch.rows[2].text_style);
    try std.testing.expectEqualStrings("[Truncated: output clipped]", scratch.rows[3].text);
    try std.testing.expectEqual(app.theme.status_warning, scratch.rows[3].text_style);
}

test "tool metadata footer renders outside the body rail" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .title = "$ sleep 1",
    } });
    _ = try app.transcript.replaceToolFooter(testing_gpa, "call-1", "Elapsed 1.0s");

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("$ sleep 1", scratch.rows[0].text);
    try std.testing.expectEqualStrings("[Elapsed 1.0s]", scratch.rows[1].text);
    try std.testing.expectEqualStrings("", scratch.rows[2].text);
}

test "tool metadata footer follows the body rail" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .title = "$ echo hi",
    } });
    _ = try app.transcript.replaceToolOutput(testing_gpa, "call-1", "hi");
    _ = try app.transcript.replaceToolFooter(testing_gpa, "call-1", "Took 0.1s");

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    try std.testing.expectEqualStrings(glyphs.tool_top_line, scratch.rows[1].text);
    try std.testing.expectEqualStrings("hi", scratch.rows[2].text);
    try std.testing.expectEqualStrings(glyphs.tool_bottom_line, scratch.rows[3].text);
    try std.testing.expectEqualStrings("[Took 0.1s]", scratch.rows[4].text);
}

test "successful read hides body until expanded" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "read",
        .presentation = .file,
        .status = .success,
        .body_mode = .hidden_on_success,
        .collapse = .{ .mode = .head, .rows_max = 10 },
        .title = "read src/main.zig:1-2",
    } });
    _ = try app.transcript.appendToolOutput(testing_gpa, "call-1", "one\ntwo", 0, 0);

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("read src/main.zig:1-2", scratch.rows[0].text);
    try std.testing.expectEqualStrings("", scratch.rows[1].text);

    count = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, true);
    try std.testing.expectEqual(@as(usize, 6), count);
    try std.testing.expectEqualStrings(glyphs.tool_top_line, scratch.rows[1].text);
    try std.testing.expectEqualStrings("one", scratch.rows[2].text);
    try std.testing.expectEqualStrings("two", scratch.rows[3].text);
}

test "tool title uses compact text only while collapsed" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "read",
        .title = "read skills/review/SKILL.md:1-10",
        .compact_title = "[skill] review:1-10 (ctrl+o to expand)",
    } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);
    try std.testing.expectEqualStrings("[skill] review:1-10 (ctrl+o to expand)", scratch.rows[0].text);

    count = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, true);
    try std.testing.expectEqualStrings("read skills/review/SKILL.md:1-10", scratch.rows[0].text);
}

test "file tool title styles name path range and hint as segments" {
    var app = App.init(80, 24, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "read",
        .presentation = .file,
        .title = "read src/main.zig:1-20",
    } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    const title = scratch.rows[0];
    try std.testing.expectEqual(@as(usize, 4), title.segments.len);
    try std.testing.expectEqualStrings("read", title.segments[0].text);
    try std.testing.expectEqualStrings(" ", title.segments[1].text);
    try std.testing.expectEqualStrings("src/main.zig", title.segments[2].text);
    try std.testing.expectEqualStrings(":1-20", title.segments[3].text);
    try std.testing.expectEqual(app.theme.status_accent, title.segments[2].style);
    try std.testing.expectEqual(app.theme.status_warning, title.segments[3].style);
}

test "tool title is plain text outside the body rail and fits width" {
    var app = App.init(24, 8, .{});
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "read",
        .title = "read src/agent/Agent.zig:1-260 plus more text",
    } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    const title = scratch.rows[0];
    const used = padding_x + text_mod.displayWidth(title.text);
    try std.testing.expectEqualStrings("", title.prefix);
    try std.testing.expect(!title.show_prefix);
    try std.testing.expect(used <= app.width);
}

test "memoized item rows match a fresh build and invalidate on mutation" {
    var app = App.init(60, 24, .{});
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

test "picker reserves bottom rows and pushes composer/status upward" {
    var app = App.init(40, 16, .{});
    defer app.deinit(testing_gpa);

    const before = transcriptVisibleRows(&app);
    const items = [_]Picker.Item{
        .{ .id = "one", .label = "one" },
        .{ .id = "two", .label = "two" },
    };
    _ = try app.apply(testing_gpa, .{ .open_picker = .{ .id = 1, .items = &items } });

    const reserved = pickerRows(&app);
    try std.testing.expect(reserved > 0);
    try std.testing.expectEqual(before - reserved, transcriptVisibleRows(&app));
}

test "scroll max accounts for composer and status reservations" {
    var app = App.init(40, 10, .{});
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
    _ = app.status.set(.{ .slot = .status_line, .id = 1, .text = "working" }, 0);
    try std.testing.expectEqual(visible - 1, transcriptVisibleRows(&app));
}

test "composer top border draws cwd and session chrome without overlap" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 60, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(60, 8, .{});
    defer app.deinit(testing_gpa);
    _ = app.status.set(.{ .slot = .composer_left, .id = 1, .text = "/repo" }, 0);
    _ = app.status.set(.{ .slot = .composer_right, .id = 2, .text = "67.5%/272k • openai/gpt (high)" }, 0);

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "/repo"));
    try std.testing.expect(screenContainsText(vx.window(), "67.5%/272k"));
    try std.testing.expect(screenContainsText(vx.window(), "openai/gpt (high)"));
}

test "composer overflow window shows a scroll hint" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 32, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(32, 8, .{});
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .replace_composer_text = "a\nb\nc\nd\ne\nf" });
    _ = try app.apply(testing_gpa, .{ .input = .{ .key = .arrow_up } });
    _ = try app.apply(testing_gpa, .{ .input = .{ .key = .arrow_up } });
    _ = try app.apply(testing_gpa, .{ .input = .{ .key = .arrow_up } });
    _ = try app.apply(testing_gpa, .{ .input = .{ .key = .arrow_up } });
    try std.testing.expectEqual(@as(usize, 1), app.status.count(.composer_bottom_left));
    try std.testing.expectEqual(@as(usize, 0), app.status.count(.composer_bottom_right));

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "↑ 1 more · ↓ 1 more"));
}

test "notification overlay keeps formatted text alive for vaxis cells" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 40, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(40, 8, .{});
    defer app.deinit(testing_gpa);
    try std.testing.expectEqual(notify_mod.SetResult.ok, app.notify.notify(.{ .message = "hello" }, 0));
    app.now_ms = 1_000;

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "hello INFO"));
}

test "vaxis screen receives the frame" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 30, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(30, 8, .{});
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "hello vaxis",
    } } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try expectScreenText(vx.window(), 1, 0, "hello vaxis");
}

test "single command completion row remains visible below composer" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 40, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(40, 8, .{});
    defer app.deinit(testing_gpa);
    const items = [_]Picker.Item{
        .{ .id = "help", .label = "/help", .detail = "Show commands" },
        .{ .id = "model", .label = "/model", .detail = "Select model" },
    };
    _ = try app.apply(testing_gpa, .{ .set_composer_completions = .{ .id = 2, .items = &items } });
    _ = try app.apply(testing_gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/m") } });

    try std.testing.expectEqual(@as(usize, 1), pickerRows(&app));
    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "/model"));
}

test "history prepend is visible at the scrollback boundary" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 30, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(30, 8, .{});
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "newer one\nnewer two\nnewer three\nnewer four",
    } } });
    _ = try app.apply(testing_gpa, .{ .prepend_transcript = .{ .message = .{
        .role = .user,
        .text = "fixture older row",
        .mode = .new_item,
    } } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "fixture older row"));
}

test "scrolled frame draws older rows and clamps to max" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);
    try vx.resize(testing_gpa, &writer, .{ .cols = 30, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(30, 8, .{});
    defer app.deinit(testing_gpa);
    var index: usize = 0;
    var label: [16]u8 = undefined;
    while (index < 10) : (index += 1) {
        const line = try std.fmt.bufPrint(&label, "line-{d}", .{index});
        _ = try app.transcript.append(testing_gpa, .{ .message = .{ .role = .assistant, .text = line } });
    }

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);

    app.viewport.scroll_rows = 10_000; // render clamps locally instead of blanking
    draw(&app, &vx, scratch);
    try expectScreenText(vx.window(), 1, 0, "line-0");
    try std.testing.expectEqual(@as(usize, 10_000), app.viewport.scroll_rows);
}

test "empty frame renders greeter above status and composer" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);
    try vx.resize(testing_gpa, &writer, .{ .cols = 60, .rows = 9, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(60, 9, .{});
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .set_greeter = .{
        .title = "zi 1.2.3",
        .subtitle = "Type / for commands. Ask zi about zi if you get lost.",
    } });
    _ = app.status.set(.{ .slot = .status_line, .id = 1, .text = "ready" }, 0);

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "░▀▀█░▀█▀"));
    try std.testing.expect(screenContainsText(vx.window(), "zi 1.2.3"));
    try std.testing.expect(screenContainsText(vx.window(), "Type / for commands"));
    try std.testing.expect(screenContainsText(vx.window(), "ready"));
}

test "greeter is empty-state chrome and hides once transcript exists" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);
    try vx.resize(testing_gpa, &writer, .{ .cols = 60, .rows = 9, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(60, 9, .{});
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .set_greeter = .{ .title = "zi 1.2.3" } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "hello",
    } } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(!screenContainsText(vx.window(), "░▀▀█░▀█▀"));
    try std.testing.expect(screenContainsText(vx.window(), "hello"));
}

fn screenContainsText(window: vaxis.Window, needle: []const u8) bool {
    var row: u16 = 0;
    while (row < window.height) : (row += 1) {
        var buffer: [512]u8 = undefined;
        var len: usize = 0;
        var col: u16 = 0;
        while (col < window.width) : (col += 1) {
            const cell = window.readCell(col, row) orelse continue;
            const grapheme = cell.char.grapheme;
            if (len + grapheme.len > buffer.len) break;
            @memcpy(buffer[len..][0..grapheme.len], grapheme);
            len += grapheme.len;
        }
        if (std.mem.indexOf(u8, buffer[0..len], needle) != null) return true;
    }
    return false;
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

test "markdown inline spans strip markers and keep styles" {
    const theme = theme_mod.Theme.kansoZen(.{});
    var scratch: RowScratch = undefined;
    scratch.reset();
    var count: usize = 0;

    buildMarkdownRows(&scratch, &count, "use `foo` and **bar**", 80, &theme);

    try std.testing.expectEqual(@as(usize, 1), count);
    const row = scratch.rows[0];
    try std.testing.expectEqual(@as(usize, 4), row.segments.len);
    try std.testing.expectEqualStrings("use ", row.segments[0].text);
    try std.testing.expectEqualStrings("foo", row.segments[1].text);
    try std.testing.expect(theme_mod.Style.eql(theme.tool_output, row.segments[1].style));
    try std.testing.expectEqualStrings(" and ", row.segments[2].text);
    try std.testing.expectEqualStrings("bar", row.segments[3].text);
    try std.testing.expect(row.segments[3].style.bold);

    var counted: usize = 0;
    buildMarkdownRows(null, &counted, "use `foo` and **bar**", 80, &theme);
    try std.testing.expectEqual(counted, count);
}

test "markdown list continuations align under marker" {
    const theme = theme_mod.Theme.kansoZen(.{});
    var scratch: RowScratch = undefined;
    scratch.reset();
    var count: usize = 0;

    buildMarkdownRows(&scratch, &count, "- abcdefgh", 8, &theme);

    try std.testing.expect(count >= 2);
    try std.testing.expectEqualStrings("- ", scratch.rows[0].prefix);
    try std.testing.expectEqualStrings("  ", scratch.rows[1].prefix);
}

test "assistant markdown row cache advances only at newline boundaries" {
    var app = App.init(40, 12, .{});
    defer app.deinit(testing_gpa);

    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "one\n",
    } } });
    const item = &app.transcript.items.items[0];
    try std.testing.expectEqual(@as(usize, 3), itemRows(item, app.width, &app.theme, app.tools_expanded));
    try std.testing.expectEqual(@as(usize, 4), item.layout.markdown_stable_end);
    try std.testing.expectEqual(@as(u32, 1), item.layout.markdown_stable_rows);

    var tail_count: usize = 0;
    buildAssistantMarkdownTailRows(null, &tail_count, item, app.width, &app.theme);
    try std.testing.expectEqual(@as(usize, 2), tail_count);

    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "two",
        .mode = .extend_previous_assistant_message,
    } } });
    try std.testing.expectEqual(@as(usize, 3), itemRows(item, app.width, &app.theme, app.tools_expanded));
    try std.testing.expectEqual(@as(usize, 4), item.layout.markdown_stable_end);
    try std.testing.expectEqual(@as(u32, 1), item.layout.markdown_stable_rows);

    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "\n",
        .mode = .extend_previous_assistant_message,
    } } });
    try std.testing.expectEqual(@as(usize, 4), itemRows(item, app.width, &app.theme, app.tools_expanded));
    try std.testing.expectEqual(@as(usize, 8), item.layout.markdown_stable_end);
    try std.testing.expectEqual(@as(u32, 2), item.layout.markdown_stable_rows);
    tail_count = 0;
    buildAssistantMarkdownTailRows(null, &tail_count, item, app.width, &app.theme);
    try std.testing.expectEqual(@as(usize, 2), tail_count);
}

test "canceled tool title renders terminal state" {
    const gpa = std.testing.allocator;
    var app = App.init(40, 8, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "call",
        .name = "bash",
        .title = "$ sleep 10",
    } } });
    _ = try app.apply(gpa, .mark_pending_tools_canceled);

    var buffer: [title_bytes_max]u8 = undefined;
    const title = toolTitle(&app.transcript.items.items[0].body.tool, true, &buffer);
    try std.testing.expectEqualStrings("$ sleep 10 (canceled)", title);
}

test "frame scratch keeps generated tool titles stable" {
    var env = try std.testing.environ.createMap(testing_gpa);
    defer env.deinit();
    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var deinit_writer = std.Io.Writer.Discarding.init(&.{});
    defer vx.deinit(testing_gpa, &deinit_writer.writer);
    var writer = std.Io.Writer.Discarding.init(&.{});
    try vx.resize(testing_gpa, &writer.writer, .{ .cols = 100, .rows = 60, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(100, 60, .{});
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .user,
        .text = "Run a single custom tool call",
    } } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "call-custom",
        .name = "custom",
        .status = .pending,
        .collapse = .{ .mode = .head, .rows_max = 20 },
        .title = "custom list",
    } } });
    _ = try app.apply(testing_gpa, .{ .replace_tool_output = .{
        .tool_call_id = "call-custom",
        .text = ".claude/\n.forks/\n.git/\n.github/\n.gitignore\n.pi/\n.references/\n.tmp/\n" ++
            ".zi/\n.zig-cache/\n.ziglint.zon\nAGENTS.md\nautoresearch.checks.sh\n" ++
            "autoresearch.ideas.md\nautoresearch.md\nautoresearch.sh\nbuild.zig\n" ++
            "build.zig.zon\nCONTEXT.md\ndocs/\n",
    } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "call-custom",
        .name = "custom",
        .status = .success,
        .collapse = .{ .mode = .head, .rows_max = 20 },
    } } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "Done.",
    } } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .user,
        .text = "run a single bash tool call",
    } } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "call-bash",
        .name = "bash",
        .presentation = .command,
        .status = .pending,
        .collapse = .{ .mode = .tail, .rows_max = 5 },
        .title = "$ pwd (timeout 10s)",
    } } });
    _ = try app.apply(testing_gpa, .{ .replace_tool_output = .{
        .tool_call_id = "call-bash",
        .text = "/Users/igors/workspace/dev/personal/zi",
    } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "call-bash",
        .name = "bash",
        .presentation = .command,
        .status = .success,
        .collapse = .{ .mode = .tail, .rows_max = 5 },
    } } });
    _ = try app.apply(testing_gpa, .{ .replace_tool_footer = .{
        .tool_call_id = "call-bash",
        .text = "Took 0.0s",
    } });
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "Done.",
    } } });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "$ pwd (timeout 10s)"));
}
