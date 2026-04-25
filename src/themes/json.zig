const std = @import("std");
const cell_mod = @import("../tui/cell.zig");
const theme_mod = @import("../tui/theme.zig");
const tokens = @import("tokens.zig");

const Color = cell_mod.Color;
const Theme = theme_mod.Theme;
const FgColor = tokens.FgColor;
const BgColor = tokens.BgColor;

pub const LoadedThemeFile = struct {
    name: []const u8,
    theme: Theme,

    pub fn deinit(self: LoadedThemeFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub fn formatLoadError(allocator: std.mem.Allocator, bytes: []const u8, err: anyerror) ![]const u8 {
    return switch (err) {
        error.MissingColor => try formatMissingColorError(allocator, bytes),
        error.UnknownToken => try formatUnknownTokenError(allocator, bytes),
        error.UnknownVariable, error.CircularVariableReference => try formatVariableError(allocator, bytes, err),
        else => try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
    };
}

pub fn loadFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !LoadedThemeFile {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidThemeFormat;
    const root = parsed.value.object;

    const name_val = root.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.InvalidThemeFormat;

    const vars_val = root.get("vars");
    if (vars_val != null and vars_val.? != .object) return error.InvalidThemeFormat;
    const vars = if (vars_val) |value| value.object else null;

    const colors_val = root.get("colors") orelse return error.MissingColors;
    if (colors_val != .object) return error.InvalidThemeFormat;

    var theme = Theme{
        .fg_colors = undefined,
        .bg_colors = undefined,
    };
    var seen_fg = [_]bool{false} ** @typeInfo(FgColor).@"enum".fields.len;
    var seen_bg = [_]bool{false} ** @typeInfo(BgColor).@"enum".fields.len;
    var visited_vars: std.ArrayList([]const u8) = .empty;
    defer visited_vars.deinit(allocator);

    var color_it = colors_val.object.iterator();
    while (color_it.next()) |entry| {
        visited_vars.clearRetainingCapacity();
        const color_value = try resolveColorValue(allocator, entry.value_ptr.*, vars, &visited_vars);

        if (tokens.parseFgWireName(entry.key_ptr.*)) |token| {
            theme.fg_colors[@intFromEnum(token)] = color_value;
            seen_fg[@intFromEnum(token)] = true;
            continue;
        }
        if (tokens.parseBgWireName(entry.key_ptr.*)) |token| {
            theme.bg_colors[@intFromEnum(token)] = color_value;
            seen_bg[@intFromEnum(token)] = true;
            continue;
        }
        return error.UnknownToken;
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

fn resolveColorValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    vars: ?std.json.ObjectMap,
    visited_vars: *std.ArrayList([]const u8),
) !Color {
    switch (value) {
        .string => |text| {
            if (text.len == 0) return Color.default;
            if (text.len == 7 and text[0] == '#') {
                return Color.rgb(
                    try parseHexByte(text[1..3]),
                    try parseHexByte(text[3..5]),
                    try parseHexByte(text[5..7]),
                );
            }

            const vars_obj = vars orelse return error.UnknownVariable;
            for (visited_vars.items) |visited| {
                if (std.mem.eql(u8, visited, text)) return error.CircularVariableReference;
            }
            const next = vars_obj.get(text) orelse return error.UnknownVariable;
            try visited_vars.append(allocator, text);
            defer _ = visited_vars.pop();
            return resolveColorValue(allocator, next, vars, visited_vars);
        },
        .integer => |raw| {
            if (raw < 0 or raw > 255) return error.InvalidColor;
            return Color.indexed(@intCast(raw));
        },
        else => return error.InvalidColor,
    }
}

fn parseHexByte(text: []const u8) !u8 {
    return std.fmt.parseInt(u8, text, 16) catch error.InvalidColor;
}

fn formatMissingColorError(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return std.fmt.allocPrint(allocator, "MissingColor", .{});
    const colors_val = parsed.value.object.get("colors") orelse return std.fmt.allocPrint(allocator, "MissingColor", .{});
    if (colors_val != .object) return std.fmt.allocPrint(allocator, "MissingColor", .{});

    inline for (tokens.fg_tokens) |token| {
        if (colors_val.object.get(token.wire_name) == null) {
            return std.fmt.allocPrint(allocator, "missing required foreground color token '{s}'", .{token.wire_name});
        }
    }
    inline for (tokens.bg_tokens) |token| {
        if (colors_val.object.get(token.wire_name) == null) {
            return std.fmt.allocPrint(allocator, "missing required background color token '{s}'", .{token.wire_name});
        }
    }
    return std.fmt.allocPrint(allocator, "MissingColor", .{});
}

fn formatUnknownTokenError(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return std.fmt.allocPrint(allocator, "UnknownToken", .{});
    const colors_val = parsed.value.object.get("colors") orelse return std.fmt.allocPrint(allocator, "UnknownToken", .{});
    if (colors_val != .object) return std.fmt.allocPrint(allocator, "UnknownToken", .{});

    var color_it = colors_val.object.iterator();
    while (color_it.next()) |entry| {
        if (tokens.parseFgWireName(entry.key_ptr.*) != null or tokens.parseBgWireName(entry.key_ptr.*) != null) continue;
        return std.fmt.allocPrint(allocator, "unknown color token '{s}'", .{entry.key_ptr.*});
    }
    return std.fmt.allocPrint(allocator, "UnknownToken", .{});
}

fn formatVariableError(allocator: std.mem.Allocator, bytes: []const u8, original_err: anyerror) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return std.fmt.allocPrint(allocator, "{s}", .{@errorName(original_err)});
    const root = parsed.value.object;
    const vars_val = root.get("vars") orelse return std.fmt.allocPrint(allocator, "{s}", .{@errorName(original_err)});
    if (vars_val != .object) return std.fmt.allocPrint(allocator, "{s}", .{@errorName(original_err)});
    const colors_val = root.get("colors") orelse return std.fmt.allocPrint(allocator, "{s}", .{@errorName(original_err)});
    if (colors_val != .object) return std.fmt.allocPrint(allocator, "{s}", .{@errorName(original_err)});

    var visited_vars: std.ArrayList([]const u8) = .empty;
    defer visited_vars.deinit(allocator);
    var color_it = colors_val.object.iterator();
    while (color_it.next()) |entry| {
        if (tokens.parseFgWireName(entry.key_ptr.*) == null and tokens.parseBgWireName(entry.key_ptr.*) == null) continue;
        visited_vars.clearRetainingCapacity();
        if (try formatVariableErrorForValue(allocator, entry.value_ptr.*, vars_val.object, &visited_vars)) |message| {
            return message;
        }
    }
    return std.fmt.allocPrint(allocator, "{s}", .{@errorName(original_err)});
}

fn formatVariableErrorForValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    vars: std.json.ObjectMap,
    visited_vars: *std.ArrayList([]const u8),
) !?[]const u8 {
    if (value != .string) return null;
    const text = value.string;
    if (text.len == 0 or (text.len == 7 and text[0] == '#')) return null;
    for (visited_vars.items) |visited| {
        if (std.mem.eql(u8, visited, text)) {
            return try std.fmt.allocPrint(allocator, "circular variable reference involving '{s}'", .{text});
        }
    }
    const next = vars.get(text) orelse return try std.fmt.allocPrint(allocator, "unknown variable '{s}'", .{text});
    try visited_vars.append(allocator, text);
    defer _ = visited_vars.pop();
    return formatVariableErrorForValue(allocator, next, vars, visited_vars);
}

test "theme json parses builtin pi-mono dark theme format" {
    const loaded = try loadFromSlice(std.testing.allocator, @embedFile("builtin/dark.json"));
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dark", loaded.name);
    try theme_mod.expectColorEq(Color.rgb(0x8A, 0xBE, 0xB7), loaded.theme.fg(.accent));
    try theme_mod.expectColorEq(Color.default, loaded.theme.fg(.text));
    try theme_mod.expectColorEq(Color.rgb(0x28, 0x28, 0x32), loaded.theme.bg(.tool_pending_bg));
}

test "theme json supports 256-color indices and variable references" {
    const source = @embedFile("builtin/dark.json");
    const accent_indexed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "\"accent\": \"accent\"", "\"accent\": 42");
    defer std.testing.allocator.free(accent_indexed);
    const pending_indexed = try std.mem.replaceOwned(u8, std.testing.allocator, accent_indexed, "\"toolPendingBg\": \"toolPendingBg\"", "\"toolPendingBg\": 236");
    defer std.testing.allocator.free(pending_indexed);

    const loaded = try loadFromSlice(std.testing.allocator, pending_indexed);
    defer loaded.deinit(std.testing.allocator);

    try theme_mod.expectColorEq(Color.indexed(42), loaded.theme.fg(.accent));
    try theme_mod.expectColorEq(Color.indexed(236), loaded.theme.bg(.tool_pending_bg));
    try theme_mod.expectColorEq(Color.rgb(0x81, 0xA2, 0xBE), loaded.theme.fg(.thinking_medium));
}

