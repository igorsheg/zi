const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const paths_mod = @import("paths.zig");
const runtime = @import("../runtime/root.zig");

pub const max_auth_file_bytes = 64 * 1024;

const builtin_oauth_providers = [_]ai.OAuthProviderInterface{ai.openai_codex_oauth_provider};

pub const OAuthCredential = struct {
    provider: []const u8,
    credentials: ai.OAuthCredentials,

    pub fn deinit(self: *OAuthCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        deinitOAuthCredentials(allocator, &self.credentials);
        self.* = undefined;
    }
};

pub const AuthStore = struct {
    allocator: std.mem.Allocator,
    dir: ?std.Io.Dir = null,
    auth_path: ?[]const u8 = null,
    credentials: []OAuthCredential,

    /// The auth file is operational input: missing, unreadable, or malformed
    /// content degrades to an empty store. Only allocation failure propagates.
    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        paths: paths_mod.PersistencePaths,
    ) !AuthStore {
        const auth_path = try paths.authPath(allocator);
        errdefer allocator.free(auth_path);
        const empty: AuthStore = .{
            .allocator = allocator,
            .dir = dir,
            .auth_path = auth_path,
            .credentials = try allocator.alloc(OAuthCredential, 0),
        };
        const bytes = dir.readFileAlloc(
            io,
            auth_path,
            allocator,
            .limited(max_auth_file_bytes),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return empty,
        };
        defer allocator.free(bytes);
        var store = parse(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return empty,
        };
        allocator.free(empty.credentials);
        store.dir = dir;
        store.auth_path = auth_path;
        return store;
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !AuthStore {
        return .{ .allocator = allocator, .credentials = try parseCredentials(allocator, bytes) };
    }

    fn parseCredentials(allocator: std.mem.Allocator, bytes: []const u8) ![]OAuthCredential {
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

        return credentials.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *AuthStore) void {
        for (self.credentials) |*credential| credential.deinit(self.allocator);
        self.allocator.free(self.credentials);
        if (self.auth_path) |auth_path| self.allocator.free(auth_path);
        self.* = undefined;
    }

    fn reload(self: *AuthStore, io: std.Io) !void {
        const dir = self.dir orelse return error.AuthStoreReadOnly;
        const auth_path = self.auth_path orelse return error.AuthStoreReadOnly;
        const bytes = dir.readFileAlloc(
            io,
            auth_path,
            self.allocator,
            .limited(max_auth_file_bytes),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.replaceCredentials(try self.allocator.alloc(OAuthCredential, 0)),
        };
        defer self.allocator.free(bytes);
        const credentials = parseCredentials(self.allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.replaceCredentials(try self.allocator.alloc(OAuthCredential, 0)),
        };
        self.replaceCredentials(credentials);
    }

    fn replaceCredentials(self: *AuthStore, credentials: []OAuthCredential) void {
        for (self.credentials) |*credential| credential.deinit(self.allocator);
        self.allocator.free(self.credentials);
        self.credentials = credentials;
    }

    pub fn setOAuth(self: *AuthStore, io: std.Io, provider: ai.Provider, credentials: ai.OAuthCredentials) !void {
        var owned = try copyOAuthCredential(self.allocator, provider, credentials);
        errdefer owned.deinit(self.allocator);

        for (self.credentials, 0..) |credential, index| {
            if (std.mem.eql(u8, credential.provider, provider)) {
                const next = try self.allocator.dupe(OAuthCredential, self.credentials);
                defer self.allocator.free(next);
                next[index] = owned;
                try self.saveCredentials(io, next);
                self.credentials[index].deinit(self.allocator);
                self.credentials[index] = owned;
                return;
            }
        }

        const next = try self.allocator.alloc(OAuthCredential, self.credentials.len + 1);
        defer self.allocator.free(next);
        @memcpy(next[0..self.credentials.len], self.credentials);
        next[self.credentials.len] = owned;
        const committed = try self.allocator.dupe(OAuthCredential, next);
        errdefer self.allocator.free(committed);
        try self.saveCredentials(io, next);
        self.allocator.free(self.credentials);
        self.credentials = committed;
    }

    pub fn remove(self: *AuthStore, io: std.Io, provider: ai.Provider) !void {
        for (self.credentials, 0..) |credential, index| {
            if (std.mem.eql(u8, credential.provider, provider)) {
                const next = try self.allocator.alloc(OAuthCredential, self.credentials.len - 1);
                defer self.allocator.free(next);
                @memcpy(next[0..index], self.credentials[0..index]);
                @memcpy(next[index..], self.credentials[index + 1 ..]);
                const committed = try self.allocator.dupe(OAuthCredential, next);
                errdefer self.allocator.free(committed);
                try self.saveCredentials(io, next);
                self.credentials[index].deinit(self.allocator);
                self.allocator.free(self.credentials);
                self.credentials = committed;
                return;
            }
        }
    }

    fn saveCredentials(self: *const AuthStore, io: std.Io, credentials: []const OAuthCredential) !void {
        const dir = self.dir orelse return error.AuthStoreReadOnly;
        const auth_path = self.auth_path orelse return error.AuthStoreReadOnly;
        const parent = std.fs.path.dirname(auth_path) orelse ".";
        try dir.createDirPath(io, parent);
        const data = try formatCredentials(self.allocator, credentials);
        defer self.allocator.free(data);
        try writeFileAtomic(self.allocator, io, dir, auth_path, data);
    }

    pub fn findOAuth(self: *const AuthStore, provider: ai.Provider) ?ai.OAuthCredentials {
        for (self.credentials) |credential| {
            if (std.mem.eql(u8, credential.provider, provider)) return credential.credentials;
        }
        return null;
    }
};

