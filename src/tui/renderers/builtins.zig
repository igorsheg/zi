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
const json_util = @import("../../ai/json_util.zig");
const diff = @import("../../lib/diff.zig");
const diff_json = @import("../../lib/diff_json.zig");
const diff_view = @import("../../lib/diff_view.zig");
const agent_protocol = @import("../../agent/root.zig").protocol;

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
    owned_raw: []u8,
    raw: []const u8,
    lines: []Line,
    /// Owned slab of formatted gutter strings (diff mode line numbers).
    /// Line.gutter slices into these; freed together in deinit.
    gutter_strs: [][]u8 = &.{},
    /// Structured diff rows own their text independently because they do not
    /// borrow from a collected raw payload.
    owned_texts: [][]u8 = &.{},
    notice: ?[]const u8 = null, // optional bottom-line notice (stripped from box)
    header: ?[]const u8 = null, // optional file header for top border
    owned_header: ?[]u8 = null,
    stats: ?DiffStats = null, // shown as a header row above drawTop
    gutter_width: u32 = 0,
    allocator: std.mem.Allocator,

    fn deinit(self: *Parsed) void {
        for (self.gutter_strs) |s| self.allocator.free(s);
        if (self.gutter_strs.len > 0) self.allocator.free(self.gutter_strs);
        for (self.owned_texts) |s| self.allocator.free(s);
        if (self.owned_texts.len > 0) self.allocator.free(self.owned_texts);
        if (self.owned_header) |h| self.allocator.free(h);
        self.allocator.free(self.lines);
        self.allocator.free(self.owned_raw);
    }
};

/// Concatenate the result content into a single buffer; ignores image
/// blocks (only text contributes here).
fn collectText(ctx: *const ToolRenderContext) ?[]u8 {
    const result = ctx.result orelse return null;
    var total: usize = 0;
    var text_blocks: usize = 0;
    for (result.content) |b| switch (b) {
        .text => |t| {
            total += t.text.len;
            text_blocks += 1;
        },
        .image => {},
    };
    if (text_blocks == 0) return null;
    total += text_blocks - 1;

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
    return buf;
}

const ParseMode = enum {
    /// Treat each line as plain text. No gutter.
    plain,
    /// Each line is "N: text" — extract N as the gutter.
    numbered,
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

    // Walk lines. Plain/numbered preallocate against the raw line
    // count (no extra entries injected, only drops are possible).
    var line_count: usize = 1;
    for (raw) |c| {
        if (c == '\n') line_count += 1;
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
            }
            lines[idx] = l;
            idx += 1;
            start = i + 1;
        }
    }

    return .{
        .owned_raw = raw_full,
        .raw = raw,
        .lines = lines[0..idx],
        .notice = notice,
        .header = null,
        .gutter_width = @intCast(max_gutter),
        .allocator = ctx.allocator,
    };
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

fn argTimeoutSeconds(args: std.json.Value) ?u64 {
    return switch (args) {
        .object => |o| switch (o.get("timeout") orelse return null) {
            .integer => |i| if (i > 0) @intCast(i) else null,
            .float => |f| if (f > 0) @intFromFloat(@floor(f)) else null,
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
const TAIL_5 = [_]excerpt_mod.Excerpt{.{ .focus = .tail, .context = 5 }};
const HEAD_TAIL_SHORT = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 3 },
    .{ .focus = .tail, .context = 5 },
};
const DIFF_COLLAPSED = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 12 },
    .{ .focus = .tail, .context = 13 },
};

// ── Read ────────────────────────────────────────────────────────────

fn skillNameFromReadPath(path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, "/SKILL.md")) return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    const name = std.fs.path.basename(dir);
    if (name.len == 0) return null;
    return name;
}

fn readCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    const short = shortPath(&buf, path);
    var detail_buf: [1100]u8 = undefined;
    if (skillNameFromReadPath(path)) |skill_name| {
        const detail = if (rangeFromArgs(ctx.args)) |r|
            std.fmt.bufPrint(&detail_buf, "{s}:{d}-{d}", .{ skill_name, r[0], r[1] }) catch skill_name
        else
            skill_name;
        renderTitle(ctx, "Skill", detail);
        return;
    }
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

