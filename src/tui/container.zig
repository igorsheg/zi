const std = @import("std");
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const component_mod = @import("component.zig");
const keys_mod = @import("terminal/keys.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Key = keys_mod.Key;

/// Vertical stack layout container.
///
/// Children are laid out top-to-bottom. One child can be designated as
/// "flex" (takes remaining vertical space after fixed children are measured).
/// One child can be designated as "focused" (receives input and provides cursor).
///
/// Children are borrowed — Container does not own their lifetimes.
pub const ChildRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Container = struct {
    children: std.ArrayListUnmanaged(Component) = .empty,
    /// Index of the child that fills remaining vertical space.
    flex_child_index: ?usize = null,
    /// Index of the child that receives input and provides cursor state.
    focused_child_index: ?usize = null,
    allocator: std.mem.Allocator,
    /// Cached from last render() call, used by cursorState() for y-offset.
    last_render_width: u32 = 80,
    last_render_height: u32 = 24,

    pub fn init(allocator: std.mem.Allocator) Container {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Container) void {
        self.children.deinit(self.allocator);
    }

    pub fn addChild(self: *Container, child: Component) void {
        self.children.append(self.allocator, child) catch return;
    }

    pub fn removeChildAt(self: *Container, index: usize) void {
        if (index >= self.children.items.len) return;
        _ = self.children.orderedRemove(index);
        // Adjust flex/focus indices
        if (self.flex_child_index) |fi| {
            if (fi == index) {
                self.flex_child_index = null;
            } else if (fi > index) {
                self.flex_child_index = fi - 1;
            }
        }
        if (self.focused_child_index) |fi| {
            if (fi == index) {
                self.focused_child_index = null;
            } else if (fi > index) {
                self.focused_child_index = fi - 1;
            }
        }
    }

    pub fn childCount(self: *const Container) usize {
        return self.children.items.len;
    }

    pub fn clear(self: *Container) void {
        self.children.items.len = 0;
        self.flex_child_index = null;
        self.focused_child_index = null;
    }

    pub fn childRect(self: *const Container, index: usize) ?ChildRect {
        if (index >= self.children.items.len) return null;
        const w = self.last_render_width;
        const h = self.last_render_height;
        if (w == 0 or h == 0) return null;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (self.flex_child_index != null and i == self.flex_child_index.?) continue;
            fixed_total += child.measure(w).preferred_height;
        }
        const flex_height = if (self.flex_child_index != null)
            (if (h > fixed_total) h - fixed_total else 0)
        else
            @as(u32, 0);

        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (y >= h) break;
            const child_h = if (self.flex_child_index != null and i == self.flex_child_index.?)
                flex_height
            else
                child.measure(w).preferred_height;
            if (child_h == 0) continue;
            const clamped_h = @min(child_h, h - y);
            if (i == index) {
                return .{ .x = 0, .y = y, .width = w, .height = clamped_h };
            }
            y += clamped_h;
        }
        return null;
    }

    // ── Component interface ────────────────────────────────────────

    pub fn render(self: *Container, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0 or self.children.items.len == 0) return;
        self.last_render_width = w;
        self.last_render_height = h;

        // Measure fixed children, compute flex child height
        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (self.flex_child_index != null and i == self.flex_child_index.?) continue;
            fixed_total += child.measure(w).preferred_height;
        }

        const flex_height = if (self.flex_child_index != null)
            (if (h > fixed_total) h - fixed_total else 0)
        else
            @as(u32, 0);

        // Render children into sub-regions
        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (y >= h) break;
            const child_h = if (self.flex_child_index != null and i == self.flex_child_index.?)
                flex_height
            else
                child.measure(w).preferred_height;

            if (child_h == 0) continue;
            const clamped_h = @min(child_h, h - y);
            const child_region = region.sub(0, y, w, clamped_h);
            child.render(child_region);
            y += clamped_h;
        }
    }

    pub fn measure(self: *Container, width: u32) Measurement {
        var total: u32 = 0;
        for (self.children.items) |child| {
            total += child.measure(width).preferred_height;
        }
        return .{ .min_height = if (self.children.items.len > 0) 1 else 0, .preferred_height = total };
    }

    pub fn handleInput(self: *Container, key: Key) bool {
        if (self.focused_child_index) |fi| {
            if (fi < self.children.items.len) {
                return self.children.items[fi].handleInput(key);
            }
        }
        return false;
    }

    pub fn cursorState(self: *Container) ?CursorState {
        const fi = self.focused_child_index orelse return null;
        if (fi >= self.children.items.len) return null;
        const cs = self.children.items[fi].cursorState() orelse return null;

        // Translate cursor y by the focused child's y-offset in the layout
        const w: u32 = 0; // Need width for measurement — use 0 as sentinel
        _ = w;
        // We need to compute the y-offset of the focused child.
        // This requires knowing the render width, which we don't have here.
        // Store it from the last render call.
        return .{
            .x = cs.x,
            .y = cs.y + self.computeChildYOffset(fi),
            .style = cs.style,
        };
    }

    pub fn invalidate(self: *Container) void {
        for (self.children.items) |child| {
            child.invalidate();
        }
    }

    pub fn nextAnimationDeadline(self: *Container, now_ns: i128) ?i128 {
        const w = self.last_render_width;
        const h = self.last_render_height;
        if (w == 0 or h == 0 or self.children.items.len == 0) return null;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (self.flex_child_index != null and i == self.flex_child_index.?) continue;
            fixed_total += child.measure(w).preferred_height;
        }
        const flex_height = if (self.flex_child_index != null)
            (if (h > fixed_total) h - fixed_total else 0)
        else
            @as(u32, 0);

        var next_deadline: ?i128 = null;
        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (y >= h) break;
            const child_h = if (self.flex_child_index != null and i == self.flex_child_index.?)
                flex_height
            else
                child.measure(w).preferred_height;
            const clamped_h = @min(child_h, h - y);
            if (clamped_h > 0) {
                if (child.nextAnimationDeadline(now_ns)) |deadline| {
                    next_deadline = if (next_deadline) |cur| @min(cur, deadline) else deadline;
                }
                y += clamped_h;
            }
        }
        return next_deadline;
    }

    pub fn tickAnimation(self: *Container, now_ns: i128) bool {
        const w = self.last_render_width;
        const h = self.last_render_height;
        if (w == 0 or h == 0 or self.children.items.len == 0) return false;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (self.flex_child_index != null and i == self.flex_child_index.?) continue;
            fixed_total += child.measure(w).preferred_height;
        }
        const flex_height = if (self.flex_child_index != null)
            (if (h > fixed_total) h - fixed_total else 0)
        else
            @as(u32, 0);

        var changed = false;
        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (y >= h) break;
            const child_h = if (self.flex_child_index != null and i == self.flex_child_index.?)
                flex_height
            else
                child.measure(w).preferred_height;
            const clamped_h = @min(child_h, h - y);
            if (clamped_h > 0) {
                changed = child.tickAnimation(now_ns) or changed;
                y += clamped_h;
            }
        }
        return changed;
    }

    pub fn component(self: *Container) Component {
        return Component.init(Container, self);
    }

    // ── Internal ───────────────────────────────────────────────────

    /// Compute the y-offset of a child at the given index,
    /// replicating the layout logic from render() using cached dimensions.
    fn computeChildYOffset(self: *const Container, target_idx: usize) u32 {
        const w = self.last_render_width;
        const h = self.last_render_height;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (self.flex_child_index != null and i == self.flex_child_index.?) continue;
            fixed_total += child.measure(w).preferred_height;
        }
        const flex_height = if (self.flex_child_index != null)
            (if (h > fixed_total) h - fixed_total else 0)
        else
            @as(u32, 0);

        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (i == target_idx) return y;
            const child_h = if (self.flex_child_index != null and i == self.flex_child_index.?)
                flex_height
            else
                child.measure(w).preferred_height;
            y += child_h;
        }
        return y;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

