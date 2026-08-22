const std = @import("std");
const ai = @import("../ai/root.zig");
const CredentialManager = @import("CredentialManager.zig");
const ModelBootstrapPolicy = @import("ModelBootstrapPolicy.zig");
const ModelConfig = @import("ModelConfig.zig");
const ModelResolution = @import("ModelResolution.zig");
const SessionFormat = @import("SessionFormat.zig");
const ZiPaths = @import("ZiPaths.zig");

const ModelAdmission = @This();

/// Failures produced while turning a bootstrap plan into one admitted runtime
/// model. RuntimeServices.Error is the process-facing superset.
pub const Error = error{
    OutOfMemory,
    Cancelled,
    SelectionRequired,
    IncompleteSelection,
    UnknownSelection,
    MissingCredential,
    InvalidCredential,
    DuplicateCredential,
    UnsupportedCliCredential,
    InvalidModelConfiguration,
    InvalidCredentialFile,
    UnsupportedVersion,
    UnsafeCredentialStorage,
    CredentialReadFailed,
    CredentialLockFailed,
    CredentialWriteFailed,
    CredentialCommitIndeterminate,
    CredentialRefreshUnavailable,
    CredentialRefreshFailed,
};

/// The admission-relevant slice of the process launch inputs.
pub const Request = struct {
    cli_api_key: ?[]const u8 = null,
    environment: ai.auth.Environment = .{},
    sources: SessionFormat.Sources,
};

/// Bounded catalog scan results feeding ModelBootstrapPolicy.plan.
pub const Models = struct {
    available: [ModelBootstrapPolicy.max_available_models]ai.ModelIdentity = undefined,
    available_len: usize = 0,
    scoped: [ModelBootstrapPolicy.max_scoped_models]ai.ModelIdentity = undefined,
    scoped_len: usize = 0,

    pub fn availableItems(self: *const Models) []const ai.ModelIdentity {
        return self.available[0..self.available_len];
    }

    pub fn scopedItems(self: *const Models) []const ai.ModelIdentity {
        return self.scoped[0..self.scoped_len];
    }

    fn appendAvailable(self: *Models, identity: ai.ModelIdentity) bool {
        if (self.available_len == self.available.len) return false;
        self.available[self.available_len] = identity;
        self.available_len += 1;
        return true;
    }

    fn appendScoped(self: *Models, identity: ai.ModelIdentity) Error!void {
        for (self.scopedItems()) |existing| {
            if (sameIdentity(existing, identity)) return;
        }
        if (self.scoped_len == self.scoped.len) return error.InvalidModelConfiguration;
        self.scoped[self.scoped_len] = identity;
        self.scoped_len += 1;
    }
};

/// Probes catalog entries against resolvable auth so the planner only sees
/// models this process could actually run.
pub fn buildModels(
    model_config: ModelConfig,
    enabled_models: ?[]const []const u8,
    stored_credentials: []const ai.credential.Entry,
    environment: ai.auth.Environment,
) Error!Models {
    var result: Models = .{};
    for (model_config.catalog.entries) |entry| {
        _ = ai.Models.resolveAuth(
            model_config.catalog,
            model_config.providers,
            entry.identity,
            .{
                .stored = stored_credentials,
                .environment = environment,
            },
        ) catch continue;
        if (!result.appendAvailable(entry.identity)) break;
    }

    const patterns = enabled_models orelse return result;
    for (patterns) |pattern| {
        if (std.mem.findScalar(u8, pattern, '*') == null) {
            const slash = std.mem.findScalar(u8, pattern, '/') orelse continue;
            if (slash == 0 or slash + 1 == pattern.len) continue;
            const resolved = model_config.resolve(.{
                .provider = pattern[0..slash],
                .model = pattern[slash + 1 ..],
            }) orelse continue;
            if (containsIdentity(result.availableItems(), resolved.entry.identity)) {
                try result.appendScoped(resolved.entry.identity);
            }
            continue;
        }

        // Zi admits '*' over canonical provider/model text. Other minimatch
        // syntax is literal until the catalog needs a wider matching contract.
        for (result.availableItems()) |identity| {
            if (wildcardMatchesIdentity(pattern, identity)) try result.appendScoped(identity);
        }
    }
    return result;
}

/// Attempts plan candidates in order until one admits. An explicit CLI
/// selection is terminal; every other provenance falls through to the next
/// candidate on unavailable credentials or resolution.
pub fn admitPlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    zi_paths: *const ZiPaths,
    transport: ai.transport.Transport,
    model_config: ModelConfig,
    plan: ModelBootstrapPolicy.Plan,
    request: Request,
) Error!ModelResolution.Resolved {
    var index: usize = 0;
    while (index < plan.items().len) {
        const candidate = plan.items()[index];
        const terminal = candidate.provenance == .explicit_cli;
        const admission = try admitCandidate(
            allocator,
            io,
            zi_paths,
            transport,
            model_config,
            candidate.identity,
            request,
            terminal,
        );
        switch (admission) {
            .admitted => |resolved| return resolved,
            .unavailable => {},
        }
        index = plan.nextAfterAdmissionFailure(index) orelse return error.SelectionRequired;
    }
    return error.SelectionRequired;
}

const CandidateAdmission = union(enum) {
    admitted: ModelResolution.Resolved,
    unavailable,
};

