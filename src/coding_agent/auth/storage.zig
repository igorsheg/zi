const std = @import("std");
const ai = @import("../../ai/root.zig");
const shared_storage = @import("../../storage.zig");
const json_write = @import("../../json/write.zig");
const types = @import("types.zig");
const file_backend = @import("file_backend.zig");
const resolve_config_value = @import("resolve_config_value.zig");
const oauth_mod = @import("oauth.zig");

const log = std.log.scoped(.auth_storage);

/// Credential store: memory mutex + backend file lock.
pub const AuthStorage = struct {
    pub const ExtensionOAuthRefreshHook = struct {
        func: *const fn (
            provider: []const u8,
            credential: types.OAuthCredential,
            allocator: std.mem.Allocator,
            ctx: ?*anyopaque,
        ) oauth_mod.ExchangeResult,
        ctx: ?*anyopaque = null,
    };

    data: types.AuthStorageData,
    backend: file_backend.Backend,
    allocator: std.mem.Allocator,
    runtime_overrides: std.StringHashMap([]const u8),
    fallback_resolver: ?*const fn (provider: []const u8) ?[]const u8 = null,
    extension_oauth_refresh_hook: ?ExtensionOAuthRefreshHook = null,
    load_error: bool = false,
    /// Guards in-memory creds across TUI/login/agent threads.
    /// Locked helpers must not relock; std.Io.Mutex is non-recursive.
    mutex: std.Io.Mutex = .init,
    io: std.Io = std.Options.debug_io,

    pub fn create(allocator: std.mem.Allocator, auth_path: ?[]const u8) !AuthStorage {
        return createWithIo(allocator, std.Options.debug_io, auth_path);
    }

    pub fn createWithIo(allocator: std.mem.Allocator, io: std.Io, auth_path: ?[]const u8) !AuthStorage {
        const path = if (auth_path) |p|
            try allocator.dupe(u8, p)
        else
            try file_backend.defaultAuthPath(allocator);
        defer allocator.free(path);

        var self = AuthStorage{
            .data = types.AuthStorageData.init(allocator),
            .backend = .{ .file = try shared_storage.LockedFile.initWithIo(allocator, io, path) },
            .allocator = allocator,
            .runtime_overrides = std.StringHashMap([]const u8).init(allocator),
            .io = io,
        };
        self.reloadLocked();
        return self;
    }

    pub fn inMemory(allocator: std.mem.Allocator, initial_data: ?*const types.AuthStorageData) !AuthStorage {
        var backend: file_backend.Backend = .{ .memory = @import("../../storage.zig").MemoryFile.init(allocator) };

        if (initial_data) |d| {
            const json = try json_write.toOwnedSlice(allocator, d, types.writeAuthJson);
            defer allocator.free(json);
            try backend.writeContent(json);
        }

        var self = AuthStorage{
            .data = types.AuthStorageData.init(allocator),
            .backend = backend,
            .allocator = allocator,
            .runtime_overrides = std.StringHashMap([]const u8).init(allocator),
            .io = std.Options.debug_io,
        };
        self.reloadLocked();
        return self;
    }

    pub fn deinit(self: *AuthStorage) void {
        var ov_it = self.runtime_overrides.iterator();
        while (ov_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.runtime_overrides.deinit();

        types.deinitAuthStorageData(&self.data);

        switch (self.backend) {
            .file => |*f| f.deinit(),
            .memory => |*m| m.deinit(),
        }
    }

    pub fn reload(self: *AuthStorage) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reloadLocked();
    }

    /// Caller holds mutex, or storage is not shared yet.
    fn reloadLocked(self: *AuthStorage) void {
        const content = self.backend.readContent(self.allocator);
        defer if (content) |c| self.allocator.free(c);

        if (content) |c| {
            const new_data = types.parseAuthJson(self.allocator, c) catch {
                self.load_error = true;
                return;
            };
            types.deinitAuthStorageData(&self.data);
            self.data = new_data;
            self.load_error = false;
        } else {
            types.deinitAuthStorageData(&self.data);
            self.data = types.AuthStorageData.init(self.allocator);
            self.load_error = false;
        }
    }

    /// Borrowed slices; dupe before the next mutation/refresh.
    pub fn get(self: *AuthStorage, provider: []const u8) ?types.AuthCredential {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.data.get(provider);
    }

    pub fn set(self: *AuthStorage, provider: []const u8, credential: types.AuthCredential) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const key_duped = self.allocator.dupe(u8, provider) catch return;

        const cred_duped = dupeCredential(self.allocator, credential) catch {
            self.allocator.free(key_duped);
            return;
        };

        if (self.data.fetchPut(key_duped, cred_duped) catch null) |old| {
            freeCredential(self.allocator, old.value);
            self.allocator.free(key_duped);
        }

        self.persistProviderChange(provider, credential);
    }

    pub fn remove(self: *AuthStorage, provider: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.data.fetchRemove(provider)) |old| {
            freeCredential(self.allocator, old.value);
            self.allocator.free(old.key);
        }
        self.persistProviderChange(provider, null);
    }

    pub fn has(self: *AuthStorage, provider: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.data.get(provider) != null;
    }

    pub fn list(self: *AuthStorage, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const count = self.data.count();
        if (count == 0) return &.{};

        const keys = try allocator.alloc([]const u8, count);
        errdefer allocator.free(keys);

        var it = self.data.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            keys[i] = try allocator.dupe(u8, entry.key_ptr.*);
            i += 1;
        }
        return keys;
    }

    /// Borrowed map; only inspect while mutation is impossible.
    pub fn getAll(self: *const AuthStorage) *const types.AuthStorageData {
        return &self.data;
    }

    pub fn setRuntimeApiKey(self: *AuthStorage, provider: []const u8, key: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const key_duped = self.allocator.dupe(u8, provider) catch return;
        const val_duped = self.allocator.dupe(u8, key) catch {
            self.allocator.free(key_duped);
            return;
        };

        if (self.runtime_overrides.fetchPut(key_duped, val_duped) catch null) |old| {
            self.allocator.free(key_duped);
            self.allocator.free(old.value);
        }
    }

    pub fn removeRuntimeApiKey(self: *AuthStorage, provider: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.runtime_overrides.fetchRemove(provider)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    pub fn setFallbackResolver(self: *AuthStorage, resolver: *const fn (provider: []const u8) ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.fallback_resolver = resolver;
    }

    pub fn setExtensionOAuthRefreshHook(self: *AuthStorage, hook: ?ExtensionOAuthRefreshHook) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.extension_oauth_refresh_hook = hook;
    }

    /// Availability check only; no OAuth refresh.
    pub fn hasAuth(self: *AuthStorage, provider: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.runtime_overrides.get(provider) != null) return true;
        if (self.data.get(provider) != null) return true;
        if (ai.env_api_keys.getEnvApiKey(provider) != null) return true;
        if (self.fallback_resolver) |resolver| {
            if (resolver(provider) != null) return true;
        }
        return false;
    }

    /// May refresh OAuth; returned slice is borrowed from storage.
    pub fn getApiKey(self: *AuthStorage, provider: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.runtime_overrides.get(provider)) |key| return key;
        if (self.data.get(provider)) |cred| {
            switch (cred) {
                .api_key => |ak| return resolve_config_value.resolveConfigValue(ak.key),
                .oauth => |oa| {
                    const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
                    if (now_ms < oa.expires) return oa.access;

                    if (self.refreshOAuthLocked(provider)) |refreshed| {
                        return refreshed;
                    }
                },
            }
        }
        if (ai.env_api_keys.getEnvApiKey(provider)) |key| return key;
        if (self.fallback_resolver) |resolver| {
            if (resolver(provider)) |key| return key;
        }

        return null;
    }

    /// Backend lock spans reload → exchange → write; avoids peer refresh races.
    fn refreshOAuthLocked(self: *AuthStorage, provider: []const u8) ?[]const u8 {
        const oauth_provider = oauth_mod.findProvider(provider) orelse {
            log.warn("oauth refresh requested for unknown provider '{s}'", .{provider});
            return null;
        };

        if (self.load_error) return null;
        if (!self.backend.acquireLock()) {
            log.warn("oauth refresh: failed to acquire backend lock for '{s}'", .{provider});
            return null;
        }
        defer self.backend.releaseLock();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const fresh_content = self.backend.readContent(arena_alloc);
        const fresh_data_opt: ?types.AuthStorageData = if (fresh_content) |c|
            (types.parseAuthJson(arena_alloc, c) catch null)
        else
            null;

        var base_cred: types.OAuthCredential = undefined;
        var base_from_disk = false;
        if (fresh_data_opt) |fd| {
            if (fd.get(provider)) |c| switch (c) {
                .oauth => |oa| {
                    base_cred = oa;
                    base_from_disk = true;
                },
                else => {},
            };
        }
        if (!base_from_disk) {
            const c = self.data.get(provider) orelse return null;
            base_cred = switch (c) {
                .oauth => |oa| oa,
                else => return null,
            };
        }

        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        if (base_from_disk and now_ms < base_cred.expires) {
            self.installRefreshedCredential(provider, base_cred) catch return null;
            return switch (self.data.get(provider) orelse return null) {
                .oauth => |oa| oa.access,
                else => null,
            };
        }

        const exchange = if (oauth_provider.kind.usesExtensionRefresh()) blk: {
            const hook = self.extension_oauth_refresh_hook orelse {
                log.warn("oauth refresh requested for extension-owned provider '{s}' without an agent-thread refresh hook", .{provider});
                return null;
            };
            break :blk hook.func(provider, base_cred, self.allocator, hook.ctx);
        } else oauth_provider.refresh_token(self.allocator, base_cred);
        switch (exchange) {
            .err => |msg| {
                log.warn("oauth refresh failed for '{s}': {s}", .{ provider, msg });
                return null;
            },
            .success => |new_cred| {
                defer freeCredential(self.allocator, .{ .oauth = new_cred });
                self.installRefreshedCredential(provider, new_cred) catch return null;
                self.persistInsideLock(arena_alloc) catch |e| {
                    log.warn("oauth refresh persisted in-memory but disk write failed for '{s}': {s}", .{ provider, @errorName(e) });
                };
                return switch (self.data.get(provider) orelse return null) {
                    .oauth => |oa| oa.access,
                    else => null,
                };
            },
        }
    }

    fn installRefreshedCredential(
        self: *AuthStorage,
        provider: []const u8,
        new_cred: types.OAuthCredential,
    ) !void {
        const cloned = try dupeCredential(self.allocator, .{ .oauth = new_cred });
        errdefer freeCredential(self.allocator, cloned);

        const key_dup = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(key_dup);

        if (self.data.fetchPut(key_dup, cloned) catch |e| {
            return e;
        }) |old| {
            freeCredential(self.allocator, old.value);
            self.allocator.free(key_dup);
        }
    }

    /// Caller already holds backend lock.
    fn persistInsideLock(self: *AuthStorage, arena_alloc: std.mem.Allocator) !void {
        const json = try json_write.toOwnedSlice(arena_alloc, &self.data, types.writeAuthJson);
        try self.backend.writeContent(json);
    }

    fn persistProviderChange(self: *AuthStorage, provider: []const u8, credential: ?types.AuthCredential) void {
        if (self.load_error) return;

        if (!self.backend.acquireLock()) return;
        defer self.backend.releaseLock();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const current_content = self.backend.readContent(arena_alloc);
        var current_data = if (current_content) |c|
            types.parseAuthJson(arena_alloc, c) catch return
        else
            types.AuthStorageData.init(arena_alloc);
        if (credential) |cred| {
            const key = arena_alloc.dupe(u8, provider) catch return;
            const duped_cred = dupeCredential(arena_alloc, cred) catch return;
            current_data.put(key, duped_cred) catch return;
        } else {
            _ = current_data.fetchRemove(provider);
        }
        const json = json_write.toOwnedSlice(arena_alloc, &current_data, types.writeAuthJson) catch return;
        self.backend.writeContent(json) catch return;
    }

    fn dupeCredential(allocator: std.mem.Allocator, cred: types.AuthCredential) !types.AuthCredential {
        switch (cred) {
            .api_key => |ak| {
                return .{ .api_key = .{
                    .key = try allocator.dupe(u8, ak.key),
                } };
            },
            .oauth => |oa| {
                const refresh = try allocator.dupe(u8, oa.refresh);
                errdefer allocator.free(refresh);
                const access = try allocator.dupe(u8, oa.access);
                errdefer allocator.free(access);

                var extras: std.json.ObjectMap = .{};
                var eit = oa.extras.iterator();
                while (eit.next()) |entry| {
                    const k = try allocator.dupe(u8, entry.key_ptr.*);
                    const v = try ai.json_util.cloneJsonValue(allocator, entry.value_ptr.*);
                    try extras.put(allocator, k, v);
                }

                return .{ .oauth = .{
                    .refresh = refresh,
                    .access = access,
                    .expires = oa.expires,
                    .extras = extras,
                } };
            },
        }
    }

    fn freeCredential(allocator: std.mem.Allocator, cred: types.AuthCredential) void {
        switch (cred) {
            .api_key => |ak| allocator.free(ak.key),
            .oauth => |oa| {
                allocator.free(oa.refresh);
                allocator.free(oa.access);
                var extras = oa.extras;
                var eit = extras.iterator();
                while (eit.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    ai.json_util.freeJsonValue(allocator, entry.value_ptr.*);
                }
                extras.deinit(allocator);
            },
        }
    }
};

