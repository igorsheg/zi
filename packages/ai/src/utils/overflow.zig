const std = @import("std");
const types = @import("../types.zig");

/// Patterns that indicate context overflow errors from different providers.
/// These are matched case-insensitively against error messages.
const OVERFLOW_PATTERNS = &[_][]const u8{
    "prompt is too long", // Anthropic
    "input is too long for requested model", // Amazon Bedrock
    "exceeds the context window", // OpenAI
    "input token count", // Google - "exceeds the maximum" part checked separately
    "maximum prompt length is", // xAI
    "reduce the length of the messages", // Groq
    "maximum context length is", // OpenRouter
    "exceeds the limit of", // GitHub Copilot
    "exceeds the available context size", // llama.cpp
    "greater than the context length", // LM Studio
    "context window exceeds limit", // MiniMax
    "exceeded model token limit", // Kimi For Coding
    "too large for model with", // Mistral - "maximum context length" part checked separately
    "model_context_window_exceeded", // z.ai
    "prompt too long", // Ollama
    "context length exceeded", // Generic
    "context_length_exceeded", // Generic snake_case
    "too many tokens", // Generic
    "token limit exceeded", // Generic
    "400", // Cerebras status code indicator
    "413", // Cerebras status code indicator
};

/// Patterns that indicate NON-overflow errors (rate limiting, throttling).
/// These take precedence - if matched, the error is NOT considered overflow.
const NON_OVERFLOW_PATTERNS = &[_][]const u8{
    "throttling error",
    "service unavailable",
    "rate limit",
    "too many requests",
};

/// Check if a text contains any of the given substrings (case-insensitive).
fn containsAnyCaseInsensitive(text: []const u8, patterns: []const []const u8) bool {
    var text_lower_buf: [4096]u8 = undefined;
    if (text.len > text_lower_buf.len) return false; // Too long to check
    
    // Convert text to lowercase
    for (text, 0..) |c, i| {
        text_lower_buf[i] = std.ascii.toLower(c);
    }
    const text_lower = text_lower_buf[0..text.len];
    
    for (patterns) |pattern| {
        var pattern_lower_buf: [128]u8 = undefined;
        if (pattern.len > pattern_lower_buf.len) continue;
        
        for (pattern, 0..) |c, i| {
            pattern_lower_buf[i] = std.ascii.toLower(c);
        }
        const pattern_lower = pattern_lower_buf[0..pattern.len];
        
        if (std.mem.indexOf(u8, text_lower, pattern_lower) != null) {
            return true;
        }
    }
    return false;
}

/// Check if an assistant message represents a context overflow error.
///
/// Handles two cases:
/// 1. Error-based overflow: stopReason "error" with specific error message pattern
/// 2. Silent overflow: stopReason "stop" but usage.input exceeds context window (z.ai style)
pub fn isContextOverflow(message: types.AssistantMessage, context_window: ?u64) bool {
    // Case 1: Check error message patterns
    if (message.stop_reason == .@"error") {
        if (message.error_message) |error_msg| {
            // First check non-overflow patterns (rate limiting, etc.)
            if (!containsAnyCaseInsensitive(error_msg, NON_OVERFLOW_PATTERNS)) {
                // Then check overflow patterns
                if (containsAnyCaseInsensitive(error_msg, OVERFLOW_PATTERNS)) {
                    return true;
                }
            }
        }
    }

    // Case 2: Silent overflow (z.ai style) - successful but usage exceeds context
    if (context_window) |cw| {
        if (message.stop_reason == .stop) {
            const input_tokens = message.usage.input + message.usage.cache_read;
            if (input_tokens > cw) {
                return true;
            }
        }
    }

    return false;
}

/// Get the overflow patterns for testing purposes.
pub fn getOverflowPatterns() []const []const u8 {
    return OVERFLOW_PATTERNS;
}

/// Get the non-overflow patterns for testing purposes.
pub fn getNonOverflowPatterns() []const []const u8 {
    return NON_OVERFLOW_PATTERNS;
}
