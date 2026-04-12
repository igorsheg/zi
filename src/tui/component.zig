const std = @import("std");
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const keys_mod = @import("keys.zig");

const Region = buffer_mod.Region;
const Key = keys_mod.Key;

/// Height requirements reported by a component during layout.
pub const Measurement = struct {
    min_height: u32,
    preferred_height: u32,
};

/// Cursor position and style for a focused component.
pub const CursorState = struct {
    x: u32,
    y: u32,
    style: cell_mod.CursorStyle = .bar,
};

/// Type-erased component interface.
/// Components implement render/handleInput/measure/cursorState and expose
/// themselves via `component()` for use in layout containers.
///
/// Heavy components can optionally implement `renderSlice(region, first_row)`
/// so viewport owners can paint visible rows directly without full-surface
/// scratch rendering.
///
/// Focus: components that can receive focus implement `setFocused(bool)`.
/// The FocusManager (on TUI) is the source of truth for who has focus.
/// Components use `focused` state to gate input handling and cursor display.
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render: *const fn (ptr: *anyopaque, region: Region) void,
        render_slice: ?*const fn (ptr: *anyopaque, region: Region, first_row: u32) void,
        handle_input: *const fn (ptr: *anyopaque, key: Key) bool,
        measure: *const fn (ptr: *anyopaque, width: u32) Measurement,
        cursor_state: *const fn (ptr: *anyopaque) ?CursorState,
        invalidate: *const fn (ptr: *anyopaque) void,
        set_focused: *const fn (ptr: *anyopaque, focused: bool) void,
        next_animation_deadline: *const fn (ptr: *anyopaque, now_ns: i128) ?i128,
        tick_animation: *const fn (ptr: *anyopaque, now_ns: i128) bool,
    };

    pub fn init(comptime T: type, ptr: *T) Component {
        const gen = struct {
            fn render(erased: *anyopaque, region: Region) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.render(region);
            }
            fn renderSlice(erased: *anyopaque, region: Region, first_row: u32) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.renderSlice(region, first_row);
            }
            fn handleInput(erased: *anyopaque, key: Key) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "handleInput")) {
                    return self.handleInput(key);
                }
                return false;
            }
            fn measure(erased: *anyopaque, width: u32) Measurement {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.measure(width);
            }
            fn cursorState(erased: *anyopaque) ?CursorState {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "cursorState")) {
                    return self.cursorState();
                }
                return null;
            }
            fn invalidate(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "invalidate")) {
                    self.invalidate();
                }
            }
            fn setFocused(erased: *anyopaque, focused: bool) void {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "setFocused")) {
                    self.setFocused(focused);
                }
            }
            fn nextAnimationDeadline(erased: *anyopaque, now_ns: i128) ?i128 {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "nextAnimationDeadline")) {
                    return self.nextAnimationDeadline(now_ns);
                }
                return null;
            }
            fn tickAnimation(erased: *anyopaque, now_ns: i128) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                if (@hasDecl(T, "tickAnimation")) {
                    return self.tickAnimation(now_ns);
                }
                return false;
            }
        };
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .render = gen.render,
                .render_slice = if (@hasDecl(T, "renderSlice")) gen.renderSlice else null,
                .handle_input = gen.handleInput,
                .measure = gen.measure,
                .cursor_state = gen.cursorState,
                .invalidate = gen.invalidate,
                .set_focused = gen.setFocused,
                .next_animation_deadline = gen.nextAnimationDeadline,
                .tick_animation = gen.tickAnimation,
            },
        };
    }

    /// Component identity — two Components are equal iff they wrap the same object.
    /// ptr is the instance pointer; vtable is shared per type so ptr alone suffices,
    /// but checking both guards against accidental aliasing across type-erased boundaries.
    pub fn eql(a: Component, b: Component) bool {
        return a.ptr == b.ptr and a.vtable == b.vtable;
    }

    pub fn render(self: Component, region: Region) void {
        self.vtable.render(self.ptr, region);
    }

    pub fn renderSlice(self: Component, region: Region, first_row: u32) bool {
        const render_slice = self.vtable.render_slice orelse return false;
        render_slice(self.ptr, region, first_row);
        return true;
    }

    pub fn handleInput(self: Component, key: Key) bool {
        return self.vtable.handle_input(self.ptr, key);
    }

    pub fn measure(self: Component, width: u32) Measurement {
        return self.vtable.measure(self.ptr, width);
    }

    pub fn cursorState(self: Component) ?CursorState {
        return self.vtable.cursor_state(self.ptr);
    }

    pub fn invalidate(self: Component) void {
        self.vtable.invalidate(self.ptr);
    }

    pub fn setFocused(self: Component, focused: bool) void {
        self.vtable.set_focused(self.ptr, focused);
    }

    pub fn nextAnimationDeadline(self: Component, now_ns: i128) ?i128 {
        return self.vtable.next_animation_deadline(self.ptr, now_ns);
    }

    pub fn tickAnimation(self: Component, now_ns: i128) bool {
        return self.vtable.tick_animation(self.ptr, now_ns);
    }
};

test "component defaults animation hooks for static components" {
    const StaticComp = struct {
        pub fn render(_: *@This(), _: Region) void {}
        pub fn measure(_: *@This(), _: u32) Measurement {
            return .{ .min_height = 1, .preferred_height = 1 };
        }
    };

    var comp = StaticComp{};
    const erased = Component.init(StaticComp, &comp);
    try std.testing.expectEqual(@as(?i128, null), erased.nextAnimationDeadline(123));
    try std.testing.expect(!erased.tickAnimation(123));
    try std.testing.expect(!erased.renderSlice(undefined, 1));
}

test "component dispatches optional renderSlice hook" {
    const SliceComp = struct {
        called: bool = false,
        first_row: u32 = 0,

        pub fn render(_: *@This(), _: Region) void {}
        pub fn renderSlice(self: *@This(), _: Region, first_row: u32) void {
            self.called = true;
            self.first_row = first_row;
        }
        pub fn measure(_: *@This(), _: u32) Measurement {
            return .{ .min_height = 1, .preferred_height = 1 };
        }
    };

    var comp = SliceComp{};
    const erased = Component.init(SliceComp, &comp);
    try std.testing.expect(erased.renderSlice(undefined, 7));
    try std.testing.expect(comp.called);
    try std.testing.expectEqual(@as(u32, 7), comp.first_row);
}
