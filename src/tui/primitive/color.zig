const std = @import("std");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,

    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    pub fn writeForeground(self: Color, writer: *std.Io.Writer) !void {
        switch (self) {
            .default => try writer.writeAll("\x1b[39m"),
            .indexed => |i| try writer.print("\x1b[38;5;{d}m", .{i}),
            .rgb => |c| try writer.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        }
    }

    pub fn writeBackground(self: Color, writer: *std.Io.Writer) !void {
        switch (self) {
            .default => try writer.writeAll("\x1b[49m"),
            .indexed => |i| try writer.print("\x1b[48;5;{d}m", .{i}),
            .rgb => |c| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        }
    }
};

test "colors compare by value" {
    try std.testing.expectEqual(Color.default, Color.default);
    const indexed: Color = .{ .indexed = 7 };
    const rgb: Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    try std.testing.expectEqual(indexed, indexed);
    try std.testing.expectEqual(rgb, rgb);
}
