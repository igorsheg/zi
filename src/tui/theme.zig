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
    expanded: bool = false,
    hide_thinking: bool = true,
    revision: u64 = 0,

    pub fn resize(self: *LayoutEpoch, width: u16, height: u16) bool {
        const width_changed = self.width != width;
        const height_changed = self.height != height;
        if (!width_changed and !height_changed) return false;
        self.width = width;
        self.height = height;
        if (width_changed) self.revision +%= 1;
        return true;
    }

    pub fn setExpanded(self: *LayoutEpoch, expanded: bool) bool {
        if (self.expanded == expanded) return false;
        self.expanded = expanded;
        self.revision +%= 1;
        return true;
    }

    pub fn setHideThinking(self: *LayoutEpoch, hidden: bool) bool {
        if (self.hide_thinking == hidden) return false;
        self.hide_thinking = hidden;
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

pub fn terminalInfoFromEnv(env_map: *const std.process.Environ.Map) TerminalInfo {
    return terminalInfo(env_map.get("COLORTERM"), env_map.get("TERM"), envFlag(env_map.get("ZI_THEME_LIGHT")));
}

fn envFlag(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;
    return !std.ascii.eqlIgnoreCase(trimmed, "0") and
        !std.ascii.eqlIgnoreCase(trimmed, "false") and
        !std.ascii.eqlIgnoreCase(trimmed, "no");
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

test "terminal info resolves light theme from environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("ZI_THEME_LIGHT", "1");

    const info = terminalInfoFromEnv(&env);
    try std.testing.expectEqual(Scheme.light, info.scheme);
    try std.testing.expectEqual(ColorLevel.truecolor, info.color_level);

    try env.put("ZI_THEME_LIGHT", "false");
    try std.testing.expectEqual(Scheme.dark, terminalInfoFromEnv(&env).scheme);
}

test "layout epoch increments only on visible changes" {
    var epoch: LayoutEpoch = .{ .width = 80, .height = 24 };
    try std.testing.expect(!epoch.resize(80, 24));
    try std.testing.expectEqual(@as(u64, 0), epoch.revision);
    try std.testing.expect(epoch.resize(100, 30));
    try std.testing.expectEqual(@as(u64, 1), epoch.revision);
    try std.testing.expect(epoch.setHideThinking(false));
    try std.testing.expectEqual(@as(u64, 2), epoch.revision);
    try std.testing.expect(epoch.resize(100, 40));
    try std.testing.expectEqual(@as(u64, 2), epoch.revision);
}
