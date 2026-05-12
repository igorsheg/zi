const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("surface.zig");
const view_mod = @import("view.zig");
const keys_mod = @import("../terminal/keys.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Component = view_mod.Component;
const Measurement = view_mod.Measurement;
const CursorState = view_mod.CursorState;
const Key = keys_mod.Key;

pub const ChildRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Height = union(enum) {
    intrinsic,
    points: u32,
    flex: u32,
};

pub const Style = struct {
    height: Height = .intrinsic,
    visible: bool = true,
};

pub const Child = struct {
    view: ?Component = null,
    style: Style = .{},
    rect: ChildRect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

pub const Stack = struct {
    children: std.ArrayListUnmanaged(Child) = .empty,
    allocator: std.mem.Allocator,

    last_render_width: u32 = 80,
    last_render_height: u32 = 24,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Stack) void {
        self.children.deinit(self.allocator);
    }

    pub fn add(self: *Stack, child: Component, style: Style) void {
        self.children.append(self.allocator, .{ .view = child, .style = style }) catch return;
    }

    pub fn addSpace(self: *Stack, style: Style) void {
        self.children.append(self.allocator, .{ .view = null, .style = style }) catch return;
    }

    pub fn setVisible(self: *Stack, target: Component, visible: bool) void {
        for (self.children.items) |*child| {
            const view = child.view orelse continue;
            if (Component.eql(view, target)) {
                child.style.visible = visible;
                return;
            }
        }
    }

    pub fn removeChildAt(self: *Stack, index: usize) void {
        if (index >= self.children.items.len) return;
        _ = self.children.orderedRemove(index);
    }

    pub fn childCount(self: *const Stack) usize {
        return self.children.items.len;
    }

    pub fn clear(self: *Stack) void {
        self.children.items.len = 0;
    }

    pub fn childRect(self: *const Stack, index: usize) ?ChildRect {
        if (index >= self.children.items.len) return null;
        const w = self.last_render_width;
        const h = self.last_render_height;
        if (w == 0 or h == 0) return null;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible or self.isFlexChild(child, i)) continue;
            fixed_total += self.childDesiredHeight(child, w);
        }
        const flex_height = if (self.hasFlexChild()) (if (h > fixed_total) h - fixed_total else 0) else @as(u32, 0);

        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible) continue;
            if (y >= h) break;
            const child_h = if (self.isFlexChild(child, i))
                flex_height
            else
                self.childDesiredHeight(child, w);
            if (child_h == 0) continue;
            const clamped_h = @min(child_h, h - y);
            if (i == index) {
                return .{ .x = 0, .y = y, .width = w, .height = clamped_h };
            }
            y += clamped_h;
        }
        return null;
    }

    pub fn render(self: *Stack, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0 or self.children.items.len == 0) return;
        self.last_render_width = w;
        self.last_render_height = h;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible or self.isFlexChild(child, i)) continue;
            fixed_total += self.childDesiredHeight(child, w);
        }

        const flex_height = if (self.hasFlexChild()) (if (h > fixed_total) h - fixed_total else 0) else @as(u32, 0);

        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible) continue;
            if (y >= h) break;
            const child_h = if (self.isFlexChild(child, i))
                flex_height
            else
                self.childDesiredHeight(child, w);

            if (child_h == 0) continue;
            const clamped_h = @min(child_h, h - y);
            const child_region = region.sub(0, y, w, clamped_h);
            if (child.view) |view| view.render(child_region);
            y += clamped_h;
        }
    }

    pub fn measure(self: *Stack, width: u32) Measurement {
        var total: u32 = 0;
        for (self.children.items) |child| {
            total += self.childDesiredHeight(child, width);
        }
        return .{ .min_height = if (self.children.items.len > 0) 1 else 0, .preferred_height = total };
    }

    pub fn handleInput(self: *Stack, key: Key) bool {
        _ = self;
        _ = key;
        return false;
    }

    pub fn cursorState(self: *Stack) ?CursorState {
        _ = self;
        return null;
    }

    pub fn cursorFor(self: *Stack, focused: Component) ?CursorState {
        for (self.children.items, 0..) |child, i| {
            const view = child.view orelse continue;
            if (!Component.eql(view, focused)) continue;
            const cs = view.cursorState() orelse return null;
            return .{
                .x = cs.x,
                .y = cs.y + self.computeChildYOffset(i),
                .style = cs.style,
            };
        }
        return null;
    }

    pub fn invalidate(self: *Stack) void {
        for (self.children.items) |child| {
            if (child.view) |view| view.invalidate();
        }
    }

    pub fn nextAnimationDeadline(self: *Stack, now_ns: i128) ?i128 {
        const w = self.last_render_width;
        const h = self.last_render_height;
        if (w == 0 or h == 0 or self.children.items.len == 0) return null;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible or self.isFlexChild(child, i)) continue;
            fixed_total += self.childDesiredHeight(child, w);
        }
        const flex_height = if (self.hasFlexChild()) (if (h > fixed_total) h - fixed_total else 0) else @as(u32, 0);

        var next_deadline: ?i128 = null;
        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible) continue;
            if (y >= h) break;
            const child_h = if (self.isFlexChild(child, i))
                flex_height
            else
                self.childDesiredHeight(child, w);
            const clamped_h = @min(child_h, h - y);
            if (clamped_h > 0) {
                if (child.view) |view| {
                    if (view.nextAnimationDeadline(now_ns)) |deadline| {
                        next_deadline = if (next_deadline) |cur| @min(cur, deadline) else deadline;
                    }
                }
                y += clamped_h;
            }
        }
        return next_deadline;
    }

    pub fn tickAnimation(self: *Stack, now_ns: i128) bool {
        const w = self.last_render_width;
        const h = self.last_render_height;
        if (w == 0 or h == 0 or self.children.items.len == 0) return false;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible or self.isFlexChild(child, i)) continue;
            fixed_total += self.childDesiredHeight(child, w);
        }
        const flex_height = if (self.hasFlexChild()) (if (h > fixed_total) h - fixed_total else 0) else @as(u32, 0);

        var changed = false;
        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible) continue;
            if (y >= h) break;
            const child_h = if (self.isFlexChild(child, i))
                flex_height
            else
                self.childDesiredHeight(child, w);
            const clamped_h = @min(child_h, h - y);
            if (clamped_h > 0) {
                if (child.view) |view| {
                    changed = view.tickAnimation(now_ns) or changed;
                }
                y += clamped_h;
            }
        }
        return changed;
    }

    pub fn component(self: *Stack) Component {
        return Component.init(Stack, self);
    }

    pub fn isFlexChild(self: *const Stack, child: Child, index: usize) bool {
        _ = self;
        _ = index;
        return switch (child.style.height) {
            .flex => true,
            else => false,
        };
    }

    fn hasFlexChild(self: *const Stack) bool {
        for (self.children.items, 0..) |child, i| {
            if (child.style.visible and self.isFlexChild(child, i)) return true;
        }
        return false;
    }

    pub fn childDesiredHeight(self: *const Stack, child: Child, width: u32) u32 {
        _ = self;
        return switch (child.style.height) {
            .intrinsic => if (!child.style.visible) 0 else if (child.view) |view| view.measure(width).preferred_height else 0,
            .points => |h| if (child.style.visible) h else 0,
            .flex => 0,
        };
    }

    fn computeChildYOffset(self: *const Stack, target_idx: usize) u32 {
        const w = self.last_render_width;
        const h = self.last_render_height;

        var fixed_total: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (!child.style.visible or self.isFlexChild(child, i)) continue;
            fixed_total += self.childDesiredHeight(child, w);
        }
        const flex_height = if (self.hasFlexChild()) (if (h > fixed_total) h - fixed_total else 0) else @as(u32, 0);

        var y: u32 = 0;
        for (self.children.items, 0..) |child, i| {
            if (i == target_idx) return y;
            if (!child.style.visible) continue;
            const child_h = if (self.isFlexChild(child, i))
                flex_height
            else
                self.childDesiredHeight(child, w);
            y += child_h;
        }
        return y;
    }
};

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

    pub fn view(self: *TestComponent) Component {
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
    pub fn view(self: *@This()) Component {
        return Component.init(@This(), self);
    }
};

