const std = @import("std");
const Args = @import("Args.zig");
const ProcessAdapters = @import("ProcessAdapters.zig");
const config = @import("../config/root.zig");

const StartupConfig = @This();

pub const maximum_warnings: usize = 128;
pub const maximum_warning_bytes: usize = 64 * 1024;

pub const FileAccess = struct {
    secure_open: config.SecureOpen.Capability,
    home: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

pub const PrepareInputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path_inputs: config.Loader.PathInputs,
    /// Explicit file access. The config prompt root is derived from the
    /// Loader-owned config path and cannot be supplied independently.
    file_access: FileAccess,
    /// Must remain alive, immutable, and address-stable until the final
    /// Owner.deinit. Environment values borrowed during prepare must not be
    /// mutated before finish.
    environment: *const ProcessAdapters.Environment,
    /// String fields are borrowed through finish. The resulting overlays own
    /// the bytes they retain.
    selection: Args.Selection = .{},
    strict_one_shot: bool = false,
    /// Its erased context must remain alive, immutable, and address-stable
    /// until Owner.deinit and across every Store call.
    provider_canonicalizer: ?config.Store.ProviderCanonicalizer = null,
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path_inputs: config.Loader.PathInputs,
    file_access: FileAccess,
    environment: *const ProcessAdapters.Environment,
    selection: Args.Selection = .{},
    resumed: ?config.Selection.RestoreMetadata = null,
    strict_one_shot: bool = false,
    provider_canonicalizer: ?config.Store.ProviderCanonicalizer = null,
};

pub const DiagnosticContext = enum { explicit, recorded };

pub const PresetIssue = union(enum) {
    missing,
    invalid: config.Preset.InvalidReason,
    mismatched,
};

