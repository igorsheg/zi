const std = @import("std");
const Style = @import("../primitive/style.zig").Style;
const text = @import("../primitive/text.zig");

pub const InlineText = struct {
    bytes: [text.grapheme_bytes_max]u8 = undefined,
    len: u8 = 0,

    pub fn from(bytes: []const u8) InlineText {
        var result: InlineText = .{};
        if (bytes.len > result.bytes.len) {
            result.bytes[0] = '?';
            result.len = 1;
            return result;
        }
        @memcpy(result.bytes[0..bytes.len], bytes);
        result.len = @intCast(bytes.len);
        return result;
    }

    pub fn slice(self: *const InlineText) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: InlineText, b: InlineText) bool {
        return std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }
};

pub const CellKind = union(enum) { empty, grapheme: InlineText, wide_head: InlineText, wide_continuation };
pub const Cell = struct {
    kind: CellKind = .empty,
    style: Style = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return kindEql(a.kind, b.kind) and a.style.eql(b.style);
    }
    pub fn scalar(ch: u21, style: Style) Cell {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(ch, &bytes) catch blk: {
            bytes[0] = '?';
            break :blk 1;
        };
        return textCell(bytes[0..len], style);
    }
    pub fn textCell(bytes: []const u8, style: Style) Cell {
        return .{ .kind = .{ .grapheme = InlineText.from(bytes) }, .style = style };
    }
    pub fn wideHead(bytes: []const u8, style: Style) Cell {
        return .{ .kind = .{ .wide_head = InlineText.from(bytes) }, .style = style };
    }
    pub fn empty(style: Style) Cell {
        return .{ .kind = .empty, .style = style };
    }
    pub fn renderText(self: Cell) ?InlineText {
        return switch (self.kind) {
            .grapheme => |t| t,
            .wide_head => |t| t,
            else => null,
        };
    }
    pub fn renderScalar(self: Cell) ?u21 {
        const inline_text = self.renderText() orelse return null;
        return std.unicode.utf8Decode(inline_text.slice()) catch null;
    }
};
fn kindEql(a: CellKind, b: CellKind) bool {
    return switch (a) {
        .empty => b == .empty,
        .wide_continuation => b == .wide_continuation,
        .grapheme => |x| switch (b) {
            .grapheme => |y| x.eql(y),
            else => false,
        },
        .wide_head => |x| switch (b) {
            .wide_head => |y| x.eql(y),
            else => false,
        },
    };
}

pub const Error = error{ OutOfBounds, TooLarge };

