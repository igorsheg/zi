const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const word_wrap_mod = @import("../word_wrap.zig");
const grapheme_mod = @import("../grapheme.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Line = word_wrap_mod.Line;

// ── Types ──────────────────────────────────────────────────────────

pub const Span = struct {
    text: []const u8,
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},
};

pub const RenderedLine = struct {
    spans: []const Span,
};

const InlineRun = struct {
    start: usize,
    end: usize,
    fg: Color,
    bg: Color,
    attrs: Attributes,
};

// ── Theme ──────────────────────────────────────────────────────────

const heading_fg = Color.rgb(255, 255, 255);
const code_inline_fg = Color.rgb(200, 175, 235);
const code_inline_bg = Color.rgb(45, 40, 60);
const code_block_fg = Color.rgb(190, 190, 190);
const code_border_fg = Color.rgb(100, 100, 100);
const list_bullet_fg = Color.rgb(100, 200, 255);
const quote_border_fg = Color.rgb(100, 100, 100);
const quote_text_fg = Color.rgb(170, 170, 170);
const hr_fg = Color.rgb(80, 80, 80);

// ── Inline Parser ──────────────────────────────────────────────────
//
// Grammar (V1, non-nestable):
//   1. escape: \<special> → literal
//   2. code span: `...` → code style (highest priority, non-nestable)
//   3. bold: **...** → bold attr
//   4. strikethrough: ~~...~~ → strikethrough attr
//   5. italic: *...* → italic attr (only if closing * is not part of **)
//   6. unmatched delimiters → literal text

const InlineContent = struct {
    text: []const u8,
    runs: []const InlineRun,
};

fn parseInline(
    source: []const u8,
    base_fg: Color,
    arena: std.mem.Allocator,
) !InlineContent {
    var text_buf: std.ArrayListUnmanaged(u8) = .{};
    var runs: std.ArrayListUnmanaged(InlineRun) = .{};

    var pos: usize = 0;
    var run_start: usize = 0;

    while (pos < source.len) {
        // 1. Escape
        if (source[pos] == '\\' and pos + 1 < source.len and isMarkdownSpecial(source[pos + 1])) {
            try text_buf.append(arena, source[pos + 1]);
            pos += 2;
            continue;
        }

        // 2. Code span (backtick)
        if (source[pos] == '`') {
            if (findCharFrom(source, pos + 1, '`')) |close| {
                // Flush current run
                try flushRun(&runs, run_start, text_buf.items.len, base_fg, Color.default, .{}, arena);
                // Emit code run
                const code_start = text_buf.items.len;
                try text_buf.appendSlice(arena, source[pos + 1 .. close]);
                try flushRun(&runs, code_start, text_buf.items.len, code_inline_fg, code_inline_bg, .{}, arena);
                run_start = text_buf.items.len;
                pos = close + 1;
                continue;
            }
        }

        // 3. Bold (**)
        if (pos + 1 < source.len and source[pos] == '*' and source[pos + 1] == '*') {
            if (findDelimiter(source, pos + 2, "**")) |close| {
                try flushRun(&runs, run_start, text_buf.items.len, base_fg, Color.default, .{}, arena);
                const bold_start = text_buf.items.len;
                try text_buf.appendSlice(arena, source[pos + 2 .. close]);
                try flushRun(&runs, bold_start, text_buf.items.len, base_fg, Color.default, .{ .bold = true }, arena);
                run_start = text_buf.items.len;
                pos = close + 2;
                continue;
            }
        }

        // 4. Strikethrough (~~)
        if (pos + 1 < source.len and source[pos] == '~' and source[pos + 1] == '~') {
            if (findDelimiter(source, pos + 2, "~~")) |close| {
                try flushRun(&runs, run_start, text_buf.items.len, base_fg, Color.default, .{}, arena);
                const strike_start = text_buf.items.len;
                try text_buf.appendSlice(arena, source[pos + 2 .. close]);
                try flushRun(&runs, strike_start, text_buf.items.len, base_fg, Color.default, .{ .strikethrough = true }, arena);
                run_start = text_buf.items.len;
                pos = close + 2;
                continue;
            }
        }

        // 5. Italic (*) — single star, closing must not be part of **
        if (source[pos] == '*' and (pos + 1 >= source.len or source[pos + 1] != '*')) {
            if (findItalicClose(source, pos + 1)) |close| {
                try flushRun(&runs, run_start, text_buf.items.len, base_fg, Color.default, .{}, arena);
                const italic_start = text_buf.items.len;
                try text_buf.appendSlice(arena, source[pos + 1 .. close]);
                try flushRun(&runs, italic_start, text_buf.items.len, base_fg, Color.default, .{ .italic = true }, arena);
                run_start = text_buf.items.len;
                pos = close + 1;
                continue;
            }
        }

        // 6. Regular character
        try text_buf.append(arena, source[pos]);
        pos += 1;
    }

    // Flush remaining
    try flushRun(&runs, run_start, text_buf.items.len, base_fg, Color.default, .{}, arena);

    return .{ .text = text_buf.items, .runs = runs.items };
}

