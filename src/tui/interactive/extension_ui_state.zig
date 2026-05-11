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
    contributions: std.StringHashMap(SlotContribution),
    frames: std.StringHashMap(FrameRecord),
    input_states: std.StringHashMap(TextInput),
    theme: *const Theme,
    status_component: TargetComponent,
    overlay_component: TargetComponent,
    editor_border_top_component: TargetComponent,
    editor_border_bottom_component: TargetComponent,

    pub fn init(allocator: std.mem.Allocator) ExtensionUiState {
        return .{
            .allocator = allocator,
            .contributions = std.StringHashMap(SlotContribution).init(allocator),
            .frames = std.StringHashMap(FrameRecord).init(allocator),
            .input_states = std.StringHashMap(TextInput).init(allocator),
            .theme = themes_builtin.dark(),
            .status_component = .{ .slot = .status },
            .overlay_component = .{ .slot = .overlay },
            .editor_border_top_component = .{ .slot = .editor_border_top },
            .editor_border_bottom_component = .{ .slot = .editor_border_bottom },
        };
    }

    pub fn deinit(self: *ExtensionUiState) void {
        var vit = self.contributions.iterator();
        while (vit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.contributions.deinit();

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

    pub fn hasOverlayViews(self: *ExtensionUiState) bool {
        return self.hasSlotViews(.overlay);
    }

    pub fn slotWantsFocus(self: *ExtensionUiState, slot: extension_ui.UiSlot) bool {
        return SlotPolicy.forSlot(slot).wantsFocus(self);
    }

    pub fn handleOverlayInput(self: *ExtensionUiState, key: keys_mod.Key) ?extension_ui.UiEvent {
        return SlotPolicy.forSlot(.overlay).routeInput(self, key);
    }

    pub fn matchOverlayKey(self: *ExtensionUiState, key: keys_mod.Key) ?extension_ui.UiEvent {
        return SlotPolicy.forSlot(.overlay).routeKey(self, key);
    }

    pub fn dismissTopOverlayAfterInput(self: *ExtensionUiState) bool {
        return SlotPolicy.forSlot(.overlay).dismissTopAfterInput(self);
    }

    fn hasSlotViews(self: *ExtensionUiState, slot: extension_ui.UiSlot) bool {
        return SlotPolicy.forSlot(slot).hasViews(self);
    }

    pub fn applyRender(self: *ExtensionUiState, render: extension_ui.RenderSpec) void {
        SlotContributionLifecycle.applyRender(self, render);
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

    pub fn syncOverlayOptions(self: *ExtensionUiState, slot: extension_ui.UiSlot, base: overlay_mod.OverlayOptions) overlay_mod.OverlayOptions {
        return SlotPolicy.forSlot(slot).overlayOptions(self, base);
    }

    fn orderedSlotViews(self: *ExtensionUiState, slot: extension_ui.UiSlot) ![]*SlotContribution {
        return SlotPolicy.forSlot(slot).orderedViews(self);
    }
};

const InputRef = struct {
    id: []const u8,
    value: []const u8,
    on_input: ?[]const u8,
    on_change: ?[]const u8,
    on_submit: ?[]const u8,
};

const RetainedNode = struct {
    node: extension_ui.UiNode,
    children: []RetainedNode = &.{},

    fn init(allocator: std.mem.Allocator, source: extension_ui.UiNode) !RetainedNode {
        return switch (source) {
            .view => |view| blk: {
                const id = if (view.id) |v| try allocator.dupe(u8, v) else null;
                errdefer if (id) |v| allocator.free(v);
                var style = try extension_ui.Style.clone(allocator, view.style);
                errdefer style.deinit(allocator);
                const children = try allocator.alloc(RetainedNode, view.children.len);
                var initialized: usize = 0;
                errdefer {
                    for (children[0..initialized]) |*child| child.deinit(allocator);
                    allocator.free(children);
                }
                for (view.children, 0..) |child, i| {
                    children[i] = try RetainedNode.init(allocator, child);
                    initialized += 1;
                }
                break :blk .{ .node = .{ .view = .{ .id = id, .style = style, .children = &.{} } }, .children = children };
            },
            else => .{ .node = try extension_ui.UiNode.clone(allocator, source), .children = &.{} },
        };
    }

    fn deinit(self: *RetainedNode, allocator: std.mem.Allocator) void {
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
        self.deinitPayload(allocator);
        self.* = undefined;
    }

    fn deinitPayload(self: *RetainedNode, allocator: std.mem.Allocator) void {
        switch (self.node) {
            .view => |*view| {
                if (view.id) |v| allocator.free(v);
                view.style.deinit(allocator);
            },
            else => self.node.deinit(allocator),
        }
    }

    fn firstInput(self: *const RetainedNode) ?InputRef {
        return switch (self.node) {
            .input => |input| .{ .id = input.id, .value = input.value, .on_input = input.on_input, .on_change = input.on_change, .on_submit = input.on_submit },
            .view => blk: {
                for (self.children) |*child| if (child.firstInput()) |found| break :blk found;
                break :blk null;
            },
            else => null,
        };
    }

    fn syncInputValues(self: *const RetainedNode, state: *ExtensionUiState, owner: []const u8, view_id: []const u8) void {
        switch (self.node) {
            .input => |input| syncInputState(state, owner, view_id, input.id, input.value) catch {},
            .view => for (self.children) |*child| child.syncInputValues(state, owner, view_id),
            else => {},
        }
    }
};

fn syncInputValues(self: *ExtensionUiState, record: *const SlotContribution) void {
    if (record.root) |*root| root.syncInputValues(self, record.spec.state_owner_id, record.spec.id);
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

fn clearFramesForView(self: *ExtensionUiState, owner: []const u8, view: []const u8) void {
    const prefix = std.fmt.allocPrint(self.allocator, "{s}\x1f{s}\x1f", .{ owner, view }) catch return;
    defer self.allocator.free(prefix);
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(self.allocator);
    var it = self.frames.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) keys.append(self.allocator, entry.key_ptr.*) catch break;
    }
    for (keys.items) |k| {
        var old = self.frames.fetchRemove(k) orelse continue;
        self.allocator.free(old.key);
        old.value.deinit(self.allocator);
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

const SlotContributionKey = struct {
    owner: []const u8,
    view: []const u8,

    fn fromRender(render: extension_ui.RenderSpec) SlotContributionKey {
        return .{ .owner = render.state_owner_id, .view = render.id };
    }

    fn alloc(self: SlotContributionKey, allocator: std.mem.Allocator) ![]const u8 {
        return makeViewKey(allocator, self.owner, self.view);
    }
};

const SlotContribution = struct {
    spec: extension_ui.RenderSpec,
    root: ?RetainedNode = null,

    fn init(allocator: std.mem.Allocator, spec: extension_ui.RenderSpec) !SlotContribution {
        var cloned = try extension_ui.RenderSpec.clone(allocator, spec);
        errdefer cloned.deinit(allocator);
        const root = if (spec.root) |source| try RetainedNode.init(allocator, source) else null;
        errdefer if (root) |*r| {
            var owned = r.*;
            owned.deinit(allocator);
        };
        if (cloned.root) |*old_root| old_root.deinit(allocator);
        cloned.root = null;
        return .{ .spec = cloned, .root = root };
    }

    fn deinit(self: *SlotContribution, allocator: std.mem.Allocator) void {
        self.spec.deinit(allocator);
        if (self.root) |*root| root.deinit(allocator);
    }
};

const SlotContributionLifecycle = struct {
    fn applyRender(state: *ExtensionUiState, render: extension_ui.RenderSpec) void {
        const contribution_key = SlotContributionKey.fromRender(render);
        const key = contribution_key.alloc(state.allocator) catch return;
        if (state.contributions.getEntry(key)) |entry| {
            if (render.generation < entry.value_ptr.spec.generation) {
                state.allocator.free(key);
                return;
            }
            if (render.remove) {
                removeExisting(state, entry.key_ptr.*);
                state.allocator.free(key);
                return;
            }
            replaceExisting(state, entry.value_ptr, render);
            state.allocator.free(key);
            return;
        }

        if (render.remove) {
            state.allocator.free(key);
            return;
        }
        insertNew(state, key, render);
    }

    fn removeExisting(state: *ExtensionUiState, key: []const u8) void {
        var old = state.contributions.fetchRemove(key) orelse return;
        clearInputValuesForView(state, old.value.spec.state_owner_id, old.value.spec.id);
        clearFramesForView(state, old.value.spec.state_owner_id, old.value.spec.id);
        state.allocator.free(old.key);
        old.value.deinit(state.allocator);
    }

    fn replaceExisting(state: *ExtensionUiState, existing: *SlotContribution, render: extension_ui.RenderSpec) void {
        var render_for_clone = render;
        if (render_for_clone.notification) |*n| {
            if (existing.spec.notification) |old| {
                n.created_ns = old.created_ns;
                n.count = if (std.mem.eql(u8, n.message, old.message)) old.count + 1 else 1;
            }
        }
        const record = SlotContribution.init(state.allocator, render_for_clone) catch return;
        clearFramesForView(state, existing.spec.state_owner_id, existing.spec.id);
        existing.deinit(state.allocator);
        existing.* = record;
        syncInputValues(state, existing);
    }

    fn insertNew(state: *ExtensionUiState, key: []const u8, render: extension_ui.RenderSpec) void {
        const record = SlotContribution.init(state.allocator, render) catch {
            state.allocator.free(key);
            return;
        };
        state.contributions.put(key, record) catch {
            var owned = record;
            owned.deinit(state.allocator);
            state.allocator.free(key);
            return;
        };
        if (state.contributions.getPtr(key)) |stored| syncInputValues(state, stored);
    }
};

const FrameRecord = struct {
    frame: extension_ui.UiFrame,
    fn deinit(self: *FrameRecord, allocator: std.mem.Allocator) void {
        self.frame.deinit(allocator);
    }
};

const SlotPolicy = struct {
    slot: extension_ui.UiSlot,

    fn forSlot(slot: extension_ui.UiSlot) SlotPolicy {
        return .{ .slot = slot };
    }

    fn orderedViews(self: SlotPolicy, state: *ExtensionUiState) ![]*SlotContribution {
        var list = std.ArrayList(*SlotContribution).empty;
        errdefer list.deinit(state.allocator);
        var it = state.contributions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.spec.slot == self.slot and entry.value_ptr.root != null) {
                try list.append(state.allocator, entry.value_ptr);
            }
        }
        std.mem.sort(*SlotContribution, list.items, {}, lessView);
        return list.toOwnedSlice(state.allocator);
    }

    fn hasViews(self: SlotPolicy, state: *ExtensionUiState) bool {
        var it = state.contributions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.spec.slot == self.slot and entry.value_ptr.root != null) return true;
        }
        return false;
    }

    fn topView(self: SlotPolicy, state: *ExtensionUiState) ?*SlotContribution {
        const ordered = self.orderedViews(state) catch return null;
        defer state.allocator.free(ordered);
        if (ordered.len == 0) return null;
        return ordered[ordered.len - 1];
    }

    fn wantsFocus(self: SlotPolicy, state: *ExtensionUiState) bool {
        const top = self.topView(state) orelse return false;
        return self.slot == .overlay and top.spec.focus;
    }

    fn overlayOptions(self: SlotPolicy, state: *ExtensionUiState, base: overlay_mod.OverlayOptions) overlay_mod.OverlayOptions {
        var options = base;
        const top = self.topView(state) orelse return options;
        applySlotOptions(&options, top.spec.slot_options);
        return options;
    }

    fn routeInput(self: SlotPolicy, state: *ExtensionUiState, key: keys_mod.Key) ?extension_ui.UiEvent {
        if (self.slot != .overlay) return null;
        const top = self.topView(state) orelse return null;
        const spec = top.spec;
        if (!spec.focus) return null;
        const input = (top.root orelse return null).firstInput() orelse return null;
        return editInput(state, spec, input, key) catch null;
    }

    fn routeKey(self: SlotPolicy, state: *ExtensionUiState, key: keys_mod.Key) ?extension_ui.UiEvent {
        if (self.slot != .overlay) return null;
        const top = self.topView(state) orelse return null;
        const spec = top.spec;
        if (!spec.focus) return null;
        for (spec.keys) |binding| {
            const parsed = keys_mod.parseKeySpec(binding.key) catch continue;
            if (!parsed.eql(key)) continue;
            return .{ .state_owner_id = spec.state_owner_id, .generation = spec.generation, .view = spec.id, .type = .key, .action = binding.action, .key = binding.key, .ctrl = key.ctrl, .alt = key.alt, .shift = key.shift };
        }
        return null;
    }

    fn dismissTopAfterInput(self: SlotPolicy, state: *ExtensionUiState) bool {
        if (self.slot != .overlay) return false;
        const top = self.topView(state) orelse return false;
        if (top.spec.slot_options.lifetime != .until_input) return false;
        const contribution_key = SlotContributionKey{ .owner = top.spec.state_owner_id, .view = top.spec.id };
        const key = contribution_key.alloc(state.allocator) catch return false;
        defer state.allocator.free(key);
        SlotContributionLifecycle.removeExisting(state, key);
        return true;
    }
};

