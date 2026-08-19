const std = @import("std");
const credential_api = @import("credential.zig");
const oauth_api = @import("oauth.zig");
const transport = @import("transport.zig");

pub const Credential = credential_api.Credential;
pub const CredentialEntry = credential_api.Entry;

pub const EnvironmentEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Environment = struct {
    entries: []const EnvironmentEntry = &.{},

    pub fn get(self: Environment, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
};

pub const ModelAuth = struct {
    api_key: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    headers: []const transport.Header = &.{},
    base_url: ?[]const u8 = null,
};

pub const ApiKeyAuth = struct {
    environment_names: []const []const u8 = &.{},
};

pub const OAuthAuth = struct {
    refresher: ?oauth_api.Refresher = null,
    refresh_skew_ms: u64 = 5 * 60 * 1000,
};

pub const ProviderAuth = struct {
    api_key: ?ApiKeyAuth = null,
    oauth: ?OAuthAuth = null,
    allow_unauthenticated: bool = false,
};

pub const Inputs = struct {
    explicit_api_key: ?[]const u8 = null,
    stored: []const CredentialEntry = &.{},
    environment: Environment = .{},
};

pub const Error = error{
    MissingCredential,
    InvalidCredential,
    DuplicateCredential,
    UnsupportedCredential,
};

pub const Selected = union(enum) {
    unauthenticated,
    api_key: []const u8,
    oauth: Credential.OAuth,
};

pub fn select(policy: ProviderAuth, provider_id: []const u8, inputs: Inputs) Error!Selected {
    if (inputs.explicit_api_key) |key| {
        if (policy.api_key == null) return error.UnsupportedCredential;
        try validateSecret(key);
        return .{ .api_key = key };
    }

    var matching: ?Credential = null;
    for (inputs.stored) |entry| {
        if (!std.mem.eql(u8, entry.provider_id, provider_id)) continue;
        if (matching != null) return error.DuplicateCredential;
        matching = entry.credential;
    }
    if (matching) |stored| return switch (stored) {
        .api_key => |api_key| selected: {
            if (policy.api_key == null) return error.UnsupportedCredential;
            try validateSecret(api_key.key);
            break :selected .{ .api_key = api_key.key };
        },
        .oauth => |oauth| selected: {
            if (policy.oauth == null) return error.UnsupportedCredential;
            try validateSecret(oauth.access);
            try validateSecret(oauth.refresh);
            if (oauth.account_id) |account_id| try validateSecret(account_id);
            break :selected .{ .oauth = oauth };
        },
    };

    if (policy.api_key) |api_key| {
        for (api_key.environment_names) |name| {
            if (inputs.environment.get(name)) |value| {
                try validateSecret(value);
                return .{ .api_key = value };
            }
        }
    }
    if (policy.allow_unauthenticated) return .unauthenticated;
    return error.MissingCredential;
}

pub fn resolve(policy: ProviderAuth, provider_id: []const u8, inputs: Inputs) Error!ModelAuth {
    return switch (try select(policy, provider_id, inputs)) {
        .unauthenticated => .{},
        .api_key => |key| .{ .api_key = key },
        .oauth => |oauth| .{ .api_key = oauth.access, .account_id = oauth.account_id },
    };
}

fn validateSecret(secret: []const u8) error{InvalidCredential}!void {
    if (secret.len == 0 or secret.len > credential_api.max_secret_bytes) return error.InvalidCredential;
}

test "provider auth applies explicit stored and ambient precedence without provider brands" {
    const stored = [_]CredentialEntry{.{
        .provider_id = "provider",
        .credential = .{ .api_key = .{ .key = "stored" } },
    }};
    const environment = [_]EnvironmentEntry{.{ .name = "PROVIDER_KEY", .value = "ambient" }};
    const policy: ProviderAuth = .{ .api_key = .{ .environment_names = &.{"PROVIDER_KEY"} } };

    try std.testing.expectEqualStrings("explicit", (try resolve(policy, "provider", .{
        .explicit_api_key = "explicit",
        .stored = &stored,
        .environment = .{ .entries = &environment },
    })).api_key.?);
    try std.testing.expectEqualStrings("stored", (try resolve(policy, "provider", .{
        .stored = &stored,
        .environment = .{ .entries = &environment },
    })).api_key.?);
    try std.testing.expectEqualStrings("ambient", (try resolve(policy, "provider", .{
        .environment = .{ .entries = &environment },
    })).api_key.?);
}

test "stored credential owns provider auth resolution" {
    const stored = [_]CredentialEntry{.{
        .provider_id = "provider",
        .credential = .{ .oauth = .{
            .access = "access",
            .refresh = "refresh",
            .expires_at_ms = 1,
        } },
    }};
    const environment = [_]EnvironmentEntry{.{ .name = "PROVIDER_KEY", .value = "ambient" }};
    try std.testing.expectError(error.UnsupportedCredential, resolve(.{
        .api_key = .{ .environment_names = &.{"PROVIDER_KEY"} },
    }, "provider", .{
        .stored = &stored,
        .environment = .{ .entries = &environment },
    }));
}
