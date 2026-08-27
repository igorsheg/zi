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
code_inline: Style,
code_block: Style,
heading: Style,
link: Style,
add: Style,
remove: Style,
ok: Style,
error_style: Style,
warn: Style,

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
const bold = "\x1b[1m";
const bold_off = "\x1b[22m";
const dim = "\x1b[2m";
const underline = "\x1b[4m";
const underline_off = "\x1b[24m";
const link_close = "\x1b[24;39m";

fn color(open: []const u8) Style {
    return .{ .open = open, .close = fg_default };
}

fn plain(open: []const u8, close: []const u8) Style {
    return .{ .open = open, .close = close };
}

fn preset(name: Name, tint: Tint) Theme {
    return switch (name) {
        .ansi => .{
            .name = .ansi,
            .tint = tint,
            .accent = color("\x1b[95m"),
            .chrome = color("\x1b[36m"),
            .chrome_dim = plain(dim ++ "\x1b[36m", fg_default ++ bold_off),
            .stance = color("\x1b[36m"),
            .code_inline = color("\x1b[36m"),
            .code_block = plain(dim, bold_off),
            .heading = plain(bold, bold_off),
            .link = plain(underline, underline_off),
            .add = color("\x1b[32m"),
            .remove = color("\x1b[31m"),
            .ok = color("\x1b[32m"),
            .error_style = color("\x1b[31m"),
            .warn = color("\x1b[33m"),
        },
        .dark => .{
            .name = .dark,
            .tint = tint,
            .accent = color("\x1b[38;5;173m"),
            .chrome = color("\x1b[38;5;37m"),
            .chrome_dim = color("\x1b[38;5;23m"),
            .stance = color(darkPrimary(tint)),
            .code_inline = color(darkPrimary(tint)),
            .code_block = color(darkSecondary(tint)),
            .heading = plain(darkHeading(tint), bold_off ++ fg_default),
            .link = plain(darkLink(tint), link_close),
            .add = color("\x1b[38;5;34m"),
            .remove = color("\x1b[38;5;160m"),
            .ok = color("\x1b[38;5;28m"),
            .error_style = color("\x1b[38;5;160m"),
            .warn = color("\x1b[38;5;178m"),
        },
        .light => .{
            .name = .light,
            .tint = tint,
            .accent = color("\x1b[38;5;130m"),
            .chrome = color("\x1b[38;5;30m"),
            .chrome_dim = color("\x1b[38;5;37m"),
            .stance = color(lightPrimary(tint)),
            .code_inline = color(lightPrimary(tint)),
            .code_block = color(lightSecondary(tint)),
            .heading = plain(lightHeading(tint), bold_off ++ fg_default),
            .link = plain(lightLink(tint), link_close),
            .add = color("\x1b[38;5;28m"),
            .remove = color("\x1b[38;5;124m"),
            .ok = color("\x1b[38;5;28m"),
            .error_style = color("\x1b[38;5;160m"),
            .warn = color("\x1b[38;5;136m"),
        },
        .off => .{
            .name = .off,
            .tint = tint,
            .accent = plain("", ""),
            .chrome = plain("", ""),
            .chrome_dim = plain(dim, bold_off),
            .stance = plain("", ""),
            .code_inline = plain("", ""),
            .code_block = plain(dim, bold_off),
            .heading = plain(bold, bold_off),
            .link = plain(underline, underline_off),
            .add = plain("", ""),
            .remove = plain("", ""),
            .ok = plain("", ""),
            .error_style = plain("", ""),
            .warn = plain("", ""),
        },
    };
}

fn darkPrimary(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[38;5;38m",
        .violet => "\x1b[38;5;140m",
        .rose => "\x1b[38;5;168m",
        .sage => "\x1b[38;5;114m",
    };
}

fn darkSecondary(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[38;5;31m",
        .violet => "\x1b[38;5;97m",
        .rose => "\x1b[38;5;132m",
        .sage => "\x1b[38;5;71m",
    };
}

fn darkHeading(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => bold ++ "\x1b[38;5;38m",
        .violet => bold ++ "\x1b[38;5;140m",
        .rose => bold ++ "\x1b[38;5;168m",
        .sage => bold ++ "\x1b[38;5;114m",
    };
}

fn darkLink(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[4;38;5;31m",
        .violet => "\x1b[4;38;5;97m",
        .rose => "\x1b[4;38;5;132m",
        .sage => "\x1b[4;38;5;71m",
    };
}

fn lightPrimary(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[38;5;31m",
        .violet => "\x1b[38;5;97m",
        .rose => "\x1b[38;5;132m",
        .sage => "\x1b[38;5;71m",
    };
}

fn lightSecondary(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[38;5;38m",
        .violet => "\x1b[38;5;140m",
        .rose => "\x1b[38;5;168m",
        .sage => "\x1b[38;5;114m",
    };
}