const TargetComponent = struct {
    state: *ExtensionUiState = undefined,
    slot: extension_ui.UiSlot,
    width_method: WidthMethod = .wcwidth,

    fn component(self: *TargetComponent) Component {
        return Component.init(TargetComponent, self);
    }

    pub fn render(self: *TargetComponent, region: Region) void {
        self.width_method = region.buf.width_method;
        const ordered = self.orderedViews() catch return;
        defer self.state.allocator.free(ordered);
        var y: u32 = 0;
        for (ordered) |view| {
            if (y >= region.height) break;
            const root = if (view.root) |*root| root else continue;
            const h = @min(measureNode(self.state, root.*, region.width, region.buf.width_method), region.height - y);
            var layout = layoutNode(self.state, root, .{ .x = 0, .y = y, .width = region.width, .height = h }, region.buf.width_method) catch continue;
            defer layout.deinit(self.state.allocator);
            paintLayout(self.state, view.spec, layout, region);
            y += h;
        }
    }

    pub fn measure(self: *TargetComponent, width: u32) Measurement {
        const ordered = self.orderedViews() catch return .{ .min_height = 0, .preferred_height = 0 };
        defer self.state.allocator.free(ordered);
        var total: u32 = 0;
        for (ordered) |view| {
            if (view.root) |root| total += measureNode(self.state, root, width, self.width_method);
        }
        return .{ .min_height = if (total > 0) 1 else 0, .preferred_height = total };
    }

    fn orderedViews(self: *TargetComponent) ![]*SlotContribution {
        return self.state.orderedSlotViews(self.slot);
    }
};

