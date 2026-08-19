const std = @import("std");
const ai = @import("../ai/root.zig");
const ai_catalog = @import("../ai/model_catalog.zig");
const ai_model = @import("../ai/model.zig");
const ModelConfig = @import("ModelConfig.zig");

const max_credentials = ai.credential.max_credentials;
const max_secret_bytes = ai.credential.max_secret_bytes;
pub const StoredCredential = ai.credential.Entry;

pub const Error = error{
    OutOfMemory,
    InvalidModelConfiguration,
    SelectionRequired,
    IncompleteSelection,
    UnknownSelection,
    MissingCredential,
    InvalidCredential,
    DuplicateCredential,
    UnsupportedCliCredential,
};

pub const RuntimeConfig = struct {
    model_config: ModelConfig,
    credentials: []const StoredCredential,
    selection: ai_model.ModelIdentity,
};

pub const Inputs = struct {
    model_config: ModelConfig = ModelConfig.builtin,
    requested_provider: ?[]const u8,
    requested_model: ?[]const u8,
    cli_api_key: ?[]const u8 = null,
    stored_credentials: []const StoredCredential = &.{},
    environment: ai.auth.Environment = .{},
};

pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    model_config: ModelConfig,
    credentials: []const StoredCredential,
    selection: ai_model.ModelIdentity,
    sensitive: [3]?[]u8,

    pub fn runtimeConfig(self: *const Resolved) RuntimeConfig {
        return .{
            .model_config = self.model_config,
            .credentials = self.credentials,
            .selection = self.selection,
        };
    }

    pub fn deinit(self: *Resolved) void {
        for (self.sensitive) |value| {
            if (value) |secret| std.crypto.secureZero(u8, secret);
        }
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn resolve(allocator: std.mem.Allocator, inputs: Inputs) Error!Resolved {
    inputs.model_config.validate() catch return error.InvalidModelConfiguration;
    if (inputs.stored_credentials.len > max_credentials) return error.InvalidCredential;

    const requested_provider = inputs.requested_provider orelse {
        if (inputs.requested_model != null) return error.IncompleteSelection;
        return error.SelectionRequired;
    };
    const requested_model = inputs.requested_model orelse return error.IncompleteSelection;
    const selected = inputs.model_config.resolve(.{
        .provider = requested_provider,
        .model = requested_model,
    }) orelse return error.UnknownSelection;
    const selected_credential = ai.Models.resolveAuth(
        inputs.model_config.catalog,
        inputs.model_config.providers,
        selected.entry.identity,
        .{
            .explicit_api_key = inputs.cli_api_key,
            .stored = inputs.stored_credentials,
            .environment = inputs.environment,
        },
    ) catch |failure| return switch (failure) {
        error.MissingCredential => error.MissingCredential,
        error.InvalidCredential => error.InvalidCredential,
        error.DuplicateCredential => error.DuplicateCredential,
        error.UnsupportedCredential => if (inputs.cli_api_key != null)
            error.UnsupportedCliCredential
        else
            error.InvalidCredential,
        error.InvalidConfiguration => error.InvalidModelConfiguration,
    };
    const provider = inputs.model_config.findProvider(selected.providerId()).?;

    var result: Resolved = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .model_config = inputs.model_config,
        .credentials = &.{},
        .selection = selected.entry.identity,
        .sensitive = .{ null, null, null },
    };
    errdefer {
        for (result.sensitive) |value| {
            if (value) |secret| std.crypto.secureZero(u8, secret);
        }
        result.arena.deinit();
    }

    switch (selected_credential) {
        .unauthenticated => {},
        .api_key => |source| {
            const key = try result.arena.allocator().dupe(u8, source);
            result.sensitive[0] = key;
            const credentials = try result.arena.allocator().alloc(StoredCredential, 1);
            credentials[0] = .{
                .provider_id = try result.arena.allocator().dupe(u8, provider.id),
                .credential = .{ .api_key = .{ .key = key } },
            };
            result.credentials = credentials;
        },
        .oauth => |source| {
            const access = try result.arena.allocator().dupe(u8, source.access);
            result.sensitive[0] = access;
            const refresh = try result.arena.allocator().dupe(u8, source.refresh);
            result.sensitive[1] = refresh;
            const account_id = if (source.account_id) |value| copied: {
                const copy = try result.arena.allocator().dupe(u8, value);
                result.sensitive[2] = copy;
                break :copied copy;
            } else null;
            const credentials = try result.arena.allocator().alloc(StoredCredential, 1);
            credentials[0] = .{
                .provider_id = try result.arena.allocator().dupe(u8, provider.id),
                .credential = .{ .oauth = .{
                    .access = access,
                    .refresh = refresh,
                    .expires_at_ms = source.expires_at_ms,
                    .account_id = account_id,
                } },
            };
            result.credentials = credentials;
        },
    }
    return result;
}

