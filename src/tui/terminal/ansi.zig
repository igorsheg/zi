const std = @import("std");

pub const reset = "\x1b[0m";
pub const clear_and_home = "\x1b[2J\x1b[H";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";

pub const title_prefix = "\x1b]0;";
pub const title_suffix = "\x07";

pub const bracketed_paste_enable = "\x1b[?2004h";
pub const bracketed_paste_disable = "\x1b[?2004l";

pub const kitty_query = "\x1b[?u";
pub const kitty_keyboard_enable = "\x1b[>7u";
pub const kitty_keyboard_disable = "\x1b[<u";

pub const modify_other_keys_enable = "\x1b[>4;2m";
pub const modify_other_keys_disable = "\x1b[>4;0m";

pub const mouse_tracking_enable = "\x1b[?1000h\x1b[?1002h\x1b[?1006h";
pub const mouse_tracking_disable = "\x1b[?1006l\x1b[?1002l\x1b[?1000l";

pub const sync_enable = "\x1b[?2026h";
pub const sync_disable = "\x1b[?2026l";

pub const default_fg = "\x1b[39m";
pub const default_bg = "\x1b[49m";

pub const attrs_reset = "\x1b[22;23;24;25;27;28;29m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const italic = "\x1b[3m";
pub const underline = "\x1b[4m";
pub const blink = "\x1b[5m";
pub const inverse = "\x1b[7m";
pub const hidden = "\x1b[8m";
pub const strikethrough = "\x1b[9m";

pub const emergency_restore = show_cursor ++
    bracketed_paste_disable ++
    kitty_keyboard_disable ++
    modify_other_keys_disable ++
    mouse_tracking_disable ++
    reset;

pub fn formatCursorPos(buf: []u8, col: u32, row: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
}

pub fn formatFgRgb(buf: []u8, r: u8, g: u8, b: u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
}

pub fn formatBgRgb(buf: []u8, r: u8, g: u8, b: u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
}

pub fn formatFgIndex(buf: []u8, index: u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{index});
}

pub fn formatBgIndex(buf: []u8, index: u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{index});
}
