const std = @import("std");
const agent = @import("../agent/root.zig");

pub const Availability = enum {
    ready,
    poisoned,
};

pub const AgentSettled = struct {
    run_id: agent.event.RunId,
    availability: Availability,
};

/// Coding-agent events extend the core agent lifecycle without replacing its
/// payloads. The repeated tags keep consumption flat while the shared payload
/// declarations prevent a second event vocabulary.
pub const Event = union(enum) {
    agent_start: agent.event.AgentStart,
    agent_end: agent.event.AgentEnd,
    turn_start: agent.event.TurnStart,
    turn_end: agent.event.TurnEnd,
    message_start: agent.event.MessageStart,
    message_update: agent.event.MessageUpdate,
    message_end: agent.event.MessageFinished,
    tool_execution_start: agent.event.ToolExecutionStart,
    tool_execution_end: agent.event.ToolExecutionEnd,
    agent_settled: AgentSettled,
};

pub const SinkError = agent.event.SinkError;

/// Event payload slices are borrowed for the duration of `emitFn`.
pub const Sink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: Event) SinkError!void,

    pub fn emit(self: Sink, event: Event) SinkError!void {
        return self.emitFn(self.context, event);
    }
};

pub fn fromAgent(value: agent.event.Event) Event {
    return switch (value) {
        .agent_start => |payload| .{ .agent_start = payload },
        .agent_end => |payload| .{ .agent_end = payload },
        .turn_start => |payload| .{ .turn_start = payload },
        .turn_end => |payload| .{ .turn_end = payload },
        .message_start => |payload| .{ .message_start = payload },
        .message_update => |payload| .{ .message_update = payload },
        .message_end => |payload| .{ .message_end = payload },
        .tool_execution_start => |payload| .{ .tool_execution_start = payload },
        .tool_execution_end => |payload| .{ .tool_execution_end = payload },
    };
}

test "session events preserve every core event tag" {
    const core: agent.event.Event = .{ .agent_start = .{ .run_id = @enumFromInt(7) } };
    const value = fromAgent(core);
    try std.testing.expect(value == .agent_start);
    try std.testing.expectEqual(@as(u64, 7), @intFromEnum(value.agent_start.run_id));
}
