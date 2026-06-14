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
const Picker = @import("Picker.zig");
const input_mod = @import("input.zig");
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
const tool_title_prefix = "╭─[";
const tool_title_suffix = "]";
const tool_body_prefix = "│ ";
const tool_bottom_line = "╰───";
const hint_bytes_max: usize = 96;
const notice_bytes_max: usize = 96;
const title_bytes_max: usize = 160;

/// Bytes of formatted (non-borrowed) text one item can pin for its rows:
/// tool title, collapse hint, and omission notice. Static literals and
/// transcript text are borrowed and need no copy.
pub const generated_text_bytes_max: usize = 512;

pub const RowSegment = struct {
    text: []const u8,
    style: theme_mod.Style,
};

pub const Row = struct {
    prefix: []const u8 = "",
    text: []const u8 = "",
    suffix: []const u8 = "",
    segments: []const RowSegment = &.{},
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
    segments: [32]RowSegment = undefined,
    segment_len: usize = 0,
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
    var painter = Painter.init(vx);
    painter.clear();
    if (app.width == 0 or app.height == 0) return;

    painter.writeText(0, 0, "zi", app.theme.shell_label);
    const composer_rows = composerRows(app);
    const picker_rows = pickerRows(app);
    const status_rows = statusRows(app);
    drawTranscript(app, &painter, scratch, transcriptVisibleRows(app));
    if (status_rows > 0 and @as(usize, app.height) > composer_rows + picker_rows) {
        const y: u16 = @intCast(@as(usize, app.height) - picker_rows - composer_rows - 1);
        drawStatusLine(app, &painter, y);
    }
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
    const reserved = @min(composerRows(app) + statusRows(app) + pickerRows(app), body_rows);
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
    if (@as(usize, app.height) <= composerRows(app) + pickerRows(app)) return 0;
    return 1;
}

pub fn composerRows(app: *App) usize {
    const text_width = composerTextWidth(app.width);
    return @min(app.composer.visualRows(text_width), Composer.visible_rows_max) + 2;
}

