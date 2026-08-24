const std = @import("std");

/// Provider wire dialect. Names and paths are static and do not require ownership.
pub const Wire = enum {
    openai_chat,
    openai_responses,
    anthropic_messages,

    /// Resolves hax's canonical dialect names and its two documented short aliases.
    pub fn parse(value: []const u8) ?Wire {
        if (std.ascii.eqlIgnoreCase(value, "openai-completions") or
            std.ascii.eqlIgnoreCase(value, "chat"))
        {
            return .openai_chat;
        }
        if (std.ascii.eqlIgnoreCase(value, "openai-responses") or
            std.ascii.eqlIgnoreCase(value, "responses"))
        {
            return .openai_responses;
        }
        if (std.ascii.eqlIgnoreCase(value, "anthropic-messages")) {
            return .anthropic_messages;
        }
        return null;
    }

    pub fn canonical(self: Wire) []const u8 {
        return switch (self) {
            .openai_chat => "openai-completions",
            .openai_responses => "openai-responses",
            .anthropic_messages => "anthropic-messages",
        };
    }

    pub fn path(self: Wire) []const u8 {
        return switch (self) {
            .openai_chat => "/chat/completions",
            .openai_responses => "/responses",
            .anthropic_messages => "/messages",
        };
    }
};

test "wire identity and request paths match hax" {
    const cases = [_]struct {
        wire: Wire,
        canonical: []const u8,
        path: []const u8,
    }{
        .{ .wire = .openai_chat, .canonical = "openai-completions", .path = "/chat/completions" },
        .{ .wire = .openai_responses, .canonical = "openai-responses", .path = "/responses" },
        .{ .wire = .anthropic_messages, .canonical = "anthropic-messages", .path = "/messages" },
    };

    for (cases) |case| {
        try std.testing.expectEqualStrings(case.canonical, case.wire.canonical());
        try std.testing.expectEqualStrings(case.path, case.wire.path());
        try std.testing.expectEqual(case.wire, Wire.parse(case.canonical).?);
    }
}

test "wire parse is case insensitive and accepts only hax aliases" {
    try std.testing.expectEqual(Wire.openai_chat, Wire.parse("OPENAI-COMPLETIONS").?);
    try std.testing.expectEqual(Wire.openai_chat, Wire.parse("Chat").?);
    try std.testing.expectEqual(Wire.openai_responses, Wire.parse("OpenAI-Responses").?);
    try std.testing.expectEqual(Wire.openai_responses, Wire.parse("Responses").?);
    try std.testing.expectEqual(Wire.anthropic_messages, Wire.parse("ANTHROPIC-MESSAGES").?);

    for ([_][]const u8{
        "",
        "messages",
        "anthropic",
        "completions",
        "openai-chat",
        " openai-responses",
        "openai-responses ",
        "grpc",
    }) |unknown| try std.testing.expect(Wire.parse(unknown) == null);
}
