const std = @import("std");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,

    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
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

    pub fn ansiBytes(self: Color, foreground: bool, buffer: []u8) ![]const u8 {
        return switch (self) {
            .default => if (foreground) "\x1b[39m" else "\x1b[49m",
            .indexed => |i| if (foreground)
                try std.fmt.bufPrint(buffer, "\x1b[38;5;{d}m", .{i})
            else
                try std.fmt.bufPrint(buffer, "\x1b[48;5;{d}m", .{i}),
            .rgb => |c| if (foreground)
                try std.fmt.bufPrint(buffer, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b })
            else
                try std.fmt.bufPrint(buffer, "\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        };
    }

    pub fn writeForeground(self: Color, writer: *std.Io.Writer) !void {
        var buffer: [32]u8 = undefined;
        try writer.writeAll(try self.ansiBytes(true, &buffer));
    }

    pub fn writeBackground(self: Color, writer: *std.Io.Writer) !void {
        var buffer: [32]u8 = undefined;
        try writer.writeAll(try self.ansiBytes(false, &buffer));
    }
};

test "colors compare by value" {
    try std.testing.expectEqual(Color.default, Color.default);
    const indexed: Color = .{ .indexed = 7 };
    const rgb: Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    try std.testing.expectEqual(indexed, indexed);
    try std.testing.expectEqual(rgb, rgb);
}
