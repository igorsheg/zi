const std = @import("std");

const QuoteMode = enum { none, double, single };

/// Removes a leading `cd TARGET &&` only when TARGET resolves lexically to cwd.
/// The returned suffix borrows `command`; null means the command must stay unchanged.
pub fn stripPrefix(
    command: []const u8,
    cwd: []const u8,
    home: ?[]const u8,
) ?[]const u8 {
    if (cwd.len == 0) return null;
    var cursor = skipHorizontal(command, 0);
    if (cursor + 2 >= command.len or !std.mem.eql(u8, command[cursor .. cursor + 2], "cd") or
        (command[cursor + 2] != ' ' and command[cursor + 2] != '\t')) return null;
    cursor = skipHorizontal(command, cursor + 2);

    const token_start: usize = if (cursor < command.len and
        (command[cursor] == '\'' or command[cursor] == '"')) cursor + 1 else cursor;
    const quote: QuoteMode = if (cursor < command.len and command[cursor] == '\'')
        .single
    else if (cursor < command.len and command[cursor] == '"')
        .double
    else
        .none;
    var token_end = token_start;
    switch (quote) {
        .single => {
            while (token_end < command.len and command[token_end] != '\'') token_end += 1;
            if (token_end == command.len) return null;
            cursor = token_end + 1;
        },
        .double => {
            while (token_end < command.len and command[token_end] != '"') : (token_end += 1) {
                if (command[token_end] == '\\') return null;
            }
            if (token_end == command.len) return null;
            cursor = token_end + 1;
        },
        .none => {
            while (token_end < command.len and !isUnquotedEnd(command[token_end])) token_end += 1;
            if (token_end == token_start) return null;
            cursor = token_end;
        },
    }
    if (quote != .none and cursor < command.len and command[cursor] != ' ' and
        command[cursor] != '\t' and command[cursor] != '&' and command[cursor] != ';') return null;

    cursor = skipHorizontal(command, cursor);
    if (cursor + 1 >= command.len or command[cursor] != '&' or command[cursor + 1] != '&') return null;
    cursor = skipHorizontal(command, cursor + 2);
    if (cursor == command.len) return null;

    const token = command[token_start..token_end];
    if (!targetEqualsCwd(token, quote, cwd, home)) return null;
    return command[cursor..];
}

pub fn stripPrefixOffset(command: []const u8, cwd: []const u8, home: ?[]const u8) usize {
    const suffix = stripPrefix(command, cwd, home) orelse return 0;
    return command.len - suffix.len;
}

fn skipHorizontal(bytes: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < bytes.len and (bytes[cursor] == ' ' or bytes[cursor] == '\t')) cursor += 1;
    return cursor;
}

fn isUnquotedEnd(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == ';' or byte == '&' or byte == '|' or
        byte == '<' or byte == '>' or byte == '(' or byte == ')' or byte == '`' or
        byte == '\\' or byte == '"' or byte == '\'';
}

fn isPathSafe(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or
        byte == '/' or byte == '.' or byte == '_' or byte == '-' or byte == '+';
}

fn unquotedExpansionSafe(value: []const u8) bool {
    for (value) |byte| switch (byte) {
        ' ', '\t', '\n', '*', '?', '[' => return false,
        else => {},
    };
    return true;
}

