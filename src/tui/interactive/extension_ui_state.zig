const std = @import("std");

const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const cell_mod = @import("../cell.zig");
const framebuffer_surface_mod = @import("../components/framebuffer_surface.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const overlay_mod = @import("../overlay.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Buffer = buffer_mod.Buffer;
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;

pub const ExtensionUiState = struct {
    allocator: std.mem.Allocator,
    views: std.StringHashMap(ViewRecord),
    frames: std.StringHashMap(FrameRecord),
    status_component: StatusComponent,
    toast_component: ToastComponent,
    overlay_component: OverlayComponent,

    pub fn init(allocator: std.mem.Allocator) ExtensionUiState {
        return .{
            .allocator = allocator,
            .views = std.StringHashMap(ViewRecord).init(allocator),
            .frames = std.StringHashMap(FrameRecord).init(allocator),
            .status_component = .{},
            .toast_component = .{},
            .overlay_component = .{},
        };
    }

    pub fn deinit(self: *ExtensionUiState) void {
        var vit = self.views.iterator();
        while (vit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.views.deinit();

        var fit = self.frames.iterator();
        while (fit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.frames.deinit();
    }

    pub fn statusComponent(self: *ExtensionUiState) Component {
        self.status_component.state = self;
        return self.status_component.component();
    }

    pub fn toastComponent(self: *ExtensionUiState) Component {
        self.toast_component.state = self;
        return self.toast_component.component();
    }

    pub fn overlayComponent(self: *ExtensionUiState) Component {
        self.overlay_component.state = self;
        return self.overlay_component.component();
    }

    pub fn hasToastViews(self: *ExtensionUiState) bool {
        return self.hasTargetViews(.toast);
    }

    pub fn hasOverlayViews(self: *ExtensionUiState) bool {
        return self.hasTargetViews(.overlay);
    }

    fn hasTargetViews(self: *ExtensionUiState, target: extension_ui.UiTarget) bool {
        var it = self.views.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.spec.target == target and entry.value_ptr.spec.root != null) return true;
        }
        return false;
    }

    pub fn applyRender(self: *ExtensionUiState, render: extension_ui.RenderSpec) void {
        const key = makeViewKey(self.allocator, render.state_owner_id, render.id) catch return;
        errdefer self.allocator.free(key);
        if (self.views.getEntry(key)) |entry| {
            if (render.generation < entry.value_ptr.spec.generation) {
                self.allocator.free(key);
                return;
            }
            if (render.remove) {
                var old = self.views.fetchRemove(entry.key_ptr.*).?;
                self.allocator.free(old.key);
                old.value.deinit(self.allocator);
                self.allocator.free(key);
                return;
            }
            const cloned = extension_ui.RenderSpec.clone(self.allocator, render) catch {
                self.allocator.free(key);
                return;
            };
            entry.value_ptr.deinit(self.allocator);
            entry.value_ptr.* = .{ .spec = cloned };
            self.allocator.free(key);
            return;
        }

        if (render.remove) {
            self.allocator.free(key);
            return;
        }
        const cloned = extension_ui.RenderSpec.clone(self.allocator, render) catch {
            self.allocator.free(key);
            return;
        };
        self.views.put(key, .{ .spec = cloned }) catch {
            var owned = cloned;
            owned.deinit(self.allocator);
            self.allocator.free(key);
        };
    }

    pub fn applyFrame(self: *ExtensionUiState, frame: extension_ui.UiFrame) void {
        frame.validate() catch return;
        const key = makeFrameKey(self.allocator, frame.state_owner_id, frame.view, frame.node) catch return;
        errdefer self.allocator.free(key);
        if (self.frames.getEntry(key)) |entry| {
            if (frame.generation < entry.value_ptr.frame.generation) {
                self.allocator.free(key);
                return;
            }
            const cloned = extension_ui.UiFrame.clone(self.allocator, frame) catch {
                self.allocator.free(key);
                return;
            };
            entry.value_ptr.deinit(self.allocator);
            entry.value_ptr.* = .{ .frame = cloned };
            self.allocator.free(key);
            return;
        }
        const cloned = extension_ui.UiFrame.clone(self.allocator, frame) catch {
            self.allocator.free(key);
            return;
        };
        self.frames.put(key, .{ .frame = cloned }) catch {
            var owned = cloned;
            owned.deinit(self.allocator);
            self.allocator.free(key);
        };
    }

    fn findFrame(self: *ExtensionUiState, owner: []const u8, view: []const u8, node: []const u8) ?extension_ui.UiFrame {
        const key = makeFrameKey(self.allocator, owner, view, node) catch return null;
        defer self.allocator.free(key);
        const rec = self.frames.get(key) orelse return null;
        return rec.frame;
    }

    pub fn syncOverlayOptions(self: *ExtensionUiState, target: extension_ui.UiTarget, base: overlay_mod.OverlayOptions) overlay_mod.OverlayOptions {
        var options = base;
        const ordered = self.orderedTargetViews(target) catch return options;
        defer self.allocator.free(ordered);
        if (ordered.len == 0) return options;
        applyTargetOptions(&options, ordered[ordered.len - 1].spec.target_options);
        return options;
    }

    fn orderedTargetViews(self: *ExtensionUiState, target: extension_ui.UiTarget) ![]*ViewRecord {
        var list = std.ArrayList(*ViewRecord).empty;
        errdefer list.deinit(self.allocator);
        var it = self.views.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.spec.target == target and entry.value_ptr.spec.root != null) {
                try list.append(self.allocator, entry.value_ptr);
            }
        }
        std.mem.sort(*ViewRecord, list.items, {}, lessView);
        return list.toOwnedSlice(self.allocator);
    }
};

