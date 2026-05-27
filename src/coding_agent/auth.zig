const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const paths_mod = @import("paths.zig");

pub const max_auth_file_bytes = 64 * 1024;

pub const OAuthCredential = struct {
    provider: []const u8,
    credentials: ai.OAuthCredentials,

    pub fn deinit(self: *OAuthCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.credentials.refresh);
        allocator.free(self.credentials.access);
        if (self.credentials.extra) |extra| agent_mod.freeJsonValue(allocator, extra);
        self.* = undefined;
    }
};

pub const AuthStore = struct {
    allocator: std.mem.Allocator,
    credentials: []OAuthCredential,

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        paths: paths_mod.PersistencePaths,
    ) !AuthStore {
        const auth_path = try paths.authPath(allocator);
        defer allocator.free(auth_path);
        const bytes = dir.readFileAlloc(
            io,
            auth_path,
            allocator,
            .limited(max_auth_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return .{
                .allocator = allocator,
                .credentials = try allocator.alloc(OAuthCredential, 0),
            },
            else => return err,
        };
        defer allocator.free(bytes);
        return parse(allocator, bytes);
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !AuthStore {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAuthStore;

        var credentials = std.ArrayList(OAuthCredential).empty;
        errdefer {
            for (credentials.items) |*credential| credential.deinit(allocator);
            credentials.deinit(allocator);
        }

        var iterator = parsed.value.object.iterator();
        while (iterator.next()) |entry| {
            if (try parseOAuthCredential(allocator, entry.key_ptr.*, entry.value_ptr.*)) |credential| {
                var owned = credential;
                credentials.append(allocator, owned) catch |err| {
                    owned.deinit(allocator);
                    return err;
                };
            }
        }

        return .{ .allocator = allocator, .credentials = try credentials.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *AuthStore) void {
        for (self.credentials) |*credential| credential.deinit(self.allocator);
        self.allocator.free(self.credentials);
        self.* = undefined;
    }

    pub fn findOAuth(self: *const AuthStore, provider: ai.Provider) ?ai.OAuthCredentials {
        for (self.credentials) |credential| {
            if (std.mem.eql(u8, credential.provider, provider)) return credential.credentials;
        }
        return null;
    }

    pub fn hasOAuth(self: *const AuthStore, provider: ai.Provider) bool {
        return self.findOAuth(provider) != null;
    }
};

pub const AuthManager = struct {
    environ: ?*const std.process.Environ.Map = null,
    store: AuthStore,

    pub const Options = struct {
        environ: ?*const std.process.Environ.Map = null,
        paths: paths_mod.PersistencePaths,
        dir: std.Io.Dir = .cwd(),
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !AuthManager {
        return .{
            .environ = options.environ,
            .store = try AuthStore.load(allocator, io, options.dir, options.paths),
        };
    }

    pub fn deinit(self: *AuthManager) void {
        self.store.deinit();
        self.* = undefined;
    }

    pub fn hook(self: *const AuthManager) agent_mod.GetApiKeyHook {
        return .{ .context = @constCast(self), .call_fn = getApiKey };
    }

    pub fn findEnvApiKey(self: *const AuthManager, provider: ai.Provider) ?ai.EnvApiKey {
        const environ = self.environ orelse return null;
        return ai.getEnvApiKey(environ, provider);
    }

    pub fn findOAuthCredentials(self: *const AuthManager, provider: ai.Provider) ?ai.OAuthCredentials {
        return self.store.findOAuth(provider);
    }

    pub fn hasAuth(self: *const AuthManager, provider: ai.Provider) bool {
        return self.findEnvApiKey(provider) != null or self.findOAuthCredentials(provider) != null;
    }

    fn getApiKey(
        allocator: std.mem.Allocator,
        context: ?*anyopaque,
        provider: ai.Provider,
    ) std.mem.Allocator.Error!?[]const u8 {
        const self: *const AuthManager = @ptrCast(@alignCast(context.?));
        if (self.findEnvApiKey(provider)) |key| {
            const owned = try allocator.dupe(u8, key.value);
            return owned;
        }
        if (self.findOAuthCredentials(provider)) |credentials| {
            if (std.mem.eql(u8, provider, ai.openai_codex_oauth_provider.id)) {
                const api_key = ai.openai_codex_oauth_provider.getApiKey(credentials) catch unreachable;
                const owned = try allocator.dupe(u8, api_key);
                return owned;
            }
        }
        return null;
    }
};

fn parseOAuthCredential(
    allocator: std.mem.Allocator,
    provider: []const u8,
    value: std.json.Value,
) !?OAuthCredential {
    if (value != .object) return null;
    const type_value = value.object.get("type") orelse return null;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "oauth")) return null;
    const refresh = requiredString(value.object.get("refresh")) orelse return null;
    const access = requiredString(value.object.get("access")) orelse return null;
    const expires = requiredInteger(value.object.get("expires")) orelse return null;

    const owned_provider = try allocator.dupe(u8, provider);
    errdefer allocator.free(owned_provider);
    const owned_refresh = try allocator.dupe(u8, refresh);
    errdefer allocator.free(owned_refresh);
    const owned_access = try allocator.dupe(u8, access);
    errdefer allocator.free(owned_access);

    return .{
        .provider = owned_provider,
        .credentials = .{
            .refresh = owned_refresh,
            .access = owned_access,
            .expires = expires,
        },
    };
}

fn requiredString(value: ?std.json.Value) ?[]const u8 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn requiredInteger(value: ?std.json.Value) ?i64 {
    const resolved = value orelse return null;
    return switch (resolved) {
        .integer => |number| number,
        else => null,
    };
}

test "auth manager returns configured env api key" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");

    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .environ = &environ,
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), ai.KnownProvider.openai);
    defer std.testing.allocator.free(key.?);

    try std.testing.expectEqualStrings("secret", key.?);
}

test "auth manager treats missing env and store as absent auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");

    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), ai.KnownProvider.openai);

    try std.testing.expectEqual(@as(?[]const u8, null), key);
}

test "auth store loads oauth credentials from global auth file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data =
        \\{"openai-codex":{"type":"oauth","refresh":"refresh-token","access":"access-token","expires":123}}
        ,
    });

    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), ai.KnownProvider.openai_codex);
    defer std.testing.allocator.free(key.?);

    try std.testing.expect(auth.hasAuth(ai.KnownProvider.openai_codex));
    try std.testing.expectEqualStrings("access-token", key.?);
}