fn applySlotOptions(options: *overlay_mod.OverlayOptions, slot: extension_ui.UiSlotOptions) void {
    if (slot.preset) |preset| options.* = preset.options(.{});
    if (slot.width) |v| applyWidth(options, v);
    // Current overlay manager does not expose exact height; use height as a max-height constraint.
    if (slot.height) |v| applyMaxHeight(options, v);
    if (slot.min_width) |v| {
        if (fixedConstraint(v)) |n| options.min_width = n;
    }
    // max_width is parsed and retained for v3, but OverlayOptions has no max_width field yet.
    if (slot.max_height) |v| applyMaxHeight(options, v);
    if (slot.anchor) |v| options.anchor = toOverlayAnchor(v);
    if (slot.backdrop) |v| options.backdrop = toOverlayBackdrop(v);
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

fn lessView(_: void, a: *SlotContribution, b: *SlotContribution) bool {
    if (a.spec.order != b.spec.order) return a.spec.order < b.spec.order;
    const owner_cmp = std.mem.order(u8, a.spec.state_owner_id, b.spec.state_owner_id);
    if (owner_cmp != .eq) return owner_cmp == .lt;
    return std.mem.order(u8, a.spec.id, b.spec.id) == .lt;
}

const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

fn measureNode(state: *ExtensionUiState, node: RetainedNode, width: u32, width_method: WidthMethod) u32 {
    return switch (node.node) {
        .text => |t| measureText(state, t, width, width_method),
        .chip => 1,
        .progress => 1,
        .separator => 1,
        .surface => |s| constraintHeight(s.style.height) orelse 1,
        .input => 1,
        .view => |b| measureView(state, b, node.children, width, width_method),
    };
}

fn measureView(state: *ExtensionUiState, b: extension_ui.UiNode.View, children: []const RetainedNode, width: u32, width_method: WidthMethod) u32 {
    const border: u32 = if (hasFrameChrome(b.style.chrome)) 1 else 0;
    const pad_v = edge(b.style.padding.top) + edge(b.style.padding.bottom);
    const pad_h = edge(b.style.padding.left) + edge(b.style.padding.right);
    const child_width = width -| (border * 2 + pad_h);
    var content: u32 = 0;
    if (children.len == 0) {
        content = 0;
    } else if (b.style.flex_direction == .row) {
        for (children) |child| content = @max(content, measureNode(state, child, child_width, width_method));
    } else {
        for (children, 0..) |child, i| {
            content += measureNode(state, child, child_width, width_method);
            if (i + 1 < children.len) content += edge(b.style.gap);
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

const LayoutBox = struct {
    node: *const RetainedNode,
    rect: Rect,
    children: []LayoutBox = &.{},

    fn deinit(self: *LayoutBox, allocator: std.mem.Allocator) void {
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
        self.* = undefined;
    }
};

fn layoutNode(state: *ExtensionUiState, node: *const RetainedNode, rect: Rect, width_method: WidthMethod) !LayoutBox {
    if (rect.width == 0 or rect.height == 0) return .{ .node = node, .rect = rect };
    return switch (node.node) {
        .view => |view| try layoutView(state, node, view, node.children, rect, width_method),
        else => .{ .node = node, .rect = rect },
    };
}

fn layoutView(state: *ExtensionUiState, node: *const RetainedNode, view: extension_ui.UiNode.View, children: []const RetainedNode, rect: Rect, width_method: WidthMethod) !LayoutBox {
    const inner = viewInnerRect(view, rect);
    const child_boxes = if (children.len == 0 or inner.width == 0 or inner.height == 0)
        &.{}
    else if (view.style.flex_direction == .row)
        try layoutRow(state, view, children, inner, width_method)
    else
        try layoutColumn(state, view, children, inner, width_method);
    return .{ .node = node, .rect = rect, .children = child_boxes };
}

fn viewInnerRect(view: extension_ui.UiNode.View, rect: Rect) Rect {
    var inner = rect;
    const border: u32 = if (hasFrameChrome(view.style.chrome)) 1 else 0;
    inner.x +|= @min(border, inner.width);
    inner.y +|= @min(border, inner.height);
    inner.width = inner.width -| border * 2;
    inner.height = inner.height -| border * 2;
    const pl = edge(view.style.padding.left);
    const pr = edge(view.style.padding.right);
    const pt = edge(view.style.padding.top);
    const pb = edge(view.style.padding.bottom);
    inner.x +|= @min(pl, inner.width);
    inner.y +|= @min(pt, inner.height);
    inner.width = inner.width -| pl -| pr;
    inner.height = inner.height -| pt -| pb;
    return inner;
}

fn layoutColumn(state: *ExtensionUiState, b: extension_ui.UiNode.View, children: []const RetainedNode, region: Rect, width_method: WidthMethod) ![]LayoutBox {
    var boxes = std.ArrayList(LayoutBox).empty;
    errdefer {
        for (boxes.items) |*box| box.deinit(state.allocator);
        boxes.deinit(state.allocator);
    }
    const gap = edge(b.style.gap);
    const total_gap = gap *| @as(u32, @intCast(if (children.len > 0) children.len - 1 else 0));
    const avail = region.height -| total_gap;
    var fixed: u32 = 0;
    var grow_sum: f32 = 0;
    for (children) |child| {
        const grow = nodeStyle(child).flex_grow;
        if (grow > 0) grow_sum += grow else fixed += resolveHeight(state, child, region.width, avail, width_method);
    }
    const remaining = avail -| fixed;
    const used = if (grow_sum > 0) region.height else fixed + total_gap;
    var y = justifyOffset(b.style.justify, region.height, used);
    const extra_gap = justifyExtraGap(b.style.justify, region.height, used, children.len);
    for (children, 0..) |child, i| {
        if (y >= region.height) break;
        const grow = nodeStyle(child).flex_grow;
        const desired = if (grow > 0 and grow_sum > 0) @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(remaining)) * grow / grow_sum))) else resolveHeight(state, child, region.width, region.height - y, width_method);
        const h = @min(desired, region.height - y);
        const child_w = crossWidth(child, region.width);
        const x = alignOffset(b.style.alignment, region.width, child_w);
        try boxes.append(state.allocator, try layoutNode(state, &children[i], .{ .x = region.x + x, .y = region.y + y, .width = @min(child_w, region.width - x), .height = h }, width_method));
        y += h;
        if (i + 1 < children.len) y +|= gap + extra_gap;
    }
    return boxes.toOwnedSlice(state.allocator);
}

