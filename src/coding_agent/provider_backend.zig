const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const session_mod = @import("session.zig");

pub const Options = struct {
    io: std.Io,
    api_key: ?[]const u8 = null,
    transport: ?ai.protocol.Transport = null,
};

pub fn synchronous(provider: *ai.provider.Provider, options: Options) session_mod.AgentSession.ExecutionBackend {
    return .{
        .stream = .{ .call_fn = streamProvider, .ctx = provider },
        .convert_messages = .{ .call_fn = convertMessages },
        .io = options.io,
        .api_key = options.api_key,
        .transport = options.transport,
    };
}

fn streamProvider(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: agent.message.Model,
    context: ai.protocol.Context,
    options: ai.protocol.SimpleStreamOptions,
    sink: ai.provider.StreamEventSink,
) error{OutOfMemory}!void {
    const provider: *const ai.provider.Provider = @ptrCast(@alignCast(ctx.?));
    provider.streamSimple(allocator, model, context, options, sink);
}

fn convertMessages(_: ?*anyopaque, allocator: std.mem.Allocator, messages: []const agent.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message {
    const out = try allocator.alloc(ai.protocol.Message, messages.len);
    for (messages, 0..) |message, i| out[i] = switch (message) {
        .user => |user| .{ .user = user },
        .assistant => |assistant| .{ .assistant = assistant },
        .tool_result => |tool| .{ .tool_result = tool },
        else => std.debug.panic("unsupported message type in provider backend", .{}),
    };
    return out;
}