/// Move-only preset failure payload. All text is owned and wiped at deinit.
pub const PresetDiagnostic = struct {
    context: DiagnosticContext,
    name: []u8,
    issue: PresetIssue,
    field: ?[]u8 = null,
    actual: ?[]u8 = null,
    append_session_hint: bool = false,

    pub fn deinit(self: *PresetDiagnostic, allocator: std.mem.Allocator) void {
        wipeFree(allocator, self.name);
        if (self.field) |field| wipeFree(allocator, field);
        if (self.actual) |actual| wipeFree(allocator, actual);
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidPath,
    PathTooLong,
    TooManyPresets,
    TooManyDefinitions,
    TooManyWarnings,
    RetainedDataTooLarge,
    WarningDataTooLarge,
    TooLarge,
    Invalid,
};

pub const WarningKind = enum {
    config_unusable,
    state_unusable,
    recorded_preset_missing,
    recorded_preset_invalid,
    recorded_preset_mismatched,
    implicit_preset_missing,
    implicit_preset_invalid,
};

/// Owned warning. `subject` is a tier path or preset name.
pub const Warning = struct {
    kind: WarningKind,
    subject: []u8,
    tier_outcome: ?config.Loader.Outcome = null,
    preset_reason: ?config.Preset.InvalidReason = null,
    field: ?[]u8 = null,
    actual: ?[]u8 = null,

    fn deinit(self: *Warning, allocator: std.mem.Allocator) void {
        wipeFree(allocator, self.subject);
        if (self.field) |field| wipeFree(allocator, field);
        if (self.actual) |actual| wipeFree(allocator, actual);
        self.* = undefined;
    }
};

const StartupFacts = struct {
    cli: Args.Selection,
    env_provider: ?[]const u8,
    env_model: ?[]const u8,
    env_effort: ?[]const u8,
    env_preset: ?[]const u8,
    env_system_prompt: ?[]const u8,
    strict_one_shot: bool,
};

const State = struct {
    allocator: std.mem.Allocator,
    tiers: config.Loader.InitialTiers,
    base: config.Store.Options,
    facts: StartupFacts,
    selection: config.Selection,
    presets: config.Preset.Enumeration,
    providers: config.ProviderDefinitions.Enumeration,
    warnings: []Warning,
};

fn deinitState(state: *State) void {
    const allocator = state.allocator;
    for (state.warnings) |*warning| warning.deinit(allocator);
    allocator.free(state.warnings);
    state.providers.deinit();
    state.presets.deinit(allocator);
    state.selection.deinit();
    deinitTiersSecure(allocator, &state.tiers);
    state.* = undefined;
    allocator.destroy(state);
}

/// Move-only, heap-stable snapshot produced by prepare. Copying this handle is
/// invalid. On finish success (including a fatal result) it is consumed. On an
/// error it remains owned by the caller and must be deinitialized.
pub const Prepared = struct {
    state: *State,

    pub fn deinit(self: *Prepared) void {
        deinitState(self.state);
        self.* = undefined;
    }

    /// Borrows Prepared. The Store and every view returned from it are valid
    /// only until finish, deinit, or another mutation of this Prepared.
    pub fn storeBeforeResume(self: *const Prepared) config.Store {
        return self.state.selection.store();
    }
};

/// Move-only handle to heap-stable startup state. Copying the handle and
/// deinitializing both copies is invalid.
pub const Owner = struct {
    state: *State,

    pub fn deinit(self: *Owner) void {
        deinitState(self.state);
        self.* = undefined;
    }

    pub fn store(self: *const Owner) config.Store {
        return self.state.selection.store();
    }

    pub fn prepareRun(
        self: *const Owner,
        change: config.Selection.RunChange,
    ) config.Selection.Error!config.Selection.PreparedRun {
        return self.state.selection.prepareRun(change);
    }

    pub fn publishRun(self: *Owner, prepared: *config.Selection.PreparedRun) void {
        self.state.selection.publishRun(prepared);
    }

    pub fn presetPlans(self: *const Owner) []const config.Preset.Plan {
        return self.state.presets.plans;
    }

    pub fn invalidPresets(self: *const Owner) []const config.Preset.Invalid {
        return self.state.presets.invalid;
    }

    pub fn providerDefinitions(self: *const Owner) []const config.ProviderDefinitions.Definition {
        return self.state.providers.definitions;
    }

    pub fn providerWarnings(self: *const Owner) []const config.ProviderDefinitions.Warning {
        return self.state.providers.warnings;
    }

    pub fn warnings(self: *const Owner) []const Warning {
        return self.state.warnings;
    }

    pub fn configResult(self: *const Owner) ?*const config.Loader.Result {
        return if (self.state.tiers.config) |*result| result else null;
    }

    pub fn stateResult(self: *const Owner) ?*const config.Loader.Result {
        return if (self.state.tiers.state) |*result| result else null;
    }

    pub fn configUnusable(self: *const Owner) bool {
        return self.state.tiers.config_unusable;
    }

    pub fn tint(self: *const Owner) ?[]const u8 {
        return self.state.selection.presetTint();
    }
};

pub const InitResult = union(enum) {
    owner: Owner,
    fatal: PresetDiagnostic,
};

const WarningBuilder = struct {
    items: std.ArrayList(Warning) = .empty,
    retained_bytes: usize = 0,

    fn deinit(self: *WarningBuilder, allocator: std.mem.Allocator) void {
        for (self.items.items) |*warning| warning.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    fn append(
        self: *WarningBuilder,
        allocator: std.mem.Allocator,
        kind: WarningKind,
        subject: []const u8,
        outcome: ?config.Loader.Outcome,
    ) Error!void {
        if (self.items.items.len == maximum_warnings) return error.TooManyWarnings;
        const next = std.math.add(usize, self.retained_bytes, subject.len) catch
            return error.WarningDataTooLarge;
        if (next > maximum_warning_bytes) return error.WarningDataTooLarge;
        const owned = try allocator.dupe(u8, subject);
        errdefer {
            std.crypto.secureZero(u8, owned);
            allocator.free(owned);
        }
        try self.items.append(allocator, .{
            .kind = kind,
            .subject = owned,
            .tier_outcome = outcome,
        });
        self.retained_bytes = next;
    }

    fn appendPreset(
        self: *WarningBuilder,
        allocator: std.mem.Allocator,
        kind: WarningKind,
        name: []const u8,
        reason: ?config.Preset.InvalidReason,
        field: ?[]const u8,
        actual: ?[]const u8,
    ) Error!void {
        const extra = (if (field) |value| value.len else 0) + (if (actual) |value| value.len else 0);
        const with_name = std.math.add(usize, self.retained_bytes, name.len) catch
            return error.WarningDataTooLarge;
        const next = std.math.add(usize, with_name, extra) catch return error.WarningDataTooLarge;
        if (next > maximum_warning_bytes) return error.WarningDataTooLarge;
        const owned_field = if (field) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_field) |value| wipeFree(allocator, value);
        const owned_actual = if (actual) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_actual) |value| wipeFree(allocator, value);
        try self.append(allocator, kind, name, null);
        const warning = &self.items.items[self.items.items.len - 1];
        warning.preset_reason = reason;
        warning.field = owned_field;
        warning.actual = owned_actual;
        self.retained_bytes = next;
    }
};

