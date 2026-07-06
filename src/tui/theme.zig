const std = @import("std");

pub const Scheme = enum { dark, light };
pub const ColorLevel = enum { unknown, ansi16, ansi256, truecolor };

pub const TerminalInfo = struct {
    scheme: Scheme = .dark,
    color_level: ColorLevel = .unknown,
};

pub const LayoutEpoch = struct {
    width: u16,
    height: u16,
    revision: u64 = 0,

    pub fn resize(self: *LayoutEpoch, width: u16, height: u16) bool {
        if (self.width == width and self.height == height) return false;
        self.width = width;
        self.height = height;
        self.revision +%= 1;
        return true;
    }
};

pub fn terminalInfo(colorterm: ?[]const u8, term: ?[]const u8, force_light: bool) TerminalInfo {
    return .{
        .scheme = if (force_light) .light else .dark,
        .color_level = detectColorLevel(colorterm, term),
    };
}

pub fn detectColorLevel(colorterm: ?[]const u8, term: ?[]const u8) ColorLevel {
    if (colorterm) |value| {
        if (containsIgnoreCase(value, "truecolor") or containsIgnoreCase(value, "24bit")) return .truecolor;
    }
    if (term) |value| {
        if (containsIgnoreCase(value, "256color")) return .ansi256;
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return .ansi16;
    }
    return .unknown;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "detect color level from terminal environment" {
    try std.testing.expectEqual(ColorLevel.truecolor, detectColorLevel("truecolor", "xterm-256color"));
    try std.testing.expectEqual(ColorLevel.truecolor, detectColorLevel("24BIT", null));
    try std.testing.expectEqual(ColorLevel.ansi256, detectColorLevel(null, "screen-256color"));
    try std.testing.expectEqual(ColorLevel.ansi16, detectColorLevel(null, "xterm"));
    try std.testing.expectEqual(ColorLevel.unknown, detectColorLevel(null, null));
}

test "layout epoch increments only on size changes" {
    var epoch: LayoutEpoch = .{ .width = 80, .height = 24 };
    try std.testing.expect(!epoch.resize(80, 24));
    try std.testing.expectEqual(@as(u64, 0), epoch.revision);
    try std.testing.expect(epoch.resize(100, 30));
    try std.testing.expectEqual(@as(u64, 1), epoch.revision);
}