const ViewRecord = struct {
    spec: extension_ui.RenderSpec,
    fn deinit(self: *ViewRecord, allocator: std.mem.Allocator) void {
        self.spec.deinit(allocator);
    }
};

const FrameRecord = struct {
    frame: extension_ui.UiFrame,
    fn deinit(self: *FrameRecord, allocator: std.mem.Allocator) void {
        self.frame.deinit(allocator);
    }
};

const StatusComponent = struct {
    state: *ExtensionUiState = undefined,

    fn component(self: *StatusComponent) Component {
        return Component.init(StatusComponent, self);
    }

    pub fn render(self: *StatusComponent, region: Region) void {
        const ordered = self.orderedStatusViews() catch return;
        defer self.state.allocator.free(ordered);
        var y: u32 = 0;
        for (ordered) |view| {
            if (y >= region.height) break;
            const h = @min(measureNode(view.spec.root orelse continue, region.width), region.height - y);
            renderNode(self.state, view.spec, view.spec.root.?, region.sub(0, y, region.width, h));
            y += h;
        }
    }

    pub fn measure(self: *StatusComponent, width: u32) Measurement {
        const ordered = self.orderedStatusViews() catch return .{ .min_height = 0, .preferred_height = 0 };
        defer self.state.allocator.free(ordered);
        var total: u32 = 0;
        for (ordered) |view| {
            if (view.spec.root) |root| total += measureNode(root, width);
        }
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    fn orderedStatusViews(self: *StatusComponent) ![]*ViewRecord {
        return self.state.orderedTargetViews(.status);
    }
};

const OverlayComponent = struct {
    state: *ExtensionUiState = undefined,

    fn component(self: *OverlayComponent) Component {
        return Component.init(OverlayComponent, self);
    }

    pub fn render(self: *OverlayComponent, region: Region) void {
        const ordered = self.orderedOverlayViews() catch return;
        defer self.state.allocator.free(ordered);
        var y: u32 = 0;
        for (ordered) |view| {
            if (y >= region.height) break;
            const h = @min(measureNode(view.spec.root orelse continue, region.width), region.height - y);
            renderNode(self.state, view.spec, view.spec.root.?, region.sub(0, y, region.width, h));
            y += h;
        }
    }

    pub fn measure(self: *OverlayComponent, width: u32) Measurement {
        const ordered = self.orderedOverlayViews() catch return .{ .min_height = 0, .preferred_height = 0 };
        defer self.state.allocator.free(ordered);
        var total: u32 = 0;
        for (ordered) |view| {
            if (view.spec.root) |root| total += measureNode(root, width);
        }
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    fn orderedOverlayViews(self: *OverlayComponent) ![]*ViewRecord {
        return self.state.orderedTargetViews(.overlay);
    }
};

const ToastComponent = struct {
    state: *ExtensionUiState = undefined,

    fn component(self: *ToastComponent) Component {
        return Component.init(ToastComponent, self);
    }

    pub fn render(self: *ToastComponent, region: Region) void {
        const ordered = self.orderedToastViews() catch return;
        defer self.state.allocator.free(ordered);
        var y: u32 = 0;
        for (ordered) |view| {
            if (y >= region.height) break;
            const h = @min(measureNode(view.spec.root orelse continue, region.width), region.height - y);
            renderNode(self.state, view.spec, view.spec.root.?, region.sub(0, y, region.width, h));
            y += h;
        }
    }

    pub fn measure(self: *ToastComponent, width: u32) Measurement {
        const ordered = self.orderedToastViews() catch return .{ .min_height = 0, .preferred_height = 0 };
        defer self.state.allocator.free(ordered);
        var total: u32 = 0;
        for (ordered) |view| {
            if (view.spec.root) |root| total += measureNode(root, width);
        }
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    fn orderedToastViews(self: *ToastComponent) ![]*ViewRecord {
        return self.state.orderedTargetViews(.toast);
    }
};

fn applyTargetOptions(options: *overlay_mod.OverlayOptions, target: extension_ui.UiTargetOptions) void {
    if (target.width) |v| applyWidth(options, v);
    // Current overlay manager does not expose exact height; use height as a max-height constraint.
    if (target.height) |v| applyMaxHeight(options, v);
    if (target.min_width) |v| {
        if (fixedConstraint(v)) |n| options.min_width = n;
    }
    // max_width is parsed and retained for v3, but OverlayOptions has no max_width field yet.
    if (target.max_height) |v| applyMaxHeight(options, v);
    if (target.anchor) |v| options.anchor = toOverlayAnchor(v);
    if (target.backdrop) |v| options.backdrop = toOverlayBackdrop(v);
}

fn applyWidth(options: *overlay_mod.OverlayOptions, c: extension_ui.Constraint) void {
    switch (c) {
        .fixed => |v| {
            options.width = edge(v);
            options.width_percent = null;
        },
        .percent => |v| {
            options.width_percent = percent(v);
            options.width = null;
        },
        else => {},
    }
}

fn applyMaxHeight(options: *overlay_mod.OverlayOptions, c: extension_ui.Constraint) void {
    switch (c) {
        .fixed => |v| {
            options.max_height = edge(v);
            options.max_height_percent = null;
        },
        .percent => |v| {
            options.max_height_percent = percent(v);
            options.max_height = null;
        },
        else => {},
    }
}

fn fixedConstraint(c: extension_ui.Constraint) ?u32 {
    return switch (c) {
        .fixed => |v| edge(v),
        else => null,
    };
}

fn percent(v: f32) u8 {
    if (v <= 0) return 0;
    if (v >= 100) return 100;
    return @intFromFloat(v);
}

fn toOverlayAnchor(anchor: extension_ui.UiAnchor) overlay_mod.OverlayAnchor {
    return switch (anchor) {
        .center => .center,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
        .top_center => .top_center,
        .bottom_center => .bottom_center,
    };
}

fn toOverlayBackdrop(backdrop: extension_ui.UiBackdrop) overlay_mod.OverlayBackdrop {
    return switch (backdrop) {
        .none => .none,
        .dim => .dim,
        .fill => .{ .fill = Color.default },
    };
}

fn lessView(_: void, a: *ViewRecord, b: *ViewRecord) bool {
    if (a.spec.order != b.spec.order) return a.spec.order < b.spec.order;
    const owner_cmp = std.mem.order(u8, a.spec.state_owner_id, b.spec.state_owner_id);
    if (owner_cmp != .eq) return owner_cmp == .lt;
    return std.mem.order(u8, a.spec.id, b.spec.id) == .lt;
}

const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

fn measureNode(node: extension_ui.UiNode, width: u32) u32 {
    return switch (node) {
        .text => 1,
        .chip => 1,
        .progress => 1,
        .surface => |s| constraintHeight(s.style.height) orelse 1,
        .box => |b| measureBox(b, width),
    };
}

fn measureBox(b: extension_ui.UiNode.Box, width: u32) u32 {
    const border: u32 = if (b.style.border) 1 else 0;
    const pad_v = edge(b.style.padding.top) + edge(b.style.padding.bottom);
    var content: u32 = 0;
    if (b.children.len == 0) {
        content = 0;
    } else if (b.style.flex_direction == .row) {
        for (b.children) |child| content = @max(content, measureNode(child, width));
    } else {
        for (b.children, 0..) |child, i| {
            content += measureNode(child, width);
            if (i + 1 < b.children.len) content += edge(b.style.gap);
        }
    }
    return @max(1, border * 2 + pad_v + content);
}

fn renderNode(state: *ExtensionUiState, view: extension_ui.RenderSpec, node: extension_ui.UiNode, region: Region) void {
    if (region.width == 0 or region.height == 0) return;
    switch (node) {
        .text => |t| writeClipped(region, t.text),
        .chip => |ch| renderChip(region, ch.label),
        .progress => |pr| renderProgress(region, pr),
        .surface => |s| if (state.findFrame(view.state_owner_id, view.id, s.id)) |frame| {
            if (frame.generation >= view.generation) framebuffer_surface_mod.renderFrame(region, frame, 0);
        },
        .box => |b| renderBox(state, view, b, region),
    }
}

fn renderBox(state: *ExtensionUiState, view: extension_ui.RenderSpec, b: extension_ui.UiNode.Box, region: Region) void {
    var inner = region;
    if (b.style.border and region.width >= 2 and region.height >= 2) {
        drawBorder(region);
        inner = region.sub(1, 1, region.width - 2, region.height - 2);
    }
    const pl = edge(b.style.padding.left);
    const pr = edge(b.style.padding.right);
    const pt = edge(b.style.padding.top);
    const pb = edge(b.style.padding.bottom);
    inner = inner.sub(@min(pl, inner.width), @min(pt, inner.height), inner.width -| pl -| pr, inner.height -| pt -| pb);
    if (b.children.len == 0 or inner.width == 0 or inner.height == 0) return;
    if (b.style.flex_direction == .row) renderRow(state, view, b, inner) else renderColumn(state, view, b, inner);
}

fn renderColumn(state: *ExtensionUiState, view: extension_ui.RenderSpec, b: extension_ui.UiNode.Box, region: Region) void {
    const gap = edge(b.style.gap);
    var y: u32 = 0;
    for (b.children, 0..) |child, i| {
        if (y >= region.height) break;
        const h = @min(resolveHeight(child, region.height - y), region.height - y);
        renderNode(state, view, child, region.sub(0, y, region.width, h));
        y += h;
        if (i + 1 < b.children.len) y +|= gap;
    }
}

fn renderRow(state: *ExtensionUiState, view: extension_ui.RenderSpec, b: extension_ui.UiNode.Box, region: Region) void {
    const gap = edge(b.style.gap);
    const total_gap = gap *| @as(u32, @intCast(if (b.children.len > 0) b.children.len - 1 else 0));
    const avail = region.width -| total_gap;
    var fixed: u32 = 0;
    var fill_count: u32 = 0;
    for (b.children) |child| {
        if (widthConstraint(child)) |w| fixed += resolveConstraint(w, avail) else fill_count += 1;
    }
    const fill_w = if (fill_count > 0) (avail -| fixed) / fill_count else 0;
    var x: u32 = 0;
    for (b.children, 0..) |child, i| {
        if (x >= region.width) break;
        const w = @min(if (widthConstraint(child)) |cw| resolveConstraint(cw, avail) else fill_w, region.width - x);
        renderNode(state, view, child, region.sub(x, 0, w, region.height));
        x += w;
        if (i + 1 < b.children.len) x +|= gap;
    }
}

fn resolveHeight(node: extension_ui.UiNode, avail: u32) u32 {
    const c = switch (node) {
        .box => |b| b.style.height,
        .text => |t| t.style.height,
        .chip => |c| c.style.height,
        .progress => |p| p.style.height,
        .surface => |s| s.style.height,
    };
    if (c) |v| return resolveConstraint(v, avail);
    return measureNode(node, avail);
}

fn widthConstraint(node: extension_ui.UiNode) ?extension_ui.Constraint {
    return switch (node) {
        .box => |b| b.style.width,
        .text => |t| t.style.width,
        .chip => |c| c.style.width,
        .progress => |p| p.style.width,
        .surface => |s| s.style.width,
    };
}

fn resolveConstraint(c: extension_ui.Constraint, avail: u32) u32 {
    return switch (c) {
        .fixed => |v| edge(v),
        .percent => |v| @intFromFloat(@max(0, @as(f32, @floatFromInt(avail)) * v / 100.0)),
        .fill => avail,
        .auto => 0,
    };
}

fn constraintHeight(c: ?extension_ui.Constraint) ?u32 {
    return if (c) |v| switch (v) {
        .fixed => |f| edge(f),
        else => null,
    } else null;
}

fn drawBorder(region: Region) void {
    const attrs = Attributes.none;
    const fg = Color.default;
    const bg = Color.default;
    region.set(0, 0, charCell('┌', fg, bg, attrs));
    region.set(region.width - 1, 0, charCell('┐', fg, bg, attrs));
    region.set(0, region.height - 1, charCell('└', fg, bg, attrs));
    region.set(region.width - 1, region.height - 1, charCell('┘', fg, bg, attrs));
    var x: u32 = 1;
    while (x + 1 < region.width) : (x += 1) {
        region.set(x, 0, charCell('─', fg, bg, attrs));
        region.set(x, region.height - 1, charCell('─', fg, bg, attrs));
    }
    var y: u32 = 1;
    while (y + 1 < region.height) : (y += 1) {
        region.set(0, y, charCell('│', fg, bg, attrs));
        region.set(region.width - 1, y, charCell('│', fg, bg, attrs));
    }
}

fn renderChip(region: Region, label: []const u8) void {
    _ = region.writeStr(0, 0, "[ ", Color.default, Color.default, Attributes.none);
    if (region.width > 2) _ = region.writeStr(2, 0, label, Color.default, Color.default, Attributes.none);
    const close_x = @min(@as(u32, @intCast(label.len)) + 2, region.width - 1);
    if (close_x + 1 < region.width) _ = region.writeStr(close_x, 0, " ]", Color.default, Color.default, Attributes.none);
}

fn renderProgress(region: Region, pr: extension_ui.UiNode.Progress) void {
    if (pr.value) |value| {
        if (region.width < 3) return;
        const pct = @max(0, @min(value, 1));
        const inner = region.width - 2;
        const filled: u32 = @intFromFloat(@as(f32, @floatFromInt(inner)) * pct);
        region.set(0, 0, charCell('[', Color.default, Color.default, Attributes.none));
        var x: u32 = 0;
        while (x < inner) : (x += 1) region.set(x + 1, 0, charCell(if (x < filled) '█' else ' ', Color.default, Color.default, Attributes.none));
        region.set(region.width - 1, 0, charCell(']', Color.default, Color.default, Attributes.none));
    } else if (pr.label) |label| {
        writeClipped(region, label);
    }
}

fn writeClipped(region: Region, text: []const u8) void {
    _ = region.writeStr(0, 0, text, Color.default, Color.default, Attributes.none);
}

fn charCell(cp: u21, fg: Color, bg: Color, attrs: Attributes) Cell {
    return .{ .grapheme = .{ .codepoint = cp }, .fg = fg, .bg = bg, .attrs = attrs };
}

fn edge(v: f32) u32 {
    if (v <= 0) return 0;
    return @intFromFloat(v);
}

fn makeViewKey(allocator: std.mem.Allocator, owner: []const u8, id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ owner, id });
}

fn makeFrameKey(allocator: std.mem.Allocator, owner: []const u8, view: []const u8, node: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ owner, view, node });
}

