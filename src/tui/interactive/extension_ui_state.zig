const std = @import("std");

const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const framebuffer_surface_mod = @import("../components/framebuffer_surface.zig");
const text_component_mod = @import("../components/text.zig");
const markdown_component_mod = @import("../components/markdown.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const overlay_mod = @import("../primitives/overlay.zig");
const keys_mod = @import("../terminal/keys.zig");
const grapheme_mod = @import("../grapheme.zig");
const chrome_mod = @import("../primitives/chrome.zig");
const text_input_mod = @import("../primitives/text_input.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Buffer = buffer_mod.Buffer;
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const TextComponent = text_component_mod.Text;
const TextRun = text_component_mod.TextRun;
const MarkdownComponent = markdown_component_mod.Markdown;
const WidthMethod = grapheme_mod.WidthMethod;
const Theme = theme_mod.Theme;
const TextInput = text_input_mod.TextInput;
const log = std.log.scoped(.extension_ui_input);

pub const ExtensionUiState = struct {
    allocator: std.mem.Allocator,
    views: std.StringHashMap(ViewRecord),
    frames: std.StringHashMap(FrameRecord),
    input_states: std.StringHashMap(TextInput),
    theme: *const Theme,
    status_component: TargetComponent,
    notification_component: TargetComponent,
    overlay_component: TargetComponent,
    editor_border_top_component: TargetComponent,
    editor_border_bottom_component: TargetComponent,

    pub fn init(allocator: std.mem.Allocator) ExtensionUiState {
        return .{
            .allocator = allocator,
            .views = std.StringHashMap(ViewRecord).init(allocator),
            .frames = std.StringHashMap(FrameRecord).init(allocator),
            .input_states = std.StringHashMap(TextInput).init(allocator),
            .theme = themes_builtin.dark(),
            .status_component = .{ .target = .status },
            .notification_component = .{ .target = .notification },
            .overlay_component = .{ .target = .overlay },
            .editor_border_top_component = .{ .target = .editor_border_top },
            .editor_border_bottom_component = .{ .target = .editor_border_bottom },
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

        var iit = self.input_states.iterator();
        while (iit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.input_states.deinit();
    }

    pub fn setTheme(self: *ExtensionUiState, theme: *const Theme) void {
        self.theme = theme;
    }

    fn activeTheme(self: *const ExtensionUiState) *const Theme {
        return self.theme;
    }

    pub fn statusComponent(self: *ExtensionUiState) Component {
        self.status_component.state = self;
        return self.status_component.component();
    }

    pub fn notificationComponent(self: *ExtensionUiState) Component {
        self.notification_component.state = self;
        return self.notification_component.component();
    }

    pub fn overlayComponent(self: *ExtensionUiState) Component {
        self.overlay_component.state = self;
        return self.overlay_component.component();
    }

    pub fn editorBorderTopComponent(self: *ExtensionUiState) Component {
        self.editor_border_top_component.state = self;
        return self.editor_border_top_component.component();
    }

    pub fn editorBorderBottomComponent(self: *ExtensionUiState) Component {
        self.editor_border_bottom_component.state = self;
        return self.editor_border_bottom_component.component();
    }

    pub fn hasNotificationViews(self: *ExtensionUiState) bool {
        return self.hasTargetViews(.notification);
    }

    pub fn hasOverlayViews(self: *ExtensionUiState) bool {
        return self.hasTargetViews(.overlay);
    }

    pub fn targetWantsFocus(self: *ExtensionUiState, target: extension_ui.UiTarget) bool {
        const ordered = self.orderedTargetViews(target) catch return false;
        defer self.allocator.free(ordered);
        if (ordered.len == 0) return false;
        return ordered[ordered.len - 1].spec.focus;
    }

    pub fn handleOverlayInput(self: *ExtensionUiState, key: keys_mod.Key) ?extension_ui.UiEvent {
        const ordered = self.orderedTargetViews(.overlay) catch return null;
        defer self.allocator.free(ordered);
        var i = ordered.len;
        while (i > 0) {
            i -= 1;
            const spec = ordered[i].spec;
            if (!spec.focus) continue;
            const input = firstInput(spec.root orelse continue) orelse continue;
            return editInput(self, spec, input, key) catch null;
        }
        return null;
    }

    pub fn matchOverlayKey(self: *ExtensionUiState, key: keys_mod.Key) ?extension_ui.UiEvent {
        const ordered = self.orderedTargetViews(.overlay) catch return null;
        defer self.allocator.free(ordered);
        var i = ordered.len;
        while (i > 0) {
            i -= 1;
            const spec = ordered[i].spec;
            for (spec.keys) |binding| {
                const parsed = keys_mod.parseKeySpec(binding.key) catch continue;
                if (!parsed.eql(key)) continue;
                return .{ .state_owner_id = spec.state_owner_id, .generation = spec.generation, .view = spec.id, .type = .key, .action = binding.action, .key = binding.key, .ctrl = key.ctrl, .alt = key.alt, .shift = key.shift };
            }
        }
        return null;
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
                clearInputValuesForView(self, render.state_owner_id, render.id);
                self.allocator.free(old.key);
                old.value.deinit(self.allocator);
                self.allocator.free(key);
                return;
            }
            var render_for_clone = render;
            if (render_for_clone.notification) |*n| {
                if (entry.value_ptr.spec.notification) |old| {
                    n.created_ns = old.created_ns;
                    n.count = if (std.mem.eql(u8, n.message, old.message)) old.count + 1 else 1;
                }
            }
            const cloned = extension_ui.RenderSpec.clone(self.allocator, render_for_clone) catch {
                self.allocator.free(key);
                return;
            };
            entry.value_ptr.deinit(self.allocator);
            entry.value_ptr.* = .{ .spec = cloned };
            syncInputValues(self, render);
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
        syncInputValues(self, render);
    }

    pub fn tickNotifications(self: *ExtensionUiState, now_ns: i128) bool {
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(self.allocator);
        var has_active_progress = false;
        var it = self.views.iterator();
        while (it.next()) |entry| {
            const notify = entry.value_ptr.spec.notification orelse continue;
            if (notify.progress and !notify.done) has_active_progress = true;
            if (notify.ttlMs()) |ttl_ms| {
                const age_ns = now_ns - notify.updated_ns;
                if (age_ns >= @as(i128, ttl_ms) * std.time.ns_per_ms) keys.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (keys.items) |k| {
            var old = self.views.fetchRemove(k) orelse continue;
            self.allocator.free(old.key);
            old.value.deinit(self.allocator);
        }
        return keys.items.len > 0 or has_active_progress;
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

const InputRef = struct {
    id: []const u8,
    value: []const u8,
    on_input: ?[]const u8,
    on_change: ?[]const u8,
    on_submit: ?[]const u8,
};

fn firstInput(node: extension_ui.UiNode) ?InputRef {
    return switch (node) {
        .input => |input| .{ .id = input.id, .value = input.value, .on_input = input.on_input, .on_change = input.on_change, .on_submit = input.on_submit },
        .view => |view| blk: {
            for (view.children) |child| if (firstInput(child)) |found| break :blk found;
            break :blk null;
        },
        else => null,
    };
}

fn syncInputValues(self: *ExtensionUiState, render: extension_ui.RenderSpec) void {
    if (render.root) |root| syncInputValuesNode(self, render.state_owner_id, render.id, root);
}

fn syncInputValuesNode(self: *ExtensionUiState, owner: []const u8, view: []const u8, node: extension_ui.UiNode) void {
    switch (node) {
        .input => |input| syncInputState(self, owner, view, input.id, input.value) catch {},
        .view => |v| for (v.children) |child| syncInputValuesNode(self, owner, view, child),
        else => {},
    }
}

fn clearInputValuesForView(self: *ExtensionUiState, owner: []const u8, view: []const u8) void {
    const prefix = std.fmt.allocPrint(self.allocator, "{s}\x1f{s}\x1f", .{ owner, view }) catch return;
    defer self.allocator.free(prefix);
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(self.allocator);
    var it = self.input_states.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) keys.append(self.allocator, entry.key_ptr.*) catch break;
    }
    for (keys.items) |k| {
        var old = self.input_states.fetchRemove(k) orelse continue;
        self.allocator.free(old.key);
        old.value.deinit();
    }
}

fn syncInputState(self: *ExtensionUiState, owner: []const u8, view: []const u8, id: []const u8, value: []const u8) !void {
    const key = try makeInputKey(self.allocator, owner, view, id);
    errdefer self.allocator.free(key);
    if (self.input_states.getEntry(key)) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.text(), value)) {
            try entry.value_ptr.setValue(value);
        }
        self.allocator.free(key);
        return;
    }
    var input = TextInput.init(self.allocator, self.activeTheme());
    errdefer input.deinit();
    try input.setValue(value);
    try self.input_states.put(key, input);
}

fn inputState(self: *ExtensionUiState, owner: []const u8, view: []const u8, id: []const u8, fallback: []const u8) !*TextInput {
    const key = try makeInputKey(self.allocator, owner, view, id);
    errdefer self.allocator.free(key);
    if (self.input_states.getEntry(key)) |entry| {
        self.allocator.free(key);
        return entry.value_ptr;
    }
    var input = TextInput.init(self.allocator, self.activeTheme());
    errdefer input.deinit();
    try input.setValue(fallback);
    try self.input_states.put(key, input);
    return self.input_states.getPtr(key).?;
}

fn inputValue(self: *ExtensionUiState, owner: []const u8, view: []const u8, id: []const u8, fallback: []const u8) []const u8 {
    const input = inputState(self, owner, view, id, fallback) catch return fallback;
    return input.text();
}

fn editInput(self: *ExtensionUiState, spec: extension_ui.RenderSpec, input: InputRef, key: keys_mod.Key) !?extension_ui.UiEvent {
    const editor = try inputState(self, spec.state_owner_id, spec.id, input.id, input.value);
    const result = editor.handleKey(key);
    switch (result) {
        .none => return null,
        .input => {
            log.debug("edited input owner={s} view={s} node={s} value_len={d}", .{ spec.state_owner_id, spec.id, input.id, editor.text().len });
            return .{ .state_owner_id = spec.state_owner_id, .generation = spec.generation, .view = spec.id, .node = input.id, .type = .input, .action = input.on_input orelse input.on_change, .value = editor.text(), .ctrl = key.ctrl, .alt = key.alt, .shift = key.shift };
        },
        .consumed => return null,
        .submit => {
            return .{ .state_owner_id = spec.state_owner_id, .generation = spec.generation, .view = spec.id, .node = input.id, .type = .submit, .action = input.on_submit, .value = editor.text(), .ctrl = key.ctrl, .alt = key.alt, .shift = key.shift };
        },
    }
}

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

const TargetComponent = struct {
    state: *ExtensionUiState = undefined,
    target: extension_ui.UiTarget,
    width_method: WidthMethod = .wcwidth,

    fn component(self: *TargetComponent) Component {
        return Component.init(TargetComponent, self);
    }

    pub fn render(self: *TargetComponent, region: Region) void {
        self.width_method = region.buf.width_method;
        const ordered = self.orderedViews() catch return;
        defer self.state.allocator.free(ordered);
        if (self.target == .notification) return renderNotifications(self, ordered, region);
        var y: u32 = 0;
        for (ordered) |view| {
            if (y >= region.height) break;
            const h = @min(measureNode(self.state, view.spec.root orelse continue, region.width, region.buf.width_method), region.height - y);
            renderNode(self.state, view.spec, view.spec.root.?, region.sub(0, y, region.width, h));
            y += h;
        }
    }

    pub fn measure(self: *TargetComponent, width: u32) Measurement {
        const ordered = self.orderedViews() catch return .{ .min_height = 0, .preferred_height = 0 };
        defer self.state.allocator.free(ordered);
        if (self.target == .notification) return .{ .min_height = if (ordered.len > 0) 1 else 0, .preferred_height = @intCast(@min(ordered.len, 12)) };
        var total: u32 = 0;
        for (ordered) |view| {
            if (view.spec.root) |root| total += measureNode(self.state, root, width, self.width_method);
        }
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    fn orderedViews(self: *TargetComponent) ![]*ViewRecord {
        return self.state.orderedTargetViews(self.target);
    }
};

fn renderNotifications(component: *TargetComponent, ordered: []*ViewRecord, region: Region) void {
    if (region.width == 0 or region.height == 0) return;
    const state = component.state;
    const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()));
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const visible = @min(ordered.len, region.height);
    const start = ordered.len - visible;
    var y: u32 = 0;
    var last_group: ?[]const u8 = null;
    for (ordered[start..]) |view| {
        if (y >= region.height) break;
        const notify = view.spec.notification orelse {
            if (view.spec.root) |root| renderNode(state, view.spec, root, region.sub(0, y, region.width, 1));
            y += 1;
            continue;
        };
        const group = notify.group orelse "";
        const show_group = last_group == null or !std.mem.eql(u8, last_group.?, group);
        last_group = group;
        const frame_idx: usize = @intCast(@mod(@divTrunc(now_ns, 120 * std.time.ns_per_ms), frames.len));
        const icon = if (notify.progress and !notify.done) frames[frame_idx] else switch (notify.level) {
            .debug => "·",
            .info => "●",
            .warn => "▲",
            .error_ => "✖",
            .success => "✓",
        };
        const label = if (notify.title) |title| title else if (show_group and group.len > 0) group else icon;
        const suffix = if (notify.annote) |annote| annote else if (notify.done) "done" else "";
        const rendered_message = if (notify.count > 1)
            std.fmt.allocPrint(state.allocator, "({d}x) {s}", .{ notify.count, notify.message }) catch notify.message
        else
            notify.message;
        defer if (rendered_message.ptr != notify.message.ptr) state.allocator.free(rendered_message);
        const text = if (suffix.len > 0)
            std.fmt.allocPrint(state.allocator, "{s} {s} — {s}", .{ label, rendered_message, suffix }) catch notify.message
        else
            std.fmt.allocPrint(state.allocator, "{s} {s}", .{ label, rendered_message }) catch notify.message;
        defer if (text.ptr != notify.message.ptr) state.allocator.free(text);
        renderText(state, region.sub(0, y, region.width, 1), .{ .text = text, .style = .{ .tone = extension_ui.notificationTone(notify), .dim = notify.done }, .wrap = .word, .max_lines = 1 });
        y += 1;
    }
}

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

fn measureNode(state: *ExtensionUiState, node: extension_ui.UiNode, width: u32, width_method: WidthMethod) u32 {
    return switch (node) {
        .text => |t| measureText(state, t, width, width_method),
        .chip => 1,
        .progress => 1,
        .separator => 1,
        .surface => |s| constraintHeight(s.style.height) orelse 1,
        .input => 1,
        .view => |b| measureView(state, b, width, width_method),
    };
}

fn measureView(state: *ExtensionUiState, b: extension_ui.UiNode.View, width: u32, width_method: WidthMethod) u32 {
    const border: u32 = if (hasFrameChrome(b.style.chrome)) 1 else 0;
    const pad_v = edge(b.style.padding.top) + edge(b.style.padding.bottom);
    const pad_h = edge(b.style.padding.left) + edge(b.style.padding.right);
    const child_width = width -| (border * 2 + pad_h);
    var content: u32 = 0;
    if (b.children.len == 0) {
        content = 0;
    } else if (b.style.flex_direction == .row) {
        for (b.children) |child| content = @max(content, measureNode(state, child, child_width, width_method));
    } else {
        for (b.children, 0..) |child, i| {
            content += measureNode(state, child, child_width, width_method);
            if (i + 1 < b.children.len) content += edge(b.style.gap);
        }
    }
    return @max(1, border * 2 + pad_v + content);
}

fn measureText(state: *ExtensionUiState, t: extension_ui.UiNode.Text, width: u32, width_method: WidthMethod) u32 {
    if (t.format == .markdown) return measureMarkdown(state, t, width, width_method);
    var text = TextComponent.init(state.allocator, width_method);
    defer text.deinit();
    applyTextContent(state, &text, t) catch {
        text.content = t.text;
    };
    applyTextOptions(&text, t);
    return text.measure(width).preferred_height;
}

fn applyTextOptions(text: *TextComponent, t: extension_ui.UiNode.Text) void {
    text.wrap_mode = switch (t.wrap) {
        .none => .none,
        .char => .char,
        .word => .word,
    };
    text.overflow = switch (t.overflow) {
        .clip => .clip,
        .ellipsis => .ellipsis,
    };
    text.text_align = switch (t.@"align") {
        .left => .left,
        .center => .center,
        .right => .right,
    };
    text.max_lines = t.max_lines;
    text.scroll_offset = t.scroll_y;
    text.scroll_x = t.scroll_x;
    text.link = t.link;
    // selectable is retained on extension_ui.UiNode.Text for future event/selection UX.
}

fn applyTextContent(state: *ExtensionUiState, text: *TextComponent, t: extension_ui.UiNode.Text) !void {
    applyStyleToText(state, text, t.style);
    if (t.format == .ansi) {
        const parsed = try parseAnsiText(state.allocator, t.text, text.fg);
        defer parsed.deinit(state.allocator);
        text.setRuns(parsed.runs);
        return;
    }
    if (t.spans) |spans| {
        const runs = try state.allocator.alloc(TextRun, spans.len);
        defer state.allocator.free(runs);
        for (spans, 0..) |span, i| {
            const style = span.style orelse t.style;
            runs[i] = .{ .text = span.text, .fg = styleFg(state.activeTheme(), style), .bg = styleBg(style), .attrs = styleAttrs(style), .link = span.link orelse t.link };
        }
        text.setRuns(runs);
    } else {
        text.content = t.text;
    }
}

const ParsedAnsiText = struct {
    text: []u8,
    runs: []TextRun,

    fn deinit(self: ParsedAnsiText, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
        allocator.free(self.text);
    }
};

const AnsiStyle = struct {
    fg: Color,
    bg: Color = Color.default,
    attrs: Attributes = .{},
    link: ?[]const u8 = null,
};

fn parseAnsiText(allocator: std.mem.Allocator, input: []const u8, base_fg: Color) !ParsedAnsiText {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var runs = std.ArrayList(TextRun).empty;
    errdefer runs.deinit(allocator);
    var style = AnsiStyle{ .fg = base_fg };
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 1 < input.len) {
            if (input[i + 1] == '[') {
                if (findCsiEnd(input, i + 2)) |end| {
                    if (input[end] == 'm') {
                        try flushAnsiRun(allocator, &runs, out.items, &run_start, style);
                        applySgr(input[i + 2 .. end], &style, base_fg);
                    }
                    i = end + 1;
                    continue;
                }
            } else if (input[i + 1] == ']') {
                if (findOscEnd(input, i + 2)) |end| {
                    const payload_end = oscPayloadEnd(input, end);
                    try flushAnsiRun(allocator, &runs, out.items, &run_start, style);
                    applyOsc(input[i + 2 .. payload_end], &style);
                    i = end;
                    continue;
                }
            }
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    try flushAnsiRun(allocator, &runs, out.items, &run_start, style);
    const text_slice = try out.toOwnedSlice(allocator);
    errdefer allocator.free(text_slice);
    var offset: usize = 0;
    for (runs.items) |*run| {
        const len = run.text.len;
        run.text = text_slice[offset .. offset + len];
        offset += len;
    }
    return .{ .text = text_slice, .runs = try runs.toOwnedSlice(allocator) };
}

fn findCsiEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b >= 0x40 and b <= 0x7e) return i;
    }
    return null;
}

