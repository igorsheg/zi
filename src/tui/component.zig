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
/// Focus: components that can receive focus implement `setFocused(bool)`.
/// The FocusManager (on TUI) is the source of truth for who has focus.
/// Components use `focused` state to gate input handling and cursor display.
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render: *const fn (ptr: *anyopaque, region: Region) void,
        handle_input: *const fn (ptr: *anyopaque, key: Key) bool,
        measure: *const fn (ptr: *anyopaque, width: u32) Measurement,
        cursor_state: *const fn (ptr: *anyopaque) ?CursorState,
        invalidate: *const fn (ptr: *anyopaque) void,
        set_focused: *const fn (ptr: *anyopaque, focused: bool) void,
    };

    pub fn init(comptime T: type, ptr: *T) Component {
        const gen = struct {
            fn render(erased: *anyopaque, region: Region) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.render(region);
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
        };
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .render = gen.render,
                .handle_input = gen.handleInput,
                .measure = gen.measure,
                .cursor_state = gen.cursorState,
                .invalidate = gen.invalidate,
                .set_focused = gen.setFocused,
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
};