const testing = std.testing;

test "skillNameFromReadPath extracts skill name from canonical skill file path" {
    try testing.expectEqualStrings("caveman", skillNameFromReadPath("/Users/igors/.zi/agent/skills/caveman/SKILL.md").?);
}

test "skillNameFromReadPath ignores ordinary read paths" {
    try testing.expect(skillNameFromReadPath("/tmp/notes.md") == null);
}

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

fn parseStructuredDiffResult(ctx: *const ToolRenderContext) ?Parsed {
    const result = ctx.result orelse return malformedEditParsed(ctx.allocator, "malformed edit result: missing tool result");
    const details = switch (result.details) {
        .object => |o| o,
        else => return malformedEditParsed(ctx.allocator, "malformed edit result: missing structuredDiff details"),
    };
    const structured = details.get("structuredDiff") orelse
        return malformedEditParsed(ctx.allocator, "malformed edit result: missing structuredDiff details");

    var document = diff_json.fromJsonValue(ctx.allocator, structured) catch
        return malformedEditParsed(ctx.allocator, "malformed edit result: invalid structuredDiff details");
    defer document.deinit();

    var view = diff_view.buildView(ctx.allocator, document) catch
        return malformedEditParsed(ctx.allocator, "malformed edit result: failed to build diff view");
    defer view.deinit();

    return parsedFromDiffView(ctx.allocator, view, null) catch
        malformedEditParsed(ctx.allocator, "malformed edit result: failed to render diff view");
}

fn malformedEditParsed(allocator: std.mem.Allocator, text: []const u8) ?Parsed {
    const owned_raw = allocator.dupe(u8, text) catch return null;

    const lines = allocator.alloc(Line, 1) catch {
        allocator.free(owned_raw);
        return null;
    };
    lines[0] = .{ .text = owned_raw, .highlight = false };
    return .{
        .owned_raw = owned_raw,
        .raw = owned_raw,
        .lines = lines,
        .allocator = allocator,
    };
}

fn parsedFromDiffView(
    allocator: std.mem.Allocator,
    view: diff_view.DiffView,
    notice: ?[]const u8,
) !Parsed {
    var lines_list: std.ArrayList(Line) = .empty;
    errdefer lines_list.deinit(allocator);

    var gutter_strs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (gutter_strs.items) |s| allocator.free(s);
        gutter_strs.deinit(allocator);
    }

    var owned_texts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_texts.items) |s| allocator.free(s);
        owned_texts.deinit(allocator);
    }

    var header_owned: ?[]u8 = null;
    errdefer {
        if (header_owned) |h| allocator.free(h);
    }
    if (view.files.len > 0) {
        header_owned = try allocator.dupe(u8, view.files[0].path);
    }

    var max_gutter: usize = 0;
    for (view.files, 0..) |file, file_index| {
        if (file_index > 0) {
            const owned_path = try allocator.dupe(u8, file.path);
            try owned_texts.append(allocator, owned_path);
            try lines_list.append(allocator, .{ .text = "" });
            try lines_list.append(allocator, .{ .text = owned_path, .highlight = false });
        }

        for (file.rows) |row| {
            switch (row.kind) {
                .gap => {
                    try lines_list.append(allocator, .{
                        .text = "",
                        .is_elision = true,
                        .elision_count = row.gap_count,
                    });
                },
                .context, .added, .removed => {
                    const owned = try allocator.dupe(u8, row.text);
                    try owned_texts.append(allocator, owned);
                    var line = Line{
                        .text = owned,
                        .diff_style = switch (row.kind) {
                            .context => .context,
                            .added => .added,
                            .removed => .removed,
                            else => unreachable,
                        },
                        .highlight = row.kind != .context,
                    };
                    const gutter_no = switch (row.kind) {
                        .context => row.new_lineno,
                        .added => row.new_lineno,
                        .removed => row.old_lineno,
                        else => null,
                    };
                    if (gutter_no) |ln| {
                        const gutter = try std.fmt.allocPrint(allocator, "{d}", .{ln});
                        try gutter_strs.append(allocator, gutter);
                        if (gutter.len > max_gutter) max_gutter = gutter.len;
                        line.gutter = gutter;
                    }
                    try lines_list.append(allocator, line);
                },
            }
        }
    }

    const owned_gutters = try gutter_strs.toOwnedSlice(allocator);
    const owned_lines = try lines_list.toOwnedSlice(allocator);
    const owned_line_texts = try owned_texts.toOwnedSlice(allocator);
    const owned_raw = try allocator.alloc(u8, 0);

    return .{
        .owned_raw = owned_raw,
        .raw = owned_raw,
        .lines = owned_lines,
        .gutter_strs = owned_gutters,
        .owned_texts = owned_line_texts,
        .notice = notice,
        .header = header_owned,
        .owned_header = header_owned,
        .stats = .{ .added = view.stats.added, .removed = view.stats.removed },
        .gutter_width = @intCast(max_gutter),
        .allocator = allocator,
    };
}

