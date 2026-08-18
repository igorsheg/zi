const std = @import("std");
const ai_catalog = @import("../ai/model_catalog.zig");
const ai_model = @import("../ai/model.zig");
const ModelConfig = @import("ModelConfig.zig");

const max_credentials = 32;
const max_secret_bytes = 1024 * 1024;

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

pub const Credential = union(enum) {
    api_key: ApiKey,
    openai_codex: OpenAiCodex,

    pub const ApiKey = struct {
        provider_id: []const u8,
        value: []const u8,
    };

    pub const OpenAiCodex = struct {
        access_token: []const u8,
        account_id: ?[]const u8 = null,
    };

    pub fn providerId(self: Credential) []const u8 {
        return switch (self) {
            .api_key => |credential| credential.provider_id,
            .openai_codex => "openai-codex",
        };
    }
};

pub const RuntimeConfig = struct {
    model_config: ModelConfig,
    credentials: []const Credential,
    selection: ai_model.ModelIdentity,
};

pub const Inputs = struct {
    model_config: ModelConfig = ModelConfig.builtin,
    requested_provider: ?[]const u8,
    requested_model: ?[]const u8,
    cli_api_key: ?[]const u8 = null,
    stored_credentials: []const Credential = &.{},
    openai_environment_api_key: ?[]const u8 = null,
};

pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    model_config: ModelConfig,
    credentials: []const Credential,
    selection: ai_model.ModelIdentity,
    sensitive: [2]?[]u8,

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
    const provider = inputs.model_config.findProvider(selected.providerId()).?;
    try validateSelectedStoredCredentials(provider.*, inputs.stored_credentials);

    var result: Resolved = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .model_config = inputs.model_config,
        .credentials = &.{},
        .selection = selected.entry.identity,
        .sensitive = .{ null, null },
    };
    errdefer {
        for (result.sensitive) |value| {
            if (value) |secret| std.crypto.secureZero(u8, secret);
        }
        result.arena.deinit();
    }

    switch (provider.*) {
        .openai_completions, .openai_responses => |definition| switch (definition.authentication) {
            .none => if (inputs.cli_api_key != null) return error.UnsupportedCliCredential,
            .api_key => {
                const source = try selectApiKey(inputs, definition.id);
                try validateSecret(source);
                const copied = try result.arena.allocator().dupe(u8, source);
                result.sensitive[0] = copied;
                const credentials = try result.arena.allocator().alloc(Credential, 1);
                credentials[0] = .{ .api_key = .{
                    .provider_id = definition.id,
                    .value = copied,
                } };
                result.credentials = credentials;
            },
        },
        .openai_codex_responses => {
            if (inputs.cli_api_key != null) return error.UnsupportedCliCredential;
            const stored = findStoredCodex(inputs.stored_credentials) orelse return error.MissingCredential;
            const token = try result.arena.allocator().dupe(u8, stored.access_token);
            result.sensitive[0] = token;
            const account_id = if (stored.account_id) |value| copied: {
                const copy = try result.arena.allocator().dupe(u8, value);
                result.sensitive[1] = copy;
                break :copied copy;
            } else null;
            const credentials = try result.arena.allocator().alloc(Credential, 1);
            credentials[0] = .{ .openai_codex = .{
                .access_token = token,
                .account_id = account_id,
            } };
            result.credentials = credentials;
        },
    }
    return result;
}

fn selectApiKey(inputs: Inputs, provider_id: []const u8) error{MissingCredential}![]const u8 {
    if (inputs.cli_api_key) |api_key| return api_key;
    if (findStoredApiKey(inputs.stored_credentials, provider_id)) |api_key| return api_key;
    if (std.mem.eql(u8, provider_id, "openai")) {
        if (inputs.openai_environment_api_key) |api_key| return api_key;
    }
    return error.MissingCredential;
}

fn validateSelectedStoredCredentials(
    provider: ModelConfig.ProviderDefinition,
    credentials: []const Credential,
) error{ InvalidCredential, DuplicateCredential }!void {
    var matching_count: usize = 0;
    for (credentials) |credential| {
        if (!std.mem.eql(u8, provider.id(), credential.providerId())) continue;
        matching_count += 1;
        if (matching_count > 1) return error.DuplicateCredential;
        switch (credential) {
            .api_key => |api_key| {
                try validateSecret(api_key.value);
                const accepts_api_key = switch (provider) {
                    .openai_completions, .openai_responses => |definition| definition.authentication == .api_key,
                    .openai_codex_responses => false,
                };
                if (!accepts_api_key) return error.InvalidCredential;
            },
            .openai_codex => |codex| {
                try validateSecret(codex.access_token);
                if (codex.account_id) |account_id| try validateSecret(account_id);
                if (provider != .openai_codex_responses) return error.InvalidCredential;
            },
        }
    }
}

fn validateSecret(secret: []const u8) error{InvalidCredential}!void {
    if (secret.len == 0 or secret.len > max_secret_bytes) return error.InvalidCredential;
}

fn findStoredApiKey(credentials: []const Credential, provider_id: []const u8) ?[]const u8 {
    for (credentials) |credential| switch (credential) {
        .api_key => |api_key| if (std.mem.eql(u8, api_key.provider_id, provider_id)) return api_key.value,
        .openai_codex => {},
    };
    return null;
}

fn findStoredCodex(credentials: []const Credential) ?Credential.OpenAiCodex {
    for (credentials) |credential| switch (credential) {
        .api_key => {},
        .openai_codex => |codex| return codex,
    };
    return null;
}