pub fn pickerRows(app: *App) usize {
    const picker = app.visiblePicker() orelse return 0;
    if (app.height < 6) return 0;
    const match_count = picker.matchCount();
    const item_rows = @min(@max(match_count, 1), Picker.visible_rows_max);
    const chrome_rows: usize = if (app.visiblePickerFocusesFilter()) 3 else 2;
    // Keep at least a one-line composer box and its border budget visible;
    // the picker is below the composer and yields first on tiny terminals.
    const rows_max = @as(usize, app.height) -| 3;
    return @min(item_rows + chrome_rows, rows_max);
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
    if (out) |scratch| {
        scratch.text_len = 0;
        scratch.segment_len = 0;
    }
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
    const title_available = width -| (padding_x +
        text_mod.displayWidth(tool_title_prefix) +
        text_mod.displayWidth(tool_title_suffix));
    const title = internText(out, fitToWidth(toolTitle(tool, expanded, &title_buffer), title_available));
    putRow(out, count, .{
        .prefix = tool_title_prefix,
        .text = title,
        .suffix = tool_title_suffix,
        .segments = toolTitleSegments(out, tool, title, theme),
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

// The adapter formats the full pi-mono-style header into `title`
// ("$ cmd", "read path:1-20", ...); the tool name is only a fallback.
fn toolTitle(tool: *const Transcript.Tool, expanded: bool, buffer: *[title_bytes_max]u8) []const u8 {
    const title = if (!expanded and tool.compact_title.len > 0) tool.compact_title else tool.title;
    if (title.len == 0) return tool.name;
    if (title.len <= buffer.len) return title;
    return text_mod.utf8Prefix(title, buffer.len);
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
        .search => addSearchTitleRest(&parts, &count, rest, theme),
        .directory => addDirectoryTitleRest(&parts, &count, rest, theme),
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

fn addSearchTitleRest(parts: *[8]RowSegment, count: *usize, rest: []const u8, theme: *const theme_mod.Theme) void {
    if (rest.len > 0 and rest[0] == '/') {
        if (std.mem.findScalarPos(u8, rest, 1, '/')) |end| {
            addTitleSegment(parts, count, rest[0 .. end + 1], theme.status_accent);
            addTitleSegment(parts, count, rest[end + 1 ..], theme.transcript_secondary);
            return;
        }
    }
    addTitleSegment(parts, count, rest, theme.status_accent);
}

fn addDirectoryTitleRest(parts: *[8]RowSegment, count: *usize, rest: []const u8, theme: *const theme_mod.Theme) void {
    addTitleSegment(parts, count, rest, theme.status_accent);
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
            const inner = app.width - 2;
            const left_x: usize = 2;
            var right_start: usize = @as(usize, app.width) - 2;
            var right_visible = false;
            if (app.status.highestPriority(.composer_right)) |view| {
                const label_width = text_mod.displayWidth(view.text);
                if (inner >= 2 + label_width) {
                    right_start = @as(usize, app.width) - 2 - label_width;
                    painter.writeText(@intCast(right_start), box_y, view.text, app.theme.composer_slot);
                    right_visible = true;
                }
            }
            if (app.status.highestPriority(.composer_left)) |view| {
                const available = if (right_visible)
                    right_start -| (left_x + 1)
                else
                    @as(usize, app.width) -| (left_x + 2);
                const label = fitToWidth(view.text, available);
                if (label.len > 0) painter.writeText(@intCast(left_x), box_y, label, app.theme.composer_slot);
            }
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

// --- picker ---

fn drawPicker(app: *App, picker: *const Picker, painter: *Painter, rows_reserved: usize, focus_filter: bool) void {
    if (app.width < 8 or app.height < 6) return;

    const match_count = picker.matchCount();
    const chrome_rows: usize = if (focus_filter) 3 else 2;
    if (rows_reserved < chrome_rows + 1) return;
    const item_rows = @min(@max(match_count, 1), rows_reserved - chrome_rows);
    const box_width: u16 = app.width;
    const x: u16 = 0;
    const y: u16 = @intCast(@as(usize, app.height) - rows_reserved);

    painter.fillRect(x, y, box_width, @intCast(rows_reserved), .{});
    painter.roundedBorder(x, y, box_width, @intCast(rows_reserved), app.theme.composer_chrome);

    const inner_width = if (box_width > 4) @as(usize, box_width) - 4 else 1;
    const title = fitToWidth(picker.titleSlice(), inner_width);
    painter.writeText(x + 2, y, title, app.theme.status_accent);

    const item_start_row: usize = if (focus_filter) 2 else 1;
    if (focus_filter) {
        const filter_prefix = "filter: ";
        painter.writeText(x + 2, y + 1, filter_prefix, app.theme.transcript_secondary);
        const prefix_width = text_mod.displayWidth(filter_prefix);
        const query = fitToWidth(picker.querySlice(), inner_width -| prefix_width);
        const query_x = advance(x + 2, prefix_width);
        painter.writeText(query_x, y + 1, query, app.theme.composer_text);
        painter.setCursor(advance(query_x, text_mod.displayWidth(query)), y + 1);
    }

    if (match_count == 0) {
        painter.writeText(
            x + 2,
            @intCast(@as(usize, y) + item_start_row),
            "no matches",
            app.theme.transcript_secondary,
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
        const marker = if (is_selected) "> " else "  ";
        painter.writeText(
            x + 2,
            row_y,
            marker,
            if (is_selected) app.theme.status_accent else app.theme.transcript_secondary,
        );
        const label_x = x + 4;
        const label_width = inner_width -| 2;
        const label = fitToWidth(item.labelSlice(), label_width);
        painter.writeText(
            label_x,
            row_y,
            label,
            if (is_selected) app.theme.composer_text else app.theme.transcript_text,
        );
        const used = text_mod.displayWidth(label) + 2;
        const detail = item.detailSlice();
        if (detail.len > 0 and used + 2 < inner_width) {
            const detail_x = advance(x + 2, used + 2);
            painter.writeText(
                detail_x,
                row_y,
                fitToWidth(detail, inner_width - used - 2),
                app.theme.transcript_secondary,
            );
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

test "tool warning body lines use warning style" {
    var app = App.init(80, 24);
    defer app.deinit(testing_gpa);

    _ = try app.transcript.append(testing_gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "grep",
        .presentation = .search,
        .title = "grep /foo/ in .",
    } });
    _ = try app.transcript.appendToolOutput(
        testing_gpa,
        "call-1",
        "src/main.zig:1: foo\n[Truncated: 2 matches limit]",
        0,
        0,
    );

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    var count: usize = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, false);

    try std.testing.expectEqualStrings("src/main.zig:1: foo", scratch.rows[1].text);
    try std.testing.expectEqual(app.theme.tool_output, scratch.rows[1].text_style);
    try std.testing.expectEqualStrings("[Truncated: 2 matches limit]", scratch.rows[2].text);
    try std.testing.expectEqual(app.theme.status_warning, scratch.rows[2].text_style);
}

test "successful read hides body until expanded" {
    var app = App.init(80, 24);
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

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("read src/main.zig:1-2", scratch.rows[0].text);
    try std.testing.expectEqualStrings(tool_bottom_line, scratch.rows[1].text);

    count = 0;
    buildItemRows(scratch, &count, &app.transcript.items.items[0], app.width, &app.theme, true);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualStrings("one", scratch.rows[1].text);
    try std.testing.expectEqualStrings("two", scratch.rows[2].text);
}

test "tool header uses compact title only while collapsed" {
    var app = App.init(80, 24);
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

test "file tool header styles name path range and hint as segments" {
    var app = App.init(80, 24);
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

    const header = scratch.rows[0];
    try std.testing.expectEqual(@as(usize, 4), header.segments.len);
    try std.testing.expectEqualStrings("read", header.segments[0].text);
    try std.testing.expectEqualStrings(" ", header.segments[1].text);
    try std.testing.expectEqualStrings("src/main.zig", header.segments[2].text);
    try std.testing.expectEqualStrings(":1-20", header.segments[3].text);
    try std.testing.expectEqual(app.theme.status_accent, header.segments[2].style);
    try std.testing.expectEqual(app.theme.status_warning, header.segments[3].style);
}

test "tool header reserves room for closing bracket" {
    var app = App.init(24, 8);
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

    const header = scratch.rows[0];
    const used = padding_x +
        text_mod.displayWidth(header.prefix) +
        text_mod.displayWidth(header.text) +
        text_mod.displayWidth(header.suffix);
    try std.testing.expectEqualStrings(tool_title_suffix, header.suffix);
    try std.testing.expect(used <= app.width);
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

test "picker reserves bottom rows and pushes composer/status upward" {
    var app = App.init(40, 16);
    defer app.deinit(testing_gpa);

    const before = transcriptVisibleRows(&app);
    const items = [_]Picker.Item{
        .{ .id = "one", .label = "one" },
        .{ .id = "two", .label = "two" },
    };
    _ = try app.apply(testing_gpa, .{ .open_picker = .{ .id = 1, .title = "Pick", .items = &items } });

    const reserved = pickerRows(&app);
    try std.testing.expect(reserved > 0);
    try std.testing.expectEqual(before - reserved, transcriptVisibleRows(&app));
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

test "composer top border draws cwd and session chrome without overlap" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 60, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(60, 8);
    defer app.deinit(testing_gpa);
    _ = app.status.set(.{ .slot = .composer_left, .id = 1, .text = "/repo" });
    _ = app.status.set(.{ .slot = .composer_right, .id = 2, .text = "67.5%/272k • openai/gpt (high)" });

    const scratch = try testing_gpa.create(RowScratch);
    defer testing_gpa.destroy(scratch);
    draw(&app, &vx, scratch);

    try std.testing.expect(screenContainsText(vx.window(), "/repo"));
    try std.testing.expect(screenContainsText(vx.window(), "67.5%/272k"));
    try std.testing.expect(screenContainsText(vx.window(), "openai/gpt (high)"));
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

test "single command completion row remains visible below composer" {
    var env = std.process.Environ.Map.init(testing_gpa);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, testing_gpa, &env, .{});
    var output_storage: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(testing_gpa, &writer);

    try vx.resize(testing_gpa, &writer, .{ .cols = 40, .rows = 8, .x_pixel = 0, .y_pixel = 0 });

    var app = App.init(40, 8);
    defer app.deinit(testing_gpa);
    const items = [_]Picker.Item{
        .{ .id = "help", .label = "/help", .detail = "Show commands" },
        .{ .id = "model", .label = "/model", .detail = "Select model" },
    };
    _ = try app.apply(testing_gpa, .{ .set_composer_completions = .{ .id = 2, .title = "Commands", .items = &items } });
    _ = try app.apply(testing_gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/m") } });

    try std.testing.expectEqual(@as(usize, 3), pickerRows(&app));
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

    var app = App.init(30, 8);
    defer app.deinit(testing_gpa);
    _ = try app.apply(testing_gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "newer one\nnewer two\nnewer three\nnewer four",
    } } });
    _ = try app.apply(testing_gpa, .{ .prepend_transcript = .{
        .role = .user,
        .text = "fixture older row",
        .mode = .new_item,
    } });

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

    app.viewport.scroll_rows = 10_000; // render clamps locally instead of blanking
    draw(&app, &vx, scratch);
    try expectScreenText(vx.window(), 1, 1, "line-0");
    try std.testing.expectEqual(@as(usize, 10_000), app.viewport.scroll_rows);
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