fn editCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    renderTitle(ctx, "Edit", shortPath(&buf, path));
}

fn editResult(ctx: *const ToolRenderContext) void {
    if (ctx.is_error) {
        var parsed = parseResult(ctx, .plain) orelse return;
        defer parsed.deinit();
        renderBoxed(ctx, &parsed, &TAIL_5);
        return;
    }

    var parsed = parseStructuredDiffResult(ctx) orelse return;
    defer parsed.deinit();
    renderBoxed(ctx, &parsed, &DIFF_COLLAPSED);
}

fn editMeasure(ctx: *const ToolRenderContext) u32 {
    if (ctx.is_error) return measureBoxed(ctx, .plain, &TAIL_5);

    var parsed = parseStructuredDiffResult(ctx) orelse return 0;
    defer parsed.deinit();

    const total: u32 = @intCast(parsed.lines.len);
    if (total == 0) return 0;
    const excerpts: []const excerpt_mod.Excerpt = if (ctx.expanded) &.{} else &DIFF_COLLAPSED;
    var window = excerpt_mod.windowExcerpts(ctx.allocator, total, excerpts) catch return 1;
    defer window.deinit();

    var visible: u32 = 0;
    var gaps: u32 = 0;
    for (window.items) |item| switch (item) {
        .span => |span| visible += span.end -| span.start,
        .gap => gaps += 1,
    };
    var h = box_chrome.measureHeight(visible, gaps);
    if (parsed.notice != null) h += 1;
    if (parsed.stats != null) h += 1;
    return h;
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

    const cmd = argString(ctx.args, "cmd") orelse argString(ctx.args, "command");
    if (cmd) |command| {
        col += region.writeStr(col, 0, command, ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });
    } else {
        col += region.writeStr(col, 0, "...", ctx.theme.fg(.tool_output), Color.default, .{});
    }

    if (argTimeoutSeconds(ctx.args)) |timeout_secs| {
        var timeout_buf: [32]u8 = undefined;
        const suffix = std.fmt.bufPrint(&timeout_buf, " (timeout {d}s)", .{timeout_secs}) catch "";
        _ = region.writeStr(col, 0, suffix, ctx.theme.fg(.dim), Color.default, .{});
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

fn rowAscii(buf: *const buffer_mod.Buffer, y: u32, out: []u8) []const u8 {
    var len: usize = 0;
    var x: u32 = 0;
    while (x < buf.width and len < out.len) : (x += 1) {
        const cp = buf.get(x, y).grapheme.codepoint;
        out[len] = if (cp <= 0x7f) @intCast(cp) else '?';
        len += 1;
    }
    return std.mem.trimRight(u8, out[0..len], " ");
}

fn makeBashArgsForTest(allocator: std.mem.Allocator, key: []const u8, command: []const u8, timeout: ?std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_command = try allocator.dupe(u8, command);
    errdefer allocator.free(owned_command);
    try obj.put(owned_key, .{ .string = owned_command });

    if (timeout) |value| {
        const timeout_key = try allocator.dupe(u8, "timeout");
        errdefer allocator.free(timeout_key);
        try obj.put(timeout_key, value);
    }

    return .{ .object = obj };
}

test "bashCall renders cmd args with timeout suffix" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 64, 1);
    defer buf.deinit();

    const args = try makeBashArgsForTest(testing.allocator, "cmd", "echo hi", .{ .integer = 5 });
    defer json_util.freeJsonValue(testing.allocator, args);

    const ctx = ToolRenderContext{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .args = args,
        .result = null,
        .is_partial = true,
        .is_error = false,
        .expanded = false,
        .execution_started = false,
        .args_complete = false,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = buf.width,
    };

    bashCall(&ctx);

    var line: [64]u8 = undefined;
    try testing.expectEqualStrings("$ echo hi (timeout 5s)", rowAscii(&buf, 0, &line));
}

