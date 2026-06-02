const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn empty() Rect { return .{ .x = 0, .y = 0, .width = 0, .height = 0 }; }
    pub fn isEmpty(self: Rect) bool { return self.width == 0 or self.height == 0; }
    pub fn contains(self: Rect, x: u16, y: u16) bool {
        const x2 = @as(u32, self.x) + self.width;
        const y2 = @as(u32, self.y) + self.height;
        return x >= self.x and y >= self.y and @as(u32, x) < x2 and @as(u32, y) < y2;
    }
    pub fn clip(a: Rect, b: Rect) Rect {
        const ax2 = @as(u32, a.x) + a.width;
        const ay2 = @as(u32, a.y) + a.height;
        const bx2 = @as(u32, b.x) + b.width;
        const by2 = @as(u32, b.y) + b.height;
        const x1 = @max(a.x, b.x);
        const y1 = @max(a.y, b.y);
        const x2 = @min(ax2, bx2);
        const y2 = @min(ay2, by2);
        if (x2 <= x1 or y2 <= y1) return empty();
        return .{ .x = x1, .y = y1, .width = @intCast(x2 - x1), .height = @intCast(y2 - y1) };
    }
};

test "rect clipping and containment" {
    const r: Rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 };
    try std.testing.expect(r.contains(1, 2));
    try std.testing.expect(!r.contains(4, 2));
    const clipped = r.clip(.{ .x = 2, .y = 3, .width = 9, .height = 2 });
    const expected: Rect = .{ .x = 2, .y = 3, .width = 2, .height = 2 };
    try std.testing.expectEqual(expected, clipped);
    try std.testing.expect(r.clip(.{ .x = 9, .y = 9, .width = 1, .height = 1 }).isEmpty());
}
