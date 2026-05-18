const std = @import("std");
const session_event = @import("../session/event.zig");
const durable_store = @import("durable_store.zig");

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

pub const Appender = union(enum) {
    disabled,
    store: *durable_store.StoreAppender,
    scripted: *ScriptedAppender,

    pub fn append(self: *Appender, payload: session_event.Payload) AppendResult {
        return switch (self.*) {
            .disabled => .{ .failed = .internal },
            .store => |store| store.append(payload),
            .scripted => |scripted| scripted.append(payload),
        };
    }
};

pub const ScriptedAppender = struct {
    result: AppendResult,
    message_count: usize = 0,

    pub fn append(self: *ScriptedAppender, payload: session_event.Payload) AppendResult {
        if (payload == .message) self.message_count += 1;
        return self.result;
    }
};
