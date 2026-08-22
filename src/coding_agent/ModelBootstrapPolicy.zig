const std = @import("std");
const ai = @import("../ai/root.zig");

const ModelBootstrapPolicy = @This();

pub const max_scoped_models: usize = 256;
pub const max_available_models: usize = 256;

pub const SessionState = enum {
    fresh,
    existing,
};

/// The process edge records whether an explicit selection was complete without
/// passing raw command-line state through the bootstrap policy.
pub const ExplicitSelection = union(enum) {
    absent,
    complete: ai.ModelIdentity,
    provider_only,
    model_only,
};

pub const ProviderDefault = enum {
    openai,
    openai_codex,
};

pub const ProviderDefaultPreference = struct {
    provider: ProviderDefault,
    identity: ai.ModelIdentity,
};

// Provenance: pi-mono packages/coding-agent/src/core/model-resolver.ts,
// findInitialModel. These are Zi's current built-in provider preferences.
pub const provider_default_preferences = [_]ProviderDefaultPreference{
    .{ .provider = .openai, .identity = .{ .provider = "openai", .model = "gpt-5.6-sol" } },
    .{ .provider = .openai_codex, .identity = .{ .provider = "openai-codex", .model = "gpt-5.6-terra" } },
};

pub const max_plan_candidates: usize = provider_default_preferences.len + 4;

pub const Provenance = union(enum) {
    explicit_cli,
    fresh_scope,
    restored_session,
    settings_default,
    provider_default: ProviderDefault,
    first_available,
};

pub const Candidate = struct {
    identity: ai.ModelIdentity,
    provenance: Provenance,
};

/// A fixed-capacity, borrowed plan. Identity bytes remain owned by the caller.
pub const Plan = struct {
    candidates: [max_plan_candidates]Candidate = undefined,
    len: usize = 0,

    pub fn items(self: *const Plan) []const Candidate {
        return self.candidates[0..self.len];
    }

    /// Returns null for an explicit selection, because its admission failure is
    /// terminal. Other candidates allow the caller to attempt the next source.
    pub fn nextAfterAdmissionFailure(self: *const Plan, index: usize) ?usize {
        if (index >= self.len or self.candidates[index].provenance == .explicit_cli) return null;
        const next = index + 1;
        return if (next < self.len) next else null;
    }

    fn appendUnique(self: *Plan, candidate: Candidate) Error!void {
        for (self.items()) |existing| {
            if (identitiesEqual(existing.identity, candidate.identity)) return;
        }
        if (self.len == self.candidates.len) return error.TooManyCandidates;
        self.candidates[self.len] = candidate;
        self.len += 1;
    }
};

pub const Inputs = struct {
    session_state: SessionState,
    explicit: ExplicitSelection = .absent,
    fresh_scoped_models: []const ai.ModelIdentity = &.{},
    restored_model: ?ai.ModelIdentity = null,
    effective_settings_default: ?ai.ModelIdentity = null,
    available_models: []const ai.ModelIdentity = &.{},
};

pub const Error = error{
    IncompleteExplicitSelection,
    TooManyScopedModels,
    TooManyAvailableModels,
    TooManyCandidates,
};