pub const AuthManager = struct {
    io: std.Io,
    environ: ?*const std.process.Environ.Map = null,
    oauth_providers: []const ai.OAuthProviderInterface = &builtin_oauth_providers,
    store: AuthStore,

    pub const Options = struct {
        environ: ?*const std.process.Environ.Map = null,
        oauth_providers: []const ai.OAuthProviderInterface = &builtin_oauth_providers,
        paths: paths_mod.PersistencePaths,
        dir: std.Io.Dir = .cwd(),
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !AuthManager {
        return .{
            .io = io,
            .environ = options.environ,
            .oauth_providers = options.oauth_providers,
            .store = try AuthStore.load(allocator, io, options.dir, options.paths),
        };
    }

    pub fn deinit(self: *AuthManager) void {
        self.store.deinit();
        self.* = undefined;
    }

    pub fn hook(self: *AuthManager) agent_mod.GetApiKeyHook {
        return .{ .context = self, .call_fn = getApiKey };
    }

    fn findEnvApiKey(self: *const AuthManager, provider: ai.Provider) ?ai.EnvApiKey {
        const environ = self.environ orelse return null;
        return ai.getEnvApiKey(environ, provider);
    }

    fn findOAuthCredentials(self: *const AuthManager, provider: ai.Provider) ?ai.OAuthCredentials {
        return self.store.findOAuth(provider);
    }

    fn oauthProvider(self: *const AuthManager, provider: ai.Provider) ?ai.OAuthProviderInterface {
        for (self.oauth_providers) |oauth_provider| {
            if (std.mem.eql(u8, oauth_provider.id, provider)) return oauth_provider;
        }
        return null;
    }

    pub fn setOAuthCredentials(
        self: *AuthManager,
        io: std.Io,
        provider: ai.Provider,
        credentials: ai.OAuthCredentials,
    ) !void {
        try self.store.setOAuth(io, provider, credentials);
    }

    pub fn removeCredentials(self: *AuthManager, io: std.Io, provider: ai.Provider) !void {
        try self.store.remove(io, provider);
    }

    pub fn loginOAuth(
        self: *AuthManager,
        io: std.Io,
        task_runtime: *runtime.Runtime,
        provider: ai.OAuthProviderInterface,
        callbacks: ai.OAuthLoginCallbacks,
    ) !void {
        var credentials = try provider.login(self.store.allocator, io, task_runtime, callbacks);
        defer deinitOAuthCredentials(self.store.allocator, &credentials);
        try self.setOAuthCredentials(io, provider.id, credentials);
    }

    pub fn hasAuth(self: *const AuthManager, provider: ai.Provider) bool {
        return self.findEnvApiKey(provider) != null or self.findOAuthCredentials(provider) != null;
    }

    fn getApiKey(
        allocator: std.mem.Allocator,
        context: ?*anyopaque,
        provider: ai.Provider,
    ) anyerror!?ai.ApiCredential {
        const self: *AuthManager = @ptrCast(@alignCast(context.?));
        if (self.findEnvApiKey(provider)) |key| {
            return .{ .api_key = try allocator.dupe(u8, key.value) };
        }
        const oauth_provider = self.oauthProvider(provider) orelse return null;
        const credentials = try self.refreshIfExpired(oauth_provider) orelse return null;
        const api_key = try oauth_provider.getApiKey(credentials);
        return .{ .api_key = try allocator.dupe(u8, api_key), .auth_extra = credentials.extra };
    }

    fn refreshIfExpired(self: *AuthManager, provider: ai.OAuthProviderInterface) !?ai.OAuthCredentials {
        const now_ms: i64 = @intCast(std.Io.Timestamp.now(self.io, .real).toMilliseconds());
        const credentials = self.findOAuthCredentials(provider.id) orelse return null;
        if (now_ms < credentials.expires) return credentials;

        // ponytail: zio-backed std.Io panics on file locks today; reload before refresh is the useful part.
        try self.store.reload(self.io);
        const current = self.findOAuthCredentials(provider.id) orelse return null;
        if (now_ms < current.expires) return current;
        return self.refreshExpiredUnlocked(provider, current);
    }

    fn refreshExpiredUnlocked(
        self: *AuthManager,
        provider: ai.OAuthProviderInterface,
        credentials: ai.OAuthCredentials,
    ) !?ai.OAuthCredentials {
        var refreshed = provider.refreshToken(self.store.allocator, self.io, credentials) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return credentials,
        };
        defer deinitOAuthCredentials(self.store.allocator, &refreshed);
        self.setOAuthCredentials(self.io, provider.id, refreshed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return credentials,
        };
        return self.findOAuthCredentials(provider.id);
    }
};