fn storedApiKey(provider_id: []const u8, key: []const u8) StoredCredential {
    return .{ .provider_id = provider_id, .credential = .{ .api_key = .{ .key = key } } };
}

fn storedOauth(provider_id: []const u8, oauth: ai.Credential.OAuth) StoredCredential {
    return .{ .provider_id = provider_id, .credential = .{ .oauth = oauth } };
}

test "resolution canonicalizes provider-scoped aliases and applies API key precedence" {
    const cli_key = try std.testing.allocator.dupe(u8, "cli-key");
    defer std.testing.allocator.free(cli_key);
    const stored = [_]StoredCredential{storedApiKey("openai", "stored-key")};
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = cli_key,
        .stored_credentials = &stored,
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
    });
    defer resolved.deinit();
    @memset(cli_key, 'x');

    try std.testing.expectEqualStrings("openai", resolved.selection.provider);
    try std.testing.expectEqualStrings("gpt-5.6-sol", resolved.selection.model);
    try std.testing.expectEqual(@as(usize, 1), resolved.credentials.len);
    try std.testing.expectEqualStrings("cli-key", resolved.credentials[0].credential.api_key.key);
}

test "resolution uses stored credentials before environment and filters unrelated providers" {
    const stored = [_]StoredCredential{
        storedApiKey("unsupported", "ignored"),
        storedOauth("openai-codex", .{ .access = "", .refresh = "refresh", .expires_at_ms = 1 }),
        storedApiKey("openai", "stored-key"),
    };
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .stored_credentials = &stored,
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
    });
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 1), resolved.credentials.len);
    try std.testing.expectEqualStrings("stored-key", resolved.credentials[0].credential.api_key.key);
}

test "resolution uses the admitted OpenAI environment value only as fallback" {
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
    });
    defer resolved.deinit();
    try std.testing.expectEqualStrings("environment-key", resolved.credentials[0].credential.api_key.key);

    try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "openai-only" }} },
    }));
}

test "resolution does not reinterpret OpenAI environment or CLI credentials for custom authentication" {
    const entries = [_]ai_catalog.Entry{.{
        .identity = .{ .provider = "custom", .model = "custom-model" },
        .protocol_id = "openai-completions",
        .profile = .{},
    }};
    const catalog: ai_catalog.Catalog = .{ .entries = &entries };
    const api_key_providers = [_]ModelConfig.ProviderDefinition{.{
        .id = "custom",
        .name = "Custom",
        .base_url = "https://example.test/v1",
        .auth = .{ .api_key = .{} },
    }};
    const api_key_config = try ModelConfig.init(catalog, &api_key_providers);
    try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
        .model_config = api_key_config,
        .requested_provider = "custom",
        .requested_model = "custom-model",
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "openai-only" }} },
    }));
    var custom = try resolve(std.testing.allocator, .{
        .model_config = api_key_config,
        .requested_provider = "custom",
        .requested_model = "custom-model",
        .cli_api_key = "custom-key",
    });
    defer custom.deinit();
    try std.testing.expectEqualStrings("custom-key", custom.credentials[0].credential.api_key.key);

    const no_auth_providers = [_]ModelConfig.ProviderDefinition{.{
        .id = "custom",
        .name = "Custom",
        .base_url = "https://example.test/v1",
        .auth = .{ .allow_unauthenticated = true },
    }};
    const no_auth_config = try ModelConfig.init(catalog, &no_auth_providers);
    try std.testing.expectError(error.UnsupportedCliCredential, resolve(std.testing.allocator, .{
        .model_config = no_auth_config,
        .requested_provider = "custom",
        .requested_model = "custom-model",
        .cli_api_key = "unneeded",
    }));
}

