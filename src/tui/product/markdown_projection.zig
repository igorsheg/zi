const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme.zig");

pub const generated_text_bytes_max: usize = 160;
const horizontal_rule_line =
    "────────────────────────────────" ++
    "────────────────────────────────";
pub const fence_lang_bytes_max: usize = 32;

pub const State = struct {
    in_code_fence: bool = false,
    fence: Fence = .none,
    lang: []const u8 = "",
};

pub const Fence = enum { none, backtick, tilde };

pub const LineKind = enum {
    plain,
    heading,
    quote,
    list,
    code,
    horizontal_rule,
};

pub const Projection = struct {
    kind: LineKind,
    prefix: []const u8 = "",
    text: []const u8,
    repeat_prefix: bool = false,
    prefix_style: vaxis.Style,
    text_style: vaxis.Style,
    row_style: vaxis.Style,
    generated: bool = false,
};

pub fn classifyLine(
    state: *State,
    line: []const u8,
    theme: *const theme_mod.Theme,
    generated_buffer: []u8,
) Projection {
    if (state.in_code_fence) {
        if (fenceMarker(line)) |marker| {
            if (marker == state.fence) state.* = .{};
            return codeProjection(line, theme);
        }
        return codeProjection(line, theme);
    }

    if (fenceMarker(line)) |marker| {
        state.in_code_fence = true;
        state.fence = marker;
        state.lang = fenceLanguage(line);
        return codeProjection(line, theme);
    }

    const trimmed = trimLeft(line);
    if (horizontalRule(trimmed)) {
        return .{
            .kind = .horizontal_rule,
            .text = horizontalRuleText(generated_buffer),
            .text_style = theme.transcript_secondary,
            .prefix_style = theme.transcript_secondary,
            .row_style = theme.transcript_secondary,
            .generated = true,
        };
    }
    if (heading(trimmed)) |content| {
        return .{
            .kind = .heading,
            .text = content,
            .text_style = theme.status_accent,
            .prefix_style = theme.status_accent,
            .row_style = theme.transcript_text,
        };
    }
    if (quote(trimmed)) |content| {
        return .{
            .kind = .quote,
            .prefix = "│ ",
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
        .text_style = theme.transcript_text,
        .prefix_style = theme.transcript_text,
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

fn fenceMarker(line: []const u8) ?Fence {
    const trimmed = trimLeft(line);
    if (std.mem.startsWith(u8, trimmed, "```")) return .backtick;
    if (std.mem.startsWith(u8, trimmed, "~~~")) return .tilde;
    return null;
}

fn fenceLanguage(line: []const u8) []const u8 {
    const trimmed = trimLeft(line);
    if (trimmed.len <= 3) return "";
    const lang = trimLeft(trimmed[3..]);
    return lang[0..@min(lang.len, fence_lang_bytes_max)];
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

fn horizontalRuleText(buffer: []u8) []const u8 {
    _ = buffer;
    return horizontal_rule_line;
}

fn trimLeft(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index < bytes.len and (bytes[index] == ' ' or bytes[index] == '\t')) : (index += 1) {}
    return bytes[index..];
}
