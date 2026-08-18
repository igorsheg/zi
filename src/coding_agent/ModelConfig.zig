const std = @import("std");
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

pub const ProviderDefinition = union(enum) {
    openai_completions: OpenAi,
    openai_responses: OpenAi,
    openai_codex_responses: OpenAiCodex,

    pub const OpenAi = struct {
        id: []const u8,
        name: []const u8,
        base_url: []const u8,
        authentication: Authentication,

        pub const Authentication = enum {
            none,
            api_key,
        };
    };

    pub const OpenAiCodex = struct {
        id: []const u8,
        name: []const u8,
        base_url: []const u8,
    };

    pub fn id(self: ProviderDefinition) []const u8 {
        return switch (self) {
            .openai_completions => |provider| provider.id,
            .openai_responses => |provider| provider.id,
            .openai_codex_responses => |provider| provider.id,
        };
    }
};

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
        switch (provider) {
            .openai_completions, .openai_responses => |definition| {
                if (definition.id.len == 0 or definition.name.len == 0 or definition.base_url.len == 0) {
                    return error.InvalidProviderDefinition;
                }
            },
            .openai_codex_responses => |definition| {
                if (!std.mem.eql(u8, definition.id, "openai-codex") or
                    definition.name.len == 0 or definition.base_url.len == 0)
                {
                    return error.InvalidProviderDefinition;
                }
            },
        }
        for (self.providers[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id(), provider.id())) return error.DuplicateProvider;
        }
        var has_model = false;
        for (self.catalog.entries) |entry| {
            if (std.mem.eql(u8, entry.identity.provider, provider.id())) {
                has_model = true;
                break;
            }
        }
        if (!has_model) return error.ProviderHasNoModels;
    }
}

pub fn findProvider(self: ModelConfig, provider_id: []const u8) ?*const ProviderDefinition {
    for (self.providers) |*definition| {
        if (std.mem.eql(u8, definition.id(), provider_id)) return definition;
    }
    return null;
}

pub fn resolve(self: ModelConfig, selection: ai_model.ModelIdentity) ?ai_catalog.Resolved {
    _ = self.findProvider(selection.provider) orelse return null;
    return self.catalog.resolve(selection);
}

pub const builtin_providers = [_]ProviderDefinition{
    .{ .openai_responses = .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .authentication = .api_key,
    } },
    .{ .openai_codex_responses = .{
        .id = "openai-codex",
        .name = "OpenAI Codex",
        .base_url = "https://chatgpt.com/backend-api",
    } },
};

pub const builtin: ModelConfig = .{
    .catalog = snapshot.value,
    .providers = &builtin_providers,
};

test "built-in model configuration resolves only defined providers" {
    try builtin.validate();
    const openai = builtin.resolve(.{ .provider = "openai", .model = "gpt-5.6" }).?;
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai.canonicalModelId());
    try std.testing.expect(builtin.resolve(.{ .provider = "missing", .model = "gpt-5.6-sol" }) == null);
    try std.testing.expectEqual(
        ProviderDefinition.OpenAi.Authentication.api_key,
        builtin.findProvider("openai").?.openai_responses.authentication,
    );
}

test "model configuration rejects duplicate and model-less providers" {
    const entries = [_]ai_catalog.Entry{.{
        .identity = .{ .provider = "configured", .model = "model" },
        .profile = .{},
    }};
    const catalog: ai_catalog.Catalog = .{ .entries = &entries };
    const duplicate = [_]ProviderDefinition{
        .{ .openai_completions = .{
            .id = "configured",
            .name = "Configured",
            .base_url = "https://example.test/v1",
            .authentication = .none,
        } },
        .{ .openai_responses = .{
            .id = "configured",
            .name = "Configured Again",
            .base_url = "https://example.test/v1",
            .authentication = .none,
        } },
    };
    try std.testing.expectError(error.DuplicateProvider, init(catalog, &duplicate));

    const missing = [_]ProviderDefinition{.{ .openai_completions = .{
        .id = "missing",
        .name = "Missing",
        .base_url = "https://example.test/v1",
        .authentication = .none,
    } }};
    try std.testing.expectError(error.ProviderHasNoModels, init(catalog, &missing));

    const invalid = [_]ProviderDefinition{
        .{ .openai_completions = .{
            .id = "",
            .name = "Configured",
            .base_url = "https://example.test/v1",
            .authentication = .none,
        } },
        .{ .openai_completions = .{
            .id = "configured",
            .name = "",
            .base_url = "https://example.test/v1",
            .authentication = .none,
        } },
        .{ .openai_completions = .{
            .id = "configured",
            .name = "Configured",
            .base_url = "",
            .authentication = .none,
        } },
        .{ .openai_codex_responses = .{
            .id = "custom-codex",
            .name = "Codex",
            .base_url = "https://example.test",
        } },
    };
    for (invalid) |provider_definition| {
        try std.testing.expectError(
            error.InvalidProviderDefinition,
            init(catalog, &.{provider_definition}),
        );
    }
}
