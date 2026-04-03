const std = @import("std");
const protocol = @import("protocol.zig");

pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = std.json.Array.initCapacity(allocator, arr.items.len) catch return error.OutOfMemory;
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(key, val);
            }
            return .{ .object = new_obj };
        },
    }
}

/// Recursively free all owned memory in a std.json.Value tree.
pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mutable = arr;
            mutable.deinit();
        },
        .object => |obj| {
            var mutable = obj;
            var it = mutable.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            mutable.deinit();
        },
        else => {},
    }
}

pub fn jsonToFloat(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

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
