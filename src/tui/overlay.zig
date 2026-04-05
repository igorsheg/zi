const std = @import("std");
const component_mod = @import("component.zig");
const buffer_mod = @import("buffer.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;

/// Anchor point for overlay positioning.
pub const OverlayAnchor = enum {
    center,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    top_center,
    bottom_center,
};

/// Overlay positioning and sizing options.
/// Matches pi-mono's OverlayOptions interface.
pub const OverlayOptions = struct {
    // Sizing
    width: ?u32 = null,
    width_percent: ?u8 = null, // 0-100
    min_width: ?u32 = null,
    max_height: ?u32 = null,
    max_height_percent: ?u8 = null,

    // Positioning
    anchor: OverlayAnchor = .center,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    row: ?u32 = null,
    col: ?u32 = null,

    // Margin from terminal edges
    margin_top: u32 = 0,
    margin_right: u32 = 0,
    margin_bottom: u32 = 0,
    margin_left: u32 = 0,

    /// If true, don't capture keyboard focus when shown.
    non_capturing: bool = false,
};

/// Internal overlay entry in the stack.
pub const OverlayEntry = struct {
    id: u64,
    component: Component,
    options: OverlayOptions,
    pre_focus: ?Component,
    hidden: bool = false,
    focus_order: u64,
};

/// Legacy handle — kept for tests that use OverlayManager directly.
/// Production code should use tui.OverlayHandle which is wired into focus.
pub const OverlayHandle = struct {
    id: u64,
    manager: *OverlayManager,

    pub fn hide(self: OverlayHandle) void {
        _ = self.manager.removeOverlay(self.id);
    }

    pub fn setHidden(self: OverlayHandle, hidden: bool) void {
        if (self.manager.findEntry(self.id)) |entry| {
            entry.hidden = hidden;
        }
    }

    pub fn isHidden(self: OverlayHandle) bool {
        if (self.manager.findEntry(self.id)) |entry| return entry.hidden;
        return true;
    }
};

/// Overlay stack manager. Lives on Interactive (composition root).
/// Handles overlay lifecycle, z-order, and rendering into cell buffer.
pub const OverlayManager = struct {
    stack: std.ArrayListUnmanaged(OverlayEntry) = .empty,
    next_id: u64 = 1,
    focus_order_counter: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OverlayManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OverlayManager) void {
        self.stack.deinit(self.allocator);
    }

    /// Show an overlay. Returns a legacy handle (for direct OverlayManager usage).
    /// `pre_focus` is the currently focused component (saved for restore).
    pub fn showOverlay(
        self: *OverlayManager,
        comp: Component,
        options: OverlayOptions,
        pre_focus: ?Component,
    ) OverlayHandle {
        const id = self.showOverlayReturnId(comp, options, pre_focus);
        return .{ .id = id, .manager = self };
    }

    /// Show an overlay and return the entry ID (for TUI-level handle construction).
    pub fn showOverlayReturnId(
        self: *OverlayManager,
        comp: Component,
        options: OverlayOptions,
        pre_focus: ?Component,
    ) u64 {
        self.focus_order_counter += 1;
        const id = self.next_id;
        self.next_id += 1;

        self.stack.append(self.allocator, .{
            .id = id,
            .component = comp,
            .options = options,
            .pre_focus = pre_focus,
            .focus_order = self.focus_order_counter,
        }) catch {};

        return id;
    }

    pub const HideResult = struct {
        pre_focus: ?Component = null,
    };

    /// Hide the topmost overlay. Returns pre_focus for the caller to restore.
    pub fn hideTopmost(self: *OverlayManager) HideResult {
        if (self.stack.items.len == 0) return .{};
        const entry = self.stack.pop();
        return .{ .pre_focus = if (entry) |e| e.pre_focus else null };
    }

    /// Remove a specific overlay by handle ID. Returns pre_focus if found.
    pub fn removeOverlay(self: *OverlayManager, id: u64) ?Component {
        for (self.stack.items, 0..) |entry, i| {
            if (entry.id == id) {
                _ = self.stack.orderedRemove(i);
                return entry.pre_focus;
            }
        }
        return null;
    }

    pub fn hasVisibleOverlays(self: *const OverlayManager) bool {
        for (self.stack.items) |entry| {
            if (!entry.hidden) return true;
        }
        return false;
    }

    /// Get the topmost visible capturing overlay's component (for focus).
    pub fn topmostCapturingComponent(self: *const OverlayManager) ?Component {
        var i: usize = self.stack.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.stack.items[i];
            if (!entry.hidden and !entry.options.non_capturing) {
                return entry.component;
            }
        }
        return null;
    }

    /// Render all visible overlays into the buffer region, sorted by focus_order
    /// (lower first = behind, higher = on top). Matches pi-mono's compositeOverlays
    /// which sorts visibleEntries by focusOrder before compositing.
    pub fn renderOverlays(self: *OverlayManager, region: Region) void {
        const term_w = region.width;
        const term_h = region.height;

        // Collect visible entries and sort by focus_order (ascending = back to front)
        var visible: [32]usize = undefined;
        var visible_count: usize = 0;
        for (self.stack.items, 0..) |*entry, i| {
            if (!entry.hidden and visible_count < visible.len) {
                visible[visible_count] = i;
                visible_count += 1;
            }
        }

        // Insertion sort by focus_order (overlay stacks are small)
        for (1..visible_count) |i| {
            const key = visible[i];
            const key_order = self.stack.items[key].focus_order;
            var j: usize = i;
            while (j > 0 and self.stack.items[visible[j - 1]].focus_order > key_order) {
                visible[j] = visible[j - 1];
                j -= 1;
            }
            visible[j] = key;
        }

        for (visible[0..visible_count]) |idx| {
            const entry = &self.stack.items[idx];
            const layout = resolveLayout(entry.options, entry.component, term_w, term_h);
            if (layout.width == 0 or layout.height == 0) continue;

            const overlay_region = region.sub(layout.col, layout.row, layout.width, layout.height);
            entry.component.render(overlay_region);
        }
    }

    /// Bump the focus_order for an overlay (brings to front).
    pub fn bumpFocusOrder(self: *OverlayManager, id: u64) void {
        if (self.findEntry(id)) |entry| {
            self.focus_order_counter += 1;
            entry.focus_order = self.focus_order_counter;
        }
    }

    pub fn findEntry(self: *OverlayManager, id: u64) ?*OverlayEntry {
        for (self.stack.items) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }
};

