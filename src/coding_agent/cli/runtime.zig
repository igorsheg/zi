const std = @import("std");
const ai = @import("../../ai/root.zig");
const env_api_keys = @import("../../ai/env_api_keys.zig");
const agent = @import("../../agent/root.zig");
const runtime_env = @import("../../runtime/env.zig");
const session_mod = @import("../session.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: runtime_env.Env,
    provider_bundle: *ai.provider_defaults.Bundle,
    active_provider: ?ai.provider.Provider = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: runtime_env.Env) !Runtime {
        const provider_bundle = try ai.provider_defaults.Bundle.init(allocator);
        errdefer provider_bundle.deinit();
        return .{ .allocator = allocator, .io = io, .env = env, .provider_bundle = provider_bundle };
    }

    pub fn deinit(self: *Runtime) void {
        self.provider_bundle.deinit();
        self.* = undefined;
    }

    pub fn resolveModel(self: *Runtime, model_ref: []const u8) ?agent.message.Model {
        _ = self;
        return ai.models.getModelById(model_ref) orelse ai.models.findModel(model_ref);
    }

    pub fn executionBackend(self: *Runtime, model: agent.message.Model) !session_mod.AgentSession.ExecutionBackend {
        const provider_name = ai.protocol.providerToString(model.provider);
        const provider = self.provider_bundle.registry.getForModel(ai.protocol.apiToString(model.api), provider_name) orelse return error.ProviderUnavailable;
        self.active_provider = provider;
        return .{
            .stream = .{ .call_fn = ProviderBridge.stream, .ctx = &self.active_provider.? },
            .convert_messages = .{ .call_fn = convertMessages },
            .io = self.io,
            .api_key = env_api_keys.getEnvApiKey(self.env, provider_name),
            .transport = .sse,
        };
    }
};

const ProviderBridge = struct {
    fn stream(ctx: ?*anyopaque, allocator: std.mem.Allocator, model: agent.message.Model, context: ai.protocol.Context, options: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
        const provider: *const ai.provider.Provider = @ptrCast(@alignCast(ctx.?));
        provider.streamSimple(allocator, model, context, options, sink);
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