/// Loads the persistent files, presets, and provider definitions exactly once.
/// The returned snapshot owns all loaded data. Input strings remain borrowed
/// through finish; Store collaborators retain the lifetimes documented above.
pub fn prepare(inputs: PrepareInputs) Error!Prepared {
    const state = try inputs.allocator.create(State);
    errdefer inputs.allocator.destroy(state);

    state.allocator = inputs.allocator;
    state.tiers = try config.Loader.loadInitialTiers(
        inputs.allocator,
        inputs.io,
        inputs.file_access.secure_open,
        inputs.path_inputs,
    );
    var tiers_owned = true;
    errdefer if (tiers_owned) deinitTiersSecure(inputs.allocator, &state.tiers);

    var warning_builder: WarningBuilder = .{};
    defer warning_builder.deinit(inputs.allocator);
    if (state.tiers.config) |result| if (result.outcome.isUnusable()) try warning_builder.append(
        inputs.allocator,
        .config_unusable,
        result.path,
        result.outcome,
    );
    if (state.tiers.state) |result| if (result.outcome.isUnusable()) try warning_builder.append(
        inputs.allocator,
        .state_unusable,
        result.path,
        result.outcome,
    );

    const documents = persistentDocuments(&state.tiers);
    const prompt_roots: config.Preset.PromptRoots = .{
        .secure_open = inputs.file_access.secure_open,
        .config_root = if (state.tiers.config) |result| std.fs.path.dirname(result.path) else null,
        .home = inputs.file_access.home,
        .cwd = inputs.file_access.cwd,
    };
    var presets = try config.Preset.enumerate(inputs.allocator, inputs.io, documents, prompt_roots);
    errdefer presets.deinit(inputs.allocator);
    var providers = try config.ProviderDefinitions.enumerate(inputs.allocator, .{
        .config = documents.config,
        .state = documents.state,
    });
    errdefer providers.deinit();

    const base: config.Store.Options = .{
        .file = documents.config,
        .state = documents.state,
        .registry = config.Settings.storeRegistry(),
        .environment = inputs.environment.store(),
        .provider_canonicalizer = inputs.provider_canonicalizer,
    };
    const facts: StartupFacts = .{
        .cli = inputs.selection,
        .env_provider = inputs.environment.get("HAX_PROVIDER"),
        .env_model = inputs.environment.get("HAX_MODEL"),
        .env_effort = inputs.environment.get("HAX_EFFORT"),
        .env_preset = inputs.environment.get("HAX_PRESET"),
        .env_system_prompt = inputs.environment.get("HAX_SYSTEM_PROMPT"),
        .strict_one_shot = inputs.strict_one_shot,
    };
    var selection = config.Selection.init(inputs.allocator, base);
    errdefer selection.deinit();
    try composeProvisional(inputs.allocator, facts, &presets, &selection);
    const warnings = try warning_builder.items.toOwnedSlice(inputs.allocator);

    state.base = base;
    state.facts = facts;
    state.selection = selection;
    state.presets = presets;
    state.providers = providers;
    state.warnings = warnings;
    warning_builder = .{};
    tiers_owned = false;
    selection = undefined;
    presets = undefined;
    providers = undefined;
    return .{ .state = state };
}

/// Consumes Prepared on either successful Owner construction or a fatal preset
/// result. If an error is returned, Prepared is unchanged and remains owned by
/// the caller. No files or environment values are read by this function.
pub fn finish(
    prepared: *Prepared,
    resumed: ?config.Selection.RestoreMetadata,
) Error!InitResult {
    const state = prepared.state;
    const allocator = state.allocator;
    var selection = config.Selection.init(allocator, state.base);
    errdefer selection.deinit();
    var warnings: WarningBuilder = .{};
    defer warnings.deinit(allocator);
    try cloneWarnings(allocator, &warnings, state.warnings);

    if (try composeFinal(allocator, state.facts, &state.presets, resumed, &selection, &warnings)) |diagnostic| {
        selection.deinit();
        deinitState(state);
        prepared.* = undefined;
        return .{ .fatal = diagnostic };
    }
    const owned_warnings = try warnings.items.toOwnedSlice(allocator);
    errdefer {
        for (owned_warnings) |*warning| warning.deinit(allocator);
        allocator.free(owned_warnings);
    }
    // filterReportedInvalid allocates before it mutates, and cannot fail after
    // publishing the replacement slice.
    try filterReportedInvalid(allocator, &state.presets, owned_warnings);

    state.selection.deinit();
    for (state.warnings) |*warning| warning.deinit(allocator);
    allocator.free(state.warnings);
    state.selection = selection;
    state.warnings = owned_warnings;
    warnings = .{};
    selection = undefined;
    prepared.* = undefined;
    return .{ .owner = .{ .state = state } };
}

/// Compatibility wrapper around the two-phase API.
pub fn init(inputs: Inputs) Error!InitResult {
    var prepared = try prepare(.{
        .allocator = inputs.allocator,
        .io = inputs.io,
        .path_inputs = inputs.path_inputs,
        .file_access = inputs.file_access,
        .environment = inputs.environment,
        .selection = inputs.selection,
        .strict_one_shot = inputs.strict_one_shot,
        .provider_canonicalizer = inputs.provider_canonicalizer,
    });
    return finish(&prepared, inputs.resumed) catch |err| {
        prepared.deinit();
        return err;
    };
}

fn startupDecision(facts: StartupFacts, effective: ?config.Store.Result) config.Selection.Decision {
    return config.Selection.startupDecision(.{
        .cli_provider = facts.cli.provider,
        .cli_model = facts.cli.model,
        .cli_effort = facts.cli.effort,
        .cli_preset = facts.cli.preset,
        .env_provider = facts.env_provider,
        .env_model = facts.env_model,
        .env_effort = facts.env_effort,
        .env_preset = facts.env_preset,
        .env_system_prompt = facts.env_system_prompt,
        .effective_preset = if (effective) |value| value.value else null,
        .effective_preset_from_conversation = if (effective) |value| value.source == .conversation else false,
    });
}

