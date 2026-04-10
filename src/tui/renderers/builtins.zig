//! Renderers for the zig built-in tools (read, write, edit, grep,
//! find, ls). All share box_chrome + excerpt windowing; the renderer
//! per tool just decides:
//!
//!   1. how to format the title bar (renderCall)
//!   2. how to parse result text into lines (with optional gutter)
//!   3. which collapsed excerpts to show
//!
//! Picture from the user shows what we're matching: a `╭─[header]` top
//! border, right-aligned line numbers separated by `│`, an elision
//! marker `· ··· N more lines` for collapsed gaps, then `╰────`. That's
//! exactly what `box_chrome` already produces — these renderers just
//! feed it the right inputs.

const std = @import("std");
const tool_display_mod = @import("../tool_display.zig");
const box_chrome = @import("../box_chrome.zig");
const excerpt_mod = @import("../excerpt.zig");
const buffer_mod = @import("../buffer.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");

const ToolRenderer = tool_display_mod.ToolRenderer;
const ToolRenderContext = tool_display_mod.ToolRenderContext;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;

// ── line splitting ──────────────────────────────────────────────────

const DiffLineStyle = enum { none, added, removed, context };

const Line = struct {
    gutter: ?[]const u8 = null,
    text: []const u8,
    highlight: bool = true,
    /// Diff-only: non-null colors the line with +/-/context theme slots.
    diff_style: DiffLineStyle = .none,
    /// Diff-only: when true, render this slot as a `· ··· N more lines`
    /// elision marker instead of a content line. Used for hunk gaps.
    is_elision: bool = false,
    elision_count: u32 = 0,
};

const DiffStats = struct { added: u32 = 0, removed: u32 = 0 };

const Parsed = struct {
    raw: []u8,
    lines: []Line,
    /// Owned slab of formatted gutter strings (diff mode line numbers).
    /// Line.gutter slices into these; freed together in deinit.
    gutter_strs: [][]u8 = &.{},
    notice: ?[]const u8 = null, // optional bottom-line notice (stripped from box)
    header: ?[]const u8 = null, // optional file header for top border
    stats: ?DiffStats = null, // shown as a header row above drawTop
    gutter_width: u32 = 0,
    allocator: std.mem.Allocator,

    fn deinit(self: *Parsed) void {
        for (self.gutter_strs) |s| self.allocator.free(s);
        if (self.gutter_strs.len > 0) self.allocator.free(self.gutter_strs);
        self.allocator.free(self.lines);
        self.allocator.free(self.raw);
    }
};

/// Concatenate the result content into a single buffer; ignores image
/// blocks (only text contributes here).
fn collectText(ctx: *const ToolRenderContext) ?[]u8 {
    const result = ctx.result orelse return null;
    var total: usize = 0;
    for (result.content) |b| switch (b) {
        .text => |t| total += t.text.len + 1,
        .image => {},
    };
    if (total == 0) return null;
    const buf = ctx.allocator.alloc(u8, total) catch return null;
    var pos: usize = 0;
    for (result.content) |b| switch (b) {
        .text => |t| {
            if (pos > 0) {
                buf[pos] = '\n';
                pos += 1;
            }
            @memcpy(buf[pos..][0..t.text.len], t.text);
            pos += t.text.len;
        },
        .image => {},
    };
    return buf[0..pos];
}

const ParseMode = enum {
    /// Treat each line as plain text. No gutter.
    plain,
    /// Each line is "N: text" — extract N as the gutter.
    numbered,
    /// Each line is unified-diff (`+`, `-`, ` `, `@@`).
    diff,
};

