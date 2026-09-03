const std = @import("std");
const Args = @import("Args.zig");
const ProcessAdapters = @import("ProcessAdapters.zig");
const PresetSave = @import("PresetSave.zig");
const RuntimeConfig = @import("RuntimeConfig.zig");
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
    state_nonce_source: ?config.StateWriter.NonceSource = null,
    config_nonce_source: ?config.ConfigWriter.NonceSource = null,
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
    state_nonce_source: ?config.StateWriter.NonceSource = null,
    config_nonce_source: ?config.ConfigWriter.NonceSource = null,
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
    state_writer: ?*config.StateWriter.Owner,
    config_writer: *config.ConfigWriter.Owner,
    base: config.Store.Options,
    facts: StartupFacts,
    selection: config.Selection,
    providers: config.ProviderDefinitions.Enumeration,
    warnings: []Warning,
};

fn deinitState(state: *State) void {
    const allocator = state.allocator;
    for (state.warnings) |*warning| warning.deinit(allocator);
    allocator.free(state.warnings);
    state.providers.deinit();
    state.selection.deinit();
    state.config_writer.deinit();
    if (state.state_writer) |writer| writer.deinit();
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

    pub fn publishRunRetired(
        self: *Owner,
        prepared: *config.Selection.PreparedRun,
    ) config.Selection.RetiredOverlay {
        return self.state.selection.publishRunRetired(prepared);
    }

    pub fn prepareRunOverride(
        self: *const Owner,
        key: []const u8,
        value: ?[]const u8,
    ) config.Selection.Error!config.Selection.PreparedOverride {
        return self.state.selection.prepareRunOverride(key, value);
    }

    pub fn publishRunOverrideRetired(
        self: *Owner,
        prepared: *config.Selection.PreparedOverride,
    ) config.Selection.RetiredOverlay {
        return self.state.selection.publishRunOverrideRetired(prepared);
    }

    /// Returns a bounded borrowed view into the cached preset enumeration.
    /// The result is valid until Owner mutation or deinit and must not be deinitialized.
    pub fn lookupPreset(self: *const Owner, name: []const u8) config.Preset.BorrowedLookup {
        return self.state.config_writer.lookup(name);
    }

    pub fn preparePreset(
        self: *const Owner,
        plan: *const config.Preset.Plan,
    ) config.Selection.Error!config.Selection.PreparedPreset {
        return self.state.selection.preparePreset(.run, plan);
    }

    pub fn publishPreset(
        self: *Owner,
        prepared: *config.Selection.PreparedPreset,
    ) config.Selection.RetiredOverlay {
        return self.state.selection.publishPreset(prepared);
    }

    pub fn prepareRestore(
        self: *const Owner,
        metadata: config.Selection.RestoreMetadata,
        lookup: ?*const config.Preset.Lookup,
    ) config.Selection.Error!config.Selection.PreparedRestore {
        return self.state.selection.prepareRestoreRun(metadata, lookup);
    }

    pub fn publishRestore(
        self: *Owner,
        prepared: *config.Selection.PreparedRestore,
    ) config.Selection.RetiredOverlay {
        return self.state.selection.publishRestoreConversation(prepared);
    }

    pub fn presetPlans(self: *const Owner) []const config.Preset.Plan {
        return self.state.config_writer.plans();
    }

    pub fn invalidPresets(self: *const Owner) []const config.Preset.Invalid {
        return self.state.config_writer.invalid();
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

    pub fn inspectPresetSave(
        self: *const Owner,
        allocator: std.mem.Allocator,
        name: []const u8,
        active_preset: ?[]const u8,
    ) error{OutOfMemory}!PresetSave.Inspection {
        var target = try self.state.config_writer.inspect(allocator, name);
        defer target.deinit(allocator);
        const path = if (self.state.config_writer.configPath()) |value|
            allocator.dupe(u8, value) catch return error.OutOfMemory
        else
            null;
        errdefer if (path) |value| allocator.free(value);
        const detail = if (target.exists)
            try makePresetSaveDetail(allocator, &target)
        else
            null;
        errdefer if (detail) |value| allocator.free(value);

        var initial_tint: PresetSave.InitialTint = .none;
        var effective_tint = self.store().read(allocator, "tint") catch return error.OutOfMemory;
        defer effective_tint.deinit(allocator);
        if (effective_tint.source == .run) {
            initial_tint = classifyPresetSaveTint(effective_tint.value);
        } else {
            var found_active = false;
            if (active_preset) |active_name| if (active_name.len != 0) {
                if (std.mem.eql(u8, active_name, name)) {
                    if (target.tint) |value| {
                        initial_tint = classifyPresetSaveTint(value);
                        found_active = true;
                    }
                } else {
                    var active = try self.state.config_writer.inspect(allocator, active_name);
                    defer active.deinit(allocator);
                    if (active.tint) |value| {
                        initial_tint = classifyPresetSaveTint(value);
                        found_active = true;
                    }
                }
            };
            if (!found_active) initial_tint = classifyPresetSaveTint(target.tint);
        }
        return .{
            .path = path,
            .exists = target.exists,
            .detail = detail,
            .initial_tint = initial_tint,
        };
    }

    pub fn savePreset(
        self: *Owner,
        outcome_allocator: std.mem.Allocator,
        request: PresetSave.Request,
    ) error{OutOfMemory}!config.ConfigWriter.SaveOutcome {
        if (request.selection.provider.len == 0 or request.selection.model.len == 0) return .failed;
        var system_prompt = self.store().read(self.state.allocator, "system_prompt") catch
            return error.OutOfMemory;
        defer system_prompt.deinit(self.state.allocator);
        var system_prompt_append = self.store().read(self.state.allocator, "system_prompt_append") catch
            return error.OutOfMemory;
        defer system_prompt_append.deinit(self.state.allocator);
        return self.state.config_writer.savePreset(outcome_allocator, request.name, .{
            .provider = request.selection.provider,
            .model = if (request.selection.model_discovered) null else request.selection.model,
            .effort = request.selection.effort,
            .system_prompt = capturablePrompt(&system_prompt),
            .system_prompt_append = capturablePrompt(&system_prompt_append),
            .tint = if (request.tint) |value| value.canonical() else null,
        });
    }

    pub fn configPath(self: *const Owner) ?[]const u8 {
        return self.state.config_writer.configPath();
    }

    pub fn configRoot(self: *const Owner) ?[]const u8 {
        return self.state.config_writer.configRoot();
    }

    pub fn stateWriter(self: *Owner) ?config.StateWriter.Writer {
        return if (self.state.state_writer) |writer| writer.writer() else null;
    }

    pub fn configUnusable(self: *const Owner) bool {
        return self.state.tiers.config_unusable;
    }

    pub fn tint(self: *const Owner) ?[]const u8 {
        return self.state.selection.presetTint();
    }
};

fn classifyPresetSaveTint(value: ?[]const u8) PresetSave.InitialTint {
    const bytes = value orelse return .none;
    return if (PresetSave.parseTint(bytes)) |tint| .{ .selected = tint } else .unsupported;
}

fn capturablePrompt(result: *const config.Store.Result) ?[]const u8 {
    return switch (result.source) {
        .run, .conversation, .env, .state => result.value,
        .config, .default => null,
    };
}

fn makePresetSaveDetail(
    allocator: std.mem.Allocator,
    inspection: *const config.Preset.SaveInspection,
) error{OutOfMemory}![]u8 {
    const provider = if (inspection.provider) |value|
        if (value.len != 0) value else "no provider"
    else
        "no provider";
    const model = if (inspection.model) |value| if (value.len != 0) value else null else null;
    const effort = if (inspection.effort) |value| if (value.len != 0) value else null else null;
    var total = provider.len;
    if (model) |value| total = std.math.add(usize, total, 4 + value.len) catch return error.OutOfMemory;
    if (effort) |value| total = std.math.add(usize, total, 4 + value.len) catch return error.OutOfMemory;
    const detail = allocator.alloc(u8, total) catch return error.OutOfMemory;
    var cursor: usize = 0;
    for ([_]?[]const u8{ provider, model, effort }) |segment| if (segment) |value| {
        if (cursor != 0) {
            @memcpy(detail[cursor..][0..4], " · ");
            cursor += 4;
        }
        @memcpy(detail[cursor..][0..value.len], value);
        cursor += value.len;
    };
    std.debug.assert(cursor == detail.len);
    return detail;
}

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

    var state_writer: ?*config.StateWriter.Owner = null;
    errdefer if (state_writer) |writer| writer.deinit();
    if (state.tiers.state) |result_value| {
        state.tiers.state = null;
        var result = result_value;
        const initialized = config.StateWriter.Owner.init(inputs.allocator, inputs.io, &result, .{
            .secure_open = inputs.file_access.secure_open,
            .nonce_source = inputs.state_nonce_source,
        }) catch |err| {
            result.deinit(inputs.allocator);
            return err;
        };
        switch (initialized) {
            .unavailable => {},
            .owner => |writer| state_writer = writer,
        }
    }

    const documents = persistentDocuments(&state.tiers, state_writer);
    const prompt_roots: config.Preset.PromptRoots = .{
        .secure_open = inputs.file_access.secure_open,
        .config_root = if (state.tiers.config) |result| std.fs.path.dirname(result.path) else null,
        .home = inputs.file_access.home,
        .cwd = inputs.file_access.cwd,
    };
    var presets = try config.Preset.enumerate(inputs.allocator, inputs.io, documents, prompt_roots);
    var presets_owned = true;
    errdefer if (presets_owned) presets.deinit(inputs.allocator);
    var providers = try config.ProviderDefinitions.enumerate(inputs.allocator, .{
        .config = documents.config,
        .state = documents.state,
    });
    errdefer providers.deinit();
    const config_writer = try config.ConfigWriter.Owner.init(
        inputs.allocator,
        inputs.io,
        &state.tiers.config,
        &presets,
        documents.state,
        .{
            .secure_open = inputs.file_access.secure_open,
            .nonce_source = inputs.config_nonce_source,
            .home = inputs.file_access.home,
            .cwd = inputs.file_access.cwd,
        },
    );
    presets_owned = false;
    errdefer config_writer.deinit();

    const base: config.Store.Options = .{
        .file = config_writer.document(),
        .state = documents.state,
        .registry = config.Settings.storeRegistry(),
        .environment = inputs.environment.store(),
        .provider_canonicalizer = inputs.provider_canonicalizer,
    };
    const facts: StartupFacts = .{
        .cli = inputs.selection,
        .env_provider = inputs.environment.get("ZI_PROVIDER"),
        .env_model = inputs.environment.get("ZI_MODEL"),
        .env_effort = inputs.environment.get("ZI_EFFORT"),
        .env_preset = inputs.environment.get("ZI_PRESET"),
        .env_system_prompt = inputs.environment.get("ZI_SYSTEM_PROMPT"),
        .strict_one_shot = inputs.strict_one_shot,
    };
    var selection = config.Selection.init(inputs.allocator, base);
    errdefer selection.deinit();
    try composeProvisional(inputs.allocator, facts, config_writer, &selection);
    const warnings = try warning_builder.items.toOwnedSlice(inputs.allocator);

    state.state_writer = state_writer;
    state.config_writer = config_writer;
    state.base = base;
    state.facts = facts;
    state.selection = selection;
    state.providers = providers;
    state.warnings = warnings;
    warning_builder = .{};
    tiers_owned = false;
    selection = undefined;
    providers = undefined;
    state_writer = null;
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

    if (try composeFinal(allocator, state.facts, state.config_writer, resumed, &selection, &warnings)) |diagnostic| {
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
        .state_nonce_source = inputs.state_nonce_source,
        .config_nonce_source = inputs.config_nonce_source,
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
    presets: *const config.ConfigWriter.Owner,
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
    presets: *const config.ConfigWriter.Owner,
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

/// Returns a shallow borrowed compatibility value. It must never be deinitialized.
fn cachedLookup(
    presets: *const config.ConfigWriter.Owner,
    name: []const u8,
) config.Preset.Lookup {
    return switch (presets.lookup(name)) {
        .missing => .missing,
        .plan => |plan| .{ .plan = plan.* },
        .invalid => |invalid| .{ .invalid = invalid.* },
    };
}

fn applyCachedProvisional(
    selection: *config.Selection,
    presets: *const config.ConfigWriter.Owner,
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
    presets: *const config.ConfigWriter.Owner,
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

fn persistentDocuments(
    tiers: *const config.Loader.InitialTiers,
    state_writer: ?*config.StateWriter.Owner,
) config.Preset.Documents {
    return .{
        .config = if (tiers.config) |*result| if (result.document) |*document| document else null else null,
        .state = if (state_writer) |writer| writer.document() else null,
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
    try tmp.dir.createDir(std.testing.io, "zi", .fromMode(0o700));
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

test "runtime config candidate rollback and confirmation precede publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{\"compact.threshold\":70}", "{}");
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
    var runtime = try RuntimeConfig.Owner.init(std.testing.allocator, &owner, .{});
    defer runtime.deinit();
    const setting = config.Settings.find("compact.threshold").?;

    var candidate = try runtime.prepare(setting, .{ .set = "75" });
    try std.testing.expectEqual(@as(u8, 75), candidate.snapshot.compact_threshold);
    try expectSetting(&owner, "compact.threshold", "70", .config);
    candidate.deinit();
    try std.testing.expectEqual(@as(u8, 70), runtime.snapshot.compact_threshold);

    const applied = try runtime.apply(
        std.testing.allocator,
        setting,
        .{ .set = "75" },
        4096,
    );
    switch (applied) {
        .failed => return error.TestUnexpectedResult,
        .changed => |value| {
            var inspection = value;
            defer inspection.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("75", inspection.display);
            try std.testing.expectEqual(config.Store.Source.run, inspection.source);
        },
    }
    try expectSetting(&owner, "compact.threshold", "75", .run);
    try std.testing.expectEqual(@as(u8, 75), runtime.snapshot.compact_threshold);

    const cleared = try runtime.apply(
        std.testing.allocator,
        setting,
        .clear,
        4096,
    );
    switch (cleared) {
        .failed => return error.TestUnexpectedResult,
        .changed => |value| {
            var inspection = value;
            defer inspection.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("70", inspection.display);
            try std.testing.expectEqual(config.Store.Source.config, inspection.source);
        },
    }
    try expectSetting(&owner, "compact.threshold", "70", .config);
    try std.testing.expectEqual(@as(u8, 70), runtime.snapshot.compact_threshold);
}

test "startup config writer publication reaches retained store and preset views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{\"unknown\":42}", "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var secure: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    var environment = ProcessAdapters.Environment.init(testEnviron(&.{}));
    var owner = try initOwner(testInputs(
        std.testing.allocator,
        base,
        config.SecureOpen.Capability.from(&secure),
        &environment,
    ));
    defer owner.deinit();
    const stable_document = owner.state.config_writer.document();
    const retained_store = owner.store();

    var outcome = try owner.state.config_writer.savePreset(std.testing.allocator, "review", .{
        .provider = "mock",
        .model = "mock-model",
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.ConfigWriter.SaveKind.saved, outcome.written);
    try std.testing.expect(stable_document == owner.state.config_writer.document());
    try std.testing.expect(owner.lookupPreset("review") == .plan);
    var provider = try retained_store.read(std.testing.allocator, "presets.review.provider");
    defer provider.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.Store.Source.config, provider.source);
    try std.testing.expectEqualStrings("mock", provider.value.?);
}

test "startup preset save capture policy accepts only non-reproducible sources" {
    var bytes = [_]u8{'x'};
    inline for (.{
        config.Store.Source.run,
        config.Store.Source.conversation,
        config.Store.Source.env,
        config.Store.Source.state,
    }) |source| {
        const result: config.Store.Result = .{ .value = &bytes, .source = source };
        try std.testing.expectEqualStrings("x", capturablePrompt(&result).?);
    }
    inline for (.{ config.Store.Source.config, config.Store.Source.default }) |source| {
        const result: config.Store.Result = .{ .value = &bytes, .source = source };
        try std.testing.expect(capturablePrompt(&result) == null);
    }
    var empty: [0]u8 = .{};
    const explicit_empty: config.Store.Result = .{ .value = &empty, .source = .env };
    try std.testing.expectEqual(@as(usize, 0), capturablePrompt(&explicit_empty).?.len);
}

test "startup preset save inspection owns detail and applies active then target tint precedence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(
        &tmp,
        "{\"presets\":{\"active\":{\"provider\":\"mock\",\"tint\":\"rose\"}," ++
            "\"target\":{\"provider\":\"old\",\"model\":7,\"effort\":true,\"tint\":\"wrong\"}}}",
        "{}",
    );
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

    var active = try owner.inspectPresetSave(std.testing.allocator, "target", "active");
    defer active.deinit(std.testing.allocator);
    try std.testing.expect(active.exists);
    try std.testing.expectEqualStrings("old · 7 · 1", active.detail.?);
    try std.testing.expectEqual(PresetSave.Tint.rose, active.initial_tint.selected);
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "zi/config.json" });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(path, active.path.?);

    var target = try owner.inspectPresetSave(std.testing.allocator, "target", null);
    defer target.deinit(std.testing.allocator);
    try std.testing.expect(target.initial_tint == .unsupported);
}

