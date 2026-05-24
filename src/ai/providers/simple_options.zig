const std = @import("std");
const protocol = @import("../protocol.zig");

const default_max_tokens_ceiling: u32 = 32_000;
const default_min_output_tokens: u32 = 1_024;

pub const BaseOptions = struct {
    stream: protocol.StreamOptions,
};

pub const AdjustedThinking = struct {
    max_tokens: u32,
    thinking_budget: u32,
};

pub fn buildBaseOptions(
    model: protocol.Model,
    options: protocol.SimpleStreamOptions,
    api_key: ?[]const u8,
) protocol.StreamOptions {
    var stream = options.stream;
    if (stream.max_tokens == null and model.max_tokens > 0) {
        const model_max_tokens: u32 = @intCast(@min(model.max_tokens, default_max_tokens_ceiling));
        stream.max_tokens = @min(model_max_tokens, default_max_tokens_ceiling);
    }
    if (api_key) |key| {
        if (key.len > 0) stream.api_key = key;
    }
    return stream;
}

pub fn clampReasoning(effort: ?protocol.ThinkingLevel) ?protocol.ThinkingLevel {
    return switch (effort orelse return null) {
        .xhigh => .high,
        else => |level| level,
    };
}

pub fn adjustMaxTokensForThinking(
    base_max_tokens: u32,
    model_max_tokens: u32,
    reasoning_level: protocol.ThinkingLevel,
    custom_budgets: ?protocol.ThinkingBudgets,
) AdjustedThinking {
    const budgets = custom_budgets orelse protocol.ThinkingBudgets{};
    var thinking_budget = budgetForLevel(reasoning_level, budgets);
    const max_tokens = @min(base_max_tokens +| thinking_budget, model_max_tokens);

    if (max_tokens <= thinking_budget) {
        thinking_budget = if (max_tokens > default_min_output_tokens) max_tokens - default_min_output_tokens else 0;
    }

    return .{ .max_tokens = max_tokens, .thinking_budget = thinking_budget };
}

fn budgetForLevel(level: protocol.ThinkingLevel, budgets: protocol.ThinkingBudgets) u32 {
    return switch (clampReasoning(level).?) {
        .minimal => budgets.minimal orelse 1_024,
        .low => budgets.low orelse 2_048,
        .medium => budgets.medium orelse 8_192,
        .high => budgets.high orelse 16_384,
        .xhigh => unreachable,
    };
}

test "base options defaults max tokens to model cap up to ceiling" {
    const model = testModel(100_000);

    const options = buildBaseOptions(model, .{}, null);

    try std.testing.expectEqual(@as(?u32, 32_000), options.max_tokens);
}

test "base options keeps explicit max tokens and prefers provided api key" {
    const model = testModel(100_000);
    const options = buildBaseOptions(model, .{ .stream = .{ .max_tokens = 512, .api_key = "old" } }, "new");

    try std.testing.expectEqual(@as(?u32, 512), options.max_tokens);
    try std.testing.expectEqualStrings("new", options.api_key.?);
}

test "clamp reasoning maps xhigh to high" {
    try std.testing.expectEqual(protocol.ThinkingLevel.high, clampReasoning(.xhigh).?);
    try std.testing.expectEqual(protocol.ThinkingLevel.medium, clampReasoning(.medium).?);
    try std.testing.expectEqual(@as(?protocol.ThinkingLevel, null), clampReasoning(null));
}

test "thinking budget expands max tokens and leaves minimum output room" {
    const adjusted = adjustMaxTokensForThinking(4_000, 5_000, .high, null);

    try std.testing.expectEqual(@as(u32, 5_000), adjusted.max_tokens);
    try std.testing.expectEqual(@as(u32, 3_976), adjusted.thinking_budget);
}

fn testModel(max_tokens: u64) protocol.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .base_url = "https://example.test",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = max_tokens,
    };
}
