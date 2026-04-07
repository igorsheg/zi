const std = @import("std");
const ai = @import("../ai/root.zig");
const shared_storage = @import("../storage.zig");
const types = @import("types.zig");
const file_backend = @import("file_backend.zig");
const resolve_config_value = @import("resolve_config_value.zig");
const oauth_mod = @import("oauth.zig");

const log = std.log.scoped(.auth_storage);

/// Credential storage for API keys and OAuth tokens.
/// Zig port of pi-mono's AuthStorage class.
/// pi-mono source: packages/coding-agent/src/core/auth-storage.ts:184
pub const AuthStorage = struct {
    data: types.AuthStorageData,
    backend: file_backend.Backend,
    allocator: std.mem.Allocator,
    runtime_overrides: std.StringHashMap([]const u8),
    fallback_resolver: ?*const fn (provider: []const u8) ?[]const u8 = null,
    load_error: bool = false,

    /// Create a file-backed AuthStorage, loading from disk.
    /// pi-mono source: auth-storage.ts:195-197
    pub fn create(allocator: std.mem.Allocator, auth_path: ?[]const u8) !AuthStorage {
        const path = if (auth_path) |p|
            try allocator.dupe(u8, p)
        else
            try file_backend.defaultAuthPath(allocator);
        defer allocator.free(path);

        var self = AuthStorage{
            .data = types.AuthStorageData.init(allocator),
            .backend = .{ .file = try shared_storage.LockedFile.init(allocator, path) },
            .allocator = allocator,
            .runtime_overrides = std.StringHashMap([]const u8).init(allocator),
        };
        self.reload();
        return self;
    }

    /// Create an in-memory AuthStorage for tests.
    /// Optionally pre-populate with initial data by serializing it into the memory backend.
    /// pi-mono source: auth-storage.ts:203-207
    pub fn inMemory(allocator: std.mem.Allocator, initial_data: ?*const types.AuthStorageData) !AuthStorage {
        var backend: file_backend.Backend = .{ .memory = @import("../storage.zig").MemoryFile.init(allocator) };

        if (initial_data) |d| {
            const json = try types.serializeAuthJson(allocator, d);
            defer allocator.free(json);
            try backend.writeContent(json);
        }

        var self = AuthStorage{
            .data = types.AuthStorageData.init(allocator),
            .backend = backend,
            .allocator = allocator,
            .runtime_overrides = std.StringHashMap([]const u8).init(allocator),
        };
        self.reload();
        return self;
    }

    pub fn deinit(self: *AuthStorage) void {
        // Free runtime overrides (we own the keys and values)
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

    /// Reload credentials from backend.
    /// pi-mono source: auth-storage.ts:247-260
    pub fn reload(self: *AuthStorage) void {
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
            // No content — could be missing file (ok) or read error.
            // pi-mono treats missing file as empty data, errors set loadError.
            // Our backend returns null for both — keep existing data on first load,
            // reset on explicit reload.
            types.deinitAuthStorageData(&self.data);
            self.data = types.AuthStorageData.init(self.allocator);
            self.load_error = false;
        }
    }

    /// Get credential for a provider.
    /// pi-mono source: auth-storage.ts:286-288
    pub fn get(self: *const AuthStorage, provider: []const u8) ?types.AuthCredential {
        return self.data.get(provider);
    }

    /// Set credential for a provider. Updates in-memory and persists.
    /// pi-mono source: auth-storage.ts:293-296
    pub fn set(self: *AuthStorage, provider: []const u8, credential: types.AuthCredential) void {
        // Update in-memory — need to dupe key and credential values
        const key_duped = self.allocator.dupe(u8, provider) catch return;

        const cred_duped = dupeCredential(self.allocator, credential) catch {
            self.allocator.free(key_duped);
            return;
        };

        // On collision, std.HashMap.fetchPut KEEPS the existing key
        // and only replaces the value (verified against zig stdlib
        // hash_map.zig:902-912 + 1099-1104). The map never adopts
        // `key_duped` when found_existing == true, so we MUST free
        // the fresh dup, NOT `old.key` — freeing old.key would
        // dangle the live key still in the map and the next
        // serialize would write whatever the GPA filled the freed
        // bytes with (0xAA in Debug). zi-m7q.
        if (self.data.fetchPut(key_duped, cred_duped) catch null) |old| {
            freeCredential(self.allocator, old.value);
            self.allocator.free(key_duped);
        }

        self.persistProviderChange(provider, credential);
    }

    /// Remove credential for a provider.
    /// pi-mono source: auth-storage.ts:301-304
    pub fn remove(self: *AuthStorage, provider: []const u8) void {
        if (self.data.fetchRemove(provider)) |old| {
            freeCredential(self.allocator, old.value);
            self.allocator.free(old.key);
        }
        self.persistProviderChange(provider, null);
    }

    /// Check if credentials exist for a provider in storage.
    /// pi-mono source: auth-storage.ts:316-318
    pub fn has(self: *const AuthStorage, provider: []const u8) bool {
        return self.data.get(provider) != null;
    }

    /// List all provider IDs with credentials. Caller owns returned slice and strings.
    /// pi-mono source: auth-storage.ts:309-311
    pub fn list(self: *const AuthStorage, allocator: std.mem.Allocator) ![][]const u8 {
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

    /// Return reference to the full data map.
    /// pi-mono source: auth-storage.ts:335-337
    pub fn getAll(self: *const AuthStorage) *const types.AuthStorageData {
        return &self.data;
    }

    /// Set a runtime API key override (not persisted). Used for CLI --api-key.
    /// pi-mono source: auth-storage.ts:213-215
    pub fn setRuntimeApiKey(self: *AuthStorage, provider: []const u8, key: []const u8) void {
        const key_duped = self.allocator.dupe(u8, provider) catch return;
        const val_duped = self.allocator.dupe(u8, key) catch {
            self.allocator.free(key_duped);
            return;
        };

        // See zi-m7q note in `set()` — fetchPut keeps the existing
        // key on collision; we MUST free the fresh dup, not old.key.
        if (self.runtime_overrides.fetchPut(key_duped, val_duped) catch null) |old| {
            self.allocator.free(key_duped);
            self.allocator.free(old.value);
        }
    }

    /// Remove a runtime API key override.
    /// pi-mono source: auth-storage.ts:220-222
    pub fn removeRuntimeApiKey(self: *AuthStorage, provider: []const u8) void {
        if (self.runtime_overrides.fetchRemove(provider)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    /// Set fallback resolver for API keys not found via other tiers.
    /// pi-mono source: auth-storage.ts:228-230
    pub fn setFallbackResolver(self: *AuthStorage, resolver: *const fn (provider: []const u8) ?[]const u8) void {
        self.fallback_resolver = resolver;
    }

    /// Check if any form of auth is configured for a provider.
    /// Does NOT auto-refresh OAuth tokens — just checks availability.
    /// pi-mono source: auth-storage.ts:324-330
    pub fn hasAuth(self: *const AuthStorage, provider: []const u8) bool {
        if (self.runtime_overrides.get(provider) != null) return true;
        if (self.data.get(provider) != null) return true;
        if (ai.env_api_keys.getEnvApiKey(provider) != null) return true;
        if (self.fallback_resolver) |resolver| {
            if (resolver(provider) != null) return true;
        }
        return false;
    }

    /// Get API key for a provider. 5-tier priority:
    /// 1. Runtime override (CLI --api-key)
    /// 2. API key from auth.json (resolved via resolveConfigValue)
    /// 3. OAuth token from auth.json — auto-refreshed under a backend
    ///    lock when expired
    /// 4. Environment variable (via ai.env_api_keys.getEnvApiKey)
    /// 5. Fallback resolver
    ///
    /// Mutates self when an OAuth token is refreshed: the new credential
    /// is written into both `data` and the on-disk auth.json under the
    /// existing backend lock. Receiver is non-const for that reason.
    ///
    /// pi-mono source: auth-storage.ts:424-485
    pub fn getApiKey(self: *AuthStorage, provider: []const u8) ?[]const u8 {
        // 1. Runtime override
        if (self.runtime_overrides.get(provider)) |key| return key;

        // 2-3. auth.json credential
        if (self.data.get(provider)) |cred| {
            switch (cred) {
                .api_key => |ak| return resolve_config_value.resolveConfigValue(ak.key),
                .oauth => |oa| {
                    // Fast path: token still valid. The 5-minute safety
                    // buffer is baked into `expires` at refresh time
                    // (oauth.zig: now + expires_in*1000 - 5*60*1000), so
                    // any expired check here doesn't need its own slack.
                    const now_ms = std.time.milliTimestamp();
                    if (now_ms < oa.expires) return oa.access;

                    // Slow path: refresh under lock. On failure, fall
                    // through and let the rest of the priority chain
                    // try (env var, fallback resolver) — the user can
                    // /login to re-authenticate without losing the
                    // stale credential, which is preserved on disk.
                    if (self.refreshOAuthLocked(provider)) |refreshed| {
                        return refreshed;
                    }
                },
            }
        }

        // 4. Environment variable
        if (ai.env_api_keys.getEnvApiKey(provider)) |key| return key;

        // 5. Fallback resolver
        if (self.fallback_resolver) |resolver| {
            if (resolver(provider)) |key| return key;
        }

        return null;
    }

    /// Refresh an expired OAuth token under the backend lock. Returns
    /// the new access token on success, null on failure (provider
    /// unknown, network error, lock contention, persist failure).
    ///
    /// Race protection mirrors pi-mono auth-storage.ts:369-413: we
    /// take the lock, reload from disk, and re-check expiry. If a
    /// peer process refreshed in the lock-acquisition window, we use
    /// their credential and skip the refresh exchange.
    ///
    /// On success the new credential is written to both in-memory
    /// `data` and the on-disk file BEFORE releasing the lock so the
    /// next reader sees a consistent view.
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

        // Re-read from disk inside the lock — another process may
        // have refreshed for us already. We use a scratch arena for
        // the parsed file so we don't leak when discarding it.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const fresh_content = self.backend.readContent(arena_alloc);
        const fresh_data_opt: ?types.AuthStorageData = if (fresh_content) |c|
            (types.parseAuthJson(arena_alloc, c) catch null)
        else
            null;

        // Pick the credential to base the refresh on: prefer the
        // re-read disk copy (most recent), fall back to the in-memory
        // copy if the file is missing or corrupt.
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

        // Race-window check: did the disk copy already get refreshed
        // by a peer? If so, install it in-memory and return.
        const now_ms = std.time.milliTimestamp();
        if (base_from_disk and now_ms < base_cred.expires) {
            self.installRefreshedCredential(provider, base_cred) catch return null;
            // Look up the just-installed credential — installRefreshedCredential
            // dupes into self.allocator, so the slice we return is owned by
            // self.data, not by the arena that's about to die.
            return switch (self.data.get(provider) orelse return null) {
                .oauth => |oa| oa.access,
                else => null,
            };
        }

        // Actually exchange. The refresh helper allocates the new
        // credential strings with `self.allocator` so they survive
        // arena teardown — we hand them straight to data + persist.
        const exchange = oauth_provider.refresh_token(self.allocator, base_cred);
        switch (exchange) {
            .err => |msg| {
                log.warn("oauth refresh failed for '{s}': {s}", .{ provider, msg });
                return null;
            },
            .success => |new_cred| {
                // installRefreshedCredential clones into self.allocator,
                // so we always free the original `new_cred` (allocated
                // by oauth_provider.refresh_token with self.allocator)
                // after install regardless of outcome.
                defer freeCredential(self.allocator, .{ .oauth = new_cred });
                self.installRefreshedCredential(provider, new_cred) catch return null;
                // Persist the new state to disk while still under lock.
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

    /// Install a refreshed OAuth credential into in-memory `data`,
    /// freeing any previous entry for the same provider. The new
    /// credential MUST already own its strings via `self.allocator`
    /// (i.e. came from oauth.refresh_token or was deep-cloned from
    /// arena memory before calling this).
    fn installRefreshedCredential(
        self: *AuthStorage,
        provider: []const u8,
        new_cred: types.OAuthCredential,
    ) !void {
        // Deep-clone via the existing helper so the entry is owned by
        // self.allocator regardless of where `new_cred`'s strings came
        // from (arena vs the success path's allocator). Caller is
        // responsible for freeing the original on rollback.
        const cloned = try dupeCredential(self.allocator, .{ .oauth = new_cred });
        errdefer freeCredential(self.allocator, cloned);

        const key_dup = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(key_dup);

        // See zi-m7q note in `set()` — on collision the map keeps
        // the existing key, so free `key_dup` (the fresh dup), NOT
        // old.key. Freeing old.key dangles the live key still in
        // the map; the next serializeAuthJson writes garbage and
        // bricks parseAuthJson on the next reload. This path is
        // hot because every expired-oauth getApiKey() lands here.
        if (self.data.fetchPut(key_dup, cloned) catch |e| {
            return e;
        }) |old| {
            freeCredential(self.allocator, old.value);
            self.allocator.free(key_dup);
        }
    }

    /// Write the current in-memory `data` to the backend. Caller
    /// MUST already hold the backend lock — this skips the acquire
    /// step that `persistProviderChange` does. Used by the refresh
    /// path which needs the read+exchange+write to be atomic.
    fn persistInsideLock(self: *AuthStorage, arena_alloc: std.mem.Allocator) !void {
        const json = try types.serializeAuthJson(arena_alloc, &self.data);
        try self.backend.writeContent(json);
    }

    /// Persist a provider change to the backend with locking.
    /// Reads current file, merges our change, writes back.
    /// pi-mono source: auth-storage.ts:262-281
    fn persistProviderChange(self: *AuthStorage, provider: []const u8, credential: ?types.AuthCredential) void {
        if (self.load_error) return;

        if (!self.backend.acquireLock()) return;
        defer self.backend.releaseLock();

        // Use an arena for the temporary parse/serialize cycle
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Read current file content (may have changed from another process)
        const current_content = self.backend.readContent(arena_alloc);

        // Parse current data (or start fresh)
        var current_data = if (current_content) |c|
            types.parseAuthJson(arena_alloc, c) catch return
        else
            types.AuthStorageData.init(arena_alloc);

        // Apply change — arena-backed, no need for manual cleanup
        if (credential) |cred| {
            const key = arena_alloc.dupe(u8, provider) catch return;
            const duped_cred = dupeCredential(arena_alloc, cred) catch return;
            current_data.put(key, duped_cred) catch return;
        } else {
            // Remove — fetchRemove to get the old entry (arena will clean up)
            _ = current_data.fetchRemove(provider);
        }

        // Serialize and write
        const json = types.serializeAuthJson(arena_alloc, &current_data) catch return;
        self.backend.writeContent(json) catch return;
    }

    /// Duplicate a credential, allocating all strings with the given allocator.
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

                var extras = std.json.ObjectMap.init(allocator);
                var eit = oa.extras.iterator();
                while (eit.next()) |entry| {
                    const k = try allocator.dupe(u8, entry.key_ptr.*);
                    const v = try ai.json_util.cloneJsonValue(allocator, entry.value_ptr.*);
                    try extras.put(k, v);
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

    /// Free a credential's owned strings.
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
                extras.deinit();
            },
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────────

test "priority chain: runtime override wins over stored credential" {
    const allocator = std.testing.allocator;

    // Set up initial data with an api_key credential
    var init_data = types.AuthStorageData.init(allocator);
    defer types.deinitAuthStorageData(&init_data);
    const key = try allocator.dupe(u8, "test-provider");
    errdefer allocator.free(key);
    try init_data.put(key, .{ .api_key = .{
        .key = try allocator.dupe(u8, "stored-key"),
    } });

    var storage = try AuthStorage.inMemory(allocator, &init_data);
    defer storage.deinit();

    // Tier 2: stored api_key should resolve
    const from_storage = storage.getApiKey("test-provider");
    try std.testing.expect(from_storage != null);
    try std.testing.expectEqualStrings("stored-key", from_storage.?);

    // Tier 1: runtime override wins
    storage.setRuntimeApiKey("test-provider", "runtime-key");
    const from_runtime = storage.getApiKey("test-provider");
    try std.testing.expect(from_runtime != null);
    try std.testing.expectEqualStrings("runtime-key", from_runtime.?);
}

test "set/get round-trip with in-memory backend" {
    const allocator = std.testing.allocator;

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();

    // Initially empty
    try std.testing.expect(storage.get("anthropic") == null);
    try std.testing.expect(!storage.has("anthropic"));

    // Set a credential
    storage.set("anthropic", .{ .api_key = .{ .key = "sk-test-123" } });

    // Verify get returns it
    const cred = storage.get("anthropic") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(.api_key, std.meta.activeTag(cred));
    try std.testing.expectEqualStrings("sk-test-123", cred.api_key.key);
    try std.testing.expect(storage.has("anthropic"));

    // Verify getApiKey resolves it
    const api_key = storage.getApiKey("anthropic");
    try std.testing.expect(api_key != null);
    try std.testing.expectEqualStrings("sk-test-123", api_key.?);

    // Remove and verify gone
    storage.remove("anthropic");
    try std.testing.expect(storage.get("anthropic") == null);
    try std.testing.expect(!storage.has("anthropic"));
}

test "hasAuth checks all tiers" {
    const allocator = std.testing.allocator;

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();

    // Unknown provider — no auth
    try std.testing.expect(!storage.hasAuth("nonexistent-provider-xyz"));

    // Tier 1: runtime override
    storage.setRuntimeApiKey("runtime-only", "key");
    try std.testing.expect(storage.hasAuth("runtime-only"));

    // Tier 2: stored credential
    storage.set("stored-only", .{ .api_key = .{ .key = "sk-stored" } });
    try std.testing.expect(storage.hasAuth("stored-only"));

    // Tier 5: fallback resolver
    storage.setFallbackResolver(&fallbackForTest);
    try std.testing.expect(storage.hasAuth("fallback-provider"));
    try std.testing.expect(!storage.hasAuth("still-unknown"));
}

fn fallbackForTest(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "fallback-provider")) return "fallback-key";
    return null;
}

test "zi-m7q: repeated set on same provider keeps key valid (no UAF on serialize)" {
    // Regression: pre-fix, the second set() freed the live map key
    // because std.HashMap.fetchPut keeps the existing key on
    // collision. The next serializeAuthJson then wrote 0xAA bytes
    // (debug undefined fill) and bricked auth.json on reload.
    const allocator = std.testing.allocator;

    var storage = try AuthStorage.inMemory(allocator, null);
    defer storage.deinit();

    storage.set("anthropic", .{ .api_key = .{ .key = "one" } });
    storage.set("anthropic", .{ .api_key = .{ .key = "two" } });

    const json = try types.serializeAuthJson(allocator, storage.getAll());
    defer allocator.free(json);

    // Pre-fix: this would be `"\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa"`.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"two\"") != null);
}
