const std = @import("std");
const cell_mod = @import("../cell.zig");
const grapheme_mod = @import("../grapheme.zig");
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Grapheme = cell_mod.Grapheme;

pub const GraphemePool = struct {
    entries: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GraphemePool {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GraphemePool) void {
        for (self.entries.items) |slice| {
            self.allocator.free(slice);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *GraphemePool, bytes: []const u8) !u32 {
        const duped = try self.allocator.dupe(u8, bytes);
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, duped);
        return idx;
    }

    pub fn get(self: *const GraphemePool, id: u32) []const u8 {
        return self.entries.items[id];
    }

    pub fn clear(self: *GraphemePool) void {
        for (self.entries.items) |slice| {
            self.allocator.free(slice);
        }
        self.entries.clearRetainingCapacity();
    }
};

pub const Buffer = struct {
    cells: []Cell,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,
    grapheme_pool: GraphemePool,
    link_table: std.ArrayList([]const u8),
    width_method: grapheme_mod.WidthMethod,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, width_method: grapheme_mod.WidthMethod) !Buffer {
        const len: usize = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alloc(Cell, len);
        @memset(cells, Cell.blank);
        return .{
            .cells = cells,
            .width = width,
            .height = height,
            .allocator = allocator,
            .grapheme_pool = GraphemePool.init(allocator),
            .link_table = .empty,
            .width_method = width_method,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
        self.grapheme_pool.deinit();
        for (self.link_table.items) |url| {
            self.allocator.free(url);
        }
        self.link_table.deinit(self.allocator);
    }

    pub fn resize(self: *Buffer, width: u32, height: u32) !void {
        const len: usize = @as(usize, width) * @as(usize, height);
        self.allocator.free(self.cells);
        self.cells = try self.allocator.alloc(Cell, len);
        self.width = width;
        self.height = height;
        @memset(self.cells, Cell.blank);
        self.grapheme_pool.clear();
        for (self.link_table.items) |url| {
            self.allocator.free(url);
        }
        self.link_table.clearRetainingCapacity();
    }

    pub fn clear(self: *Buffer) void {
        @memset(self.cells, Cell.blank);
        self.grapheme_pool.clear();
        for (self.link_table.items) |url| {
            self.allocator.free(url);
        }
        self.link_table.clearRetainingCapacity();
    }

    pub fn get(self: *const Buffer, x: u32, y: u32) Cell {
        if (x >= self.width or y >= self.height) return Cell.blank;
        return self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn appendCellText(self: *const Buffer, out: anytype, allocator: std.mem.Allocator, cell: Cell) !void {
        if (cell.width == 0) return;
        switch (cell.grapheme) {
            .codepoint => |cp| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return;
                try out.appendSlice(allocator, buf[0..len]);
            },
            .pooled => |id| try out.appendSlice(allocator, self.grapheme_pool.get(id)),
        }
    }

    pub fn cellIsSpace(self: *const Buffer, cell: Cell) bool {
        if (cell.width == 0) return true;
        return switch (cell.grapheme) {
            .codepoint => |cp| cp == ' ',
            .pooled => |id| std.mem.eql(u8, self.grapheme_pool.get(id), " "),
        };
    }

    pub fn set(self: *Buffer, x: u32, y: u32, c: Cell) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);

        // If replacing a continuation cell, clear the probable start cell to
        // avoid stale wide/grapheme left halves after partial overwrites.
        if (self.cells[idx].width == 0 and x > 0) {
            self.cells[idx - 1] = Cell.blank;
        }

        // If replacing a wide/grapheme start, clear its continuation cells.
        const old = self.cells[idx];
        if (old.width > 1) {
            var i: u32 = 1;
            while (i < old.width and x + i < self.width) : (i += 1) {
                self.cells[idx + i] = Cell.blank;
            }
        }

        self.cells[idx] = c;

        // Install continuation cells for wide/grapheme starts.
        if (c.width > 1) {
            var i: u32 = 1;
            while (i < c.width and x + i < self.width) : (i += 1) {
                self.cells[idx + i] = .{
                    .grapheme = .{ .codepoint = ' ' },
                    .fg = c.fg,
                    .bg = c.bg,
                    .attrs = c.attrs,
                    .width = 0,
                    .link_id = c.link_id,
                };
            }
        }
    }

    pub fn writeStr(self: *Buffer, x: u32, y: u32, text: []const u8, fg: Color, bg: Color, attrs: Attributes) u32 {
        return self.writeStrLink(x, y, text, fg, bg, attrs, 0);
    }

    pub fn writeStrLink(self: *Buffer, x: u32, y: u32, text: []const u8, fg: Color, bg: Color, attrs: Attributes, link_id: u16) u32 {
        if (y >= self.height) return 0;
        var col = x;
        var i: usize = 0;
        while (i < text.len) {
            const cluster = grapheme_mod.nextCluster(text, i, self.width_method) orelse break;
            if (cluster.bytes.len == 0) break;
            i += cluster.bytes.len;
            const w = cluster.width;
            if (w == 0) continue;
            if (col + @as(u32, w) > self.width) break;

            const g: Grapheme = if (cluster.single_codepoint) |cp|
                .{ .codepoint = cp }
            else blk: {
                const id = self.grapheme_pool.add(cluster.bytes) catch break;
                break :blk .{ .pooled = id };
            };

            self.set(col, y, .{
                .grapheme = g,
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
                .width = w,
                .link_id = link_id,
            });
            col += @as(u32, w);
        }
        return col - x;
    }

    pub fn fill(self: *Buffer, x: u32, y: u32, w: u32, h: u32, c: Cell) void {
        const end_y = @min(self.height, y +| h);
        const end_x = @min(self.width, x +| w);
        var row = y;
        while (row < end_y) : (row += 1) {
            var col = x;
            while (col < end_x) : (col += 1) {
                self.set(col, row, c);
            }
        }
    }

    pub fn addLink(self: *Buffer, url: []const u8) !u16 {
        for (self.link_table.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, url)) return @intCast(i + 1);
        }
        if (self.link_table.items.len >= std.math.maxInt(u16)) return error.TooManyLinks;
        const duped = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(duped);
        try self.link_table.append(self.allocator, duped);
        return @intCast(self.link_table.items.len);
    }

    pub fn region(self: *Buffer) Region {
        return .{
            .buf = self,
            .x = 0,
            .y = 0,
            .width = self.width,
            .height = self.height,
        };
    }
};

