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

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Buffer {
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

    pub fn set(self: *Buffer, x: u32, y: u32, c: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = c;
    }

    pub fn writeStr(self: *Buffer, x: u32, y: u32, text: []const u8, fg: Color, bg: Color, attrs: Attributes) u32 {
        if (y >= self.height) return 0;
        var col = x;
        var i: usize = 0;
        while (i < text.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + byte_len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i..][0..byte_len]) catch {
                i += 1;
                continue;
            };
            const w = grapheme_mod.charWidth(cp);
            if (w == 0) {
                i += byte_len;
                continue;
            }
            if (col + @as(u32, w) > self.width) break;
            self.set(col, y, .{
                .grapheme = .{ .codepoint = cp },
                .fg = fg,
                .bg = bg,
                .attrs = attrs,
                .width = w,
            });
            if (w == 2) {
                self.set(col + 1, y, .{
                    .grapheme = .{ .codepoint = ' ' },
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                    .width = 0,
                });
            }
            col += @as(u32, w);
            i += byte_len;
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
        const duped = try self.allocator.dupe(u8, url);
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
        if (x >= self.width or y >= self.height) return 0;
        const max_w = self.width - x;
        const clipped = grapheme_mod.sliceToWidth(text, max_w);
        return self.buf.writeStr(self.x + x, self.y + y, clipped, fg, bg, attrs);
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
    var buf = try Buffer.init(std.testing.allocator, 10, 5);
    defer buf.deinit();

    try std.testing.expect(buf.get(0, 0).eql(Cell.blank));
    buf.set(3, 2, Cell{ .grapheme = .{ .codepoint = 'X' }, .fg = Color.rgb(255, 0, 0) });
    try std.testing.expectEqual(@as(u21, 'X'), buf.get(3, 2).grapheme.codepoint);
    buf.set(99, 99, Cell{ .grapheme = .{ .codepoint = 'Z' } });
    buf.clear();
    try std.testing.expect(buf.get(3, 2).eql(Cell.blank));
}

test "writeStr and fill respect buffer bounds" {
    var buf = try Buffer.init(std.testing.allocator, 5, 2);
    defer buf.deinit();

    const cols = buf.writeStr(0, 0, "hello world", Color.default, Color.default, Attributes.none);
    try std.testing.expectEqual(@as(u32, 5), cols);
    try std.testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    buf.fill(1, 0, 3, 2, Cell{ .grapheme = .{ .codepoint = '#' } });
    try std.testing.expectEqual(@as(u21, '#'), buf.get(2, 1).grapheme.codepoint);
}

test "Region clips and nests correctly" {
    var buf = try Buffer.init(std.testing.allocator, 20, 20);
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

test "GraphemePool stores and retrieves clusters" {
    var pool = GraphemePool.init(std.testing.allocator);
    defer pool.deinit();
    const id = try pool.add("👨‍👩‍👧");
    try std.testing.expectEqualStrings("👨‍👩‍👧", pool.get(id));
}