test "startup preset save captures env and state prompts and omits discovered model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{\"system_prompt\":\"config prompt\"}", "{\"system_prompt_append\":\"state append\"}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    const entries = [_][*:0]const u8{"ZI_SYSTEM_PROMPT="};
    var environment = ProcessAdapters.Environment.init(testEnviron(&entries));
    var owner = try initOwner(testInputs(
        std.testing.allocator,
        base,
        config.SecureOpen.Capability.from(&access),
        &environment,
    ));
    defer owner.deinit();

    var outcome = try owner.savePreset(std.testing.allocator, .{
        .name = "captured",
        .tint = .sage,
        .selection = .{
            .generation = 1,
            .provider = "mock",
            .model = "server-model",
            .effort = "high",
            .active_preset = null,
            .model_discovered = true,
        },
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.ConfigWriter.SaveKind.saved, outcome.written);
    const plan = owner.lookupPreset("captured").plan;
    try std.testing.expect(plan.model.value == null);
    try std.testing.expectEqualStrings("high", plan.effort.value.?);
    try std.testing.expectEqual(@as(usize, 0), plan.system_prompt.value.?.len);
    try std.testing.expectEqualStrings("state append", plan.system_prompt_append.value.?);
    try std.testing.expectEqualStrings("sage", plan.tint.value.?);
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

test "startup state writer publishes through the stable store slot and preserves unknown state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{}", "{\"provider\":\"old\",\"unknown\":{\"answer\":42}}");
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

    const writer = owner.stateWriter().?;
    try std.testing.expectEqual(config.StateWriter.Outcome.written, try writer.write(.{
        .provider = "new",
        .model = "chosen",
        .effort = config.Store.default_sentinel,
    }));
    try expectSetting(&owner, "provider", "new", .state);
    try expectSetting(&owner, "model", "chosen", .state);
    const state_document = owner.state.state_writer.?.document();
    try std.testing.expectEqual(@as(i64, 42), state_document.lookup("unknown.answer").?.integer);
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
    const entries = [_][*:0]const u8{"ZI_PRESET="};
    var environment = ProcessAdapters.Environment.init(testEnviron(&entries));
    var inputs = testInputs(std.testing.allocator, base, config.SecureOpen.Capability.from(&access), &environment);
    inputs.resumed = .{ .provider = "recorded-p", .model = "recorded-m", .preset = "saved" };
    var owner = try initOwner(inputs);
    defer owner.deinit();
    try expectSetting(&owner, "provider", "saved-p", .conversation);
    try expectSetting(&owner, "preset", "saved", .conversation);
}

