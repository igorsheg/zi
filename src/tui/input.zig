const vaxis = @import("vaxis");

pub const Input = union(enum) {
    cancel,
    submit,
    backspace,
    move_left,
    move_right,
    page_up,
    page_down,
    text: []const u8,
};

pub fn inputFromKey(key: vaxis.Key) ?Input {
    if (key.matches('c', .{ .ctrl = true })) return .cancel;
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) return .submit;
    if (key.matches(vaxis.Key.backspace, .{})) return .backspace;
    if (key.matches(vaxis.Key.left, .{})) return .move_left;
    if (key.matches(vaxis.Key.right, .{})) return .move_right;
    if (key.matches(vaxis.Key.page_up, .{})) return .page_up;
    if (key.matches(vaxis.Key.page_down, .{})) return .page_down;
    if (key.text) |text| {
        if (text.len > 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.meta) {
            return .{ .text = text };
        }
    }
    return null;
}