pub const CellBuffer = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    max_cells: usize,
    cells: []Cell,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, max_cells: usize) !CellBuffer {
        const count = try checkedCount(width, height, max_cells);
        const cells = try allocator.alloc(Cell, count);
        @memset(cells, .{});
        return .{ .allocator = allocator, .width = width, .height = height, .max_cells = max_cells, .cells = cells };
    }
    pub fn deinit(self: *CellBuffer) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
    pub fn clear(self: *CellBuffer) void {
        @memset(self.cells, .{});
    }
    pub fn resize(self: *CellBuffer, width: u16, height: u16) !void {
        const count = try checkedCount(width, height, self.max_cells);
        const next = try self.allocator.alloc(Cell, count);
        @memset(next, .{});
        self.allocator.free(self.cells);
        self.cells = next;
        self.width = width;
        self.height = height;
    }
    pub fn set(self: *CellBuffer, x: u16, y: u16, cell: Cell) Error!void {
        const i = try self.index(x, y);
        self.clearPairedAt(i);
        self.cells[i] = cell;
    }
    pub fn get(self: CellBuffer, x: u16, y: u16) Error!Cell {
        return self.cells[try self.index(x, y)];
    }
    pub fn clearRow(self: *CellBuffer, y: u16) Error!void {
        if (y >= self.height) return error.OutOfBounds;
        var x: u16 = 0;
        while (x < self.width) : (x += 1) try self.set(x, y, .{});
    }
    pub fn clearRect(self: *CellBuffer, x: u16, y: u16, w: u16, h: u16) Error!void {
        try self.fillRect(x, y, w, h, .{});
    }
    pub fn fillRect(self: *CellBuffer, x: u16, y: u16, w: u16, h: u16, style: Style) Error!void {
        const x_end = @min(@as(usize, x) + w, self.width);
        const y_end = @min(@as(usize, y) + h, self.height);
        var yy: usize = y;
        while (yy < y_end) : (yy += 1) {
            var xx: usize = x;
            while (xx < x_end) : (xx += 1) try self.set(@intCast(xx), @intCast(yy), Cell.empty(style));
        }
    }
    pub fn writeText(self: *CellBuffer, x: u16, y: u16, bytes: []const u8, style: Style) Error!void {
        if (x >= self.width or y >= self.height) return error.OutOfBounds;
        var col = x;
        var i: usize = 0;
        while (i < bytes.len and col < self.width) {
            const grapheme = text.nextGrapheme(bytes[i..]);
            if (grapheme.end == 0) break;
            const grapheme_bytes = bytes[i..][grapheme.start..grapheme.end];
            i += grapheme.end;
            if (containsTerminalControl(grapheme_bytes)) {
                try self.set(col, y, Cell.scalar(text.replacement, style));
                col += 1;
                continue;
            }
            if (grapheme.width == 0) continue;
            if (grapheme.width == 2) {
                if (col + 1 >= self.width) break;
                try self.setWide(col, y, grapheme_bytes, style);
                col += 2;
            } else {
                try self.set(col, y, Cell.textCell(grapheme_bytes, style));
                col += 1;
            }
        }
    }
    fn setWide(self: *CellBuffer, x: u16, y: u16, bytes: []const u8, style: Style) Error!void {
        const head = try self.index(x, y);
        const tail = try self.index(x + 1, y);
        self.clearPairedAt(head);
        self.clearPairedAt(tail);
        self.cells[head] = Cell.wideHead(bytes, style);
        self.cells[tail] = .{ .kind = .wide_continuation, .style = style };
    }

    fn clearPairedAt(self: *CellBuffer, i: usize) void {
        const x = i % self.width;
        switch (self.cells[i].kind) {
            .wide_continuation => if (x > 0) {
                self.cells[i - 1] = .{};
            },
            .wide_head => if (x + 1 < self.width) {
                self.cells[i + 1] = .{};
            },
            else => {},
        }
    }
    fn index(self: CellBuffer, x: u16, y: u16) Error!usize {
        if (x >= self.width or y >= self.height) return error.OutOfBounds;
        return @as(usize, y) * self.width + x;
    }
};
fn containsTerminalControl(bytes: []const u8) bool {
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    var index: usize = 0;
    while (index < bytes.len) {
        const scalar = text.nextScalar(bytes[index..]);
        if (scalar.len == 0) return false;
        if (scalar.scalar < 0x20 or scalar.scalar == 0x7f or
            (scalar.scalar >= 0x80 and scalar.scalar <= 0x9f)) return true;
        index += scalar.len;
    }
    return false;
}

fn checkedCount(width: u16, height: u16, max_cells: usize) Error!usize {
    const count = @as(usize, width) * height;
    if (count > max_cells) return error.TooLarge;
    return count;
}

test "cell buffer replaces terminal controls instead of storing raw bytes" {
    var b = try CellBuffer.init(std.testing.allocator, 8, 1, 8);
    defer b.deinit();

    try b.writeText(0, 0, "a\x1b[31m\r", .{});
    try std.testing.expectEqual(@as(u21, 'a'), (try b.get(0, 0)).renderScalar().?);
    try std.testing.expectEqual(text.replacement, (try b.get(1, 0)).renderScalar().?);
    try std.testing.expectEqual(@as(u21, '['), (try b.get(2, 0)).renderScalar().?);
    try std.testing.expectEqual(@as(u21, '3'), (try b.get(3, 0)).renderScalar().?);
    try std.testing.expectEqual(@as(u21, '1'), (try b.get(4, 0)).renderScalar().?);
    try std.testing.expectEqual(@as(u21, 'm'), (try b.get(5, 0)).renderScalar().?);
    try std.testing.expectEqual(text.replacement, (try b.get(6, 0)).renderScalar().?);
}

