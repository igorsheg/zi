const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const runtime_env = @import("../../runtime/env.zig");
const session_mod = @import("../session.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: runtime_env.Env,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: runtime_env.Env) !Runtime {
        return .{ .allocator = allocator, .io = io, .env = env };
    }

    pub fn deinit(self: *Runtime) void {
        self.* = undefined;
    }

    pub fn resolveModel(self: *Runtime, model_ref: []const u8) ?agent.message.Model {
        _ = self;
        return ai.models.getModelById(model_ref) orelse ai.models.findModel(model_ref);
    }

    pub fn executionBackend(self: *Runtime, model: agent.message.Model) !session_mod.AgentSession.ExecutionBackend {
        _ = self;
        _ = model;
        return error.ProviderUnavailable;
    }
};

fn convertMessages(_: ?*anyopaque, allocator: std.mem.Allocator, messages: []const agent.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message {
    const out = try allocator.alloc(ai.protocol.Message, messages.len);
    for (messages, 0..) |message, i| out[i] = switch (message) {
        .user => |user| .{ .user = user },
        .assistant => |assistant| .{ .assistant = assistant },
        .tool_result => |tool| .{ .tool_result = tool },
        else => std.debug.panic("unsupported message type in provider runtime", .{}),
    };
    return out;
}
