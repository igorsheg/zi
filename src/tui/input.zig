const vaxis = @import("vaxis");

const App = @import("App.zig");

pub fn commandFromKey(key: vaxis.Key) ?App.Command {
    if (key.matches('c', .{ .ctrl = true })) return .cancel_or_quit;
    if (key.matches(vaxis.Key.escape, .{})) return .cancel_or_quit;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) return .submit_composer;
    if (key.matches(vaxis.Key.backspace, .{})) return .backspace;
    if (key.matches(vaxis.Key.left, .{})) return .move_left;
    if (key.matches(vaxis.Key.right, .{})) return .move_right;
    if (key.matches(vaxis.Key.page_up, .{})) return .scroll_up;
    if (key.matches(vaxis.Key.page_down, .{})) return .scroll_down;
    if (key.text) |text| {
        if (text.len > 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.meta) {
            return .{ .insert_text = text };
        }
    }
    return null;
}
