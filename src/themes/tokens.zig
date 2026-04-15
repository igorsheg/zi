const std = @import("std");

pub const TokenKind = enum {
    fg,
    bg,
};

pub const FgColor = enum {
    accent,
    border,
    border_accent,
    border_muted,
    success,
    @"error",
    warning,
    muted,
    dim,
    text,
    thinking_text,
    user_message_text,
    custom_message_text,
    custom_message_label,
    tool_title,
    tool_output,
    md_heading,
    md_link,
    md_link_url,
    md_code,
    md_code_block,
    md_code_block_border,
    md_quote,
    md_quote_border,
    md_hr,
    md_list_bullet,
    tool_diff_added,
    tool_diff_removed,
    tool_diff_context,
    syntax_comment,
    syntax_keyword,
    syntax_function,
    syntax_variable,
    syntax_string,
    syntax_number,
    syntax_type,
    syntax_operator,
    syntax_punctuation,
    thinking_off,
    thinking_minimal,
    thinking_low,
    thinking_medium,
    thinking_high,
    thinking_xhigh,
    bash_mode,
};

pub const BgColor = enum {
    selected_bg,
    user_message_bg,
    custom_message_bg,
    tool_pending_bg,
    tool_success_bg,
    tool_error_bg,
};

pub const FgTokenInfo = struct {
    value: FgColor,
    zig_name: []const u8,
    wire_name: []const u8,
    kind: TokenKind = .fg,
};

pub const BgTokenInfo = struct {
    value: BgColor,
    zig_name: []const u8,
    wire_name: []const u8,
    kind: TokenKind = .bg,
};

pub const fg_tokens = [_]FgTokenInfo{
    .{ .value = .accent, .zig_name = "accent", .wire_name = "accent" },
    .{ .value = .border, .zig_name = "border", .wire_name = "border" },
    .{ .value = .border_accent, .zig_name = "border_accent", .wire_name = "borderAccent" },
    .{ .value = .border_muted, .zig_name = "border_muted", .wire_name = "borderMuted" },
    .{ .value = .success, .zig_name = "success", .wire_name = "success" },
    .{ .value = .@"error", .zig_name = "error", .wire_name = "error" },
    .{ .value = .warning, .zig_name = "warning", .wire_name = "warning" },
    .{ .value = .muted, .zig_name = "muted", .wire_name = "muted" },
    .{ .value = .dim, .zig_name = "dim", .wire_name = "dim" },
    .{ .value = .text, .zig_name = "text", .wire_name = "text" },
    .{ .value = .thinking_text, .zig_name = "thinking_text", .wire_name = "thinkingText" },
    .{ .value = .user_message_text, .zig_name = "user_message_text", .wire_name = "userMessageText" },
    .{ .value = .custom_message_text, .zig_name = "custom_message_text", .wire_name = "customMessageText" },
    .{ .value = .custom_message_label, .zig_name = "custom_message_label", .wire_name = "customMessageLabel" },
    .{ .value = .tool_title, .zig_name = "tool_title", .wire_name = "toolTitle" },
    .{ .value = .tool_output, .zig_name = "tool_output", .wire_name = "toolOutput" },
    .{ .value = .md_heading, .zig_name = "md_heading", .wire_name = "mdHeading" },
    .{ .value = .md_link, .zig_name = "md_link", .wire_name = "mdLink" },
    .{ .value = .md_link_url, .zig_name = "md_link_url", .wire_name = "mdLinkUrl" },
    .{ .value = .md_code, .zig_name = "md_code", .wire_name = "mdCode" },
    .{ .value = .md_code_block, .zig_name = "md_code_block", .wire_name = "mdCodeBlock" },
    .{ .value = .md_code_block_border, .zig_name = "md_code_block_border", .wire_name = "mdCodeBlockBorder" },
    .{ .value = .md_quote, .zig_name = "md_quote", .wire_name = "mdQuote" },
    .{ .value = .md_quote_border, .zig_name = "md_quote_border", .wire_name = "mdQuoteBorder" },
    .{ .value = .md_hr, .zig_name = "md_hr", .wire_name = "mdHr" },
    .{ .value = .md_list_bullet, .zig_name = "md_list_bullet", .wire_name = "mdListBullet" },
    .{ .value = .tool_diff_added, .zig_name = "tool_diff_added", .wire_name = "toolDiffAdded" },
    .{ .value = .tool_diff_removed, .zig_name = "tool_diff_removed", .wire_name = "toolDiffRemoved" },
    .{ .value = .tool_diff_context, .zig_name = "tool_diff_context", .wire_name = "toolDiffContext" },
    .{ .value = .syntax_comment, .zig_name = "syntax_comment", .wire_name = "syntaxComment" },
    .{ .value = .syntax_keyword, .zig_name = "syntax_keyword", .wire_name = "syntaxKeyword" },
    .{ .value = .syntax_function, .zig_name = "syntax_function", .wire_name = "syntaxFunction" },
    .{ .value = .syntax_variable, .zig_name = "syntax_variable", .wire_name = "syntaxVariable" },
    .{ .value = .syntax_string, .zig_name = "syntax_string", .wire_name = "syntaxString" },
    .{ .value = .syntax_number, .zig_name = "syntax_number", .wire_name = "syntaxNumber" },
    .{ .value = .syntax_type, .zig_name = "syntax_type", .wire_name = "syntaxType" },
    .{ .value = .syntax_operator, .zig_name = "syntax_operator", .wire_name = "syntaxOperator" },
    .{ .value = .syntax_punctuation, .zig_name = "syntax_punctuation", .wire_name = "syntaxPunctuation" },
    .{ .value = .thinking_off, .zig_name = "thinking_off", .wire_name = "thinkingOff" },
    .{ .value = .thinking_minimal, .zig_name = "thinking_minimal", .wire_name = "thinkingMinimal" },
    .{ .value = .thinking_low, .zig_name = "thinking_low", .wire_name = "thinkingLow" },
    .{ .value = .thinking_medium, .zig_name = "thinking_medium", .wire_name = "thinkingMedium" },
    .{ .value = .thinking_high, .zig_name = "thinking_high", .wire_name = "thinkingHigh" },
    .{ .value = .thinking_xhigh, .zig_name = "thinking_xhigh", .wire_name = "thinkingXhigh" },
    .{ .value = .bash_mode, .zig_name = "bash_mode", .wire_name = "bashMode" },
};

