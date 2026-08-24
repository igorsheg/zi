const std = @import("std");
const auth = @import("auth.zig");
const credential = @import("credential.zig");
const model_api = @import("model.zig");
const model_catalog = @import("model_catalog.zig");
const protocol_api = @import("protocol.zig");
const provider_api = @import("provider.zig");
const settings = @import("settings.zig");
const transport_api = @import("transport.zig");

const Models = @This();

pub const Config = struct {
    catalog: model_catalog.Catalog,
    providers: []const provider_api.Definition,
    credentials: []const credential.Entry,
    auth_resolver: ?auth.Resolver = null,
    selection: model_api.ModelIdentity,
};

pub const Error = error{
    OutOfMemory,
    InvalidConfiguration,
};

pub const AuthError = error{
    MissingCredential,
    InvalidCredential,
    DuplicateCredential,
    UnsupportedCredential,
    InvalidConfiguration,
};

arena: std.heap.ArenaAllocator,
registry: provider_api.Registry,
catalog: model_catalog.Catalog,
providers: []provider_api.Configured,
credentials: []credential.Entry,
sensitive: [][]u8,
sensitive_count: usize,
model_value: model_api.Model,

pub fn init(
    allocator: std.mem.Allocator,
    transport: transport_api.Transport,
    protocols: protocol_api.Registry,
    config: Config,
) Error!Models {
    try validate(protocols, config);
    var self: Models = undefined;
    self.arena = std.heap.ArenaAllocator.init(allocator);
    errdefer self.arena.deinit();
    self.registry = provider_api.Registry.init(allocator);
    errdefer self.registry.deinit();

    const owned = self.arena.allocator();
    self.catalog = try copyCatalog(owned, config.catalog);
    self.providers = try owned.alloc(provider_api.Configured, config.providers.len);
    self.sensitive = try owned.alloc([]u8, config.credentials.len * 3);
    self.sensitive_count = 0;
    errdefer self.wipeSensitive();
    self.credentials = try self.copyCredentials(config.credentials);

    for (config.providers, 0..) |definition, index| {
        self.providers[index] = .{
            .transport = transport,
            .protocols = protocols,
            .catalog = self.catalog,
            .definition = try copyProvider(owned, definition),
            .auth_inputs = .{ .stored = self.credentials },
            .auth_resolver = config.auth_resolver,
        };
        self.registry.register(self.providers[index].provider()) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateProvider, error.InvalidProvider => return error.InvalidConfiguration,
        };
    }
    self.model_value = self.registry.resolve(config.selection) orelse return error.InvalidConfiguration;
    return self;
}

pub fn resolveAuth(
    catalog: model_catalog.Catalog,
    providers: []const provider_api.Definition,
    selection: model_api.ModelIdentity,
    inputs: auth.Inputs,
) AuthError!auth.Selected {
    const selected = catalog.resolve(selection) orelse return error.InvalidConfiguration;
    const provider = findProvider(providers, selected.providerId()) orelse return error.InvalidConfiguration;
    return auth.select(provider.auth, provider.id, inputs);
}

pub fn model(self: *const Models) model_api.Model {
    return self.model_value;
}

pub fn deinit(self: *Models) void {
    self.wipeSensitive();
    self.registry.deinit();
    self.arena.deinit();
    self.* = undefined;
}

fn copyCredentials(self: *Models, source: []const credential.Entry) error{OutOfMemory}![]credential.Entry {
    const copied = try self.arena.allocator().alloc(credential.Entry, source.len);
    for (source, copied) |entry, *destination| {
        destination.provider_id = try self.arena.allocator().dupe(u8, entry.provider_id);
        destination.credential = switch (entry.credential) {
            .api_key => |api_key| .{ .api_key = .{ .key = try self.copySensitive(api_key.key) } },
            .oauth => |oauth| .{ .oauth = .{
                .access = try self.copySensitive(oauth.access),
                .refresh = try self.copySensitive(oauth.refresh),
                .expires_at_ms = oauth.expires_at_ms,
                .account_id = if (oauth.account_id) |account_id|
                    try self.copySensitive(account_id)
                else
                    null,
            } },
        };
    }
    return copied;
}

fn copySensitive(self: *Models, value: []const u8) error{OutOfMemory}![]u8 {
    const copied = try self.arena.allocator().dupe(u8, value);
    self.sensitive[self.sensitive_count] = copied;
    self.sensitive_count += 1;
    return copied;
}

fn wipeSensitive(self: *Models) void {
    for (self.sensitive[0..self.sensitive_count]) |value| std.crypto.secureZero(u8, value);
}

