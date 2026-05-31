const std = @import("std");
const vaxis = @import("vaxis");

pub fn screenToAscii(
    allocator: std.mem.Allocator,
    screen: *const vaxis.Screen,
    width: u16,
    height: u16,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    for (0..height) |row| {
        if (row != 0) try bytes.append(allocator, '\n');

        var skip_cell_count: u16 = 0;
        for (0..width) |col| {
            if (skip_cell_count > 0) {
                skip_cell_count -= 1;
                continue;
            }

            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse {
                try bytes.append(allocator, ' ');
                continue;
            };
            const grapheme = cell.char.grapheme;
            if (grapheme.len == 0) {
                try bytes.append(allocator, ' ');
            } else {
                try bytes.appendSlice(allocator, grapheme);
            }
            if (cell.char.width > 1) skip_cell_count = cell.char.width - 1;
        }
    }

    return bytes.toOwnedSlice(allocator);
}

pub fn expectScreenAscii(
    expected: []const u8,
    screen: *const vaxis.Screen,
    width: u16,
    height: u16,
) !void {
    const actual = try screenToAscii(std.testing.allocator, screen, width, height);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "screen ascii captures cells and empty space" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2,
        .cols = 5,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    screen.writeCell(0, 0, .{ .char = .{ .grapheme = "a", .width = 1 } });
    screen.writeCell(1, 0, .{ .char = .{ .grapheme = "b", .width = 1 } });
    screen.writeCell(0, 1, .{ .char = .{ .grapheme = ">", .width = 1 } });

    try expectScreenAscii("ab   \n>    ", &screen, 5, 2);
}
