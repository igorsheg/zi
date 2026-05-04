//! Canonical built-in provider bundle.
//!
//! Why this module exists: previously each entry path (interactive,
//! print, json, tests) hand-built its own `ai.provider.Registry` and
//! manually registered the providers it cared about. That meant
//!   1. adding a provider required touching every mode in `main.zig`,
//!   2. switching to a model whose `api` wasn't registered silently
//!      no-op'd inside `StreamClosure.streamFn` ("Working..." then
//!      nothing — see beads zi-yjc),
//!   3. the upcoming extension `provider_queue` (D2) had no single
//!      registry to flush into.
//!
//! `Bundle` is the one place that knows the full set of built-in
//! providers, owns their backing structs on the heap, and registers
//! them into a `Registry` under their `Api` identifiers. The sdk
//! factory creates one per `AgentSession` and stores it on the
//! session for tear-down. Tests that want a custom registry pass
//! their own and skip the bundle.

const std = @import("std");
const provider_mod = @import("provider.zig");
const anthropic = @import("anthropic.zig");
const openai_completions = @import("openai_completions.zig");
const openai_responses = @import("openai_responses.zig");
const openai_codex = @import("openai_codex.zig");

/// Heap-owned set of built-in providers + the registry they're
/// registered into. One bundle per generation; deinit destroys
/// every owned provider after closing the registry.
pub const Bundle = struct {
    allocator: std.mem.Allocator,
    registry: *provider_mod.Registry,

    anthropic_prov: *anthropic.AnthropicProvider,
    openai_completions_prov: *openai_completions.OpenAICompletionsProvider,
    openai_responses_prov: *openai_responses.OpenAIResponsesProvider,
    openai_codex_prov: *openai_codex.OpenAICodexProvider,

    /// Allocate a fresh registry, populate it with every built-in
    /// provider, and return an owned bundle.
    ///
    /// Caller deinits via `deinit`. Order matters: the registry must
    /// outlive any `AgentSession` that holds a reference to it,
    /// which is why both live in the same struct and the session's
    /// deinit drops the bundle after the agent.
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
