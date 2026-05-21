const ai = @import("../ai/root.zig");
const schema = @import("schema.zig");

pub fn modelToProtocol(model: schema.Model) ai.protocol.Model {
    const provider = ai.protocol.parseProvider(model.provider);
    return .{
        .id = model.id,
        .provider_model = model.provider_model,
        .name = model.name orelse model.id,
        .api = ai.protocol.parseApi(model.api),
        .provider = provider,
        .base_url = model.base_url orelse ai.models.defaultBaseUrlForProvider(provider) orelse "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = model.context_window orelse 0,
        .max_tokens = model.max_tokens orelse 0,
    };
}

test "settings model resolves user id separately from provider request model" {
    const model = modelToProtocol(.{
        .id = "openrouter/sonnet",
        .name = "Sonnet via OpenRouter",
        .api = "openai-completions",
        .provider = "openrouter",
        .provider_model = "anthropic/claude-sonnet-4",
    });

    try @import("std").testing.expectEqualStrings("openrouter/sonnet", model.id);
    try @import("std").testing.expectEqualStrings("anthropic/claude-sonnet-4", model.requestModel());
    try @import("std").testing.expectEqualStrings("https://openrouter.ai/api/v1", model.base_url);
}
