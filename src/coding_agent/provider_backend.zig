const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");

pub const Options = struct {
    io: std.Io,
    api_key: ?[]const u8 = null,
    transport: ?ai.protocol.Transport = null,
};

pub fn synchronous(provider: *ai.provider.Provider, options: Options) agent.config.RunBackend {
    return .{
        .stream = .{ .call_fn = streamProvider, .ctx = provider },
        .convert_messages = agent.llm_messages.default_hook,
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
