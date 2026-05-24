const std = @import("std");
const protocol = @import("protocol.zig");

pub const EnvApiKey = struct {
    name: []const u8,
    value: []const u8,
};

pub fn getApiKeyEnvVars(provider: protocol.Provider) ?[]const []const u8 {
    if (std.mem.eql(u8, provider, protocol.KnownProvider.anthropic)) {
        return &.{ "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY" };
    }

    if (std.mem.eql(u8, provider, protocol.KnownProvider.openai)) {
        return &.{"OPENAI_API_KEY"};
    }

    if (std.mem.eql(u8, provider, protocol.KnownProvider.openrouter)) {
        return &.{"OPENROUTER_API_KEY"};
    }

    if (std.mem.eql(u8, provider, protocol.KnownProvider.fireworks)) {
        return &.{"FIREWORKS_API_KEY"};
    }

    return null;
}

pub fn findEnvKey(environ: *const std.process.Environ.Map, provider: protocol.Provider) ?[]const u8 {
    const env_vars = getApiKeyEnvVars(provider) orelse return null;
    for (env_vars) |env_var| {
        const value = environ.get(env_var) orelse continue;
        if (value.len > 0) return env_var;
    }
    return null;
}

pub fn getEnvApiKey(environ: *const std.process.Environ.Map, provider: protocol.Provider) ?EnvApiKey {
    const env_vars = getApiKeyEnvVars(provider) orelse return null;
    for (env_vars) |env_var| {
        const value = environ.get(env_var) orelse continue;
        if (value.len > 0) return .{ .name = env_var, .value = value };
    }
    return null;
}

test "anthropic oauth token takes precedence over api key" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ANTHROPIC_API_KEY", "api-key");
    try environ.put("ANTHROPIC_OAUTH_TOKEN", "oauth-token");

    const found = getEnvApiKey(&environ, protocol.KnownProvider.anthropic).?;

    try std.testing.expectEqualStrings("ANTHROPIC_OAUTH_TOKEN", found.name);
    try std.testing.expectEqualStrings("oauth-token", found.value);
}

test "find env key reports configured key name without exposing value" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    const found = findEnvKey(&environ, protocol.KnownProvider.openai).?;

    try std.testing.expectEqualStrings("OPENAI_API_KEY", found);
}

test "empty env values are treated as missing" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENROUTER_API_KEY", "");

    try std.testing.expectEqual(@as(?EnvApiKey, null), getEnvApiKey(&environ, protocol.KnownProvider.openrouter));
    try std.testing.expectEqual(@as(?[]const u8, null), findEnvKey(&environ, protocol.KnownProvider.openrouter));
}

test "unsupported providers have no api key env vars" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expectEqual(@as(?[]const []const u8, null), getApiKeyEnvVars(protocol.KnownProvider.openai_codex));
    try std.testing.expectEqual(@as(?EnvApiKey, null), getEnvApiKey(&environ, protocol.KnownProvider.openai_codex));
}