fn parseResult(
    ctx: *const ToolRenderContext,
    mode: ParseMode,
) ?Parsed {
    const raw_full = collectText(ctx) orelse return null;
    var raw = raw_full;
    // Trim trailing newlines.
    while (raw.len > 0 and (raw[raw.len - 1] == '\n' or raw[raw.len - 1] == '\r')) {
        raw.len -= 1;
    }
    if (raw.len == 0) {
        ctx.allocator.free(raw_full);
        return null;
    }

    // Detect & strip a trailing parenthesised notice like
    // `(showing lines 1-500 of 656. use read_range to see more.)`. The
    // image example puts that line outside the box.
    var notice: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, raw, '\n')) |nl| {
        const last_line = raw[nl + 1 ..];
        if (last_line.len >= 2 and last_line[0] == '(' and last_line[last_line.len - 1] == ')') {
            notice = last_line[1 .. last_line.len - 1];
            raw.len = nl;
            // Drop trailing blank line if present (we wrote "\n\n(...)").
            while (raw.len > 0 and raw[raw.len - 1] == '\n') raw.len -= 1;
        }
    }

    // Walk lines. Diff mode owns its own growable list inside
    // parseDiffResult; plain/numbered preallocate against the raw line
    // count (no extra entries injected, only drops are possible).
    var line_count: usize = 1;
    for (raw) |c| { if (c == '\n') line_count += 1; }

    if (mode == .diff) {
        return parseDiffResult(ctx.allocator, raw_full, raw, line_count, notice) catch {
            ctx.allocator.free(raw_full);
            return null;
        };
    }

    const lines = ctx.allocator.alloc(Line, line_count) catch {
        ctx.allocator.free(raw_full);
        return null;
    };

    var idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    var max_gutter: usize = 0;
    while (i <= raw.len) : (i += 1) {
        if (i == raw.len or raw[i] == '\n') {
            const line_text = raw[start..i];
            var l = Line{ .text = line_text };
            switch (mode) {
                .plain => {},
                .numbered => {
                    // Look for "N: rest". Allow leading whitespace.
                    var j: usize = 0;
                    while (j < line_text.len and line_text[j] == ' ') : (j += 1) {}
                    const num_start = j;
                    while (j < line_text.len and line_text[j] >= '0' and line_text[j] <= '9') : (j += 1) {}
                    if (j > num_start and j + 1 < line_text.len and line_text[j] == ':' and line_text[j + 1] == ' ') {
                        l.gutter = line_text[num_start..j];
                        l.text = line_text[j + 2 ..];
                        if (l.gutter.?.len > max_gutter) max_gutter = l.gutter.?.len;
                    }
                },
                .diff => unreachable,
            }
            lines[idx] = l;
            idx += 1;
            start = i + 1;
        }
    }

    return .{
        .raw = raw_full,
        .lines = lines[0..idx],
        .notice = notice,
        .header = null,
        .gutter_width = @intCast(max_gutter),
        .allocator = ctx.allocator,
    };
}