test "resolution admits already-resolved Codex OAuth without API-key fallback" {
    const stored = [_]StoredCredential{storedOauth("openai-codex", .{
        .access = "codex-token",
        .refresh = "codex-refresh",
        .expires_at_ms = 1_777_800_000_000,
        .account_id = "codex-account",
    })};
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .stored_credentials = &stored,
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "openai-only" }} },
    });
    defer resolved.deinit();

    try std.testing.expectEqualStrings("codex-token", resolved.credentials[0].credential.oauth.access);
    try std.testing.expectEqualStrings("codex-account", resolved.credentials[0].credential.oauth.account_id.?);
    try std.testing.expectError(error.UnsupportedCliCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .cli_api_key = "not-codex-oauth",
        .stored_credentials = &stored,
    }));
}

test "resolution rejects incomplete, unknown, unavailable, and invalid inputs" {
    try std.testing.expectError(error.SelectionRequired, resolve(std.testing.allocator, .{
        .requested_provider = null,
        .requested_model = null,
    }));
    try std.testing.expectError(error.IncompleteSelection, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = null,
    }));
    try std.testing.expectError(error.IncompleteSelection, resolve(std.testing.allocator, .{
        .requested_provider = null,
        .requested_model = "gpt-5.6-sol",
    }));
    try std.testing.expectError(error.UnknownSelection, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "missing",
    }));
    try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
    }));
    try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .cli_api_key = "",
    }));

    const invalid_stored = [_]StoredCredential{storedApiKey("openai", "")};
    try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .stored_credentials = &invalid_stored,
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "must-not-mask-invalid-stored" }} },
    }));

    const duplicate = [_]StoredCredential{
        storedApiKey("openai", "one"),
        storedApiKey("openai", "two"),
    };
    try std.testing.expectError(error.DuplicateCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .stored_credentials = &duplicate,
    }));

    const oversized_secret = try std.testing.allocator.alloc(u8, max_secret_bytes + 1);
    defer std.testing.allocator.free(oversized_secret);
    @memset(oversized_secret, 'x');
    try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .cli_api_key = oversized_secret,
    }));

    var too_many: [max_credentials + 1]StoredCredential = undefined;
    for (&too_many) |*credential| {
        credential.* = storedApiKey("unsupported", "ignored");
    }
    try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .stored_credentials = &too_many,
        .environment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "environment-key" }} },
    }));
}

fn resolveAndDeinit(allocator: std.mem.Allocator) !void {
    const stored = [_]StoredCredential{storedOauth("openai-codex", .{
        .access = "codex-token",
        .refresh = "codex-refresh",
        .expires_at_ms = 1_777_800_000_000,
        .account_id = "codex-account",
    })};
    var resolved = try resolve(allocator, .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .stored_credentials = &stored,
    });
    resolved.deinit();
}

test "resolution settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, resolveAndDeinit, .{});
}

test "resolution wipes its selected credential copy" {
    const backing = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0xa5);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const stored = [_]StoredCredential{storedOauth("openai-codex", .{
        .access = "wipe-resolution-token",
        .refresh = "wipe-resolution-refresh",
        .expires_at_ms = 1_777_800_000_000,
        .account_id = "wipe-resolution-account",
    })};
    var resolved = try resolve(fixed.allocator(), .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .stored_credentials = &stored,
    });
    const credential = resolved.credentials[0].credential.oauth;
    const secrets = [_][]const u8{ credential.access, credential.refresh, credential.account_id.? };
    var offsets: [secrets.len]usize = undefined;
    var lengths: [secrets.len]usize = undefined;
    for (secrets, 0..) |secret, index| {
        offsets[index] = @intFromPtr(secret.ptr) - @intFromPtr(backing.ptr);
        lengths[index] = secret.len;
    }
    resolved.deinit();
    for (offsets, lengths) |offset, length| {
        for (backing[offset..][0..length]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
