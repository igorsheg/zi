const ai = @import("../ai/root.zig");
const commit = @import("Commit.zig");

/// Process-local identity for one admitted agent run.
pub const RunId = enum(u64) {
    _,
};

pub const TurnIndex = u32;

pub const MessageSnapshot = union(enum) {
    request: ai.message.RequestMessage,
    response: ai.stream.ResponseSnapshot,
};

pub const DiscardedResponse = struct {
    response: ai.stream.ResponseSnapshot,
    outcome: commit.RunOutcome,
};

pub const ResponseEnd = union(enum) {
    published: ai.message.ResponseMessage,
    discarded: DiscardedResponse,
};

pub const MessageEnd = union(enum) {
    /// The canonical message was committed and published to agent history.
    published: ai.message.Message,

    /// Streaming began but did not produce a publishable canonical response.
    discarded_response: DiscardedResponse,
};

pub const AgentStart = struct {
    run_id: RunId,
};

pub const AgentEnd = struct {
    run_id: RunId,
    outcome: commit.RunOutcome,
    /// Canonical messages published by this run, not the entire history.
    messages: []const ai.message.Message,
};

pub const TurnStart = struct {
    run_id: RunId,
    index: TurnIndex,
};

pub const TurnEnd = struct {
    run_id: RunId,
    index: TurnIndex,
    response: ResponseEnd,
    tool_results: []const ai.message.ToolResult,
};

pub const MessageStart = struct {
    run_id: RunId,
    turn_index: TurnIndex,
    message: MessageSnapshot,
};

pub const MessageUpdate = struct {
    run_id: RunId,
    turn_index: TurnIndex,
    /// Complete partial response after applying `update`.
    message: ai.stream.ResponseSnapshot,
    /// Incremental normalized provider event that produced this snapshot.
    update: ai.stream.StreamEvent,
};

pub const MessageFinished = struct {
    run_id: RunId,
    turn_index: TurnIndex,
    message: MessageEnd,
};

pub const ToolExecutionStart = struct {
    run_id: RunId,
    turn_index: TurnIndex,
    call_id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const ToolExecutionResult = union(enum) {
    published: ai.message.ToolResult,
    discarded: commit.RunOutcome,
};

pub const ToolExecutionEnd = struct {
    run_id: RunId,
    turn_index: TurnIndex,
    call_id: []const u8,
    name: []const u8,
    result: ToolExecutionResult,
};

pub const Event = union(enum) {
    agent_start: AgentStart,
    agent_end: AgentEnd,
    turn_start: TurnStart,
    turn_end: TurnEnd,
    message_start: MessageStart,
    message_update: MessageUpdate,
    message_end: MessageFinished,
    tool_execution_start: ToolExecutionStart,
    tool_execution_end: ToolExecutionEnd,
};

pub const SinkError = error{
    OutOfMemory,
    Cancelled,
    ConsumerStopped,
};

/// Event payload slices are borrowed for the duration of `emitFn`.
pub const Sink = struct {
    context: *anyopaque,
    emitFn: *const fn (context: *anyopaque, event: Event) SinkError!void,

    pub fn emit(self: Sink, event: Event) SinkError!void {
        return self.emitFn(self.context, event);
    }
};