fn admitCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    zi_paths: *const ZiPaths,
    transport: ai.transport.Transport,
    model_config: ModelConfig,
    identity: ai.ModelIdentity,
    request: Request,
    terminal: bool,
) Error!CandidateAdmission {
    var stored_credentials = CredentialManager.loadForRuntime(
        allocator,
        io,
        zi_paths,
        transport,
        .{
            .model_config = model_config,
            .selection = identity,
            .explicit_api_key = request.cli_api_key,
            .now_ms = request.sources.nowMsFn(request.sources.clock_context),
        },
    ) catch |failure| {
        if (!terminal and credentialFailureAllowsFallback(failure)) return .unavailable;
        return mapCredentialRuntimeFailure(failure);
    };
    defer stored_credentials.deinit();

    const resolved = ModelResolution.resolve(allocator, .{
        .model_config = model_config,
        .requested_provider = identity.provider,
        .requested_model = identity.model,
        .cli_api_key = request.cli_api_key,
        .stored_credentials = stored_credentials.entries,
        .environment = request.environment,
    }) catch |failure| {
        if (!terminal and resolutionFailureAllowsFallback(failure)) return .unavailable;
        return failure;
    };
    return .{ .admitted = resolved };
}

fn credentialFailureAllowsFallback(failure: CredentialManager.Error) bool {
    return switch (failure) {
        error.InvalidModelConfiguration,
        error.AuthenticationUnavailable,
        error.RefreshUnavailable,
        error.TimedOut,
        error.InvalidUrl,
        error.InvalidRequest,
        error.ConnectionFailed,
        error.InvalidResponse,
        error.ResponseTooLarge,
        error.ConsumerStopped,
        error.Rejected,
        => true,
        else => false,
    };
}

fn resolutionFailureAllowsFallback(failure: ModelResolution.Error) bool {
    return switch (failure) {
        error.SelectionRequired,
        error.IncompleteSelection,
        error.UnknownSelection,
        error.MissingCredential,
        error.InvalidCredential,
        error.DuplicateCredential,
        error.UnsupportedCliCredential,
        => true,
        else => false,
    };
}

fn mapCredentialRuntimeFailure(failure: CredentialManager.Error) Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCredentialFile => error.InvalidCredentialFile,
        error.UnsupportedVersion => error.UnsupportedVersion,
        error.UnsafePath => error.UnsafeCredentialStorage,
        error.ReadFailed => error.CredentialReadFailed,
        error.LockFailed => error.CredentialLockFailed,
        error.WriteFailed => error.CredentialWriteFailed,
        error.CommitIndeterminate => error.CredentialCommitIndeterminate,
        error.InvalidModelConfiguration => error.InvalidModelConfiguration,
        error.AuthenticationUnavailable,
        error.RefreshUnavailable,
        => error.CredentialRefreshUnavailable,
        error.Cancelled => error.Cancelled,
        error.Rejected,
        error.InvalidResponse,
        error.TimedOut,
        error.InvalidUrl,
        error.InvalidRequest,
        error.ConnectionFailed,
        error.ResponseTooLarge,
        error.ConsumerStopped,
        => error.CredentialRefreshFailed,
    };
}

fn wildcardMatchesIdentity(pattern: []const u8, identity: ai.ModelIdentity) bool {
    const text_len = identity.provider.len + 1 + identity.model.len;
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_index: ?usize = null;
    var star_text_index: usize = 0;

    while (text_index < text_len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_text_index = text_index;
        } else if (pattern_index < pattern.len and
            pattern[pattern_index] == identityByte(identity, text_index))
        {
            pattern_index += 1;
            text_index += 1;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            star_text_index += 1;
            text_index = star_text_index;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn identityByte(identity: ai.ModelIdentity, index: usize) u8 {
    if (index < identity.provider.len) return identity.provider[index];
    if (index == identity.provider.len) return '/';
    return identity.model[index - identity.provider.len - 1];
}

fn containsIdentity(identities: []const ai.ModelIdentity, wanted: ai.ModelIdentity) bool {
    for (identities) |identity| {
        if (sameIdentity(identity, wanted)) return true;
    }
    return false;
}

fn sameIdentity(left: ai.ModelIdentity, right: ai.ModelIdentity) bool {
    return std.mem.eql(u8, left.provider, right.provider) and
        std.mem.eql(u8, left.model, right.model);
}

test "enabled model scope admits exact aliases and star wildcards in settings order" {
    const stored = [_]ai.credential.Entry{
        .{
            .provider_id = "openai",
            .credential = .{ .api_key = .{ .key = "openai-key" } },
        },
        .{
            .provider_id = "openai-codex",
            .credential = .{ .oauth = .{
                .access = "codex-access",
                .refresh = "codex-refresh",
                .expires_at_ms = 1,
            } },
        },
    };
    const patterns = [_][]const u8{
        "openai-codex/gpt-5.4*",
        "openai/gpt-5.6",
        "openai-codex/gpt-5.4",
        "openai-codex/gpt-5.?",
    };
    const models = try buildModels(
        ModelConfig.builtin,
        &patterns,
        &stored,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 3), models.scopedItems().len);
    try std.testing.expectEqualStrings("gpt-5.4", models.scopedItems()[0].model);
    try std.testing.expectEqualStrings("gpt-5.4-mini", models.scopedItems()[1].model);
    try std.testing.expectEqualStrings("gpt-5.6-sol", models.scopedItems()[2].model);
}