fn findOscEnd(input: []const u8, start: usize) ?usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == 0x07) return i + 1;
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') return i + 2;
    }
    return null;
}

fn oscPayloadEnd(input: []const u8, end: usize) usize {
    if (end > 0 and input[end - 1] == 0x07) return end - 1;
    return end - 2;
}

fn applyOsc(payload: []const u8, style: *AnsiStyle) void {
    if (!std.mem.startsWith(u8, payload, "8;")) return;
    const second_sep = std.mem.indexOfScalarPos(u8, payload, 2, ';') orelse return;
    const uri = payload[second_sep + 1 ..];
    style.link = if (uri.len == 0) null else uri;
}

fn flushAnsiRun(allocator: std.mem.Allocator, runs: *std.ArrayList(TextRun), text: []u8, run_start: *usize, style: AnsiStyle) !void {
    if (text.len == run_start.*) return;
    try runs.append(allocator, .{ .text = text[run_start.*..], .fg = style.fg, .bg = style.bg, .attrs = style.attrs, .link = style.link });
    run_start.* = text.len;
}

fn applySgr(params: []const u8, style: *AnsiStyle, base_fg: Color) void {
    if (params.len == 0) {
        const link = style.link;
        style.* = .{ .fg = base_fg, .link = link };
        return;
    }
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |part| {
        const code = parseSgrInt(part) orelse 0;
        switch (code) {
            0 => {
                const link = style.link;
                style.* = .{ .fg = base_fg, .link = link };
            },
            1 => style.attrs.bold = true,
            2 => style.attrs.dim = true,
            3 => style.attrs.italic = true,
            4 => style.attrs.underline = true,
            9 => style.attrs.strikethrough = true,
            22 => {
                style.attrs.bold = false;
                style.attrs.dim = false;
            },
            23 => style.attrs.italic = false,
            24 => style.attrs.underline = false,
            29 => style.attrs.strikethrough = false,
            30...37 => style.fg = ansiColor(@intCast(code - 30), false),
            39 => style.fg = base_fg,
            90...97 => style.fg = ansiColor(@intCast(code - 90), true),
            40...47 => style.bg = ansiColor(@intCast(code - 40), false),
            49 => style.bg = Color.default,
            100...107 => style.bg = ansiColor(@intCast(code - 100), true),
            38, 48 => {
                const is_fg = code == 38;
                const mode = parseSgrInt(it.next() orelse "") orelse continue;
                if (mode == 2) {
                    const r = parseByte(it.next() orelse "") orelse continue;
                    const g = parseByte(it.next() orelse "") orelse continue;
                    const b = parseByte(it.next() orelse "") orelse continue;
                    if (is_fg) style.fg = Color.rgb(r, g, b) else style.bg = Color.rgb(r, g, b);
                } else if (mode == 5) {
                    const index = parseByte(it.next() orelse "") orelse continue;
                    if (is_fg) style.fg = ansi256Color(index) else style.bg = ansi256Color(index);
                }
            },
            else => {},
        }
    }
}

