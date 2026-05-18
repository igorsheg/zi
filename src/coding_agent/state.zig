const command = @import("command.zig");

pub const State = struct {
    activity: Activity = .idle,
};

pub const Activity = union(enum) {
    idle,
    running: Running,
    aborting: Running,
    failed: Failed,
};

pub const Running = struct {
    command_id: command.CommandId,
};

pub const Failed = struct {
    reason: []const u8,
};
