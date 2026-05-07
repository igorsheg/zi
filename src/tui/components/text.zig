const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const component_mod = @import("../primitives/view.zig");
const text_layout = @import("../text/layout.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const grapheme = @import("../grapheme.zig");
const Line = text_layout.Line;
pub const WrapMode = text_layout.WrapMode;
pub const OverflowMode = text_layout.OverflowMode;
pub const TextAlign = text_layout.TextAlign;
pub const TextRun = text_layout.TextRun;
const StyleSpan = text_layout.StyleSpan;
const LayoutCache = text_layout.LayoutCache;
const TextBuffer = text_layout.TextBuffer;

/// Styled text with word wrapping, padding, and scroll support.
///
/// Wraps content at word boundaries when rendering into a Region.
/// Supports horizontal/vertical padding (matching pi-mono's Text component).
/// When content exceeds the visible area, `scroll_offset` controls which
/// wrapped lines are visible. Call `scrollToBottom` after updating content
/// to auto-follow streaming output.
pub const Text = struct {
    content: []const u8 = "",
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},
    padding_x: u32 = 0,
    padding_y: u32 = 0,
    scroll_offset: u32 = 0,
    scroll_x: u32 = 0,
    text_align: TextAlign = .left,
    wrap_mode: WrapMode = .word,
    overflow: OverflowMode = .clip,
    max_lines: ?u32 = null,
    link: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    /// Owned content and style mapping. Direct `content` assignment remains
    /// supported for plain compatibility; setContent/setRuns copy into this
    /// buffer when callers want lifetime-safe content.
    buffer: TextBuffer = .{},
    layout_cache: LayoutCache = .{},
    width_method: grapheme.WidthMethod = .wcwidth,

    pub fn init(allocator: std.mem.Allocator, width_method: grapheme.WidthMethod) Text {
        return .{
            .allocator = allocator,
            .width_method = width_method,
        };
    }

    pub fn setContent(self: *Text, text: []const u8) void {
        self.content = self.buffer.setPlain(self.allocator, text) catch return;
        self.invalidateCache();
    }

    pub fn setRuns(self: *Text, runs: []const TextRun) void {
        self.content = self.buffer.setRuns(self.allocator, runs) catch return;
        self.invalidateCache();
    }

    pub fn setPadding(self: *Text, x: u32, y: u32) void {
        self.padding_x = x;
        self.padding_y = y;
        self.invalidateCache();
    }

    pub fn setWidthMethod(self: *Text, width_method: grapheme.WidthMethod) void {
        if (self.width_method == width_method) return;
        self.width_method = width_method;
        self.invalidateCache();
    }

    /// Scroll so the last wrapped line is visible at the bottom of the region.
    /// Call after setContent during streaming to auto-follow.
    pub fn scrollToBottom(self: *Text, visible_height: u32) void {
        const total = self.totalLines(visible_height);
        if (total > visible_height) {
            self.scroll_offset = @intCast(total - visible_height);
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Total lines this text would occupy (wrapped lines + padding).
    pub fn totalLines(self: *Text, visible_width: u32) u32 {
        const m = self.measure(visible_width);
        return m.preferred_height;
    }

    pub fn render(self: *Text, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *Text, region: Region, first_row: u32) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        if (!self.bg.eql(Color.default)) {
            region.fill(0, 0, w, h, .{
                .grapheme = .{ .codepoint = ' ' },
                .fg = self.fg,
                .bg = self.bg,
            });
        }
        if (self.content.len == 0) return;

        const content_width = self.contentWidth(w);
        const layout = self.getLayout(content_width, region.buf.width_method) orelse return;
        const lines = layout.lines orelse return;

        const row_limit = if (self.max_lines) |m| @min(h, m) else h;
        var row: u32 = 0;
        var virtual_row: u32 = self.scroll_offset + first_row;
        while (row < row_limit) {
            if (virtual_row < self.padding_y) {
                virtual_row += 1;
                row += 1;
                continue;
            }

            const line_idx = virtual_row - self.padding_y;
            if (line_idx >= lines.len) break;

            const line = lines[line_idx];
            const line_text = line.text(self.content);
            if (line_text.len > 0) {
                self.writeLine(region, self.padding_x, row, line, line_text, content_width);
            }

            row += 1;
            virtual_row += 1;
        }
    }

    pub fn measure(self: *Text, width: u32) Measurement {
        if (self.content.len == 0) return .{ .min_height = 0, .preferred_height = 0 };
        if (width == 0) return .{ .min_height = 1, .preferred_height = 1 };

        const layout = self.getLayout(self.contentWidth(width), self.width_method) orelse
            return .{ .min_height = 1, .preferred_height = 1 };
        const lines = layout.lines orelse return .{ .min_height = 1, .preferred_height = 1 };

        const total = text_layout.measureLineCount(lines, self.padding_y, self.max_lines);
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    pub fn component(self: *Text) Component {
        return Component.init(Text, self);
    }

    fn contentWidth(self: *const Text, outer_width: u32) u32 {
        return if (outer_width > self.padding_x * 2) outer_width - self.padding_x * 2 else 1;
    }

    fn writeLine(self: *Text, region: Region, x: u32, y: u32, line: Line, line_text: []const u8, content_width: u32) void {
        if (content_width == 0) return;

        const viewport = text_layout.viewportForLine(self.content, line, content_width, self.scroll_x, region.buf.width_method);
        if (viewport.start >= viewport.end) return;
        const visible_text = self.content[viewport.start..viewport.end];
        const visible_width: u32 = @intCast(grapheme.strWidth(visible_text, region.buf.width_method));
        const aligned_x = x + text_layout.alignmentOffset(self.text_align, content_width, visible_width);

        if (self.overflow == .ellipsis and self.scroll_x == 0 and grapheme.strWidth(line_text, region.buf.width_method) > content_width) {
            if (content_width == 1) {
                self.writeFallbackGlyph(region, aligned_x, y, "…");
                return;
            }
            const prefix = grapheme.sliceToWidth(line_text, content_width - 1, region.buf.width_method);
            const used: u32 = @intCast(grapheme.strWidth(prefix, region.buf.width_method));
            self.writeStyledSlice(region, aligned_x, y, line.start, line.start + prefix.len);
            self.writeFallbackGlyph(region, aligned_x + used, y, "…");
            return;
        }
        self.writeStyledSlice(region, aligned_x, y, viewport.start, viewport.end);
    }

    fn writeStyledSlice(self: *Text, region: Region, x: u32, y: u32, start: usize, end: usize) void {
        const fallback = StyleSpan{ .start = start, .end = end, .fg = self.fg, .bg = self.bg, .attrs = self.attrs, .link = self.link };
        var col = x;
        var byte = start;
        var cached_link: ?[]const u8 = null;
        var cached_id: u16 = 0;
        while (byte < end and col < region.width) {
            const next = grapheme.nextGraphemeBoundaryFromBoundary(self.content[start..end], byte - start, region.buf.width_method) + start;
            if (next <= byte) break;
            const span = self.buffer.styleAt(byte, fallback);
            const link_id = if (span.link) |url| blk: {
                if (cached_link == null or !std.mem.eql(u8, cached_link.?, url)) {
                    cached_link = url;
                    cached_id = region.buf.addLink(url) catch 0;
                }
                break :blk cached_id;
            } else 0;
            const wrote = region.writeStrLink(col, y, self.content[byte..next], span.fg, span.bg, span.attrs, link_id);
            col += wrote;
            byte = next;
        }
    }

    fn writeFallbackGlyph(self: *Text, region: Region, x: u32, y: u32, glyph: []const u8) void {
        const link_id = if (self.link) |url| region.buf.addLink(url) catch 0 else 0;
        _ = region.writeStrLink(x, y, glyph, self.fg, self.bg, self.attrs, link_id);
    }

    fn getLayout(self: *Text, content_width: u32, width_method: grapheme.WidthMethod) ?*const LayoutCache {
        return text_layout.getCached(&self.layout_cache, self.allocator, .{
            .text = self.content,
            .width = content_width,
            .wrap_mode = self.wrap_mode,
            .max_lines = self.max_lines,
            .width_method = width_method,
            .style_generation = self.buffer.style_generation,
        }) catch null;
    }

    fn invalidateCache(self: *Text) void {
        self.layout_cache.clear(self.allocator);
    }

    pub fn deinit(self: *Text) void {
        self.layout_cache.clear(self.allocator);
        self.buffer.deinit(self.allocator);
    }
};

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "Text wraps content across multiple rows" {
    var buf = try Buffer.init(testing.allocator, 10, 5, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "hello world how are you";
    text.fg = Color.rgb(255, 255, 255);
    text.render(buf.region());

    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'w'), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'a'), buf.get(0, 2).grapheme.codepoint);
}