fn composeProvisional(
    allocator: std.mem.Allocator,
    facts: StartupFacts,
    presets: *const config.Preset.Enumeration,
    selection: *config.Selection,
) Error!void {
    var effective = try selection.store().read(allocator, "preset");
    defer effective.deinit(allocator);
    const decision = startupDecision(facts, effective);
    if (decision.run_preset) |name| {
        if (name.len != 0) try applyCachedProvisional(selection, presets, name, true);
    } else if (effective.value) |name| {
        if (name.len != 0) {
            if (decision.suppress_lower_preset) {
                try selection.exitPreset(.run);
            } else {
                try applyCachedProvisional(selection, presets, name, false);
            }
        }
    }
    try selection.setRun(.{
        .provider = facts.cli.provider,
        .model = facts.cli.model,
        .effort = facts.cli.effort,
    });
}

fn composeFinal(
    allocator: std.mem.Allocator,
    facts: StartupFacts,
    presets: *const config.Preset.Enumeration,
    resumed: ?config.Selection.RestoreMetadata,
    selection: *config.Selection,
    warnings: *WarningBuilder,
) Error!?PresetDiagnostic {
    const initial_decision = startupDecision(facts, null);
    if (resumed) |metadata| {
        var restored_metadata = metadata;
        if (!initial_decision.restore_resumed_preset) restored_metadata.preset = null;
        var lookup_value: config.Preset.Lookup = cachedLookup(presets, restored_metadata.preset orelse "");
        const lookup = if (restored_metadata.preset) |name| if (name.len != 0) &lookup_value else null else null;
        const outcome = try selection.restoreConversation(restored_metadata, lookup);
        if (try handleRestoreOutcomeFacts(
            allocator,
            facts.strict_one_shot,
            warnings,
            restored_metadata.preset,
            outcome,
            lookup,
        )) |diagnostic| return diagnostic;
    }

    var effective = try selection.store().read(allocator, "preset");
    defer effective.deinit(allocator);
    const decision = startupDecision(facts, effective);
    if (decision.run_preset) |name| {
        if (name.len != 0) if (try applyCachedPreset(
            allocator,
            presets,
            selection,
            name,
            true,
            warnings,
        )) |diagnostic| return diagnostic;
    } else if (effective.value) |name| {
        if (name.len != 0 and effective.source != .conversation) {
            if (decision.suppress_lower_preset) {
                try selection.exitPreset(.run);
            } else if (try applyCachedPreset(
                allocator,
                presets,
                selection,
                name,
                false,
                warnings,
            )) |diagnostic| return diagnostic;
        }
    }
    try selection.setRun(.{
        .provider = facts.cli.provider,
        .model = facts.cli.model,
        .effort = facts.cli.effort,
    });
    return null;
}

fn cloneWarnings(
    allocator: std.mem.Allocator,
    destination: *WarningBuilder,
    source: []const Warning,
) Error!void {
    for (source) |warning| switch (warning.kind) {
        .config_unusable, .state_unusable => try destination.append(
            allocator,
            warning.kind,
            warning.subject,
            warning.tier_outcome,
        ),
        else => try destination.appendPreset(
            allocator,
            warning.kind,
            warning.subject,
            warning.preset_reason,
            warning.field,
            warning.actual,
        ),
    };
}

/// Returns a borrowed lookup view. It must never be deinitialized.
fn cachedLookup(
    presets: *const config.Preset.Enumeration,
    name: []const u8,
) config.Preset.Lookup {
    for (presets.plans) |plan| {
        if (std.mem.eql(u8, plan.name, name)) return .{ .plan = plan };
    }
    for (presets.invalid) |invalid| {
        if (std.mem.eql(u8, invalid.name, name)) return .{ .invalid = invalid };
    }
    return .missing;
}

fn applyCachedProvisional(
    selection: *config.Selection,
    presets: *const config.Preset.Enumeration,
    name: []const u8,
    explicit: bool,
) Error!void {
    var lookup = cachedLookup(presets, name);
    switch (lookup) {
        .plan => |*plan| try selection.applyPreset(.run, plan),
        .missing, .invalid => if (!explicit) try selection.exitPreset(.run),
    }
}

fn applyCachedPreset(
    allocator: std.mem.Allocator,
    presets: *const config.Preset.Enumeration,
    selection: *config.Selection,
    name: []const u8,
    explicit: bool,
    warnings: *WarningBuilder,
) Error!?PresetDiagnostic {
    var lookup = cachedLookup(presets, name);
    switch (lookup) {
        .plan => |*plan| {
            try selection.applyPreset(.run, plan);
            return null;
        },
        .missing => if (explicit) {
            return makeOptionalDiagnostic(allocator, .explicit, name, .missing, null, null, false);
        } else {
            try warnings.appendPreset(allocator, .implicit_preset_missing, name, null, null, null);
            try selection.exitPreset(.run);
            return null;
        },
        .invalid => |invalid| if (explicit) {
            return makeOptionalDiagnostic(
                allocator,
                .explicit,
                name,
                .{ .invalid = invalid.reason },
                invalid.field,
                null,
                false,
            );
        } else {
            try warnings.appendPreset(
                allocator,
                .implicit_preset_invalid,
                name,
                invalid.reason,
                invalid.field,
                null,
            );
            try selection.exitPreset(.run);
            return null;
        },
    }
}