fn parseSgrInt(bytes: []const u8) ?u16 {
    if (bytes.len == 0) return 0;
    return std.fmt.parseInt(u16, bytes, 10) catch null;
}

fn parseByte(bytes: []const u8) ?u8 {
    const v = parseSgrInt(bytes) orelse return null;
    if (v > 255) return null;
    return @intCast(v);
}

fn ansiColor(index: u3, bright: bool) Color {
    const normal = [_]Color{
        Color.rgb(0, 0, 0),
        Color.rgb(205, 49, 49),
        Color.rgb(13, 188, 121),
        Color.rgb(229, 229, 16),
        Color.rgb(36, 114, 200),
        Color.rgb(188, 63, 188),
        Color.rgb(17, 168, 205),
        Color.rgb(229, 229, 229),
    };
    const bright_palette = [_]Color{
        Color.rgb(102, 102, 102),
        Color.rgb(241, 76, 76),
        Color.rgb(35, 209, 139),
        Color.rgb(245, 245, 67),
        Color.rgb(59, 142, 234),
        Color.rgb(214, 112, 214),
        Color.rgb(41, 184, 219),
        Color.rgb(255, 255, 255),
    };
    return if (bright) bright_palette[index] else normal[index];
}

fn ansi256Color(index: u8) Color {
    if (index < 8) return ansiColor(@intCast(index), false);
    if (index < 16) return ansiColor(@intCast(index - 8), true);
    if (index < 232) {
        const cube_index = index - 16;
        const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
        return Color.rgb(
            levels[cube_index / 36],
            levels[(cube_index / 6) % 6],
            levels[cube_index % 6],
        );
    }
    const level: u8 = 8 + (index - 232) * 10;
    return Color.rgb(level, level, level);
}