pub const bg_tokens = [_]BgTokenInfo{
    .{ .value = .selected_bg, .zig_name = "selected_bg", .wire_name = "selectedBg" },
    .{ .value = .user_message_bg, .zig_name = "user_message_bg", .wire_name = "userMessageBg" },
    .{ .value = .custom_message_bg, .zig_name = "custom_message_bg", .wire_name = "customMessageBg" },
    .{ .value = .tool_pending_bg, .zig_name = "tool_pending_bg", .wire_name = "toolPendingBg" },
    .{ .value = .tool_success_bg, .zig_name = "tool_success_bg", .wire_name = "toolSuccessBg" },
    .{ .value = .tool_error_bg, .zig_name = "tool_error_bg", .wire_name = "toolErrorBg" },
};

pub fn parseFgWireName(name: []const u8) ?FgColor {
    for (fg_tokens) |token| {
        if (std.mem.eql(u8, name, token.wire_name)) return token.value;
    }
    return null;
}

pub fn parseBgWireName(name: []const u8) ?BgColor {
    for (bg_tokens) |token| {
        if (std.mem.eql(u8, name, token.wire_name)) return token.value;
    }
    return null;
}

pub fn fgWireName(token: FgColor) []const u8 {
    return fg_tokens[@intFromEnum(token)].wire_name;
}

pub fn bgWireName(token: BgColor) []const u8 {
    return bg_tokens[@intFromEnum(token)].wire_name;
}

comptime {
    const fg_fields = @typeInfo(FgColor).@"enum".fields;
    if (fg_fields.len != fg_tokens.len) @compileError("fg_tokens must cover every FgColor");
    for (fg_fields, 0..) |field, i| {
        if (!std.mem.eql(u8, field.name, fg_tokens[i].zig_name)) {
            @compileError("fg token order must match FgColor enum order");
        }
    }

    const bg_fields = @typeInfo(BgColor).@"enum".fields;
    if (bg_fields.len != bg_tokens.len) @compileError("bg_tokens must cover every BgColor");
    for (bg_fields, 0..) |field, i| {
        if (!std.mem.eql(u8, field.name, bg_tokens[i].zig_name)) {
            @compileError("bg token order must match BgColor enum order");
        }
    }
}

test "wire name parsers cover canonical pi-mono names" {
    try std.testing.expectEqual(FgColor.border_accent, parseFgWireName("borderAccent").?);
    try std.testing.expectEqual(FgColor.thinking_xhigh, parseFgWireName("thinkingXhigh").?);
    try std.testing.expectEqual(BgColor.tool_pending_bg, parseBgWireName("toolPendingBg").?);
    try std.testing.expect(parseBgWireName("tool_transcript_bg") == null);
}