fn seedStoredApiKey(allocator: std.mem.Allocator, data: *types.AuthStorageData, provider: []const u8, api_key: []const u8) !void {
    const key = try allocator.dupe(u8, provider);
    errdefer allocator.free(key);
    const value = try allocator.dupe(u8, api_key);
    errdefer allocator.free(value);
    try data.put(key, .{ .api_key = .{ .key = value } });
}

fn expectApiKey(storage: *AuthStorage, provider: []const u8, expected: []const u8) !void {
    const key = storage.getApiKey(provider) orelse return error.ExpectedApiKey;
    try std.testing.expectEqualStrings(expected, key);
}

fn oauthExpiryFromNow(delta_ms: i64) i64 {
    return std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() + delta_ms;
}

test "priority chain prefers runtime override before stored credential" {
    const allocator = std.testing.allocator;
    var init_data = types.AuthStorageData.init(allocator);
    defer types.deinitAuthStorageData(&init_data);
    try seedStoredApiKey(allocator, &init_data, "test-provider", "stored-key");

    var storage = try AuthStorage.inMemory(allocator, &init_data);
    defer storage.deinit();
    try expectApiKey(&storage, "test-provider", "stored-key");
    storage.setRuntimeApiKey("test-provider", "runtime-key");
    try expectApiKey(&storage, "test-provider", "runtime-key");
}

