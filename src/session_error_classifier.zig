const std = @import("std");
const ai = @import("ai/root.zig");

pub const FailureClass = enum {
    none,
    aborted,
    overflow,
    retryable_transient,
    fatal,
};

pub const Classification = struct {
    class: FailureClass,
    error_message: ?[]const u8 = null,
};

const overflow_needles = [_][]const u8{
    "prompt is too long",
    "input is too long for requested model",
    "exceeds the context window",
    "input token count",
    "maximum prompt length is",
    "reduce the length of the messages",
    "maximum context length is",
    "exceeds the limit of",
    "exceeds the available context size",
    "greater than the context length",
    "context window exceeds limit",
    "exceeded model token limit",
    "too large for model with",
    "model_context_window_exceeded",
    "prompt too long; exceeded",
    "context length exceeded",
    "context_length_exceeded",
    "too many tokens",
    "token limit exceeded",
    "400 (no body)",
    "413 (no body)",
    "400 status code (no body)",
    "413 status code (no body)",
};

const non_overflow_needles = [_][]const u8{
    "throttling error:",
    "service unavailable:",
    "rate limit",
    "too many requests",
};

const retryable_needles = [_][]const u8{
    "overloaded",
    "provider returned error",
    "throttling error",
    "rate limit",
    "too many requests",
    "429",
    "500",
    "502",
    "503",
    "504",
    "service unavailable",
    "server error",
    "internal error",
    "network error",
    "connection error",
    "connection refused",
    "other side closed",
    "fetch failed",
    "upstream connect",
    "reset before headers",
    "socket hang up",
    "timed out",
    "timeout",
    "terminated",
    "retry delay",
};

pub fn classifyAssistantMessage(
    message: *const ai.protocol.AssistantMessage,
    context_window: ?u64,
) Classification {
    if (message.failure) |failure| {
        return .{
            .class = switch (failure.kind) {
                .aborted => .aborted,
                .context_overflow => .overflow,
                .rate_limited, .transient => .retryable_transient,
                .auth, .invalid_request, .fatal => .fatal,
            },
            .error_message = message.error_message,
        };
    }

    if (message.stop_reason == .aborted) {
        return .{ .class = .aborted, .error_message = message.error_message };
    }

    if (isContextOverflow(message, context_window)) {
        return .{ .class = .overflow, .error_message = message.error_message };
    }

    if (message.stop_reason != .@"error") {
        return .{ .class = .none, .error_message = message.error_message };
    }

    const err = message.error_message orelse return .{ .class = .fatal };
    if (isRetryableError(err)) {
        return .{ .class = .retryable_transient, .error_message = err };
    }

    return .{ .class = .fatal, .error_message = err };
}

pub fn isContextOverflow(
    message: *const ai.protocol.AssistantMessage,
    context_window: ?u64,
) bool {
    if (message.stop_reason == .@"error") {
        const err = message.error_message orelse return false;
        if (containsAnyCI(err, &non_overflow_needles)) return false;
        return containsAnyCI(err, &overflow_needles);
    }

    if (context_window) |limit| {
        if (limit > 0 and message.stop_reason == .stop) {
            const input_tokens = message.usage.input + message.usage.cache_read;
            return input_tokens > limit;
        }
    }

    return false;
}

pub fn isRetryableError(error_message: []const u8) bool {
    return containsAnyCI(error_message, &retryable_needles);
}

fn containsAnyCI(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsCI(haystack, needle)) return true;
    }
    return false;
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "classifyAssistantMessage marks overflow separately from retryable errors" {
    const msg = ai.protocol.AssistantMessage{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .@"error",
        .error_message = "Your input exceeds the context window of this model",
        .timestamp = 0,
    };

    const classification = classifyAssistantMessage(&msg, 128_000);
    try std.testing.expectEqual(FailureClass.overflow, classification.class);
}

test "classifyAssistantMessage prefers structured normalized failures over string heuristics" {
    const msg = ai.protocol.AssistantMessage{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .@"error",
        .error_message = "weird provider wording that does not mention retrying",
        .failure = .{ .kind = .rate_limited, .http_status = 429 },
        .timestamp = 0,
    };

    const classification = classifyAssistantMessage(&msg, null);
    try std.testing.expectEqual(FailureClass.retryable_transient, classification.class);
}

test "classifyAssistantMessage excludes throttling too many tokens from overflow" {
    const msg = ai.protocol.AssistantMessage{
        .content = &.{},
        .api = .bedrock_converse_stream,
        .provider = .amazon_bedrock,
        .model = "bedrock-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .@"error",
        .error_message = "Throttling error: Too many tokens, please wait before trying again.",
        .timestamp = 0,
    };

    const classification = classifyAssistantMessage(&msg, null);
    try std.testing.expectEqual(FailureClass.retryable_transient, classification.class);
}

test "isContextOverflow detects silent overflow from usage" {
    const msg = ai.protocol.AssistantMessage{
        .content = &.{},
        .api = .{ .custom = "zai" },
        .provider = .zai,
        .model = "zai-test",
        .usage = .{ .input = 210_000, .output = 12, .cache_read = 1_000, .cache_write = 0, .total_tokens = 211_012, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try std.testing.expect(isContextOverflow(&msg, 200_000));
}