// ── unified diff parser ─────────────────────────────────────────────
//
// Parses the output of `tui/components/diff.zig`'s `toUnified`:
//
//   --- a/path
//   +++ b/path
//   @@ -old_start,old_count +new_start,new_count @@
//    context
//   -removed
//   +inserted
//
// Drops the `---`/`+++` headers entirely (they're shown as the box
// title elsewhere). Keeps the `@@` headers as elision markers that
// visualize the gap between hunks. Assigns line numbers from the @@
// range so every content line gets a right-aligned gutter.
fn parseDiffResult(
    allocator: std.mem.Allocator,
    raw_full: []u8,
    raw: []const u8,
    raw_line_estimate: usize,
    notice: ?[]const u8,
) !Parsed {
    // Growable lines list — diff mode synthesizes elision entries for
    // hunk gaps and drops header lines, so the final count differs from
    // the raw line count in both directions. The previous fixed-cap
    // version silently truncated diffs with >16 hunk gaps (oracle).
    var lines_list: std.ArrayList(Line) = .empty;
    errdefer lines_list.deinit(allocator);
    try lines_list.ensureTotalCapacity(allocator, raw_line_estimate);

    var gutter_strs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (gutter_strs.items) |s| allocator.free(s);
        gutter_strs.deinit(allocator);
    }

    var stats = DiffStats{};
    var max_gutter: usize = 0;
    var header: ?[]const u8 = null;

    // Hunk state — incremented per content line within a hunk.
    var old_lineno: u32 = 0;
    var new_lineno: u32 = 0;
    var hunk_old_end: u32 = 0; // first line AFTER the previous hunk (in old file)
    var in_hunk = false;

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_text| {
        if (line_text.len == 0 and lines_list.items.len == 0) continue; // leading blank
        // Capture the filename from `--- path` for the box header.
        // Skip `+++ path` entirely.
        if (std.mem.startsWith(u8, line_text, "--- ")) {
            if (header == null) header = line_text[4..];
            continue;
        }
        if (std.mem.startsWith(u8, line_text, "+++ ")) continue;
        if (std.mem.startsWith(u8, line_text, "@@")) {
            if (parseHunkHeader(line_text)) |hdr| {
                if (in_hunk) {
                    const gap = if (hdr.old_start > hunk_old_end) hdr.old_start - hunk_old_end else 0;
                    if (gap > 0) {
                        try lines_list.append(allocator, .{
                            .text = "",
                            .is_elision = true,
                            .elision_count = gap,
                        });
                    }
                }
                old_lineno = hdr.old_start;
                new_lineno = hdr.new_start;
                hunk_old_end = hdr.old_start + hdr.old_count;
                in_hunk = true;
            }
            continue;
        }
        if (!in_hunk or line_text.len == 0) continue;

        const prefix = line_text[0];
        const body = line_text[1..];
        var line = Line{ .text = body };

        switch (prefix) {
            ' ' => {
                const g = try std.fmt.allocPrint(allocator, "{d}", .{new_lineno});
                try gutter_strs.append(allocator, g);
                if (g.len > max_gutter) max_gutter = g.len;
                line.gutter = g;
                line.diff_style = .context;
                line.highlight = false;
                old_lineno += 1;
                new_lineno += 1;
            },
            '-' => {
                const g = try std.fmt.allocPrint(allocator, "{d}", .{old_lineno});
                try gutter_strs.append(allocator, g);
                if (g.len > max_gutter) max_gutter = g.len;
                line.gutter = g;
                line.diff_style = .removed;
                line.highlight = true;
                stats.removed += 1;
                old_lineno += 1;
            },
            '+' => {
                const g = try std.fmt.allocPrint(allocator, "{d}", .{new_lineno});
                try gutter_strs.append(allocator, g);
                if (g.len > max_gutter) max_gutter = g.len;
                line.gutter = g;
                line.diff_style = .added;
                line.highlight = true;
                stats.added += 1;
                new_lineno += 1;
            },
            else => {
                line.text = line_text;
            },
        }
        try lines_list.append(allocator, line);
    }

    const owned_gutters = try gutter_strs.toOwnedSlice(allocator);
    const owned_lines = try lines_list.toOwnedSlice(allocator);

    return .{
        .raw = raw_full,
        .lines = owned_lines,
        .gutter_strs = owned_gutters,
        .notice = notice,
        .header = header,
        .stats = stats,
        .gutter_width = @intCast(max_gutter),
        .allocator = allocator,
    };
}

const HunkHeader = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

/// Parses `@@ -old_start,old_count +new_start,new_count @@` (git also
/// allows the `,count` to be omitted when count == 1; handle both).
fn parseHunkHeader(s: []const u8) ?HunkHeader {
    // Find "-" then " +" then " @@".
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse return null;
    const plus_seq = std.mem.indexOf(u8, s, " +") orelse return null;
    if (plus_seq <= dash) return null;
    const old_part = s[dash + 1 .. plus_seq];
    const after_plus = s[plus_seq + 2 ..];
    const end = std.mem.indexOf(u8, after_plus, " @@") orelse after_plus.len;
    const new_part = after_plus[0..end];

    const old_parsed = parseRange(old_part) orelse return null;
    const new_parsed = parseRange(new_part) orelse return null;
    return .{
        .old_start = old_parsed[0],
        .old_count = old_parsed[1],
        .new_start = new_parsed[0],
        .new_count = new_parsed[1],
    };
}

fn parseRange(s: []const u8) ?[2]u32 {
    if (std.mem.indexOfScalar(u8, s, ',')) |c| {
        const a = std.fmt.parseInt(u32, s[0..c], 10) catch return null;
        const b = std.fmt.parseInt(u32, s[c + 1 ..], 10) catch return null;
        return .{ a, b };
    }
    const a = std.fmt.parseInt(u32, s, 10) catch return null;
    return .{ a, 1 };
}

// ── shared draw helpers ─────────────────────────────────────────────