const TestComponent = struct {
    height: u32,
    rendered_count: u32 = 0,
    input_count: u32 = 0,
    consumes_input: bool = false,
    cursor: ?CursorState = null,
    last_region: ?ChildRect = null,

    pub fn render(self: *TestComponent, region: Region) void {
        self.rendered_count += 1;
        self.last_region = .{ .x = region.x, .y = region.y, .width = region.width, .height = region.height };
    }

    pub fn measure(self: *TestComponent, width: u32) Measurement {
        _ = width;
        return .{ .min_height = 1, .preferred_height = self.height };
    }

    pub fn handleInput(self: *TestComponent, _: Key) bool {
        self.input_count += 1;
        return self.consumes_input;
    }

    pub fn cursorState(self: *TestComponent) ?CursorState {
        return self.cursor;
    }

    pub fn component(self: *TestComponent) Component {
        return Component.init(TestComponent, self);
    }
};

const AnimatedComp = struct {
    height: u32 = 1,
    deadline_ns: ?i128 = null,
    ticked: bool = false,

    pub fn render(_: *@This(), _: Region) void {}
    pub fn measure(self: *@This(), _: u32) Measurement {
        return .{ .min_height = 1, .preferred_height = self.height };
    }
    pub fn nextAnimationDeadline(self: *@This(), _: i128) ?i128 {
        return self.deadline_ns;
    }
    pub fn tickAnimation(self: *@This(), _: i128) bool {
        self.ticked = true;
        return true;
    }
    pub fn component(self: *@This()) Component {
        return Component.init(@This(), self);
    }
};

