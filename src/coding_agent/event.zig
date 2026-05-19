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
    follow_up_queued: FollowUpQueued,
    abort_requested: AbortRequested,
    tool_started: ToolStarted,
    tool_finished: ToolFinished,
    finished: struct { command_id: command.CommandId, terminal: RunTerminal },
};

pub const FollowUpQueued = struct {
    command_id: command.CommandId,
    run_command_id: command.CommandId,
    pending_follow_ups: usize,
};

pub const AbortRequested = struct {
    command_id: command.CommandId,
    run_command_id: command.CommandId,
};

pub const ToolStarted = struct {
    run_command_id: command.CommandId,
    op_id: u64,
    tool_call_id: []const u8,
    tool_name: []const u8,
};

pub const ToolFinished = struct {
    run_command_id: command.CommandId,
    op_id: u64,
    tool_call_id: []const u8,
    tool_name: []const u8,
    terminal: ToolTerminal,
};

pub const ToolTerminal = enum {
    completed,
    failed,
    aborted,
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
