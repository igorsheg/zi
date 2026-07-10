const std = @import("std");
const screen = @import("screen.zig");

pub const MdState = struct {
    fence: ?Fence = null,

    pub const Fence = struct { char: u8 = '`', len: u8 = 3 };
};

pub fn renderLine(state: *MdState, out: *screen.Line, text: []const u8, base: screen.Style) error{LineFull}!void {
    const trimmed_right = std.mem.trimEnd(u8, text, "\r");
    const trimmed = std.mem.trimStart(u8, trimmed_right, " \t");

    if (state.fence != null) {
        const style = if (isFence(trimmed)) screen.markdown_styles.code_block_border else screen.markdown_styles.code_block;
        if (isFence(trimmed)) state.fence = null;
        try out.append(.{ .text = trimmed_right, .style = mergeStyle(base, style) });
        return;
    }

    if (isFence(trimmed)) {
        state.fence = .{};
        try out.append(.{ .text = trimmed_right, .style = mergeStyle(base, screen.markdown_styles.code_block_border) });
        return;
    }

    if (headingText(trimmed)) |heading| {
        try out.append(.{ .text = heading, .style = screen.withBold(mergeStyle(base, screen.markdown_styles.heading)) });
        return;
    }

    if (std.mem.eql(u8, trimmed, "---")) {
        try out.append(.{ .text = "--------", .style = mergeStyle(base, screen.markdown_styles.hr) });
        return;
    }

    if (std.mem.startsWith(u8, trimmed, ">")) {
        var quote = trimmed[1..];
        if (quote.len > 0 and quote[0] == ' ') quote = quote[1..];
        try renderInline(out, quote, mergeStyle(base, screen.markdown_styles.quote));
        return;
    }

    try renderInline(out, trimmed_right, base);
}

pub fn renderInline(out: *screen.Line, text: []const u8, base: screen.Style) error{LineFull}!void {
    var index: usize = 0;
    while (index < text.len) {
        // Keep one span available for the transcript's outer inset. Folding the
        // remaining inline source into the base style is the bounded fallback.
        if (out.span_len >= screen.span_capacity - 2) {
            try out.append(.{ .text = text[index..], .style = base });
            return;
        }
        if (std.mem.startsWith(u8, text[index..], "**")) {
            if (std.mem.indexOf(u8, text[index + 2 ..], "**")) |end_rel| {
                const inner = text[index + 2 .. index + 2 + end_rel];
                try out.append(.{ .text = inner, .style = screen.withBold(base) });
                index += 2 + end_rel + 2;
                continue;
            }
        }
        if (text[index] == '`') {
            if (std.mem.indexOfScalar(u8, text[index + 1 ..], '`')) |end_rel| {
                const inner = text[index + 1 .. index + 1 + end_rel];
                try out.append(.{ .text = inner, .style = mergeStyle(base, screen.markdown_styles.code) });
                index += 1 + end_rel + 1;
                continue;
            }
        }
        if (text[index] == '*') {
            if (std.mem.indexOfScalar(u8, text[index + 1 ..], '*')) |end_rel| {
                const inner = text[index + 1 .. index + 1 + end_rel];
                try out.append(.{ .text = inner, .style = screen.withItalic(base) });
                index += 1 + end_rel + 1;
                continue;
            }
        }
        if (text[index] == '[') {
            if (std.mem.indexOf(u8, text[index..], "](")) |mid_rel| {
                const url_start = index + mid_rel + 2;
                if (std.mem.indexOfScalar(u8, text[url_start..], ')')) |url_end_rel| {
                    const label = text[index + 1 .. index + mid_rel];
                    try out.append(.{ .text = label, .style = mergeStyle(base, screen.markdown_styles.link) });
                    index = url_start + url_end_rel + 1;
                    continue;
                }
            }
        }

        const next = nextMarker(text, index + 1);
        try out.append(.{ .text = text[index..next], .style = base });
        index = next;
    }
}

fn nextMarker(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            '*', '`', '[' => return index,
            else => {},
        }
    }
    return text.len;
}

fn headingText(line: []const u8) ?[]const u8 {
    var count: usize = 0;
    while (count < line.len and count < 6 and line[count] == '#') : (count += 1) {}
    if (count == 0 or count >= line.len or line[count] != ' ') return null;
    return line[count + 1 ..];
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
}

pub fn mergeStyle(base: screen.Style, overlay: screen.Style) screen.Style {
    var out = base;
    if (overlay.fg != .default) out.fg = overlay.fg;
    if (overlay.bg != .default) out.bg = overlay.bg;
    if (overlay.ul != .default) out.ul = overlay.ul;
    if (overlay.ul_style != .off) out.ul_style = overlay.ul_style;
    out.bold = out.bold or overlay.bold;
    out.dim = out.dim or overlay.dim;
    out.italic = out.italic or overlay.italic;
    out.blink = out.blink or overlay.blink;
    out.reverse = out.reverse or overlay.reverse;
    out.invisible = out.invisible or overlay.invisible;
    out.strikethrough = out.strikethrough or overlay.strikethrough;
    return out;
}

test "markdown renders basic inline styles" {
    var state: MdState = .{};
    var line: screen.Line = .{};
    try renderLine(&state, &line, "# hello **world**", screen.text.normal);
    try std.testing.expectEqual(@as(usize, 1), line.spans().len);
    try std.testing.expect(line.spans()[0].style.bold);
    try std.testing.expectEqualStrings("hello **world**", line.spans()[0].text);

    var inline_line: screen.Line = .{};
    try renderInline(&inline_line, "a **b** `c` *d* [e](url)", screen.text.normal);
    try std.testing.expect(inline_line.spans()[1].style.bold);
    try std.testing.expect(std.meta.eql(inline_line.spans()[3].style.fg, screen.markdown_styles.code.fg));
    try std.testing.expect(inline_line.spans()[5].style.italic);
    try std.testing.expect(inline_line.spans()[7].style.ul_style == .single);
}

test "markdown carries fence state" {
    var state: MdState = .{};
    var open: screen.Line = .{};
    try renderLine(&state, &open, "```zig", screen.text.normal);
    try std.testing.expect(state.fence != null);
    var body: screen.Line = .{};
    try renderLine(&state, &body, "const x = 1;", screen.text.normal);
    try std.testing.expect(std.meta.eql(body.spans()[0].style.fg, screen.markdown_styles.code_block.fg));
    var close: screen.Line = .{};
    try renderLine(&state, &close, "```", screen.text.normal);
    try std.testing.expect(state.fence == null);
}

test "markdown keeps text when inline spans exceed line capacity" {
    var line: screen.Line = .{};
    try renderInline(&line, "a **b** c **d** e **f** g **h** i **j** k **l** m", screen.text.normal);
    try std.testing.expect(line.spans().len <= screen.span_capacity);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a b c d e f g h i j k l m", line.copyText(&buffer));
}
test {
    std.testing.refAllDecls(@This());
}