test "Stack gives flex child remaining height and reports rendered geometry" {
    var stack = Stack.init(testing.allocator);
    defer stack.deinit();

    var header = TestComponent{ .height = 2 };
    var body = TestComponent{ .height = 0 };
    var footer = TestComponent{ .height = 1 };
    stack.add(header.view(), .{});
    stack.add(body.view(), .{ .height = .{ .flex = 1 } });
    stack.add(footer.view(), .{});

    var buf = try Buffer.init(testing.allocator, 10, 8, .wcwidth);
    defer buf.deinit();
    stack.render(buf.region());

    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 0, .width = 10, .height = 2 }, header.last_region.?);
    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 2, .width = 10, .height = 5 }, body.last_region.?);
    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 7, .width = 10, .height = 1 }, footer.last_region.?);

    try testing.expectEqualDeep(header.last_region.?, stack.childRect(0).?);
    try testing.expectEqualDeep(body.last_region.?, stack.childRect(1).?);
    try testing.expectEqualDeep(footer.last_region.?, stack.childRect(2).?);
}

test "Stack clips rendering to available height" {
    var stack = Stack.init(testing.allocator);
    defer stack.deinit();

    var visible = TestComponent{ .height = 2 };
    var clipped = TestComponent{ .height = 2 };
    var hidden = TestComponent{ .height = 1 };
    stack.add(visible.view(), .{});
    stack.add(clipped.view(), .{});
    stack.add(hidden.view(), .{});

    var buf = try Buffer.init(testing.allocator, 10, 3, .wcwidth);
    defer buf.deinit();
    stack.render(buf.region());

    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 0, .width = 10, .height = 2 }, visible.last_region.?);
    try testing.expectEqualDeep(ChildRect{ .x = 0, .y = 2, .width = 10, .height = 1 }, clipped.last_region.?);
    try testing.expectEqual(@as(u32, 0), hidden.rendered_count);
    try testing.expectEqual(@as(?ChildRect, null), stack.childRect(2));
}

test "Stack resolves cursor for focused child identity" {
    var stack = Stack.init(testing.allocator);
    defer stack.deinit();

    var top = TestComponent{ .height = 2 };
    var focused = TestComponent{
        .height = 1,
        .consumes_input = true,
        .cursor = .{ .x = 4, .y = 1, .style = .bar },
    };
    stack.add(top.view(), .{});
    stack.add(focused.view(), .{});

    var buf = try Buffer.init(testing.allocator, 10, 5, .wcwidth);
    defer buf.deinit();
    stack.render(buf.region());

    try testing.expectEqualDeep(CursorState{ .x = 4, .y = 3, .style = .bar }, stack.cursorFor(focused.view()).?);
}
