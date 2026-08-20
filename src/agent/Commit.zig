const message = @import("../ai/message.zig");

pub const Error = error{
    OutOfMemory,
    SessionTooLarge,
    PersistenceFailed,
    CommitIndeterminate,
};

pub const MessageKind = enum {
    user,
    response,
    tool_result,
};

pub const Failure = enum {
    resource_exhausted,
    timed_out,
    unsupported_capability,
    unsupported_setting,
    invalid_request,
    connection_failed,
    rate_limited,
    provider_rejected_request,
    provider_unavailable,
    invalid_provider_response,
    event_consumer_stopped,
    handoff_rejected,
    max_model_requests_exceeded,
    max_tool_calls_exceeded,
    tool_result_too_large,
    tool_control_unavailable,
    persistence_failed,
};

pub const RunOutcome = union(enum) {
    completed,
    failed: Failure,
    cancelled,
    interrupted,
};

pub const Sink = struct {
    context: *anyopaque,
    messageFn: *const fn (context: *anyopaque, kind: MessageKind, value: message.Message) Error!void,
    settleFn: *const fn (context: *anyopaque, outcome: RunOutcome) Error!void,

    pub fn commitMessage(self: Sink, kind: MessageKind, value: message.Message) Error!void {
        return self.messageFn(self.context, kind, value);
    }

    pub fn settleRun(self: Sink, outcome: RunOutcome) Error!void {
        return self.settleFn(self.context, outcome);
    }
};
