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

/// Heap-owned set of built-in providers + the registry they're
/// registered into. One bundle per generation; deinit destroys
/// every owned provider after closing the registry.
pub const Bundle = struct {
    allocator: std.mem.Allocator,
    registry: *provider_mod.Registry,

    // Each provider that needs persistent state lives here as a
    // heap allocation. Adding a new built-in provider = one field
    // here, one register() call in `init`, one destroy in `deinit`.
    anthropic_prov: *anthropic.AnthropicProvider,
    openai_completions_prov: *openai_completions.OpenAICompletionsProvider,

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

        // openai-completions: openrouter today, future custom
        // OpenAI-compatible providers reuse this slot.
        const oac = try allocator.create(openai_completions.OpenAICompletionsProvider);
        errdefer allocator.destroy(oac);
        oac.* = openai_completions.OpenAICompletionsProvider.init(allocator);
        try registry.register("openai-completions", oac.provider(), null);

        self.* = .{
            .allocator = allocator,
            .registry = registry,
            .anthropic_prov = anth,
            .openai_completions_prov = oac,
        };
        return self;
    }

    pub fn deinit(self: *Bundle) void {
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        // Destroy in reverse registration order — providers don't
        // currently have ordering dependencies on each other, but
        // keeping the discipline now means future providers that DO
        // (e.g. shared core wrappers) get correct teardown for free.
        self.allocator.destroy(self.openai_completions_prov);
        self.allocator.destroy(self.anthropic_prov);
        self.allocator.destroy(self);
    }
};