fn layoutRow(state: *ExtensionUiState, b: extension_ui.UiNode.View, children: []const RetainedNode, region: Rect, width_method: WidthMethod) ![]LayoutBox {
    var boxes = std.ArrayList(LayoutBox).empty;
    errdefer {
        for (boxes.items) |*box| box.deinit(state.allocator);
        boxes.deinit(state.allocator);
    }
    const gap = edge(b.style.gap);
    const total_gap = gap *| @as(u32, @intCast(if (children.len > 0) children.len - 1 else 0));
    const avail = region.width -| total_gap;
    var fixed: u32 = 0;
    var grow_sum: f32 = 0;
    for (children) |child| {
        const grow = nodeStyle(child).flex_grow;
        if (grow > 0) grow_sum += grow else if (widthConstraint(child)) |w| fixed += resolveConstraint(w, avail) else fixed += measureNode(state, child, avail, width_method);
    }
    const remaining = avail -| fixed;
    const used = if (grow_sum > 0) region.width else fixed + total_gap;
    var x = justifyOffset(b.style.justify, region.width, used);
    const extra_gap = justifyExtraGap(b.style.justify, region.width, used, children.len);
    for (children, 0..) |child, i| {
        if (x >= region.width) break;
        const grow = nodeStyle(child).flex_grow;
        const desired = if (grow > 0 and grow_sum > 0) @as(u32, @intFromFloat(@floor(@as(f32, @floatFromInt(remaining)) * grow / grow_sum))) else if (widthConstraint(child)) |cw| resolveConstraint(cw, avail) else measureNode(state, child, avail, width_method);
        const w = @min(desired, region.width - x);
        const child_h = crossHeight(child, region.height);
        const y = alignOffset(b.style.alignment, region.height, child_h);
        try boxes.append(state.allocator, try layoutNode(state, &children[i], .{ .x = region.x + x, .y = region.y + y, .width = w, .height = @min(child_h, region.height - y) }, width_method));
        x += w;
        if (i + 1 < children.len) x +|= gap + extra_gap;
    }
    return boxes.toOwnedSlice(state.allocator);
}