test "Container stacks fixed children and measures their preferred height" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    var a = TestComponent{ .height = 2 };
    var b = TestComponent{ .height = 3 };
    container.addChild(a.component());
    container.addChild(b.component());

    var buf = try Buffer.init(testing.allocator, 10, 10);
    defer buf.deinit();
    container.render(buf.region());

    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 0, .width = 10, .height = 2 }, a.last_region.?);
    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 2, .width = 10, .height = 3 }, b.last_region.?);

    const m = container.measure(10);
    try testing.expectEqual(@as(u32, 1), m.min_height);
    try testing.expectEqual(@as(u32, 5), m.preferred_height);
}

test "Container gives flex child remaining height and reports rendered geometry" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    var header = TestComponent{ .height = 2 };
    var body = TestComponent{ .height = 0 };
    var footer = TestComponent{ .height = 1 };
    container.addChild(header.component());
    container.addChild(body.component());
    container.addChild(footer.component());
    container.flex_child_index = 1;

    var buf = try Buffer.init(testing.allocator, 10, 8);
    defer buf.deinit();
    container.render(buf.region());

    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 0, .width = 10, .height = 2 }, header.last_region.?);
    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 2, .width = 10, .height = 5 }, body.last_region.?);
    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 7, .width = 10, .height = 1 }, footer.last_region.?);

    try testing.expectEqualDeep(header.last_region.?, container.childRect(0).?);
    try testing.expectEqualDeep(body.last_region.?, container.childRect(1).?);
    try testing.expectEqualDeep(footer.last_region.?, container.childRect(2).?);
}

test "Container clips rendering to available height" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    var visible = TestComponent{ .height = 2 };
    var clipped = TestComponent{ .height = 2 };
    var hidden = TestComponent{ .height = 1 };
    container.addChild(visible.component());
    container.addChild(clipped.component());
    container.addChild(hidden.component());

    var buf = try Buffer.init(testing.allocator, 10, 3);
    defer buf.deinit();
    container.render(buf.region());

    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 0, .width = 10, .height = 2 }, visible.last_region.?);
    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 2, .width = 10, .height = 1 }, clipped.last_region.?);
    try testing.expectEqual(@as(u32, 0), hidden.rendered_count);
    try testing.expectEqual(@as(?ChildRect, null), container.childRect(2));
}

test "Container delegates input and cursor state to focused child" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    var top = TestComponent{ .height = 2 };
    var focused = TestComponent{
        .height = 1,
        .consumes_input = true,
        .cursor = .{ .x = 4, .y = 1, .style = .bar },
    };
    container.addChild(top.component());
    container.addChild(focused.component());

    try testing.expect(!container.handleInput(.{ .code = .char, .char = 'a' }));
    try testing.expectEqual(@as(u32, 0), top.input_count);
    try testing.expectEqual(@as(u32, 0), focused.input_count);

    container.focused_child_index = 1;
    try testing.expect(container.handleInput(.{ .code = .char, .char = 'b' }));
    try testing.expectEqual(@as(u32, 0), top.input_count);
    try testing.expectEqual(@as(u32, 1), focused.input_count);

    var buf = try Buffer.init(testing.allocator, 10, 5);
    defer buf.deinit();
    container.render(buf.region());

    try testing.expectEqualDeep(CursorState{ .x = 4, .y = 3, .style = .bar }, container.cursorState().?);
}

test "Container aggregates animation only for rendered children" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    var visible_slow = AnimatedComp{ .height = 1, .deadline_ns = 50 };
    var visible_fast = AnimatedComp{ .height = 1, .deadline_ns = 10 };
    var clipped = AnimatedComp{ .height = 1, .deadline_ns = 5 };
    container.addChild(visible_slow.component());
    container.addChild(visible_fast.component());
    container.addChild(clipped.component());

    var buf = try Buffer.init(testing.allocator, 10, 2);
    defer buf.deinit();
    container.render(buf.region());

    try testing.expectEqual(@as(?i128, 10), container.nextAnimationDeadline(0));
    try testing.expect(container.tickAnimation(10));
    try testing.expect(visible_slow.ticked);
    try testing.expect(visible_fast.ticked);
    try testing.expect(!clipped.ticked);
}
