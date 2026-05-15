const std = @import("std");
const agent = @import("../../agent/root.zig");

pub const RepairStats = struct {
    orphan_tool_results: usize = 0,
    duplicate_tool_results: usize = 0,
    missing_tool_results: usize = 0,
};

pub const Projection = struct {
    messages: []const agent.protocol.AgentMessage,
    repairs: RepairStats,
};

pub fn providerSafeProjection(allocator: std.mem.Allocator, messages: []const agent.protocol.AgentMessage) !Projection {
    var tool_calls: std.StringHashMapUnmanaged(void) = .empty;
    defer tool_calls.deinit(allocator);
    var emitted_results: std.StringHashMapUnmanaged(void) = .empty;
    defer emitted_results.deinit(allocator);
    var counted_results: std.StringHashMapUnmanaged(void) = .empty;
    defer counted_results.deinit(allocator);
    var out: std.ArrayList(agent.protocol.AgentMessage) = .empty;
    errdefer out.deinit(allocator);
    var repairs: RepairStats = .{};

    for (messages) |msg| switch (msg) {
        .assistant => |a| for (a.content) |block| switch (block) {
            .tool_call => |tc| try tool_calls.put(allocator, tc.id, {}),
            else => {},
        },
        else => {},
    };

    for (messages) |msg| switch (msg) {
        .tool_result => |tr| {
            if (!tool_calls.contains(tr.tool_call_id)) {
                repairs.orphan_tool_results += 1;
                continue;
            }
            if (counted_results.contains(tr.tool_call_id)) {
                repairs.duplicate_tool_results += 1;
                continue;
            }
            try counted_results.put(allocator, tr.tool_call_id, {});
        },
        else => {},
    };

    for (messages) |msg| switch (msg) {
        .assistant => |a| {
            try out.append(allocator, msg);
            for (a.content) |block| switch (block) {
                .tool_call => |tc| {
                    if (emitted_results.contains(tc.id)) continue;
                    if (findFirstToolResult(messages, tc.id)) |tr_msg| {
                        try out.append(allocator, tr_msg);
                        try emitted_results.put(allocator, tc.id, {});
                    } else {
                        try appendSyntheticResult(allocator, &out, tc.id, tc.name);
                        try emitted_results.put(allocator, tc.id, {});
                        repairs.missing_tool_results += 1;
                    }
                },
                else => {},
            };
        },
        .tool_result => {},
        else => try out.append(allocator, msg),
    };
    return .{ .messages = try out.toOwnedSlice(allocator), .repairs = repairs };
}

fn findFirstToolResult(messages: []const agent.protocol.AgentMessage, id: []const u8) ?agent.protocol.AgentMessage {
    for (messages) |msg| switch (msg) {
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_call_id, id)) return msg,
        else => {},
    };
    return null;
}

fn appendSyntheticResult(allocator: std.mem.Allocator, out: *std.ArrayList(agent.protocol.AgentMessage), id: []const u8, name: []const u8) !void {
    const content = try allocator.alloc(agent.protocol.ToolResultMessage.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "tool result missing; synthesized by transcript invariant checker") } };
    try out.append(allocator, .{ .tool_result = .{
        .tool_call_id = try allocator.dupe(u8, id),
        .tool_name = try allocator.dupe(u8, name),
        .content = content,
        .is_error = true,
        .timestamp = 0,
    } });
}

test "provider projection drops orphan and duplicate tool results" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const blocks = try alloc.alloc(agent.protocol.AssistantMessage.AssistantContentBlock, 1);
    blocks[0] = .{ .tool_call = .{ .id = "tc1", .name = "read", .arguments = .{ .object = .{} } } };
    const empty = try alloc.alloc(agent.protocol.ToolResultMessage.ContentBlock, 0);
    const msgs = [_]agent.protocol.AgentMessage{
        .{ .tool_result = .{ .tool_call_id = "orphan", .tool_name = "read", .content = empty, .is_error = true, .timestamp = 1 } },
        .{ .assistant = .{ .content = blocks, .api = .anthropic_messages, .provider = .anthropic, .model = "m", .usage = .{}, .stop_reason = .tool_call, .timestamp = 2 } },
        .{ .user = .{ .content = .{ .text = "intervening" }, .timestamp = 3 } },
        .{ .tool_result = .{ .tool_call_id = "tc1", .tool_name = "read", .content = empty, .is_error = false, .timestamp = 4 } },
        .{ .tool_result = .{ .tool_call_id = "tc1", .tool_name = "read", .content = empty, .is_error = false, .timestamp = 5 } },
    };
    const p = try providerSafeProjection(testing.allocator, &msgs);
    defer testing.allocator.free(p.messages);
    try testing.expectEqual(@as(usize, 3), p.messages.len);
    try testing.expect(p.messages[1] == .tool_result);
    try testing.expectEqual(@as(usize, 1), p.repairs.orphan_tool_results);
    try testing.expectEqual(@as(usize, 1), p.repairs.duplicate_tool_results);
    try testing.expectEqual(@as(usize, 0), p.repairs.missing_tool_results);
}
