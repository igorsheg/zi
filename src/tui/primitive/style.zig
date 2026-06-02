const std = @import("std");
const Color = @import("color.zig").Color;

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    underline: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.bold == b.bold and a.underline == b.underline and colorEql(a.fg, b.fg) and colorEql(a.bg, b.bg);
    }
};

fn colorEql(a: Color, b: Color) bool {
    return switch (a) {
        .default => switch (b) { .default => true, else => false },
        .indexed => |i| switch (b) { .indexed => |j| i == j, else => false },
        .rgb => |x| switch (b) { .rgb => |y| x.r == y.r and x.g == y.g and x.b == y.b, else => false },
    };
}

test "default style is stable" {
    const a: Style = .{};
    const b: Style = .{};
    try std.testing.expect(a.eql(b));
}
