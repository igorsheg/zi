const std = @import("std");
const ai = @import("../ai/root.zig");

/// Tracks the suffix that is unsafe to send back to a provider while a tool
/// exchange is incomplete. Durable restoration and the live agent both use
/// this policy so reopening a session cannot change provider context.
pub const State = struct {
    unsafe_start: ?usize = null,

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    pub fn publishResponse(
        self: *State,
        message_index: usize,
        response: ai.message.ResponseMessage,
    ) void {
        if (countToolCalls(response) > 0) self.unsafe_start = message_index;
    }

    pub fn completeToolExchange(self: *State) void {
        self.unsafe_start = null;
    }

    pub fn completed(self: *State, message_count: usize) usize {
        self.reset();
        return message_count;
    }

    pub fn abandoned(self: *State, message_count: usize) usize {
        const retained = self.unsafe_start orelse message_count;
        self.reset();
        return retained;
    }
};

fn countToolCalls(response: ai.message.ResponseMessage) usize {
    var count: usize = 0;
    for (response.parts) |part| switch (part) {
        .tool_call => count += 1,
        else => {},
    };
    return count;
}

test "abandoned projection drops only an incomplete tool exchange" {
    var state: State = .{};
    state.publishResponse(2, .{
        .parts = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
        .identity = .{ .provider = "script", .model = "projection" },
        .finish = .{ .category = .tool_calls },
    });
    try std.testing.expectEqual(@as(usize, 2), state.abandoned(4));

    state.publishResponse(5, .{
        .parts = &.{.{ .tool_call = .{ .id = "call", .name = "read", .arguments_json = "{}" } }},
        .identity = .{ .provider = "script", .model = "projection" },
        .finish = .{ .category = .tool_calls },
    });
    state.completeToolExchange();
    try std.testing.expectEqual(@as(usize, 7), state.abandoned(7));
}