/// Produces the pure selection order. Candidate admission, including strict
/// ModelResolution and credentials, belongs to the caller.
pub fn plan(inputs: Inputs) Error!Plan {
    if (inputs.fresh_scoped_models.len > max_scoped_models) return error.TooManyScopedModels;
    if (inputs.available_models.len > max_available_models) return error.TooManyAvailableModels;

    var result: Plan = .{};
    switch (inputs.explicit) {
        .absent => {},
        .provider_only, .model_only => return error.IncompleteExplicitSelection,
        .complete => |selection| {
            try result.appendUnique(.{ .identity = selection, .provenance = .explicit_cli });
            return result;
        },
    }

    if (inputs.session_state == .fresh and inputs.fresh_scoped_models.len > 0) {
        try result.appendUnique(.{
            .identity = inputs.fresh_scoped_models[0],
            .provenance = .fresh_scope,
        });
    }
    if (inputs.restored_model) |restored| {
        try result.appendUnique(.{ .identity = restored, .provenance = .restored_session });
    }
    if (inputs.effective_settings_default) |settings_default| {
        try result.appendUnique(.{ .identity = settings_default, .provenance = .settings_default });
    }
    for (provider_default_preferences) |preference| {
        if (!containsIdentity(inputs.available_models, preference.identity)) continue;
        try result.appendUnique(.{
            .identity = preference.identity,
            .provenance = .{ .provider_default = preference.provider },
        });
    }
    if (inputs.available_models.len > 0) {
        try result.appendUnique(.{
            .identity = inputs.available_models[0],
            .provenance = .first_available,
        });
    }
    return result;
}

fn containsIdentity(identities: []const ai.ModelIdentity, wanted: ai.ModelIdentity) bool {
    for (identities) |candidate| {
        if (identitiesEqual(candidate, wanted)) return true;
    }
    return false;
}

fn identitiesEqual(left: ai.ModelIdentity, right: ai.ModelIdentity) bool {
    return std.mem.eql(u8, left.provider, right.provider) and std.mem.eql(u8, left.model, right.model);
}

fn identity(provider: []const u8, model: []const u8) ai.ModelIdentity {
    return .{ .provider = provider, .model = model };
}

fn expectCandidate(candidate: Candidate, expected: ai.ModelIdentity, provenance: Provenance) !void {
    try std.testing.expect(identitiesEqual(candidate.identity, expected));
    try std.testing.expectEqual(provenance, candidate.provenance);
}

test "complete explicit CLI selection is the only terminal bootstrap candidate" {
    const scoped = [_]ai.ModelIdentity{identity("scope", "model")};
    const available = [_]ai.ModelIdentity{identity("openai", "gpt-5.6-sol")};
    const result = try plan(.{
        .session_state = .fresh,
        .explicit = .{ .complete = identity("cli", "model") },
        .fresh_scoped_models = &scoped,
        .restored_model = identity("restored", "model"),
        .effective_settings_default = identity("settings", "model"),
        .available_models = &available,
    });

    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try expectCandidate(result.items()[0], identity("cli", "model"), .explicit_cli);
    try std.testing.expect(result.nextAfterAdmissionFailure(0) == null);
}

test "partial explicit CLI selection is rejected" {
    for ([_]ExplicitSelection{ .provider_only, .model_only }) |explicit| {
        try std.testing.expectError(error.IncompleteExplicitSelection, plan(.{
            .session_state = .fresh,
            .explicit = explicit,
        }));
    }
}

test "fresh sessions prefer the first scoped model" {
    const scoped = [_]ai.ModelIdentity{
        identity("scope", "first"),
        identity("scope", "second"),
    };
    const available = [_]ai.ModelIdentity{identity("openai", "gpt-5.6-sol")};
    const result = try plan(.{
        .session_state = .fresh,
        .fresh_scoped_models = &scoped,
        .restored_model = identity("restored", "model"),
        .effective_settings_default = identity("settings", "model"),
        .available_models = &available,
    });

    try expectCandidate(result.items()[0], scoped[0], .fresh_scope);
    try expectCandidate(result.items()[1], identity("restored", "model"), .restored_session);
}

test "existing sessions skip fresh scope and restore before settings" {
    const scoped = [_]ai.ModelIdentity{identity("scope", "model")};
    const result = try plan(.{
        .session_state = .existing,
        .fresh_scoped_models = &scoped,
        .restored_model = identity("restored", "model"),
        .effective_settings_default = identity("settings", "model"),
    });

    try std.testing.expectEqual(@as(usize, 2), result.items().len);
    try expectCandidate(result.items()[0], identity("restored", "model"), .restored_session);
    try expectCandidate(result.items()[1], identity("settings", "model"), .settings_default);
}