fn flushRun(
    runs: *std.ArrayListUnmanaged(InlineRun),
    start: usize,
    end: usize,
    fg: Color,
    bg: Color,
    attrs: Attributes,
    arena: std.mem.Allocator,
) !void {
    if (start >= end) return;
    try runs.append(arena, .{ .start = start, .end = end, .fg = fg, .bg = bg, .attrs = attrs });
}

fn findCharFrom(source: []const u8, start: usize, char: u8) ?usize {
    if (start >= source.len) return null;
    const offset = std.mem.indexOfScalar(u8, source[start..], char) orelse return null;
    return start + offset;
}

fn findDelimiter(source: []const u8, start: usize, delimiter: []const u8) ?usize {
    if (start + delimiter.len > source.len) return null;
    var pos = start;
    while (pos + delimiter.len <= source.len) : (pos += 1) {
        if (std.mem.eql(u8, source[pos..][0..delimiter.len], delimiter)) return pos;
    }
    return null;
}

fn findItalicClose(source: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < source.len) : (pos += 1) {
        if (source[pos] == '*') {
            // Reject if this * is followed by another * (part of **)
            if (pos + 1 < source.len and source[pos + 1] == '*') {
                pos += 1; // skip the pair
                continue;
            }
            return pos;
        }
    }
    return null;
}

fn isMarkdownSpecial(c: u8) bool {
    return switch (c) {
        '*', '`', '~', '#', '-', '_', '[', ']', '(', ')', '\\', '>' => true,
        else => false,
    };
}

// ── Span Reconstruction ────────────────────────────────────────────

fn reconstructSpans(
    line: Line,
    display_text: []const u8,
    runs: []const InlineRun,
    arena: std.mem.Allocator,
) ![]const Span {
    var spans: std.ArrayListUnmanaged(Span) = .{};
    for (runs) |run| {
        if (run.end <= line.start) continue;
        if (run.start >= line.end) break;
        const s = @max(run.start, line.start);
        const e = @min(run.end, line.end);
        if (s < e) {
            try spans.append(arena, .{
                .text = display_text[s..e],
                .fg = run.fg,
                .bg = run.bg,
                .attrs = run.attrs,
            });
        }
    }
    return try spans.toOwnedSlice(arena);
}

// ── Content Wrapping ───────────────────────────────────────────────

fn wrapContent(
    display_text: []const u8,
    runs: []const InlineRun,
    width: u32,
    arena: std.mem.Allocator,
) ![]const RenderedLine {
    if (width == 0) return &.{};
    const wrapped = try word_wrap_mod.wordWrap(display_text, width, arena);
    var result: std.ArrayListUnmanaged(RenderedLine) = .{};
    for (wrapped) |line| {
        try result.append(arena, .{ .spans = try reconstructSpans(line, display_text, runs, arena) });
    }
    return try result.toOwnedSlice(arena);
}

