const std = @import("std");
const cell_mod = @import("../tui/cell.zig");
const theme_mod = @import("../tui/theme.zig");

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

fn expectColorEq(expected: Color, actual: Color) !void {
    try std.testing.expectEqual(expected.is_default, actual.is_default);
    if (!expected.is_default) {
        try std.testing.expectEqual(expected.r, actual.r);
        try std.testing.expectEqual(expected.g, actual.g);
        try std.testing.expectEqual(expected.b, actual.b);
    }
}

test "theme json parses a complete custom theme" {
    const json =
        \\{
        \\  "name": "custom",
        \\  "fg": {
        \\    "accent": "#010203",
        \\    "border": "#020304",
        \\    "border_accent": "#030405",
        \\    "border_muted": "#040506",
        \\    "success": "#050607",
        \\    "error": "#060708",
        \\    "warning": "#070809",
        \\    "muted": "#08090A",
        \\    "dim": "#090A0B",
        \\    "text": "#0A0B0C",
        \\    "thinking_text": "#0B0C0D",
        \\    "user_message_text": "#0C0D0E",
        \\    "custom_message_text": "#0D0E0F",
        \\    "custom_message_label": "#0E0F10",
        \\    "tool_title": "#0F1011",
        \\    "tool_output": "#101112",
        \\    "md_heading": "#111213",
        \\    "md_link": "#121314",
        \\    "md_link_url": "#131415",
        \\    "md_code": "#141516",
        \\    "md_code_block": "#151617",
        \\    "md_code_block_border": "#161718",
        \\    "md_quote": "#171819",
        \\    "md_quote_border": "#18191A",
        \\    "md_hr": "#191A1B",
        \\    "md_list_bullet": "#1A1B1C",
        \\    "tool_diff_added": "#1B1C1D",
        \\    "tool_diff_removed": "#1C1D1E",
        \\    "tool_diff_context": "#1D1E1F",
        \\    "syntax_comment": "#1E1F20",
        \\    "syntax_keyword": "#1F2021",
        \\    "syntax_function": "#202122",
        \\    "syntax_variable": "#212223",
        \\    "syntax_string": "#222324",
        \\    "syntax_number": "#232425",
        \\    "syntax_type": "#242526",
        \\    "syntax_operator": "#252627",
        \\    "syntax_punctuation": "#262728",
        \\    "thinking_off": "#272829",
        \\    "thinking_minimal": "#28292A",
        \\    "thinking_low": "#292A2B",
        \\    "thinking_medium": "#2A2B2C",
        \\    "thinking_high": "#2B2C2D",
        \\    "thinking_xhigh": "#2C2D2E",
        \\    "bash_mode": "#2D2E2F"
        \\  },
        \\  "bg": {
        \\    "selected_bg": "#303132",
        \\    "user_message_bg": "#313233",
        \\    "custom_message_bg": "#323334",
        \\    "tool_transcript_bg": "#333435",
        \\    "tool_pending_bg": "#343536",
        \\    "tool_success_bg": "#353637",
        \\    "tool_error_bg": "#363738"
        \\  }
        \\}
    ;

    const loaded = try loadFromSlice(std.testing.allocator, json);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("custom", loaded.name);
    try expectColorEq(Color.rgb(0x01, 0x02, 0x03), loaded.theme.fg(.accent));
    try expectColorEq(Color.rgb(0x34, 0x35, 0x36), loaded.theme.bg(.tool_pending_bg));
}

test "theme json rejects missing colors" {
    const json =
        \\{
        \\  "name": "broken",
        \\  "fg": { "accent": "#010203" },
        \\  "bg": { "selected_bg": "#303132" }
        \\}
    ;

    try std.testing.expectError(error.MissingColor, loadFromSlice(std.testing.allocator, json));
}
