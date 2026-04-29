const std = @import("std");

const agent_mod = @import("../../agent3/root.zig");
const agent_protocol = @import("../../agent3/types.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");

const AgentEvent = agent_mod.protocol.AgentEvent;
const AgentSession = coding_agent_mod.AgentSession;

pub const PublishedStatusSnapshot = struct {
    model_provider: []u8,
    model_id: []u8,
    thinking_level: agent_protocol.ThinkingLevel,
    context_tokens: ?u64,
    context_window: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        snapshot: AgentSession.StatusSnapshot,
    ) !PublishedStatusSnapshot {
        const model_provider = try allocator.dupe(u8, snapshot.model_provider);
        errdefer allocator.free(model_provider);
        const model_id = try allocator.dupe(u8, snapshot.model_id);
        return .{
            .model_provider = model_provider,
            .model_id = model_id,
            .thinking_level = snapshot.thinking_level,
            .context_tokens = snapshot.context_tokens,
            .context_window = snapshot.context_window,
        };
    }

    pub fn deinit(self: *PublishedStatusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.model_provider);
        allocator.free(self.model_id);
        self.* = undefined;
    }

    pub fn eql(self: PublishedStatusSnapshot, snapshot: AgentSession.StatusSnapshot) bool {
        return std.mem.eql(u8, self.model_provider, snapshot.model_provider) and
            std.mem.eql(u8, self.model_id, snapshot.model_id) and
            self.thinking_level == snapshot.thinking_level and
            self.context_tokens == snapshot.context_tokens and
            self.context_window == snapshot.context_window;
    }
};

pub fn shouldPublishStatusSnapshotForAgentEvent(event: AgentEvent) bool {
    return switch (event) {
        .message_end => true,
        .turn_end => |payload| switch (payload.message) {
            .assistant => true,
            else => false,
        },
        else => false,
    };
}

const testing = std.testing;

test "status snapshot publication follows message-end source mutations" {
    const user = agent_protocol.AgentMessage{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } };
    const assistant = agent_protocol.AgentMessage{ .assistant = .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 2,
    } };
    const tool_result = agent_protocol.AgentMessage{ .tool_result = .{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{},
        .is_error = false,
        .timestamp = 3,
    } };

    try testing.expect(shouldPublishStatusSnapshotForAgentEvent(.{ .message_end = .{ .message = user } }));
    try testing.expect(shouldPublishStatusSnapshotForAgentEvent(.{ .message_end = .{ .message = assistant } }));
    try testing.expect(shouldPublishStatusSnapshotForAgentEvent(.{ .message_end = .{ .message = tool_result } }));
    try testing.expect(shouldPublishStatusSnapshotForAgentEvent(.{ .turn_end = .{ .message = assistant, .tool_results = &.{} } }));
}