/// Wrap inline content with a styled prefix on the first line and
/// space-indent on continuation lines. Wrapping width accounts for prefix.
fn wrapWithPrefix(
    prefix: []const Span,
    prefix_width: u32,
    display_text: []const u8,
    runs: []const InlineRun,
    total_width: u32,
    arena: std.mem.Allocator,
) ![]const RenderedLine {
    const content_width = if (total_width > prefix_width) total_width - prefix_width else 1;
    const wrapped = try word_wrap_mod.wordWrap(display_text, content_width, arena);
    var result: std.ArrayListUnmanaged(RenderedLine) = .{};

    for (wrapped, 0..) |line, i| {
        var spans: std.ArrayListUnmanaged(Span) = .{};
        if (i == 0) {
            try spans.appendSlice(arena, prefix);
        } else if (prefix_width > 0) {
            const indent = try arena.alloc(u8, prefix_width);
            @memset(indent, ' ');
            try spans.append(arena, .{ .text = indent });
        }
        try spans.appendSlice(arena, try reconstructSpans(line, display_text, runs, arena));
        try result.append(arena, .{ .spans = try spans.toOwnedSlice(arena) });
    }
    return try result.toOwnedSlice(arena);
}

// ── Block Detection ────────────────────────────────────────────────

const HeadingInfo = struct { level: u8, content: []const u8 };

fn detectHeading(line: []const u8) ?HeadingInfo {
    if (line.len == 0 or line[0] != '#') return null;
    var level: u8 = 0;
    var pos: usize = 0;
    while (pos < line.len and line[pos] == '#' and level < 6) {
        level += 1;
        pos += 1;
    }
    if (pos >= line.len or line[pos] != ' ') return null;
    return .{ .level = level, .content = std.mem.trimRight(u8, line[pos + 1 ..], " \t") };
}

const ListItemInfo = struct {
    indent: usize,
    bullet_text: []const u8,
    content: []const u8,
};

fn detectListItem(line: []const u8) ?ListItemInfo {
    var pos: usize = 0;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    const indent = pos;
    if (pos >= line.len) return null;

    // Unordered: - or * followed by space
    if ((line[pos] == '-' or line[pos] == '*') and pos + 1 < line.len and line[pos + 1] == ' ') {
        return .{ .indent = indent, .bullet_text = line[pos .. pos + 2], .content = line[pos + 2 ..] };
    }

    // Ordered: digits. space
    const digit_start = pos;
    while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') : (pos += 1) {}
    if (pos > digit_start and pos + 1 < line.len and line[pos] == '.' and line[pos + 1] == ' ') {
        return .{ .indent = indent, .bullet_text = line[digit_start .. pos + 2], .content = line[pos + 2 ..] };
    }
    return null;
}

fn isHorizontalRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    const ch = trimmed[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var count: usize = 0;
    for (trimmed) |c| {
        if (c == ch) {
            count += 1;
        } else if (c != ' ' and c != '\t') return false;
    }
    return count >= 3;
}

// ── Build Lines ────────────────────────────────────────────────────