test "startup ignores the old product environment prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{\"model\":\"configured-model\"}", "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };
    const entries = [_][*:0]const u8{"HAX" ++ "_MODEL=ignored"};
    var environment = ProcessAdapters.Environment.init(testEnviron(&entries));
    var owner = try initOwner(testInputs(
        std.testing.allocator,
        base,
        config.SecureOpen.Capability.from(&access),
        &environment,
    ));
    defer owner.deinit();
    try expectSetting(&owner, "model", "configured-model", .config);
}

test "per-setting environment suppresses persisted preset and stale implicit preset warns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTiers(&tmp, "{\"preset\":\"stale\",\"provider\":\"base\"}", "{}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var access: TestSecureOpen = .{ .directory = tmp.dir, .base = base };

    const per_setting_entries = [_][*:0]const u8{"ZI_MODEL=environment-m"};
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
    try expectSetting(&owner, "system_prompt", "@prompt.txt", .run);
}

test "reported implicit invalid preset remains addressable" {
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
    try std.testing.expectEqual(@as(usize, 1), owner.invalidPresets().len);
    try std.testing.expectEqualStrings("bad", owner.invalidPresets()[0].name);
    try std.testing.expectEqual(
        config.Preset.InvalidReason.invalid_tint,
        owner.lookupPreset("bad").invalid.reason,
    );
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
    const entries = [_][*:0]const u8{"ZI_SESSION_RETENTION_DAYS=14"};
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