fn applyStyleToText(state: *ExtensionUiState, text: *TextComponent, style: extension_ui.Style) void {
    text.fg = styleFg(state.activeTheme(), style);
    text.bg = styleBg(style);
    text.attrs = styleAttrs(style);
}

fn styleFg(theme: *const Theme, style: extension_ui.Style) Color {
    return if (style.fg) |fg| uiColor(fg) else chrome_mod.toneFg(theme, toChromeTone(style.tone));
}

fn styleBg(style: extension_ui.Style) Color {
    return if (style.bg) |bg| uiColor(bg) else Color.default;
}

fn styleAttrs(style: extension_ui.Style) Attributes {
    return .{
        .bold = style.bold,
        .dim = style.dim,
        .italic = style.italic,
        .underline = style.underline,
        .strikethrough = style.strikethrough,
    };
}

fn uiColor(color: extension_ui.Color) Color {
    return Color.rgb(color.r, color.g, color.b);
}

fn initMarkdown(state: *ExtensionUiState, t: extension_ui.UiNode.Text, width_method: WidthMethod) MarkdownComponent {
    var md = MarkdownComponent.init(state.allocator, width_method);
    md.setContent(t.text);
    md.fg = styleFg(state.activeTheme(), t.style);
    md.bg = styleBg(t.style);
    md.attrs = styleAttrs(t.style);
    // Markdown exposes symmetric padding only. Preserve text style padding when it is
    // representable; asymmetric padding is rounded up so content is never clipped.
    md.padding_x = @max(edge(t.style.padding.left), edge(t.style.padding.right));
    md.padding_y = @max(edge(t.style.padding.top), edge(t.style.padding.bottom));
    md.scroll_offset = t.scroll_y;
    return md;
}

fn measureMarkdown(state: *ExtensionUiState, t: extension_ui.UiNode.Text, width: u32, width_method: WidthMethod) u32 {
    var md = initMarkdown(state, t, width_method);
    defer md.deinit();
    // Markdown owns wrapping during document rendering; extension Text wrap=none,
    // max_lines, scroll_x, and align do not have compatible Markdown component knobs.
    return md.measure(width).preferred_height;
}

fn renderMarkdown(state: *ExtensionUiState, region: Region, t: extension_ui.UiNode.Text) void {
    var md = initMarkdown(state, t, region.buf.width_method);
    defer md.deinit();
    // Caveat: max_lines, scroll_x, and align intentionally remain Text-only options.
    md.render(region);
}

fn renderText(state: *ExtensionUiState, region: Region, t: extension_ui.UiNode.Text) void {
    if (t.format == .markdown) return renderMarkdown(state, region, t);
    var text = TextComponent.init(state.allocator, region.buf.width_method);
    defer text.deinit();
    applyTextContent(state, &text, t) catch {
        text.content = t.text;
    };
    applyTextOptions(&text, t);
    text.render(region);
}

fn renderNode(state: *ExtensionUiState, view: extension_ui.RenderSpec, node: extension_ui.UiNode, region: Region) void {
    if (region.width == 0 or region.height == 0) return;
    switch (node) {
        .text => |t| renderText(state, region, t),
        .chip => |ch| renderChip(region, ch.label),
        .progress => |pr| renderProgress(region, pr),
        .separator => |sep| renderSeparator(state, region, sep),
        .surface => |s| if (state.findFrame(view.state_owner_id, view.id, s.id)) |frame| {
            if (frame.generation >= view.generation) framebuffer_surface_mod.renderFrame(region, frame, 0);
        },
        .input => |input| renderInput(state, view, region, input),
        .view => |b| renderView(state, view, b, region),
    }
}

fn renderView(state: *ExtensionUiState, view: extension_ui.RenderSpec, b: extension_ui.UiNode.View, region: Region) void {
    var inner = region;
    if (renderChrome(state, b.style.chrome, region)) |chrome_inner| {
        inner = chrome_inner;
    }
    const pl = edge(b.style.padding.left);
    const pr = edge(b.style.padding.right);
    const pt = edge(b.style.padding.top);
    const pb = edge(b.style.padding.bottom);
    inner = inner.sub(@min(pl, inner.width), @min(pt, inner.height), inner.width -| pl -| pr, inner.height -| pt -| pb);
    if (b.children.len == 0 or inner.width == 0 or inner.height == 0) return;
    if (b.style.flex_direction == .row) renderRow(state, view, b, inner) else renderColumn(state, view, b, inner);
}

