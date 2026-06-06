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
            a.fg.eql(b.fg) and
            a.bg.eql(b.bg);
    }
};

test "style equality includes intensity" {
    try std.testing.expect((Style{}).eql(.{}));
    try std.testing.expect(!(Style{ .dim = true }).eql(.{}));
    try std.testing.expect(!(Style{ .bold = true }).eql(.{ .dim = true }));
}