fn renderNode(state: *ExtensionUiState, view: extension_ui.RenderSpec, node: extension_ui.UiNode, region: Region) void {
    var retained = RetainedNode.init(state.allocator, node) catch return;
    defer retained.deinit(state.allocator);
    var layout = layoutNode(state, &retained, .{ .x = 0, .y = 0, .width = region.width, .height = region.height }, region.buf.width_method) catch return;
    defer layout.deinit(state.allocator);
    paintLayout(state, view, layout, region);
}

fn measureUiNode(state: *ExtensionUiState, node: extension_ui.UiNode, width: u32, width_method: WidthMethod) u32 {
    var retained = RetainedNode.init(state.allocator, node) catch return 0;
    defer retained.deinit(state.allocator);
    return measureNode(state, retained, width, width_method);
}

fn paintLayout(state: *ExtensionUiState, view: extension_ui.RenderSpec, box: LayoutBox, root_region: Region) void {
    if (box.rect.width == 0 or box.rect.height == 0) return;
    const region = root_region.sub(@min(box.rect.x, root_region.width), @min(box.rect.y, root_region.height), @min(box.rect.width, root_region.width -| box.rect.x), @min(box.rect.height, root_region.height -| box.rect.y));
    switch (box.node.node) {
        .text => |t| renderText(state, region, t),
        .chip => |ch| renderChip(state, region, ch.label),
        .progress => |pr| renderProgress(state, region, pr),
        .separator => |sep| renderSeparator(state, region, sep),
        .surface => |s| if (state.findFrame(view.state_owner_id, view.id, s.id)) |frame| {
            if (frame.generation >= view.generation) framebuffer_surface_mod.renderFrame(region, frame, 0);
        },
        .input => |input| renderInput(state, view, region, input),
        .view => |v| {
            _ = renderChrome(state, v.style.chrome, region);
            for (box.children) |child| paintLayout(state, view, child, root_region);
        },
    }
}

fn nodeStyle(node: RetainedNode) extension_ui.Style {
    return switch (node.node) {
        .view => |v| v.style,
        .text => |t| t.style,
        .chip => |c| c.style,
        .progress => |p| p.style,
        .separator => |s| s.style,
        .surface => |s| s.style,
        .input => |i| i.style,
    };
}

fn justifyOffset(justify: extension_ui.Justify, container: u32, used: u32) u32 {
    if (used >= container) return 0;
    const extra = container - used;
    return switch (justify) {
        .start, .space_between => 0,
        .center => extra / 2,
        .end => extra,
    };
}

