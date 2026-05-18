const message = @import("message.zig");
const failure = @import("failure.zig");

pub const AgentState = struct {
    messages: []const message.AgentMessage = &.{},
    activity: Activity = .idle,

    pub const Activity = union(enum) {
        idle,
        running: Running,
        failed: Failed,
        aborted,
    };

    pub const Running = struct {
        turn_open: bool,
        pending_tool_count: usize = 0,
    };

    pub const Failed = struct {
        reason: failure.Failure,
    };
};