test "bashCall falls back to legacy command arg for old sessions" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 32, 1);
    defer buf.deinit();

    const args = try makeBashArgsForTest(testing.allocator, "command", "ls -la", null);
    defer json_util.freeJsonValue(testing.allocator, args);

    const ctx = ToolRenderContext{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .args = args,
        .result = null,
        .is_partial = true,
        .is_error = false,
        .expanded = false,
        .execution_started = false,
        .args_complete = false,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = buf.width,
    };

    bashCall(&ctx);

    var line: [32]u8 = undefined;
    try testing.expectEqualStrings("$ ls -la", rowAscii(&buf, 0, &line));
}

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

test "edit renderer uses structured diff details" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 80, 12);
    defer buf.deinit();

    const inputs = [_]diff.Input{.{
        .old_path = "a.txt",
        .new_path = "a.txt",
        .old_text =
        \\one
        \\two
        \\three
        ,
        .new_text =
        \\one
        \\TWO
        \\three
        ,
    }};
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();
    const diff_value = try diff_json.toJsonValue(testing.allocator, doc);
    defer json_util.freeJsonValue(testing.allocator, diff_value);

    var details = std.json.ObjectMap.init(testing.allocator);
    defer json_util.freeJsonValue(testing.allocator, .{ .object = details });
    try details.put(try testing.allocator.dupe(u8, "structuredDiff"), try json_util.cloneJsonValue(testing.allocator, diff_value));

    const content = try testing.allocator.alloc(agent_protocol.AgentToolResult.ContentBlock, 1);
    defer {
        testing.allocator.free(content[0].text.text);
        testing.allocator.free(content);
    }
    content[0] = .{ .text = .{ .text = try testing.allocator.dupe(u8, "ignored text payload") } };

    const result = agent_protocol.AgentToolResult{
        .content = content,
        .details = .{ .object = details },
        .is_error = false,
    };

    const ctx = ToolRenderContext{
        .tool_name = "edit",
        .tool_call_id = "call-1",
        .args = .null,
        .result = result,
        .is_partial = false,
        .is_error = false,
        .expanded = true,
        .execution_started = true,
        .args_complete = true,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = buf.width,
    };

    editResult(&ctx);

    var row0: [80]u8 = undefined;
    var row2: [80]u8 = undefined;
    var row3: [80]u8 = undefined;
    var row4: [80]u8 = undefined;
    try testing.expectEqualStrings("+1 -1", rowAscii(&buf, 0, &row0));
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 2, &row2), "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 3, &row3), "one") != null);
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 4, &row4), "two") != null or std.mem.indexOf(u8, rowAscii(&buf, 4, &row4), "TWO") != null);
}

test "edit renderer shows malformed result message when structured diff details are missing" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 80, 8);
    defer buf.deinit();

    const content = try testing.allocator.alloc(agent_protocol.AgentToolResult.ContentBlock, 1);
    defer {
        testing.allocator.free(content[0].text.text);
        testing.allocator.free(content);
    }
    content[0] = .{ .text = .{ .text = try testing.allocator.dupe(u8, "ignored text payload") } };

    const result = agent_protocol.AgentToolResult{
        .content = content,
        .details = .null,
        .is_error = false,
    };

    const ctx = ToolRenderContext{
        .tool_name = "edit",
        .tool_call_id = "call-2",
        .args = .null,
        .result = result,
        .is_partial = false,
        .is_error = false,
        .expanded = true,
        .execution_started = true,
        .args_complete = true,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = buf.width,
    };

    try testing.expect(editMeasure(&ctx) > 0);
    editResult(&ctx);

    var row: [80]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 0, &row), "malformed edit result") != null);
}
