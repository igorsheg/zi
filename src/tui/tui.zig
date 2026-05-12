const std = @import("std");
const component_mod = @import("primitives/view.zig");
const stack_mod = @import("primitives/layout.zig");
const overlay_mod = @import("primitives/overlay.zig");
const focus_mod = @import("primitives/focus.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal/mod.zig");
const keys_mod = @import("terminal/keys.zig");
const buffer_mod = @import("primitives/surface.zig");

const Component = component_mod.Component;
const CursorState = component_mod.CursorState;
const Stack = stack_mod.Stack;
const OverlayManager = overlay_mod.OverlayManager;
const OverlayOptions = overlay_mod.OverlayOptions;
const FocusManager = focus_mod.FocusManager;
const Renderer = renderer_mod.Renderer;
const Terminal = terminal_mod.Terminal;
const Key = keys_mod.Key;
const Region = buffer_mod.Region;

pub const TUI = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    renderer: Renderer,
    root: Stack,
    focus: FocusManager = .{},
    overlays: OverlayManager,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) !TUI {
        var term = Terminal.init();
        term.updateSize();
        const rend = try Renderer.init(allocator, term.fd_out, term.width, term.height, term.capabilities.width_method);
        return .{
            .allocator = allocator,
            .terminal = term,
            .renderer = rend,
            .root = Stack.init(allocator),
            .overlays = OverlayManager.init(allocator),
        };
    }

    pub fn deinit(self: *TUI) void {
        self.overlays.deinit();
        self.root.deinit();
        self.renderer.deinit();
        self.terminal.deinit();
    }

    pub fn setFocus(self: *TUI, target: ?Component) void {
        self.focus.setFocus(target);
    }

    pub fn handleInput(self: *TUI, key: Key) bool {
        return self.focus.handleInput(key);
    }

    pub fn showOverlay(self: *TUI, comp: Component, options: OverlayOptions) OverlayHandle {
        const pre_focus = self.focus.current;
        const entry_id = self.overlays.showOverlayReturnId(comp, options, pre_focus);

        if (!options.non_capturing) {
            self.focus.setFocus(comp);
        }
        self.terminal.hideCursor();
        self.dirty = true;

        return .{ .id = entry_id, .tui = self };
    }

    pub fn hideOverlay(self: *TUI) void {
        if (self.overlays.stack.items.len == 0) return;
        const top = self.overlays.stack.items[self.overlays.stack.items.len - 1];
        const overlay_had_focus = if (self.focus.current) |focused|
            Component.eql(focused, top.component)
        else
            false;
        const result = self.overlays.hideTopmost();

        if (overlay_had_focus) {
            const top_visible = self.overlays.topmostCapturingComponent();
            self.focus.setFocus(top_visible orelse result.pre_focus);
        }
        if (self.overlays.stack.items.len == 0) self.terminal.hideCursor();
        self.dirty = true;
    }

    pub fn hasOverlay(self: *const TUI) bool {
        return self.overlays.hasVisibleOverlays();
    }

    pub fn hasCapturingOverlay(self: *const TUI) bool {
        return self.overlays.topmostCapturingComponent() != null;
    }

    pub fn width(self: *const TUI) u32 {
        return self.renderer.width;
    }

    pub fn height(self: *const TUI) u32 {
        return self.renderer.height;
    }

    pub fn requestRender(self: *TUI) void {
        self.dirty = true;
    }

    pub fn nextAnimationDeadline(self: *TUI, now_ns: i128) ?i128 {
        const suspend_root_animations = self.overlays.topmostCapturingComponent() != null;
        var next_deadline: ?i128 = if (suspend_root_animations) null else self.root.nextAnimationDeadline(now_ns);
        for (self.overlays.stack.items) |entry| {
            if (entry.hidden) continue;
            if (entry.component.nextAnimationDeadline(now_ns)) |deadline| {
                next_deadline = if (next_deadline) |cur| @min(cur, deadline) else deadline;
            }
        }
        return next_deadline;
    }

    pub fn tickAnimations(self: *TUI, now_ns: i128) bool {
        const suspend_root_animations = self.overlays.topmostCapturingComponent() != null;
        var changed = if (suspend_root_animations) false else self.root.tickAnimation(now_ns);
        for (self.overlays.stack.items) |entry| {
            if (entry.hidden) continue;
            changed = entry.component.tickAnimation(now_ns) or changed;
        }
        return changed;
    }

    pub fn render(self: *TUI) ?CursorState {
        const region = self.renderer.begin();

        {
            self.root.render(region);
            if (self.overlays.hasVisibleOverlays()) {
                self.overlays.renderOverlays(region);
            }
        }

        {
            self.renderer.end() catch {};
        }

        if (self.overlays.hasVisibleOverlays()) {
            if (self.overlayFocusCursor()) |cs| return cs;
        }
        if (self.focus.current) |focused| return self.root.cursorFor(focused);
        return null;
    }

    pub fn checkResize(self: *TUI) bool {
        self.terminal.updateSize();
        if (self.terminal.width != self.renderer.width or self.terminal.height != self.renderer.height) {
            self.renderer.resize(self.terminal.width, self.terminal.height) catch {};
            self.dirty = true;
            return true;
        }
        return false;
    }

    fn overlayFocusCursor(self: *TUI) ?CursorState {
        const focused = self.focus.current orelse return null;
        for (self.overlays.stack.items) |*entry| {
            if (entry.hidden) continue;
            if (Component.eql(entry.component, focused)) {
                const cs = focused.cursorState() orelse return null;
                const layout = overlay_mod.resolveLayout(
                    entry.options,
                    entry.component,
                    self.renderer.width,
                    self.renderer.height,
                );
                return .{
                    .x = cs.x + layout.col,
                    .y = cs.y + layout.row,
                    .style = cs.style,
                };
            }
        }
        return null;
    }
};

