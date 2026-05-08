const std = @import("std");
const types = @import("types.zig");
const registry_mod = @import("registry.zig");

pub const SelectableId = types.SelectableId;
pub const Point = types.Point;
pub const Rect = types.Rect;
pub const GlobalSelection = types.GlobalSelection;
pub const SelectionRegistry = registry_mod.SelectionRegistry;

pub const SelectionController = struct {
    state: State = .inactive,
    selected: std.ArrayListUnmanaged(SelectableId) = .empty,
    touched: std.ArrayListUnmanaged(SelectableId) = .empty,
    scratch: std.ArrayListUnmanaged(SelectableId) = .empty,

    pub const State = union(enum) {
        inactive,
        dragging: ActiveSelection,
        complete: ActiveSelection,
    };

    pub const SelectionAnchor = struct {
        renderable_id: SelectableId,
        local: Point,
    };

    pub const ActiveSelection = struct {
        anchor: SelectionAnchor,
        focus: Point,
    };

    pub fn deinit(self: *SelectionController, allocator: std.mem.Allocator) void {
        self.selected.deinit(allocator);
        self.touched.deinit(allocator);
        self.scratch.deinit(allocator);
    }

    pub fn isActive(self: *const SelectionController) bool {
        return self.state != .inactive;
    }

    pub fn clear(self: *SelectionController, registry: *SelectionRegistry) void {
        for (self.touched.items) |id| {
            if (registry.byId(id)) |item| item.clearSelection();
        }
        self.selected.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();
        self.state = .inactive;
    }

    pub fn begin(self: *SelectionController, allocator: std.mem.Allocator, registry: *SelectionRegistry, point: Point) !bool {
        const id = registry.hitTest(point) orelse return false;
        const item = registry.byId(id) orelse return false;
        if (!item.shouldStartSelection(point)) return false;

        self.clear(registry);
        const b = item.bounds();
        self.state = .{ .dragging = .{
            .anchor = .{ .renderable_id = id, .local = point.sub(b.origin()) },
            .focus = point,
        } };
        try self.notify(allocator, registry, true);
        return true;
    }

    pub fn update(self: *SelectionController, allocator: std.mem.Allocator, registry: *SelectionRegistry, point: Point) !bool {
        switch (self.state) {
            .inactive, .complete => return false,
            .dragging => |*active| active.focus = point,
        }
        try self.notify(allocator, registry, false);
        return true;
    }

    pub fn finish(self: *SelectionController, allocator: std.mem.Allocator, registry: *SelectionRegistry, point: Point) !?[]u8 {
        switch (self.state) {
            .inactive, .complete => return null,
            .dragging => |*active| active.focus = point,
        }
        try self.notify(allocator, registry, false);
        switch (self.state) {
            .dragging => |active| self.state = .{ .complete = active },
            else => {},
        }
        return try self.selectedText(allocator, registry);
    }

    pub fn selectedText(self: *SelectionController, allocator: std.mem.Allocator, registry: *SelectionRegistry) !?[]u8 {
        if (self.selected.items.len == 0) return null;
        registry.sortReadingOrder(self.selected.items);

        var parts: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (parts.items) |part| allocator.free(part);
            parts.deinit(allocator);
        }

        for (self.selected.items) |id| {
            const item = registry.byId(id) orelse continue;
            const maybe_text = try item.selectedText(allocator);
            const text = maybe_text orelse continue;
            if (text.len == 0) {
                allocator.free(text);
                continue;
            }
            try parts.append(allocator, text);
        }
        if (parts.items.len == 0) return null;

        var total: usize = 0;
        for (parts.items) |part| total += part.len;
        total += parts.items.len - 1;

        var out = try allocator.alloc(u8, total);
        var off: usize = 0;
        for (parts.items, 0..) |part, i| {
            if (i != 0) {
                out[off] = '\n';
                off += 1;
            }
            @memcpy(out[off..][0..part.len], part);
            off += part.len;
        }
        return out;
    }

    fn notify(self: *SelectionController, allocator: std.mem.Allocator, registry: *SelectionRegistry, is_start: bool) !void {
        const active = switch (self.state) {
            .inactive => return,
            .dragging => |active| active,
            .complete => |active| active,
        };
        const anchor_item = registry.byId(active.anchor.renderable_id) orelse {
            self.clear(registry);
            return;
        };
        const anchor = anchor_item.bounds().origin().add(active.anchor.local);
        const selection = GlobalSelection{ .anchor = anchor, .focus = active.focus, .is_start = is_start, .is_active = true };

        try registry.intersecting(allocator, selection.bounds(), &self.scratch);

        for (self.touched.items) |old_id| {
            if (!containsId(self.scratch.items, old_id)) {
                if (registry.byId(old_id)) |item| _ = item.onSelectionChanged(null);
            }
        }

        self.selected.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
        for (self.scratch.items) |id| {
            const item = registry.byId(id) orelse continue;
            if (item.onSelectionChanged(selection)) try self.selected.append(allocator, id);
            try self.touched.append(allocator, id);
        }
    }
};

fn containsId(ids: []const SelectableId, id: SelectableId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}
