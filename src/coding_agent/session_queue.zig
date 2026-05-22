const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const message_memory = @import("../agent/message_memory.zig");
const command_mod = @import("command.zig");
const model_memory = @import("model_memory.zig");

pub const QueuedCommand = struct {
    id: command_mod.CommandId,
    command: OwnedCommand,

    pub fn deinit(self: *QueuedCommand, allocator: std.mem.Allocator) void {
        freeCommand(allocator, self.command);
        self.* = undefined;
    }
};

pub const QueuedAbort = struct {
    id: command_mod.CommandId,
};

pub const OwnedCommand = union(enum) {
    submit_prompt: command_mod.SubmitPrompt,
    follow_up: command_mod.FollowUp,
    steer: command_mod.Steer,
    abort_run,
    continue_run,
    set_model: command_mod.SetModel,
    set_reasoning: command_mod.SetReasoning,
};

pub const QueuedFollowUp = struct {
    id: command_mod.CommandId,
    messages: []const agent_mod.AgentMessage,

    pub fn deinit(self: *QueuedFollowUp, allocator: std.mem.Allocator) void {
        freeMessages(allocator, self.messages);
        self.* = undefined;
    }
};

pub fn cloneCommand(allocator: std.mem.Allocator, value: command_mod.Command) !OwnedCommand {
    return switch (value) {
        .submit_prompt => |prompt| .{ .submit_prompt = .{ .messages = try cloneMessages(allocator, prompt.messages) } },
        .follow_up => |follow_up| .{ .follow_up = .{ .messages = try cloneMessages(allocator, follow_up.messages) } },
        .steer => |steer| .{ .steer = .{ .text = try allocator.dupe(u8, steer.text) } },
        .set_model => |set| .{ .set_model = .{ .model = try model_memory.cloneModel(allocator, set.model) } },
        .set_reasoning => |set| .{ .set_reasoning = set },
        .abort_run => .abort_run,
        .continue_run => .continue_run,
    };
}

pub fn freeCommand(allocator: std.mem.Allocator, value: OwnedCommand) void {
    switch (value) {
        .submit_prompt => |prompt| freeMessages(allocator, prompt.messages),
        .follow_up => |follow_up| freeMessages(allocator, follow_up.messages),
        .steer => |steer| allocator.free(steer.text),
        .set_model => |set| model_memory.freeModel(allocator, set.model),
        .set_reasoning => {},
        .abort_run, .continue_run => {},
    }
}

pub fn cloneMessages(
    allocator: std.mem.Allocator,
    messages: []const agent_mod.AgentMessage,
) ![]const agent_mod.AgentMessage {
    return message_memory.cloneMessages(allocator, messages);
}

pub fn freeMessages(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) void {
    for (messages) |msg| message_memory.freeMessage(allocator, msg);
    allocator.free(messages);
}

