const std = @import("std");
const excerpt_mod = @import("excerpt.zig");
const box_chrome = @import("chrome.zig");
const layout_mod = @import("layout.zig");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");

const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Allocator = std.mem.Allocator;

pub const LineStyle = enum {
    none,
    added,
    removed,
    context,
};

pub const Row = struct {
    gutter: ?[]const u8 = null,
    text: []const u8 = "",
    highlight: bool = true,
    style: LineStyle = .none,
    is_elision: bool = false,
    elision_count: u32 = 0,
};

pub const Stats = struct {
    added: u32 = 0,
    removed: u32 = 0,
};

pub const Palette = struct {
    base: box_chrome.Style,
    added: box_chrome.Style,
    removed: box_chrome.Style,
    context: box_chrome.Style,
};

pub const OwnedSurface = struct {
    allocator: Allocator,
    rows: std.ArrayList(Row) = .empty,
    owned_texts: std.ArrayList([]u8) = .empty,
    owned_gutters: std.ArrayList([]u8) = .empty,
    raw_buf: std.ArrayList(u8) = .empty,
    collapsed_items: std.ArrayList(excerpt_mod.WindowItem) = .empty,
    header: ?[]const u8 = null,
    owned_header: ?[]u8 = null,
    notice: ?[]const u8 = null,
    owned_notice: ?[]u8 = null,
    stats: ?Stats = null,
    gutter_width: u32 = 0,
    collapsed_visible_lines: u32 = 0,
    collapsed_gap_count: u32 = 0,
    layout: layout_mod.Retained,
    layout_palette: ?Palette = null,

    pub fn init(allocator: Allocator) OwnedSurface {
        return .{ .allocator = allocator, .layout = layout_mod.Retained.init(allocator) };
    }

    pub fn deinit(self: *OwnedSurface) void {
        self.clear();
        self.layout.deinit();
        self.rows.deinit(self.allocator);
        self.owned_texts.deinit(self.allocator);
        self.owned_gutters.deinit(self.allocator);
        self.raw_buf.deinit(self.allocator);
        self.collapsed_items.deinit(self.allocator);
    }

    pub fn clear(self: *OwnedSurface) void {
        for (self.owned_texts.items) |text| self.allocator.free(text);
        self.owned_texts.clearRetainingCapacity();

        for (self.owned_gutters.items) |gutter| self.allocator.free(gutter);
        self.owned_gutters.clearRetainingCapacity();

        self.rows.clearRetainingCapacity();
        self.raw_buf.clearRetainingCapacity();
        self.collapsed_items.clearRetainingCapacity();

        if (self.owned_header) |header| self.allocator.free(header);
        if (self.owned_notice) |notice| self.allocator.free(notice);
        self.header = null;
        self.owned_header = null;
        self.notice = null;
        self.owned_notice = null;
        self.stats = null;
        self.gutter_width = 0;
        self.collapsed_visible_lines = 0;
        self.collapsed_gap_count = 0;
        self.layout.invalidate();
        self.layout_palette = null;
    }

    pub fn setHeaderOwned(self: *OwnedSurface, header: []u8) void {
        if (self.owned_header) |old| self.allocator.free(old);
        self.owned_header = header;
        self.header = header;
    }

    pub fn setNoticeOwned(self: *OwnedSurface, notice: []u8) void {
        if (self.owned_notice) |old| self.allocator.free(old);
        self.owned_notice = notice;
        self.notice = notice;
    }

    pub fn setCollapsedExcerpts(self: *OwnedSurface, excerpts: []const excerpt_mod.Excerpt) !void {
        self.collapsed_items.clearRetainingCapacity();
        self.collapsed_visible_lines = 0;
        self.collapsed_gap_count = 0;

        const total: u32 = @intCast(self.rows.items.len);
        if (total == 0) return;

        var window = try excerpt_mod.windowExcerpts(self.allocator, total, excerpts);
        defer window.deinit();

        try self.collapsed_items.appendSlice(self.allocator, window.items);
        for (self.collapsed_items.items) |item| switch (item) {
            .span => |span| self.collapsed_visible_lines += span.end - span.start,
            .gap => self.collapsed_gap_count += 1,
        };
    }

    pub fn measure(self: *const OwnedSurface, expanded: bool) u32 {
        if (self.rows.items.len == 0) return 0;

        const visible_lines: u32 = if (expanded)
            @intCast(self.rows.items.len)
        else
            self.collapsedVisibleLines();
        const gap_count: u32 = if (expanded) 0 else self.collapsed_gap_count;

        var height = box_chrome.measureHeight(visible_lines, gap_count);
        if (self.stats != null) height += 1;
        if (self.notice != null) height += 1;
        return height;
    }

    pub fn renderSlice(
        self: *OwnedSurface,
        region: Region,
        palette: Palette,
        expanded: bool,
        first_row: u32,
    ) void {
        if (region.width == 0 or region.height == 0) return;
        if (self.rows.items.len == 0) return;

        const total_height = self.measure(expanded);
        if (first_row >= total_height) return;
        self.ensureLayout(palette, expanded) catch return;
        self.layout.renderSlice(region, first_row);
    }

    fn ensureLayout(self: *OwnedSurface, palette: Palette, expanded: bool) !void {
        const key: layout_mod.Key = .{ .width = 0, .expanded = expanded };
        if (self.layout.matches(key) and paletteEql(self.layout_palette, palette)) return;
        const arena = self.layout.reset();
        var builder = layout_mod.Builder.init(arena);
        if (self.stats) |stats| try appendStats(&builder, stats, palette);
        try builder.appendRow(try box_chrome.topSegments(arena, self.header, palette.base));
        if (expanded or self.collapsed_items.items.len == 0) {
            for (self.rows.items) |row| try self.appendSurfaceRow(&builder, row, palette);
        } else {
            for (self.collapsed_items.items) |item| switch (item) {
                .span => |span| {
                    var idx: usize = span.start;
                    while (idx < span.end) : (idx += 1) try self.appendSurfaceRow(&builder, self.rows.items[idx], palette);
                },
                .gap => |count| try builder.appendRow(try box_chrome.elisionSegments(arena, count, self.gutter_width, palette.base)),
            };
        }
        try builder.appendRow(try box_chrome.bottomSegments(arena, palette.base));
        if (self.notice) |notice| try builder.appendRow(try box_chrome.noticeSegments(arena, notice, palette.base));
        self.layout.setRows(key, try builder.toOwnedRows());
        self.layout_palette = palette;
    }

    fn appendSurfaceRow(self: *const OwnedSurface, builder: *layout_mod.Builder, row: Row, palette: Palette) !void {
        const arena = builder.allocator;
        if (row.is_elision) {
            try builder.appendRow(try box_chrome.elisionSegments(arena, row.elision_count, self.gutter_width, palette.base));
        } else {
            const style = lineStyle(palette, row.style);
            try builder.appendRow(try box_chrome.contentSegments(arena, row.gutter, self.gutter_width, row.text, style, row.highlight or row.style != .none));
        }
    }

    fn collapsedVisibleLines(self: *const OwnedSurface) u32 {
        if (self.collapsed_items.items.len == 0 and self.rows.items.len > 0) {
            return @intCast(self.rows.items.len);
        }
        return self.collapsed_visible_lines;
    }

    fn appendStats(builder: *layout_mod.Builder, stats: Stats, palette: Palette) !void {
        const arena = builder.allocator;
        var segs: std.ArrayListUnmanaged(layout_mod.Segment) = .empty;
        var col: u32 = 0;
        if (stats.added > 0) {
            const txt = try std.fmt.allocPrint(arena, "+{d}", .{stats.added});
            try segs.append(arena, .{ .x = col, .text = txt, .style = .{ .fg = palette.added.fg, .attrs = .{ .bold = true } } });
            col += @intCast(txt.len);
        }
        if (stats.removed > 0) {
            if (col > 0) { try segs.append(arena, .{ .x = col, .text = " " }); col += 1; }
            const txt = try std.fmt.allocPrint(arena, "-{d}", .{stats.removed});
            try segs.append(arena, .{ .x = col, .text = txt, .style = .{ .fg = palette.removed.fg, .attrs = .{ .bold = true } } });
        }
        if (segs.items.len == 0) try segs.append(arena, .{ .x = 0, .text = "no changes", .style = .{ .fg = palette.base.dim } });
        try builder.appendRow(try segs.toOwnedSlice(arena));
    }

    fn lineStyle(palette: Palette, style: LineStyle) box_chrome.Style {
        return switch (style) {
            .none => palette.base,
            .added => palette.added,
            .removed => palette.removed,
            .context => palette.context,
        };
    }

};

