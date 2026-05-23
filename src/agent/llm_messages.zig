const std = @import("std");
const ai = @import("../ai/root.zig");
const config = @import("config.zig");
const message = @import("message.zig");

pub fn defaultConvertToLlm(_: ?*anyopaque, allocator: std.mem.Allocator, messages: []const message.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message { // ziglint-ignore: Z024, Z023
    var out: std.ArrayList(ai.protocol.Message) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, messages.len);

    for (messages) |value| switch (value) {
        .user => |user| out.appendAssumeCapacity(.{ .user = user }),
        .assistant => |assistant| out.appendAssumeCapacity(.{ .assistant = assistant }),
        .tool_result => |tool| out.appendAssumeCapacity(.{ .tool_result = tool }),
        .compaction_summary, .branch_summary, .custom => {},
    };

    return try out.toOwnedSlice(allocator); // ziglint-ignore: Z017
}

pub const default_hook = config.ConvertMessagesHook{ .call_fn = defaultConvertToLlm }; // ziglint-ignore: Z004

test "default convert to llm filters agent-only messages" {
    const converted = try defaultConvertToLlm(null, std.testing.allocator, &.{
        .{ .custom = .{ .custom_type = "notice", .content = .{ .text = "skip" }, .timestamp = 1 } },
        .{ .user = .{ .content = .{ .text = "keep" }, .timestamp = 2 } },
        .{ .compaction_summary = .{ .summary = "skip", .tokens_before = 1, .timestamp = 3 } },
    });
    defer std.testing.allocator.free(converted);

    try std.testing.expectEqual(@as(usize, 1), converted.len);
    try std.testing.expect(converted[0] == .user);
    try std.testing.expectEqualStrings("keep", converted[0].user.content.text);
}