fn justifyExtraGap(justify: extension_ui.Justify, container: u32, used: u32, child_count: usize) u32 {
    if (justify != .space_between or child_count < 2 or used >= container) return 0;
    return (container - used) / @as(u32, @intCast(child_count - 1));
}

fn alignOffset(alignment: extension_ui.Align, container: u32, child: u32) u32 {
    if (child >= container) return 0;
    const extra = container - child;
    return switch (alignment) {
        .start, .stretch => 0,
        .center => extra / 2,
        .end => extra,
    };
}

fn crossWidth(node: RetainedNode, container: u32) u32 {
    if (nodeStyle(node).alignment == .stretch) return container;
    return if (widthConstraint(node)) |w| @min(resolveConstraint(w, container), container) else container;
}

fn crossHeight(node: RetainedNode, container: u32) u32 {
    if (nodeStyle(node).alignment == .stretch) return container;
    return if (nodeStyle(node).height) |h| @min(resolveConstraint(h, container), container) else container;
}

fn resolveHeight(state: *ExtensionUiState, node: RetainedNode, width: u32, avail: u32, width_method: WidthMethod) u32 {
    const c = switch (node.node) {
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

fn widthConstraint(node: RetainedNode) ?extension_ui.Constraint {
    return switch (node.node) {
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

fn renderChip(state: *ExtensionUiState, region: Region, label: []const u8) void {
    const theme = state.activeTheme();
    const chrome = theme.fg(.border_muted);
    const fg = theme.fg(.text);
    _ = region.writeStr(0, 0, "[ ", chrome, Color.default, Attributes.none);
    if (region.width > 2) _ = region.writeStr(2, 0, label, fg, Color.default, Attributes.none);
    const close_x = @min(@as(u32, @intCast(label.len)) + 2, region.width - 1);
    if (close_x + 1 < region.width) _ = region.writeStr(close_x, 0, " ]", chrome, Color.default, Attributes.none);
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

fn renderProgress(state: *ExtensionUiState, region: Region, pr: extension_ui.UiNode.Progress) void {
    if (pr.value) |value| {
        if (region.width < 3) return;
        const pct = @max(0, @min(value, 1));
        const inner = region.width - 2;
        const filled: u32 = @intFromFloat(@as(f32, @floatFromInt(inner)) * pct);
        const theme = state.activeTheme();
        const chrome = theme.fg(.border_muted);
        const filled_fg = theme.fg(.accent);
        const empty_fg = theme.fg(.dim);
        region.set(0, 0, charCell('[', chrome, Color.default, Attributes.none));
        var x: u32 = 0;
        while (x < inner) : (x += 1) {
            const fg = if (x < filled) filled_fg else empty_fg;
            region.set(x + 1, 0, charCell(if (x < filled) '█' else ' ', fg, Color.default, Attributes.none));
        }
        region.set(region.width - 1, 0, charCell(']', chrome, Color.default, Attributes.none));
    } else if (pr.label) |label| {
        var text = TextComponent.init(state.allocator, region.buf.width_method);
        defer text.deinit();
        text.content = label;
        text.wrap_mode = .none;
        text.overflow = .ellipsis;
        text.max_lines = 1;
        text.render(region);
    }
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
    try std.testing.expectEqual(@as(usize, 0), state.contributions.count());

    const root = extension_ui.UiNode{ .text = .{ .text = "new" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .slot = .status, .root = root });
    try std.testing.expectEqual(@as(usize, 1), state.contributions.count());

    const stale = extension_ui.UiNode{ .text = .{ .text = "old" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = stale });
    const rec = state.contributions.get("owner\x1fview").?;
    try std.testing.expectEqualStrings("new", rec.root.?.node.text.text);

    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .remove = true });
    try std.testing.expectEqual(@as(usize, 1), state.contributions.count());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 3, .id = "view", .remove = true });
    try std.testing.expectEqual(@as(usize, 0), state.contributions.count());
}

test "extension ui edits focused overlay input and emits structured events" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .input = .{ .id = "filter", .value = "z", .placeholder = "Filter", .on_input = "input", .on_change = "changed", .on_submit = "submitted" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .overlay, .focus = true, .root = root });

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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .overlay, .focus = true, .root = .{ .input = .{ .id = "filter", .value = "a" } } });
    _ = state.handleOverlayInput(.{ .code = .char, .char = 'b' }).?;
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .slot = .overlay, .focus = true, .root = .{ .input = .{ .id = "filter", .value = "server" } } });
    const submitted = state.handleOverlayInput(.{ .code = .enter }).?;
    try std.testing.expectEqualStrings("server", submitted.value.?);
}

test "extension ui renders text" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .text = .{ .text = "hello" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 10, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'o'), cpAt(&buf, 4, 0));
}

test "extension ui row justify center honors retained layout" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const a = extension_ui.UiNode{ .text = .{ .text = "a", .style = .{ .width = .{ .fixed = 1 } } } };
    const b = extension_ui.UiNode{ .text = .{ .text = "b", .style = .{ .width = .{ .fixed = 1 } } } };
    const children = [_]extension_ui.UiNode{ a, b };
    const root = extension_ui.UiNode{ .view = .{ .style = .{ .flex_direction = .row, .justify = .center }, .children = @constCast(&children) } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 6, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 2, 0));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 3, 0));
}