fn literalSafe(value: []const u8, quote: QuoteMode) bool {
    for (value) |byte| {
        if (quote == .double) {
            if (byte == '$' or byte == '`') return false;
        } else if (!isPathSafe(byte)) return false;
    }
    return true;
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn joinedEqualsCwd(prefix: []const u8, suffix: []const u8, cwd: []const u8) bool {
    const expected = trimTrailingSlashes(cwd);
    var total = prefix.len + suffix.len;
    while (total > 1) {
        const last = if (total > prefix.len) suffix[total - prefix.len - 1] else prefix[total - 1];
        if (last != '/') break;
        total -= 1;
    }
    if (total != expected.len) return false;
    const prefix_part = @min(prefix.len, total);
    if (!std.mem.eql(u8, prefix[0..prefix_part], expected[0..prefix_part])) return false;
    return total == prefix_part or std.mem.eql(
        u8,
        suffix[0 .. total - prefix_part],
        expected[prefix_part..],
    );
}

fn targetEqualsCwd(token: []const u8, quote: QuoteMode, cwd: []const u8, home: ?[]const u8) bool {
    if (std.mem.eql(u8, token, ".")) return true;
    if (quote == .single) return joinedEqualsCwd(token, "", cwd);

    if (quote == .none and token.len >= 1 and token[0] == '~') {
        const home_path = home orelse return false;
        if (home_path.len == 0 or !unquotedExpansionSafe(home_path)) return false;
        if (token.len == 1) return joinedEqualsCwd(home_path, "", cwd);
        if (token[1] != '/' or !literalSafe(token[2..], .none)) return false;
        return joinedEqualsCwd(home_path, token[1..], cwd);
    }

    var prefix_len: usize = 0;
    if (token.len >= 5 and std.mem.eql(u8, token[0..5], "$HOME") and
        (token.len == 5 or token[5] == '/'))
    {
        prefix_len = 5;
    } else if (token.len >= 7 and std.mem.eql(u8, token[0..7], "${HOME}")) {
        prefix_len = 7;
    }
    if (prefix_len != 0) {
        const home_path = home orelse return false;
        if (home_path.len == 0 or (quote == .none and !unquotedExpansionSafe(home_path)) or
            !literalSafe(token[prefix_len..], quote)) return false;
        return joinedEqualsCwd(home_path, token[prefix_len..], cwd);
    }

    return token.len != 0 and token[0] == '/' and literalSafe(token, quote) and
        joinedEqualsCwd(token, "", cwd);
}

test "strip no-op cd prefix exact hax cases" {
    const cwd = "/Users/me/proj";
    const home = "/Users/me";
    const strips = [_]struct { command: []const u8, working: []const u8, home_path: ?[]const u8, suffix: []const u8 }{
        .{ .command = "cd /Users/me/proj && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd /Users/me/proj/ && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd ~/proj && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd ~ && pwd", .working = home, .home_path = home, .suffix = "pwd" },
        .{ .command = "cd $HOME/proj && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd ${HOME}/proj && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd . && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd \".\" && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd '.' && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd \"/Users/me/proj\" && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd \"$HOME/proj\" && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd '/Users/me/proj' && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "   cd /Users/me/proj && rg foo", .working = cwd, .home_path = home, .suffix = "rg foo" },
        .{ .command = "cd /&&ls", .working = "/", .home_path = home, .suffix = "ls" },
        .{
            .command = "cd \"/tmp/my proj\" && rg foo",
            .working = "/tmp/my proj",
            .home_path = home,
            .suffix = "rg foo",
        },
        .{
            .command = "cd \"$HOME/my proj\" && rg foo",
            .working = "/Users/me/my proj",
            .home_path = home,
            .suffix = "rg foo",
        },
    };
    for (strips) |case| try std.testing.expectEqualStrings(
        case.suffix,
        stripPrefix(case.command, case.working, case.home_path).?,
    );
}

test "unsafe or semantic cd prefixes remain unchanged" {
    const cwd = "/Users/me/proj";
    const home = "/Users/me";
    const commands = [_][]const u8{
        "cd ~ && pwd",
        "cd $PWD && rg foo",
        "cd ${PWD} && rg foo",
        "cd '~/proj' && rg foo",
        "cd \"~/proj\" && rg foo",
        "cd /elsewhere && rg foo",
        "cd proj && rg foo",
        "cd /Users/me/proj; rg foo",
        "cd /Users/me/proj || rg foo",
        "cd $(pwd) && rg foo",
        "cd `pwd` && rg foo",
        "cd /Users/me/pro* && rg foo",
        "cd /Users/me/\\proj && rg foo",
        "cd ~other/proj && rg foo",
        "cd $HOMEx/proj && rg foo",
        "cd && rg foo",
        "cd /Users/me/proj &&",
        "cd \"/Users/me/proj\"x && rg foo",
        "cd \"/Users/me/\\proj\" && rg foo",
        "cd \"/tmp/$x\" && ls",
        "cd \"/tmp/`cmd`\" && ls",
    };
    for (commands) |command| try std.testing.expect(stripPrefix(command, cwd, home) == null);
    try std.testing.expect(stripPrefix("cd ~/proj && rg foo", cwd, null) == null);
    try std.testing.expect(stripPrefix("cd $HOME && pwd", "/tmp/a b", "/tmp/a b") == null);
    try std.testing.expect(stripPrefix("cd $HOME && ls", "/tmp/q?", "/tmp/q?") == null);
}
