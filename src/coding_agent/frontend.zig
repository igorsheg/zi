const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");

pub const FrontendAction = union(enum) {
    submit_prompt: SubmitPrompt,
    cancel_run,
    continue_run,
    request_shutdown,
    invoke_command: []const u8,
    set_active_tools: []const []const u8,

    pub const SubmitPrompt = struct {
        text: []const u8,
    };
};

pub const ReadModel = struct {
    status: Status = .idle,
    messages_seen: usize = 0,
    assistant_updates_seen: usize = 0,
    tool_executions_started: usize = 0,
    tool_executions_finished: usize = 0,
    queue_revision: u64 = 0,
    steering_count: usize = 0,
    follow_up_count: usize = 0,
    session_name_set: bool = false,

    pub const Status = enum {
        idle,
        running,
        cancel_requested,
        failed,
        shutdown_requested,
        stopped,
    };

    pub fn initFromSnapshot(snapshot: AgentSession.RuntimeStatusSnapshot) ReadModel {
        return .{
            .status = statusFromSession(snapshot.status),
        };
    }

    pub fn apply(self: *ReadModel, event: AgentSession.AgentSessionEvent) void {
        switch (event) {
            .agent_event => |agent_event| self.applyAgentEvent(agent_event),
            .queue_update => |payload| {
                self.queue_revision = payload.revision;
                self.steering_count = payload.steering.items.len;
                self.follow_up_count = payload.follow_up.items.len;
            },
            .prompt_command => {},
            .session_info_changed => |payload| {
                self.session_name_set = payload.name != null;
            },
            .compaction_start => {},
            .compaction_end => {},
            .auto_retry_start => {},
            .auto_retry_end => {},
        }
    }

    pub fn markCancelled(self: *ReadModel) void {
        self.status = .cancel_requested;
    }

    pub fn markRunning(self: *ReadModel) void {
        self.status = .running;
    }

    pub fn markFailed(self: *ReadModel) void {
        self.status = .failed;
    }

    pub fn markShutdownRequested(self: *ReadModel) void {
        self.status = .shutdown_requested;
    }

    fn applyAgentEvent(self: *ReadModel, event: agent_mod.AgentEvent) void {
        switch (event) {
            .agent_start => self.status = .running,
            .agent_end => self.status = .idle,
            .message_start => {},
            .message_update => self.assistant_updates_seen += 1,
            .message_end => self.messages_seen += 1,
            .turn_start => {},
            .turn_end => {},
            .tool_execution_start => self.tool_executions_started += 1,
            .tool_execution_update => {},
            .tool_execution_end => self.tool_executions_finished += 1,
        }
    }

    fn statusFromSession(status: AgentSession.AgentSessionStatus) Status {
        return switch (status) {
            .idle => .idle,
            .running => .running,
            .cancel_requested => .cancel_requested,
            .shutdown_requested => .shutdown_requested,
            .stopped => .stopped,
        };
    }
};

test "frontend read model applies public event stream without touching session internals" {
    var model = ReadModel.initFromSnapshot(.{
        .status = .idle,
        .public_event_count = 0,
        .dropped_public_event_count = 0,
    });

    model.apply(.{ .agent_event = .agent_start });
    try std.testing.expectEqual(ReadModel.Status.running, model.status);

    model.apply(.{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = emptyAssistantMessage() },
        .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = "hi",
            .partial = emptyAssistantMessage(),
        } },
    } } });
    try std.testing.expectEqual(@as(usize, 1), model.assistant_updates_seen);

    var steering = try AgentSession.EventTextList.init(std.testing.allocator, &.{"steer"});
    defer steering.deinit();
    var follow_up = try AgentSession.EventTextList.init(std.testing.allocator, &.{ "one", "two" });
    defer follow_up.deinit();
    model.apply(.{ .queue_update = .{
        .steering = steering,
        .follow_up = follow_up,
        .revision = 7,
    } });
    try std.testing.expectEqual(@as(u64, 7), model.queue_revision);
    try std.testing.expectEqual(@as(usize, 1), model.steering_count);
    try std.testing.expectEqual(@as(usize, 2), model.follow_up_count);

    model.apply(.{ .agent_event = .{ .agent_end = .{ .messages = &.{} } } });
    try std.testing.expectEqual(ReadModel.Status.idle, model.status);
    model.markFailed();
    try std.testing.expectEqual(ReadModel.Status.failed, model.status);
}

fn emptyAssistantMessage() ai.AssistantMessage {
    return .{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}
