const std = @import("std");
const provider_mod = @import("provider.zig");
const protocol = @import("protocol.zig");
const ai_models = @import("models.zig");
const anthropic = @import("anthropic.zig");
const openai_completions = @import("openai_completions.zig");
const openai_responses_core = @import("openai_responses_core.zig");
const openai_codex = @import("openai_codex.zig");

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    registry: *provider_mod.Registry,

    anthropic_prov: anthropic.AnthropicProvider,
    openai_completions_prov: openai_completions.OpenAICompletionsProvider,
    openai_codex_prov: openai_codex.OpenAICodexProvider,

    pub fn init(allocator: std.mem.Allocator) !*Bundle {
        const self = try allocator.create(Bundle);
        errdefer allocator.destroy(self);

        const registry = try allocator.create(provider_mod.Registry);
        errdefer allocator.destroy(registry);
        registry.* = provider_mod.Registry.init(allocator);
        errdefer registry.deinit();

        self.* = .{
            .allocator = allocator,
            .registry = registry,
            .anthropic_prov = anthropic.AnthropicProvider.init(allocator),
            .openai_completions_prov = openai_completions.OpenAICompletionsProvider.init(allocator),
            .openai_codex_prov = openai_codex.OpenAICodexProvider.init(allocator),
        };

        try registry.register("anthropic-messages", self.anthropic_prov.provider(), null);
        try registry.register("openai-completions", self.openai_completions_prov.provider(), null);
        try registry.register("openai-responses", openaiResponsesProvider(self), null);
        try registry.register("openai-codex-responses", self.openai_codex_prov.provider(), null);
        return self;
    }

    pub fn deinit(self: *Bundle) void {
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        self.allocator.destroy(self);
    }
};

fn openaiResponsesProvider(bundle: *Bundle) provider_mod.Provider {
    return .{
        .ptr = bundle,
        .vtable = &.{
            .stream = streamOpenAIResponses,
            .stream_simple = streamOpenAIResponsesSimple,
            .get_name = getOpenAIResponsesName,
            .deinit = noopProviderDeinit,
        },
    };
}

fn streamOpenAIResponses(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.StreamOptions,
    callback: provider_mod.EventCallback,
    callback_ctx: ?*anyopaque,
) void {
    openai_responses_core.streamCore(allocator, model, context, options, .{
        .path = "/v1/responses",
        .auth = .{ .build = buildBearerAuth },
        .provider_label = "openai-responses",
    }, callback, callback_ctx);
}

fn streamOpenAIResponsesSimple(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.SimpleStreamOptions,
    callback: provider_mod.EventCallback,
    callback_ctx: ?*anyopaque,
) void {
    const clamped = ai_models.clampReasoning(options.reasoning, model);
    const effort: ?[]const u8 = if (clamped) |level| protocol.thinkingLevelToString(level) else null;
    openai_responses_core.streamCore(allocator, model, context, options.base, .{
        .path = "/v1/responses",
        .auth = .{ .build = buildBearerAuth },
        .provider_label = "openai-responses",
        .reasoning_effort = effort,
        .reasoning_summary = if (effort != null) "auto" else null,
    }, callback, callback_ctx);
}

fn getOpenAIResponsesName(_: *anyopaque) []const u8 {
    return "openai-responses";
}

fn noopProviderDeinit(_: *anyopaque) void {}

fn buildBearerAuth(_: ?*anyopaque, buf: []u8, api_key: ?[]const u8) error{ NoApiKey, BufferTooSmall }![]u8 {
    const key = api_key orelse return error.NoApiKey;
    return std.fmt.bufPrint(buf, "Bearer {s}", .{key}) catch return error.BufferTooSmall;
}