pub const Region = struct {
    buf: *Buffer,
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn set(self: Region, x: u32, y: u32, c: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.buf.set(self.x + x, self.y + y, c);
    }

    pub fn get(self: Region, x: u32, y: u32) Cell {
        if (x >= self.width or y >= self.height) return Cell.blank;
        return self.buf.get(self.x + x, self.y + y);
    }

    pub fn writeStr(self: Region, x: u32, y: u32, text: []const u8, fg: Color, bg: Color, attrs: Attributes) u32 {
        return self.writeStrLink(x, y, text, fg, bg, attrs, 0);
    }

    pub fn writeStrLink(self: Region, x: u32, y: u32, text: []const u8, fg: Color, bg: Color, attrs: Attributes, link_id: u16) u32 {
        if (x >= self.width or y >= self.height) return 0;
        const max_w = self.width - x;
        const clipped = grapheme_mod.sliceToWidth(text, max_w, self.buf.width_method);
        return self.buf.writeStrLink(self.x + x, self.y + y, clipped, fg, bg, attrs, link_id);
    }

    pub fn textWidth(self: Region, text: []const u8) u32 {
        return @intCast(grapheme_mod.strWidth(text, self.buf.width_method));
    }

    pub fn sliceToWidth(self: Region, text: []const u8, max_cols: u32) []const u8 {
        return grapheme_mod.sliceToWidth(text, max_cols, self.buf.width_method);
    }

    pub fn fill(self: Region, x: u32, y: u32, w: u32, h: u32, c: Cell) void {
        if (x >= self.width or y >= self.height) return;
        const cw = @min(w, self.width - x);
        const ch = @min(h, self.height - y);
        self.buf.fill(self.x +| x, self.y +| y, cw, ch, c);
    }

    pub fn sub(self: Region, x: u32, y: u32, w: u32, h: u32) Region {
        if (x >= self.width or y >= self.height) {
            return .{ .buf = self.buf, .x = self.x, .y = self.y, .width = 0, .height = 0 };
        }
        return .{
            .buf = self.buf,
            .x = self.x + x,
            .y = self.y + y,
            .width = @min(w, self.width - x),
            .height = @min(h, self.height - y),
        };
    }
};

test "Buffer read-write round-trip and clear" {
    var buf = try Buffer.init(std.testing.allocator, 10, 5, .wcwidth);
    defer buf.deinit();

    try std.testing.expect(buf.get(0, 0).eql(Cell.blank));
    buf.set(3, 2, Cell{ .grapheme = .{ .codepoint = 'X' }, .fg = Color.rgb(255, 0, 0) });
    try std.testing.expectEqual(@as(u21, 'X'), buf.get(3, 2).grapheme.codepoint);
    buf.set(99, 99, Cell{ .grapheme = .{ .codepoint = 'Z' } });
    buf.clear();
    try std.testing.expect(buf.get(3, 2).eql(Cell.blank));
}

test "writeStr and fill respect buffer bounds" {
    var buf = try Buffer.init(std.testing.allocator, 5, 2, .wcwidth);
    defer buf.deinit();

    const cols = buf.writeStr(0, 0, "hello world", Color.default, Color.default, Attributes.none);
    try std.testing.expectEqual(@as(u32, 5), cols);
    try std.testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    buf.fill(1, 0, 3, 2, Cell{ .grapheme = .{ .codepoint = '#' } });
    try std.testing.expectEqual(@as(u21, '#'), buf.get(2, 1).grapheme.codepoint);
}

