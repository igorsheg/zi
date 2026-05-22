const std = @import("std");
const protocol = @import("../../protocol.zig");
const ai_models = @import("../../models.zig");
const ai_provider = @import("../../provider.zig");
const core = @import("core.zig");

pub const OpenAiResponsesProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAiResponsesProvider {
        return .{ .allocator = allocator };
    }

    pub fn provider(self: *OpenAiResponsesProvider) ai_provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .stream = streamImpl,
                .stream_simple = streamSimpleImpl,
                .get_name = getName,
                .deinit = deinitImpl,
            },
        };
    }

    fn streamImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator, // ziglint-ignore: Z023
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        sink: ai_provider.StreamEventSink,
    ) void {
        _ = ptr;
        core.streamCore(allocator, model, context, options, .{
            .path = "/v1/responses",
            .auth = .{ .build = buildBearerAuth },
            .provider_label = "openai-responses",
        }, sink);
    }

    fn streamSimpleImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator, // ziglint-ignore: Z023
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        sink: ai_provider.StreamEventSink,
    ) void {
        _ = ptr;
        const clamped = ai_models.clampReasoning(options.reasoning, model);
        const effort: ?[]const u8 = if (clamped) |level| protocol.thinkingLevelToString(level) else null;
        core.streamCore(allocator, model, context, options.base, .{
            .path = "/v1/responses",
            .auth = .{ .build = buildBearerAuth },
            .provider_label = "openai-responses",
            .reasoning_effort = effort,
            .reasoning_summary = if (effort != null) "auto" else null,
        }, sink);
    }

    fn getName(_: *anyopaque) []const u8 {
        return "openai-responses";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

fn buildBearerAuth(_: ?*anyopaque, buf: []u8, api_key: ?[]const u8) error{ NoApiKey, BufferTooSmall }![]u8 {
    const key = api_key orelse return error.NoApiKey;
    return std.fmt.bufPrint(buf, "Bearer {s}", .{key}) catch return error.BufferTooSmall;
}