test "theme json rejects missing required colors" {
    const json =
        \\{
        \\  "name": "broken",
        \\  "colors": { "accent": "#010203" }
        \\}
    ;

    try std.testing.expectError(error.MissingColor, loadFromSlice(std.testing.allocator, json));
}

test "theme json formats invalid theme diagnostics with repair detail" {
    const missing =
        \\{
        \\  "name": "broken",
        \\  "colors": { "accent": "#010203" }
        \\}
    ;
    const missing_msg = try formatLoadError(std.testing.allocator, missing, error.MissingColor);
    defer std.testing.allocator.free(missing_msg);
    try std.testing.expect(std.mem.indexOf(u8, missing_msg, "missing required foreground color token 'border'") != null);

    const source = @embedFile("builtin/dark.json");
    const unknown_var = try std.mem.replaceOwned(u8, std.testing.allocator, source, "\"accent\": \"accent\"", "\"accent\": \"ghostAccent\"");
    defer std.testing.allocator.free(unknown_var);
    const unknown_msg = try formatLoadError(std.testing.allocator, unknown_var, error.UnknownVariable);
    defer std.testing.allocator.free(unknown_msg);
    try std.testing.expect(std.mem.indexOf(u8, unknown_msg, "unknown variable 'ghostAccent'") != null);

    const circular = try std.mem.replaceOwned(u8, std.testing.allocator, source, "\"accent\": \"#8abeb7\",\n    \"selectedBg\": \"#3a3a4a\"", "\"accent\": \"selectedBg\",\n    \"selectedBg\": \"accent\"");
    defer std.testing.allocator.free(circular);
    const circular_msg = try formatLoadError(std.testing.allocator, circular, error.CircularVariableReference);
    defer std.testing.allocator.free(circular_msg);
    try std.testing.expect(std.mem.indexOf(u8, circular_msg, "circular variable reference involving 'accent'") != null);
}
