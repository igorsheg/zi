const std = @import("std");
const ai = @import("../ai/root.zig");
const schema = @import("schema.zig");

pub const Diagnostic = union(enum) {
    unknown_api: Field,
    unknown_provider: Field,
    missing_base_url: MissingBaseUrl,

    pub const Field = struct {
        model_id: []const u8,
        value: []const u8,
    };

    pub const MissingBaseUrl = struct {
        model_id: []const u8,
        provider: []const u8,
    };
};

pub const ModelResult = union(enum) {
    ok: ai.protocol.Model,
    err: Diagnostic,
};

pub fn modelToProtocol(model: schema.Model) ModelResult {
    const api = parseKnownApi(model.api) orelse return .{ .err = .{ .unknown_api = .{
        .model_id = model.id,
        .value = model.api,
    } } };
    const provider = parseKnownProvider(model.provider) orelse return .{ .err = .{ .unknown_provider = .{
        .model_id = model.id,
        .value = model.provider,
    } } };
    const base_url = model.base_url orelse ai.models.defaultBaseUrlForProvider(provider) orelse return .{ .err = .{ .missing_base_url = .{
        .model_id = model.id,
        .provider = model.provider,
    } } };

    return .{ .ok = .{
        .id = model.id,
        .provider_model = model.provider_model,
        .name = model.name orelse model.id,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = model.context_window orelse 0,
        .max_tokens = model.max_tokens orelse 0,
    } };
}

fn parseKnownApi(value: []const u8) ?ai.protocol.Api {
    const parsed = ai.protocol.parseApi(value);
    return switch (parsed) {
        .custom => null,
        else => parsed,
    };
}

fn parseKnownProvider(value: []const u8) ?ai.protocol.Provider {
    const parsed = ai.protocol.parseProvider(value);
    return switch (parsed) {
        .custom => null,
        else => parsed,
    };
}

test "settings model resolves user id separately from provider request model" {
    const model = modelToProtocol(.{
        .id = "openrouter/sonnet",
        .name = "Sonnet via OpenRouter",
        .api = "openai-completions",
        .provider = "openrouter",
        .provider_model = "anthropic/claude-sonnet-4",
    }).ok;

    try std.testing.expectEqualStrings("openrouter/sonnet", model.id);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", model.requestModel());
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", model.base_url);
}

test "settings model rejects unknown api" {
    const result = modelToProtocol(.{ .id = "bad", .api = "typo", .provider = "openrouter" });
    try std.testing.expect(result == .err);
    try std.testing.expect(result.err == .unknown_api);
    try std.testing.expectEqualStrings("bad", result.err.unknown_api.model_id);
    try std.testing.expectEqualStrings("typo", result.err.unknown_api.value);
}

test "settings model rejects unknown provider" {
    const result = modelToProtocol(.{ .id = "bad", .api = "openai-completions", .provider = "typo" });
    try std.testing.expect(result == .err);
    try std.testing.expect(result.err == .unknown_provider);
    try std.testing.expectEqualStrings("bad", result.err.unknown_provider.model_id);
    try std.testing.expectEqualStrings("typo", result.err.unknown_provider.value);
}