fn handleRestoreOutcomeFacts(
    allocator: std.mem.Allocator,
    strict_one_shot: bool,
    warnings: *WarningBuilder,
    recorded: ?[]const u8,
    outcome: config.Selection.RestoreOutcome,
    lookup: ?*const config.Preset.Lookup,
) Error!?PresetDiagnostic {
    const name = recorded orelse "";
    if (outcome == .restored or outcome == .no_preset) return null;
    const details = presetDetails(outcome, lookup);
    if (strict_one_shot) return makeOptionalDiagnostic(
        allocator,
        .recorded,
        name,
        details.issue,
        details.field,
        details.actual,
        true,
    );
    const kind: WarningKind = switch (outcome) {
        .missing_preset => .recorded_preset_missing,
        .invalid_preset => .recorded_preset_invalid,
        .mismatched_preset => .recorded_preset_mismatched,
        else => unreachable,
    };
    try warnings.appendPreset(
        allocator,
        kind,
        name,
        switch (details.issue) {
            .invalid => |reason| reason,
            else => null,
        },
        details.field,
        details.actual,
    );
    return null;
}

fn deinitTiersSecure(allocator: std.mem.Allocator, tiers: *config.Loader.InitialTiers) void {
    if (tiers.config) |*result| if (result.document) |*document| wipeValue(&document.parsed.value);
    if (tiers.state) |*result| if (result.document) |*document| wipeValue(&document.parsed.value);
    tiers.deinit(allocator);
}

fn wipeValue(value: *std.json.Value) void {
    switch (value.*) {
        .string => |bytes| std.crypto.secureZero(u8, @constCast(bytes)),
        .array => |*array| for (array.items) |*item| wipeValue(item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| wipeValue(entry.value_ptr);
        },
        else => {},
    }
}

fn persistentDocuments(tiers: *const config.Loader.InitialTiers) config.Preset.Documents {
    return .{
        .config = if (tiers.config) |*result| if (result.document) |*document| document else null else null,
        .state = if (tiers.state) |*result| if (result.document) |*document| document else null else null,
    };
}

const PresetDetails = struct {
    issue: PresetIssue,
    field: ?[]const u8 = null,
    actual: ?[]const u8 = null,
};

fn presetDetails(
    outcome: config.Selection.RestoreOutcome,
    lookup: ?*const config.Preset.Lookup,
) PresetDetails {
    return switch (outcome) {
        .missing_preset => .{ .issue = .missing },
        .invalid_preset => if (lookup) |value| switch (value.*) {
            .invalid => |invalid| .{
                .issue = .{ .invalid = invalid.reason },
                .field = invalid.field,
            },
            else => .{ .issue = .{ .invalid = .not_object } },
        } else .{ .issue = .{ .invalid = .not_object } },
        .mismatched_preset => if (lookup) |value| switch (value.*) {
            .plan => |plan| .{ .issue = .mismatched, .actual = plan.name },
            else => .{ .issue = .mismatched },
        } else .{ .issue = .mismatched },
        else => unreachable,
    };
}

fn makeOptionalDiagnostic(
    allocator: std.mem.Allocator,
    context: DiagnosticContext,
    name: []const u8,
    issue: PresetIssue,
    field: ?[]const u8,
    actual: ?[]const u8,
    append_session_hint: bool,
) Error!?PresetDiagnostic {
    const diagnostic = try makeDiagnostic(
        allocator,
        context,
        name,
        issue,
        field,
        actual,
        append_session_hint,
    );
    return diagnostic;
}

fn makeDiagnostic(
    allocator: std.mem.Allocator,
    context: DiagnosticContext,
    name: []const u8,
    issue: PresetIssue,
    field: ?[]const u8,
    actual: ?[]const u8,
    append_session_hint: bool,
) Error!PresetDiagnostic {
    const owned_name = try allocator.dupe(u8, name);
    errdefer wipeFree(allocator, owned_name);
    const owned_field = if (field) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_field) |value| wipeFree(allocator, value);
    const owned_actual = if (actual) |value| try allocator.dupe(u8, value) else null;
    return .{
        .context = context,
        .name = owned_name,
        .issue = issue,
        .field = owned_field,
        .actual = owned_actual,
        .append_session_hint = append_session_hint,
    };
}

fn filterReportedInvalid(
    allocator: std.mem.Allocator,
    presets: *config.Preset.Enumeration,
    warnings: []const Warning,
) Error!void {
    var keep_count: usize = 0;
    for (presets.invalid) |invalid| if (!invalidReported(invalid.name, warnings)) {
        keep_count += 1;
    };
    if (keep_count == presets.invalid.len) return;
    const kept = try allocator.alloc(config.Preset.Invalid, keep_count);
    var index: usize = 0;
    for (presets.invalid) |*invalid| {
        if (invalidReported(invalid.name, warnings)) {
            invalid.deinit(allocator);
        } else {
            kept[index] = invalid.*;
            invalid.* = undefined;
            index += 1;
        }
    }
    allocator.free(presets.invalid);
    presets.invalid = kept;
}

