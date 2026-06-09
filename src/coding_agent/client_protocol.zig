const std = @import("std");

const runtime = @import("../runtime/root.zig");
const session_events = @import("session_events.zig");

pub const RequestId = u64;

pub const command_queue_capacity_default = 64;
pub const event_queue_capacity_default = 256;

pub const CommandQueue = runtime.BoundedQueue(CommandEnvelope);
pub const EventQueue = runtime.BoundedQueue(EventEnvelope);

pub const EventText = session_events.EventText;
pub const EventTextList = session_events.EventTextList;
pub const OwnedAgentEvent = session_events.OwnedAgentEvent;

pub const CommandEnvelope = struct {
    id: ?RequestId = null,
    command: ClientCommand,

    pub fn initSubmitPrompt(allocator: std.mem.Allocator, id: ?RequestId, text: []const u8) !CommandEnvelope {
        return .{ .id = id, .command = .{ .submit_prompt = .{ .text = try allocator.dupe(u8, text) } } };
    }

    pub fn deinit(self: *CommandEnvelope, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        self.* = undefined;
    }
};

pub const ClientCommand = union(enum) {
    submit_prompt: SubmitPrompt,
    cancel,
    clear_queue,
    request_snapshot,
    shutdown,

    pub fn deinit(self: *ClientCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .submit_prompt => |prompt| allocator.free(prompt.text),
            .cancel, .clear_queue, .request_snapshot, .shutdown => {},
        }
        self.* = undefined;
    }
};

pub const SubmitPrompt = struct {
    text: []u8,
};

pub const EventEnvelope = struct {
    request_id: ?RequestId = null,
    event: ClientEvent,

    pub fn deinit(self: *EventEnvelope, allocator: std.mem.Allocator) void {
        self.event.deinit(allocator);
        self.* = undefined;
    }
};

pub const ClientEvent = union(enum) {
    rejected: Rejection,
    response: Response,
    agent_event: OwnedAgentEvent,
    queue_update: session_events.AgentSessionEvent.QueueUpdate,
    prompt_command: session_events.AgentSessionEvent.PromptCommand,
    compaction_start: session_events.AgentSessionEvent.CompactionStart,
    session_info_changed: session_events.AgentSessionEvent.SessionInfoChanged,
    compaction_end: session_events.AgentSessionEvent.CompactionEnd,
    auto_retry_start: session_events.AgentSessionEvent.AutoRetryStart,
    auto_retry_end: session_events.AgentSessionEvent.AutoRetryEnd,
    event_overflow: session_events.AgentSessionEvent.PublicEventOverflow,

    pub fn fromSessionEvent(event: session_events.AgentSessionEvent) ClientEvent {
        return switch (event) {
            .agent_event => |payload| .{ .agent_event = payload },
            .queue_update => |payload| .{ .queue_update = payload },
            .prompt_command => |payload| .{ .prompt_command = payload },
            .compaction_start => |payload| .{ .compaction_start = payload },
            .session_info_changed => |payload| .{ .session_info_changed = payload },
            .compaction_end => |payload| .{ .compaction_end = payload },
            .auto_retry_start => |payload| .{ .auto_retry_start = payload },
            .auto_retry_end => |payload| .{ .auto_retry_end = payload },
            .public_event_overflow => |payload| .{ .event_overflow = payload },
        };
    }

    pub fn deinit(self: *ClientEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .rejected => |rejection| allocator.free(rejection.message),
            .agent_event => |*payload| payload.deinit(),
            .queue_update => |*payload| payload.deinit(),
            .prompt_command => |*payload| payload.deinit(),
            .session_info_changed => |*payload| if (payload.name) |*name| name.deinit(),
            .compaction_end => |*payload| payload.deinit(),
            .auto_retry_start => |*payload| payload.error_message.deinit(),
            .auto_retry_end => |*payload| if (payload.final_error) |*err| err.deinit(),
            .response, .compaction_start, .event_overflow => {},
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: ClientEvent, stringify: *std.json.Stringify) !void {
        switch (self) {
            .agent_event => |payload| try stringify.write(session_events.AgentSessionEvent{ .agent_event = payload }),
            .queue_update => |payload| try stringify.write(session_events.AgentSessionEvent{ .queue_update = payload }),
            .prompt_command => |payload| try stringify.write(session_events.AgentSessionEvent{ .prompt_command = payload }),
            .compaction_start => |payload| try stringify.write(session_events.AgentSessionEvent{ .compaction_start = payload }),
            .session_info_changed => |payload| try stringify.write(session_events.AgentSessionEvent{ .session_info_changed = payload }),
            .compaction_end => |payload| try stringify.write(session_events.AgentSessionEvent{ .compaction_end = payload }),
            .auto_retry_start => |payload| try stringify.write(session_events.AgentSessionEvent{ .auto_retry_start = payload }),
            .auto_retry_end => |payload| try stringify.write(session_events.AgentSessionEvent{ .auto_retry_end = payload }),
            .event_overflow => |payload| try stringify.write(session_events.AgentSessionEvent{ .public_event_overflow = payload }),
            .rejected => |payload| try stringify.write(.{ .type = "rejected", .message = payload.message }),
            .response => |payload| try stringify.write(.{ .type = "response", .response = payload }),
        }
    }
};

pub const Rejection = struct {
    code: Code,
    message: []u8,

    pub const Code = enum {
        busy,
        queue_full,
        shutting_down,
        invalid_command,
        overflow,
    };
};

pub const Response = union(enum) {
    prompt_finished,
    canceled,
    queue_cleared,
    snapshot_sent,
    shutdown_started,
};

test "command envelope owns prompt text" {
    var envelope = try CommandEnvelope.initSubmitPrompt(std.testing.allocator, 7, "hello");
    defer envelope.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?RequestId, 7), envelope.id);
    try std.testing.expectEqualStrings("hello", envelope.command.submit_prompt.text);
}

test "event envelope deinitializes owned client event" {
    var event: EventEnvelope = .{ .event = .{ .prompt_command = .{
        .command = try session_events.EventText.init(std.testing.allocator, "help"),
        .result = .handled,
        .message = try session_events.EventText.init(std.testing.allocator, "ok"),
    } } };
    event.deinit(std.testing.allocator);
}