pub const OverlayHandle = struct {
    id: u64,
    tui: *TUI,

    pub fn hide(self: OverlayHandle) void {
        const entry = self.tui.overlays.findEntry(self.id) orelse return;
        const pre_focus = entry.pre_focus;
        const comp = entry.component;
        _ = self.tui.overlays.removeOverlay(self.id);

        if (self.tui.focus.current) |focused| {
            if (Component.eql(focused, comp)) {
                const top_visible = self.tui.overlays.topmostCapturingComponent();
                self.tui.focus.setFocus(top_visible orelse pre_focus);
            }
        }
        if (self.tui.overlays.stack.items.len == 0) self.tui.terminal.hideCursor();
        self.tui.dirty = true;
    }

    pub fn setHidden(self: OverlayHandle, hidden: bool) void {
        const entry = self.tui.overlays.findEntry(self.id) orelse return;
        if (entry.hidden == hidden) return;
        const comp = entry.component;
        const pre_focus = entry.pre_focus;
        const non_capturing = entry.options.non_capturing;
        entry.hidden = hidden;

        if (hidden) {
            if (self.tui.focus.current) |focused| {
                if (Component.eql(focused, comp)) {
                    const top_visible = self.tui.overlays.topmostCapturingComponent();
                    self.tui.focus.setFocus(top_visible orelse pre_focus);
                }
            }
        } else {
            if (!non_capturing) {
                self.tui.overlays.bumpFocusOrder(self.id);
                self.tui.focus.setFocus(comp);
            }
        }
        self.tui.dirty = true;
    }

    pub fn isHidden(self: OverlayHandle) bool {
        const entry = self.tui.overlays.findEntry(self.id) orelse return true;
        return entry.hidden;
    }

    pub fn setOptions(self: OverlayHandle, options: OverlayOptions) void {
        const entry = self.tui.overlays.findEntry(self.id) orelse return;
        entry.options = options;
        self.tui.dirty = true;
    }

    pub fn focus(self: OverlayHandle) void {
        const entry = self.tui.overlays.findEntry(self.id) orelse return;
        if (entry.hidden) return;
        const comp = entry.component;
        if (self.tui.focus.current == null or !Component.eql(self.tui.focus.current.?, comp)) {
            self.tui.focus.setFocus(comp);
        }
        self.tui.overlays.bumpFocusOrder(self.id);
        self.tui.dirty = true;
    }

    pub fn unfocus(self: OverlayHandle) void {
        const entry = self.tui.overlays.findEntry(self.id) orelse return;
        const comp = entry.component;
        if (self.tui.focus.current) |focused| {
            if (!Component.eql(focused, comp)) return;
        } else return;

        const top_visible = self.tui.overlays.topmostCapturingComponent();
        if (top_visible) |tv| {
            if (!Component.eql(tv, comp)) {
                self.tui.focus.setFocus(tv);
            } else {
                self.tui.focus.setFocus(entry.pre_focus);
            }
        } else {
            self.tui.focus.setFocus(entry.pre_focus);
        }
        self.tui.dirty = true;
    }

    pub fn isFocused(self: OverlayHandle) bool {
        const entry = self.tui.overlays.findEntry(self.id) orelse return false;
        if (self.tui.focus.current) |focused| {
            return Component.eql(focused, entry.component);
        }
        return false;
    }
};

const testing = std.testing;

const DummyComp = struct {
    focused: bool = false,
    input_count: u32 = 0,
    height: u32 = 1,

    pub fn render(_: *DummyComp, _: Region) void {}

    pub fn measure(self: *DummyComp, _: u32) component_mod.Measurement {
        return .{ .min_height = 1, .preferred_height = self.height };
    }

    pub fn handleInput(self: *DummyComp, _: Key) bool {
        self.input_count += 1;
        return true;
    }

    pub fn setFocused(self: *DummyComp, f: bool) void {
        self.focused = f;
    }

    pub fn component(self: *DummyComp) Component {
        return Component.init(DummyComp, self);
    }
};

test "FocusManager routes input to focused component" {
    var fm: FocusManager = .{};
    var comp = DummyComp{};

    try testing.expect(!fm.handleInput(.{ .code = .char, .char = 'a' }));

    fm.setFocus(comp.component());
    try testing.expect(comp.focused);
    try testing.expect(fm.handleInput(.{ .code = .char, .char = 'a' }));
    try testing.expectEqual(@as(u32, 1), comp.input_count);

    fm.setFocus(null);
    try testing.expect(!comp.focused);
}

test "FocusManager save and restore" {
    var fm: FocusManager = .{};
    var a = DummyComp{};
    var b = DummyComp{};

    fm.setFocus(a.component());
    const saved = fm.save();

    fm.setFocus(b.component());
    try testing.expect(b.focused);
    try testing.expect(!a.focused);

    fm.restore(saved);
    try testing.expect(a.focused);
    try testing.expect(!b.focused);
}

test "OverlayHandle hide restores focus" {
    var mgr = OverlayManager.init(testing.allocator);
    defer mgr.deinit();
    var root = Stack.init(testing.allocator);
    defer root.deinit();

    var editor = DummyComp{};
    var overlay_comp = DummyComp{};

    const id = mgr.showOverlayReturnId(overlay_comp.component(), .{}, editor.component());
    try testing.expectEqual(@as(usize, 1), mgr.stack.items.len);

    const pre_focus = mgr.removeOverlay(id);
    try testing.expect(pre_focus != null);
    try testing.expect(Component.eql(pre_focus.?, editor.component()));
    try testing.expectEqual(@as(usize, 0), mgr.stack.items.len);
}
