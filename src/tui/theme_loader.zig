const std = @import("std");
const cell_mod = @import("cell.zig");
const theme_mod = @import("theme.zig");

const Color = cell_mod.Color;
const Theme = theme_mod.Theme;
const FgColor = theme_mod.FgColor;
const BgColor = theme_mod.BgColor;

pub const LoadedThemeFile = struct {
    name: []const u8,
    theme: Theme,

    pub fn deinit(self: LoadedThemeFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub fn loadFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !LoadedThemeFile {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidThemeFormat;
    const root = parsed.value.object;

    const name_val = root.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.InvalidThemeFormat;

    const fg_val = root.get("fg") orelse return error.MissingFg;
    if (fg_val != .object) return error.InvalidThemeFormat;

    const bg_val = root.get("bg") orelse return error.MissingBg;
    if (bg_val != .object) return error.InvalidThemeFormat;

    var theme = Theme{
        .fg_colors = undefined,
        .bg_colors = undefined,
    };
    var seen_fg = [_]bool{false} ** @typeInfo(FgColor).@"enum".fields.len;
    var seen_bg = [_]bool{false} ** @typeInfo(BgColor).@"enum".fields.len;

    var fg_it = fg_val.object.iterator();
    while (fg_it.next()) |entry| {
        const token = parseEnumToken(FgColor, entry.key_ptr.*) orelse return error.UnknownToken;
        theme.fg_colors[@intFromEnum(token)] = try parseColorValue(entry.value_ptr.*);
        seen_fg[@intFromEnum(token)] = true;
    }

    var bg_it = bg_val.object.iterator();
    while (bg_it.next()) |entry| {
        const token = parseEnumToken(BgColor, entry.key_ptr.*) orelse return error.UnknownToken;
        theme.bg_colors[@intFromEnum(token)] = try parseColorValue(entry.value_ptr.*);
        seen_bg[@intFromEnum(token)] = true;
    }

    for (seen_fg) |seen| {
        if (!seen) return error.MissingColor;
    }
    for (seen_bg) |seen| {
        if (!seen) return error.MissingColor;
    }

    return .{
        .name = try allocator.dupe(u8, name_val.string),
        .theme = theme,
    };
}

fn parseEnumToken(comptime E: type, name: []const u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn parseColorValue(value: std.json.Value) !Color {
    if (value != .string) return error.InvalidColor;
    const text = value.string;
    if (text.len == 0) return Color.default;
    if (text.len != 7 or text[0] != '#') return error.InvalidColor;

    return Color.rgb(
        try parseHexByte(text[1..3]),
        try parseHexByte(text[3..5]),
        try parseHexByte(text[5..7]),
    );
}

fn parseHexByte(text: []const u8) !u8 {
    return std.fmt.parseInt(u8, text, 16) catch error.InvalidColor;
}

fn expectThemeEq(expected: Theme, actual: Theme) !void {
    inline for (@typeInfo(FgColor).@"enum".fields) |field| {
        const token: FgColor = @enumFromInt(field.value);
        try expectColorEq(expected.fg(token), actual.fg(token));
    }
    inline for (@typeInfo(BgColor).@"enum".fields) |field| {
        const token: BgColor = @enumFromInt(field.value);
        try expectColorEq(expected.bg(token), actual.bg(token));
    }
}

fn expectColorEq(expected: Color, actual: Color) !void {
    try std.testing.expectEqual(expected.is_default, actual.is_default);
    if (!expected.is_default) {
        try std.testing.expectEqual(expected.r, actual.r);
        try std.testing.expectEqual(expected.g, actual.g);
        try std.testing.expectEqual(expected.b, actual.b);
    }
}

test "embedded dark json matches Theme.dark" {
    const loaded = try loadFromSlice(std.testing.allocator, theme_mod.builtin_dark_json);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dark", loaded.name);
    try expectThemeEq(theme_mod.Theme.dark, loaded.theme);
}

test "embedded light json matches Theme.light" {
    const loaded = try loadFromSlice(std.testing.allocator, theme_mod.builtin_light_json);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("light", loaded.name);
    try expectThemeEq(theme_mod.Theme.light, loaded.theme);
}