test "extension ui row flex grow consumes remaining width before justify" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const a = extension_ui.UiNode{ .text = .{ .text = "a", .style = .{ .width = .{ .fixed = 1 } } } };
    const b = extension_ui.UiNode{ .text = .{ .text = "b", .style = .{ .flex_grow = 1 } } };
    const children = [_]extension_ui.UiNode{ a, b };
    const root = extension_ui.UiNode{ .view = .{ .style = .{ .flex_direction = .row, .justify = .end }, .children = @constCast(&children) } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });
    var buf = try Buffer.init(std.testing.allocator, 6, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'a'), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'b'), cpAt(&buf, 1, 0));
}

test "extension ui measures and renders multiline text" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const root = extension_ui.UiNode{ .text = .{ .text = "hello\nworld" } };
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });

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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });

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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });
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
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "b", .slot = .status, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "a", .slot = .status, .order = 1, .root = .{ .text = .{ .text = "a" } } });
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "c", .slot = .status, .order = 1, .root = .{ .text = .{ .text = "c" } } });
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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });
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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });
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
    try std.testing.expectEqual(@as(u32, 2), measureUiNode(&state, node, 3, .wcwidth));
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
    try std.testing.expectEqual(@as(u32, 1), measureUiNode(&state, node, 3, .wcwidth));

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
    try std.testing.expectEqual(@as(u32, 3), measureUiNode(&state, measured_node, 20, .wcwidth));

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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .slot = .status, .root = root });
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

test "extension ui contribution removal clears owned frames" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = .{ .surface = .{ .id = "node" } } });
    const red = [_]u8{ 255, 0, 0, 255 };
    state.applyFrame(.{ .state_owner_id = "owner", .generation = 1, .view = "view", .node = "node", .width = 1, .height = 1, .data = &red });
    try std.testing.expectEqual(@as(usize, 1), state.frames.count());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .remove = true });
    try std.testing.expectEqual(@as(usize, 0), state.frames.count());
}

test "extension ui contribution replacement clears stale frames" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = .{ .surface = .{ .id = "old" } } });
    const red = [_]u8{ 255, 0, 0, 255 };
    state.applyFrame(.{ .state_owner_id = "owner", .generation = 1, .view = "view", .node = "old", .width = 1, .height = 1, .data = &red });
    try std.testing.expectEqual(@as(usize, 1), state.frames.count());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "view", .slot = .status, .root = .{ .text = .{ .text = "new" } } });
    try std.testing.expectEqual(@as(usize, 0), state.frames.count());
}

test "extension ui sorts overlay views and filters other slots" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "status", .slot = .status, .order = 0, .root = .{ .text = .{ .text = "s" } } });
    state.applyRender(.{ .state_owner_id = "b", .generation = 1, .id = "late", .slot = .overlay, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "z", .slot = .overlay, .order = 1, .root = .{ .text = .{ .text = "z" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "a", .slot = .overlay, .order = 1, .root = .{ .text = .{ .text = "a" } } });

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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "overlay", .slot = .overlay, .root = .{ .text = .{ .text = "hi" } } });
    try std.testing.expect(state.hasOverlayViews());
    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "overlay", .slot = .overlay, .remove = true });
    try std.testing.expect(!state.hasOverlayViews());
}

test "extension ui overlay focus follows top ordered view" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "background", .slot = .overlay, .order = 1, .focus = true, .root = .{ .text = .{ .text = "bg" } } });
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "front", .slot = .overlay, .order = 2, .focus = false, .root = .{ .text = .{ .text = "front" } } });
    try std.testing.expect(!state.slotWantsFocus(.overlay));

    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "front", .slot = .overlay, .order = 2, .focus = true, .root = .{ .text = .{ .text = "front" } } });
    try std.testing.expect(state.slotWantsFocus(.overlay));
}

test "extension ui overlay input routes only to top focused view" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "background", .slot = .overlay, .order = 1, .focus = true, .root = .{ .input = .{ .id = "bg", .value = "a", .on_input = "bg-input" } } });
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "front", .slot = .overlay, .order = 2, .focus = false, .root = .{ .text = .{ .text = "front" } } });
    try std.testing.expect(state.handleOverlayInput(.{ .code = .char, .char = 'x' }) == null);

    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "front", .slot = .overlay, .order = 2, .focus = true, .root = .{ .input = .{ .id = "front", .value = "z", .on_input = "front-input" } } });
    const event = state.handleOverlayInput(.{ .code = .char, .char = 'i' }).?;
    try std.testing.expectEqualStrings("front", event.view);
    try std.testing.expectEqualStrings("front", event.node.?);
    try std.testing.expectEqualStrings("zi", event.value.?);
}

