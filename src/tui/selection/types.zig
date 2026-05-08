const std = @import("std");

pub const SelectableId = enum(u32) { _ };

pub const Point = struct {
    x: i32,
    y: i32,

    pub fn sub(self: Point, other: Point) Point {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn origin(self: Rect) Point {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn contains(self: Rect, point: Point) bool {
        if (self.width == 0 or self.height == 0) return false;
        const right = self.x + @as(i32, @intCast(self.width));
        const bottom = self.y + @as(i32, @intCast(self.height));
        return point.x >= self.x and point.x < right and point.y >= self.y and point.y < bottom;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        if (self.width == 0 or self.height == 0 or other.width == 0 or other.height == 0) return false;
        const a_right = self.x + @as(i32, @intCast(self.width));
        const a_bottom = self.y + @as(i32, @intCast(self.height));
        const b_right = other.x + @as(i32, @intCast(other.width));
        const b_bottom = other.y + @as(i32, @intCast(other.height));
        return self.x < b_right and a_right > other.x and self.y < b_bottom and a_bottom > other.y;
    }
};

pub const GlobalSelection = struct {
    anchor: Point,
    focus: Point,
    is_start: bool = false,
    is_active: bool = true,

    pub fn bounds(self: GlobalSelection) Rect {
        const min_x = @min(self.anchor.x, self.focus.x);
        const min_y = @min(self.anchor.y, self.focus.y);
        const max_x = @max(self.anchor.x, self.focus.x);
        const max_y = @max(self.anchor.y, self.focus.y);
        return .{
            .x = min_x,
            .y = min_y,
            .width = @intCast(max_x - min_x + 1),
            .height = @intCast(max_y - min_y + 1),
        };
    }
};
