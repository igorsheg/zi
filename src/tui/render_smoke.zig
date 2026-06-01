const std = @import("std");
const vaxis = @import("vaxis");

pub fn measurePrint(
    win: vaxis.Window,
    segments: []const vaxis.Cell.Segment,
) vaxis.Window.PrintResult {
    return win.print(segments, .{
        .commit = false,
        .wrap = .grapheme,
    });
}

test "libvaxis print measures grapheme wrapping without zi row engine" {
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 4,
        .height = 2,
        .screen = &screen,
    };
    const segments = [_]vaxis.Cell.Segment{.{ .text = "a🙂b" }};

    const result = measurePrint(win, &segments);

    try std.testing.expectEqual(@as(u16, 1), result.row);
    try std.testing.expectEqual(@as(u16, 0), result.col);
    try std.testing.expectEqual(false, result.overflow);
}