fn invalidReported(name: []const u8, warnings: []const Warning) bool {
    for (warnings) |warning| switch (warning.kind) {
        .recorded_preset_invalid, .implicit_preset_invalid => if (std.mem.eql(u8, name, warning.subject)) return true,
        else => {},
    };
    return false;
}

fn wipeFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

test {
    _ = StartupConfig;
}

fn initOwner(inputs: Inputs) !Owner {
    const result = try init(inputs);
    return switch (result) {
        .owner => |owner| owner,
        .fatal => |value| {
            var diagnostic = value;
            diagnostic.deinit(inputs.allocator);
            return error.UnexpectedFatal;
        },
    };
}

const TestSecureOpen = struct {
    directory: std.Io.Dir,
    base: []const u8,
    deny_path: ?[]const u8 = null,
    open_count: usize = 0,

    fn relative(self: *TestSecureOpen, path: []const u8) config.SecureOpen.Error![]const u8 {
        if (!std.mem.startsWith(u8, path, self.base) or path.len <= self.base.len or
            path[self.base.len] != '/') return error.InvalidPath;
        return path[self.base.len + 1 ..];
    }

    pub fn statAbsolute(
        self: *TestSecureOpen,
        io: std.Io,
        path: []const u8,
    ) config.SecureOpen.Error!std.Io.File.Stat {
        const sub_path = try self.relative(path);
        if (self.deny_path) |denied| if (std.mem.eql(u8, sub_path, denied)) return error.Unreadable;
        return self.directory.statFile(
            io,
            sub_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Unreadable,
        };
    }

    pub fn openAbsolute(
        self: *TestSecureOpen,
        io: std.Io,
        path: []const u8,
    ) config.SecureOpen.Error!std.Io.File {
        self.open_count += 1;
        return self.directory.openFile(io, try self.relative(path), .{}) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Unreadable,
        };
    }
};

fn testEnviron(entries: []const [*:0]const u8) std.process.Environ {
    return .{ .block = .{ .slice = @ptrCast(entries) } };
}

fn expectSetting(owner: *const Owner, key: []const u8, expected: []const u8, source: config.Store.Source) !void {
    var result = try owner.store().read(std.testing.allocator, key);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(source, result.source);
    try std.testing.expectEqualStrings(expected, result.value.?);
}

fn testInputs(
    allocator: std.mem.Allocator,
    base: []const u8,
    secure_open: config.SecureOpen.Capability,
    environment: *const ProcessAdapters.Environment,
) Inputs {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .path_inputs = .{ .xdg_config_home = base, .xdg_state_home = base },
        .file_access = .{
            .secure_open = secure_open,
            .home = base,
            .cwd = base,
        },
        .environment = environment,
    };
}

fn writeTiers(tmp: *std.testing.TmpDir, config_bytes: []const u8, state_bytes: []const u8) !void {
    try tmp.dir.createDir(std.testing.io, "zi", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zi/config.json", .data = config_bytes });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zi/state.json", .data = state_bytes });
}

test "explicit preset is atomic and CLI selection overrides it last" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"provider":"base","presets":{"work":{"provider":"preset-p","model":"preset-m","tint":"rose"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    inputs.selection = .{ .preset = "work", .model = "cli-m" };
    var owner = try initOwner(inputs);
    defer owner.deinit();
    try expectSetting(&owner, "provider", "preset-p", .run);
    try expectSetting(&owner, "model", "cli-m", .run);
    try std.testing.expectEqualStrings("rose", owner.tint().?);
    try std.testing.expectEqual(@as(usize, 1), owner.presetPlans().len);
}

test "owner forwards prospective run preparation and publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"presets":{"work":{"provider":"old-p","model":"old-m","effort":"low"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    inputs.selection.preset = "work";
    var owner = try initOwner(inputs);
    defer owner.deinit();

    var prepared = try owner.prepareRun(.{ .model = "new-m", .effort = "high" });
    try expectSetting(&owner, "model", "old-m", .run);
    var candidate = try prepared.store().read(std.testing.allocator, "model");
    defer candidate.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new-m", candidate.value.?);
    owner.publishRun(&prepared);
    try expectSetting(&owner, "model", "new-m", .run);
    try expectSetting(&owner, "effort", "high", .run);
    try expectSetting(&owner, "preset", "", .run);
}

test "empty environment preset suppresses a lower preset without replacing a resumed stance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"preset":"low","provider":"base","presets":{"low":{"provider":"low-p"},"saved":{"provider":"saved-p"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    const entries = [_][*:0]const u8{"HAX_PRESET="};
    var environment = ProcessAdapters.Environment.init(testEnviron(&entries));
    var inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    inputs.resumed = .{ .provider = "recorded-p", .model = "recorded-m", .preset = "saved" };
    var owner = try initOwner(inputs);
    defer owner.deinit();
    try expectSetting(&owner, "provider", "saved-p", .conversation);
    try expectSetting(&owner, "preset", "saved", .conversation);
}

