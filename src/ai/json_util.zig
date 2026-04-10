//! AI-protocol-specific enum↔string converters. Generic JSON
//! helpers (clone/free/typed accessors) were moved to
//! `src/json/value.zig`; this file re-exports them so legacy call
//! sites keep working while the migration settles.
const std = @import("std");
const protocol = @import("protocol.zig");
const json_value = @import("../json/value.zig");

// Re-exports of generic helpers — callers should prefer importing
// from `src/json/value.zig` directly in new code.
pub const cloneJsonValue = json_value.cloneJsonValue;
pub const freeJsonValue = json_value.freeJsonValue;
pub const jsonToFloat = json_value.jsonToFloat;

pub fn providerToString(p: protocol.Provider) []const u8 {
    return switch (p) {
        .amazon_bedrock => "amazon-bedrock",
        .anthropic => "anthropic",
        .google => "google",
        .google_gemini_cli => "google-gemini-cli",
        .google_antigravity => "google-antigravity",
        .google_vertex => "google-vertex",
        .openai => "openai",
        .azure_openai_responses => "azure-openai-responses",
        .openai_codex => "openai-codex",
        .github_copilot => "github-copilot",
        .xai => "xai",
        .groq => "groq",
        .cerebras => "cerebras",
        .openrouter => "openrouter",
        .vercel_ai_gateway => "vercel-ai-gateway",
        .zai => "zai",
        .mistral => "mistral",
        .minimax => "minimax",
        .minimax_cn => "minimax-cn",
        .huggingface => "huggingface",
        .opencode => "opencode",
        .opencode_go => "opencode-go",
        .kimi_coding => "kimi-coding",
        .custom => |s| s,
    };
}

pub fn parseProvider(s: []const u8) protocol.Provider {
    const map = .{
        .{ "amazon-bedrock", protocol.Provider.amazon_bedrock },
        .{ "anthropic", protocol.Provider.anthropic },
        .{ "google", protocol.Provider.google },
        .{ "google-gemini-cli", protocol.Provider.google_gemini_cli },
        .{ "google-antigravity", protocol.Provider.google_antigravity },
        .{ "google-vertex", protocol.Provider.google_vertex },
        .{ "openai", protocol.Provider.openai },
        .{ "azure-openai-responses", protocol.Provider.azure_openai_responses },
        .{ "openai-codex", protocol.Provider.openai_codex },
        .{ "github-copilot", protocol.Provider.github_copilot },
        .{ "xai", protocol.Provider.xai },
        .{ "groq", protocol.Provider.groq },
        .{ "cerebras", protocol.Provider.cerebras },
        .{ "openrouter", protocol.Provider.openrouter },
        .{ "vercel-ai-gateway", protocol.Provider.vercel_ai_gateway },
        .{ "zai", protocol.Provider.zai },
        .{ "mistral", protocol.Provider.mistral },
        .{ "minimax", protocol.Provider.minimax },
        .{ "minimax-cn", protocol.Provider.minimax_cn },
        .{ "huggingface", protocol.Provider.huggingface },
        .{ "opencode", protocol.Provider.opencode },
        .{ "opencode-go", protocol.Provider.opencode_go },
        .{ "kimi-coding", protocol.Provider.kimi_coding },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return .{ .custom = s };
}

pub fn parseApi(s: []const u8) protocol.Api {
    const map = .{
        .{ "openai-completions", protocol.Api.openai_completions },
        .{ "mistral-conversations", protocol.Api.mistral_conversations },
        .{ "openai-responses", protocol.Api.openai_responses },
        .{ "azure-openai-responses", protocol.Api.azure_openai_responses },
        .{ "openai-codex-responses", protocol.Api.openai_codex_responses },
        .{ "anthropic-messages", protocol.Api.anthropic_messages },
        .{ "bedrock-converse-stream", protocol.Api.bedrock_converse_stream },
        .{ "google-generative-ai", protocol.Api.google_generative_ai },
        .{ "google-gemini-cli", protocol.Api.google_gemini_cli },
        .{ "google-vertex", protocol.Api.google_vertex },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return .{ .custom = s };
}

pub fn stopReasonToString(r: protocol.StopReason) []const u8 {
    return switch (r) {
        .stop => "stop",
        .length => "length",
        .toolUse => "toolUse",
        .@"error" => "error",
        .aborted => "aborted",
    };
}

pub fn utf8LossyAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return allocator.dupe(u8, bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        if (i + len > bytes.len) {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            break;
        }
        _ = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        try out.appendSlice(allocator, bytes[i .. i + len]);
        i += len;
    }

    return out.toOwnedSlice(allocator);
}

pub fn parseStopReason(s: []const u8) protocol.StopReason {
    if (std.mem.eql(u8, s, "stop")) return .stop;
    if (std.mem.eql(u8, s, "length")) return .length;
    if (std.mem.eql(u8, s, "toolUse")) return .toolUse;
    if (std.mem.eql(u8, s, "error")) return .@"error";
    if (std.mem.eql(u8, s, "aborted")) return .aborted;
    return .@"error";
}

const provider_mod = @import("provider.zig");

test "providerToString round-trip" {
    const cases = .{
        .{ protocol.Provider.amazon_bedrock, "amazon-bedrock" },
        .{ protocol.Provider.anthropic, "anthropic" },
        .{ protocol.Provider.google, "google" },
        .{ protocol.Provider.openai, "openai" },
        .{ protocol.Provider.xai, "xai" },
        .{ protocol.Provider.mistral, "mistral" },
        .{ protocol.Provider.kimi_coding, "kimi-coding" },
    };
    inline for (cases) |c| {
        const s = providerToString(c[0]);
        try std.testing.expectEqualStrings(c[1], s);
        const p = parseProvider(s);
        try std.testing.expectEqual(c[0], p);
    }
}

test "parseApi round-trip" {
    const cases = .{
        .{ protocol.Api.openai_completions, "openai-completions" },
        .{ protocol.Api.anthropic_messages, "anthropic-messages" },
        .{ protocol.Api.google_generative_ai, "google-generative-ai" },
        .{ protocol.Api.google_vertex, "google-vertex" },
    };
    inline for (cases) |c| {
        const s = provider_mod.apiToString(c[0]);
        try std.testing.expectEqualStrings(c[1], s);
        const a = parseApi(s);
        try std.testing.expectEqual(c[0], a);
    }
}

test "utf8LossyAlloc preserves valid utf-8 and replaces invalid bytes" {
    const allocator = std.testing.allocator;

    const valid = try utf8LossyAlloc(allocator, "hello é");
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("hello é", valid);

    const invalid = try utf8LossyAlloc(allocator, "bad\xaa\xfftail");
    defer allocator.free(invalid);
    try std.testing.expectEqualStrings("bad��tail", invalid);
}

test "utf8LossyAlloc replaces truncated trailing sequence" {
    const allocator = std.testing.allocator;
    const invalid = try utf8LossyAlloc(allocator, "x\xE2");
    defer allocator.free(invalid);
    try std.testing.expectEqualStrings("x�", invalid);
}
