const view_mod = @import("view.zig");
const keys_mod = @import("../terminal/keys.zig");

const Component = view_mod.Component;
const Key = keys_mod.Key;

/// Component-identity-based focus manager.
/// Source of truth for which component receives input and shows cursor.
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
