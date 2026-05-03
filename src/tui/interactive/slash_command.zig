const std = @import("std");

pub const ParsedSlashCommand = struct {
    name: []const u8,
    args: []const u8,
};

pub const BuiltinInteractiveCommand = enum {
    quit,
    clear,
    new,
    compact,
    @"resume",
    fork,
    model,
    login,
    settings,
    hotkeys,
    memory,
};

pub fn parse(text: []const u8) ?ParsedSlashCommand {
    if (text.len == 0 or text[0] != '/') return null;
    const after_slash = text[1..];
    const space_idx = std.mem.indexOfScalar(u8, after_slash, ' ');
    const name = if (space_idx) |si| after_slash[0..si] else after_slash;
    if (name.len == 0) return null;
    const args = if (space_idx) |si| std.mem.trimStart(u8, after_slash[si + 1 ..], " ") else "";
    return .{ .name = name, .args = args };
}

pub fn builtinInteractiveCommand(name: []const u8) ?BuiltinInteractiveCommand {
    if (std.mem.eql(u8, name, "quit")) return .quit;
    if (std.mem.eql(u8, name, "clear")) return .clear;
    if (std.mem.eql(u8, name, "new")) return .new;
    if (std.mem.eql(u8, name, "compact")) return .compact;
    if (std.mem.eql(u8, name, "resume")) return .@"resume";
    if (std.mem.eql(u8, name, "fork")) return .fork;
    if (std.mem.eql(u8, name, "model")) return .model;
    if (std.mem.eql(u8, name, "login")) return .login;
    if (std.mem.eql(u8, name, "settings")) return .settings;
    if (std.mem.eql(u8, name, "hotkeys")) return .hotkeys;
    if (std.mem.eql(u8, name, "memory")) return .memory;
    return null;
}

test "parse splits slash command name and trimmed args" {
    const parsed = parse("/model   claude") orelse return error.MissingCommand;
    try std.testing.expectEqualStrings("model", parsed.name);
    try std.testing.expectEqualStrings("claude", parsed.args);
}

test "parse rejects empty slash command" {
    try std.testing.expect(parse("/") == null);
}
