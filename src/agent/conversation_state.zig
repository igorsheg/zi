const std = @import("std");
const event = @import("event.zig");
const message = @import("message.zig");
const failure = @import("failure.zig");

pub const Projection = struct {
    state: State = .idle,

    pub const State = union(enum) {
        idle,
        running: Running,
        failed: failure.Failure,
        aborted,
    };

    pub const Running = struct {
        turn_open: bool = false,
        pending_tool_count: usize = 0,
    };

    pub const Effect = union(enum) {
        none,
        commit_message: message.AgentMessage,
        terminal,
    };

    pub fn apply(self: *Projection, value: event.AgentEvent) Effect {
        switch (value) {
            .lifecycle => |lifecycle| return self.applyLifecycle(lifecycle),
            .message => |stream| return self.applyMessage(stream),
            .tool => |tool_event| return self.applyTool(tool_event),
        }
    }

    fn applyLifecycle(self: *Projection, lifecycle: event.Lifecycle) Effect {
        switch (lifecycle) {
            .run_started => {
                self.state = .{ .running = .{} };
                return .none;
            },
            .turn_started => {
                switch (self.state) {
                    .running => |*running| running.turn_open = true,
                    else => self.state = .{ .running = .{ .turn_open = true } },
                }
                return .none;
            },
            .turn_finished => |terminal| {
                switch (terminal) {
                    .completed => |completed| {
                        switch (self.state) {
                            .running => |*running| running.turn_open = false,
                            else => {},
                        }
                        return .{ .commit_message = completed.message };
                    },
                    .failed => |failed| {
                        self.state = .{ .failed = failed.reason };
                        return .terminal;
                    },
                    .aborted => {
                        self.state = .aborted;
                        return .terminal;
                    },
                }
            },
            .run_finished => |terminal| {
                switch (terminal) {
                    .completed => self.state = .idle,
                    .failed => |failed| self.state = .{ .failed = failed.reason },
                    .aborted => self.state = .aborted,
                }
                return .terminal;
            },
        }
    }

    fn applyMessage(_: *Projection, stream: event.MessageStream) Effect {
        switch (stream) {
            .started, .delta, .finished => return .none,
        }
    }

    fn applyTool(self: *Projection, tool_event: event.ToolEvent) Effect {
        switch (tool_event) {
            .started => {
                switch (self.state) {
                    .running => |*running| running.pending_tool_count += 1,
                    else => self.state = .{ .running = .{ .pending_tool_count = 1 } },
                }
                return .none;
            },
            .finished => {
                switch (self.state) {
                    .running => |*running| {
                        if (running.pending_tool_count > 0) running.pending_tool_count -= 1;
                    },
                    else => {},
                }
                return .none;
            },
            .update => return .none,
        }
    }
};

test "projection tracks run terminal state" {
    var projection = Projection{};
    try std.testing.expect(projection.apply(.{ .lifecycle = .run_started }) == .none);
    switch (projection.state) {
        .running => {},
        else => return error.TestExpectedEqual,
    }
    _ = projection.apply(.{ .lifecycle = .{ .run_finished = .{ .failed = .{ .messages = &.{}, .reason = .{ .invalid_context = "bad" } } } } });
    switch (projection.state) {
        .failed => |reason| switch (reason) {
            .invalid_context => |msg| try std.testing.expectEqualStrings("bad", msg),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}
