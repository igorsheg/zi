const std = @import("std");

const ai = @import("../ai/root.zig");

pub fn userText(message: ai.UserMessage) ?[]const u8 {
    return switch (message.content) {
        .string => |text| text,
        .blocks => |blocks| for (blocks) |block| {
            if (block == .text) break block.text.text;
        } else null,
    };
}

pub fn isContextOverflowAssistant(message: ai.AssistantMessage) bool {
    if (message.stop_reason != .error_) return false;
    if (message.operational_failure) |failure| return failure.category == .context_overflow;
    const text = message.error_message orelse return false;
    return ai.isContextOverflowText(text);
}

pub fn isRetryableAssistant(message: ai.AssistantMessage) bool {
    if (message.stop_reason != .error_) return false;
    if (isContextOverflowAssistant(message)) return false;
    if (message.operational_failure) |failure| switch (failure.retryable) {
        .yes => return true,
        .no => return false,
        .unknown => {},
    };
    const text = message.error_message orelse return false;
    return isRetryableAssistantErrorText(text);
}

fn isRetryableAssistantErrorText(text: []const u8) bool {
    const needles = [_][]const u8{
        "overloaded",          "rate limit",   "too many requests", "429",
        "500",                 "502",          "503",               "504",
        "service unavailable", "server error", "server_error",      "internal error",
        "internal_error",      "network",      "connection",        "timeout",
        "timed out",           "terminated",
    };
    for (needles) |needle| {
        if (contains(text, needle)) return true;
    }
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "retryable and overflow classification" {
    try std.testing.expect(isRetryableAssistantErrorText("Rate Limit exceeded"));
    try std.testing.expect(isRetryableAssistantErrorText("connection reset"));
    try std.testing.expect(!isRetryableAssistantErrorText("invalid api key"));
    try std.testing.expect(ai.isContextOverflowText("Your input exceeds the context window of this model"));
    try std.testing.expect(ai.isContextOverflowText("prompt is too long: 213462 tokens > 200000 maximum"));
    try std.testing.expect(ai.isContextOverflowText("This endpoint's maximum context length is 100 tokens"));
    try std.testing.expect(ai.isContextOverflowText("token limit exceeded"));
    try std.testing.expect(!ai.isContextOverflowText("rate limit: too many tokens, please wait"));
}
