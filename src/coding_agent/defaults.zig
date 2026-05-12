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

pub const DEFAULT_THINKING_LEVEL: protocol.ThinkingLevel = .medium;
