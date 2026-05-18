const std = @import("std");
const durable = @import("durable.zig");
const session_event = @import("../session/event.zig");
const session_store = @import("../session/store.zig");

pub const StoreAppender = struct {
    store: *session_store.Store,
    io: std.Io,
    random: std.Random,
    timestamp: []const u8,
    last_event_id: ?session_event.EventId = null,

    pub fn append(self: *StoreAppender, payload: session_event.Payload) durable.AppendResult {
        const parent_id: ?[]const u8 = if (self.last_event_id) |*id| id else null;
        const id = self.store.appendPayload(self.io, self.random, parent_id, self.timestamp, payload) catch |err| {
            return mapAppendError(err);
        };
        self.last_event_id = id;
        return .{ .appended = id };
    }
};

fn mapAppendError(err: anyerror) durable.AppendResult {
    return switch (err) {
        error.OutOfMemory => .{ .failed = .out_of_memory },
        error.DuplicateEntryId, error.EmptyEntryId, error.EmptyParentEntryId, error.UnknownParentEntryId => .{ .rejected = .invalid_state },
        else => .{ .failed = .io },
    };
}
