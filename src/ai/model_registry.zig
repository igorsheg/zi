//! Session-owned, read-only snapshot of the model catalog.
//!
//! Phase 2: built at session init from `models_generated.models` plus
//! any caller-supplied custom models. Holds a borrowed `*AuthStorage`
//! for the synchronous `hasConfiguredAuth`/`getAvailable` queries.
//! Immutable for the session lifetime — no register/remove API.
//!
//! pi-mono source: packages/coding-agent/src/core/model-registry.ts
//!
//! Threading: agent-owned. The TUI binds a borrowed `[]const Model`
//! slice via `getAll()` at init and calls `auth_storage.hasAuth()`
//! directly for availability checks — the sanctioned cross-thread
//! read per the threading doctrine.

const std = @import("std");
const protocol = @import("protocol.zig");
const generated = @import("models_generated.zig");
const json_util = @import("json_util.zig");
const auth_storage_mod = @import("../auth/storage.zig");

pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    /// Merged catalog: built-ins first, then custom_models. Stable for
    /// the session lifetime; never reordered.
    models: []const protocol.Model,
    /// Backing storage for custom models. Empty in phase 2 — phase 5
    /// wires settings.custom_models here. Freed on deinit.
    custom_backing: []protocol.Model,
    auth: *auth_storage_mod.AuthStorage,

    /// Build a merged catalog. `custom_models` is borrowed only for
    /// the duration of this call; entries are copied into an owned
    /// backing slice. Pass `&.{}` for phase 2.
    pub fn init(
        allocator: std.mem.Allocator,
        auth: *auth_storage_mod.AuthStorage,
        custom_models: []const protocol.Model,
    ) !ModelRegistry {
        const total = generated.models.len + custom_models.len;
        const merged = try allocator.alloc(protocol.Model, total);
        @memcpy(merged[0..generated.models.len], &generated.models);
        if (custom_models.len > 0) {
            @memcpy(merged[generated.models.len..], custom_models);
        }
        return .{
            .allocator = allocator,
            .models = merged,
            .custom_backing = merged,
            .auth = auth,
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        self.allocator.free(self.custom_backing);
        self.models = &.{};
        self.custom_backing = &.{};
    }

    /// Stable slice valid for the session lifetime. Caller must not
    /// mutate.
    pub fn getAll(self: *const ModelRegistry) []const protocol.Model {
        return self.models;
    }

    /// Exact `(provider, id)` match. Byte-exact on id.
    pub fn find(
        self: *const ModelRegistry,
        provider: protocol.Provider,
        id: []const u8,
    ) ?protocol.Model {
        for (self.models) |m| {
            if (std.meta.eql(m.provider, provider) and std.mem.eql(u8, m.id, id)) {
                return m;
            }
        }
        return null;
    }

    /// Synchronous hasAuth check. Unlike pi-mono's async counterpart,
    /// zi's AuthStorage is lock-protected and sync-friendly.
    pub fn hasConfiguredAuth(self: *const ModelRegistry, model: protocol.Model) bool {
        const provider_str = json_util.providerToString(model.provider);
        return self.auth.hasAuth(provider_str);
    }

    /// Caller-owned slice of models whose provider has configured
    /// auth. Sync — no oauth refresh side effects.
    pub fn getAvailable(
        self: *const ModelRegistry,
        allocator: std.mem.Allocator,
    ) ![]protocol.Model {
        var list: std.ArrayListUnmanaged(protocol.Model) = .empty;
        errdefer list.deinit(allocator);
        for (self.models) |m| {
            if (self.hasConfiguredAuth(m)) try list.append(allocator, m);
        }
        return list.toOwnedSlice(allocator);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "registry returns all built-in models when custom is empty" {
    const alloc = std.testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    try std.testing.expectEqual(generated.models.len, reg.getAll().len);
    try std.testing.expectEqualStrings(generated.models[0].id, reg.getAll()[0].id);
}

test "find by provider+id matches anthropic claude-opus-4-6" {
    const alloc = std.testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    const m = reg.find(.anthropic, "claude-opus-4-6") orelse
        return error.MissingCatalogEntry;
    try std.testing.expectEqualStrings("claude-opus-4-6", m.id);
    try std.testing.expect(std.meta.eql(m.provider, protocol.Provider.anthropic));
}

test "hasConfiguredAuth delegates to AuthStorage.hasAuth" {
    const alloc = std.testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.create(alloc, null);
    defer auth.deinit();
    // Seed a runtime api key so hasAuth("anthropic") returns true
    // without touching disk.
    auth.setRuntimeApiKey("anthropic", "test-key");

    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    const m = reg.find(.anthropic, "claude-opus-4-6") orelse
        return error.MissingCatalogEntry;
    try std.testing.expect(reg.hasConfiguredAuth(m));
}