pub const ResolvedLayout = struct {
    row: u32,
    col: u32,
    width: u32,
    height: u32,
};

pub fn resolveLayout(options: OverlayOptions, comp: Component, term_w: u32, term_h: u32) ResolvedLayout {
    const margin_h = options.margin_left + options.margin_right;
    const margin_v = options.margin_top + options.margin_bottom;
    const avail_w = if (term_w > margin_h) term_w - margin_h else 1;
    const avail_h = if (term_h > margin_v) term_h - margin_v else 1;

    // Resolve width
    var width: u32 = if (options.width) |w| w else if (options.width_percent) |pct|
        @max(1, avail_w * pct / 100)
    else
        @min(80, avail_w);

    if (options.min_width) |mw| width = @max(width, mw);
    width = @min(width, avail_w);

    // Measure component height at resolved width
    var comp_h = comp.measure(width).preferred_height;

    // Apply max_height
    if (options.max_height) |mh| {
        comp_h = @min(comp_h, mh);
    } else if (options.max_height_percent) |pct| {
        comp_h = @min(comp_h, @max(1, avail_h * pct / 100));
    }
    comp_h = @min(comp_h, avail_h);

    // Resolve position
    var row: u32 = undefined;
    var col: u32 = undefined;

    if (options.row) |r| {
        row = @min(r, if (term_h > comp_h) term_h - comp_h else 0);
    } else if (options.col) |_| {
        row = options.margin_top;
    } else {
        // Anchor-based positioning
        switch (options.anchor) {
            .center => {
                row = options.margin_top + (if (avail_h > comp_h) (avail_h - comp_h) / 2 else 0);
                col = options.margin_left + (if (avail_w > width) (avail_w - width) / 2 else 0);
            },
            .top_left, .top_center => {
                row = options.margin_top;
                col = if (options.anchor == .top_center)
                    options.margin_left + (if (avail_w > width) (avail_w - width) / 2 else 0)
                else
                    options.margin_left;
            },
            .bottom_left, .bottom_center, .bottom_right => {
                row = options.margin_top + (if (avail_h > comp_h) avail_h - comp_h else 0);
                col = switch (options.anchor) {
                    .bottom_center => options.margin_left + (if (avail_w > width) (avail_w - width) / 2 else 0),
                    .bottom_right => options.margin_left + (if (avail_w > width) avail_w - width else 0),
                    else => options.margin_left,
                };
            },
            .top_right => {
                row = options.margin_top;
                col = options.margin_left + (if (avail_w > width) avail_w - width else 0);
            },
        }
    }

    if (options.col) |c| {
        col = @min(c, if (term_w > width) term_w - width else 0);
    }

    // Apply offsets
    const signed_row: i64 = @as(i64, @intCast(row)) + options.offset_y;
    const signed_col: i64 = @as(i64, @intCast(col)) + options.offset_x;
    row = @intCast(@max(0, @min(signed_row, @as(i64, @intCast(term_h -| comp_h)))));
    col = @intCast(@max(0, @min(signed_col, @as(i64, @intCast(term_w -| width)))));

    return .{ .row = row, .col = col, .width = width, .height = comp_h };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "OverlayManager show and hide topmost" {
    var mgr = OverlayManager.init(testing.allocator);
    defer mgr.deinit();

    // Create a dummy component for testing
    const DummyComp = struct {
        val: u8 = 0,
        pub fn render(_: *@This(), _: Region) void {}
        pub fn measure(_: *@This(), _: u32) Measurement {
            return .{ .min_height = 1, .preferred_height = 5 };
        }
        pub fn component(self: *@This()) Component {
            return Component.init(@This(), self);
        }
    };

    var d1 = DummyComp{};
    var d2 = DummyComp{};

    const h1 = mgr.showOverlay(d1.component(), .{}, null);
    _ = h1;
    _ = mgr.showOverlay(d2.component(), .{}, d1.component());

    try testing.expectEqual(@as(usize, 2), mgr.stack.items.len);
    try testing.expect(mgr.hasVisibleOverlays());

    // Hide topmost returns pre_focus of d2 (which is d1)
    const result = mgr.hideTopmost();
    try testing.expect(result.pre_focus != null);
    try testing.expect(Component.eql(result.pre_focus.?, d1.component()));
    try testing.expectEqual(@as(usize, 1), mgr.stack.items.len);
}

test "OverlayHandle hide removes specific overlay" {
    var mgr = OverlayManager.init(testing.allocator);
    defer mgr.deinit();

    const DummyComp = struct {
        pub fn render(_: *@This(), _: Region) void {}
        pub fn measure(_: *@This(), _: u32) Measurement {
            return .{ .min_height = 1, .preferred_height = 1 };
        }
        pub fn component(self: *@This()) Component {
            return Component.init(@This(), self);
        }
    };

    var d1 = DummyComp{};
    var d2 = DummyComp{};

    const h1 = mgr.showOverlay(d1.component(), .{}, null);
    _ = mgr.showOverlay(d2.component(), .{}, null);

    // Remove first overlay by handle
    h1.hide();
    try testing.expectEqual(@as(usize, 1), mgr.stack.items.len);
}

test "OverlayManager non-capturing overlay not returned by topmostCapturing" {
    var mgr = OverlayManager.init(testing.allocator);
    defer mgr.deinit();

    const DummyComp = struct {
        pub fn render(_: *@This(), _: Region) void {}
        pub fn measure(_: *@This(), _: u32) Measurement {
            return .{ .min_height = 1, .preferred_height = 1 };
        }
        pub fn component(self: *@This()) Component {
            return Component.init(@This(), self);
        }
    };

    var d1 = DummyComp{};
    _ = mgr.showOverlay(d1.component(), .{ .non_capturing = true }, null);

    try testing.expect(mgr.topmostCapturingComponent() == null);
    try testing.expect(mgr.hasVisibleOverlays());
}
