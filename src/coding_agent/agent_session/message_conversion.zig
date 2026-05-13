const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent_mod = @import("../../agent/root.zig");

const protocol = agent_mod.protocol;

const COMPACTION_SUMMARY_PREFIX =
    "The conversation history before this point was compacted into the following summary:\n\n<summary>\n";
const COMPACTION_SUMMARY_SUFFIX = "\n</summary>";

const BRANCH_SUMMARY_PREFIX =
    "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n";
const BRANCH_SUMMARY_SUFFIX = "</summary>";

pub fn convertToLlm(
    allocator: std.mem.Allocator,
    messages: []const protocol.AgentMessage,
    _: ?*anyopaque,
) error{OutOfMemory}![]const ai.protocol.Message {
    var result: std.ArrayList(ai.protocol.Message) = .empty;
    for (messages) |msg| {
        switch (msg) {
            .user => |u| try result.append(allocator, .{ .user = u }),
            .assistant => |a| try result.append(allocator, .{ .assistant = a }),
            .tool_result => |t| try result.append(allocator, .{ .tool_result = t }),
            .compaction_summary => |cs| {
                const text = std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ COMPACTION_SUMMARY_PREFIX, cs.summary, COMPACTION_SUMMARY_SUFFIX },
                );
                const blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1);
                blocks[0] = .{ .text = .{ .text = text } };
                try result.append(allocator, .{ .user = .{
                    .content = .{ .blocks = blocks },
                    .timestamp = cs.timestamp,
                } });
            },
            .branch_summary => |bs| {
                const text = std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ BRANCH_SUMMARY_PREFIX, bs.summary, BRANCH_SUMMARY_SUFFIX },
                );
                const blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1);
                blocks[0] = .{ .text = .{ .text = text } };
                try result.append(allocator, .{ .user = .{
                    .content = .{ .blocks = blocks },
                    .timestamp = bs.timestamp,
                } });
            },
            .custom => |c| {
                const user_content: ai.protocol.UserMessage.UserMessageContent = switch (c.content) {
                    .text => |t| blk: {
                        const blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, 1);
                        blocks[0] = .{ .text = .{ .text = t } };
                        break :blk .{ .blocks = blocks };
                    },
                    .blocks => |b| .{ .blocks = b },
                };
                try result.append(allocator, .{ .user = .{
                    .content = user_content,
                    .timestamp = c.timestamp,
                } });
            },
        }
    }
    return result.items;
}

const testing = std.testing;

test "convertToLlm passes through user and assistant messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = alloc.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = "hi" } };

    const messages = &[_]protocol.AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = content,
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "test",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    };

    const result = try convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expect(result[0] == .user);
    try testing.expect(result[1] == .assistant);
}

test "convertToLlm wraps summary entries as user messages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Previous work summarized", .tokens_before = 5000, .timestamp = 1 } },
        .{ .branch_summary = .{ .summary = "Tried approach X", .from_id = "abc", .timestamp = 2 } },
    };

    const result = try convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 2), result.len);
    for (result) |message| try testing.expect(message == .user);

    const compaction_text = result[0].user.content.blocks[0].text.text;
    try testing.expect(std.mem.indexOf(u8, compaction_text, "compacted into the following summary") != null);
    try testing.expect(std.mem.indexOf(u8, compaction_text, "Previous work summarized") != null);
    try testing.expect(std.mem.indexOf(u8, compaction_text, "<summary>") != null);
    try testing.expect(std.mem.indexOf(u8, compaction_text, "</summary>") != null);

    const branch_text = result[1].user.content.blocks[0].text.text;
    try testing.expect(std.mem.indexOf(u8, branch_text, "summary of a branch") != null);
    try testing.expect(std.mem.indexOf(u8, branch_text, "Tried approach X") != null);
}

test "convertToLlm converts custom text to user message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const messages = &[_]protocol.AgentMessage{
        .{ .custom = .{ .custom_type = "skill", .content = .{ .text = "Do X" }, .display = true, .timestamp = 1 } },
    };

    const result = try convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0] == .user);
    try testing.expectEqualStrings("Do X", result[0].user.content.blocks[0].text.text);
}

test "convertToLlm preserves mixed message order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = alloc.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = "response" } };

    const messages = &[_]protocol.AgentMessage{
        .{ .compaction_summary = .{ .summary = "Summary", .tokens_before = 1000, .timestamp = 0 } },
        .{ .user = .{ .content = .{ .text = "question" }, .timestamp = 1 } },
        .{ .assistant = .{
            .content = content,
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "test",
            .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
            .stop_reason = .stop,
            .timestamp = 2,
        } },
        .{ .branch_summary = .{ .summary = "Branch work", .from_id = "x", .timestamp = 3 } },
        .{ .custom = .{ .custom_type = "ext", .content = .{ .text = "Custom content" }, .timestamp = 4 } },
    };

    const result = try convertToLlm(alloc, messages, null);
    try testing.expectEqual(@as(usize, 5), result.len);
    try testing.expect(result[0] == .user);
    try testing.expect(result[1] == .user);
    try testing.expect(result[2] == .assistant);
    try testing.expect(result[3] == .user);
    try testing.expect(result[4] == .user);
}
