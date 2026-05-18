const command = @import("command.zig");

pub const State = struct {
    activity: Activity = .idle,
};

pub const Activity = union(enum) {
    idle,
    running: Running,
    aborting: Aborting,
    failed: Failed,
};

pub const Running = struct {
    command_id: command.CommandId,
    pending_follow_ups: usize = 0,
    pending_steering: usize = 0,
};

pub const Aborting = struct {
    command_id: command.CommandId,
    pending_follow_ups: usize = 0,
};

pub const Failed = struct {
    reason: []const u8,
};
