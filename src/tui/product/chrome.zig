const std = @import("std");
const vaxis = @import("vaxis");

pub const BorderGlyphs = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,

    pub const rounded: BorderGlyphs = .{
        .top_left = "╭",
        .top_right = "╮",
        .bottom_left = "╰",
        .bottom_right = "╯",
        .horizontal = "─",
        .vertical = "│",
    };
};

pub const OpenBlock = struct {
    glyphs: BorderGlyphs = BorderGlyphs.rounded,

    pub fn bodyPrefix(self: OpenBlock) []const u8 {
        _ = self;
        return "│ ";
    }

    pub fn bottomLine(self: OpenBlock, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}", .{
            self.glyphs.bottom_left,
            self.glyphs.horizontal,
            self.glyphs.horizontal,
            self.glyphs.horizontal,
        });
    }
};

pub const Label = struct {
    text: []const u8,
    style: vaxis.Style = .{},
};

pub fn elisionLine(buffer: []u8, omitted_lines: usize, omitted_bytes: usize) !?[]const u8 {
    if (omitted_lines > 0) return try std.fmt.bufPrint(buffer, "· ··· {d} earlier lines", .{omitted_lines});
    if (omitted_bytes > 0) return try std.fmt.bufPrint(buffer, "· ··· {d} earlier bytes", .{omitted_bytes});
    return null;
}