fn cpAt(buf: *Buffer, x: u32, y: u32) u21 {
    return buf.get(x, y).grapheme.codepoint;
}

test "extension ui retains clone remove and generation gates" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.views.count());

    const root = extension_ui.UiNode{ .text = .{ .text = "new" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .target = .status, .root = root });
    try std.testing.expectEqual(@as(usize, 1), state.views.count());

    const stale = extension_ui.UiNode{ .text = .{ .text = "old" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = stale });
    const rec = state.views.get("owner\x1fview").?;
    try std.testing.expectEqualStrings("new", rec.spec.root.?.text.text);

    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .remove = true });
    try std.testing.expectEqual(@as(usize, 1), state.views.count());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 3, .id = "view", .remove = true });
    try std.testing.expectEqual(@as(usize, 0), state.views.count());
}

test "extension ui renders text" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .text = .{ .text = "hello" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 10, 1);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'o'), cpAt(&buf, 4, 0));
}

test "extension ui renders bordered box" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const child = extension_ui.UiNode{ .text = .{ .text = "hi" } };
    const root = extension_ui.UiNode{ .box = .{ .style = .{ .border = true, .padding = .{ .left = 1, .top = 0 } }, .children = @constCast(&[_]extension_ui.UiNode{child}) } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 8, 3);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, '┌'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, '┐'), cpAt(&buf, 7, 0));
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 2, 1));
}

