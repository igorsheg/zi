const std = @import("std");
const excerpt_mod = @import("excerpt.zig");
const box_chrome = @import("box_chrome.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");

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

    pub fn init(allocator: Allocator) OwnedSurface {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OwnedSurface) void {
        self.clear();
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
        self: *const OwnedSurface,
        region: Region,
        palette: Palette,
        expanded: bool,
        first_row: u32,
    ) void {
        if (region.width == 0 or region.height == 0) return;
        if (self.rows.items.len == 0) return;

        const total_height = self.measure(expanded);
        if (first_row >= total_height) return;

        const row_end = first_row +| region.height;
        var virtual_row: u32 = 0;

        if (self.stats) |stats| {
            self.maybeDrawStats(region, first_row, row_end, &virtual_row, stats, palette);
        }
        self.maybeDrawTop(region, first_row, row_end, &virtual_row, palette.base);

        if (expanded or self.collapsed_items.items.len == 0) {
            for (self.rows.items) |row| {
                self.maybeDrawSurfaceRow(region, first_row, row_end, &virtual_row, row, palette);
            }
        } else {
            for (self.collapsed_items.items) |item| switch (item) {
                .span => |span| {
                    var idx: usize = span.start;
                    while (idx < span.end) : (idx += 1) {
                        self.maybeDrawSurfaceRow(region, first_row, row_end, &virtual_row, self.rows.items[idx], palette);
                    }
                },
                .gap => |count| self.maybeDrawExcerptGap(region, first_row, row_end, &virtual_row, count, palette.base),
            };
        }

        self.maybeDrawBottom(region, first_row, row_end, &virtual_row, palette.base);
        if (self.notice) |notice| {
            self.maybeDrawNotice(region, first_row, row_end, &virtual_row, notice, palette.base);
        }
    }

    fn collapsedVisibleLines(self: *const OwnedSurface) u32 {
        if (self.collapsed_items.items.len == 0 and self.rows.items.len > 0) {
            return @intCast(self.rows.items.len);
        }
        return self.collapsed_visible_lines;
    }

    fn lineStyle(palette: Palette, style: LineStyle) box_chrome.Style {
        return switch (style) {
            .none => palette.base,
            .added => palette.added,
            .removed => palette.removed,
            .context => palette.context,
        };
    }

    fn screenRow(first_row: u32, row_end: u32, virtual_row: u32) ?u32 {
        if (virtual_row < first_row or virtual_row >= row_end) return null;
        return virtual_row - first_row;
    }

    fn maybeDrawStats(self: *const OwnedSurface, region: Region, first_row: u32, row_end: u32, virtual_row: *u32, stats: Stats, palette: Palette) void {
        _ = self;
        if (screenRow(first_row, row_end, virtual_row.*)) |screen_row| {
            var col: u32 = 0;
            if (stats.added > 0) {
                var buf: [16]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "+{d}", .{stats.added}) catch "+?";
                col += region.writeStr(col, screen_row, txt, palette.added.fg, Color.default, .{ .bold = true });
            }
            if (stats.removed > 0) {
                if (col > 0) col += region.writeStr(col, screen_row, " ", Color.default, Color.default, .{});
                var buf: [16]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "-{d}", .{stats.removed}) catch "-?";
                col += region.writeStr(col, screen_row, txt, palette.removed.fg, Color.default, .{ .bold = true });
            }
            if (col == 0) {
                _ = region.writeStr(0, screen_row, "no changes", palette.base.dim, Color.default, .{});
            }
        }
        virtual_row.* += 1;
    }

    fn maybeDrawTop(self: *const OwnedSurface, region: Region, first_row: u32, row_end: u32, virtual_row: *u32, style: box_chrome.Style) void {
        if (screenRow(first_row, row_end, virtual_row.*)) |screen_row| {
            _ = box_chrome.drawTop(region, screen_row, self.header, style);
        }
        virtual_row.* += 1;
    }

    fn maybeDrawSurfaceRow(self: *const OwnedSurface, region: Region, first_row: u32, row_end: u32, virtual_row: *u32, row: Row, palette: Palette) void {
        if (screenRow(first_row, row_end, virtual_row.*)) |screen_row| {
            if (row.is_elision) {
                _ = box_chrome.drawElision(region, screen_row, row.elision_count, self.gutter_width, palette.base);
            } else {
                const style = lineStyle(palette, row.style);
                _ = box_chrome.drawContentLine(
                    region,
                    screen_row,
                    row.gutter,
                    self.gutter_width,
                    row.text,
                    style,
                    row.highlight or row.style != .none,
                );
            }
        }
        virtual_row.* += 1;
    }

    fn maybeDrawExcerptGap(self: *const OwnedSurface, region: Region, first_row: u32, row_end: u32, virtual_row: *u32, count: u32, style: box_chrome.Style) void {
        if (screenRow(first_row, row_end, virtual_row.*)) |screen_row| {
            _ = box_chrome.drawElision(region, screen_row, count, self.gutter_width, style);
        }
        virtual_row.* += 1;
    }

    fn maybeDrawBottom(self: *const OwnedSurface, region: Region, first_row: u32, row_end: u32, virtual_row: *u32, style: box_chrome.Style) void {
        _ = self;
        if (screenRow(first_row, row_end, virtual_row.*)) |screen_row| {
            _ = box_chrome.drawBottom(region, screen_row, style);
        }
        virtual_row.* += 1;
    }

    fn maybeDrawNotice(self: *const OwnedSurface, region: Region, first_row: u32, row_end: u32, virtual_row: *u32, notice: []const u8, style: box_chrome.Style) void {
        _ = self;
        if (screenRow(first_row, row_end, virtual_row.*)) |screen_row| {
            _ = region.writeStr(0, screen_row, "[", style.dim, Color.default, .{});
            const after_bracket = region.writeStr(1, screen_row, notice, style.dim, Color.default, .{});
            _ = region.writeStr(1 + after_bracket, screen_row, "]", style.dim, Color.default, .{});
        }
        virtual_row.* += 1;
    }
};

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn rowAscii(buf: *const Buffer, y: u32, out: []u8) []const u8 {
    var len: usize = 0;
    var x: u32 = 0;
    while (x < buf.width and len < out.len) : (x += 1) {
        const cp = buf.get(x, y).grapheme.codepoint;
        out[len] = if (cp <= 0x7f) @intCast(cp) else '?';
        len += 1;
    }
    return std.mem.trimRight(u8, out[0..len], " ");
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

    var buf = try Buffer.init(testing.allocator, 40, 4);
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