fn renderColumn(state: *ExtensionUiState, view: extension_ui.RenderSpec, b: extension_ui.UiNode.View, region: Region) void {
    const gap = edge(b.style.gap);
    var y: u32 = 0;
    for (b.children, 0..) |child, i| {
        if (y >= region.height) break;
        const h = @min(resolveHeight(state, child, region.width, region.height - y, region.buf.width_method), region.height - y);
        renderNode(state, view, child, region.sub(0, y, region.width, h));
        y += h;
        if (i + 1 < b.children.len) y +|= gap;
    }
}

fn renderRow(state: *ExtensionUiState, view: extension_ui.RenderSpec, b: extension_ui.UiNode.View, region: Region) void {
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

fn resolveHeight(state: *ExtensionUiState, node: extension_ui.UiNode, width: u32, avail: u32, width_method: WidthMethod) u32 {
    const c = switch (node) {
        .view => |b| b.style.height,
        .text => |t| t.style.height,
        .chip => |c| c.style.height,
        .progress => |p| p.style.height,
        .separator => |s| s.style.height,
        .surface => |s| s.style.height,
        .input => |input| input.style.height,
    };
    if (c) |v| return resolveConstraint(v, avail);
    return measureNode(state, node, width, width_method);
}

fn widthConstraint(node: extension_ui.UiNode) ?extension_ui.Constraint {
    return switch (node) {
        .view => |b| b.style.width,
        .text => |t| t.style.width,
        .chip => |c| c.style.width,
        .progress => |p| p.style.width,
        .separator => |s| s.style.width,
        .surface => |s| s.style.width,
        .input => |input| input.style.width,
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

fn hasFrameChrome(chrome: extension_ui.Chrome) bool {
    return switch (chrome) {
        .none => false,
        .frame => true,
    };
}

fn renderChrome(state: *ExtensionUiState, chrome_spec: extension_ui.Chrome, region: Region) ?Region {
    return switch (chrome_spec) {
        .none => null,
        .frame => |frame| renderFrameChrome(state, frame, region),
    };
}

fn renderFrameChrome(state: *ExtensionUiState, frame_chrome: extension_ui.Chrome.FrameChrome, region: Region) ?Region {
    const frame = chrome_mod.Frame{
        .title = frame_chrome.title,
        .trailing = frame_chrome.trailing,
        .border = toChromeBorderStyle(frame_chrome.border),
        .tone = toChromeTone(frame_chrome.tone),
    };
    const layout = frame.render(region, state.activeTheme()) orelse return null;
    return layout.body;
}

fn toChromeTone(tone: extension_ui.Tone) chrome_mod.Tone {
    return switch (tone) {
        .neutral => .neutral,
        .muted => .muted,
        .info => .info,
        .success => .success,
        .warning => .warning,
        .danger => .danger,
        .accent => .accent,
    };
}

fn toChromeBorderStyle(border: extension_ui.BorderStyle) chrome_mod.BorderStyle {
    return switch (border) {
        .rounded => .rounded,
        .square => .square,
    };
}

fn renderChip(region: Region, label: []const u8) void {
    _ = region.writeStr(0, 0, "[ ", Color.default, Color.default, Attributes.none);
    if (region.width > 2) _ = region.writeStr(2, 0, label, Color.default, Color.default, Attributes.none);
    const close_x = @min(@as(u32, @intCast(label.len)) + 2, region.width - 1);
    if (close_x + 1 < region.width) _ = region.writeStr(close_x, 0, " ]", Color.default, Color.default, Attributes.none);
}

fn renderInput(state: *ExtensionUiState, view: extension_ui.RenderSpec, region: Region, input: extension_ui.UiNode.Input) void {
    if (region.width == 0) return;
    const primitive = inputState(state, view.state_owner_id, view.id, input.id, input.value) catch return;
    log.debug("render input owner={s} view={s} node={s} value_len={d} width={d}", .{ view.state_owner_id, view.id, input.id, primitive.text().len, region.width });
    primitive.placeholder = input.placeholder;
    primitive.render(region);
}

fn renderSeparator(state: *ExtensionUiState, region: Region, sep: extension_ui.UiNode.Separator) void {
    const color = if (sep.style.fg) |fg| uiColor(fg) else null;
    (chrome_mod.Separator{ .color = color }).render(region, state.activeTheme());
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

fn makeInputKey(allocator: std.mem.Allocator, owner: []const u8, view: []const u8, node: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ owner, view, node });
}

fn bufferContainsText(buf: *Buffer, needle: []const u8) !bool {
    var row: u32 = 0;
    while (row < buf.height) : (row += 1) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        var col: u32 = 0;
        while (col < buf.width) : (col += 1) {
            try buf.appendCellText(&out, std.testing.allocator, buf.get(col, row));
        }
        if (std.mem.indexOf(u8, out.items, needle) != null) return true;
    }
    return false;
}

fn bufferHasAttr(buf: *Buffer, comptime field: []const u8) bool {
    var row: u32 = 0;
    while (row < buf.height) : (row += 1) {
        var col: u32 = 0;
        while (col < buf.width) : (col += 1) {
            if (@field(buf.get(col, row).attrs, field)) return true;
        }
    }
    return false;
}

fn cpAt(buf: *Buffer, x: u32, y: u32) u21 {
    const cell = buf.get(x, y);
    return switch (cell.grapheme) {
        .codepoint => |cp| cp,
        .pooled => 0,
    };
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

test "extension ui edits focused overlay input and emits structured events" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .input = .{ .id = "filter", .value = "z", .placeholder = "Filter", .on_input = "input", .on_change = "changed", .on_submit = "submitted" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .overlay, .focus = true, .root = root });

    const changed = state.handleOverlayInput(.{ .code = .char, .char = 'i' }).?;
    try std.testing.expectEqual(extension_ui.UiEventType.input, changed.type);
    try std.testing.expectEqualStrings("filter", changed.node.?);
    try std.testing.expectEqualStrings("input", changed.action.?);
    try std.testing.expectEqualStrings("zi", changed.value.?);

    const submitted = state.handleOverlayInput(.{ .code = .enter }).?;
    try std.testing.expectEqual(extension_ui.UiEventType.submit, submitted.type);
    try std.testing.expectEqualStrings("submitted", submitted.action.?);
    try std.testing.expectEqualStrings("zi", submitted.value.?);

    var buf = try Buffer.init(std.testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.overlayComponent();
    comp.render(buf.region());
    try std.testing.expect(try bufferContainsText(&buf, "zi"));
}

test "extension ui render resyncs input state" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .overlay, .focus = true, .root = .{ .input = .{ .id = "filter", .value = "a" } } });
    _ = state.handleOverlayInput(.{ .code = .char, .char = 'b' }).?;
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .target = .overlay, .focus = true, .root = .{ .input = .{ .id = "filter", .value = "server" } } });
    const submitted = state.handleOverlayInput(.{ .code = .enter }).?;
    try std.testing.expectEqualStrings("server", submitted.value.?);
}

