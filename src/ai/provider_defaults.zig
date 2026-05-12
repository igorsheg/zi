const std = @import("std");
const provider_mod = @import("provider.zig");
const anthropic = @import("anthropic.zig");
const openai_completions = @import("openai_completions.zig");
const openai_responses = @import("openai_responses.zig");
const openai_codex = @import("openai_codex.zig");

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    registry: *provider_mod.Registry,

    anthropic_prov: *anthropic.AnthropicProvider,
    openai_completions_prov: *openai_completions.OpenAICompletionsProvider,
    openai_responses_prov: *openai_responses.OpenAIResponsesProvider,
    openai_codex_prov: *openai_codex.OpenAICodexProvider,

    pub fn init(allocator: std.mem.Allocator) !*Bundle {
        const self = try allocator.create(Bundle);
        errdefer allocator.destroy(self);

        const registry = try allocator.create(provider_mod.Registry);
        errdefer allocator.destroy(registry);
        registry.* = provider_mod.Registry.init(allocator);
        errdefer registry.deinit();

        const anth = try allocator.create(anthropic.AnthropicProvider);
        errdefer allocator.destroy(anth);
        anth.* = anthropic.AnthropicProvider.init(allocator);
        try registry.register("anthropic-messages", anth.provider(), null);

        const oac = try allocator.create(openai_completions.OpenAICompletionsProvider);
        errdefer allocator.destroy(oac);
        oac.* = openai_completions.OpenAICompletionsProvider.init(allocator);
        try registry.register("openai-completions", oac.provider(), null);

        const oar = try allocator.create(openai_responses.OpenAIResponsesProvider);
        errdefer allocator.destroy(oar);
        oar.* = openai_responses.OpenAIResponsesProvider.init(allocator);
        try registry.register("openai-responses", oar.provider(), null);

        const ocx = try allocator.create(openai_codex.OpenAICodexProvider);
        errdefer allocator.destroy(ocx);
        ocx.* = openai_codex.OpenAICodexProvider.init(allocator);
        try registry.register("openai-codex-responses", ocx.provider(), null);

        self.* = .{
            .allocator = allocator,
            .registry = registry,
            .anthropic_prov = anth,
            .openai_completions_prov = oac,
            .openai_responses_prov = oar,
            .openai_codex_prov = ocx,
        };
        return self;
    }

    pub fn deinit(self: *Bundle) void {
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        self.allocator.destroy(self.openai_codex_prov);
        self.allocator.destroy(self.openai_responses_prov);
        self.allocator.destroy(self.openai_completions_prov);
        self.allocator.destroy(self.anthropic_prov);
        self.allocator.destroy(self);
    }
};