test "cell buffer writes text wide overwrite and preserves on failed resize" {
    var b = try CellBuffer.init(std.testing.allocator, 3, 1, 3);
    defer b.deinit();
    try b.writeText(0, 0, "a\xe4\xb8\xad", .{});
    try std.testing.expectEqual(@as(u21, 'a'), (try b.get(0, 0)).renderScalar().?);
    try std.testing.expect((try b.get(1, 0)).kind == .wide_head);
    try std.testing.expect((try b.get(2, 0)).kind == .wide_continuation);
    try b.set(2, 0, Cell.scalar('x', .{}));
    try std.testing.expect((try b.get(1, 0)).kind == .empty);
    const old = b.cells.ptr;
    try std.testing.expectError(error.TooLarge, b.resize(4, 1));
    try std.testing.expectEqual(old, b.cells.ptr);
}

test "cell buffer wide pairs do not cross rows" {
    var b = try CellBuffer.init(std.testing.allocator, 2, 2, 4);
    defer b.deinit();
    try b.writeText(0, 0, "中", .{});
    try b.set(0, 1, Cell.scalar('x', .{}));
    try std.testing.expect((try b.get(1, 0)).kind == .wide_continuation);
    try b.set(1, 0, Cell.scalar('y', .{}));
    try std.testing.expect((try b.get(0, 1)).kind == .grapheme);
}

test "cell buffer keeps grapheme bytes in one cell" {
    var b = try CellBuffer.init(std.testing.allocator, 4, 1, 4);
    defer b.deinit();

    try b.writeText(0, 0, "o\u{0300}👩🏽‍🚀", .{});
    const first = try b.get(0, 0);
    const second = try b.get(1, 0);
    const first_text = first.renderText().?;
    const second_text = second.renderText().?;
    try std.testing.expectEqualStrings("o\u{0300}", first_text.slice());
    try std.testing.expectEqualStrings("👩🏽‍🚀", second_text.slice());
    try std.testing.expect((try b.get(2, 0)).kind == .wide_continuation);
}

test "cell buffer wide write clears old pairs at both target columns" {
    var b = try CellBuffer.init(std.testing.allocator, 4, 1, 4);
    defer b.deinit();

    try b.writeText(1, 0, "中", .{});
    try b.writeText(0, 0, "界", .{});

    try std.testing.expect((try b.get(0, 0)).kind == .wide_head);
    try std.testing.expect((try b.get(1, 0)).kind == .wide_continuation);
    try std.testing.expect((try b.get(2, 0)).kind == .empty);
}

test "cell buffer overwrite clears wide and grapheme cells" {
    var b = try CellBuffer.init(std.testing.allocator, 4, 1, 4);
    defer b.deinit();

    try b.writeText(0, 0, "中a", .{});
    try b.writeText(1, 0, "o\u{0300}", .{});
    try std.testing.expect((try b.get(0, 0)).kind == .empty);
    const middle = (try b.get(1, 0)).renderText().?;
    try std.testing.expectEqualStrings("o\u{0300}", middle.slice());
    try std.testing.expectEqual(@as(u21, 'a'), (try b.get(2, 0)).renderScalar().?);

    try b.writeText(1, 0, "界", .{});
    try std.testing.expect((try b.get(0, 0)).kind == .empty);
    try std.testing.expect((try b.get(1, 0)).kind == .wide_head);
    try std.testing.expect((try b.get(2, 0)).kind == .wide_continuation);
}

test "cell buffer clear rect clears intersecting wide pairs" {
    var b = try CellBuffer.init(std.testing.allocator, 4, 1, 4);
    defer b.deinit();

    try b.writeText(0, 0, "a中b", .{});
    try b.clearRect(2, 0, 1, 1);
    try std.testing.expectEqual(@as(u21, 'a'), (try b.get(0, 0)).renderScalar().?);
    try std.testing.expect((try b.get(1, 0)).kind == .empty);
    try std.testing.expect((try b.get(2, 0)).kind == .empty);
    try std.testing.expectEqual(@as(u21, 'b'), (try b.get(3, 0)).renderScalar().?);
}