fn buildLines(
    source: []const u8,
    content_width: u32,
    base_fg: Color,
    arena: std.mem.Allocator,
) ![]const RenderedLine {
    if (content_width == 0) return &.{};

    var lines: std.ArrayListUnmanaged(RenderedLine) = .{};
    var in_code_block = false;
    var last_was_blank = false;

    var line_start: usize = 0;
    while (true) {
        const remaining = source[line_start..];
        const newline_pos = std.mem.indexOfScalar(u8, remaining, '\n');
        const raw_line = if (newline_pos) |p| remaining[0..p] else remaining;

        if (in_code_block) {
            const trimmed = std.mem.trimLeft(u8, raw_line, " \t");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                in_code_block = false;
                try appendSingleSpan(&lines, "```", code_border_fg, Color.default, .{ .dim = true }, arena);
                last_was_blank = false;
            } else {
                // Code line: preserve whitespace, hard-clip at width. No wordWrap.
                try appendCodeLine(&lines, raw_line, content_width, arena);
                last_was_blank = false;
            }
        } else {
            const trimmed = std.mem.trimLeft(u8, raw_line, " \t");

            if (trimmed.len == 0) {
                // Blank line
                if (!last_was_blank and lines.items.len > 0) {
                    try lines.append(arena, .{ .spans = &.{} });
                }
                last_was_blank = true;
            } else if (std.mem.startsWith(u8, trimmed, "```")) {
                // Code fence start
                in_code_block = true;
                try appendSingleSpan(&lines, trimmed, code_border_fg, Color.default, .{ .dim = true }, arena);
                last_was_blank = false;
            } else if (detectHeading(trimmed)) |h| {
                try appendHeading(&lines, h, content_width, base_fg, arena);
                last_was_blank = false;
            } else if (isHorizontalRule(trimmed)) {
                try appendHR(&lines, content_width, arena);
                last_was_blank = false;
            } else if (trimmed.len > 0 and trimmed[0] == '>' and (trimmed.len == 1 or trimmed[1] == ' ')) {
                const qcontent = if (trimmed.len > 2) trimmed[2..] else "";
                try appendBlockquote(&lines, qcontent, content_width, base_fg, arena);
                last_was_blank = false;
            } else if (detectListItem(trimmed)) |li| {
                try appendListItem(&lines, li, content_width, base_fg, arena);
                last_was_blank = false;
            } else {
                // Paragraph line — each physical line rendered independently
                // (no cross-line joining; avoids reflow jank during streaming)
                const inline_content = try parseInline(trimmed, base_fg, arena);
                const wrapped = try wrapContent(inline_content.text, inline_content.runs, content_width, arena);
                try lines.appendSlice(arena, wrapped);
                last_was_blank = false;
            }
        }

        if (newline_pos) |p| {
            line_start += p + 1;
        } else {
            break;
        }
    }

    // Trim trailing empty lines
    while (lines.items.len > 0 and lines.items[lines.items.len - 1].spans.len == 0) {
        lines.items.len -= 1;
    }

    return lines.items;
}

fn appendSingleSpan(
    lines: *std.ArrayListUnmanaged(RenderedLine),
    text: []const u8,
    fg: Color,
    bg: Color,
    attrs: Attributes,
    arena: std.mem.Allocator,
) !void {
    const span = try arena.alloc(Span, 1);
    // Arena-dupe text so spans never borrow from external content
    span[0] = .{ .text = try arena.dupe(u8, text), .fg = fg, .bg = bg, .attrs = attrs };
    try lines.append(arena, .{ .spans = span });
}

fn appendCodeLine(
    lines: *std.ArrayListUnmanaged(RenderedLine),
    raw_line: []const u8,
    width: u32,
    arena: std.mem.Allocator,
) !void {
    // "  " indent + source line, hard-clipped to width. No wordWrap.
    const indent = "  ";
    const indent_width: u32 = 2;
    var spans: std.ArrayListUnmanaged(Span) = .{};
    try spans.append(arena, .{ .text = indent, .fg = code_block_fg });
    if (raw_line.len > 0) {
        const avail = if (width > indent_width) width - indent_width else 0;
        const clipped = grapheme_mod.sliceToWidth(raw_line, avail);
        if (clipped.len > 0) {
            // Arena-dupe so spans don't borrow from external content
            try spans.append(arena, .{ .text = try arena.dupe(u8, clipped), .fg = code_block_fg });
        }
    }
    try lines.append(arena, .{ .spans = try spans.toOwnedSlice(arena) });
}

fn appendHeading(
    lines: *std.ArrayListUnmanaged(RenderedLine),
    h: HeadingInfo,
    width: u32,
    base_fg: Color,
    arena: std.mem.Allocator,
) !void {
    _ = base_fg;
    var heading_attrs: Attributes = .{ .bold = true };
    if (h.level == 1) heading_attrs.underline = true;

    if (h.level >= 3) {
        // "### " prefix + content
        const content = try parseInline(h.content, heading_fg, arena);
        const heading_runs = try overrideRunStyle(content.runs, heading_fg, heading_attrs, arena);
        const prefix_len = @as(usize, h.level) + 1;
        const prefix_text = try arena.alloc(u8, prefix_len);
        @memset(prefix_text[0..h.level], '#');
        prefix_text[h.level] = ' ';
        const prefix = try arena.alloc(Span, 1);
        prefix[0] = .{ .text = prefix_text, .fg = heading_fg, .attrs = heading_attrs };
        const wrapped = try wrapWithPrefix(prefix, @intCast(prefix_len), content.text, heading_runs, width, arena);
        try lines.appendSlice(arena, wrapped);
    } else {
        // h1/h2: styled content, no prefix
        const content = try parseInline(h.content, heading_fg, arena);
        const heading_runs = try overrideRunStyle(content.runs, heading_fg, heading_attrs, arena);
        const wrapped = try wrapContent(content.text, heading_runs, width, arena);
        try lines.appendSlice(arena, wrapped);
    }
    // Spacing after heading
    try lines.append(arena, .{ .spans = &.{} });
}

