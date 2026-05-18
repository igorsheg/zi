const command = @import("command.zig");
const session_event = @import("../session/event.zig");
const state = @import("state.zig");
const durable = @import("durable.zig");

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
    started: command.CommandId,
    finished: struct { command_id: command.CommandId, terminal: RunTerminal },
};

pub const RunTerminal = union(enum) {
    completed,
    failed: state.FailureKind,
    aborted,
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