test "Region clips and nests correctly" {
    var buf = try Buffer.init(std.testing.allocator, 20, 20, .wcwidth);
    defer buf.deinit();

    const r = Region{ .buf = &buf, .x = 5, .y = 5, .width = 10, .height = 10 };
    r.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'A' } });
    try std.testing.expectEqual(@as(u21, 'A'), buf.get(5, 5).grapheme.codepoint);
    r.set(15, 0, Cell{ .grapheme = .{ .codepoint = 'B' } });
    try std.testing.expect(buf.get(20, 5).eql(Cell.blank));

    const inner = r.sub(2, 3, 4, 4);
    try std.testing.expectEqual(@as(u32, 7), inner.x);
    try std.testing.expectEqual(@as(u32, 8), inner.y);
}

test "writeStr stores grapheme clusters as pooled cells" {
    var buf = try Buffer.init(std.testing.allocator, 8, 2, .wcwidth);
    defer buf.deinit();

    const combining_cols = buf.writeStr(0, 0, "e\u{0301}x", Color.default, Color.default, Attributes.none);
    try std.testing.expectEqual(@as(u32, 2), combining_cols);
    try std.testing.expect(buf.get(0, 0).grapheme == .pooled);
    try std.testing.expectEqualStrings("e\u{0301}", buf.grapheme_pool.get(buf.get(0, 0).grapheme.pooled));
    try std.testing.expectEqual(@as(u2, 1), buf.get(0, 0).width);
    try std.testing.expectEqual(@as(u21, 'x'), buf.get(1, 0).grapheme.codepoint);

    const emoji_cols = buf.writeStr(0, 1, "👩‍🚀!", Color.default, Color.default, Attributes.none);
    try std.testing.expectEqual(@as(u32, 3), emoji_cols);
    try std.testing.expect(buf.get(0, 1).grapheme == .pooled);
    try std.testing.expectEqualStrings("👩‍🚀", buf.grapheme_pool.get(buf.get(0, 1).grapheme.pooled));
    try std.testing.expectEqual(@as(u2, 2), buf.get(0, 1).width);
    try std.testing.expectEqual(@as(u2, 0), buf.get(1, 1).width);
    try std.testing.expectEqual(@as(u21, '!'), buf.get(2, 1).grapheme.codepoint);
}

test "appendCellText extracts pooled graphemes" {
    var buf = try Buffer.init(std.testing.allocator, 4, 1, .wcwidth);
    defer buf.deinit();

    _ = buf.writeStr(0, 0, "e\u{0301}x", Color.default, Color.default, Attributes.none);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try buf.appendCellText(&out, std.testing.allocator, buf.get(0, 0));
    try buf.appendCellText(&out, std.testing.allocator, buf.get(1, 0));
    try std.testing.expectEqualStrings("e\u{0301}x", out.items);
}

test "Buffer.set clears stale wide continuations" {
    var buf = try Buffer.init(std.testing.allocator, 4, 1, .wcwidth);
    defer buf.deinit();

    _ = buf.writeStr(0, 0, "界x", Color.default, Color.default, Attributes.none);
    try std.testing.expectEqual(@as(u2, 2), buf.get(0, 0).width);
    try std.testing.expectEqual(@as(u2, 0), buf.get(1, 0).width);

    buf.set(1, 0, Cell{ .grapheme = .{ .codepoint = 'A' } });
    try std.testing.expect(buf.get(0, 0).eql(Cell.blank));
    try std.testing.expectEqual(@as(u21, 'A'), buf.get(1, 0).grapheme.codepoint);

    _ = buf.writeStr(0, 0, "界", Color.default, Color.default, Attributes.none);
    buf.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'B' } });
    try std.testing.expectEqual(@as(u21, 'B'), buf.get(0, 0).grapheme.codepoint);
    try std.testing.expect(buf.get(1, 0).eql(Cell.blank));
}

test "GraphemePool stores and retrieves clusters" {
    var pool = GraphemePool.init(std.testing.allocator);
    defer pool.deinit();
    const id = try pool.add("👨‍👩‍👧");
    try std.testing.expectEqualStrings("👨‍👩‍👧", pool.get(id));
}

test "Buffer addLink dedupes and guards id overflow" {
    var buf = try Buffer.init(std.testing.allocator, 1, 1, .wcwidth);
    defer buf.deinit();

    const first = try buf.addLink("https://example.test");
    const second = try buf.addLink("https://example.test");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), buf.link_table.items.len);

    while (buf.link_table.items.len < std.math.maxInt(u16)) {
        const url = try std.testing.allocator.dupe(u8, "x");
        try buf.link_table.append(std.testing.allocator, url);
    }
    try std.testing.expectError(error.TooManyLinks, buf.addLink("https://overflow.test"));
}