fn appendHR(
    lines: *std.ArrayListUnmanaged(RenderedLine),
    width: u32,
    arena: std.mem.Allocator,
) !void {
    const hr_width = @min(width, 80);
    // "─" is U+2500, 3 bytes in UTF-8
    const hr_text = try arena.alloc(u8, hr_width * 3);
    for (0..hr_width) |i| {
        hr_text[i * 3] = 0xe2;
        hr_text[i * 3 + 1] = 0x94;
        hr_text[i * 3 + 2] = 0x80;
    }
    try appendSingleSpan(lines, hr_text, hr_fg, Color.default, .{ .dim = true }, arena);
}

fn appendBlockquote(
    lines: *std.ArrayListUnmanaged(RenderedLine),
    content: []const u8,
    width: u32,
    base_fg: Color,
    arena: std.mem.Allocator,
) !void {
    _ = base_fg;
    const inline_content = try parseInline(content, quote_text_fg, arena);
    const quote_runs = try overrideRunStyle(inline_content.runs, quote_text_fg, .{ .italic = true }, arena);

    const prefix = try arena.alloc(Span, 1);
    prefix[0] = .{ .text = "│ ", .fg = quote_border_fg, .attrs = .{ .dim = true } };
    // "│" is 1 display column + " " = 2
    const wrapped = try wrapWithPrefix(prefix, 2, inline_content.text, quote_runs, width, arena);
    try lines.appendSlice(arena, wrapped);
}

fn appendListItem(
    lines: *std.ArrayListUnmanaged(RenderedLine),
    li: ListItemInfo,
    width: u32,
    base_fg: Color,
    arena: std.mem.Allocator,
) !void {
    const inline_content = try parseInline(li.content, base_fg, arena);

    const indent_len = @min(li.indent, 20);
    const prefix_text_len = indent_len + li.bullet_text.len;
    const prefix_text = try arena.alloc(u8, prefix_text_len);
    @memset(prefix_text[0..indent_len], ' ');
    @memcpy(prefix_text[indent_len..prefix_text_len], li.bullet_text);

    const prefix = try arena.alloc(Span, 1);
    prefix[0] = .{ .text = prefix_text, .fg = list_bullet_fg };

    const prefix_display_width: u32 = @intCast(grapheme_mod.strWidth(prefix_text));
    const wrapped = try wrapWithPrefix(prefix, prefix_display_width, inline_content.text, inline_content.runs, width, arena);
    try lines.appendSlice(arena, wrapped);
}

fn overrideRunStyle(
    runs: []const InlineRun,
    fg: Color,
    base_attrs: Attributes,
    arena: std.mem.Allocator,
) ![]const InlineRun {
    const new_runs = try arena.alloc(InlineRun, runs.len);
    for (runs, 0..) |run, i| {
        new_runs[i] = run;
        // Don't override inline code styling
        if (!run.bg.eql(code_inline_bg)) {
            new_runs[i].fg = fg;
            new_runs[i].attrs = mergeAttrs(base_attrs, run.attrs);
        }
    }
    return new_runs;
}

fn mergeAttrs(base: Attributes, overlay: Attributes) Attributes {
    return .{
        .bold = base.bold or overlay.bold,
        .dim = base.dim or overlay.dim,
        .italic = base.italic or overlay.italic,
        .underline = base.underline or overlay.underline,
        .blink = base.blink or overlay.blink,
        .inverse = base.inverse or overlay.inverse,
        .hidden = base.hidden or overlay.hidden,
        .strikethrough = base.strikethrough or overlay.strikethrough,
    };
}

// ── Markdown Component ─────────────────────────────────────────────

