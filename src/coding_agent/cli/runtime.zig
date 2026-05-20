const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const runtime_env = @import("../../runtime/env.zig");
const session_mod = @import("../session.zig");
const openai_responses = @import("../../ai/openai/responses/provider.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: runtime_env.Env,
    openai_responses_provider: openai_responses.OpenAIResponsesProvider,
    active_provider: ?ai.provider.Provider = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: runtime_env.Env) !Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .openai_responses_provider = openai_responses.OpenAIResponsesProvider.init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.* = undefined;
    }

    pub fn resolveModel(self: *Runtime, model_ref: []const u8) ?agent.message.Model {
        _ = self;
        return ai.models.getModelById(model_ref) orelse ai.models.findModel(model_ref);
    }

    pub fn executionBackend(self: *Runtime, model: agent.message.Model) !session_mod.AgentSession.ExecutionBackend {
        if (model.provider != .openai or model.api != .openai_responses) return error.ProviderUnavailable;
        const api_key = self.env.get("OPENAI_API_KEY") orelse return error.MissingApiKey;
        self.active_provider = self.openai_responses_provider.provider();
        return .{
            .stream = .{ .call_fn = ProviderBridge.stream, .ctx = &self.active_provider.? },
            .convert_messages = .{ .call_fn = convertMessages },
            .io = self.io,
            .api_key = api_key,
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