test "set/get round-trip with in-memory backend" {
    const allocator = std.testing.allocator;

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();
    try std.testing.expect(storage.get("anthropic") == null);
    try std.testing.expect(!storage.has("anthropic"));
    storage.set("anthropic", .{ .api_key = .{ .key = "sk-test-123" } });
    const cred = storage.get("anthropic") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.api_key, std.meta.activeTag(cred));
    try std.testing.expectEqualStrings("sk-test-123", cred.api_key.key);
    try std.testing.expect(storage.has("anthropic"));
    try expectApiKey(&storage, "anthropic", "sk-test-123");
    storage.remove("anthropic");
    try std.testing.expect(storage.get("anthropic") == null);
    try std.testing.expect(!storage.has("anthropic"));
}

test "oauth-backed claim providers resolve auth by visible claim name only" {
    const allocator = std.testing.allocator;
    oauth_mod.resetDynamicProvidersForTest();
    defer oauth_mod.resetDynamicProvidersForTest();

    var claim = ai.provider.ClaimRegistration{
        .name = try allocator.dupe(u8, "proxy"),
        .api = try allocator.dupe(u8, "anthropic-messages"),
        .base_url = try allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try allocator.dupe(u8, "Proxy Login"),
        .owner_id = try allocator.dupe(u8, "state-123"),
        .generation = 3,
    };
    defer claim.deinit(allocator);
    try oauth_mod.syncClaimProvider(allocator, &claim);

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();

    storage.set("anthropic-messages", .{ .oauth = .{
        .refresh = "delegate-refresh",
        .access = "delegate-access",
        .expires = oauthExpiryFromNow(60_000),
        .extras = .{},
    } });
    try std.testing.expect(storage.getApiKey("proxy") == null);

    storage.set("proxy", .{ .oauth = .{
        .refresh = "proxy-refresh",
        .access = "proxy-access",
        .expires = oauthExpiryFromNow(60_000),
        .extras = .{},
    } });
    try expectApiKey(&storage, "proxy", "proxy-access");
}