fn makeStyle(ctx: *const ToolRenderContext) box_chrome.Style {
    return .{
        .chrome = ctx.theme.fg(.dim),
        .fg = if (ctx.is_error) ctx.theme.fg(.@"error") else ctx.theme.fg(.tool_output),
        .dim = ctx.theme.fg(.dim),
    };
}

fn renderTitle(
    ctx: *const ToolRenderContext,
    label: []const u8,
    detail: ?[]const u8,
) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;
    var col: u32 = 0;
    col += region.writeStr(col, 0, label, ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });
    col += region.writeStr(col, 0, " ", Color.default, Color.default, .{});
    if (detail) |d| _ = region.writeStr(col, 0, d, ctx.theme.fg(.dim), Color.default, .{});
}

fn renderBoxed(ctx: *const ToolRenderContext, parsed: *Parsed, collapsed_excerpts: []const excerpt_mod.Excerpt) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;
    const total: u32 = @intCast(parsed.lines.len);
    if (total == 0) return;
    const style = makeStyle(ctx);

    const excerpts: []const excerpt_mod.Excerpt = if (ctx.expanded) &.{} else collapsed_excerpts;
    var window = excerpt_mod.windowExcerpts(ctx.allocator, total, excerpts) catch return;
    defer window.deinit();

    var row: u32 = 0;

    // Stats row (diff mode only) — drawn as a dim single-row banner
    // above the box top border. Format: `+12 -4`.
    if (parsed.stats) |s| {
        if (row < region.height) {
            var col: u32 = 0;
            if (s.added > 0) {
                var buf: [16]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "+{d}", .{s.added}) catch "+?";
                col += region.writeStr(col, row, txt, ctx.theme.fg(.tool_diff_added), Color.default, .{ .bold = true });
            }
            if (s.removed > 0) {
                if (col > 0) col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
                var buf: [16]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "-{d}", .{s.removed}) catch "-?";
                col += region.writeStr(col, row, txt, ctx.theme.fg(.tool_diff_removed), Color.default, .{ .bold = true });
            }
            if (col == 0) {
                _ = region.writeStr(0, row, "no changes", ctx.theme.fg(.dim), Color.default, .{});
            }
            row += 1;
        }
    }

    row += box_chrome.drawTop(region, row, parsed.header, style);

    for (window.items) |item| {
        switch (item) {
            .span => |span| {
                var i = span.start;
                while (i < span.end and row < region.height) : (i += 1) {
                    const ln = parsed.lines[i];
                    if (ln.is_elision) {
                        // Hunk gap — reuse the box elision helper.
                        row += box_chrome.drawElision(region, row, ln.elision_count, parsed.gutter_width, style);
                        continue;
                    }
                    const line_style = diffLineStyle(ctx, style, ln.diff_style);
                    row += box_chrome.drawContentLine(
                        region,
                        row,
                        ln.gutter,
                        parsed.gutter_width,
                        ln.text,
                        line_style,
                        ln.highlight or ln.diff_style != .none,
                    );
                }
            },
            .gap => |count| {
                row += box_chrome.drawElision(region, row, count, parsed.gutter_width, style);
            },
        }
    }
    _ = box_chrome.drawBottom(region, row, style);
    row += 1;

    // Trailing notice (e.g., "showing lines 1-500 of 656").
    if (parsed.notice) |notice| {
        if (row < region.height) {
            _ = region.writeStr(0, row, "[", ctx.theme.fg(.dim), Color.default, .{});
            const after_bracket = region.writeStr(1, row, notice, ctx.theme.fg(.dim), Color.default, .{});
            _ = region.writeStr(1 + after_bracket, row, "]", ctx.theme.fg(.dim), Color.default, .{});
        }
    }
}

/// Build a per-line Style override for diff-colored lines. Added/removed/
/// context all share the chrome + dim colors from the base style; only
/// `fg` changes. Returned by value so the caller passes it to
/// `drawContentLine` without caring whether it's the base or overridden.
fn diffLineStyle(ctx: *const ToolRenderContext, base: box_chrome.Style, ds: DiffLineStyle) box_chrome.Style {
    return switch (ds) {
        .none => base,
        .added => .{ .chrome = base.chrome, .fg = ctx.theme.fg(.tool_diff_added), .dim = base.dim },
        .removed => .{ .chrome = base.chrome, .fg = ctx.theme.fg(.tool_diff_removed), .dim = base.dim },
        .context => .{ .chrome = base.chrome, .fg = ctx.theme.fg(.tool_diff_context), .dim = base.dim },
    };
}

