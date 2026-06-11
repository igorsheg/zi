const std = @import("std");
const vaxis = @import("vaxis");

pub const InlineBytes = struct {
    len: u8 = 0,
    bytes: [64]u8 = undefined,

    pub fn from(data: []const u8) InlineBytes {
        var value: InlineBytes = .{};
        const n = @min(data.len, value.bytes.len);
        @memcpy(value.bytes[0..n], data[0..n]);
        value.len = @intCast(n);
        return value;
    }

    pub fn slice(self: *const InlineBytes) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Key = enum {
    escape,
    enter,
    tab,
    backspace,
    delete,
    arrow_left,
    arrow_right,
    home,
    end,
    page_up,
    page_down,
    ctrl_c,
    ctrl_d,
    ctrl_u,
};

pub const Input = union(enum) {
    key: Key,
    text: InlineBytes,
    paste_begin,
    paste_end,
    focus_in,
    focus_out,
    ignored,
};

pub fn fromVaxis(event: vaxis.Event) Input {
    return switch (event) {
        .key_press => |key| fromVaxisKey(key),
        .paste_start => .paste_begin,
        .paste_end => .paste_end,
        .focus_in => .focus_in,
        .focus_out => .focus_out,
        else => .ignored,
    };
}

fn fromVaxisKey(key: vaxis.Key) Input {
    if (key.matches(vaxis.Key.escape, .{})) return .{ .key = .escape };
    if (key.matches(vaxis.Key.enter, .{})) return .{ .key = .enter };
    if (key.matches(vaxis.Key.kp_enter, .{})) return .{ .key = .enter };
    if (key.matches(vaxis.Key.tab, .{})) return .{ .key = .tab };
    if (key.matches(vaxis.Key.backspace, .{})) return .{ .key = .backspace };
    if (key.matches(vaxis.Key.delete, .{})) return .{ .key = .delete };
    if (key.matches(vaxis.Key.left, .{})) return .{ .key = .arrow_left };
    if (key.matches(vaxis.Key.right, .{})) return .{ .key = .arrow_right };
    if (key.matches(vaxis.Key.home, .{})) return .{ .key = .home };
    if (key.matches(vaxis.Key.end, .{})) return .{ .key = .end };
    if (key.matches(vaxis.Key.page_up, .{})) return .{ .key = .page_up };
    if (key.matches(vaxis.Key.page_down, .{})) return .{ .key = .page_down };
    if (key.matches('c', .{ .ctrl = true })) return .{ .key = .ctrl_c };
    if (key.matches('d', .{ .ctrl = true })) return .{ .key = .ctrl_d };
    if (key.matches('u', .{ .ctrl = true })) return .{ .key = .ctrl_u };
    if (key.text) |text| {
        if (text.len > 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
            return .{ .text = InlineBytes.from(text) };
        }
    }
    return .ignored;
}
