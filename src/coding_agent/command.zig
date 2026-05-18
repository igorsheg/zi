const ai = @import("../ai/root.zig");
const agent_message = @import("../agent/message.zig");

pub const CommandId = enum(u64) { _ };

pub const Command = union(enum) {
    submit_prompt: SubmitPrompt,
    follow_up: FollowUp,
    steer: Steer,
    abort_run,
    continue_run,
    set_model: SetModel,
    set_reasoning: SetReasoning,
};

pub const SubmitPrompt = struct {
    messages: []const agent_message.AgentMessage,
};

pub const FollowUp = struct {
    messages: []const agent_message.AgentMessage,
};

pub const Steer = struct {
    text: []const u8,
};

pub const SetModel = struct {
    model: agent_message.Model,
};

pub const SetReasoning = struct {
    reasoning: ?ai.protocol.ThinkingLevel,
};

pub const SubmitResult = union(enum) {
    accepted: CommandId,
    rejected: Rejection,
};

pub const Rejection = union(enum) {
    busy,
    invalid_state,
    queue_full,
    follow_up_queue_full,
    unsupported,
};