test "resolution canonicalizes provider-scoped aliases and applies API key precedence" {
    const cli_key = try std.testing.allocator.dupe(u8, "cli-key");
    defer std.testing.allocator.free(cli_key);
    const stored = [_]Credential{.{ .api_key = .{
        .provider_id = "openai",
        .value = "stored-key",
    } }};
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6",
        .cli_api_key = cli_key,
        .stored_credentials = &stored,
        .openai_environment_api_key = "environment-key",
    });
    defer resolved.deinit();
    @memset(cli_key, 'x');

    try std.testing.expectEqualStrings("openai", resolved.selection.provider);
    try std.testing.expectEqualStrings("gpt-5.6-sol", resolved.selection.model);
    try std.testing.expectEqual(@as(usize, 1), resolved.credentials.len);
    try std.testing.expectEqualStrings("cli-key", resolved.credentials[0].api_key.value);
}

test "resolution uses stored credentials before environment and filters unrelated providers" {
    const stored = [_]Credential{
        .{ .api_key = .{ .provider_id = "unsupported", .value = "ignored" } },
        .{ .openai_codex = .{ .access_token = "" } },
        .{ .api_key = .{ .provider_id = "openai", .value = "stored-key" } },
    };
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .stored_credentials = &stored,
        .openai_environment_api_key = "environment-key",
    });
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 1), resolved.credentials.len);
    try std.testing.expectEqualStrings("stored-key", resolved.credentials[0].api_key.value);
}

test "resolution uses the admitted OpenAI environment value only as fallback" {
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .openai_environment_api_key = "environment-key",
    });
    defer resolved.deinit();
    try std.testing.expectEqualStrings("environment-key", resolved.credentials[0].api_key.value);

    try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .openai_environment_api_key = "openai-only",
    }));
}

test "resolution does not reinterpret OpenAI environment or CLI credentials for custom authentication" {
    const entries = [_]ai_catalog.Entry{.{
        .identity = .{ .provider = "custom", .model = "custom-model" },
        .profile = .{},
    }};
    const catalog: ai_catalog.Catalog = .{ .entries = &entries };
    const api_key_providers = [_]ModelConfig.ProviderDefinition{.{ .openai_completions = .{
        .id = "custom",
        .name = "Custom",
        .base_url = "https://example.test/v1",
        .authentication = .api_key,
    } }};
    const api_key_config = try ModelConfig.init(catalog, &api_key_providers);
    try std.testing.expectError(error.MissingCredential, resolve(std.testing.allocator, .{
        .model_config = api_key_config,
        .requested_provider = "custom",
        .requested_model = "custom-model",
        .openai_environment_api_key = "openai-only",
    }));
    var custom = try resolve(std.testing.allocator, .{
        .model_config = api_key_config,
        .requested_provider = "custom",
        .requested_model = "custom-model",
        .cli_api_key = "custom-key",
    });
    defer custom.deinit();
    try std.testing.expectEqualStrings("custom-key", custom.credentials[0].api_key.value);

    const no_auth_providers = [_]ModelConfig.ProviderDefinition{.{ .openai_completions = .{
        .id = "custom",
        .name = "Custom",
        .base_url = "https://example.test/v1",
        .authentication = .none,
    } }};
    const no_auth_config = try ModelConfig.init(catalog, &no_auth_providers);
    try std.testing.expectError(error.UnsupportedCliCredential, resolve(std.testing.allocator, .{
        .model_config = no_auth_config,
        .requested_provider = "custom",
        .requested_model = "custom-model",
        .cli_api_key = "unneeded",
    }));
}

test "resolution admits already-resolved Codex OAuth without API-key fallback" {
    const stored = [_]Credential{.{ .openai_codex = .{
        .access_token = "codex-token",
        .account_id = "codex-account",
    } }};
    var resolved = try resolve(std.testing.allocator, .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .stored_credentials = &stored,
        .openai_environment_api_key = "openai-only",
    });
    defer resolved.deinit();

    try std.testing.expectEqualStrings("codex-token", resolved.credentials[0].openai_codex.access_token);
    try std.testing.expectEqualStrings("codex-account", resolved.credentials[0].openai_codex.account_id.?);
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

    const invalid_stored = [_]Credential{.{ .api_key = .{
        .provider_id = "openai",
        .value = "",
    } }};
    try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .stored_credentials = &invalid_stored,
        .openai_environment_api_key = "must-not-mask-invalid-stored",
    }));

    const duplicate = [_]Credential{
        .{ .api_key = .{ .provider_id = "openai", .value = "one" } },
        .{ .api_key = .{ .provider_id = "openai", .value = "two" } },
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

    var too_many: [max_credentials + 1]Credential = undefined;
    for (&too_many) |*credential| {
        credential.* = .{ .api_key = .{ .provider_id = "unsupported", .value = "ignored" } };
    }
    try std.testing.expectError(error.InvalidCredential, resolve(std.testing.allocator, .{
        .requested_provider = "openai",
        .requested_model = "gpt-5.6-sol",
        .stored_credentials = &too_many,
        .openai_environment_api_key = "environment-key",
    }));
}

fn resolveAndDeinit(allocator: std.mem.Allocator) !void {
    const stored = [_]Credential{.{ .openai_codex = .{
        .access_token = "codex-token",
        .account_id = "codex-account",
    } }};
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
    const stored = [_]Credential{.{ .openai_codex = .{
        .access_token = "wipe-resolution-token",
        .account_id = "wipe-resolution-account",
    } }};
    var resolved = try resolve(fixed.allocator(), .{
        .requested_provider = "openai-codex",
        .requested_model = "gpt-5.6-terra",
        .stored_credentials = &stored,
    });
    const credential = resolved.credentials[0].openai_codex;
    const secrets = [_][]const u8{ credential.access_token, credential.account_id.? };
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
