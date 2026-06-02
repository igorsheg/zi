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
    const text = message.error_message orelse return false;
    if (!asciiContainsIgnoreCase(text, "context")) return false;
    return asciiContainsIgnoreCase(text, "overflow") or
        asciiContainsIgnoreCase(text, "too large") or
        asciiContainsIgnoreCase(text, "maximum") or
        asciiContainsIgnoreCase(text, "length");
}

pub fn isRetryableAssistant(message: ai.AssistantMessage) bool {
    if (message.stop_reason != .error_) return false;
    if (isContextOverflowAssistant(message)) return false;
    const text = message.error_message orelse return false;
    return isRetryableAssistantErrorText(text);
}

pub fn isRetryableAssistantErrorText(text: []const u8) bool {
    return asciiContainsIgnoreCase(text, "overloaded") or
        asciiContainsIgnoreCase(text, "rate limit") or
        asciiContainsIgnoreCase(text, "too many requests") or
        asciiContainsIgnoreCase(text, "429") or
        asciiContainsIgnoreCase(text, "500") or
        asciiContainsIgnoreCase(text, "502") or
        asciiContainsIgnoreCase(text, "503") or
        asciiContainsIgnoreCase(text, "504") or
        asciiContainsIgnoreCase(text, "service unavailable") or
        asciiContainsIgnoreCase(text, "server error") or
        asciiContainsIgnoreCase(text, "server_error") or
        asciiContainsIgnoreCase(text, "internal error") or
        asciiContainsIgnoreCase(text, "internal_error") or
        asciiContainsIgnoreCase(text, "network") or
        asciiContainsIgnoreCase(text, "connection") or
        asciiContainsIgnoreCase(text, "timeout") or
        asciiContainsIgnoreCase(text, "timed out") or
        asciiContainsIgnoreCase(text, "terminated");
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var index: usize = 0;
        while (index < needle.len) : (index += 1) {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(needle[index])) break;
        } else return true;
    }
    return false;
}
