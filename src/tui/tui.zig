const std = @import("std");
const component_mod = @import("component.zig");
const container_mod = @import("container.zig");
const overlay_mod = @import("overlay.zig");
const renderer_mod = @import("renderer.zig");
const terminal_mod = @import("terminal.zig");
const keys_mod = @import("keys.zig");
const buffer_mod = @import("buffer.zig");

const Component = component_mod.Component;
const CursorState = component_mod.CursorState;
const Container = container_mod.Container;
const OverlayManager = overlay_mod.OverlayManager;
const OverlayOptions = overlay_mod.OverlayOptions;
const Renderer = renderer_mod.Renderer;
const Terminal = terminal_mod.Terminal;
const Key = keys_mod.Key;
const Region = buffer_mod.Region;

/// Reusable TUI infrastructure — terminal, renderer, focus, overlays, layout tree.
///
/// Matches pi-mono's TUI class (packages/tui/src/tui.ts):
///   setFocus, showOverlay, hideOverlay, requestRender, handleInput, addChild.
///
/// Interactive mode composes this with domain-specific state (editor, transcript,
/// agent thread, event queue). Extensions interact through this interface.
///
/// Focus/cursor split:
///   - FocusManager is source of truth for input routing and focus state.
///   - Container.focused_child_index is for cursor y-offset translation ONLY.
///   - Overlay cursor bypasses the container tree (resolved from overlay layout).
pub const TUI = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    renderer: Renderer,
    root: Container,
    focus: FocusManager = .{},
    overlays: OverlayManager,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) !TUI {
        var term = Terminal.init();
        term.updateSize();
        const rend = try Renderer.init(allocator, term.fd_out, term.width, term.height);
        return .{
            .allocator = allocator,
            .terminal = term,
            .renderer = rend,
            .root = Container.init(allocator),
            .overlays = OverlayManager.init(allocator),
        };
    }

    pub fn deinit(self: *TUI) void {
        self.overlays.deinit();
        self.root.deinit();
        self.renderer.deinit();
        self.terminal.deinit();
    }

    // ── Focus ─────────────────────────────────────────────────────

    /// Set the focused component. Notifies old and new components via setFocused().
    /// Matches pi-mono TUI.setFocus().
    pub fn setFocus(self: *TUI, target: ?Component) void {
        self.focus.setFocus(target);
    }

    /// Route keyboard input to the focused component.
    /// Returns true if the focused component consumed the key.
    pub fn handleInput(self: *TUI, key: Key) bool {
        return self.focus.handleInput(key);
    }

    // ── Overlays ──────────────────────────────────────────────────

    /// Show an overlay component. Saves current focus, sets focus to the overlay
    /// (unless non_capturing), returns a handle for controlling it.
    /// Matches pi-mono TUI.showOverlay().
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

    /// Hide the topmost overlay and restore previous focus.
    /// Matches pi-mono TUI.hideOverlay() — restores focus when the popped
    /// overlay had focus, even if pre_focus is null.
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

    // ── Layout ────────────────────────────────────────────────────

    pub fn addChild(self: *TUI, child: Component) void {
        self.root.addChild(child);
    }

    pub fn width(self: *const TUI) u32 {
        return self.renderer.width;
    }

    pub fn height(self: *const TUI) u32 {
        return self.renderer.height;
    }

    // ── Render ────────────────────────────────────────────────────

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

    /// Render the layout tree and overlays into the cell buffer.
    /// Returns the cursor state (if any focused component reports one).
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

        // Cursor: check overlay first, then container tree
        if (self.overlays.hasVisibleOverlays()) {
            if (self.overlayFocusCursor()) |cs| return cs;
        }
        return self.root.cursorState();
    }

    /// Check for terminal resize. Returns true if size changed.
    pub fn checkResize(self: *TUI) bool {
        self.terminal.updateSize();
        if (self.terminal.width != self.renderer.width or self.terminal.height != self.renderer.height) {
            self.renderer.resize(self.terminal.width, self.terminal.height) catch {};
            self.dirty = true;
            return true;
        }
        return false;
    }

    // ── Internal ──────────────────────────────────────────────────

    /// If the focused component lives in a visible overlay, compute its cursor
    /// from the overlay's resolved position + component-relative cursor.
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

/// Component-identity-based focus manager.
/// Source of truth for which component receives input and shows cursor.
///
/// Cursor y-offset translation still comes from the container tree
/// (Container.focused_child_index + computeChildYOffset) for base-tree
/// components. Overlay components get absolute cursor from resolveLayout.
pub const FocusManager = struct {
    current: ?Component = null,

    pub fn setFocus(self: *FocusManager, target: ?Component) void {
        if (self.current) |prev| prev.setFocused(false);
        self.current = target;
        if (target) |t| t.setFocused(true);
    }

    pub fn handleInput(self: *FocusManager, key: Key) bool {
        if (self.current) |focused| return focused.handleInput(key);
        return false;
    }

    pub fn save(self: *FocusManager) ?Component {
        return self.current;
    }

    pub fn restore(self: *FocusManager, saved: ?Component) void {
        self.setFocus(saved);
    }
};

/// Handle for controlling a specific overlay.
/// Wired into TUI's focus management — hide/focus/unfocus update the FocusManager.
/// Matches pi-mono's OverlayHandle interface.
pub const OverlayHandle = struct {
    id: u64,
    tui: *TUI,

    /// Permanently remove the overlay.
    pub fn hide(self: OverlayHandle) void {
        const entry = self.tui.overlays.findEntry(self.id) orelse return;
        const pre_focus = entry.pre_focus;
        const comp = entry.component;
        _ = self.tui.overlays.removeOverlay(self.id);

        // Restore focus if this overlay had it
        if (self.tui.focus.current) |focused| {
            if (Component.eql(focused, comp)) {
                const top_visible = self.tui.overlays.topmostCapturingComponent();
                self.tui.focus.setFocus(top_visible orelse pre_focus);
            }
        }
        if (self.tui.overlays.stack.items.len == 0) self.tui.terminal.hideCursor();
        self.tui.dirty = true;
    }

    /// Temporarily hide or show the overlay.
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

    /// Focus this overlay and bring it to the visual front.
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

    /// Release focus to the previous target.
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

// ── Tests ─────────────────────────────────────────────────────────

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
    var root = Container.init(testing.allocator);
    defer root.deinit();

    // We can't construct a full TUI in tests (needs terminal fd), so test
    // the OverlayManager methods directly that the handle delegates to.
    var editor = DummyComp{};
    var overlay_comp = DummyComp{};

    const id = mgr.showOverlayReturnId(overlay_comp.component(), .{}, editor.component());
    try testing.expectEqual(@as(usize, 1), mgr.stack.items.len);

    const pre_focus = mgr.removeOverlay(id);
    try testing.expect(pre_focus != null);
    try testing.expect(Component.eql(pre_focus.?, editor.component()));
    try testing.expectEqual(@as(usize, 0), mgr.stack.items.len);
}
