const std = @import("std");
const ai = @import("../ai/root.zig");
const ai_catalog = @import("../ai/model_catalog.zig");
const ai_model = @import("../ai/model.zig");
const snapshot = @import("../ai/model_catalog_snapshot.zig");

const ModelConfig = @This();
const max_providers = 32;

pub const Error = error{
    InvalidProviderDefinition,
    DuplicateProvider,
    ProviderHasNoModels,
    InvalidModelCatalog,
};

pub const ProviderDefinition = ai.provider.Definition;

catalog: ai_catalog.Catalog,
providers: []const ProviderDefinition,

pub fn init(catalog: ai_catalog.Catalog, providers: []const ProviderDefinition) Error!ModelConfig {
    const config: ModelConfig = .{ .catalog = catalog, .providers = providers };
    try config.validate();
    return config;
}

pub fn validate(self: ModelConfig) Error!void {
    self.catalog.validate() catch return error.InvalidModelCatalog;
    if (self.providers.len > max_providers) return error.InvalidProviderDefinition;
    for (self.providers, 0..) |provider, index| {
        if (provider.id.len == 0 or provider.name.len == 0 or provider.base_url.len == 0) {
            return error.InvalidProviderDefinition;
        }
        const has_auth = provider.auth.api_key != null or provider.auth.oauth != null or
            provider.auth.allow_unauthenticated;
        if (!has_auth) return error.InvalidProviderDefinition;
        for (self.providers[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, provider.id)) return error.DuplicateProvider;
        }
        var has_model = false;
        for (self.catalog.entries) |entry| {
            if (std.mem.eql(u8, entry.identity.provider, provider.id)) {
                has_model = true;
                break;
            }
        }
        if (!has_model) return error.ProviderHasNoModels;
    }
}

pub fn findProvider(self: ModelConfig, provider_id: []const u8) ?*const ProviderDefinition {
    for (self.providers) |*definition| {
        if (std.mem.eql(u8, definition.id, provider_id)) return definition;
    }
    return null;
}

pub fn resolve(self: ModelConfig, selection: ai_model.ModelIdentity) ?ai_catalog.Resolved {
    _ = self.findProvider(selection.provider) orelse return null;
    return self.catalog.resolve(selection);
}

pub const builtin: ModelConfig = .{
    .catalog = snapshot.value,
    .providers = &ai.providers.builtin,
};

test "built-in model configuration resolves only defined providers" {
    try builtin.validate();
    const openai = builtin.resolve(.{ .provider = "openai", .model = "gpt-5.6" }).?;
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai.canonicalModelId());
    try std.testing.expect(builtin.resolve(.{ .provider = "missing", .model = "gpt-5.6-sol" }) == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        builtin.findProvider("openai").?.auth.api_key.?.environment_names.len,
    );
}

test "model configuration rejects duplicate and model-less providers" {
    const entries = [_]ai_catalog.Entry{.{
        .identity = .{ .provider = "configured", .model = "model" },
        .protocol_id = "openai-completions",
        .profile = .{},
    }};
    const catalog: ai_catalog.Catalog = .{ .entries = &entries };
    const duplicate = [_]ProviderDefinition{
        .{
            .id = "configured",
            .name = "Configured",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        },
        .{
            .id = "configured",
            .name = "Configured Again",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        },
    };
    try std.testing.expectError(error.DuplicateProvider, init(catalog, &duplicate));

    const missing = [_]ProviderDefinition{.{
        .id = "missing",
        .name = "Missing",
        .base_url = "https://example.test/v1",
        .auth = .{ .allow_unauthenticated = true },
    }};
    try std.testing.expectError(error.ProviderHasNoModels, init(catalog, &missing));

    const invalid = [_]ProviderDefinition{
        .{
            .id = "",
            .name = "Configured",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        },
        .{
            .id = "configured",
            .name = "",
            .base_url = "https://example.test/v1",
            .auth = .{ .allow_unauthenticated = true },
        },
        .{
            .id = "configured",
            .name = "Configured",
            .base_url = "",
            .auth = .{ .allow_unauthenticated = true },
        },
        .{
            .id = "configured",
            .name = "Configured",
            .base_url = "https://example.test/v1",
            .auth = .{},
        },
    };
    for (invalid) |provider_definition| {
        try std.testing.expectError(
            error.InvalidProviderDefinition,
            init(catalog, &.{provider_definition}),
        );
    }
}