test "extension ui renders text" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .text = .{ .text = "hello" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 10, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'o'), cpAt(&buf, 4, 0));
}

test "extension ui measures and renders multiline text" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .text = .{ .text = "hello\nworld" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });

    var comp = state.statusComponent();
    const measured = comp.measure(10);
    try std.testing.expectEqual(@as(u32, 2), measured.preferred_height);

    var buf = try Buffer.init(std.testing.allocator, 10, 2, .wcwidth);
    defer buf.deinit();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'w'), cpAt(&buf, 0, 1));
}

test "extension ui wraps text and lays out following column content below it" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const text = extension_ui.UiNode{ .text = .{ .text = "hello world" } };
    const chip = extension_ui.UiNode{ .chip = .{ .label = "next" } };
    const children = [_]extension_ui.UiNode{ text, chip };
    const root = extension_ui.UiNode{ .view = .{ .children = @constCast(&children) } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });

    var comp = state.statusComponent();
    const measured = comp.measure(5);
    try std.testing.expectEqual(@as(u32, 3), measured.preferred_height);

    var buf = try Buffer.init(std.testing.allocator, 5, 3, .wcwidth);
    defer buf.deinit();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'w'), cpAt(&buf, 0, 1));
    try std.testing.expectEqual(@as(u21, '['), cpAt(&buf, 0, 2));
}

test "extension ui renders bordered box" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const child = extension_ui.UiNode{ .text = .{ .text = "hi" } };
    const root = extension_ui.UiNode{ .view = .{ .style = .{ .chrome = .{ .frame = .{} }, .padding = .{ .left = 1, .top = 0 } }, .children = @constCast(&[_]extension_ui.UiNode{child}) } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 8, 3, .wcwidth);
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
    var buf = try Buffer.init(std.testing.allocator, 4, 3, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'c'), cpAt(&buf, 0, 1));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 0, 2));
}

test "extension ui renders text spans with colors and attributes" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const spans = [_]extension_ui.TextSpan{
        .{ .text = "ok", .style = .{ .tone = .success, .fg = extension_ui.Color.rgb(1, 2, 3), .bg = extension_ui.Color.rgb(4, 5, 6), .bold = true, .underline = true } },
        .{ .text = "!", .style = .{ .tone = .danger, .italic = true, .strikethrough = true } },
    };
    const root = extension_ui.UiNode{ .text = .{ .text = "ok!", .spans = @constCast(&spans) } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 4, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'o'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, '!'), cpAt(&buf, 2, 0));
    try std.testing.expect(buf.get(0, 0).fg.eql(Color.rgb(1, 2, 3)));
    try std.testing.expect(buf.get(0, 0).bg.eql(Color.rgb(4, 5, 6)));
    try std.testing.expect(buf.get(0, 0).attrs.bold);
    try std.testing.expect(buf.get(0, 0).attrs.underline);
    try std.testing.expect(buf.get(2, 0).fg.eql(chrome_mod.toneFg(state.activeTheme(), toChromeTone(.danger))));
    try std.testing.expect(buf.get(2, 0).attrs.italic);
    try std.testing.expect(buf.get(2, 0).attrs.strikethrough);
}

test "extension ui renders default text style colors and attrs" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    var buf = try Buffer.init(std.testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();
    const root = extension_ui.UiNode{ .text = .{ .text = "hi", .style = .{ .fg = extension_ui.Color.rgb(9, 8, 7), .bg = extension_ui.Color.rgb(6, 5, 4), .bold = true, .dim = true, .italic = true, .underline = true, .strikethrough = true } } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });
    state.statusComponent().render(buf.region());
    const cell = buf.get(0, 0);
    try std.testing.expect(cell.fg.eql(Color.rgb(9, 8, 7)));
    try std.testing.expect(cell.bg.eql(Color.rgb(6, 5, 4)));
    try std.testing.expect(cell.attrs.bold);
    try std.testing.expect(cell.attrs.dim);
    try std.testing.expect(cell.attrs.italic);
    try std.testing.expect(cell.attrs.underline);
    try std.testing.expect(cell.attrs.strikethrough);
}

test "extension ui renders text span links" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const spans = [_]extension_ui.TextSpan{
        .{ .text = "go", .link = "https://span.test" },
        .{ .text = "!" },
    };
    const node = extension_ui.UiNode{ .text = .{ .text = "go!", .spans = @constCast(&spans), .link = "https://node.test" } };
    var buf = try Buffer.init(std.testing.allocator, 4, 1, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());

    try std.testing.expectEqual(@as(usize, 2), buf.link_table.items.len);
    try std.testing.expectEqualStrings("https://span.test", buf.link_table.items[0]);
    try std.testing.expectEqualStrings("https://node.test", buf.link_table.items[1]);
    try std.testing.expectEqual(@as(u16, 1), buf.get(0, 0).link_id);
    try std.testing.expectEqual(@as(u16, 2), buf.get(2, 0).link_id);
}

test "extension ui wraps text spans across span boundaries" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const spans = [_]extension_ui.TextSpan{ .{ .text = "abc", .style = .{ .tone = .info } }, .{ .text = "def", .style = .{ .tone = .warning } } };
    const node = extension_ui.UiNode{ .text = .{ .text = "abcdef", .spans = @constCast(&spans), .wrap = .char } };
    try std.testing.expectEqual(@as(u32, 2), measureNode(&state, node, 3, .wcwidth));
    var buf = try Buffer.init(std.testing.allocator, 3, 2, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'd'), cpAt(&buf, 0, 1));
    try std.testing.expect(buf.get(0, 0).fg.eql(chrome_mod.toneFg(state.activeTheme(), toChromeTone(.info))));
    try std.testing.expect(buf.get(0, 1).fg.eql(chrome_mod.toneFg(state.activeTheme(), toChromeTone(.warning))));
}

test "extension ui ansi text strips escapes for measurement and render" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const node = extension_ui.UiNode{ .text = .{ .text = "a\x1b[31mb\x1b[0mc", .format = .ansi, .wrap = .char } };
    try std.testing.expectEqual(@as(u32, 1), measureNode(&state, node, 3, .wcwidth));

    var buf = try Buffer.init(std.testing.allocator, 3, 1, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 1, 0));
    try std.testing.expectEqual(@as(u21, 'c'), cpAt(&buf, 2, 0));
}

test "extension ui ansi text renders color spans and reset" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const node = extension_ui.UiNode{ .text = .{ .text = "x\x1b[31my\x1b[0mz", .format = .ansi } };
    var buf = try Buffer.init(std.testing.allocator, 3, 1, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());
    try std.testing.expect(buf.get(1, 0).fg.eql(ansiColor(1, false)));
    try std.testing.expect(buf.get(2, 0).fg.eql(Color.default));
}

test "extension ui ansi text renders truecolor and attributes" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const node = extension_ui.UiNode{ .text = .{ .text = "\x1b[1;3;4;38;2;1;2;3;48;2;4;5;6mA", .format = .ansi } };
    var buf = try Buffer.init(std.testing.allocator, 1, 1, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());
    const cell = buf.get(0, 0);
    try std.testing.expect(cell.fg.eql(Color.rgb(1, 2, 3)));
    try std.testing.expect(cell.bg.eql(Color.rgb(4, 5, 6)));
    try std.testing.expect(cell.attrs.bold);
    try std.testing.expect(cell.attrs.italic);
    try std.testing.expect(cell.attrs.underline);
}