test "Text renders pooled grapheme clusters without splitting" {
    var buf = try Buffer.init(testing.allocator, 12, 2, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "Cafe\u{0301} 👩‍🚀";
    text.render(buf.region());

    try testing.expect(buf.get(3, 0).grapheme == .pooled);
    try testing.expect(buf.get(6, 0).grapheme == .pooled);
    try testing.expectEqual(@as(u2, 2), buf.get(6, 0).width);
    try testing.expectEqual(@as(u2, 0), buf.get(7, 0).width);
}

test "Text measure returns accurate wrapped line count" {
    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "hello world";

    try testing.expectEqual(@as(u32, 2), text.measure(5).preferred_height);

    try testing.expectEqual(@as(u32, 1), text.measure(20).preferred_height);

    text.padding_y = 1;
    try testing.expectEqual(@as(u32, 4), text.measure(5).preferred_height);

    var empty = Text.init(testing.allocator, .wcwidth);
    defer empty.deinit();
    try testing.expectEqual(@as(u32, 0), empty.measure(10).preferred_height);
}

test "Text scroll_offset skips top lines" {
    var buf = try Buffer.init(testing.allocator, 10, 2, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "aaa bbb ccc ddd";
    text.content = "aa bb cc dd";

    var small_buf = try Buffer.init(testing.allocator, 3, 2, .wcwidth);
    defer small_buf.deinit();

    text.scroll_offset = 2;
    text.render(small_buf.region());

    try testing.expectEqual(@as(u21, 'c'), small_buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'd'), small_buf.get(0, 1).grapheme.codepoint);
}

test "Text wrap none measures explicit lines only and clips horizontally" {
    var buf = try Buffer.init(testing.allocator, 5, 2, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "hello world\nbye";
    text.wrap_mode = .none;

    try testing.expectEqual(@as(u32, 2), text.measure(5).preferred_height);
    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'o'), buf.get(4, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'b'), buf.get(0, 1).grapheme.codepoint);
}