test "extension-owned oauth refresh uses the agent-thread hook and persists the returned credential" {
    const allocator = std.testing.allocator;
    oauth_mod.resetDynamicProvidersForTest();
    defer oauth_mod.resetDynamicProvidersForTest();

    var claim = ai.provider.ClaimRegistration{
        .name = try allocator.dupe(u8, "proxy-refresh"),
        .api = try allocator.dupe(u8, "anthropic-messages"),
        .base_url = try allocator.dupe(u8, "https://proxy.example"),
        .oauth_enabled = true,
        .oauth_name = try allocator.dupe(u8, "Proxy Refresh"),
        .oauth_refresh_token_ref = 1,
        .owner_id = try allocator.dupe(u8, "state-456"),
        .generation = 4,
    };
    defer claim.deinit(allocator);
    try oauth_mod.syncClaimProvider(allocator, &claim);

    const Hook = struct {
        fn refresh(provider: []const u8, credential: types.OAuthCredential, alloc: std.mem.Allocator, _: ?*anyopaque) oauth_mod.ExchangeResult {
            if (!std.mem.eql(u8, provider, "proxy-refresh")) return .{ .err = "wrong provider" };
            if (!std.mem.eql(u8, credential.refresh, "old-refresh")) return .{ .err = "wrong refresh token" };
            return .{ .success = .{
                .refresh = alloc.dupe(u8, "new-refresh") catch return .{ .err = "oom" },
                .access = alloc.dupe(u8, "new-access") catch return .{ .err = "oom" },
                .expires = oauthExpiryFromNow(60_000),
                .extras = .{},
            } };
        }
    };

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();
    storage.setExtensionOAuthRefreshHook(.{ .func = &Hook.refresh });
    storage.set("proxy-refresh", .{ .oauth = .{
        .refresh = "old-refresh",
        .access = "old-access",
        .expires = oauthExpiryFromNow(-1),
        .extras = .{},
    } });

    try expectApiKey(&storage, "proxy-refresh", "new-access");

    const refreshed = storage.get("proxy-refresh") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("new-refresh", refreshed.oauth.refresh);
    try std.testing.expectEqualStrings("new-access", refreshed.oauth.access);
}

test "hasAuth checks all tiers" {
    const allocator = std.testing.allocator;

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();
    try std.testing.expect(!storage.hasAuth("nonexistent-provider-xyz"));
    storage.setRuntimeApiKey("runtime-only", "key");
    try std.testing.expect(storage.hasAuth("runtime-only"));
    storage.set("stored-only", .{ .api_key = .{ .key = "sk-stored" } });
    try std.testing.expect(storage.hasAuth("stored-only"));
    storage.setFallbackResolver(&fallbackForTest);
    try std.testing.expect(storage.hasAuth("fallback-provider"));
    try std.testing.expect(!storage.hasAuth("still-unknown"));
}

fn fallbackForTest(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "fallback-provider")) return "fallback-key";
    return null;
}

test "zi-m7q: repeated set on same provider keeps key valid (no UAF on serialize)" {
    const allocator = std.testing.allocator;

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();

    storage.set("anthropic", .{ .api_key = .{ .key = "one" } });
    storage.set("anthropic", .{ .api_key = .{ .key = "two" } });

    const json = try json_write.toOwnedSlice(allocator, storage.getAll(), types.writeAuthJson);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"two\"") != null);
}