test "extension ui overlay key routes only to top focused view" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const lower_keys = [_]extension_ui.KeyBinding{.{ .key = "escape", .action = "lower-close" }};
    const upper_keys = [_]extension_ui.KeyBinding{.{ .key = "escape", .action = "upper-close" }};
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "lower", .slot = .overlay, .order = 1, .focus = true, .root = .{ .text = .{ .text = "lower" } }, .keys = @constCast(&lower_keys) });
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "upper", .slot = .overlay, .order = 2, .focus = false, .root = .{ .text = .{ .text = "upper" } }, .keys = @constCast(&upper_keys) });
    try std.testing.expect(state.matchOverlayKey(.{ .code = .escape }) == null);

    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "upper", .slot = .overlay, .order = 2, .focus = true, .root = .{ .text = .{ .text = "upper" } }, .keys = @constCast(&upper_keys) });
    const event = state.matchOverlayKey(.{ .code = .escape }).?;
    try std.testing.expectEqualStrings("upper", event.view);
    try std.testing.expectEqualStrings("upper-close", event.action.?);
}

test "extension ui until_input lifetime dismisses after routed input" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "overlay", .slot = .overlay, .slot_options = .{ .lifetime = .until_input }, .focus = true, .root = .{ .input = .{ .id = "input", .value = "a", .on_input = "input" } } });
    const event = state.handleOverlayInput(.{ .code = .char, .char = 'b' }).?;
    try std.testing.expectEqualStrings("ab", event.value.?);
    try std.testing.expect(state.dismissTopOverlayAfterInput());
    try std.testing.expect(!state.hasOverlayViews());
}

test "extension ui manual lifetime survives routed key" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    const keys = [_]extension_ui.KeyBinding{.{ .key = "escape", .action = "close" }};
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "overlay", .slot = .overlay, .slot_options = .{ .lifetime = .manual }, .focus = true, .root = .{ .text = .{ .text = "hi" } }, .keys = @constCast(&keys) });
    _ = state.matchOverlayKey(.{ .code = .escape }).?;
    try std.testing.expect(!state.dismissTopOverlayAfterInput());
    try std.testing.expect(state.hasOverlayViews());
}

test "extension ui maps retained overlay slot options" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();
    state.applyRender(.{
        .state_owner_id = "owner",
        .generation = 1,
        .id = "overlay",
        .slot = .overlay,
        .slot_options = .{ .width = .{ .percent = 92 }, .max_height = .{ .percent = 90 }, .anchor = .center, .backdrop = .dim },
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
    state.applyRender(.{ .state_owner_id = "o", .generation = 1, .id = "status", .slot = .status, .order = 0, .root = .{ .text = .{ .text = "s" } } });
    state.applyRender(.{ .state_owner_id = "b", .generation = 1, .id = "late", .slot = .editor_border_top, .order = 2, .root = .{ .text = .{ .text = "b" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "z", .slot = .editor_border_top, .order = 1, .root = .{ .text = .{ .text = "z" } } });
    state.applyRender(.{ .state_owner_id = "a", .generation = 1, .id = "a", .slot = .editor_border_top, .order = 1, .root = .{ .text = .{ .text = "a" } } });

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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "bottom", .slot = .editor_border_bottom, .root = .{ .chip = .{ .label = "hint" } } });

    var buf = try Buffer.init(std.testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.editorBorderBottomComponent();
    comp.render(buf.region());
    try std.testing.expectEqual(@as(u21, '['), cpAt(&buf, 0, 0));
    try std.testing.expectEqual(@as(u21, 'h'), cpAt(&buf, 2, 0));

    state.applyRender(.{ .state_owner_id = "owner", .generation = 2, .id = "bottom", .slot = .editor_border_bottom, .remove = true });
    try std.testing.expectEqual(@as(usize, 0), state.contributions.count());
    const m = comp.measure(8);
    try std.testing.expectEqual(@as(u32, 0), m.preferred_height);
}

test "extension ui text measurement uses supplied width method" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();

    const node = extension_ui.UiNode{ .text = .{ .text = "☕x", .wrap = .char } };
    try std.testing.expectEqual(@as(u32, 1), measureUiNode(&state, node, 2, .wcwidth));
    try std.testing.expectEqual(@as(u32, 2), measureUiNode(&state, node, 2, .unicode));
}

test "extension ui markdown measurement uses supplied width method" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();

    const node = extension_ui.UiNode{ .text = .{ .format = .markdown, .text = "☕x" } };
    try std.testing.expectEqual(@as(u32, 1), measureUiNode(&state, node, 2, .wcwidth));
    try std.testing.expectEqual(@as(u32, 2), measureUiNode(&state, node, 2, .unicode));
}

test "extension ui text max_lines and scroll_y affect measurement and render" {
    var state = ExtensionUiState.init(std.testing.allocator);
    defer state.deinit();

    const node = extension_ui.UiNode{ .text = .{ .text = "aa bb cc dd", .max_lines = 2, .scroll_y = 1 } };
    try std.testing.expectEqual(@as(u32, 2), measureUiNode(&state, node, 3, .wcwidth));

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
    try std.testing.expectEqual(@as(u32, 2), measureUiNode(&state, node, 5, .wcwidth));

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
    state.applyRender(.{ .state_owner_id = "owner", .generation = 1, .id = "view", .slot = .status, .root = root });

    var buf = try Buffer.init(std.testing.allocator, 5, 1, .wcwidth);
    defer buf.deinit();
    var comp = state.statusComponent();
    comp.render(buf.region());

    try std.testing.expectEqual(@as(u21, 'e'), cpAt(&buf, 3, 0));
    try std.testing.expectEqual(@as(u21, 'f'), cpAt(&buf, 4, 0));
}