test "Text max_lines caps measurement and render" {
    var buf = try Buffer.init(testing.allocator, 3, 4, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "aa bb cc dd";
    text.max_lines = 2;

    try testing.expectEqual(@as(u32, 2), text.measure(3).preferred_height);
    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'a'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'b'), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 2).grapheme.codepoint);
}

test "Text renders adjacent styled runs" {
    var buf = try Buffer.init(testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();
    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    const red = Color.rgb(255, 0, 0);
    const green = Color.rgb(0, 255, 0);
    const runs = [_]TextRun{ .{ .text = "ab", .fg = red }, .{ .text = "cd", .fg = green, .attrs = .{ .bold = true } } };
    text.setRuns(&runs);
    text.render(buf.region());
    try testing.expect(buf.get(0, 0).fg.eql(red));
    try testing.expect(buf.get(2, 0).fg.eql(green));
    try testing.expect(buf.get(2, 0).attrs.bold);
}

test "Text wraps styled runs across boundaries" {
    var buf = try Buffer.init(testing.allocator, 3, 2, .wcwidth);
    defer buf.deinit();
    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.wrap_mode = .char;
    const blue = Color.rgb(0, 0, 255);
    const yellow = Color.rgb(255, 255, 0);
    const runs = [_]TextRun{ .{ .text = "abc", .fg = blue }, .{ .text = "def", .fg = yellow } };
    text.setRuns(&runs);
    try testing.expectEqual(@as(u32, 2), text.measure(3).preferred_height);
    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'a'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'd'), buf.get(0, 1).grapheme.codepoint);
    try testing.expect(buf.get(0, 0).fg.eql(blue));
    try testing.expect(buf.get(0, 1).fg.eql(yellow));
}

test "Text layout cache invalidates for same-buffer content mutation" {
    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();

    var bytes = [_]u8{ 'a', 'b' };
    text.content = bytes[0..];
    text.wrap_mode = .none;

    try testing.expectEqual(@as(u32, 1), text.measure(10).preferred_height);
    bytes[1] = '\n';
    try testing.expectEqual(@as(u32, 2), text.measure(10).preferred_height);
}

test "Text layout cache key includes max_lines" {
    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "aa bb cc dd";

    try testing.expectEqual(@as(u32, 4), text.measure(3).preferred_height);
    text.max_lines = 2;
    try testing.expectEqual(@as(u32, 2), text.measure(3).preferred_height);
}

test "Text setContent keeps plain text compatible and owned" {
    var buf = try Buffer.init(testing.allocator, 5, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();

    var source = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    text.setContent(source[0..]);
    source[0] = 'j';

    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
}

test "Text styles grapheme cluster using run at cluster start" {
    var buf = try Buffer.init(testing.allocator, 4, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    const red = Color.rgb(255, 0, 0);
    const green = Color.rgb(0, 255, 0);
    const runs = [_]TextRun{
        .{ .text = "e", .fg = red },
        .{ .text = "\u{0301}", .fg = green },
    };
    text.setRuns(&runs);

    text.render(buf.region());
    try testing.expect(buf.get(0, 0).grapheme == .pooled);
    try testing.expect(buf.get(0, 0).fg.eql(red));
    try testing.expectEqual(@as(u21, ' '), buf.get(1, 0).grapheme.codepoint);
}

test "Text max_lines and scroll render a capped viewport" {
    var buf = try Buffer.init(testing.allocator, 3, 4, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "aa bb cc dd";
    text.max_lines = 2;
    text.scroll_offset = 1;

    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'b'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'c'), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 2).grapheme.codepoint);
}

