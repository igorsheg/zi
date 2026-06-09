const std = @import("std");

const runtime = @import("../runtime/root.zig");
const session_events = @import("session_events.zig");

pub const RequestId = u64;

pub const command_queue_capacity_default = 64;
pub const event_queue_capacity_default = 256;

pub const CommandQueue = runtime.BoundedQueue(CommandEnvelope);
pub const EventQueue = runtime.BoundedQueue(EventEnvelope);

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
    accepted: RequestId,
    rejected: Rejection,
    response: Response,
    session_event: session_events.AgentSessionEvent,
    shutdown_complete,

    pub fn deinit(self: *ClientEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .rejected => |rejection| allocator.free(rejection.message),
            .session_event => |*event| event.deinit(),
            .accepted, .response, .shutdown_complete => {},
        }
        self.* = undefined;
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

test "event envelope deinitializes owned session event" {
    var event: EventEnvelope = .{ .event = .{ .session_event = .{ .prompt_command = .{
        .command = try session_events.EventText.init(std.testing.allocator, "help"),
        .result = .handled,
        .message = try session_events.EventText.init(std.testing.allocator, "ok"),
    } } } };
    event.deinit(std.testing.allocator);
}
