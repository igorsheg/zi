const protocol = @import("protocol.zig");

const text_input = [_]protocol.Model.Input{.text};
const text_image_input = [_]protocol.Model.Input{ .text, .image };

pub const providers = [_]protocol.Provider{
    protocol.KnownProvider.anthropic,
    protocol.KnownProvider.openai,
    protocol.KnownProvider.openai_codex,
};

pub const models = [_]protocol.Model{
    .{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = protocol.KnownApi.anthropic_messages,
        .provider = protocol.KnownProvider.anthropic,
        .base_url = "https://api.anthropic.com",
        .reasoning = true,
        .input = &text_image_input,
        .cost = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200_000,
        .max_tokens = 64_000,
    },
    .{
        .id = "gpt-5.1",
        .name = "GPT-5.1",
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input = &text_image_input,
        .cost = .{ .input = 1.25, .output = 10, .cache_read = 0.125, .cache_write = 0 },
        .context_window = 400_000,
        .max_tokens = 128_000,
    },
    .{
        .id = "gpt-5.1-codex-max",
        .name = "GPT-5.1 Codex Max",
        .api = protocol.KnownApi.openai_codex_responses,
        .provider = protocol.KnownProvider.openai_codex,
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input = &text_image_input,
        .cost = .{ .input = 1.25, .output = 10, .cache_read = 0.125, .cache_write = 0 },
        .context_window = 400_000,
        .max_tokens = 128_000,
    },
    .{
        .id = "gpt-5.1-codex-mini",
        .name = "GPT-5.1 Codex Mini",
        .api = protocol.KnownApi.openai_codex_responses,
        .provider = protocol.KnownProvider.openai_codex,
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input = &text_input,
        .cost = .{ .input = 0.25, .output = 2, .cache_read = 0.025, .cache_write = 0 },
        .context_window = 400_000,
        .max_tokens = 128_000,
    },
};