test "Text fills background across padded region" {
    var buf = try Buffer.init(testing.allocator, 4, 3, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    const bg = Color.rgb(10, 20, 30);
    text.setContent("x");
    text.bg = bg;
    text.padding_x = 1;
    text.padding_y = 1;

    text.render(buf.region());
    try testing.expect(buf.get(0, 0).bg.eql(bg));
    try testing.expect(buf.get(1, 1).bg.eql(bg));
    try testing.expectEqual(@as(u21, 'x'), buf.get(1, 1).grapheme.codepoint);
}

test "Text aligns visual lines left center and right" {
    var buf = try Buffer.init(testing.allocator, 6, 3, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "hi";

    text.text_align = .left;
    text.renderSlice(buf.region().sub(0, 0, 6, 1), 0);
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);

    text.text_align = .center;
    text.renderSlice(buf.region().sub(0, 1, 6, 1), 0);
    try testing.expectEqual(@as(u21, 'h'), buf.get(2, 1).grapheme.codepoint);

    text.text_align = .right;
    text.renderSlice(buf.region().sub(0, 2, 6, 1), 0);
    try testing.expectEqual(@as(u21, 'h'), buf.get(4, 2).grapheme.codepoint);
}

test "Text scroll_x clips horizontal viewport for wrap none" {
    var buf = try Buffer.init(testing.allocator, 4, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "abcdef";
    text.wrap_mode = .none;
    text.scroll_x = 2;

    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'c'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'f'), buf.get(3, 0).grapheme.codepoint);
}

test "Text scroll_x respects padding" {
    var buf = try Buffer.init(testing.allocator, 6, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "abcdef";
    text.wrap_mode = .none;
    text.padding_x = 1;
    text.scroll_x = 2;

    text.render(buf.region());
    try testing.expectEqual(@as(u21, ' '), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'c'), buf.get(1, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'f'), buf.get(4, 0).grapheme.codepoint);
}

test "Text alignment respects padding" {
    var buf = try Buffer.init(testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "hi";
    text.padding_x = 1;
    text.text_align = .right;

    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'h'), buf.get(5, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'i'), buf.get(6, 0).grapheme.codepoint);
}

test "Text alignment applies after max_lines viewport" {
    var buf = try Buffer.init(testing.allocator, 5, 3, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "a\nb";
    text.wrap_mode = .none;
    text.text_align = .center;
    text.max_lines = 1;
    text.scroll_offset = 1;

    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'b'), buf.get(2, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(2, 1).grapheme.codepoint);
}

test "Text renders links into cell link ids" {
    var buf = try Buffer.init(testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    const runs = [_]TextRun{.{ .text = "hi", .link = "https://example.test" }};
    text.setRuns(&runs);
    text.render(buf.region());

    try testing.expectEqual(@as(usize, 1), buf.link_table.items.len);
    try testing.expectEqualStrings("https://example.test", buf.link_table.items[0]);
    try testing.expectEqual(@as(u16, 1), buf.get(0, 0).link_id);
    try testing.expectEqual(@as(u16, 1), buf.get(1, 0).link_id);
}

test "Text default link applies to plain content" {
    var buf = try Buffer.init(testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();
    text.content = "go";
    text.link = "https://plain.test";
    text.render(buf.region());

    try testing.expectEqual(@as(usize, 1), buf.link_table.items.len);
    try testing.expectEqualStrings("https://plain.test", buf.link_table.items[0]);
    try testing.expectEqual(@as(u16, 1), buf.get(0, 0).link_id);
}

test "Text setRuns owns text and does not retain caller run slice" {
    var buf = try Buffer.init(testing.allocator, 2, 1, .wcwidth);
    defer buf.deinit();

    var text = Text.init(testing.allocator, .wcwidth);
    defer text.deinit();

    const source = try testing.allocator.dupe(u8, "hi");
    var runs = try testing.allocator.alloc(TextRun, 1);
    runs[0] = .{ .text = source, .fg = Color.rgb(1, 2, 3) };
    text.setRuns(runs);
    testing.allocator.free(runs);
    testing.allocator.free(source);

    text.render(buf.region());
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    try testing.expect(buf.get(0, 0).fg.eql(Color.rgb(1, 2, 3)));
}
