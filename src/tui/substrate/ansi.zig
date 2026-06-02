const std = @import("std");

pub const enter_alt_screen = "\x1b[?1049h";
pub const leave_alt_screen = "\x1b[?1049l";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const reset = "\x1b[0m";
pub const clear = "\x1b[2J";

pub fn cursor(buf: []u8, row: u16, col: u16) ![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col });
}

test "ansi cursor deterministic" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[2;3H", try cursor(&buf, 2, 3));
}
