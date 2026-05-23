const command = @import("command.zig");
const agent_mod = @import("../agent/root.zig");
const session_event = @import("../session/event.zig");
const durable = @import("durable.zig");

pub const Event = union(enum) {
    command: CommandEvent,
    agent: agent_mod.AgentEvent,
    control: ControlEvent,
    session: SessionEvent,
};

pub const CommandEvent = union(enum) {
    accepted: command.CommandId,
    rejected: command.Rejection,
};

pub const ControlEvent = union(enum) {
    follow_up_queued: FollowUpQueued,
    abort_requested: AbortRequested,
};

pub const FollowUpQueued = struct {
    command_id: command.CommandId,
    queued_followups: usize,
};

pub const AbortRequested = struct {
    command_id: command.CommandId,
};

pub const SessionEvent = union(enum) {
    appended: session_event.EventId,
    append_rejected: durable.Rejection,
    append_failed: durable.Failure,
};

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    emit_fn: *const fn (event: Event, ctx: ?*anyopaque) void,

    pub fn emit(self: Sink, value: Event) void {
        self.emit_fn(value, self.ctx);
    }
};