fn deinitOAuthCredentials(allocator: std.mem.Allocator, credentials: *ai.OAuthCredentials) void {
    allocator.free(credentials.refresh);
    allocator.free(credentials.access);
    if (credentials.extra) |extra| runtime.freeJsonValue(allocator, extra);
    credentials.* = undefined;
}

fn formatCredentials(allocator: std.mem.Allocator, credentials: []const OAuthCredential) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeByte('{');
    for (credentials, 0..) |credential, index| {
        if (index > 0) try writer.writer.writeByte(',');
        try std.json.Stringify.value(credential.provider, .{}, &writer.writer);
        try writer.writer.writeAll(":{\"type\":\"oauth\",\"refresh\":");
        try std.json.Stringify.value(credential.credentials.refresh, .{}, &writer.writer);
        try writer.writer.writeAll(",\"access\":");
        try std.json.Stringify.value(credential.credentials.access, .{}, &writer.writer);
        try writer.writer.writeAll(",\"expires\":");
        try writer.writer.print("{}", .{credential.credentials.expires});
        if (credential.credentials.extra) |extra| {
            try writer.writer.writeAll(",\"extra\":");
            try std.json.Stringify.value(extra, .{}, &writer.writer);
        }
        try writer.writer.writeByte('}');
    }
    try writer.writer.writeAll("}\n");
    return writer.toOwnedSlice();
}

fn writeFileAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    data: []const u8,
) !void {
    const parent = std.fs.path.dirname(path);
    const basename = std.fs.path.basename(path);
    const tmp_basename = try std.fmt.allocPrint(allocator, ".{s}.tmp", .{basename});
    defer allocator.free(tmp_basename);
    const tmp_path = if (parent) |dir_path|
        try std.fs.path.join(allocator, &.{ dir_path, tmp_basename })
    else
        try allocator.dupe(u8, tmp_basename);
    defer allocator.free(tmp_path);
    errdefer dir.deleteFile(io, tmp_path) catch {};
    try dir.writeFile(io, .{ .sub_path = tmp_path, .data = data });
    try std.Io.Dir.rename(dir, tmp_path, dir, path, io);
}