test "extension ui ansi text ignores unknown escapes safely" {
    const parsed = try parseAnsiText(std.testing.allocator, "a\x1b[999mb\x1b[?25hcd", Color.default);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abcd", parsed.text);
    for (parsed.runs) |run| try std.testing.expect(run.fg.eql(Color.default));
}

test "extension ui ansi text extracts OSC 8 hyperlinks" {
    const parsed = try parseAnsiText(std.testing.allocator, "a\x1b]8;;https://example.test\x07b\x1b[31mc\x1b]8;;\x1b\\d", Color.default);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abcd", parsed.text);
    try std.testing.expectEqual(@as(usize, 4), parsed.runs.len);
    try std.testing.expect(parsed.runs[0].link == null);
    try std.testing.expectEqualStrings("https://example.test", parsed.runs[1].link.?);
    try std.testing.expectEqualStrings("https://example.test", parsed.runs[2].link.?);
    try std.testing.expect(parsed.runs[2].fg.eql(ansiColor(1, false)));
    try std.testing.expect(parsed.runs[3].link == null);
}

test "extension ui ansi text renders OSC 8 hyperlinks" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const node = extension_ui.UiNode{ .text = .{ .text = "a\x1b]8;;https://example.test\x07bc\x1b]8;;\x07d", .format = .ansi } };
    var buf = try Buffer.init(std.testing.allocator, 4, 1, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());
    try std.testing.expectEqual(@as(usize, 1), buf.link_table.items.len);
    try std.testing.expectEqualStrings("https://example.test", buf.link_table.items[0]);
    try std.testing.expectEqual(@as(u16, 0), buf.get(0, 0).link_id);
    try std.testing.expectEqual(@as(u16, 1), buf.get(1, 0).link_id);
    try std.testing.expectEqual(@as(u16, 1), buf.get(2, 0).link_id);
    try std.testing.expectEqual(@as(u16, 0), buf.get(3, 0).link_id);
}

test "extension ui ansi text supports partial attribute resets" {
    const bold_dim = try parseAnsiText(std.testing.allocator, "\x1b[1;2mA\x1b[22mB", Color.default);
    defer bold_dim.deinit(std.testing.allocator);
    try std.testing.expect(bold_dim.runs[0].attrs.bold);
    try std.testing.expect(bold_dim.runs[0].attrs.dim);
    try std.testing.expect(!bold_dim.runs[1].attrs.bold);
    try std.testing.expect(!bold_dim.runs[1].attrs.dim);

    const italic = try parseAnsiText(std.testing.allocator, "\x1b[3mA\x1b[23mB", Color.default);
    defer italic.deinit(std.testing.allocator);
    try std.testing.expect(italic.runs[0].attrs.italic);
    try std.testing.expect(!italic.runs[1].attrs.italic);

    const underline = try parseAnsiText(std.testing.allocator, "\x1b[4mA\x1b[24mB", Color.default);
    defer underline.deinit(std.testing.allocator);
    try std.testing.expect(underline.runs[0].attrs.underline);
    try std.testing.expect(!underline.runs[1].attrs.underline);

    const strike = try parseAnsiText(std.testing.allocator, "\x1b[9mA\x1b[29mB", Color.default);
    defer strike.deinit(std.testing.allocator);
    try std.testing.expect(strike.runs[0].attrs.strikethrough);
    try std.testing.expect(!strike.runs[1].attrs.strikethrough);
}

test "extension ui ansi text supports default fg and bg resets" {
    const base = Color.rgb(7, 8, 9);
    const parsed = try parseAnsiText(std.testing.allocator, "\x1b[31;42mA\x1b[39;49mB", base);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.runs[0].fg.eql(ansiColor(1, false)));
    try std.testing.expect(parsed.runs[0].bg.eql(ansiColor(2, false)));
    try std.testing.expect(parsed.runs[1].fg.eql(base));
    try std.testing.expect(parsed.runs[1].bg.eql(Color.default));
}

test "extension ui ansi text maps xterm 256 colors" {
    try std.testing.expect(ansi256Color(1).eql(ansiColor(1, false)));
    try std.testing.expect(ansi256Color(9).eql(ansiColor(1, true)));
    try std.testing.expect(ansi256Color(16).eql(Color.rgb(0, 0, 0)));
    try std.testing.expect(ansi256Color(21).eql(Color.rgb(0, 0, 255)));
    try std.testing.expect(ansi256Color(51).eql(Color.rgb(0, 255, 255)));
    try std.testing.expect(ansi256Color(231).eql(Color.rgb(255, 255, 255)));
    try std.testing.expect(ansi256Color(232).eql(Color.rgb(8, 8, 8)));
    try std.testing.expect(ansi256Color(255).eql(Color.rgb(238, 238, 238)));
}

test "extension ui ansi text supports 256 color fg and bg sequences" {
    const parsed = try parseAnsiText(std.testing.allocator, "\x1b[38;5;196;48;5;24mA", Color.default);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A", parsed.text);
    try std.testing.expect(parsed.runs[0].fg.eql(Color.rgb(255, 0, 0)));
    try std.testing.expect(parsed.runs[0].bg.eql(Color.rgb(0, 95, 135)));
}

test "extension ui ansi text supports mixed sgr sequences" {
    const parsed = try parseAnsiText(std.testing.allocator, "\x1b[1;38;2;1;2;3mA\x1b[38;5;46mB\x1b[22;48;5;240mC\x1b[999mD", Color.default);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ABCD", parsed.text);
    try std.testing.expect(parsed.runs[0].fg.eql(Color.rgb(1, 2, 3)));
    try std.testing.expect(parsed.runs[0].attrs.bold);
    try std.testing.expect(parsed.runs[1].fg.eql(Color.rgb(0, 255, 0)));
    try std.testing.expect(parsed.runs[1].attrs.bold);
    try std.testing.expect(parsed.runs[2].fg.eql(Color.rgb(0, 255, 0)));
    try std.testing.expect(parsed.runs[2].bg.eql(Color.rgb(88, 88, 88)));
    try std.testing.expect(!parsed.runs[2].attrs.bold);
    try std.testing.expect(parsed.runs[3].fg.eql(Color.rgb(0, 255, 0)));
    try std.testing.expect(parsed.runs[3].bg.eql(Color.rgb(88, 88, 88)));
}

test "extension ui markdown text renders heading bold list and table basics" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const node = extension_ui.UiNode{ .text = .{
        .format = .markdown,
        .text = "# Title\n\n**bold**\n\n- item\n\n| A | B |\n| --- | --- |\n| 1 | 2 |",
    } };

    var buf = try Buffer.init(std.testing.allocator, 32, 18, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());

    try std.testing.expect(try bufferContainsText(&buf, "Title"));
    try std.testing.expect(try bufferContainsText(&buf, "bold"));
    try std.testing.expect(bufferHasAttr(&buf, "bold"));
    try std.testing.expect(try bufferContainsText(&buf, "- item"));
    try std.testing.expect(try bufferContainsText(&buf, "A"));
    try std.testing.expect(try bufferContainsText(&buf, "1"));
    try std.testing.expectEqual(@as(u21, '┌'), cpAt(&buf, 0, 7));
}