fn measureBoxed(ctx: *const ToolRenderContext, mode: ParseMode, collapsed_excerpts: []const excerpt_mod.Excerpt) u32 {
    var parsed = parseResult(ctx, mode) orelse return 0;
    defer parsed.deinit();
    const total: u32 = @intCast(parsed.lines.len);
    if (total == 0) return 0;
    const excerpts: []const excerpt_mod.Excerpt = if (ctx.expanded) &.{} else collapsed_excerpts;
    var window = excerpt_mod.windowExcerpts(ctx.allocator, total, excerpts) catch return 1;
    defer window.deinit();
    var visible: u32 = 0;
    var gaps: u32 = 0;
    for (window.items) |item| switch (item) {
        .span => |span| {
            // Be defensive here: excerpt windows should always satisfy
            // end >= start, but if a malformed span slips through during
            // teardown/recovery we still don't want the UI thread to die
            // on an overflow trap.
            visible += span.end -| span.start;
        },
        .gap => gaps += 1,
    };
    var h = box_chrome.measureHeight(visible, gaps);
    if (parsed.notice != null) h += 1;
    if (parsed.stats != null) h += 1;
    return h;
}

// ── path shortening for titles ──────────────────────────────────────

fn shortPath(buf: []u8, path: []const u8) []const u8 {
    const home = std.posix.getenv("HOME") orelse return path;
    if (std.mem.startsWith(u8, path, home)) {
        if (path.len - home.len + 1 > buf.len) return path;
        buf[0] = '~';
        @memcpy(buf[1 .. 1 + (path.len - home.len)], path[home.len..]);
        return buf[0 .. 1 + (path.len - home.len)];
    }
    return path;
}

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (args) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
}

// ── collapsed excerpt presets ───────────────────────────────────────

const READ_COLLAPSED = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 3 },
    .{ .focus = .tail, .context = 5 },
};
const TAIL_5 = [_]excerpt_mod.Excerpt{ .{ .focus = .tail, .context = 5 } };
const HEAD_TAIL_SHORT = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 3 },
    .{ .focus = .tail, .context = 5 },
};
const DIFF_COLLAPSED = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 12 },
    .{ .focus = .tail, .context = 13 },
};

// ── Read ────────────────────────────────────────────────────────────

fn readCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    const short = shortPath(&buf, path);
    var detail_buf: [1100]u8 = undefined;
    const detail = if (rangeFromArgs(ctx.args)) |r|
        std.fmt.bufPrint(&detail_buf, "{s}:{d}-{d}", .{ short, r[0], r[1] }) catch short
    else
        short;
    renderTitle(ctx, "Read", detail);
}

fn rangeFromArgs(args: std.json.Value) ?[2]i64 {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const arr = switch (obj.get("read_range") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len != 2) return null;
    const a = switch (arr.items[0]) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return null,
    };
    const b = switch (arr.items[1]) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return null,
    };
    return .{ a, b };
}

fn readResult(ctx: *const ToolRenderContext) void {
    var parsed = parseResult(ctx, .numbered) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, &READ_COLLAPSED);
}

fn readMeasure(ctx: *const ToolRenderContext) u32 {
    return measureBoxed(ctx, .numbered, &READ_COLLAPSED);
}

pub const read_renderer = ToolRenderer{
    .render_call = readCall,
    .render_result = readResult,
    .measure_result = readMeasure,
};

// ── Write ───────────────────────────────────────────────────────────

fn writeCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    renderTitle(ctx, "Write", shortPath(&buf, path));
}

fn writeResult(ctx: *const ToolRenderContext) void {
    var parsed = parseResult(ctx, .plain) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, &TAIL_5);
}

fn writeMeasure(ctx: *const ToolRenderContext) u32 {
    return measureBoxed(ctx, .plain, &TAIL_5);
}

pub const write_renderer = ToolRenderer{
    .render_call = writeCall,
    .render_result = writeResult,
    .measure_result = writeMeasure,
};

// ── Edit ────────────────────────────────────────────────────────────

fn editCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    renderTitle(ctx, "Edit", shortPath(&buf, path));
}

