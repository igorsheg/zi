const std = @import("std");
const cell_mod = @import("cell.zig");
const tokens = @import("../themes/tokens.zig");

pub const Color = cell_mod.Color;
pub const FgColor = tokens.FgColor;
pub const BgColor = tokens.BgColor;

/// Semantic color theme matching pi-mono's token model.
pub const Theme = struct {
    fg_colors: [fg_count]Color,
    bg_colors: [bg_count]Color,

    pub const Background = enum {
        dark,
        light,
    };

    const fg_count = @typeInfo(FgColor).@"enum".fields.len;
    const bg_count = @typeInfo(BgColor).@"enum".fields.len;

    pub fn fg(self: *const Theme, color: FgColor) Color {
        return self.fg_colors[@intFromEnum(color)];
    }

    pub fn bg(self: *const Theme, color: BgColor) Color {
        return self.bg_colors[@intFromEnum(color)];
    }

    pub fn detectTerminalBackground() Background {
        return terminalBackgroundFromColorFgbg(std.posix.getenv("COLORFGBG") orelse "");
    }
};

fn terminalBackgroundFromColorFgbg(colorfgbg: []const u8) Theme.Background {
    var parts = std.mem.splitScalar(u8, colorfgbg, ';');
    _ = parts.next();
    const bg_part = parts.next() orelse return .dark;
    const bg = std.fmt.parseInt(u8, bg_part, 10) catch return .dark;
    return if (bg < 8) .dark else .light;
}

pub fn expectColorEq(expected: Color, actual: Color) !void {
    try std.testing.expect(expected.eql(actual));
}

test "terminal background detection mirrors pi-mono COLORFGBG heuristic" {
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg("15;0"));
    try std.testing.expectEqual(Theme.Background.light, terminalBackgroundFromColorFgbg("0;15"));
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg("broken"));
    try std.testing.expectEqual(Theme.Background.dark, terminalBackgroundFromColorFgbg(""));
}
