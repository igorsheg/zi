const message = @import("message.zig");
const tool = @import("tool.zig");
const failure = @import("failure.zig");

pub const AgentEvent = union(enum) {
    lifecycle: Lifecycle,
    message: MessageStream,
    tool: ToolEvent,
};

pub const Lifecycle = union(enum) {
    run_started,
    run_finished: RunTerminal,
    turn_started,
    turn_finished: TurnTerminal,
};

pub const RunTerminal = union(enum) {
    completed: struct { messages: []const message.AgentMessage },
    failed: struct { messages: []const message.AgentMessage, reason: failure.Failure },
    aborted: struct { messages: []const message.AgentMessage },
};

pub const TurnTerminal = union(enum) {
    completed: struct { message: message.AgentMessage, tool_results: []const message.ToolResultMessage },
    failed: struct { message: ?message.AgentMessage, tool_results: []const message.ToolResultMessage, reason: failure.Failure },
    aborted: struct { message: ?message.AgentMessage, tool_results: []const message.ToolResultMessage },
};

pub const MessageStream = union(enum) {
    started,
    delta: message.AssistantMessageEvent,
    finished: message.AssistantMessage,
};

pub const ToolEvent = union(enum) {
    started: struct { op_id: tool.ToolOpId, tool_call_id: []const u8, tool_name: []const u8 },
    update: tool.ToolUpdate,
    finished: tool.ToolTerminalCompletion,
};

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    emit_fn: *const fn (event: AgentEvent, ctx: ?*anyopaque) void,

    pub fn emit(self: Sink, event: AgentEvent) void {
        self.emit_fn(event, self.ctx);
    }
};