fn lightHeading(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => bold ++ "\x1b[38;5;31m",
        .violet => bold ++ "\x1b[38;5;97m",
        .rose => bold ++ "\x1b[38;5;132m",
        .sage => bold ++ "\x1b[38;5;71m",
    };
}

fn lightLink(tint: Tint) []const u8 {
    return switch (tint) {
        .teal => "\x1b[4;38;5;38m",
        .violet => "\x1b[4;38;5;140m",
        .rose => "\x1b[4;38;5;168m",
        .sage => "\x1b[4;38;5;114m",
    };
}

fn expectStyle(expected: Style, actual: Style) !void {
    try std.testing.expectEqualStrings(expected.open, actual.open);
    try std.testing.expectEqualStrings(expected.close, actual.close);
}

test "all explicit themes preserve exact base role palettes" {
    const ansi = try resolve(.{ .configured_theme = "ANSI", .configured_tint = "SAGE" });
    try std.testing.expectEqual(Name.ansi, ansi.name);
    try std.testing.expectEqual(Tint.sage, ansi.tint);
    try expectStyle(color("\x1b[95m"), ansi.accent);
    try expectStyle(color("\x1b[36m"), ansi.chrome);
    try expectStyle(plain("\x1b[2m\x1b[36m", "\x1b[39m\x1b[22m"), ansi.chrome_dim);
    try expectStyle(color("\x1b[36m"), ansi.stance);
    try expectStyle(color("\x1b[36m"), ansi.code_inline);
    try expectStyle(plain("\x1b[2m", "\x1b[22m"), ansi.code_block);
    try expectStyle(plain("\x1b[1m", "\x1b[22m"), ansi.heading);
    try expectStyle(plain("\x1b[4m", "\x1b[24m"), ansi.link);
    try expectStyle(color("\x1b[32m"), ansi.add);
    try expectStyle(color("\x1b[31m"), ansi.remove);
    try expectStyle(color("\x1b[32m"), ansi.ok);
    try expectStyle(color("\x1b[31m"), ansi.error_style);
    try expectStyle(color("\x1b[33m"), ansi.warn);

    const dark = try resolve(.{ .configured_theme = "dark", .configured_tint = "teal" });
    try expectStyle(color("\x1b[38;5;173m"), dark.accent);
    try expectStyle(color("\x1b[38;5;37m"), dark.chrome);
    try expectStyle(color("\x1b[38;5;23m"), dark.chrome_dim);
    try expectStyle(color("\x1b[38;5;38m"), dark.stance);
    try expectStyle(color("\x1b[38;5;38m"), dark.code_inline);
    try expectStyle(color("\x1b[38;5;31m"), dark.code_block);
    try expectStyle(plain("\x1b[1m\x1b[38;5;38m", "\x1b[22m\x1b[39m"), dark.heading);
    try expectStyle(plain("\x1b[4;38;5;31m", "\x1b[24;39m"), dark.link);
    try expectStyle(color("\x1b[38;5;34m"), dark.add);
    try expectStyle(color("\x1b[38;5;160m"), dark.remove);
    try expectStyle(color("\x1b[38;5;28m"), dark.ok);
    try expectStyle(color("\x1b[38;5;160m"), dark.error_style);
    try expectStyle(color("\x1b[38;5;178m"), dark.warn);

    const light = try resolve(.{ .configured_theme = "light", .configured_tint = "teal" });
    try expectStyle(color("\x1b[38;5;130m"), light.accent);
    try expectStyle(color("\x1b[38;5;30m"), light.chrome);
    try expectStyle(color("\x1b[38;5;37m"), light.chrome_dim);
    try expectStyle(color("\x1b[38;5;31m"), light.stance);
    try expectStyle(color("\x1b[38;5;31m"), light.code_inline);
    try expectStyle(color("\x1b[38;5;38m"), light.code_block);
    try expectStyle(plain("\x1b[1m\x1b[38;5;31m", "\x1b[22m\x1b[39m"), light.heading);
    try expectStyle(plain("\x1b[4;38;5;38m", "\x1b[24;39m"), light.link);
    try expectStyle(color("\x1b[38;5;28m"), light.add);
    try expectStyle(color("\x1b[38;5;124m"), light.remove);
    try expectStyle(color("\x1b[38;5;28m"), light.ok);
    try expectStyle(color("\x1b[38;5;160m"), light.error_style);
    try expectStyle(color("\x1b[38;5;136m"), light.warn);

    const off = try resolve(.{ .configured_theme = "Off", .configured_tint = "Violet" });
    try expectStyle(plain("", ""), off.accent);
    try expectStyle(plain("", ""), off.chrome);
    try expectStyle(plain("\x1b[2m", "\x1b[22m"), off.chrome_dim);
    try expectStyle(plain("", ""), off.stance);
    try expectStyle(plain("", ""), off.code_inline);
    try expectStyle(plain("\x1b[2m", "\x1b[22m"), off.code_block);
    try expectStyle(plain("\x1b[1m", "\x1b[22m"), off.heading);
    try expectStyle(plain("\x1b[4m", "\x1b[24m"), off.link);
    try expectStyle(plain("", ""), off.add);
    try expectStyle(plain("", ""), off.remove);
    try expectStyle(plain("", ""), off.ok);
    try expectStyle(plain("", ""), off.error_style);
    try expectStyle(plain("", ""), off.warn);
}

