const std = @import("std");
const selectable_mod = @import("selectable.zig");
const types = @import("types.zig");

pub const Selectable = selectable_mod.Selectable;
pub const SelectableId = types.SelectableId;
pub const Point = types.Point;
pub const Rect = types.Rect;

pub const SelectionRegistry = struct {
    items: std.ArrayListUnmanaged(Selectable) = .empty,

    pub fn deinit(self: *SelectionRegistry, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *SelectionRegistry) void {
        self.items.clearRetainingCapacity();
    }

    pub fn register(self: *SelectionRegistry, allocator: std.mem.Allocator, item: Selectable) !void {
        try self.items.append(allocator, item);
    }

    pub fn byId(self: *SelectionRegistry, id: SelectableId) ?Selectable {
        for (self.items.items) |item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn hitTest(self: *SelectionRegistry, point: Point) ?SelectableId {
        var idx = self.items.items.len;
        while (idx > 0) {
            idx -= 1;
            const item = self.items.items[idx];
            if (item.bounds().contains(point)) return item.id;
        }
        return null;
    }

    pub fn intersecting(self: *SelectionRegistry, allocator: std.mem.Allocator, rect: Rect, out: *std.ArrayListUnmanaged(SelectableId)) !void {
        out.clearRetainingCapacity();
        for (self.items.items) |item| {
            if (item.bounds().intersects(rect)) try out.append(allocator, item.id);
        }
    }

    pub fn sortReadingOrder(self: *SelectionRegistry, ids: []SelectableId) void {
        std.mem.sort(SelectableId, ids, self, lessReadingOrder);
    }

    fn lessReadingOrder(self: *SelectionRegistry, a: SelectableId, b: SelectableId) bool {
        const ar = if (self.byId(a)) |item| item.bounds() else return false;
        const br = if (self.byId(b)) |item| item.bounds() else return true;
        if (ar.y != br.y) return ar.y < br.y;
        return ar.x < br.x;
    }
};
