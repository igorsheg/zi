const std = @import("std");
const ai = @import("../ai/root.zig");
const auth_mod = @import("auth.zig");

pub const ModelRegistry = struct {
    auth_manager: *const auth_mod.AuthManager,

    pub fn init(auth_manager: *const auth_mod.AuthManager) ModelRegistry {
        return .{ .auth_manager = auth_manager };
    }

    pub fn find(_: *const ModelRegistry, provider: ai.Provider, model_id: []const u8) ?ai.Model {
        return ai.getModel(provider, model_id);
    }

    pub fn hasConfiguredAuth(self: *const ModelRegistry, model: ai.Model) bool {
        return self.auth_manager.hasAuth(model.provider);
    }

    pub fn findAvailable(self: *const ModelRegistry, provider: ai.Provider, model_id: []const u8) ?ai.Model {
        const model = self.find(provider, model_id) orelse return null;
        return if (self.hasConfiguredAuth(model)) model else null;
    }

    pub fn firstAvailable(self: *const ModelRegistry) ?ai.Model {
        for (ai.getProviders()) |provider| {
            for (ai.getModels(provider)) |model| {
                if (self.hasConfiguredAuth(model)) return model;
            }
        }
        return null;
    }
};

test "model registry finds model only when auth is configured" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    const auth = auth_mod.AuthManager.init(.{ .environ = &environ });
    const registry = ModelRegistry.init(&auth);

    try std.testing.expect(registry.findAvailable(ai.KnownProvider.openai, "gpt-5.1") != null);
    try std.testing.expect(registry.findAvailable(ai.KnownProvider.openai_codex, "gpt-5.1-codex-max") == null);
}

test "model registry exposes first available authed model" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    const auth = auth_mod.AuthManager.init(.{ .environ = &environ });
    const registry = ModelRegistry.init(&auth);

    try std.testing.expect(registry.firstAvailable() != null);
}

test "model registry considers every known provider for first available model" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ANTHROPIC_API_KEY", "secret");

    const auth = auth_mod.AuthManager.init(.{ .environ = &environ });
    const registry = ModelRegistry.init(&auth);
    const model = registry.firstAvailable().?;

    try std.testing.expectEqualStrings(ai.KnownProvider.anthropic, model.provider);
}