test "extension ui sorts status views by order and id" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "b", .target = .status, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "a", .target = .status, .order = 1, .root = .{ .text = .{ .text = "a" } } });
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "c", .target = .status, .order = 1, .root = .{ .text = .{ .text = "c" } } });
    var buf = try Buffer.init(std.testing.allocator, 4, 3);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'c'), cpAt(&buf, 0, 1));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 0, 2));
}

test "extension ui surface uses keyed frame lookup" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .surface = .{ .id = "node", .style = .{ .height = .{ .fixed = 1 } } } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .target = .status, .root = root });
    const red = [_]u8{ 255, 0, 0, 255, 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255, 0, 0, 255, 255 };
    state.applyFrame(.{ .state_owner_id = "owner", .generation = 1, .view = "other", .node = "node", .width = 1, .height = 2, .data = &blue });
    state.applyFrame(.{ .state_owner_id = "owner", .generation = 2, .view = "view", .node = "node", .width = 1, .height = 2, .data = &red });
    var buf = try Buffer.init(std.testing.allocator, 1, 1);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, '▀'), cpAt(&buf, 0, 0));
    try std.testing.expect(buf.get(0, 0).fg.eql(Color.rgb(255, 0, 0)));
}

test "extension ui sorts toast views and filters status" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "status", .target = .status, .order = 0, .root = .{ .text = .{ .text = "s" } } });
    state.applyRender(.{ .state_owner_id = "b", .generation = 1, .id = "late", .target = .toast, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "z", .target = .toast, .order = 1, .root = .{ .text = .{ .text = "z" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "a", .target = .toast, .order = 1, .root = .{ .text = .{ .text = "a" } } });

    try std.testing.expect(state.hasToastViews());
    var buf = try Buffer.init(std.testing.allocator, 4, 3);
    defer buf.deinit();
    var comp = state.toastComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'z'), cpAt(&buf, 0, 1));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 0, 2));
}

