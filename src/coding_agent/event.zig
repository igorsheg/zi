const command = @import("command.zig");
const agent_event = @import("../agent/event.zig");
const session_event = @import("../session/event.zig");

pub const Event = union(enum) {
    command: CommandEvent,
    run: RunEvent,
    session: SessionEvent,
};

pub const CommandEvent = union(enum) {
    accepted: command.CommandId,
    rejected: command.Rejection,
};

pub const RunEvent = union(enum) {
    agent: agent_event.AgentEvent,
};

pub const SessionEvent = union(enum) {
    appended: session_event.EventId,
};

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    emit_fn: *const fn (event: Event, ctx: ?*anyopaque) void,

    pub fn emit(self: Sink, value: Event) void {
        self.emit_fn(value, self.ctx);
    }
};
