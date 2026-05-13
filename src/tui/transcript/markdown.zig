const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const component_mod = @import("../primitives/view.zig");
const grapheme_mod = @import("../grapheme.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const parser_mod = @import("../markdown/parser.zig");
const render_mod = @import("../markdown/render.zig");
const layout_mod = @import("layout.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;

pub const Span = render_mod.Span;
pub const RenderedLine = render_mod.RenderedLine;
pub const code_inline_bg = render_mod.code_inline_bg;

pub const Markdown = struct {
    content: []const u8 = "",
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},
    padding_x: u32 = 0,
    padding_y: u32 = 0,
    scroll_offset: u32 = 0,
    theme: *const theme_mod.Theme = undefined,
    code_block_indent: []const u8 = "  ",
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    content_buf: std.ArrayListUnmanaged(u8) = .empty,
    cached_rows: ?[]const layout_mod.Row = null,
    cached_width: u32 = 0,
    cached_content_len: usize = 0,
    cached_width_method: grapheme_mod.WidthMethod = .wcwidth,
    width_method: grapheme_mod.WidthMethod = .wcwidth,

    pub fn init(allocator: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) Markdown {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .theme = themes_builtin.dark(),
            .cached_width_method = width_method,
            .width_method = width_method,
        };
    }

    pub fn deinit(self: *Markdown) void {
        self.content_buf.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn setContent(self: *Markdown, text: []const u8) void {
        self.content_buf.clearRetainingCapacity();
        self.content_buf.appendSlice(self.allocator, text) catch return;
        self.content = self.content_buf.items;
        self.invalidate();
    }

    pub fn appendContent(self: *Markdown, delta: []const u8) void {
        self.content_buf.appendSlice(self.allocator, delta) catch return;
        self.content = self.content_buf.items;
        self.invalidate();
    }

    pub fn setWidthMethod(self: *Markdown, width_method: grapheme_mod.WidthMethod) void {
        if (self.width_method == width_method) return;
        self.width_method = width_method;
        self.invalidate();
    }

    pub fn scrollToBottom(self: *Markdown, visible_height: u32) void {
        const total = self.totalLines(visible_height);
        self.scroll_offset = if (total > visible_height) @intCast(total - visible_height) else 0;
    }

    pub fn totalLines(self: *Markdown, visible_width: u32) u32 {
        return self.measure(visible_width).preferred_height;
    }

    pub fn invalidate(self: *Markdown) void {
        self.cached_rows = null;
    }

    pub fn component(self: *Markdown) component_mod.Component {
        return component_mod.Component.init(Markdown, self);
    }

    pub fn measure(self: *Markdown, width: u32) Measurement {
        if (self.content.len == 0) return .{ .min_height = 0, .preferred_height = 0 };
        if (width == 0) return .{ .min_height = 1, .preferred_height = 1 };

        const content_width = if (width > self.padding_x * 2) width - self.padding_x * 2 else 1;
        const rendered = self.getLayoutRows(content_width, self.width_method) orelse return .{ .min_height = 1, .preferred_height = 1 };
        return .{
            .min_height = 1,
            .preferred_height = @intCast(rendered.len),
        };
    }

    pub fn render(self: *Markdown, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *Markdown, region: Region, first_row: u32) void {
        if (self.content.len == 0) return;
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        const content_width = if (w > self.padding_x * 2) w - self.padding_x * 2 else 1;
        const width_method = region.buf.width_method;
        const rendered = self.getLayoutRows(content_width, width_method) orelse return;
        if (!self.bg.eql(Color.default)) region.fill(0, 0, w, h, .{ .grapheme = .{ .codepoint = ' ' }, .fg = self.fg, .bg = self.bg });
        layout_mod.renderRowsSlice(rendered, region, self.scroll_offset + first_row);
    }

    fn getLayoutRows(self: *Markdown, content_width: u32, width_method: grapheme_mod.WidthMethod) ?[]const layout_mod.Row {
        if (self.cached_rows) |cached| {
            if (self.cached_width == content_width and self.cached_content_len == self.content.len and self.cached_width_method == width_method) {
                return cached;
            }
        }

        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();

        const doc = parser_mod.parseDocument(self.content, arena) catch {
            return null;
        };

        const built = render_mod.renderDocument(doc, content_width, self.theme, .{
            .fg = self.fg,
            .bg = Color.default,
            .attrs = self.attrs,
        }, self.code_block_indent, arena, width_method) catch {
            return null;
        };

        var rows: std.ArrayListUnmanaged(layout_mod.Row) = .empty;
        var pad: u32 = 0;
        while (pad < self.padding_y) : (pad += 1) rows.append(arena, .{}) catch return null;
        for (built) |line| {
            var segments: std.ArrayListUnmanaged(layout_mod.Segment) = .empty;
            var col = self.padding_x;
            for (line.spans) |span| {
                if (span.text.len == 0) continue;
                const effective_bg = if (span.bg.eql(Color.default)) self.bg else span.bg;
                segments.append(arena, .{ .x = col, .text = span.text, .style = .{ .fg = span.fg, .bg = effective_bg, .attrs = span.attrs } }) catch return null;
                col += @intCast(grapheme_mod.strWidth(span.text, width_method));
            }
            const owned_segments = segments.toOwnedSlice(arena) catch return null;
            rows.append(arena, .{ .segments = owned_segments }) catch return null;
        }
        pad = 0;
        while (pad < self.padding_y) : (pad += 1) rows.append(arena, .{}) catch return null;

        self.cached_rows = rows.toOwnedSlice(arena) catch return null;
        self.cached_width = content_width;
        self.cached_content_len = self.content.len;
        self.cached_width_method = width_method;
        return self.cached_rows;
    }
};

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn renderToBuffer(text: []const u8, width: u32, height: u32) !Buffer {
    var md = Markdown.init(testing.allocator, .wcwidth);
    md.setContent(text);
    var buf = try Buffer.init(testing.allocator, width, height, .wcwidth);
    md.render(buf.region());
    md.deinit();
    return buf;
}

fn rowText(buf: *const Buffer, row: u32, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var col: u32 = 0;
    while (col < buf.width) : (col += 1) {
        try buf.appendCellText(&out, allocator, buf.get(col, row));
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        out.items.len -= 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn expectBufferContainsText(buf: *const Buffer, needle: []const u8) !void {
    for (0..buf.height) |row| {
        const text = try rowText(buf, @intCast(row), testing.allocator);
        defer testing.allocator.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return;
    }
    return error.ExpectedVisibleMarkdownText;
}

fn bufferHasAttr(buf: *const Buffer, comptime field: []const u8) bool {
    for (0..buf.height) |row| {
        for (0..buf.width) |col| {
            const cell = buf.get(@intCast(col), @intCast(row));
            if (@field(cell.attrs, field)) return true;
        }
    }
    return false;
}

fn bufferHasBg(buf: *const Buffer, color: Color) bool {
    for (0..buf.height) |row| {
        for (0..buf.width) |col| {
            if (buf.get(@intCast(col), @intCast(row)).bg.eql(color)) return true;
        }
    }
    return false;
}

test "markdown renders nested lists and preserves ordered numbering" {
    var buf = try renderToBuffer(
        "1. First item\n" ++
            "   - Nested bullet\n\n" ++
            "```ts\ncode\n```\n\n" ++
            "2. Second item",
        40,
        12,
    );
    defer buf.deinit();

    try expectBufferContainsText(&buf, "1. First item");
    try expectBufferContainsText(&buf, "- Nested bullet");
    try expectBufferContainsText(&buf, "2. Second item");
}

test "markdown renders blockquotes with lazy continuation and inline styling" {
    var buf = try renderToBuffer("> Quote with **bold** and `code`\ncontinued line", 40, 6);
    defer buf.deinit();

    var quoted_rows: usize = 0;
    for (0..buf.height) |row| {
        if (buf.get(0, @intCast(row)).grapheme == .codepoint and buf.get(0, @intCast(row)).grapheme.codepoint == '│') {
            quoted_rows += 1;
        }
    }
    try testing.expect(quoted_rows >= 1);
    try expectBufferContainsText(&buf, "continued");
    try testing.expect(bufferHasAttr(&buf, "bold"));
    try testing.expect(bufferHasBg(&buf, code_inline_bg));
}

test "markdown renders tables with borders wrapping and inline code" {
    var md = Markdown.init(testing.allocator, .wcwidth);
    defer md.deinit();
    md.setContent(
        "| Command | Description |\n" ++
            "| --- | --- |\n" ++
            "| `npm run build` | Build the project artifacts |",
    );

    var buf = try Buffer.init(testing.allocator, 26, 12, .wcwidth);
    defer buf.deinit();
    md.render(buf.region());

    try testing.expectEqual(@as(u21, '┌'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '│'), buf.get(0, 1).grapheme.codepoint);
    try testing.expect(buf.get(2, 3).bg.eql(code_inline_bg));
}

test "markdown renders links and html like tags as visible text" {
    var buf = try renderToBuffer("Visit [site](https://example.com) and <thinking>keep this</thinking>", 80, 4);
    defer buf.deinit();

    try expectBufferContainsText(&buf, "Visit site (https://example.com)");
    try expectBufferContainsText(&buf, "<thinking>keep this</thinking>");
    try testing.expect(bufferHasAttr(&buf, "underline"));
}

test "markdown renders pooled grapheme clusters as visible text" {
    var buf = try renderToBuffer("Cafe\u{0301} 👩‍🚀", 12, 3);
    defer buf.deinit();

    try expectBufferContainsText(&buf, "Cafe\u{0301} 👩‍🚀");
    try testing.expect(buf.get(3, 0).grapheme == .pooled);
    try testing.expect(buf.get(6, 0).grapheme == .pooled);
    try testing.expectEqual(@as(u2, 2), buf.get(6, 0).width);
    try testing.expectEqual(@as(u2, 0), buf.get(7, 0).width);
}

test "markdown applies default attrs and heading spacing without trailing blank line" {
    var md = Markdown.init(testing.allocator, .wcwidth);
    defer md.deinit();
    md.attrs = .{ .italic = true };
    md.setContent("# Title\nBody");

    const measure = md.measure(20);
    try testing.expectEqual(@as(u32, 3), measure.preferred_height);

    var buf = try Buffer.init(testing.allocator, 20, 4, .wcwidth);
    defer buf.deinit();
    md.render(buf.region());

    try testing.expect(buf.get(0, 2).attrs.italic);
    try testing.expectEqual(@as(u21, 'B'), buf.get(0, 2).grapheme.codepoint);
}