fn copyProvider(
    allocator: std.mem.Allocator,
    source: provider_api.Definition,
) error{OutOfMemory}!provider_api.Definition {
    const environment_names = if (source.auth.api_key) |api_key| names: {
        const copied = try allocator.alloc([]const u8, api_key.environment_names.len);
        for (api_key.environment_names, copied) |name, *destination| {
            destination.* = try allocator.dupe(u8, name);
        }
        break :names copied;
    } else null;
    const headers = try allocator.alloc(transport_api.Header, source.headers.len);
    for (source.headers, headers) |header, *destination| {
        destination.* = .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
            .sensitive = header.sensitive,
        };
    }
    return .{
        .id = try allocator.dupe(u8, source.id),
        .name = try allocator.dupe(u8, source.name),
        .base_url = try allocator.dupe(u8, source.base_url),
        .headers = headers,
        .auth = .{
            .api_key = if (environment_names) |names| .{ .environment_names = names } else null,
            .oauth = source.auth.oauth,
            .allow_unauthenticated = source.auth.allow_unauthenticated,
        },
    };
}

fn copyCatalog(allocator: std.mem.Allocator, source: model_catalog.Catalog) error{OutOfMemory}!model_catalog.Catalog {
    const entries = try allocator.alloc(model_catalog.Entry, source.entries.len);
    for (source.entries, entries) |entry, *destination| {
        const aliases = try allocator.alloc([]const u8, entry.aliases.len);
        for (entry.aliases, aliases) |alias, *copied| copied.* = try allocator.dupe(u8, alias);
        var profile = entry.profile;
        if (entry.profile.thinking) |thinking| profile.thinking = .{
            .level_map = try copyThinkingLevelMap(allocator, thinking.level_map),
        };
        destination.* = .{
            .identity = .{
                .provider = try allocator.dupe(u8, entry.identity.provider),
                .model = try allocator.dupe(u8, entry.identity.model),
            },
            .protocol_id = try allocator.dupe(u8, entry.protocol_id),
            .aliases = aliases,
            .source_url = if (entry.source_url) |url| try allocator.dupe(u8, url) else null,
            .profile = profile,
        };
    }
    return .{ .entries = entries };
}

fn copyThinkingLevelMap(
    allocator: std.mem.Allocator,
    source: settings.ThinkingLevelMap,
) error{OutOfMemory}!settings.ThinkingLevelMap {
    var result = source;
    inline for (std.meta.fields(settings.ThinkingLevel)) |field| {
        @field(result, field.name) = switch (@field(source, field.name)) {
            .inherited => .inherited,
            .unsupported => .unsupported,
            .mapped => |value| .{ .mapped = try allocator.dupe(u8, value) },
        };
    }
    return result;
}

fn validate(protocols: protocol_api.Registry, config: Config) Error!void {
    config.catalog.validate() catch return error.InvalidConfiguration;
    if (config.credentials.len > credential.max_credentials) return error.InvalidConfiguration;
    for (config.catalog.entries) |entry| {
        _ = protocols.find(entry.protocol_id) orelse return error.InvalidConfiguration;
    }
    for (config.providers, 0..) |provider, index| {
        if (provider.id.len == 0 or provider.name.len == 0 or provider.base_url.len == 0) {
            return error.InvalidConfiguration;
        }
        transport_api.validateExtraHeaders(provider.headers) catch return error.InvalidConfiguration;
        for (config.providers[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, provider.id)) return error.InvalidConfiguration;
        }
    }
    for (config.credentials, 0..) |entry, index| {
        const provider = findProvider(config.providers, entry.provider_id) orelse return error.InvalidConfiguration;
        switch (entry.credential) {
            .api_key => |api_key| if (api_key.key.len == 0 or provider.auth.api_key == null)
                return error.InvalidConfiguration,
            .oauth => |oauth| {
                if (oauth.access.len == 0 or oauth.refresh.len == 0 or provider.auth.oauth == null) {
                    return error.InvalidConfiguration;
                }
                if (oauth.account_id) |account_id| if (account_id.len == 0) return error.InvalidConfiguration;
            },
        }
        for (config.credentials[0..index]) |previous| {
            if (std.mem.eql(u8, previous.provider_id, entry.provider_id)) return error.InvalidConfiguration;
        }
    }
    // A dynamic resolver is authoritative at invocation time, so static
    // credentials may be absent. Registry resolution below still validates the
    // selected provider and model during initialization.
    if (config.auth_resolver == null) {
        _ = resolveAuth(
            config.catalog,
            config.providers,
            config.selection,
            .{ .stored = config.credentials },
        ) catch return error.InvalidConfiguration;
    }
}

fn findProvider(providers: []const provider_api.Definition, id: []const u8) ?*const provider_api.Definition {
    for (providers) |*provider| {
        if (std.mem.eql(u8, provider.id, id)) return provider;
    }
    return null;
}

test "owned catalog copies model-specific thinking wire mappings" {
    var wire_value = [_]u8{ 'm', 'a', 'x', 'i', 'm', 'u', 'm' };
    const entries = [_]model_catalog.Entry{.{
        .identity = .{ .provider = "provider", .model = "model" },
        .protocol_id = "protocol",
        .profile = .{ .thinking = .{ .level_map = .{
            .high = .{ .mapped = &wire_value },
        } } },
    }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copied = try copyCatalog(arena.allocator(), .{ .entries = &entries });
    @memset(&wire_value, 'x');
    try std.testing.expectEqualStrings(
        "maximum",
        copied.entries[0].profile.thinking.?.level_map.high.mapped,
    );
}
