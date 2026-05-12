const std = @import("std");
const protocol = @import("protocol.zig");
const ai_models = @import("models.zig");
const ai_provider = @import("provider.zig");
const core = @import("openai_responses_core.zig");

pub const OpenAIResponsesProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAIResponsesProvider {
        return .{ .allocator = allocator };
    }

    pub fn provider(self: *OpenAIResponsesProvider) ai_provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .stream = streamWrap,
                .stream_simple = streamSimpleWrap,
                .get_name = getName,
                .deinit = deinitImpl,
            },
        };
    }

    fn streamWrap(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        _ = ptr;
        core.streamCore(allocator, model, context, options, .{
            .path = "/v1/responses",
            .auth = .{ .build = buildBearerAuth },
            .provider_label = "openai-responses",
        }, callback, callback_ctx);
    }

    fn streamSimpleWrap(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        _ = ptr;
        const clamped = ai_models.clampReasoning(options.reasoning, model);
        const effort: ?[]const u8 = if (clamped) |l| protocol.thinkingLevelToString(l) else null;
        core.streamCore(allocator, model, context, options.base, .{
            .path = "/v1/responses",
            .auth = .{ .build = buildBearerAuth },
            .provider_label = "openai-responses",
            .reasoning_effort = effort,
            .reasoning_summary = if (effort != null) "auto" else null,
        }, callback, callback_ctx);
    }

    fn getName(_: *anyopaque) []const u8 {
        return "openai-responses";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

fn buildBearerAuth(
    _: ?*anyopaque,
    buf: []u8,
    api_key: ?[]const u8,
) error{ NoApiKey, BufferTooSmall }![]u8 {
    const key = api_key orelse return error.NoApiKey;
    return std.fmt.bufPrint(buf, "Bearer {s}", .{key}) catch return error.BufferTooSmall;
}