test "per-setting environment suppresses persisted preset and stale implicit preset warns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{\"preset\":\"stale\",\"provider\":\"base\"}", "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };

    const per_setting_entries = [_][*:0]const u8{"HAX_MODEL=environment-m"};
    var per_setting_environment = ProcessAdapters.Environment.init(testEnviron(&per_setting_entries));
    var owner = try initOwner(testInputs(
        std.testing.allocator,
        base,
        config.SecureOpen.Capability.from(&access),
        &per_setting_environment,
    ));
    try expectSetting(&owner, "preset", "", .run);
    try expectSetting(&owner, "model", "environment-m", .env);
    try std.testing.expectEqual(@as(usize, 0), owner.warnings().len);
    owner.deinit();

    var empty_environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var stale_owner = try initOwner(testInputs(
        std.testing.allocator,
        base,
        config.SecureOpen.Capability.from(&access),
        &empty_environment,
    ));
    defer stale_owner.deinit();
    try std.testing.expectEqual(WarningKind.implicit_preset_missing, stale_owner.warnings()[0].kind);
    try expectSetting(&stale_owner, "preset", "", .run);
}

test "bad explicit and strict recorded presets are typed fatal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{}", "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    inputs.selection.preset = "missing";
    var explicit = (try init(inputs)).fatal;
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqual(DiagnosticContext.explicit, explicit.context);
    try std.testing.expect(explicit.issue == .missing);
    try std.testing.expectEqualStrings("missing", explicit.name);

    inputs.selection = .{};
    inputs.resumed = .{ .provider = "p", .preset = "missing" };
    inputs.strict_one_shot = true;
    var recorded = (try init(inputs)).fatal;
    defer recorded.deinit(std.testing.allocator);
    try std.testing.expectEqual(DiagnosticContext.recorded, recorded.context);
    try std.testing.expect(recorded.issue == .missing);
    try std.testing.expect(recorded.append_session_hint);
}

test "unusable tier warnings preserve config then state order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "[]", "not-json");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var owner = try initOwner(testInputs(
        std.testing.allocator,
        base,
        config.SecureOpen.Capability.from(&access),
        &environment,
    ));
    defer owner.deinit();
    try std.testing.expectEqual(@as(usize, 2), owner.warnings().len);
    try std.testing.expectEqual(WarningKind.config_unusable, owner.warnings()[0].kind);
    try std.testing.expectEqual(WarningKind.state_unusable, owner.warnings()[1].kind);
    try std.testing.expectEqual(config.Loader.Outcome.invalid, owner.warnings()[0].tier_outcome.?);
}

fn exerciseStartupAllocationFailures(
    allocator: std.mem.Allocator,
    base: []const u8,
    access: *TestSecureOpen,
    environment: *const ProcessAdapters.Environment,
) !void {
    var inputs = testInputs(allocator, base, config.SecureOpen.Capability.from(access), environment);
    inputs.selection = .{ .preset = "work", .model = "override" };
    var owner = try initOwner(inputs);
    defer owner.deinit();
    try expectSetting(&owner, "provider", "p", .run);
    try expectSetting(&owner, "model", "override", .run);
}

test "startup composition releases every allocation on OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"presets":{"work":{"provider":"p","model":"preset-model","system_prompt":"secret"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseStartupAllocationFailures,
        .{ base, &access, &environment },
    );
}

test "explicit diagnostics retain exact invalid preset details" {
    const cases = [_]struct {
        body: []const u8,
        reason: config.Preset.InvalidReason,
        field: []const u8,
        deny_path: ?[]const u8 = null,
    }{
        .{
            .body = "{\"presets\":{\"bad\":{\"provider\":\"p\",\"unknown\":1}}}",
            .reason = .unknown_field,
            .field = "unknown",
        },
        .{
            .body = "{\"presets\":{\"bad\":{\"provider\":\"p\",\"tint\":\"nope\"}}}",
            .reason = .invalid_tint,
            .field = "tint",
        },
        .{
            .body = "{\"presets\":{\"bad\":{\"provider\":\"p\",\"system_prompt\":\"@blocked\"}}}",
            .reason = .prompt_unreadable,
            .field = "system_prompt",
            .deny_path = "zi/blocked",
        },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeTiers(&tmp, case.body, "{}");
        const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(base);
        var access: TestSecureOpen = .{
            .directory = tmp.dir,
            .base = base,
            .deny_path = case.deny_path,
        };
        var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
        var inputs = testInputs(
            std.testing.allocator,
            base,
            config.SecureOpen.Capability.from(&access),
            &environment,
        );
        inputs.selection.preset = "bad";
        var diagnostic = (try init(inputs)).fatal;
        defer diagnostic.deinit(std.testing.allocator);
        try std.testing.expectEqual(DiagnosticContext.explicit, diagnostic.context);
        try std.testing.expectEqual(case.reason, diagnostic.issue.invalid);
        try std.testing.expectEqualStrings(case.field, diagnostic.field.?);
    }
}

