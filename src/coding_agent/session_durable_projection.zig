const agent_mod = @import("../agent/root.zig");
const durable_mod = @import("durable.zig");
const event_mod = @import("event.zig");

pub const Append = union(enum) {
    appended,
    skipped,
    failed: Failure,
};

pub const Failure = enum {
    durable_append_rejected,
    durable_append_failed,
    unsupported_batch,
};

pub const Projection = struct {
    appender: *durable_mod.Appender,
    event_sink: ?event_mod.Sink,

    pub fn appendRunInput(self: Projection, messages: []const agent_mod.AgentMessage) Append {
        if (self.appender.* == .disabled) return .skipped;
        if (messages.len == 0) return .skipped;
        if (messages.len != 1) {
            self.emit(.{ .session = .{ .append_rejected = .unsupported_batch } });
            return .{ .failed = .unsupported_batch };
        }
        return self.appendMessage(messages[0]);
    }

    pub fn appendCompletedTerminal(self: Projection, messages: []const agent_mod.AgentMessage) Append {
        if (self.appender.* == .disabled) return .skipped;
        var appended_any = false;
        for (messages) |message| {
            switch (self.appendMessage(message)) {
                .appended => appended_any = true,
                .skipped => {},
                .failed => |failure| return .{ .failed = failure },
            }
        }
        return if (appended_any) .appended else .skipped;
    }

    fn appendMessage(self: Projection, message: agent_mod.AgentMessage) Append {
        const result = self.appender.append(.{ .message = .{ .message = message } });
        switch (result) {
            .appended => |id| {
                self.emit(.{ .session = .{ .appended = id } });
                return .appended;
            },
            .rejected => |reason| {
                self.emit(.{ .session = .{ .append_rejected = reason } });
                return .{ .failed = .durable_append_rejected };
            },
            .failed => |failure| {
                self.emit(.{ .session = .{ .append_failed = failure } });
                return .{ .failed = .durable_append_failed };
            },
        }
    }

    fn emit(self: Projection, value: event_mod.Event) void {
        if (self.event_sink) |sink| sink.emit(value);
    }
};
