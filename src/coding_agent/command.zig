const agent_message = @import("../agent/message.zig");

pub const CommandId = enum(u64) { _ };

pub const Command = union(enum) {
    submit_prompt: SubmitPrompt,
    abort_run,
    continue_run,
};

pub const SubmitPrompt = struct {
    messages: []const agent_message.AgentMessage,
};

pub const SubmitResult = union(enum) {
    accepted: CommandId,
    rejected: Rejection,
};

pub const Rejection = union(enum) {
    busy,
    invalid_state,
    queue_full,
};