test "prompt config root is derived from config path dirname" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"presets":{"work":{"provider":"p","system_prompt":"@prompt.txt"}}}
    , "{}");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zi/prompt.txt", .data = "from-config-dir" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    inputs.selection.preset = "work";
    var owner = try initOwner(inputs);
    defer owner.deinit();
    try expectSetting(&owner, "system_prompt", "from-config-dir", .run);
}

test "reported implicit invalid preset is not enumerated twice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"preset":"bad","presets":{"bad":{"provider":"p","tint":"wrong"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var owner = try initOwner(testInputs(
        std.testing.allocator,
        base,
        config.SecureOpen.Capability.from(&access),
        &environment,
    ));
    defer owner.deinit();
    try std.testing.expectEqual(@as(usize, 1), owner.warnings().len);
    try std.testing.expectEqual(WarningKind.implicit_preset_invalid, owner.warnings()[0].kind);
    try std.testing.expectEqual(config.Preset.InvalidReason.invalid_tint, owner.warnings()[0].preset_reason.?);
    try std.testing.expectEqualStrings("tint", owner.warnings()[0].field.?);
    try std.testing.expectEqual(@as(usize, 0), owner.invalidPresets().len);
}

fn exerciseDiagnosticAllocationFailures(
    allocator: std.mem.Allocator,
    base: []const u8,
    access: *TestSecureOpen,
    environment: *const ProcessAdapters.Environment,
) !void {
    var inputs = testInputs(allocator, base, config.SecureOpen.Capability.from(access), environment);
    inputs.selection.preset = "bad";
    var result = try init(inputs);
    switch (result) {
        .fatal => |*diagnostic| {
            try std.testing.expectEqual(config.Preset.InvalidReason.unknown_field, diagnostic.issue.invalid);
            try std.testing.expectEqualStrings("unknown", diagnostic.field.?);
            diagnostic.deinit(allocator);
        },
        .owner => |*owner| owner.deinit(),
    }
}

test "owned diagnostic construction releases every allocation on OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"presets":{"bad":{"provider":"p","unknown":"secret"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDiagnosticAllocationFailures,
        .{ base, &access, &environment },
    );
}

test "prepare store applies environment retention with a run preset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"session_retention_days":7,"presets":{"work":{"provider":"preset-p"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    const entries = [_][*:0]const u8{"HAX_SESSION_RETENTION_DAYS=14"};
    var environment = ProcessAdapters.Environment.init(testEnviron(&entries));
    var inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    inputs.selection.preset = "work";
    var prepared = try prepare(.{
        .allocator = inputs.allocator,
        .io = inputs.io,
        .path_inputs = inputs.path_inputs,
        .file_access = inputs.file_access,
        .environment = inputs.environment,
        .selection = inputs.selection,
    });
    defer prepared.deinit();
    var retention = try prepared.storeBeforeResume().read(std.testing.allocator, "session_retention_days");
    defer retention.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("14", retention.value.?);
    try std.testing.expectEqual(config.Store.Source.env, retention.source);
    var provider = try prepared.storeBeforeResume().read(std.testing.allocator, "provider");
    defer provider.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("preset-p", provider.value.?);
    try std.testing.expectEqual(config.Store.Source.run, provider.source);
}

test "finish uses the prepared file snapshot after files change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"preset":"saved","presets":{"saved":{"provider":"old-p"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    const inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    var prepared = try prepare(.{
        .allocator = inputs.allocator,
        .io = inputs.io,
        .path_inputs = inputs.path_inputs,
        .file_access = inputs.file_access,
        .environment = inputs.environment,
    });
    var prepared_owned = true;
    defer if (prepared_owned) prepared.deinit();
    const reads_after_prepare = access.open_count;
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zi/config.json",
        .data = "{\"preset\":\"saved\",\"presets\":{\"saved\":{\"provider\":\"new-p\"}}}",
    });
    const result = try finish(&prepared, .{ .provider = "recorded", .preset = "saved" });
    prepared_owned = false;
    var owner = result.owner;
    defer owner.deinit();
    try std.testing.expectEqual(reads_after_prepare, access.open_count);
    try expectSetting(&owner, "provider", "old-p", .conversation);
    try expectSetting(&owner, "preset", "saved", .conversation);
}

test "recorded preset replaces provisional persisted preset in final store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp,
        \\{"preset":"work","presets":{"work":{"provider":"work-p"},"saved":{"provider":"saved-p"}}}
    , "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    const inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    var prepared = try prepare(.{
        .allocator = inputs.allocator,
        .io = inputs.io,
        .path_inputs = inputs.path_inputs,
        .file_access = inputs.file_access,
        .environment = inputs.environment,
    });
    var provisional_provider = try prepared.storeBeforeResume().read(std.testing.allocator, "provider");
    defer provisional_provider.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("work-p", provisional_provider.value.?);
    const result = try finish(&prepared, .{ .provider = "recorded-p", .preset = "saved" });
    var owner = result.owner;
    defer owner.deinit();
    try expectSetting(&owner, "provider", "saved-p", .conversation);
    try expectSetting(&owner, "preset", "saved", .conversation);
}