fn copyOAuthCredential(
    allocator: std.mem.Allocator,
    provider: ai.Provider,
    credentials: ai.OAuthCredentials,
) !OAuthCredential {
    const owned_provider = try allocator.dupe(u8, provider);
    errdefer allocator.free(owned_provider);
    const owned_refresh = try allocator.dupe(u8, credentials.refresh);
    errdefer allocator.free(owned_refresh);
    const owned_access = try allocator.dupe(u8, credentials.access);
    errdefer allocator.free(owned_access);
    const owned_extra = if (credentials.extra) |extra| try runtime.cloneJsonValue(allocator, extra) else null;
    errdefer if (owned_extra) |extra| runtime.freeJsonValue(allocator, extra);

    return .{
        .provider = owned_provider,
        .credentials = .{
            .refresh = owned_refresh,
            .access = owned_access,
            .expires = credentials.expires,
            .extra = owned_extra,
        },
    };
}

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
    const extra = if (value.object.get("extra")) |extra_value|
        try runtime.cloneJsonValue(allocator, extra_value)
    else
        null;
    errdefer if (extra) |item| runtime.freeJsonValue(allocator, item);

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
            .extra = extra,
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
    defer std.testing.allocator.free(key.?.api_key);

    try std.testing.expectEqualStrings("secret", key.?.api_key);
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

    try std.testing.expectEqual(@as(?ai.ApiCredential, null), key);
}

test "auth store loads oauth credentials from global auth file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"openai-codex\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\"," ++
            "\"access\":\"access-token\",\"expires\":123,\"extra\":{\"account\":\"a1\"}}}",
    });

    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), ai.KnownProvider.openai_codex);
    defer std.testing.allocator.free(key.?.api_key);
    try std.testing.expect(auth.hasAuth(ai.KnownProvider.openai_codex));
    try std.testing.expectEqualStrings("access-token", key.?.api_key);
    try std.testing.expect(key.?.auth_extra.? == .object);
}

test "auth manager refreshes expired oauth credentials before returning api key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"test-oauth\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\"," ++
            "\"access\":\"expired-access-token\",\"expires\":0}}",
    });

    var calls: OAuthRefreshCalls = .{};
    const providers = [_]ai.OAuthProviderInterface{.{
        .id = "test-oauth",
        .name = "Test OAuth",
        .context = &calls,
        .login_fn = testOAuthLogin,
        .refresh_token_fn = testOAuthRefreshWithCount,
        .get_api_key_fn = testOAuthApiKey,
    }};
    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .oauth_providers = &providers,
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();

    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), "test-oauth");
    defer std.testing.allocator.free(key.?.api_key);
    try std.testing.expectEqualStrings("refreshed-access-token", key.?.api_key);
    try std.testing.expectEqual(@as(usize, 1), calls.refresh_count);

    const second_key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), "test-oauth");
    defer std.testing.allocator.free(second_key.?.api_key);
    try std.testing.expectEqualStrings("refreshed-access-token", second_key.?.api_key);
    try std.testing.expectEqual(@as(usize, 1), calls.refresh_count);

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "agent/auth.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "refreshed-access-token") != null);
}

test "auth manager reloads oauth credentials under refresh lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"test-oauth\":{\"type\":\"oauth\",\"refresh\":\"old-refresh\"," ++
            "\"access\":\"expired-access-token\",\"expires\":0}}",
    });

    var calls: OAuthRefreshCalls = .{};
    const providers = [_]ai.OAuthProviderInterface{.{
        .id = "test-oauth",
        .name = "Test OAuth",
        .context = &calls,
        .login_fn = testOAuthLogin,
        .refresh_token_fn = testOAuthRefreshWithCount,
        .get_api_key_fn = testOAuthApiKey,
    }};
    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .oauth_providers = &providers,
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"test-oauth\":{\"type\":\"oauth\",\"refresh\":\"new-refresh\"," ++
            "\"access\":\"fresh-access-token\",\"expires\":9223372036854775807}}",
    });

    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), "test-oauth");
    defer std.testing.allocator.free(key.?.api_key);
    try std.testing.expectEqualStrings("fresh-access-token", key.?.api_key);
    try std.testing.expectEqual(@as(usize, 0), calls.refresh_count);
}

