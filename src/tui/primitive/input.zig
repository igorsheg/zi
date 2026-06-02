const vaxis = @import("vaxis");

pub const key_text_size_bytes_max = 256;

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

pub const KeyPress = struct {
    codepoint: u21,
    text_buffer: [key_text_size_bytes_max]u8 = undefined,
    text_size_bytes: u16 = 0,
    shifted_codepoint: ?u21 = null,
    base_layout_codepoint: ?u21 = null,
    mods: vaxis.Key.Modifiers = .{},

    pub fn copyFromVaxis(key: vaxis.Key) !KeyPress {
        var key_press: KeyPress = .{
            .codepoint = key.codepoint,
            .shifted_codepoint = key.shifted_codepoint,
            .base_layout_codepoint = key.base_layout_codepoint,
            .mods = key.mods,
        };
        if (key.text) |bytes| {
            if (bytes.len > key_press.text_buffer.len) return error.KeyTextTooLarge;
            @memcpy(key_press.text_buffer[0..bytes.len], bytes);
            key_press.text_size_bytes = @intCast(bytes.len);
        }
        return key_press;
    }

    pub fn text(self: *const KeyPress) ?[]const u8 {
        if (self.text_size_bytes == 0) return null;
        return self.text_buffer[0..self.text_size_bytes];
    }

    pub fn matches(self: KeyPress, codepoint: u21, mods: vaxis.Key.Modifiers) bool {
        return self.vaxisKey().matches(codepoint, mods);
    }

    fn vaxisKey(self: KeyPress) vaxis.Key {
        return .{
            .codepoint = self.codepoint,
            .text = self.text(),
            .shifted_codepoint = self.shifted_codepoint,
            .base_layout_codepoint = self.base_layout_codepoint,
            .mods = self.mods,
        };
    }
};

pub fn inputFromKey(key: KeyPress) ?Input {
    if (key.matches('c', .{ .ctrl = true })) return .cancel;
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) return .submit;
    if (key.matches(vaxis.Key.backspace, .{})) return .backspace;
    if (key.matches(vaxis.Key.left, .{})) return .move_left;
    if (key.matches(vaxis.Key.right, .{})) return .move_right;
    if (key.matches(vaxis.Key.page_up, .{})) return .page_up;
    if (key.matches(vaxis.Key.page_down, .{})) return .page_down;
    if (key.text()) |text| {
        if (text.len > 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.meta) {
            return .{ .text = text };
        }
    }
    return null;
}
