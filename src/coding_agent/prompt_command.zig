const std = @import("std");

pub const CommandName = enum {
    help,
    session,
};

const commands: []const CommandName = &.{ .help, .session };

pub fn parse(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[0] != '/') return null;
    var end: usize = 1;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
    if (end == 1) return null;
    return text[1..end];
}

pub fn parseName(command: []const u8) ?CommandName {
    for (commands) |name| {
        if (std.mem.eql(u8, command, @tagName(name))) return name;
    }
    return null;
}

pub fn helpText() []const u8 {
    return "available commands: /help, /session";
}

pub fn unknownText(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "unknown command: /{s}", .{command});
}

pub const SessionInfo = struct {
    status_name: []const u8,
    public_event_count: usize,
    dropped_public_event_count: usize,
    active_tool_count: usize,
};

pub fn sessionText(allocator: std.mem.Allocator, info: SessionInfo) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "session: {s}; public events: {}; dropped events: {}; active tools: {}",
        .{
            info.status_name,
            info.public_event_count,
            info.dropped_public_event_count,
            info.active_tool_count,
        },
    );
}

test "prompt command parser requires slash command name" {
    try std.testing.expectEqual(@as(?[]const u8, null), parse(""));
    try std.testing.expectEqual(@as(?[]const u8, null), parse("/"));
    try std.testing.expectEqual(@as(?[]const u8, null), parse("hello"));
    try std.testing.expectEqualStrings("help", parse("/help") orelse return error.ExpectedCommand);
    try std.testing.expectEqualStrings("help", parse("/help now") orelse return error.ExpectedCommand);
}

test "prompt command names are known commands only" {
    try std.testing.expectEqual(CommandName.help, parseName("help").?);
    try std.testing.expectEqual(CommandName.session, parseName("session").?);
    try std.testing.expectEqual(@as(?CommandName, null), parseName("nope"));
}
