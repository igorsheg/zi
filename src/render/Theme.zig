const std = @import("std");

const Theme = @This();

pub const Style = struct {
    open: []const u8,
    close: []const u8,
};

pub const Name = enum {
    dark,
    light,
    ansi,
    off,
};

pub const Tint = enum {
    teal,
    violet,
    rose,
    sage,
};

pub const Inputs = struct {
    /// Configured theme name: auto, dark, light, ansi, or off.
    configured_theme: []const u8,
    /// Effective configured tint after all configuration precedence is applied.
    configured_tint: []const u8,
    /// Borrowed environment snapshots. Null means unset; empty means set to an empty value.
    no_color: ?[]const u8 = null,
    term: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    colorfgbg: ?[]const u8 = null,
};

pub const Error = error{
    UnknownTheme,
    UnknownTint,
};

name: Name,
tint: Tint,
accent: Style,
chrome: Style,
chrome_dim: Style,
stance: Style,
error_style: Style,

/// Resolves borrowed configuration and environment snapshots into a value-only theme.
/// The returned styles refer only to static strings and require no deinitialization.
pub fn resolve(inputs: Inputs) Error!Theme {
    const name = try parseTheme(inputs.configured_theme, inputs);
    const tint = try parseTint(inputs.configured_tint);
    return preset(name, tint);
}

fn parseTheme(value: []const u8, inputs: Inputs) Error!Name {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return autodetect(inputs);
    if (std.ascii.eqlIgnoreCase(value, "dark")) return .dark;
    if (std.ascii.eqlIgnoreCase(value, "light")) return .light;
    if (std.ascii.eqlIgnoreCase(value, "ansi")) return .ansi;
    if (std.ascii.eqlIgnoreCase(value, "off")) return .off;
    return error.UnknownTheme;
}

fn parseTint(value: []const u8) Error!Tint {
    if (std.ascii.eqlIgnoreCase(value, "teal")) return .teal;
    if (std.ascii.eqlIgnoreCase(value, "violet")) return .violet;
    if (std.ascii.eqlIgnoreCase(value, "rose")) return .rose;
    if (std.ascii.eqlIgnoreCase(value, "sage")) return .sage;
    return error.UnknownTint;
}

/// Matches hax auto resolution, including its case-sensitive TERM and COLORFGBG checks.
fn autodetect(inputs: Inputs) Name {
    if (inputs.no_color) |value| {
        if (value.len != 0) return .off;
    }

    const term = inputs.term orelse return .off;
    if (term.len == 0 or std.mem.eql(u8, term, "dumb")) return .off;

    const has_colorterm = if (inputs.colorterm) |value| value.len != 0 else false;
    if (std.mem.indexOf(u8, term, "256color") == null and !has_colorterm) return .ansi;

    if (inputs.colorfgbg) |value| {
        if (std.mem.findScalarLast(u8, value, ';')) |separator| {
            const background = value[separator + 1 ..];
            if (std.mem.eql(u8, background, "7") or std.mem.eql(u8, background, "15")) return .light;
        }
    }
    return .dark;
}

const fg_default = "\x1b[39m";
const bold_off = "\x1b[22m";

fn color(open: []const u8) Style {
    return .{ .open = open, .close = fg_default };
}

fn preset(name: Name, tint: Tint) Theme {
    return switch (name) {
        .ansi => .{
            .name = .ansi,
            .tint = tint,
            .accent = color("\x1b[95m"),
            .chrome = color("\x1b[36m"),
            .chrome_dim = .{ .open = "\x1b[2m\x1b[36m", .close = fg_default ++ bold_off },
            .stance = color("\x1b[36m"),
            .error_style = color("\x1b[31m"),
        },
        .dark => .{
            .name = .dark,
            .tint = tint,
            .accent = color("\x1b[38;5;173m"),
            .chrome = color("\x1b[38;5;37m"),
            .chrome_dim = color("\x1b[38;5;23m"),
            .stance = color(darkStance(tint)),
            .error_style = color("\x1b[38;5;160m"),
        },
        .light => .{
            .name = .light,
            .tint = tint,
            .accent = color("\x1b[38;5;130m"),
            .chrome = color("\x1b[38;5;30m"),
            .chrome_dim = color("\x1b[38;5;37m"),
            .stance = color(lightStance(tint)),
            .error_style = color("\x1b[38;5;160m"),
        },
        .off => .{
            .name = .off,
            .tint = tint,
            .accent = .{ .open = "", .close = "" },
            .chrome = .{ .open = "", .close = "" },
            .chrome_dim = .{ .open = "\x1b[2m", .close = bold_off },
            .stance = .{ .open = "", .close = "" },
            .error_style = .{ .open = "", .close = "" },
        },
    };
}

fn darkStance(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[38;5;38m",
        .violet => "\x1b[38;5;140m",
        .rose => "\x1b[38;5;168m",
        .sage => "\x1b[38;5;114m",
    };
}

fn lightStance(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[38;5;31m",
        .violet => "\x1b[38;5;97m",
        .rose => "\x1b[38;5;132m",
        .sage => "\x1b[38;5;71m",
    };
}

fn expectStyle(expected: Style, actual: Style) !void {
    try std.testing.expectEqualStrings(expected.open, actual.open);
    try std.testing.expectEqualStrings(expected.close, actual.close);
}

