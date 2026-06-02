const std = @import("std");
const Style = @import("../primitive/style.zig").Style;
const text_width = @import("../primitive/text_width.zig");

pub const CellKind = union(enum) { empty, scalar: u21, wide_head: u21, wide_continuation };
pub const Cell = struct {
    kind: CellKind = .empty,
    style: Style = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return kindEql(a.kind, b.kind) and a.style.eql(b.style);
    }
    pub fn scalar(ch: u21, style: Style) Cell {
        return .{ .kind = .{ .scalar = ch }, .style = style };
    }
    pub fn wideHead(ch: u21, style: Style) Cell {
        return .{ .kind = .{ .wide_head = ch }, .style = style };
    }
    pub fn empty(style: Style) Cell {
        return .{ .kind = .empty, .style = style };
    }
    pub fn renderScalar(self: Cell) ?u21 {
        return switch (self.kind) {
            .scalar => |c| c,
            .wide_head => |c| c,
            else => null,
        };
    }
};
fn kindEql(a: CellKind, b: CellKind) bool {
    return switch (a) {
        .empty => b == .empty,
        .wide_continuation => b == .wide_continuation,
        .scalar => |x| switch (b) {
            .scalar => |y| x == y,
            else => false,
        },
        .wide_head => |x| switch (b) {
            .wide_head => |y| x == y,
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
        const x_end = @min(@as(usize, x) + w, self.width);
        const y_end = @min(@as(usize, y) + h, self.height);
        var yy: usize = y;
        while (yy < y_end) : (yy += 1) {
            var xx: usize = x;
            while (xx < x_end) : (xx += 1) try self.set(@intCast(xx), @intCast(yy), .{});
        }
    }
    pub fn writeText(self: *CellBuffer, x: u16, y: u16, bytes: []const u8, style: Style) Error!void {
        if (x >= self.width or y >= self.height) return error.OutOfBounds;
        var col = x;
        var i: usize = 0;
        while (i < bytes.len and col < self.width) {
            const decoded = text_width.nextScalar(bytes[i..]);
            i += decoded.len;
            const w = text_width.scalarWidth(decoded.scalar);
            if (w == 2) {
                if (col + 1 >= self.width) break;
                try self.setWide(col, y, decoded.scalar, style);
                col += 2;
            } else {
                try self.set(col, y, Cell.scalar(decoded.scalar, style));
                col += 1;
            }
        }
    }
    fn setWide(self: *CellBuffer, x: u16, y: u16, scalar_value: u21, style: Style) Error!void {
        const head = try self.index(x, y);
        const tail = try self.index(x + 1, y);
        self.clearPairedAt(head);
        self.clearPairedAt(tail);
        self.cells[head] = Cell.wideHead(scalar_value, style);
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
fn checkedCount(width: u16, height: u16, max_cells: usize) Error!usize {
    const count = @as(usize, width) * height;
    if (count > max_cells) return error.TooLarge;
    return count;
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
    try std.testing.expect((try b.get(0, 1)).kind == .scalar);
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