pub const Markdown = struct {
    content: []const u8 = "",
    fg: Color = Color.default,
    bg: Color = Color.default,
    padding_x: u32 = 0,
    padding_y: u32 = 0,
    scroll_offset: u32 = 0,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    /// Owned content buffer — Markdown owns its text to avoid
    /// borrowing from external mutable storage (e.g. transcript text_buf).
    content_buf: std.ArrayListUnmanaged(u8) = .empty,

    // Cache — keyed on content_len + width (content is owned, ptr is stable)
    cached_lines: ?[]const RenderedLine = null,
    cached_width: u32 = 0,
    cached_content_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Markdown {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Markdown) void {
        self.content_buf.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Replace content entirely (copies into owned buffer).
    pub fn setContent(self: *Markdown, text: []const u8) void {
        self.content_buf.clearRetainingCapacity();
        self.content_buf.appendSlice(self.allocator, text) catch return;
        self.content = self.content_buf.items;
    }

    /// Append streaming content (avoids full copy on each delta).
    pub fn appendContent(self: *Markdown, delta: []const u8) void {
        self.content_buf.appendSlice(self.allocator, delta) catch return;
        self.content = self.content_buf.items;
    }

    pub fn scrollToBottom(self: *Markdown, visible_height: u32) void {
        const total = self.totalLines(visible_height);
        if (total > visible_height) {
            self.scroll_offset = @intCast(total - visible_height);
        } else {
            self.scroll_offset = 0;
        }
    }

    pub fn totalLines(self: *Markdown, visible_width: u32) u32 {
        return self.measure(visible_width).preferred_height;
    }

    pub fn measure(self: *Markdown, width: u32) Measurement {
        if (self.content.len == 0) return .{ .min_height = 0, .preferred_height = 0 };
        if (width == 0) return .{ .min_height = 1, .preferred_height = 1 };
        const content_width = if (width > self.padding_x * 2) width - self.padding_x * 2 else 1;
        const rendered = self.getRenderedLines(content_width) orelse
            return .{ .min_height = 1, .preferred_height = 1 };
        const total: u32 = @intCast(rendered.len);
        return .{ .min_height = 1, .preferred_height = total + self.padding_y * 2 };
    }

    pub fn render(self: *Markdown, region: Region) void {
        if (self.content.len == 0) return;
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        const content_width = if (w > self.padding_x * 2) w - self.padding_x * 2 else 1;
        const rendered = self.getRenderedLines(content_width) orelse return;

        if (!self.bg.eql(Color.default)) {
            region.fill(0, 0, w, h, .{
                .grapheme = .{ .codepoint = ' ' },
                .fg = self.fg,
                .bg = self.bg,
            });
        }

        const pad_y = self.padding_y;
        var row: u32 = 0;
        var virtual_row: u32 = self.scroll_offset;

        while (row < h) {
            if (virtual_row < pad_y) {
                virtual_row += 1;
                row += 1;
                continue;
            }
            const line_idx = virtual_row - pad_y;
            if (line_idx >= rendered.len) break;

            const rline = rendered[line_idx];
            var col: u32 = self.padding_x;
            for (rline.spans) |span| {
                if (span.text.len == 0) continue;
                // Fill background for spans with non-default bg (e.g. inline code)
                if (!span.bg.eql(Color.default)) {
                    const span_width = grapheme_mod.strWidth(span.text);
                    region.fill(col, row, @intCast(span_width), 1, .{
                        .grapheme = .{ .codepoint = ' ' },
                        .bg = span.bg,
                    });
                }
                const written = region.writeStr(col, row, span.text, span.fg, span.bg, span.attrs);
                col += written;
            }

            row += 1;
            virtual_row += 1;
        }
    }

    fn getRenderedLines(self: *Markdown, content_width: u32) ?[]const RenderedLine {
        // Cache key: content_len + width. Content is owned (stable ptr),
        // and len only grows during streaming (appendContent), so a len
        // match means the bytes haven't changed.
        if (self.cached_lines) |cached| {
            if (self.cached_width == content_width and
                self.cached_content_len == self.content.len)
            {
                return cached;
            }
        }
        // Cache miss — rebuild
        self.cached_lines = null;
        _ = self.arena.reset(.retain_capacity);
        const arena_alloc = self.arena.allocator();

        const built = buildLines(self.content, content_width, self.fg, arena_alloc) catch return null;
        self.cached_lines = built;
        self.cached_width = content_width;
        self.cached_content_len = self.content.len;
        return built;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "markdown renders headings with bold styling" {
    var md = Markdown.init(testing.allocator);
    defer md.deinit();
    md.setContent("# Hello");

    var buf = try Buffer.init(testing.allocator, 30, 5);
    defer buf.deinit();
    md.render(buf.region());

    // h1: "Hello" bold+underline at col 0 (no # prefix for h1/h2)
    try testing.expectEqual(@as(u21, 'H'), buf.get(0, 0).grapheme.codepoint);
    try testing.expect(buf.get(0, 0).attrs.bold);
    try testing.expect(buf.get(0, 0).attrs.underline);
}

test "markdown renders code blocks with indent, no word wrap" {
    var md = Markdown.init(testing.allocator);
    defer md.deinit();
    md.setContent("```\nhello world\n```");

    var buf = try Buffer.init(testing.allocator, 30, 5);
    defer buf.deinit();
    md.render(buf.region());

    // Line 0: "```" border
    try testing.expectEqual(@as(u21, '`'), buf.get(0, 0).grapheme.codepoint);
    // Line 1: "  hello world" (2-space indent)
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(1, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'h'), buf.get(2, 1).grapheme.codepoint);
    // Line 2: "```" closing border
    try testing.expectEqual(@as(u21, '`'), buf.get(0, 2).grapheme.codepoint);
}

test "markdown renders inline bold and code with correct attributes" {
    var md = Markdown.init(testing.allocator);
    defer md.deinit();
    md.setContent("hello **world** and `code`");

    var buf = try Buffer.init(testing.allocator, 40, 3);
    defer buf.deinit();
    md.render(buf.region());

    // "hello " — not bold
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    try testing.expect(!buf.get(0, 0).attrs.bold);

    // "world" — bold (at col 6: "hello " = 6 chars)
    try testing.expectEqual(@as(u21, 'w'), buf.get(6, 0).grapheme.codepoint);
    try testing.expect(buf.get(6, 0).attrs.bold);

    // "code" — inline code bg (at col 16: "hello " + "world" + " and " = 16)
    try testing.expectEqual(@as(u21, 'c'), buf.get(16, 0).grapheme.codepoint);
    try testing.expect(buf.get(16, 0).bg.eql(code_inline_bg));
}

test "markdown word-wraps paragraphs and measures correctly" {
    // Verify wordWrap directly first
    const direct_lines = try word_wrap_mod.wordWrap("the quick brown fox jumps over the lazy dog", 20, testing.allocator);
    defer testing.allocator.free(direct_lines);
    try testing.expectEqual(@as(usize, 3), direct_lines.len);

    var md = Markdown.init(testing.allocator);
    defer md.deinit();
    md.setContent("the quick brown fox jumps over the lazy dog");

    const m = md.measure(20);
    try testing.expectEqual(@as(u32, 3), m.preferred_height);

    var buf = try Buffer.init(testing.allocator, 20, 5);
    defer buf.deinit();
    md.render(buf.region());

    try testing.expectEqual(@as(u21, 't'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'j'), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'd'), buf.get(0, 2).grapheme.codepoint);
}

test "markdown renders list items with styled bullet" {
    var md = Markdown.init(testing.allocator);
    defer md.deinit();
    md.setContent("- first item\n- second item");

    var buf = try Buffer.init(testing.allocator, 30, 5);
    defer buf.deinit();
    md.render(buf.region());

    // "- " bullet in list_bullet_fg color
    try testing.expectEqual(@as(u21, '-'), buf.get(0, 0).grapheme.codepoint);
    try testing.expect(buf.get(0, 0).fg.eql(list_bullet_fg));
    // Content "first item" starts at col 2
    try testing.expectEqual(@as(u21, 'f'), buf.get(2, 0).grapheme.codepoint);
    // Second item on next line
    try testing.expectEqual(@as(u21, '-'), buf.get(0, 1).grapheme.codepoint);
}