test "dark and light apply every tint to all model roles" {
    const tint_names = [_][]const u8{ "teal", "violet", "rose", "sage" };
    const dark_primary = [_][]const u8{
        "\x1b[38;5;38m",
        "\x1b[38;5;140m",
        "\x1b[38;5;168m",
        "\x1b[38;5;114m",
    };
    const dark_secondary = [_][]const u8{
        "\x1b[38;5;31m",
        "\x1b[38;5;97m",
        "\x1b[38;5;132m",
        "\x1b[38;5;71m",
    };
    const dark_headings = [_][]const u8{
        "\x1b[1m\x1b[38;5;38m",
        "\x1b[1m\x1b[38;5;140m",
        "\x1b[1m\x1b[38;5;168m",
        "\x1b[1m\x1b[38;5;114m",
    };
    const dark_links = [_][]const u8{
        "\x1b[4;38;5;31m",
        "\x1b[4;38;5;97m",
        "\x1b[4;38;5;132m",
        "\x1b[4;38;5;71m",
    };

    for (tint_names, dark_primary, dark_secondary, dark_headings, dark_links) |
        tint_name,
        primary,
        secondary,
        heading_open,
        link_open,
    | {
        const dark = try resolve(.{ .configured_theme = "dark", .configured_tint = tint_name });
        try std.testing.expectEqualStrings(primary, dark.stance.open);
        try std.testing.expectEqualStrings(primary, dark.code_inline.open);
        try std.testing.expectEqualStrings(secondary, dark.code_block.open);
        try std.testing.expectEqualStrings(heading_open, dark.heading.open);
        try std.testing.expectEqualStrings("\x1b[22m\x1b[39m", dark.heading.close);
        try std.testing.expectEqualStrings(link_open, dark.link.open);
        try std.testing.expectEqualStrings("\x1b[24;39m", dark.link.close);
    }

    const light_primary = dark_secondary;
    const light_secondary = dark_primary;
    const light_headings = [_][]const u8{
        "\x1b[1m\x1b[38;5;31m",
        "\x1b[1m\x1b[38;5;97m",
        "\x1b[1m\x1b[38;5;132m",
        "\x1b[1m\x1b[38;5;71m",
    };
    const light_links = [_][]const u8{
        "\x1b[4;38;5;38m",
        "\x1b[4;38;5;140m",
        "\x1b[4;38;5;168m",
        "\x1b[4;38;5;114m",
    };

    for (tint_names, light_primary, light_secondary, light_headings, light_links) |
        tint_name,
        primary,
        secondary,
        heading_open,
        link_open,
    | {
        const light = try resolve(.{ .configured_theme = "light", .configured_tint = tint_name });
        try std.testing.expectEqualStrings(primary, light.stance.open);
        try std.testing.expectEqualStrings(primary, light.code_inline.open);
        try std.testing.expectEqualStrings(secondary, light.code_block.open);
        try std.testing.expectEqualStrings(heading_open, light.heading.open);
        try std.testing.expectEqualStrings("\x1b[22m\x1b[39m", light.heading.close);
        try std.testing.expectEqualStrings(link_open, light.link.open);
        try std.testing.expectEqualStrings("\x1b[24;39m", light.link.close);
    }
}

test "ansi and off ignore every valid tint" {
    const tint_names = [_][]const u8{ "teal", "violet", "rose", "sage" };
    for (tint_names) |tint_name| {
        const ansi = try resolve(.{ .configured_theme = "ansi", .configured_tint = tint_name });
        const off = try resolve(.{ .configured_theme = "off", .configured_tint = tint_name });
        try std.testing.expectEqualStrings("\x1b[36m", ansi.stance.open);
        try std.testing.expectEqualStrings("\x1b[36m", ansi.code_inline.open);
        try std.testing.expectEqualStrings("\x1b[2m", ansi.code_block.open);
        try std.testing.expectEqualStrings("\x1b[1m", ansi.heading.open);
        try std.testing.expectEqualStrings("\x1b[4m", ansi.link.open);
        try std.testing.expectEqualStrings("", off.stance.open);
        try std.testing.expectEqualStrings("", off.code_inline.open);
        try std.testing.expectEqualStrings("\x1b[2m", off.code_block.open);
        try std.testing.expectEqualStrings("\x1b[1m", off.heading.open);
        try std.testing.expectEqualStrings("\x1b[4m", off.link.open);
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