test "extension ui remove final toast clears presence" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "toast", .target = .toast, .root = .{ .text = .{ .text = "hi" } } });
    try std.testing.expect(state.hasToastViews());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "toast", .target = .toast, .remove = true });
    try std.testing.expect(!state.hasToastViews());
}

test "extension ui sorts overlay views and filters other targets" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "status", .target = .status, .order = 0, .root = .{ .text = .{ .text = "s" } } });
    state.applyRender(.{ .state_owner_id = "b", .generation = 1, .id = "late", .target = .overlay, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "z", .target = .overlay, .order = 1, .root = .{ .text = .{ .text = "z" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "a", .target = .overlay, .order = 1, .root = .{ .text = .{ .text = "a" } } });

    try std.testing.expect(state.hasOverlayViews());
    var buf = try Buffer.init(std.testing.allocator, 4, 3);
    defer buf.deinit();
    var comp = state.overlayComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'z'), cpAt(&buf, 0, 1));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 0, 2));
}

test "extension ui remove final overlay clears presence" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "overlay", .target = .overlay, .root = .{ .text = .{ .text = "hi" } } });
    try std.testing.expect(state.hasOverlayViews());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "overlay", .target = .overlay, .remove = true });
    try std.testing.expect(!state.hasOverlayViews());
}

test "extension ui maps retained overlay target options" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{
        .state_owner_id = "owner",
        .generation = 1,
        .id = "overlay",
        .target = .overlay,
        .target_options = .{ .width = .{ .percent = 92 }, .max_height = .{ .percent = 90 }, .anchor = .center, .backdrop = .dim },
        .root = .{ .text = .{ .text = "hi" } },
    });
    const options = state.syncOverlayOptions(.overlay, .{});
    try std.testing.expectEqual(@as(?u8, 92), options.width_percent);
    try std.testing.expectEqual(@as(?u8, 90), options.max_height_percent);
    try std.testing.expectEqual(overlay_mod.OverlayAnchor.center, options.anchor);
    try std.testing.expect(options.backdrop == .dim);
}