fn editResult(ctx: *const ToolRenderContext) void {
    // Error results are plain text ("file not found", "could not find
    // old_str", …) — no `@@` headers, nothing for the diff parser to
    // latch onto. Fall back to plain mode so the user can actually
    // read the error message.
    const mode: ParseMode = if (ctx.is_error) .plain else .diff;
    const excerpts: []const excerpt_mod.Excerpt = if (ctx.is_error) &TAIL_5 else &DIFF_COLLAPSED;
    var parsed = parseResult(ctx, mode) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, excerpts);
}

fn editMeasure(ctx: *const ToolRenderContext) u32 {
    const mode: ParseMode = if (ctx.is_error) .plain else .diff;
    const excerpts: []const excerpt_mod.Excerpt = if (ctx.is_error) &TAIL_5 else &DIFF_COLLAPSED;
    return measureBoxed(ctx, mode, excerpts);
}

pub const edit_renderer = ToolRenderer{
    .render_call = editCall,
    .render_result = editResult,
    .measure_result = editMeasure,
};

// ── Grep ────────────────────────────────────────────────────────────

fn grepCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const pattern = argString(ctx.args, "pattern") orelse "...";
    const path = argString(ctx.args, "path") orelse argString(ctx.args, "glob") orelse ".";
    const short = shortPath(&buf, path);
    var detail_buf: [2048]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "/{s}/ in {s}", .{ pattern, short }) catch pattern;
    renderTitle(ctx, "Grep", detail);
}

fn grepResult(ctx: *const ToolRenderContext) void {
    var parsed = parseResult(ctx, .plain) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, &HEAD_TAIL_SHORT);
}

fn grepMeasure(ctx: *const ToolRenderContext) u32 {
    return measureBoxed(ctx, .plain, &HEAD_TAIL_SHORT);
}

pub const grep_renderer = ToolRenderer{
    .render_call = grepCall,
    .render_result = grepResult,
    .measure_result = grepMeasure,
};

// ── Find ────────────────────────────────────────────────────────────

fn findCall(ctx: *const ToolRenderContext) void {
    const pat = argString(ctx.args, "filePattern") orelse "...";
    renderTitle(ctx, "Find", pat);
}

fn findResult(ctx: *const ToolRenderContext) void {
    var parsed = parseResult(ctx, .plain) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, &HEAD_TAIL_SHORT);
}

fn findMeasure(ctx: *const ToolRenderContext) u32 {
    return measureBoxed(ctx, .plain, &HEAD_TAIL_SHORT);
}

pub const find_renderer = ToolRenderer{
    .render_call = findCall,
    .render_result = findResult,
    .measure_result = findMeasure,
};

// ── Bash ────────────────────────────────────────────────────────────

fn bashCall(ctx: *const ToolRenderContext) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;
    var col: u32 = 0;
    col += region.writeStr(col, 0, "$ ", ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });
    if (argString(ctx.args, "command")) |cmd| {
        _ = region.writeStr(col, 0, cmd, ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });
    } else {
        _ = region.writeStr(col, 0, "...", ctx.theme.fg(.tool_output), Color.default, .{});
    }
}

fn bashResult(ctx: *const ToolRenderContext) void {
    var parsed = parseResult(ctx, .plain) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, &TAIL_5);
}

fn bashMeasure(ctx: *const ToolRenderContext) u32 {
    return measureBoxed(ctx, .plain, &TAIL_5);
}

pub const bash_renderer = ToolRenderer{
    .render_call = bashCall,
    .render_result = bashResult,
    .measure_result = bashMeasure,
};

// ── Ls ──────────────────────────────────────────────────────────────

fn lsCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse ".";
    renderTitle(ctx, "Ls", shortPath(&buf, path));
}

fn lsResult(ctx: *const ToolRenderContext) void {
    var parsed = parseResult(ctx, .plain) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, &HEAD_TAIL_SHORT);
}

fn lsMeasure(ctx: *const ToolRenderContext) u32 {
    return measureBoxed(ctx, .plain, &HEAD_TAIL_SHORT);
}

pub const ls_renderer = ToolRenderer{
    .render_call = lsCall,
    .render_result = lsResult,
    .measure_result = lsMeasure,
};
