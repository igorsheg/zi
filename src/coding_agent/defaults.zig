//! Default model id per provider, walked in declaration order during
//! `resolve.findInitialModel` step 4 (first authed provider's default
//! model). Declaration order == priority.
//!
//! pi-mono source: packages/coding-agent/src/core/model-resolver.ts:14-38
//!
//! Phase 2 ships a reduced set: only the providers zi has registered
//! under the auth-duality matrix (anthropic + openai + openai-codex +
//! openrouter). The full table returns as phases 3/4 land more
//! providers. See issue zi-1er for the full phase plan.

const protocol = @import("../ai/protocol.zig");

pub const Entry = struct {
    provider: protocol.Provider,
    id: []const u8,
};

pub const default_model_per_provider = [_]Entry{
    .{ .provider = .anthropic, .id = "claude-opus-4-6" },
    .{ .provider = .openai, .id = "gpt-5.4" },
    .{ .provider = .openai_codex, .id = "gpt-5.4" },
    .{ .provider = .openrouter, .id = "openai/gpt-5.1-codex" },
};

/// pi-mono: packages/coding-agent/src/core/defaults.ts:3
pub const DEFAULT_THINKING_LEVEL: protocol.ThinkingLevel = .medium;
