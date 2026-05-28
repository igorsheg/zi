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
    dir: ?std.Io.Dir = null,
    auth_path: ?[]const u8 = null,
    credentials: []OAuthCredential,

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        paths: paths_mod.PersistencePaths,
    ) !AuthStore {
        const auth_path = try paths.authPath(allocator);
        errdefer allocator.free(auth_path);
        const bytes = dir.readFileAlloc(
            io,
            auth_path,
            allocator,
            .limited(max_auth_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return .{
                .allocator = allocator,
                .dir = dir,
                .auth_path = auth_path,
                .credentials = try allocator.alloc(OAuthCredential, 0),
            },
            else => return err,
        };
        defer allocator.free(bytes);
        var store = try parse(allocator, bytes);
        store.dir = dir;
        store.auth_path = auth_path;
        return store;
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
        if (self.auth_path) |auth_path| self.allocator.free(auth_path);
        self.* = undefined;
    }

    pub fn setOAuth(self: *AuthStore, io: std.Io, provider: ai.Provider, credentials: ai.OAuthCredentials) !void {
        var owned = try cloneOAuthCredential(self.allocator, provider, credentials);
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

    pub fn save(self: *const AuthStore, io: std.Io) !void {
        try self.saveCredentials(io, self.credentials);
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

    pub fn format(self: *const AuthStore, allocator: std.mem.Allocator) ![]const u8 {
        return formatCredentials(allocator, self.credentials);
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

fn cloneOAuthCredential(
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
    const owned_extra = if (credentials.extra) |extra| try cloneJsonValue(allocator, extra) else null;
    errdefer if (owned_extra) |extra| agent_mod.freeJsonValue(allocator, extra);

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
    const extra = if (value.object.get("extra")) |extra_value| try cloneJsonValue(allocator, extra_value) else null;
    errdefer if (extra) |item| agent_mod.freeJsonValue(allocator, item);

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

fn cloneJsonValue(allocator: std.mem.Allocator, source: std.json.Value) !std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |array| blk: {
            var cloned: std.json.Array = .init(allocator);
            errdefer agent_mod.freeJsonValue(allocator, .{ .array = cloned });
            for (array.items) |item| try cloned.append(try cloneJsonValue(allocator, item));
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned: std.json.ObjectMap = .empty;
            errdefer agent_mod.freeJsonValue(allocator, .{ .object = cloned });
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = cloneJsonValue(allocator, entry.value_ptr.*) catch |err| {
                    allocator.free(key);
                    return err;
                };
                cloned.put(allocator, key, value) catch |err| {
                    allocator.free(key);
                    agent_mod.freeJsonValue(allocator, value);
                    return err;
                };
            }
            break :blk .{ .object = cloned };
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
        .data = "{\"openai-codex\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\"," ++
            "\"access\":\"access-token\",\"expires\":123,\"extra\":{\"account\":\"a1\"}}}",
    });

    var auth = try AuthManager.init(std.testing.allocator, std.testing.io, .{
        .paths = .{ .global_dir = "agent", .cwd = "repo" },
        .dir = tmp.dir,
    });
    defer auth.deinit();
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), ai.KnownProvider.openai_codex);
    defer std.testing.allocator.free(key.?);
    try auth.store.save(std.testing.io);
    const saved = try tmp.dir.readFileAlloc(std.testing.io, "agent/auth.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(saved);

    try std.testing.expect(auth.hasAuth(ai.KnownProvider.openai_codex));
    try std.testing.expectEqualStrings("access-token", key.?);
    try std.testing.expectEqualStrings(
        "{\"openai-codex\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\"," ++
            "\"access\":\"access-token\",\"expires\":123,\"extra\":{\"account\":\"a1\"}}}\n",
        saved,
    );
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