test "all explicit themes preserve presentation role palettes" {
    const ansi = try resolve(.{ .configured_theme = "ANSI", .configured_tint = "SAGE" });
    try std.testing.expectEqual(Name.ansi, ansi.name);
    try std.testing.expectEqual(Tint.sage, ansi.tint);
    try expectStyle(color("\x1b[95m"), ansi.accent);
    try expectStyle(color("\x1b[36m"), ansi.chrome);
    try expectStyle(.{ .open = "\x1b[2m\x1b[36m", .close = "\x1b[39m\x1b[22m" }, ansi.chrome_dim);
    try expectStyle(color("\x1b[36m"), ansi.stance);

    const dark = try resolve(.{ .configured_theme = "dark", .configured_tint = "teal" });
    try expectStyle(color("\x1b[38;5;173m"), dark.accent);
    try expectStyle(color("\x1b[38;5;37m"), dark.chrome);
    try expectStyle(color("\x1b[38;5;23m"), dark.chrome_dim);
    try expectStyle(color("\x1b[38;5;38m"), dark.stance);

    const light = try resolve(.{ .configured_theme = "light", .configured_tint = "teal" });
    try expectStyle(color("\x1b[38;5;130m"), light.accent);
    try expectStyle(color("\x1b[38;5;30m"), light.chrome);
    try expectStyle(color("\x1b[38;5;37m"), light.chrome_dim);
    try expectStyle(color("\x1b[38;5;31m"), light.stance);

    const off = try resolve(.{ .configured_theme = "Off", .configured_tint = "Violet" });
    try expectStyle(.{ .open = "", .close = "" }, off.accent);
    try expectStyle(.{ .open = "", .close = "" }, off.chrome);
    try expectStyle(.{ .open = "\x1b[2m", .close = "\x1b[22m" }, off.chrome_dim);
    try expectStyle(.{ .open = "", .close = "" }, off.stance);
}

test "dark and light apply every tint only to stance" {
    const tint_names = [_][]const u8{ "teal", "violet", "rose", "sage" };
    const dark_opens = [_][]const u8{
        "\x1b[38;5;38m",
        "\x1b[38;5;140m",
        "\x1b[38;5;168m",
        "\x1b[38;5;114m",
    };
    const light_opens = [_][]const u8{
        "\x1b[38;5;31m",
        "\x1b[38;5;97m",
        "\x1b[38;5;132m",
        "\x1b[38;5;71m",
    };

    for (tint_names, dark_opens, light_opens) |tint_name, dark_open, light_open| {
        const dark = try resolve(.{ .configured_theme = "dark", .configured_tint = tint_name });
        const light = try resolve(.{ .configured_theme = "light", .configured_tint = tint_name });
        try std.testing.expectEqualStrings(dark_open, dark.stance.open);
        try std.testing.expectEqualStrings(light_open, light.stance.open);
        try std.testing.expectEqualStrings("\x1b[38;5;173m", dark.accent.open);
        try std.testing.expectEqualStrings("\x1b[38;5;130m", light.accent.open);
    }
}

test "ansi and off ignore every valid tint" {
    const tint_names = [_][]const u8{ "teal", "violet", "rose", "sage" };
    for (tint_names) |tint_name| {
        const ansi = try resolve(.{ .configured_theme = "ansi", .configured_tint = tint_name });
        const off = try resolve(.{ .configured_theme = "off", .configured_tint = tint_name });
        try std.testing.expectEqualStrings("\x1b[36m", ansi.stance.open);
        try std.testing.expectEqualStrings("", off.stance.open);
    }
}

test "auto resolution matches environment precedence and background hints" {
    const cases = [_]struct {
        no_color: ?[]const u8 = null,
        term: ?[]const u8 = null,
        colorterm: ?[]const u8 = null,
        colorfgbg: ?[]const u8 = null,
        expected: Name,
    }{
        .{ .expected = .off },
        .{ .term = "", .expected = .off },
        .{ .term = "dumb", .expected = .off },
        .{ .no_color = "1", .term = "xterm-256color", .expected = .off },
        .{ .no_color = "", .term = "vt100", .expected = .ansi },
        .{ .term = "vt100", .colorterm = "truecolor", .expected = .dark },
        .{ .term = "xterm-256color", .expected = .dark },
        .{ .term = "xterm-256color", .colorfgbg = "0;15", .expected = .light },
        .{ .term = "xterm-256color", .colorfgbg = "12;default;7", .expected = .light },
        .{ .term = "xterm-256color", .colorfgbg = "15;0", .expected = .dark },
        .{ .term = "xterm-256color", .colorfgbg = "15", .expected = .dark },
    };

    for (cases) |case| {
        const resolved = try resolve(.{
            .configured_theme = "auto",
            .configured_tint = "teal",
            .no_color = case.no_color,
            .term = case.term,
            .colorterm = case.colorterm,
            .colorfgbg = case.colorfgbg,
        });
        try std.testing.expectEqual(case.expected, resolved.name);
    }
}

test "unknown configured values return validation errors" {
    try std.testing.expectError(error.UnknownTheme, resolve(.{
        .configured_theme = "solarized",
        .configured_tint = "teal",
    }));
    try std.testing.expectError(error.UnknownTheme, resolve(.{
        .configured_theme = "",
        .configured_tint = "teal",
    }));
    try std.testing.expectError(error.UnknownTint, resolve(.{
        .configured_theme = "dark",
        .configured_tint = "chartreuse",
    }));
    try std.testing.expectError(error.UnknownTint, resolve(.{
        .configured_theme = "auto",
        .configured_tint = "",
    }));
}
