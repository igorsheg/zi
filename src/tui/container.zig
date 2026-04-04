const std = @import("std");
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const component_mod = @import("component.zig");
const keys_mod = @import("keys.zig");

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
    rendered: bool = false,
    label: u8 = 'X',

    pub fn render(self: *TestComponent, region: Region) void {
        self.rendered = true;
        // Write label on first row to verify rendering
        if (region.height > 0 and region.width > 0) {
            region.set(0, 0, .{ .grapheme = .{ .codepoint = @as(u21, self.label) } });
        }
    }

    pub fn measure(self: *TestComponent, width: u32) Measurement {
        _ = width;
        return .{ .min_height = 1, .preferred_height = self.height };
    }

    pub fn component(self: *TestComponent) Component {
        return Component.init(TestComponent, self);
    }
};

test "Container lays out children vertically" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    var a = TestComponent{ .height = 2, .label = 'A' };
    var b = TestComponent{ .height = 3, .label = 'B' };
    container.addChild(a.component());
    container.addChild(b.component());

    var buf = try Buffer.init(testing.allocator, 10, 10);
    defer buf.deinit();
    container.render(buf.region());

    // A renders at row 0
    try testing.expectEqual(@as(u21, 'A'), buf.get(0, 0).grapheme.codepoint);
    // B renders at row 2 (after A's height of 2)
    try testing.expectEqual(@as(u21, 'B'), buf.get(0, 2).grapheme.codepoint);

    const m = container.measure(10);
    try testing.expectEqual(@as(u32, 5), m.preferred_height);
}

test "Container flex child fills remaining space" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    var header = TestComponent{ .height = 1, .label = 'H' };
    var content = TestComponent{ .height = 0, .label = 'C' }; // will be flex
    var footer = TestComponent{ .height = 1, .label = 'F' };

    container.addChild(header.component());
    container.addChild(content.component());
    container.addChild(footer.component());
    container.flex_child_index = 1; // content is flex

    var buf = try Buffer.init(testing.allocator, 10, 10);
    defer buf.deinit();
    container.render(buf.region());

    // Header at row 0
    try testing.expectEqual(@as(u21, 'H'), buf.get(0, 0).grapheme.codepoint);
    // Content at row 1, gets 10 - 1 - 1 = 8 rows
    try testing.expectEqual(@as(u21, 'C'), buf.get(0, 1).grapheme.codepoint);
    // Footer at row 9 (1 + 8 = 9)
    try testing.expectEqual(@as(u21, 'F'), buf.get(0, 9).grapheme.codepoint);
}

test "Container delegates input to focused child" {
    var container = Container.init(testing.allocator);
    defer container.deinit();

    // No focused child — input not consumed
    try testing.expect(!container.handleInput(.{ .code = .char, .char = 'a' }));

    // With a test component that doesn't handle input — still returns false
    var a = TestComponent{ .height = 1 };
    container.addChild(a.component());
    container.focused_child_index = 0;
    try testing.expect(!container.handleInput(.{ .code = .char, .char = 'a' }));
}
