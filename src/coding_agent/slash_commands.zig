//! Small slash-command catalog and parser. This is deliberately metadata +
//! typed ids, not a callback registry: SessionRuntime remains the owner that
//! applies command effects.
const std = @import("std");

pub const command_count_max: usize = 32;
pub const name_bytes_max: usize = 32;
pub const summary_bytes_max: usize = 96;

pub const Id = enum {
    help,
    session,
    model,
    resume_session,
    new_session,
    compact,
    settings,
};

pub const PickerKind = enum {
    none,
    model,
    session,
};

pub const Command = struct {
    id: Id,
    name: []const u8,
    summary: []const u8,
    picker: PickerKind = .none,
};

pub const Invocation = struct {
    name: []const u8,
    args: []const u8,
};

pub const builtins = [_]Command{
    .{ .id = .help, .name = "help", .summary = "Show commands" },
    .{ .id = .session, .name = "session", .summary = "Show session info and stats" },
    .{
        .id = .model,
        .name = "model",
        .summary = "Select model",
        .picker = .model,
    },
    .{
        .id = .resume_session,
        .name = "resume",
        .summary = "Resume session",
        .picker = .session,
    },
    .{ .id = .new_session, .name = "new", .summary = "Start a new session" },
    .{ .id = .compact, .name = "compact", .summary = "Compact session context" },
    .{ .id = .settings, .name = "settings", .summary = "Open settings" },
};

comptime {
    if (builtins.len > command_count_max) @compileError("too many builtin slash commands");
    for (builtins) |command| {
        if (command.name.len == 0 or command.name.len > name_bytes_max) @compileError("invalid slash command name");
        if (command.summary.len == 0 or command.summary.len > summary_bytes_max) {
            @compileError("invalid slash command summary");
        }
    }
}

pub fn lookup(name: []const u8) ?Command {
    for (builtins) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

pub fn parseInvocation(text: []const u8) ?Invocation {
    if (text.len < 2 or text[0] != '/') return null;
    var end: usize = 1;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
    if (end == 1) return null;
    var args_start = end;
    while (args_start < text.len and std.ascii.isWhitespace(text[args_start])) args_start += 1;
    return .{ .name = text[1..end], .args = std.mem.trim(u8, text[args_start..], " \t\r\n") };
}

pub fn parseName(text: []const u8) ?[]const u8 {
    const invocation = parseInvocation(text) orelse return null;
    return invocation.name;
}

pub fn formatAvailable(buffer: []u8) []const u8 {
    var written: usize = 0;
    written = appendLiteral(buffer, written, "available commands: ") orelse return "available commands";
    for (builtins, 0..) |command, index| {
        if (index > 0) written = appendLiteral(buffer, written, ", ") orelse return "available commands";
        written = appendLiteral(buffer, written, "/") orelse return "available commands";
        written = appendLiteral(buffer, written, command.name) orelse return "available commands";
    }
    return buffer[0..written];
}

fn appendLiteral(buffer: []u8, written: usize, text: []const u8) ?usize {
    if (written + text.len > buffer.len) return null;
    @memcpy(buffer[written..][0..text.len], text);
    return written + text.len;
}

test "slash command parser extracts name and trimmed args" {
    const parsed = parseInvocation("/model  openai/gpt-5.1 \n").?;
    try std.testing.expectEqualStrings("model", parsed.name);
    try std.testing.expectEqualStrings("openai/gpt-5.1", parsed.args);
    try std.testing.expect(parseInvocation("/") == null);
    try std.testing.expect(parseInvocation("/ help") == null);
    try std.testing.expect(parseInvocation("hello") == null);
}

test "slash command catalog formats help from builtin source" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "available commands: /help, /session, /model, /resume, /new, /compact, /settings",
        formatAvailable(&buffer),
    );
    try std.testing.expectEqual(Id.model, lookup("model").?.id);
    try std.testing.expect(lookup("missing") == null);
}