fn styleEql(a: box_chrome.Style, b: box_chrome.Style) bool {
    return a.chrome.eql(b.chrome) and a.fg.eql(b.fg) and a.dim.eql(b.dim);
}

fn paletteEql(a_opt: ?Palette, b: Palette) bool {
    const a = a_opt orelse return false;
    return styleEql(a.base, b.base) and styleEql(a.added, b.added) and styleEql(a.removed, b.removed) and styleEql(a.context, b.context);
}

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn rowAscii(buf: *const Buffer, y: u32, out: []u8) []const u8 {
    var len: usize = 0;
    var x: u32 = 0;
    while (x < buf.width and len < out.len) : (x += 1) {
        const cell = buf.get(x, y);
        if (cell.width == 0) continue;
        switch (cell.grapheme) {
            .codepoint => |cp| out[len] = if (cp <= 0x7f) @intCast(cp) else '?',
            .pooled => out[len] = '?',
        }
        len += 1;
    }
    return std.mem.trimEnd(u8, out[0..len], " ");
}

test "owned surface renders collapsed rows and gaps from an arbitrary offset" {
    var surface = OwnedSurface.init(testing.allocator);
    defer surface.deinit();

    try surface.rows.append(testing.allocator, .{ .text = "line1" });
    try surface.rows.append(testing.allocator, .{ .text = "line2" });
    try surface.rows.append(testing.allocator, .{ .text = "line3" });
    try surface.rows.append(testing.allocator, .{ .text = "line4" });
    try surface.rows.append(testing.allocator, .{ .text = "line5" });
    try surface.setCollapsedExcerpts(&.{
        .{ .focus = .head, .context = 1 },
        .{ .focus = .tail, .context = 1 },
    });

    const palette = Palette{
        .base = .{ .chrome = Color.default, .fg = Color.default, .dim = Color.default },
        .added = .{ .chrome = Color.default, .fg = Color.default, .dim = Color.default },
        .removed = .{ .chrome = Color.default, .fg = Color.default, .dim = Color.default },
        .context = .{ .chrome = Color.default, .fg = Color.default, .dim = Color.default },
    };

    var buf = try Buffer.init(testing.allocator, 40, 4, .wcwidth);
    defer buf.deinit();

    surface.renderSlice(buf.region(), palette, false, 1);

    var row0: [40]u8 = undefined;
    var row1: [40]u8 = undefined;
    var row2: [40]u8 = undefined;
    var row3: [40]u8 = undefined;
    try testing.expectEqualStrings("? line1", rowAscii(&buf, 0, &row0));
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 1, &row1), "more lines") != null);
    try testing.expectEqualStrings("? line5", rowAscii(&buf, 2, &row2));
    try testing.expectEqualStrings("?????", rowAscii(&buf, 3, &row3));
}