test "auth manager persists oauth credentials through one mutation path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();

    try auth.setOAuthCredentials(std.testing.io, ai.KnownProvider.openai_codex, .{
        .refresh = "refresh-token",
        .access = "access-token",
        .expires = 123,
    });

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "agent/auth.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"openai-codex\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\"," ++
            "\"access\":\"access-token\",\"expires\":123}}\n",
        bytes,
    );
    try std.testing.expect(auth.hasAuth(ai.KnownProvider.openai_codex));
}

test "auth manager removes stored credentials" {
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

    try auth.removeCredentials(std.testing.io, ai.KnownProvider.openai_codex);

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "agent/auth.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{}\n", bytes);
    try std.testing.expect(!auth.hasAuth(ai.KnownProvider.openai_codex));
}

test "auth manager logs in through oauth provider and persists credentials" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var calls: OAuthLoginCalls = .{};
    const provider: ai.OAuthProviderInterface = .{
        .id = "openai-codex",
        .name = "Test Codex",
        .login_fn = testOAuthLogin,
        .refresh_token_fn = testOAuthRefresh,
        .get_api_key_fn = testOAuthApiKey,
    };

    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();

    try auth.loginOAuth(task_runtime.io(), task_runtime, provider, .{
        .context = &calls,
        .on_auth_fn = testOnOAuthAuth,
        .on_prompt_fn = testOnOAuthPrompt,
    });

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "agent/auth.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), calls.auth_count);
    try std.testing.expectEqualStrings(
        "{\"openai-codex\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\"," ++
            "\"access\":\"access-token\",\"expires\":123}}\n",
        bytes,
    );
    try std.testing.expect(auth.hasAuth(ai.KnownProvider.openai_codex));
}

const OAuthLoginCalls = struct {
    auth_count: usize = 0,
};

const OAuthRefreshCalls = struct {
    refresh_count: usize = 0,
};

fn testOAuthLogin(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: *runtime.Runtime,
    _: ?*anyopaque,
    callbacks: ai.OAuthLoginCallbacks,
) !ai.OAuthCredentials {
    try callbacks.onAuth(.{ .url = "https://example.test" });
    return .{
        .refresh = try allocator.dupe(u8, "refresh-token"),
        .access = try allocator.dupe(u8, "access-token"),
        .expires = 123,
    };
}

fn testOAuthRefresh(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: ?*anyopaque,
    credentials: ai.OAuthCredentials,
) !ai.OAuthCredentials {
    return .{
        .refresh = try allocator.dupe(u8, credentials.refresh),
        .access = try allocator.dupe(u8, credentials.access),
        .expires = credentials.expires,
    };
}

fn testOAuthRefreshWithCount(
    allocator: std.mem.Allocator,
    _: std.Io,
    context: ?*anyopaque,
    credentials: ai.OAuthCredentials,
) !ai.OAuthCredentials {
    const calls: *OAuthRefreshCalls = @ptrCast(@alignCast(context.?));
    calls.refresh_count += 1;
    return .{
        .refresh = try allocator.dupe(u8, credentials.refresh),
        .access = try allocator.dupe(u8, "refreshed-access-token"),
        .expires = std.math.maxInt(i64),
    };
}

fn testOAuthApiKey(_: ?*anyopaque, credentials: ai.OAuthCredentials) ![]const u8 {
    return credentials.access;
}

fn testOnOAuthAuth(context: ?*anyopaque, info: ai.OAuthAuthInfo) !void {
    const calls: *OAuthLoginCalls = @ptrCast(@alignCast(context.?));
    calls.auth_count += 1;
    try std.testing.expectEqualStrings("https://example.test", info.url);
}

fn testOnOAuthPrompt(_: ?*anyopaque, _: ai.OAuthPrompt) ![]const u8 {
    return "";
}
