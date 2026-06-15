//! Line classifier for assistant text: headings, quotes, lists, code fences,
//! and horizontal rules get distinct prefixes and styles. This is per-line
//! presentation policy, not a markdown AST; inline emphasis is out of scope.
const std = @import("std");
const glyphs = @import("glyphs.zig");
const theme_mod = @import("theme.zig");

pub const State = struct {
    fence: Fence = .none,

    pub const Fence = enum { none, backtick, tilde };
};

pub const LineKind = enum { plain, heading, quote, list, code, horizontal_rule };

pub const Projection = struct {
    kind: LineKind,
    prefix: []const u8 = "",
    text: []const u8,
    /// Whether wrapped continuation rows repeat the prefix (quotes/code do;
    /// list markers indent instead).
    repeat_prefix: bool = false,
    prefix_style: theme_mod.Style,
    text_style: theme_mod.Style,
    row_style: theme_mod.Style,
};

pub fn classifyLine(state: *State, line: []const u8, theme: *const theme_mod.Theme) Projection {
    if (state.fence != .none) {
        if (fenceMarker(line)) |marker| {
            if (marker == state.fence) state.* = .{};
        }
        return codeProjection(line, theme);
    }

    if (fenceMarker(line)) |marker| {
        state.fence = marker;
        return codeProjection(line, theme);
    }

    const trimmed = trimLeft(line);
    if (horizontalRule(trimmed)) {
        return .{
            .kind = .horizontal_rule,
            .text = glyphs.horizontal_rule,
            .prefix_style = theme.transcript_secondary,
            .text_style = theme.transcript_secondary,
            .row_style = theme.transcript_secondary,
        };
    }
    if (heading(trimmed)) |content| {
        return .{
            .kind = .heading,
            .text = content,
            .prefix_style = theme.status_accent,
            .text_style = theme.status_accent,
            .row_style = theme.transcript_text,
        };
    }
    if (quote(trimmed)) |content| {
        return .{
            .kind = .quote,
            .prefix = glyphs.quote_prefix,
            .text = content,
            .repeat_prefix = true,
            .prefix_style = theme.transcript_secondary,
            .text_style = theme.transcript_text,
            .row_style = theme.transcript_text,
        };
    }
    if (list(trimmed)) |parts| {
        return .{
            .kind = .list,
            .prefix = parts.prefix,
            .text = parts.text,
            .repeat_prefix = false,
            .prefix_style = theme.status_accent,
            .text_style = theme.transcript_text,
            .row_style = theme.transcript_text,
        };
    }
    return .{
        .kind = .plain,
        .text = line,
        .prefix_style = theme.transcript_text,
        .text_style = theme.transcript_text,
        .row_style = theme.transcript_text,
    };
}

fn codeProjection(line: []const u8, theme: *const theme_mod.Theme) Projection {
    return .{
        .kind = .code,
        .prefix = "  ",
        .text = line,
        .repeat_prefix = true,
        .prefix_style = theme.transcript_secondary,
        .text_style = theme.tool_output,
        .row_style = theme.transcript_text,
    };
}

fn fenceMarker(line: []const u8) ?State.Fence {
    const trimmed = trimLeft(line);
    if (std.mem.startsWith(u8, trimmed, "```")) return .backtick;
    if (std.mem.startsWith(u8, trimmed, "~~~")) return .tilde;
    return null;
}

fn heading(line: []const u8) ?[]const u8 {
    var level: usize = 0;
    while (level < line.len and level < 3 and line[level] == '#') : (level += 1) {}
    if (level == 0) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return trimLeft(line[level + 1 ..]);
}

fn quote(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '>') return null;
    var content = line[1..];
    if (content.len > 0 and content[0] == ' ') content = content[1..];
    return content;
}

const ListParts = struct {
    prefix: []const u8,
    text: []const u8,
};

fn list(line: []const u8) ?ListParts {
    if (line.len >= 2 and isUnorderedMarker(line[0]) and line[1] == ' ') {
        return .{ .prefix = line[0..2], .text = line[2..] };
    }
    var index: usize = 0;
    while (index < line.len and std.ascii.isDigit(line[index])) : (index += 1) {}
    if (index == 0 or index + 1 >= line.len) return null;
    if (line[index] != '.' or line[index + 1] != ' ') return null;
    return .{ .prefix = line[0 .. index + 2], .text = line[index + 2 ..] };
}

fn isUnorderedMarker(byte: u8) bool {
    return byte == '-' or byte == '*' or byte == '+';
}

fn horizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const marker = line[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    for (line) |byte| {
        if (byte != marker and byte != ' ' and byte != '\t') return false;
    }
    return true;
}

fn trimLeft(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return bytes[index..];
}

test "classifyLine tracks fences and recognizes structures" {
    const theme = theme_mod.Theme.codex(.{});
    var state: State = .{};

    try std.testing.expectEqual(LineKind.heading, classifyLine(&state, "# Title", &theme).kind);
    try std.testing.expectEqual(LineKind.quote, classifyLine(&state, "> quoted", &theme).kind);
    try std.testing.expectEqual(LineKind.list, classifyLine(&state, "12. item", &theme).kind);
    try std.testing.expectEqual(LineKind.horizontal_rule, classifyLine(&state, "---", &theme).kind);

    try std.testing.expectEqual(LineKind.code, classifyLine(&state, "```zig", &theme).kind);
    // Inside a fence everything is code, including would-be headings.
    try std.testing.expectEqual(LineKind.code, classifyLine(&state, "# not a heading", &theme).kind);
    try std.testing.expectEqual(LineKind.code, classifyLine(&state, "```", &theme).kind);
    try std.testing.expectEqual(LineKind.plain, classifyLine(&state, "after", &theme).kind);
}

test "list marker requires a space and ordered lists keep their numbers" {
    const theme = theme_mod.Theme.codex(.{});
    var state: State = .{};
    try std.testing.expectEqual(LineKind.plain, classifyLine(&state, "-no space", &theme).kind);
    const ordered = classifyLine(&state, "3. third", &theme);
    try std.testing.expectEqualStrings("3. ", ordered.prefix);
    try std.testing.expectEqualStrings("third", ordered.text);
}
