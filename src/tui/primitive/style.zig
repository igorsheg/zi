const std = @import("std");
const Color = @import("color.zig").Color;

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.bold == b.bold and
            a.dim == b.dim and
            a.underline == b.underline and
            colorEql(a.fg, b.fg) and
            colorEql(a.bg, b.bg);
    }
};

fn colorEql(a: Color, b: Color) bool {
    return switch (a) {
        .default => switch (b) {
            .default => true,
            else => false,
        },
        .indexed => |i| switch (b) {
            .indexed => |j| i == j,
            else => false,
        },
        .rgb => |x| switch (b) {
            .rgb => |y| x.r == y.r and x.g == y.g and x.b == y.b,
            else => false,
        },
    };
}

test "style equality includes intensity" {
    try std.testing.expect((Style{}).eql(.{}));
    try std.testing.expect(!(Style{ .dim = true }).eql(.{}));
    try std.testing.expect(!(Style{ .bold = true }).eql(.{ .dim = true }));
}