test "extension ui markdown text measures multiline height and maps scroll_y" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const measured_node = extension_ui.UiNode{ .text = .{ .format = .markdown, .text = "# Title\nBody" } };
    try std.testing.expectEqual(@as(u32, 3), measureNode(&state, measured_node, 20, .wcwidth));

    // Markdown has no knobs for extension Text max_lines/scroll_x/align, but it does
    // share the vertical scroll model through scroll_y -> Markdown.scroll_offset.
    const scrolled_node = extension_ui.UiNode{ .text = .{ .format = .markdown, .text = "# Title\nBody", .scroll_y = 2, .max_lines = 1, .scroll_x = 3, .@"align" = .right } };
    var buf = try Buffer.init(std.testing.allocator, 20, 1, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, scrolled_node, buf.region());
    try std.testing.expectEqual(@as(u21, 'B'), cpAt(&buf, 0, 0));
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
    var buf = try Buffer.init(std.testing.allocator, 1, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, '▀'), cpAt(&buf, 0, 0));
    try std.testing.expect(buf.get(0, 0).fg.eql(Color.rgb(255, 0, 0)));
}

test "extension ui sorts notification views and filters status" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "status", .target = .status, .order = 0, .root = .{ .text = .{ .text = "s" } } });
    state.applyRender(.{ .state_owner_id = "b", .generation = 1, .id = "late", .target = .notification, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "z", .target = .notification, .order = 1, .root = .{ .text = .{ .text = "z" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "a", .target = .notification, .order = 1, .root = .{ .text = .{ .text = "a" } } });

    try std.testing.expect(state.hasNotificationViews());
    var buf = try Buffer.init(std.testing.allocator, 4, 3, .wcwidth);
    defer buf.deinit();
    var comp = state.notificationComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'z'), cpAt(&buf, 0, 1));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 0, 2));
}

test "extension ui remove final notification clears presence" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "toast", .target = .notification, .root = .{ .text = .{ .text = "hi" } } });
    try std.testing.expect(state.hasNotificationViews());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "toast", .target = .notification, .remove = true });
    try std.testing.expect(!state.hasNotificationViews());
}

test "extension ui sorts overlay views and filters other targets" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "status", .target = .status, .order = 0, .root = .{ .text = .{ .text = "s" } } });
    state.applyRender(.{ .state_owner_id = "b", .generation = 1, .id = "late", .target = .overlay, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "z", .target = .overlay, .order = 1, .root = .{ .text = .{ .text = "z" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "a", .target = .overlay, .order = 1, .root = .{ .text = .{ .text = "a" } } });

    try std.testing.expect(state.hasOverlayViews());
    var buf = try Buffer.init(std.testing.allocator, 4, 3, .wcwidth);
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

test "extension ui overlay focus follows top ordered view" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "background", .target = .overlay, .order = 1, .focus = true, .root = .{ .text = .{ .text = "bg" } } });
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "front", .target = .overlay, .order = 2, .focus = false, .root = .{ .text = .{ .text = "front" } } });
    try std.testing.expect(!state.targetWantsFocus(.overlay));

    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "front", .target = .overlay, .order = 2, .focus = true, .root = .{ .text = .{ .text = "front" } } });
    try std.testing.expect(state.targetWantsFocus(.overlay));
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

test "extension ui sorts editor border top views and filters other targets" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "status", .target = .status, .order = 0, .root = .{ .text = .{ .text = "s" } } });
    state.applyRender(.{ .state_owner_id = "b", .generation = 1, .id = "late", .target = .editor_border_top, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "z", .target = .editor_border_top, .order = 1, .root = .{ .text = .{ .text = "z" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "a", .target = .editor_border_top, .order = 1, .root = .{ .text = .{ .text = "a" } } });

    var buf = try Buffer.init(std.testing.allocator, 4, 3, .wcwidth);
    defer buf.deinit();
    var comp = state.editorBorderTopComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'z'), cpAt(&buf, 0, 1));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 0, 2));
}

test "extension ui renders and removes editor border bottom views" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "bottom", .target = .editor_border_bottom, .root = .{ .chip = .{ .label = "hint" } } });

    var buf = try Buffer.init(std.testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.editorBorderBottomComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, '['), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 2, 0));

    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "bottom", .target = .editor_border_bottom, .remove = true });
    try std.testing.expectEqual(@as(usize, 0), state.views.count());
    const m = comp.measure(8);
    try std.testing.expectEqual(@as(u32, 0), m.preferred_height);
}

test "extension ui text measurement uses supplied width method" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();

    const node = extension_ui.UiNode{ .text = .{ .text = "☕x", .wrap = .char } };
    try std.testing.expectEqual(@as(u32, 1), measureNode(&state, node, 2, .wcwidth));
    try std.testing.expectEqual(@as(u32, 2), measureNode(&state, node, 2, .unicode));
}

test "extension ui markdown measurement uses supplied width method" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();

    const node = extension_ui.UiNode{ .text = .{ .format = .markdown, .text = "☕x" } };
    try std.testing.expectEqual(@as(u32, 1), measureNode(&state, node, 2, .wcwidth));
    try std.testing.expectEqual(@as(u32, 2), measureNode(&state, node, 2, .unicode));
}

test "extension ui text max_lines and scroll_y affect measurement and render" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();

    const node = extension_ui.UiNode{ .text = .{ .text = "aa bb cc dd", .max_lines = 2, .scroll_y = 1 } };
    try std.testing.expectEqual(@as(u32, 2), measureNode(&state, node, 3, .wcwidth));

    var buf = try Buffer.init(std.testing.allocator, 3, 2, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());
    try std.testing.expectEqual(@as(u21, 'b'), buf.get(0, 0).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), buf.get(0, 1).grapheme.codepoint);
}

test "extension ui text wrap none measures explicit lines" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();

    const node = extension_ui.UiNode{ .text = .{ .text = "hello world\nbye", .wrap = .none } };
    try std.testing.expectEqual(@as(u32, 2), measureNode(&state, node, 5, .wcwidth));

    var buf = try Buffer.init(std.testing.allocator, 5, 2, .wcwidth);
    defer buf.deinit();
    renderNode(&state, .{ .state_owner_id = "o", .generation = 1, .id = "v" }, node, buf.region());
    try std.testing.expectEqual(@as(u21, 'o'), buf.get(4, 0).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), buf.get(0, 1).grapheme.codepoint);
}

test "extension ui wires text align and scroll_x" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .text = .{ .text = "abcdef", .wrap = .none, .@"align" = .right, .scroll_x = 4 } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .target = .status, .root = root });

    var buf = try Buffer.init(std.testing.allocator, 5, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());

    try std.testing.expectEqual(@as(u21, 'e'), cpAt(&buf, 3, 0));
    try std.testing.expectEqual(@as(u21, 'f'), cpAt(&buf, 4, 0));
}
