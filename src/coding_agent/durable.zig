const session_event = @import("../session/event.zig");

pub const AppendResult = union(enum) {
    appended: session_event.EventId,
    rejected: Rejection,
    failed: Failure,
};

pub const Rejection = union(enum) {
    unsupported_batch,
    unsupported_payload,
    invalid_state,
};

pub const Failure = union(enum) {
    out_of_memory,
    io,
    internal,
};

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    append_fn: *const fn (payload: session_event.Payload, ctx: ?*anyopaque) AppendResult,

    pub fn append(self: Sink, payload: session_event.Payload) AppendResult {
        return self.append_fn(payload, self.ctx);
    }
};
