const std = @import("std");
const ai = @import("ai");
const types = @import("types.zig");
const file_backend = @import("file_backend.zig");
const resolve_config_value = @import("resolve_config_value.zig");

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
        var self = AuthStorage{
            .data = types.AuthStorageData.init(allocator),
            .backend = .{ .file = try file_backend.FileState.init(allocator, auth_path) },
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
        var backend: file_backend.Backend = .{ .memory = file_backend.MemoryState.init(allocator) };

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

        // Free old entry if present
        if (self.data.fetchPut(key_duped, cred_duped) catch null) |old| {
            freeCredential(self.allocator, old.value);
            self.allocator.free(old.key);
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

        if (self.runtime_overrides.fetchPut(key_duped, val_duped) catch null) |old| {
            self.allocator.free(old.key);
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
    /// 3. OAuth token from auth.json (access token — NO auto-refresh in v1)
    /// 4. Environment variable (via ai.env_api_keys.getEnvApiKey)
    /// 5. Fallback resolver
    ///
    /// NOTE: OAuth auto-refresh with locking is deferred to v2.
    /// For now, we return the stored access token as-is.
    /// pi-mono source: auth-storage.ts:424-485
    pub fn getApiKey(self: *const AuthStorage, provider: []const u8) ?[]const u8 {
        // 1. Runtime override
        if (self.runtime_overrides.get(provider)) |key| return key;

        // 2-3. auth.json credential
        if (self.data.get(provider)) |cred| {
            switch (cred) {
                .api_key => |ak| return resolve_config_value.resolveConfigValue(ak.key),
                .oauth => |oa| return oa.access,
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
                    const v = try cloneJsonValue(allocator, entry.value_ptr.*);
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
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                extras.deinit();
            },
        }
    }

    fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
        switch (value) {
            .null => return .null,
            .bool => |b| return .{ .bool = b },
            .integer => |i| return .{ .integer = i },
            .float => |f| return .{ .float = f },
            .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            .array => |arr| {
                var new_arr = try std.json.Array.initCapacity(allocator, arr.items.len);
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

    fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
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
                var oit = mutable.iterator();
                while (oit.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                mutable.deinit();
            },
            else => {},
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
