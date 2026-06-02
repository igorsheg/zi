const std = @import("std");

pub const CommandName = enum {
    help,
    session,
};

const commands: []const CommandName = &.{ .help, .session };

pub const Parsed = struct {
    text: []const u8,
    name: ?CommandName,
};

pub fn parse(text: []const u8) ?Parsed {
    if (text.len < 2 or text[0] != '/') return null;
    var end: usize = 1;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
    if (end == 1) return null;
    const command = text[1..end];
    for (commands) |name| {
        if (std.mem.eql(u8, command, @tagName(name))) return .{ .text = command, .name = name };
    }
    return .{ .text = command, .name = null };
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

test "prompt command parser returns text and known name" {
    try std.testing.expectEqual(@as(?Parsed, null), parse(""));
    try std.testing.expectEqual(@as(?Parsed, null), parse("/"));
    try std.testing.expectEqual(@as(?Parsed, null), parse("hello"));
    const help = parse("/help now") orelse return error.ExpectedCommand;
    try std.testing.expectEqualStrings("help", help.text);
    try std.testing.expectEqual(CommandName.help, help.name.?);
    const unknown = parse("/nope") orelse return error.ExpectedCommand;
    try std.testing.expectEqualStrings("nope", unknown.text);
    try std.testing.expectEqual(@as(?CommandName, null), unknown.name);
}
