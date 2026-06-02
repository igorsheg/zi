const std = @import("std");
const Style = @import("../primitive/style.zig").Style;

pub const Cell = struct { ch: u21 = ' ', style: Style = .{} };
pub const Error = error{OutOfBounds, TooLarge};

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
    pub fn deinit(self: *CellBuffer) void { self.allocator.free(self.cells); self.* = undefined; }
    pub fn clear(self: *CellBuffer) void { @memset(self.cells, .{}); }
    pub fn resize(self: *CellBuffer, width: u16, height: u16) !void {
        const count = try checkedCount(width, height, self.max_cells);
        const next = try self.allocator.alloc(Cell, count);
        @memset(next, .{});
        self.allocator.free(self.cells);
        self.cells = next; self.width = width; self.height = height;
    }
    pub fn set(self: *CellBuffer, x: u16, y: u16, cell: Cell) Error!void { self.cells[try self.index(x, y)] = cell; }
    pub fn get(self: CellBuffer, x: u16, y: u16) Error!Cell { return self.cells[try self.index(x, y)]; }
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

test "cell buffer bounds clear resize" {
    var b = try CellBuffer.init(std.testing.allocator, 2, 2, 4);
    defer b.deinit();
    try b.set(1, 1, .{ .ch = 'x' });
    try std.testing.expectEqual(@as(u21, 'x'), (try b.get(1, 1)).ch);
    try std.testing.expectError(error.OutOfBounds, b.set(2, 0, .{}));
    b.clear();
    try std.testing.expectEqual(@as(u21, ' '), (try b.get(1, 1)).ch);
    try std.testing.expectError(error.TooLarge, b.resize(3, 3));
}