test "effective settings default precedes provider defaults and first available" {
    const available = [_]ai.ModelIdentity{
        identity("other", "first"),
        identity("openai", "gpt-5.6-sol"),
    };
    const result = try plan(.{
        .session_state = .fresh,
        .effective_settings_default = identity("settings", "model"),
        .available_models = &available,
    });

    try expectCandidate(result.items()[0], identity("settings", "model"), .settings_default);
    try expectCandidate(
        result.items()[1],
        identity("openai", "gpt-5.6-sol"),
        .{ .provider_default = .openai },
    );
    try expectCandidate(result.items()[2], available[0], .first_available);
}

test "provider defaults use Zi's deterministic preference order" {
    const available = [_]ai.ModelIdentity{
        identity("custom", "first"),
        identity("openai-codex", "gpt-5.6-terra"),
        identity("openai", "gpt-5.6-sol"),
    };
    const result = try plan(.{ .session_state = .fresh, .available_models = &available });

    try expectCandidate(
        result.items()[0],
        identity("openai", "gpt-5.6-sol"),
        .{ .provider_default = .openai },
    );
    try expectCandidate(
        result.items()[1],
        identity("openai-codex", "gpt-5.6-terra"),
        .{ .provider_default = .openai_codex },
    );
    try expectCandidate(result.items()[2], available[0], .first_available);
}

test "first available model is used when no provider default is available" {
    const available = [_]ai.ModelIdentity{identity("custom", "model")};
    const result = try plan(.{ .session_state = .fresh, .available_models = &available });

    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try expectCandidate(result.items()[0], available[0], .first_available);
    try std.testing.expect(result.nextAfterAdmissionFailure(0) == null);
}

test "duplicate identities retain their first provenance" {
    const repeated = identity("openai", "gpt-5.6-sol");
    const available = [_]ai.ModelIdentity{ repeated, identity("openai-codex", "gpt-5.6-terra") };
    const result = try plan(.{
        .session_state = .fresh,
        .fresh_scoped_models = &.{repeated},
        .restored_model = repeated,
        .effective_settings_default = repeated,
        .available_models = &available,
    });

    try std.testing.expectEqual(@as(usize, 2), result.items().len);
    try expectCandidate(result.items()[0], repeated, .fresh_scope);
    try expectCandidate(
        result.items()[1],
        identity("openai-codex", "gpt-5.6-terra"),
        .{ .provider_default = .openai_codex },
    );
}

test "absent candidates produce no model" {
    const result = try plan(.{ .session_state = .existing });
    try std.testing.expectEqual(@as(usize, 0), result.items().len);
    try std.testing.expect(result.nextAfterAdmissionFailure(0) == null);
}

test "candidate inputs and output plan are bounded" {
    var too_many_scoped: [max_scoped_models + 1]ai.ModelIdentity = undefined;
    try std.testing.expectError(error.TooManyScopedModels, plan(.{
        .session_state = .fresh,
        .fresh_scoped_models = &too_many_scoped,
    }));

    var too_many_available: [max_available_models + 1]ai.ModelIdentity = undefined;
    try std.testing.expectError(error.TooManyAvailableModels, plan(.{
        .session_state = .fresh,
        .available_models = &too_many_available,
    }));

    const scoped = [_]ai.ModelIdentity{identity("scope", "model")};
    const available = [_]ai.ModelIdentity{
        identity("custom", "first"),
        identity("openai", "gpt-5.6-sol"),
        identity("openai-codex", "gpt-5.6-terra"),
    };
    const result = try plan(.{
        .session_state = .fresh,
        .fresh_scoped_models = &scoped,
        .restored_model = identity("restored", "model"),
        .effective_settings_default = identity("settings", "model"),
        .available_models = &available,
    });
    try std.testing.expectEqual(max_plan_candidates, result.items().len);
}
