const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const config = @import("../config/root.zig");
const persistence = @import("../persistence/root.zig");
const tool = @import("../tool/root.zig");
const Interactive = @import("Interactive.zig");
const PromptAssembly = @import("../PromptAssembly.zig");
const ProviderConfig = @import("../ProviderConfig.zig");
const ProviderRuntime = @import("../ProviderRuntime.zig");
const SessionDurability = @import("../SessionDurability.zig");

pub const ModelProvenance = enum {
    inherited,
    concrete,
    discovered,
    explicit,
};

pub const ReportedMetadataChange = union(enum) {
    preserve,
    replace: ?ai.ModelMeta.Metadata,
};

pub const RequestedSelection = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_label: ?[]const u8 = null,
    effort: ?[]const u8,
    reported_metadata: ReportedMetadataChange = .preserve,
    model_provenance: ModelProvenance = .inherited,
    effort_selected: bool = false,
};

pub const Intent = enum { user_persistent, session_restore };

pub const RestoreRequest = struct {
    meta: *const persistence.SessionFile.Meta,
    selection: persistence.SessionFile.Selection,
};

pub const Request = union(enum) {
    run: RequestedSelection,
    preset: []const u8,
    restore: RestoreRequest,
};

/// Product-facing reason a recorded selection could not replace the current one.
/// Provider construction and prompt/tool mechanism errors stay behind these classes.
pub const RestoreFailure = enum {
    no_recorded_provider,
    unknown_provider,
    runtime_unavailable,
    model_unavailable,
    preparation_failed,
};

pub const PrepareError = error{
    OutOfMemory,
    Reentrant,
    InvalidIntent,
    PresetMissing,
    PresetInvalid,
    RestoreUnknownProvider,
    RestoreRuntimeUnavailable,
    RestoreModelUnavailable,
    RestorePreparationFailed,
};

pub fn restoreFailure(err: PrepareError) ?RestoreFailure {
    return switch (err) {
        error.RestoreUnknownProvider => .unknown_provider,
        error.RestoreRuntimeUnavailable => .runtime_unavailable,
        error.RestoreModelUnavailable => .model_unavailable,
        error.RestorePreparationFailed => .preparation_failed,
        else => null,
    };
}

pub const Built = struct {
    runtime: ProviderRuntime.Owned,
    prompt: ?PromptAssembly.OwnedPrompt,
    image_input: ai.Provider.ImageInput,
    context_limit: ?u64,
    sort_models: bool,
    active: bool = true,

    pub fn deinit(self: *Built, allocator: std.mem.Allocator) void {
        if (self.active) {
            if (self.prompt) |*prompt| prompt.deinit(allocator);
            self.runtime.deinit();
        }
        self.* = undefined;
    }
};

/// Builds all fallible provider, prompt, and derived state against a borrowed
/// prospective store. The returned value owns everything that survives build.
pub const Builder = struct {
    context: *anyopaque,
    build_fn: *const fn (*anyopaque, config.Store, ?ai.ModelMeta.Metadata) anyerror!Built,

    pub fn build(self: Builder, store: config.Store, reported_metadata: ?ai.ModelMeta.Metadata) !Built {
        return self.build_fn(self.context, store, reported_metadata);
    }

    pub fn from(implementation: anytype) Builder {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("RunSelection.Builder.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn build(
                context: *anyopaque,
                store: config.Store,
                reported_metadata: ?ai.ModelMeta.Metadata,
            ) anyerror!Built {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.build(store, reported_metadata);
            }
        };
        return .{ .context = implementation, .build_fn = Adapter.build };
    }
};

pub const ProviderSource = struct {
    context: *anyopaque,
    choices_fn: *const fn (std.mem.Allocator, *anyopaque) anyerror!ProviderConfig.ProviderChoices,
    recheck_fn: *const fn (std.Io, *anyopaque, []const u8, ?ai.Provider.Tick) anyerror!bool,
    listing_fn: *const fn (*anyopaque, config.Store) anyerror!ProviderRuntime.ListingOwned,

    pub fn choices(self: ProviderSource, allocator: std.mem.Allocator) !ProviderConfig.ProviderChoices {
        return self.choices_fn(allocator, self.context);
    }

    pub fn recheck(self: ProviderSource, io: std.Io, provider: []const u8, tick: ?ai.Provider.Tick) !bool {
        return self.recheck_fn(io, self.context, provider, tick);
    }

    pub fn listing(self: ProviderSource, store: config.Store) !ProviderRuntime.ListingOwned {
        return self.listing_fn(self.context, store);
    }

    pub fn from(implementation: anytype) ProviderSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("RunSelection.ProviderSource.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn choices(allocator: std.mem.Allocator, context: *anyopaque) anyerror!ProviderConfig.ProviderChoices {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.providerChoices(allocator);
            }

            fn recheck(
                io: std.Io,
                context: *anyopaque,
                provider: []const u8,
                tick: ?ai.Provider.Tick,
            ) anyerror!bool {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.recheckProvider(io, provider, tick);
            }

            fn listing(context: *anyopaque, store: config.Store) anyerror!ProviderRuntime.ListingOwned {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.buildProviderListing(store);
            }
        };
        return .{
            .context = implementation,
            .choices_fn = Adapter.choices,
            .recheck_fn = Adapter.recheck,
            .listing_fn = Adapter.listing,
        };
    }
};

pub const ProviderListingCandidate = struct {
    allocator: std.mem.Allocator,
    config_run: config.Selection.PreparedRun,
    runtime: ProviderRuntime.ListingOwned,
    sort_models: bool,

    pub fn deinit(self: *ProviderListingCandidate) void {
        self.runtime.deinit();
        self.config_run.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const ConfigSource = struct {
    context: *anyopaque,
    prepare_fn: *const fn (*anyopaque, config.Selection.RunChange) anyerror!config.Selection.PreparedRun,
    publish_fn: *const fn (*anyopaque, *config.Selection.PreparedRun) void,
    publish_run_retired_fn: *const fn (
        *anyopaque,
        *config.Selection.PreparedRun,
    ) config.Selection.RetiredOverlay,
    lookup_preset_fn: *const fn (*anyopaque, []const u8) config.Preset.BorrowedLookup,
    preset_plans_fn: *const fn (*anyopaque) []const config.Preset.Plan,
    preset_tint_fn: *const fn (*anyopaque) ?[]const u8,
    prepare_preset_fn: *const fn (
        *anyopaque,
        *const config.Preset.Plan,
    ) anyerror!config.Selection.PreparedPreset,
    publish_preset_fn: *const fn (
        *anyopaque,
        *config.Selection.PreparedPreset,
    ) config.Selection.RetiredOverlay,
    prepare_restore_fn: *const fn (
        *anyopaque,
        config.Selection.RestoreMetadata,
        ?*const config.Preset.Lookup,
    ) anyerror!config.Selection.PreparedRestore,
    publish_restore_fn: *const fn (
        *anyopaque,
        *config.Selection.PreparedRestore,
    ) config.Selection.RetiredOverlay,

    pub fn prepare(self: ConfigSource, change: config.Selection.RunChange) !config.Selection.PreparedRun {
        return self.prepare_fn(self.context, change);
    }

    pub fn publish(self: ConfigSource, prepared: *config.Selection.PreparedRun) void {
        self.publish_fn(self.context, prepared);
    }

    /// Borrows cached preset enumeration storage owned by the implementation.
    pub fn lookupPreset(self: ConfigSource, name: []const u8) config.Preset.BorrowedLookup {
        return self.lookup_preset_fn(self.context, name);
    }

    pub fn presetPlans(self: ConfigSource) []const config.Preset.Plan {
        return self.preset_plans_fn(self.context);
    }

    pub fn presetTint(self: ConfigSource) ?[]const u8 {
        return self.preset_tint_fn(self.context);
    }

    pub fn preparePreset(
        self: ConfigSource,
        plan: *const config.Preset.Plan,
    ) !config.Selection.PreparedPreset {
        return self.prepare_preset_fn(self.context, plan);
    }

    pub fn publishPreset(
        self: ConfigSource,
        prepared: *config.Selection.PreparedPreset,
    ) config.Selection.RetiredOverlay {
        return self.publish_preset_fn(self.context, prepared);
    }

    pub fn prepareRestore(
        self: ConfigSource,
        metadata: config.Selection.RestoreMetadata,
        lookup: ?*const config.Preset.Lookup,
    ) !config.Selection.PreparedRestore {
        return self.prepare_restore_fn(self.context, metadata, lookup);
    }

    pub fn publishRestore(
        self: ConfigSource,
        prepared: *config.Selection.PreparedRestore,
    ) config.Selection.RetiredOverlay {
        return self.publish_restore_fn(self.context, prepared);
    }

    pub fn from(implementation: anytype) ConfigSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("RunSelection.ConfigSource.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn prepare(
                context: *anyopaque,
                change: config.Selection.RunChange,
            ) anyerror!config.Selection.PreparedRun {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.prepareRun(change);
            }

            fn publish(context: *anyopaque, prepared: *config.Selection.PreparedRun) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.publishRun(prepared);
            }

            fn publishRunRetired(
                context: *anyopaque,
                prepared: *config.Selection.PreparedRun,
            ) config.Selection.RetiredOverlay {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.publishRunRetired(prepared);
            }

            fn lookupPreset(context: *anyopaque, name: []const u8) config.Preset.BorrowedLookup {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.lookupPreset(name);
            }

            fn presetPlans(context: *anyopaque) []const config.Preset.Plan {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.presetPlans();
            }

            fn presetTint(context: *anyopaque) ?[]const u8 {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.tint();
            }

            fn preparePreset(
                context: *anyopaque,
                plan: *const config.Preset.Plan,
            ) anyerror!config.Selection.PreparedPreset {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.preparePreset(plan);
            }

            fn publishPreset(
                context: *anyopaque,
                prepared: *config.Selection.PreparedPreset,
            ) config.Selection.RetiredOverlay {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.publishPreset(prepared);
            }

            fn prepareRestore(
                context: *anyopaque,
                metadata: config.Selection.RestoreMetadata,
                lookup: ?*const config.Preset.Lookup,
            ) anyerror!config.Selection.PreparedRestore {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.prepareRestore(metadata, lookup);
            }

            fn publishRestore(
                context: *anyopaque,
                prepared: *config.Selection.PreparedRestore,
            ) config.Selection.RetiredOverlay {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.publishRestore(prepared);
            }
        };
        return .{
            .context = implementation,
            .prepare_fn = Adapter.prepare,
            .publish_fn = Adapter.publish,
            .publish_run_retired_fn = Adapter.publishRunRetired,
            .lookup_preset_fn = Adapter.lookupPreset,
            .preset_plans_fn = Adapter.presetPlans,
            .preset_tint_fn = Adapter.presetTint,
            .prepare_preset_fn = Adapter.preparePreset,
            .publish_preset_fn = Adapter.publishPreset,
            .prepare_restore_fn = Adapter.prepareRestore,
            .publish_restore_fn = Adapter.publishRestore,
        };
    }
};

/// Prepared child-process selection publication. Validation may fail;
/// publication runs only between turns and cannot fail or allocate.
pub const ToolSelection = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque, tool.Bash.RunSelection) anyerror!void,
    publish_fn: *const fn (*anyopaque, tool.Bash.RunSelection) void,

    pub fn validate(self: ToolSelection, selection: tool.Bash.RunSelection) !void {
        return self.validate_fn(self.context, selection);
    }

    /// Synchronous, allocation-free, non-failing, non-retaining, and
    /// non-reentrant. The implementation may copy the scalar selection.
    pub fn publish(self: ToolSelection, selection: tool.Bash.RunSelection) void {
        self.publish_fn(self.context, selection);
    }

    pub fn from(implementation: anytype) ToolSelection {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("RunSelection.ToolSelection.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn validate(context: *anyopaque, selection: tool.Bash.RunSelection) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.validateRunSelection(selection);
            }

            fn publish(context: *anyopaque, selection: tool.Bash.RunSelection) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.publishRunSelection(selection);
            }
        };
        return .{ .context = implementation, .validate_fn = Adapter.validate, .publish_fn = Adapter.publish };
    }
};

pub const Derived = struct {
    runtime: *ProviderRuntime.Owned,
    system_prompt: []const u8,
    image_input: ai.Provider.ImageInput,
    context_limit: ?u64,
    preset_tint: ?[]const u8,
};

pub const Views = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, Derived) void,

    /// Synchronous, allocation-free, non-failing, and non-reentrant. Slices
    /// and pointers may be retained only into the newly published stable Owner.
    pub fn publish(self: Views, derived: Derived) void {
        self.publish_fn(self.context, derived);
    }

    pub fn from(implementation: anytype) Views {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or pointer_info.pointer.is_const) {
            @compileError("RunSelection.Views.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn publish(context: *anyopaque, derived: Derived) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.publishSelectionViews(derived);
            }
        };
        return .{ .context = implementation, .publish_fn = Adapter.publish };
    }
};

pub const Candidate = struct {
    allocator: std.mem.Allocator,
    config_run: config.Selection.PreparedRun,
    built: Built,
    session: SessionDurability.PreparedSelection,
    tool_selection: tool.Bash.RunSelection,
    reported_metadata: ?ai.ModelMeta.Metadata,
    model_provenance: ModelProvenance,
    persistent_model: ?[]const u8,
    persistent_effort: ?[]const u8,
    active: bool = true,

    pub fn deinit(self: *Candidate) void {
        if (self.active) {
            self.session.deinit();
            self.built.deinit(self.allocator);
            self.config_run.deinit(self.allocator);
        }
        self.* = undefined;
    }
};

pub const ConfigOverlay = union(enum) {
    run: config.Selection.PreparedRun,
    preset: config.Selection.PreparedPreset,
    restore: config.Selection.PreparedRestore,

    fn store(self: *const ConfigOverlay) config.Store {
        return switch (self.*) {
            .run => |*value| value.store(),
            .preset => |*value| value.store(),
            .restore => |*value| value.store(),
        };
    }

    fn deinit(self: *ConfigOverlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => |*value| value.deinit(allocator),
            .preset => |*value| value.deinit(),
            .restore => |*value| value.deinit(),
        }
        self.* = undefined;
    }

    fn publish(self: *ConfigOverlay, source: ConfigSource) config.Selection.RetiredOverlay {
        const retired = switch (self.*) {
            .run => |*value| source.publish_run_retired_fn(source.context, value),
            .preset => |*value| source.publishPreset(value),
            .restore => |*value| source.publishRestore(value),
        };
        self.* = undefined;
        return retired;
    }
};

/// Detached provider/config/tool state. It never contains a prepared session
/// or durability value tied to a live conversation address.
pub const DetachedCandidate = struct {
    owner: *Owner,
    generation: u64,
    allocator: std.mem.Allocator,
    config_overlay: ConfigOverlay,
    built: Built,
    requested: RequestedSelection,
    session_selection: agent.Session.Selection,
    log_selection: persistence.SessionFile.Selection,
    tool_selection: tool.Bash.RunSelection,
    intent: Intent,
    restore_outcome: ?config.Selection.RestoreOutcome,
    owned_model_label: []u8,
    owned_preset: ?[]u8,
    reported_metadata: ?ai.ModelMeta.Metadata,
    model_provenance: ModelProvenance,
    active: bool = true,

    pub fn deinit(self: *DetachedCandidate) void {
        if (self.active) {
            if (self.owned_preset) |value| self.allocator.free(value);
            self.allocator.free(self.owned_model_label);
            self.built.deinit(self.allocator);
            self.config_overlay.deinit(self.allocator);
        }
        self.* = undefined;
    }
};

/// Values displaced by detached publication. Cleanup must occur after the
/// caller leaves its coordinated publication section.
pub const RetiredRuntime = struct {
    allocator: std.mem.Allocator,
    config_overlay: config.Selection.RetiredOverlay,
    runtime: ProviderRuntime.Owned,
    prompt: ?PromptAssembly.OwnedPrompt,
    candidate_model_label: []u8,
    candidate_preset: ?[]u8,
    active: bool = true,

    pub fn deinit(self: *RetiredRuntime) void {
        if (self.active) {
            if (self.candidate_preset) |value| self.allocator.free(value);
            self.allocator.free(self.candidate_model_label);
            if (self.prompt) |*value| value.deinit(self.allocator);
            self.runtime.deinit();
            self.config_overlay.deinit();
        }
        self.* = undefined;
    }
};

pub const PresetPreparationError = error{ PresetMissing, PresetInvalid };

pub const PresetAuthority = enum {
    coordinated,
    quarantined_transition,
};

const PresetMetadataPreparation = union(enum) {
    coordinated: SessionDurability.PreparedSelection,
    quarantined_transition: SessionDurability.PreparedQuarantinedTransitionSelection,

    fn deinit(self: *PresetMetadataPreparation) void {
        switch (self.*) {
            inline else => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};

/// Move-only preset transaction prepared against the prospective preset Store.
pub const PresetCandidate = struct {
    allocator: std.mem.Allocator,
    owner: *Owner,
    generation: u64,
    config_preset: config.Selection.PreparedPreset,
    built: Built,
    metadata: PresetMetadataPreparation,
    agent_selection: agent.Session.Selection,
    log_selection: persistence.SessionFile.Selection,
    tool_selection: tool.Bash.RunSelection,
    reported_metadata: ?ai.ModelMeta.Metadata,
    model_provenance: ModelProvenance,
    preset_name: []u8,
    owned_model_label: []u8,
    active: bool = true,

    pub fn deinit(self: *PresetCandidate) void {
        if (self.active) {
            self.metadata.deinit();
            self.built.deinit(self.allocator);
            self.config_preset.deinit();
            self.allocator.free(self.owned_model_label);
            self.allocator.free(self.preset_name);
        }
        self.* = undefined;
    }

    pub fn effectiveAgentSelection(self: *const PresetCandidate) agent.Session.Selection {
        std.debug.assert(self.active);
        return self.agent_selection;
    }

    pub fn effectiveLogSelection(self: *const PresetCandidate) persistence.SessionFile.Selection {
        std.debug.assert(self.active);
        return self.log_selection;
    }
};

const RetiredPresetMetadata = union(enum) {
    coordinated: SessionDurability.RetiredSelection,
    quarantined_transition: SessionDurability.RetiredSelection,

    fn deinit(self: *RetiredPresetMetadata) void {
        switch (self.*) {
            inline else => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};

/// Move-only values displaced by an allocation-free preset publication.
pub const RetiredPreset = struct {
    allocator: std.mem.Allocator,
    config_overlay: config.Selection.RetiredOverlay,
    runtime: ProviderRuntime.Owned,
    prompt: ?PromptAssembly.OwnedPrompt,
    metadata: RetiredPresetMetadata,
    preset_name: []u8,
    candidate_model_label: []u8,
    active: bool = true,

    pub fn deinit(self: *RetiredPreset) void {
        if (self.active) {
            self.metadata.deinit();
            if (self.prompt) |*value| value.deinit(self.allocator);
            self.runtime.deinit();
            self.config_overlay.deinit();
            self.allocator.free(self.candidate_model_label);
            self.allocator.free(self.preset_name);
        }
        self.* = undefined;
    }
};

/// Move-only old-log selection used while a preset transition settles tasks.
pub const TransitionSelection = struct {
    durability: SessionDurability.TransitionSelection,
    active: bool = true,

    pub fn deinit(self: *TransitionSelection) void {
        if (self.active) self.durability.deinit();
        self.* = undefined;
    }
};

pub const CommitResult = enum { written, unchanged, run_only };

pub const CurrentSelection = struct {
    generation: u64 = 0,
    provider: []const u8,
    provider_label: []const u8,
    model: []const u8,
    model_label: ?[]const u8,
    effort: ?[]const u8,
    preset: ?[]const u8,
    provider_efforts: ai.Effort.Set,
    efforts: ai.Effort.Set,
    model_metadata: ai.ModelMeta.Metadata,
    sort_models: bool = true,
    model_provenance: ModelProvenance = .inherited,
    model_discovered: bool = false,
};

/// Heap-stable live interactive selection. The owner is the only writer of
/// runtime and prompt state. Snapshots are borrowed only between commands.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    config_source: ConfigSource,
    builder: Builder,
    provider_source: ?ProviderSource = null,
    tools: ToolSelection,
    session: *agent.Session.Session,
    durability: *SessionDurability.Owner,
    runtime: ProviderRuntime.Owned,
    prompt: ?PromptAssembly.OwnedPrompt,
    tool_list: []const tool.Tool.Tool,
    image_input: ai.Provider.ImageInput,
    context_limit: ?u64,
    model_metadata_source: ?agent.ModelMetadataSource.ModelMetadataSource,
    image_input_source: ?agent.ImageInputSource.ImageInputSource,
    model_hints_source: ?ProviderConfig.ModelHintsSource = null,
    reported_metadata: ?ai.ModelMeta.Metadata = null,
    sort_models: bool = true,
    model_provenance: ModelProvenance = .inherited,
    state_writer: ?config.StateWriter.Writer = null,
    views: ?Views = null,
    generation: u64 = 0,
    preset_transition_generation: u64 = 0,
    committing: bool = false,
    catalog_lookup_active: bool = false,
    bound_address: ?usize = null,

    pub fn deinit(self: *Owner) void {
        self.assertStable();
        if (self.prompt) |*prompt| prompt.deinit(self.allocator);
        self.runtime.deinit();
        self.* = undefined;
    }

    pub fn setViews(self: *Owner, views: Views) void {
        std.debug.assert(self.bound_address == null);
        self.bound_address = @intFromPtr(self);
        self.views = views;
        views.publish(self.derived());
    }

    pub fn current(self: *const Owner) CurrentSelection {
        self.assertStable();
        std.debug.assert(!self.committing);
        return .{
            .generation = self.generation,
            .provider = self.runtime.metadata.provider_id,
            .provider_label = self.runtime.metadata.display_name,
            .model = self.runtime.model,
            .model_label = self.session.currentSelection().model_label,
            .effort = self.runtime.effort,
            .preset = self.session.currentSelection().preset,
            .provider_efforts = self.runtime.metadata.provider_efforts,
            .efforts = self.runtime.metadata.efforts,
            .model_metadata = self.runtime.metadata.model,
            .sort_models = self.sort_models,
            .model_provenance = self.model_provenance,
            .model_discovered = self.runtime.model_discovered,
        };
    }

    /// Borrows the process-owned preset registry for one synchronous command.
    pub fn lookupPreset(self: *const Owner, name: []const u8) config.Preset.BorrowedLookup {
        self.assertStable();
        std.debug.assert(!self.committing);
        return self.config_source.lookupPreset(name);
    }

    /// Borrows valid process-owned preset plans for one synchronous picker.
    pub fn presetPlans(self: *const Owner) []const config.Preset.Plan {
        self.assertStable();
        std.debug.assert(!self.committing);
        return self.config_source.presetPlans();
    }

    pub fn providerChoices(self: *Owner) !ProviderConfig.ProviderChoices {
        self.assertStable();
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        const source = self.provider_source orelse return error.Unsupported;
        return source.choices(self.allocator);
    }

    pub fn recheckProvider(
        self: *Owner,
        io: std.Io,
        provider: []const u8,
        tick: ?ai.Provider.Tick,
    ) !bool {
        self.assertStable();
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        const source = self.provider_source orelse return false;
        return source.recheck(io, provider, tick);
    }

    /// Builds a non-streaming runtime under provider defaults. Its prepared
    /// config overlay is destroyed with it and can never be published.
    pub fn prepareProviderListing(self: *Owner, provider: []const u8) !ProviderListingCandidate {
        self.assertStable();
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        const source = self.provider_source orelse return error.Unsupported;
        var config_run = try self.config_source.prepare(.{
            .provider = provider,
            .model = config.Store.default_sentinel,
            .effort = config.Store.default_sentinel,
            .exit_preset = true,
        });
        errdefer config_run.deinit(self.allocator);
        var runtime = try source.listing(config_run.store());
        errdefer runtime.deinit();
        const sort_models = try resolveSortModels(
            self.allocator,
            config_run.store(),
            runtime.keepModelOrder(),
        );
        return .{
            .allocator = self.allocator,
            .config_run = config_run,
            .runtime = runtime,
            .sort_models = sort_models,
        };
    }

    /// Enumerates through the live runtime. Returned ownership belongs to the caller.
    pub fn listModels(
        self: *Owner,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?ai.Provider.Tick,
    ) ai.ModelListing.Error!ai.ModelListing.Outcome {
        self.assertStable();
        std.debug.assert(!self.committing);
        return self.runtime.listModels(allocator, io, tick);
    }

    /// Reads one current catalog snapshot without starting or waiting for refresh work.
    /// Output metadata aligns with `models` and owns all variable data inline.
    pub fn catalogMetadataBatch(
        self: *Owner,
        allocator: std.mem.Allocator,
        models: []const ai.ModelListing.Model,
        output: []ai.ModelMeta.Metadata,
    ) error{ OutOfMemory, Reentrant, SelectionChanged }!void {
        self.assertStable();
        std.debug.assert(models.len == output.len);
        std.debug.assert(models.len <= ai.ModelListing.maximum_models);
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        for (output) |*value| value.* = .{};
        return self.catalogMetadataBatchFor(
            allocator,
            self.runtime.metadata.catalog_id,
            models,
            output,
        );
    }

    pub fn catalogMetadataBatchFor(
        self: *Owner,
        allocator: std.mem.Allocator,
        catalog_id_value: ?[]const u8,
        models: []const ai.ModelListing.Model,
        output: []ai.ModelMeta.Metadata,
    ) error{ OutOfMemory, Reentrant, SelectionChanged }!void {
        self.assertStable();
        std.debug.assert(models.len == output.len);
        std.debug.assert(models.len <= ai.ModelListing.maximum_models);
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        for (output) |*value| value.* = .{};
        const source = self.model_hints_source orelse return;
        const catalog_id = catalog_id_value orelse return;
        const generation = self.generation;

        self.catalog_lookup_active = true;
        defer self.catalog_lookup_active = false;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const model_ids = try scratch.alloc([]const u8, models.len);
        const contributions = try scratch.alloc(ai.ModelCatalog.Contribution, models.len);
        for (models, model_ids) |model_value, *model_id| model_id.* = model_value.id;
        try source.lookupBatch(scratch, catalog_id, model_ids, contributions);
        if (self.generation != generation) return error.SelectionChanged;
        for (contributions, output) |contribution, *metadata| metadata.* = contribution.metadata;
    }

    pub fn snapshot(self: *Owner) Interactive.TurnSnapshot {
        self.assertStable();
        std.debug.assert(!self.committing);
        return .{
            .provider = self.runtime.provider(),
            .model = self.runtime.model,
            .model_metadata = self.runtime.metadata.model,
            .model_metadata_source = self.model_metadata_source,
            .system_prompt = self.promptBytes(),
            .tools = self.tool_list,
            .effort = self.runtime.effort,
            .image_input = self.image_input,
            .image_input_source = self.image_input_source,
        };
    }

    pub fn prepareDetached(
        self: *Owner,
        request: Request,
        intent: Intent,
    ) PrepareError!DetachedCandidate {
        self.assertStable();
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        if ((intent == .session_restore) != (request == .restore)) return error.InvalidIntent;

        var overlay: ConfigOverlay = switch (request) {
            .run => |requested| .{ .run = self.config_source.prepare(.{
                .provider = requested.provider,
                .model = requested.model,
                .effort = requested.effort orelse config.Store.default_sentinel,
                .exit_preset = true,
            }) catch |err| return mapPreparationError(intent, err) },
            .preset => |name| blk: {
                const plan = switch (self.config_source.lookupPreset(name)) {
                    .missing => return error.PresetMissing,
                    .invalid => return error.PresetInvalid,
                    .plan => |value| value,
                };
                break :blk .{ .preset = self.config_source.preparePreset(plan) catch |err|
                    return mapPreparationError(intent, err) };
            },
            .restore => |restore| blk: {
                const recorded_preset = restore.selection.preset;
                var lookup_value: config.Preset.Lookup = if (recorded_preset) |name|
                    borrowedLookup(self.config_source.lookupPreset(name))
                else
                    .missing;
                const lookup = if (recorded_preset) |name| if (name.len != 0) &lookup_value else null else null;
                break :blk .{ .restore = self.config_source.prepareRestore(.{
                    .provider = restore.selection.provider,
                    .model = restore.selection.model,
                    .effort = restore.selection.effort,
                    .preset = recorded_preset,
                }, lookup) catch |err| return mapPreparationError(intent, err) };
            },
        };
        errdefer overlay.deinit(self.allocator);

        const requested_input: RequestedSelection = switch (request) {
            .run => |value| value,
            .preset => .{ .effort = null },
            .restore => .{ .effort = null, .reported_metadata = .{ .replace = null } },
        };
        const reported_metadata = switch (requested_input.reported_metadata) {
            .preserve => self.reported_metadata,
            .replace => |value| value,
        };
        var built = self.builder.build(overlay.store(), reported_metadata) catch |err|
            return mapPreparationError(intent, err);
        errdefer built.deinit(self.allocator);

        const provider_changed = !std.mem.eql(
            u8,
            built.runtime.metadata.provider_id,
            self.runtime.metadata.provider_id,
        );
        const recorded_label = switch (request) {
            .run => |value| value.model_label,
            .preset => null,
            .restore => |value| value.selection.model_label,
        };
        const model_label = self.allocator.dupe(u8, recorded_label orelse built.runtime.model) catch
            return error.OutOfMemory;
        errdefer self.allocator.free(model_label);
        const preset_bytes: ?[]const u8 = switch (request) {
            .preset => |name| name,
            .restore => |value| switch (overlay) {
                .restore => |prepared| if (prepared.outcome == .restored)
                    value.selection.preset
                else
                    null,
                else => unreachable,
            },
            .run => null,
        };
        const owned_preset = if (preset_bytes) |value|
            self.allocator.dupe(u8, value) catch return error.OutOfMemory
        else
            null;
        errdefer if (owned_preset) |value| self.allocator.free(value);

        const session_selection: agent.Session.Selection = .{
            .provider_id = built.runtime.metadata.provider_id,
            .model = built.runtime.model,
            .model_label = model_label,
            .effort = built.runtime.effort,
            .preset = owned_preset,
        };
        const log_selection: persistence.SessionFile.Selection = .{
            .provider = session_selection.provider_id,
            .model = session_selection.model,
            .model_label = session_selection.model_label,
            .effort = session_selection.effort,
            .preset = session_selection.preset,
        };
        const tool_selection: tool.Bash.RunSelection = .{
            .provider = built.runtime.metadata.provider_id,
            .model = built.runtime.model,
            .effort = built.runtime.effort,
        };
        self.tools.validate(tool_selection) catch |err| return mapPreparationError(intent, err);
        return .{
            .owner = self,
            .generation = self.generation,
            .allocator = self.allocator,
            .config_overlay = overlay,
            .built = built,
            .requested = .{
                .provider = built.runtime.metadata.provider_id,
                .model = built.runtime.model,
                .model_label = model_label,
                .effort = built.runtime.effort,
                .reported_metadata = .{ .replace = reported_metadata },
                .model_provenance = requested_input.model_provenance,
                .effort_selected = requested_input.effort_selected,
            },
            .session_selection = session_selection,
            .log_selection = log_selection,
            .tool_selection = tool_selection,
            .intent = intent,
            .restore_outcome = switch (overlay) {
                .restore => |value| value.outcome,
                else => null,
            },
            .owned_model_label = model_label,
            .owned_preset = owned_preset,
            .reported_metadata = reported_metadata,
            .model_provenance = switch (requested_input.model_provenance) {
                .inherited => if (provider_changed) .inherited else self.model_provenance,
                .concrete, .discovered, .explicit => requested_input.model_provenance,
            },
        };
    }

    pub fn prepare(self: *Owner, requested: RequestedSelection) !Candidate {
        self.assertStable();
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        var config_run = try self.config_source.prepare(.{
            .provider = requested.provider,
            .model = requested.model,
            .effort = requested.effort orelse config.Store.default_sentinel,
            .exit_preset = true,
        });
        errdefer config_run.deinit(self.allocator);

        const reported_metadata = switch (requested.reported_metadata) {
            .preserve => self.reported_metadata,
            .replace => |value| value,
        };
        var built = try self.builder.build(config_run.store(), reported_metadata);
        errdefer built.deinit(self.allocator);
        const provider_changed = !std.mem.eql(
            u8,
            built.runtime.metadata.provider_id,
            self.runtime.metadata.provider_id,
        );
        const selection: agent.Session.Selection = .{
            .provider_id = built.runtime.metadata.provider_id,
            .model = built.runtime.model,
            .model_label = requested.model_label orelse if (provider_changed)
                built.runtime.model
            else
                self.session.currentSelection().model_label orelse built.runtime.model,
            .effort = built.runtime.effort,
            .preset = null,
        };
        const log_selection: persistence.SessionFile.Selection = .{
            .provider = selection.provider_id,
            .model = selection.model,
            .model_label = selection.model_label,
            .effort = selection.effort,
            .preset = selection.preset,
        };
        var prepared_session = try self.durability.prepareSelection(self.session, log_selection);
        errdefer prepared_session.deinit();

        const tool_selection: tool.Bash.RunSelection = .{
            .provider = built.runtime.metadata.provider_id,
            .model = built.runtime.model,
            .effort = built.runtime.effort,
        };
        try self.tools.validate(tool_selection);
        return .{
            .allocator = self.allocator,
            .config_run = config_run,
            .built = built,
            .session = prepared_session,
            .tool_selection = tool_selection,
            .reported_metadata = reported_metadata,
            .model_provenance = switch (requested.model_provenance) {
                .inherited => if (provider_changed) .inherited else self.model_provenance,
                .concrete, .discovered, .explicit => requested.model_provenance,
            },
            .persistent_model = switch (requested.model_provenance) {
                .concrete, .explicit => built.runtime.model,
                .inherited, .discovered => null,
            },
            .persistent_effort = if (requested.effort_selected)
                built.runtime.effort orelse config.Store.default_sentinel
            else
                null,
        };
    }

    /// Prepares one preset against the cached prospective Store. Quarantined
    /// transitions stage only stable session metadata.
    pub fn preparePreset(
        self: *Owner,
        name: []const u8,
        authority: PresetAuthority,
    ) !PresetCandidate {
        self.assertStable();
        if (self.committing or self.catalog_lookup_active) return error.Reentrant;
        const plan = switch (self.config_source.lookupPreset(name)) {
            .missing => return error.PresetMissing,
            .invalid => return error.PresetInvalid,
            .plan => |value| value,
        };
        const preset_name = try self.allocator.dupe(u8, plan.name);
        errdefer self.allocator.free(preset_name);
        var config_preset = try self.config_source.preparePreset(plan);
        errdefer config_preset.deinit();
        var built = try self.builder.build(config_preset.store(), self.reported_metadata);
        errdefer built.deinit(self.allocator);
        const owned_model_label = if (std.mem.eql(
            u8,
            built.runtime.metadata.provider_id,
            "llamacpp",
        ))
            try ai.LocalDiscovery.modelLabel(self.allocator, built.runtime.model)
        else
            try self.allocator.dupe(u8, built.runtime.model);
        errdefer self.allocator.free(owned_model_label);

        const agent_selection: agent.Session.Selection = .{
            .provider_id = built.runtime.metadata.provider_id,
            .model = built.runtime.model,
            .model_label = owned_model_label,
            .effort = built.runtime.effort,
            .preset = preset_name,
        };
        const log_selection: persistence.SessionFile.Selection = .{
            .provider = agent_selection.provider_id,
            .model = agent_selection.model,
            .model_label = agent_selection.model_label,
            .effort = agent_selection.effort,
            .preset = agent_selection.preset,
        };
        var metadata: PresetMetadataPreparation = switch (authority) {
            .coordinated => .{ .coordinated = try self.durability.prepareSelection(self.session, log_selection) },
            .quarantined_transition => .{
                .quarantined_transition = try self.durability.prepareSelectionForQuarantinedTransition(
                    self.session,
                    log_selection,
                ),
            },
        };
        errdefer metadata.deinit();

        const tool_selection: tool.Bash.RunSelection = .{
            .provider = built.runtime.metadata.provider_id,
            .model = built.runtime.model,
            .effort = built.runtime.effort,
        };
        try self.tools.validate(tool_selection);
        const provider_changed = !std.mem.eql(
            u8,
            built.runtime.metadata.provider_id,
            self.runtime.metadata.provider_id,
        );
        return .{
            .allocator = self.allocator,
            .owner = self,
            .generation = self.generation,
            .config_preset = config_preset,
            .built = built,
            .metadata = metadata,
            .agent_selection = agent_selection,
            .log_selection = log_selection,
            .tool_selection = tool_selection,
            .reported_metadata = self.reported_metadata,
            .model_provenance = if (provider_changed) .inherited else self.model_provenance,
            .preset_name = preset_name,
            .owned_model_label = owned_model_label,
        };
    }

    /// Publishes every live preset view without allocation, returns displaced
    /// ownership through `retired`, then attempts user-state persistence.
    pub fn commitPreset(
        self: *Owner,
        candidate: *PresetCandidate,
        retired: *RetiredPreset,
    ) CommitResult {
        self.assertStable();
        std.debug.assert(candidate.active);
        std.debug.assert(candidate.owner == self);
        std.debug.assert(candidate.generation == self.generation);
        std.debug.assert(!self.committing);
        std.debug.assert(!self.catalog_lookup_active);
        self.committing = true;

        const old_config = self.config_source.publishPreset(&candidate.config_preset);
        const old_runtime = self.runtime;
        const old_prompt = self.prompt;
        self.runtime = candidate.built.runtime;
        self.prompt = candidate.built.prompt;
        self.image_input = candidate.built.image_input;
        self.context_limit = candidate.built.context_limit;
        self.sort_models = candidate.built.sort_models;
        candidate.built.active = false;
        const old_metadata: RetiredPresetMetadata = switch (candidate.metadata) {
            .coordinated => |*value| .{
                .coordinated = self.durability.publishSelectionRetired(self.session, value),
            },
            .quarantined_transition => |*value| .{
                .quarantined_transition = self.durability.publishSelectionForQuarantinedTransitionRetired(
                    self.session,
                    value,
                ),
            },
        };
        self.tools.publish(candidate.tool_selection);
        self.reported_metadata = candidate.reported_metadata;
        self.model_provenance = candidate.model_provenance;
        self.generation +%= 1;
        self.preset_transition_generation +%= 1;
        if (self.views) |views| views.publish(self.derived());
        candidate.active = false;
        retired.* = .{
            .allocator = self.allocator,
            .config_overlay = old_config,
            .runtime = old_runtime,
            .prompt = old_prompt,
            .metadata = old_metadata,
            .preset_name = candidate.preset_name,
            .candidate_model_label = candidate.owned_model_label,
        };
        self.committing = false;

        const writer = self.state_writer orelse return .run_only;
        const outcome = writer.write(.{
            .provider = self.runtime.metadata.provider_id,
            .model = null,
            .effort = null,
            .preset = retired.preset_name,
        }) catch return .run_only;
        return switch (outcome) {
            .written => .written,
            .unchanged => .unchanged,
            .unavailable, .failed => .run_only,
        };
    }

    /// Starts old-branch settlement without exposing retired metadata internals.
    pub fn beginTransitionSelection(
        self: *Owner,
        retired: *RetiredPreset,
    ) TransitionSelection {
        const durability = switch (retired.metadata) {
            .coordinated => |*metadata| self.durability.beginTransitionSelection(metadata),
            .quarantined_transition => unreachable,
        };
        return .{ .durability = durability };
    }

    /// Restores the published preset selection and durably flushes it when materialized.
    pub fn restoreTransitionSelection(
        self: *Owner,
        token: *TransitionSelection,
    ) SessionDurability.TransitionSelectionFlush {
        std.debug.assert(token.active);
        token.durability.restore();
        return self.durability.flushRestoredTransitionSelection(self.session);
    }

    /// Publishes the live candidate first. Persistent failure never rolls back
    /// the run and is represented only by run_only.
    pub fn commit(self: *Owner, candidate: *Candidate) CommitResult {
        self.assertStable();
        std.debug.assert(candidate.active);
        std.debug.assert(!self.committing);
        std.debug.assert(!self.catalog_lookup_active);
        self.committing = true;
        defer self.committing = false;
        self.config_source.publish(&candidate.config_run);

        var old_runtime = self.runtime;
        self.runtime = candidate.built.runtime;
        var old_prompt = self.prompt;
        self.prompt = candidate.built.prompt;
        self.image_input = candidate.built.image_input;
        self.context_limit = candidate.built.context_limit;
        self.sort_models = candidate.built.sort_models;
        candidate.built.active = false;

        self.durability.publishSelection(self.session, &candidate.session);
        self.tools.publish(candidate.tool_selection);
        self.reported_metadata = candidate.reported_metadata;
        self.model_provenance = candidate.model_provenance;
        self.generation +%= 1;
        if (self.views) |views| views.publish(self.derived());
        candidate.active = false;

        if (old_prompt) |*prompt| prompt.deinit(self.allocator);
        old_runtime.deinit();

        const writer = self.state_writer orelse return .run_only;
        const outcome = writer.write(.{
            .provider = self.runtime.metadata.provider_id,
            .model = candidate.persistent_model,
            .effort = candidate.persistent_effort,
        }) catch return .run_only;
        return switch (outcome) {
            .written => .written,
            .unchanged => .unchanged,
            .unavailable, .failed => .run_only,
        };
    }

    fn assertStable(self: *const Owner) void {
        if (self.bound_address) |address| std.debug.assert(address == @intFromPtr(self));
    }

    fn promptBytes(self: *const Owner) []const u8 {
        return if (self.prompt) |prompt| prompt.bytes else "";
    }

    fn derived(self: *Owner) Derived {
        return .{
            .runtime = &self.runtime,
            .system_prompt = self.promptBytes(),
            .image_input = self.image_input,
            .context_limit = self.context_limit,
            .preset_tint = self.config_source.presetTint(),
        };
    }
};

pub fn validateDetached(self: *Owner, candidate: *const DetachedCandidate) error{StaleCandidate}!void {
    self.assertStable();
    if (!candidate.active or candidate.owner != self or candidate.generation != self.generation) {
        return error.StaleCandidate;
    }
}

/// Publishes only detached selection state. ConversationRuntime must validate
/// its coordinated lease before calling this function. No writer or cleanup
/// runs here.
pub fn publishDetached(self: *Owner, candidate: *DetachedCandidate) RetiredRuntime {
    self.assertStable();
    validateDetached(self, candidate) catch unreachable;
    std.debug.assert(self.committing);
    std.debug.assert(!self.catalog_lookup_active);

    const old_config = candidate.config_overlay.publish(self.config_source);
    const old_runtime = self.runtime;
    const old_prompt = self.prompt;
    self.runtime = candidate.built.runtime;
    self.prompt = candidate.built.prompt;
    self.image_input = candidate.built.image_input;
    self.context_limit = candidate.built.context_limit;
    self.sort_models = candidate.built.sort_models;
    candidate.built.active = false;
    self.tools.publish(candidate.tool_selection);
    self.reported_metadata = candidate.reported_metadata;
    self.model_provenance = candidate.model_provenance;
    self.generation +%= 1;
    if (self.views) |views| views.publish(self.derived());
    candidate.active = false;
    return .{
        .allocator = self.allocator,
        .config_overlay = old_config,
        .runtime = old_runtime,
        .prompt = old_prompt,
        .candidate_model_label = candidate.owned_model_label,
        .candidate_preset = candidate.owned_preset,
    };
}

fn borrowedLookup(value: config.Preset.BorrowedLookup) config.Preset.Lookup {
    return switch (value) {
        .missing => .missing,
        .invalid => |invalid| .{ .invalid = invalid.* },
        .plan => |plan| .{ .plan = plan.* },
    };
}

fn mapPreparationError(_: Intent, err: anyerror) PrepareError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownProvider, error.MissingProvider => error.RestoreUnknownProvider,
        error.InvalidModelId, error.MissingModel => error.RestoreModelUnavailable,
        error.ProviderUnavailable,
        error.AdapterUnavailable,
        error.UnsupportedWire,
        error.MissingCredential,
        error.InvalidAuth,
        error.MissingSessionCacheKey,
        => error.RestoreRuntimeUnavailable,
        else => error.RestorePreparationFailed,
    };
}

fn resolveSortModels(
    allocator: std.mem.Allocator,
    store: config.Store,
    keep_provider_order: bool,
) !bool {
    var setting = try config.Settings.getString(store, allocator, "sort_models");
    defer setting.deinit(allocator);
    const value = setting.value orelse return !keep_provider_order;
    if (std.ascii.eqlIgnoreCase(value, "auto")) return !keep_provider_order;
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "on")) return true;
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "off")) return false;
    return !keep_provider_order;
}

test "prospective provider sorting honors global policy before provider order" {
    const environment: TestEnvironment = .{};
    var automatic_document = try config.Document.parse(std.testing.allocator, "{}", .{});
    defer automatic_document.deinit();
    const automatic = config.Store.init(.{
        .run = &automatic_document,
        .registry = config.Settings.storeRegistry(),
        .environment = .from(&environment),
    });
    try std.testing.expect(!try resolveSortModels(std.testing.allocator, automatic, true));

    var enabled_document = try config.Document.parse(std.testing.allocator, "{\"sort_models\":true}", .{});
    defer enabled_document.deinit();
    const enabled = config.Store.init(.{
        .run = &enabled_document,
        .registry = config.Settings.storeRegistry(),
        .environment = .from(&environment),
    });
    try std.testing.expect(try resolveSortModels(std.testing.allocator, enabled, true));
}

const TestEnvironment = struct {
    pub fn get(_: *const TestEnvironment, _: []const u8) ?[]const u8 {
        return null;
    }
};

const TestTransport = struct {
    pub fn ssePost(
        _: std.mem.Allocator,
        _: std.Io,
        _: *TestTransport,
        _: ai.Transport.Request,
        _: ai.Transport.EventSink,
    ) ai.Transport.StreamError!ai.Transport.Result {
        return error.InvalidRequest;
    }
};

const TestBuilder = struct {
    allocator: std.mem.Allocator,
    environment: *const TestEnvironment,
    definition: *const config.ProviderDefinitions.Definition,
    transport: *TestTransport,
    metadata: *const ai.ModelMeta.Metadata,
    failure: ?anyerror = null,

    pub fn build(
        self: *TestBuilder,
        store: config.Store,
        reported_metadata: ?ai.ModelMeta.Metadata,
    ) !Built {
        if (self.failure) |err| return err;
        var runtime = try ProviderRuntime.init(.{
            .allocator = self.allocator,
            .store = store,
            .api_key_environment = .from(self.environment),
            .provider_definitions = self.definition[0..1],
            .hints = .{ .reported = if (reported_metadata) |*value| value else null },
        }, ai.Transport.Transport.from(self.transport), 0);
        errdefer runtime.deinit();
        const prompt = try std.fmt.allocPrint(
            self.allocator,
            "model={s};effort={s}",
            .{ runtime.model, runtime.effort orelse "default" },
        );
        const high = if (runtime.effort) |value| std.mem.eql(u8, value, "high") else false;
        return .{
            .runtime = runtime,
            .prompt = .{ .bytes = prompt },
            .image_input = if (high) .supported else .unsupported,
            .context_limit = if (high) 222 else 111,
            .sort_models = !high,
        };
    }
};

const TestTools = struct {
    provider: [128]u8 = undefined,
    provider_len: usize = 0,
    model: [128]u8 = undefined,
    model_len: usize = 0,
    effort: [ai.Effort.maximum_value_bytes]u8 = undefined,
    effort_len: usize = 0,
    publications: usize = 0,
    fail_validation: bool = false,

    pub fn validateRunSelection(self: *TestTools, selection: tool.Bash.RunSelection) !void {
        if (self.fail_validation) return error.ToolPreparationFailed;
        try tool.Bash.validateRunSelection(selection);
    }

    pub fn publishRunSelection(self: *TestTools, selection: tool.Bash.RunSelection) void {
        self.provider_len = selection.provider.len;
        @memcpy(self.provider[0..self.provider_len], selection.provider);
        const model = selection.model orelse "";
        self.model_len = model.len;
        @memcpy(self.model[0..self.model_len], model);
        const effort_value = selection.effort orelse "";
        self.effort_len = effort_value.len;
        @memcpy(self.effort[0..self.effort_len], effort_value);
        self.publications += 1;
    }
};

const PublicationObserver = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,

    fn allocator(self: *PublicationObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PublicationObserver = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *PublicationObserver = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *PublicationObserver = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *PublicationObserver = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const TestViews = struct {
    publications: usize = 0,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    image_input: ai.Provider.ImageInput = .unknown,
    context_limit: ?u64 = null,
    preset_tint: ?[]const u8 = null,

    pub fn publishSelectionViews(self: *TestViews, derived: Derived) void {
        self.publications += 1;
        self.provider = derived.runtime.metadata.provider_id;
        self.model = derived.runtime.model;
        self.prompt = derived.system_prompt;
        self.effort = derived.runtime.effort;
        self.image_input = derived.image_input;
        self.context_limit = derived.context_limit;
        self.preset_tint = derived.preset_tint;
    }
};

const TestConfigSource = struct {
    selection: *config.Selection,
    plans: []const config.Preset.Plan = &.{},
    invalid: []const config.Preset.Invalid = &.{},
    lookup_override: ?config.Preset.BorrowedLookup = null,
    invalidate_preset_name_on_publish: bool = false,

    pub fn prepareRun(
        self: *const TestConfigSource,
        change: config.Selection.RunChange,
    ) !config.Selection.PreparedRun {
        return self.selection.prepareRun(change);
    }

    pub fn publishRun(self: *TestConfigSource, prepared: *config.Selection.PreparedRun) void {
        self.selection.publishRun(prepared);
    }

    pub fn publishRunRetired(
        self: *TestConfigSource,
        prepared: *config.Selection.PreparedRun,
    ) config.Selection.RetiredOverlay {
        return self.selection.publishRunRetired(prepared);
    }

    pub fn lookupPreset(self: *const TestConfigSource, name: []const u8) config.Preset.BorrowedLookup {
        if (self.lookup_override) |value| return value;
        for (self.plans) |*plan| if (std.mem.eql(u8, plan.name, name)) return .{ .plan = plan };
        for (self.invalid) |*invalid| if (std.mem.eql(u8, invalid.name, name)) return .{ .invalid = invalid };
        return .missing;
    }

    pub fn presetPlans(self: *const TestConfigSource) []const config.Preset.Plan {
        return self.plans;
    }

    pub fn tint(self: *const TestConfigSource) ?[]const u8 {
        return self.selection.presetTint();
    }

    pub fn preparePreset(
        self: *const TestConfigSource,
        plan: *const config.Preset.Plan,
    ) !config.Selection.PreparedPreset {
        return self.selection.preparePreset(.run, plan);
    }

    pub fn publishPreset(
        self: *TestConfigSource,
        prepared: *config.Selection.PreparedPreset,
    ) config.Selection.RetiredOverlay {
        const retired = self.selection.publishPreset(prepared);
        if (self.invalidate_preset_name_on_publish) @memset(@constCast(self.plans[0].name), 'x');
        return retired;
    }

    pub fn prepareRestore(
        self: *const TestConfigSource,
        metadata: config.Selection.RestoreMetadata,
        lookup: ?*const config.Preset.Lookup,
    ) !config.Selection.PreparedRestore {
        return self.selection.prepareRestoreRun(metadata, lookup);
    }

    pub fn publishRestore(
        self: *TestConfigSource,
        prepared: *config.Selection.PreparedRestore,
    ) config.Selection.RetiredOverlay {
        return self.selection.publishRestoreConversation(prepared);
    }
};

const CapturingStateWriter = struct {
    preset: [16]u8 = undefined,
    preset_len: usize = 0,

    fn writer(self: *CapturingStateWriter) config.StateWriter.Writer {
        return .{ .context = self, .write_fn = write };
    }

    fn write(
        context: *anyopaque,
        selection: config.StateWriter.Selection,
    ) error{OutOfMemory}!config.StateWriter.Outcome {
        const self: *CapturingStateWriter = @ptrCast(@alignCast(context));
        const preset = selection.preset orelse "";
        std.debug.assert(preset.len <= self.preset.len);
        @memcpy(self.preset[0..preset.len], preset);
        self.preset_len = preset.len;
        return .written;
    }
};

const TestRig = struct {
    allocator: std.mem.Allocator,
    selection: config.Selection,
    config_source: TestConfigSource,
    session: agent.Session.Session,
    durability: *SessionDurability.Owner,
    builder: TestBuilder,
    tools: TestTools = .{},
    views: TestViews = .{},
    live: Owner,

    fn init(allocator: std.mem.Allocator) !TestRig {
        const environment = try allocator.create(TestEnvironment);
        errdefer allocator.destroy(environment);
        environment.* = .{};
        const definition = try allocator.create(config.ProviderDefinitions.Definition);
        errdefer allocator.destroy(definition);
        definition.* = .{
            .id = @constCast("selection-test"),
            .api = .openai_responses,
            .base_url = @constCast("https://selection.test/v1"),
            .catalog_id = @constCast("selection-test"),
        };
        const transport = try allocator.create(TestTransport);
        errdefer allocator.destroy(transport);
        transport.* = .{};
        const metadata = try allocator.create(ai.ModelMeta.Metadata);
        errdefer allocator.destroy(metadata);
        metadata.* = .{
            .efforts = try ai.Effort.Set.init(&.{ "low", "high" }),
            .context_window = 64_000,
            .image_input = .yes,
        };

        var selection = config.Selection.init(allocator, .{
            .registry = config.Settings.storeRegistry(),
            .environment = config.Store.Environment.from(environment),
        });
        errdefer selection.deinit();
        try selection.setRun(.{
            .provider = "selection-test",
            .model = "old-model",
            .effort = "low",
            .preset = "work",
        });
        var runtime = try ProviderRuntime.init(.{
            .allocator = allocator,
            .store = selection.store(),
            .api_key_environment = .from(environment),
            .provider_definitions = definition[0..1],
            .hints = .{ .reported = metadata },
        }, ai.Transport.Transport.from(transport), 0);
        errdefer runtime.deinit();
        const prompt_bytes = try allocator.dupe(u8, "model=old-model;effort=low");
        errdefer allocator.free(prompt_bytes);
        var session = try agent.Session.Session.init(allocator, .{
            .provider_id = "selection-test",
            .model = "old-model",
            .model_label = "old-model",
            .effort = "low",
            .preset = "work",
        });
        errdefer session.deinit();
        var no_log: ?persistence.SessionFile.Log = null;
        const durability = try SessionDurability.Owner.create(allocator, &no_log, .{});
        errdefer durability.deinit();

        var rig: TestRig = undefined;
        rig.allocator = allocator;
        rig.selection = selection;
        rig.config_source = .{ .selection = &rig.selection };
        rig.session = session;
        rig.durability = durability;
        rig.builder = .{
            .allocator = allocator,
            .environment = environment,
            .definition = definition,
            .transport = transport,
            .metadata = metadata,
        };
        rig.tools = .{};
        rig.views = .{};
        rig.live = .{
            .allocator = allocator,
            .config_source = ConfigSource.from(&rig.config_source),
            .builder = Builder.from(&rig.builder),
            .tools = ToolSelection.from(&rig.tools),
            .session = &rig.session,
            .durability = rig.durability,
            .runtime = runtime,
            .prompt = .{ .bytes = prompt_bytes },
            .tool_list = &.{},
            .image_input = .unsupported,
            .context_limit = 111,
            .model_metadata_source = null,
            .image_input_source = null,
        };
        return rig;
    }

    fn stabilize(self: *TestRig) void {
        self.config_source.selection = &self.selection;
        self.live.config_source = ConfigSource.from(&self.config_source);
        self.live.builder = Builder.from(&self.builder);
        self.live.tools = ToolSelection.from(&self.tools);
        self.live.session = &self.session;
        self.live.durability = self.durability;
        self.live.setViews(Views.from(&self.views));
    }

    fn deinit(self: *TestRig) void {
        const environment = self.builder.environment;
        const definition = self.builder.definition;
        const transport = self.builder.transport;
        const metadata = self.builder.metadata;
        self.live.deinit();
        self.durability.deinit();
        self.session.deinit();
        self.selection.deinit();
        self.allocator.destroy(metadata);
        self.allocator.destroy(transport);
        self.allocator.destroy(definition);
        self.allocator.destroy(environment);
        self.* = undefined;
    }
};

fn exerciseCandidateAllocationFailures(allocator: std.mem.Allocator) !void {
    var rig = try TestRig.init(allocator);
    defer rig.deinit();
    rig.stabilize();
    const before = rig.live.snapshot();
    var candidate = rig.live.prepare(.{
        .provider = "selection-test",
        .model = "old-model",
        .model_label = "old-model",
        .effort = "high",
    }) catch |err| {
        const after = rig.live.snapshot();
        try std.testing.expectEqualStrings(before.model, after.model);
        try std.testing.expectEqualStrings(before.effort.?, after.effort.?);
        try std.testing.expectEqualStrings(before.system_prompt, after.system_prompt);
        try std.testing.expectEqual(@as(usize, 0), rig.tools.publications);
        return err;
    };
    defer candidate.deinit();
    try std.testing.expectEqualStrings("low", rig.live.snapshot().effort.?);
    try std.testing.expectEqualStrings("work", rig.session.currentSelection().preset.?);
}

fn exercisePresetCandidateAllocationFailures(allocator: std.mem.Allocator) !void {
    var rig = try TestRig.init(allocator);
    defer rig.deinit();
    rig.stabilize();
    const plans = [_]config.Preset.Plan{.{
        .name = @constCast("review"),
        .provider = @constCast("selection-test"),
        .model = .{ .value = @constCast("preset-model") },
        .effort = .{ .value = @constCast("high") },
        .system_prompt = .{},
        .system_prompt_append = .{},
        .tint = .{},
        .description = .{},
    }};
    rig.config_source.plans = &plans;
    var candidate = rig.live.preparePreset("review", .coordinated) catch |err| {
        try std.testing.expectEqual(@as(u64, 0), rig.live.generation);
        try std.testing.expectEqualStrings("old-model", rig.live.snapshot().model);
        try std.testing.expectEqualStrings("work", rig.session.currentSelection().preset.?);
        try std.testing.expectEqual(@as(usize, 0), rig.tools.publications);
        return err;
    };
    candidate.deinit();
    try std.testing.expectEqual(@as(u64, 0), rig.live.generation);
}

test "preset candidate cancellation and every allocation failure preserve live state" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePresetCandidateAllocationFailures,
        .{},
    );
}

test "preset persistence owns its name across cache invalidation" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();
    var preset_name = [_]u8{ 'r', 'e', 'v', 'i', 'e', 'w' };
    const plans = [_]config.Preset.Plan{.{
        .name = &preset_name,
        .provider = @constCast("selection-test"),
        .model = .{ .value = @constCast("/models/Foo.GGUF") },
        .effort = .{},
        .system_prompt = .{},
        .system_prompt_append = .{},
        .tint = .{ .value = @constCast("rose") },
        .description = .{},
    }};
    rig.config_source.plans = &plans;
    rig.config_source.invalidate_preset_name_on_publish = true;
    try std.testing.expectEqual(@as(usize, 1), rig.live.presetPlans().len);
    try std.testing.expect(rig.live.lookupPreset("review") == .plan);
    var state_writer: CapturingStateWriter = .{};
    rig.live.state_writer = state_writer.writer();
    var candidate = try rig.live.preparePreset("review", .coordinated);
    defer if (candidate.active) candidate.deinit();

    var retired: RetiredPreset = undefined;
    try std.testing.expectEqual(.written, rig.live.commitPreset(&candidate, &retired));
    defer retired.deinit();
    try std.testing.expectEqualStrings("xxxxxx", &preset_name);
    try std.testing.expectEqualStrings("review", state_writer.preset[0..state_writer.preset_len]);
    try std.testing.expectEqualStrings("rose", rig.views.preset_tint.?);
    try std.testing.expectEqualStrings("/models/Foo.GGUF", rig.live.current().model_label.?);
    try std.testing.expect(rig.live.lookupPreset("review") == .missing);
}

test "critical preset publication defers every displaced free" {
    var observer: PublicationObserver = .{ .backing = std.testing.allocator };
    var rig = try TestRig.init(observer.allocator());
    defer rig.deinit();
    rig.stabilize();
    const plans = [_]config.Preset.Plan{.{
        .name = @constCast("review"),
        .provider = @constCast("selection-test"),
        .model = .{ .value = @constCast("preset-model") },
        .effort = .{ .value = @constCast("high") },
        .system_prompt = .{},
        .system_prompt_append = .{},
        .tint = .{},
        .description = .{},
    }};
    rig.config_source.plans = &plans;
    var candidate = try rig.live.preparePreset("review", .coordinated);
    defer if (candidate.active) candidate.deinit();

    const frees_before = observer.frees;
    var retired: RetiredPreset = undefined;
    _ = rig.live.commitPreset(&candidate, &retired);
    try std.testing.expectEqual(frees_before, observer.frees);
    retired.deinit();
    try std.testing.expect(observer.frees > frees_before);
}

test "candidate preparation failure at every allocation preserves live publication" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCandidateAllocationFailures,
        .{},
    );
}

test "successful publication changes every next-turn and derived selection view" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var optional_log: ?persistence.SessionFile.Log = try persistence.SessionFile.Log.prepare(
        std.testing.allocator,
        std.testing.io,
        .{
            .state_root = root,
            .cwd = "/work",
            .selection = .{
                .provider = "selection-test",
                .model = "old-model",
                .model_label = "old-model",
                .effort = "low",
                .preset = "work",
            },
            .timestamp = .{ .epoch_seconds = 0 },
            .uuid = [_]u8{
                0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
                0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
            },
            .writer_version = "test",
        },
    );
    rig.durability.deinit();
    rig.durability = try SessionDurability.Owner.create(std.testing.allocator, &optional_log, .{});
    rig.live.durability = rig.durability;
    const runtime_address = @intFromPtr(&rig.live.runtime);
    const view_publications_before = rig.views.publications;

    var candidate = try rig.live.prepare(.{
        .provider = "selection-test",
        .model = "old-model",
        .model_label = "Old model",
        .effort = "high",
        .reported_metadata = .{ .replace = .{ .context_window = 999, .tools = .no } },
        .model_provenance = .explicit,
    });
    defer candidate.deinit();
    try std.testing.expectEqualStrings("low", rig.live.snapshot().effort.?);
    _ = rig.live.commit(&candidate);

    const turn = rig.live.snapshot();
    try std.testing.expectEqual(runtime_address, @intFromPtr(&rig.live.runtime));
    try std.testing.expectEqualStrings("high", turn.effort.?);
    try std.testing.expectEqual(@as(u64, 999), turn.model_metadata.context_window);
    try std.testing.expectEqual(ai.ModelMeta.Support.no, turn.model_metadata.tools);
    try std.testing.expectEqual(ModelProvenance.explicit, rig.live.current().model_provenance);
    try std.testing.expectEqualStrings("model=old-model;effort=high", turn.system_prompt);
    try std.testing.expectEqual(ai.Provider.ImageInput.supported, turn.image_input);
    try std.testing.expectEqualStrings("high", rig.session.currentSelection().effort.?);
    try std.testing.expect(rig.session.currentSelection().preset == null);
    try std.testing.expect(!rig.durability.materialized());
    try std.testing.expectEqual(@as(usize, 1), rig.tools.publications);
    try std.testing.expectEqualStrings("selection-test", rig.tools.provider[0..rig.tools.provider_len]);
    try std.testing.expectEqualStrings("old-model", rig.tools.model[0..rig.tools.model_len]);
    try std.testing.expectEqualStrings("high", rig.tools.effort[0..rig.tools.effort_len]);
    try std.testing.expectEqual(view_publications_before + 1, rig.views.publications);
    try std.testing.expectEqualStrings("selection-test", rig.views.provider.?);
    try std.testing.expectEqualStrings("old-model", rig.views.model.?);
    try std.testing.expectEqualStrings("high", rig.views.effort.?);
    try std.testing.expectEqualStrings(turn.system_prompt, rig.views.prompt.?);
    try std.testing.expectEqual(ai.Provider.ImageInput.supported, rig.views.image_input);
    try std.testing.expectEqual(@as(?u64, 222), rig.views.context_limit);
    try std.testing.expect(!rig.live.current().sort_models);

    var effort_setting = try rig.selection.store().read(std.testing.allocator, "effort");
    defer effort_setting.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("high", effort_setting.value.?);
    var preset_setting = try rig.selection.store().read(std.testing.allocator, "preset");
    defer preset_setting.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", preset_setting.value.?);
}

const MutatingHints = struct {
    live: *Owner,
    batch_calls: usize = 0,

    pub fn lookup(
        _: *MutatingHints,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
    ) error{OutOfMemory}!ai.ModelCatalog.Contribution {
        return .{};
    }

    pub fn lookupBatch(
        self: *MutatingHints,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const []const u8,
        output: []ai.ModelCatalog.Contribution,
    ) error{OutOfMemory}!void {
        self.batch_calls += 1;
        for (output) |*value| value.* = .{};
        self.live.generation +%= 1;
    }
};

test "catalog batch detects generation changes and invokes the source once" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();
    var source: MutatingHints = .{ .live = &rig.live };
    rig.live.model_hints_source = ProviderConfig.ModelHintsSource.from(&source);
    const models = [_]ai.ModelListing.Model{ .{ .id = "a" }, .{ .id = "b" } };
    var metadata: [models.len]ai.ModelMeta.Metadata = undefined;
    try std.testing.expectError(
        error.SelectionChanged,
        rig.live.catalogMetadataBatch(std.testing.allocator, &models, &metadata),
    );
    try std.testing.expectEqual(@as(usize, 1), source.batch_calls);
}

test "effort changes preserve reported metadata and model changes can reset it" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();

    var selected = try rig.live.prepare(.{
        .model = "old-model",
        .model_label = "old-model",
        .effort = "high",
        .reported_metadata = .{ .replace = .{ .context_window = 999, .tools = .no } },
    });
    defer selected.deinit();
    _ = rig.live.commit(&selected);

    var effort_only = try rig.live.prepare(.{
        .model_label = "old-model",
        .effort = "low",
    });
    defer effort_only.deinit();
    try std.testing.expectEqual(@as(u64, 999), effort_only.built.runtime.metadata.model.context_window);
    try std.testing.expectEqual(ai.ModelMeta.Support.no, effort_only.built.runtime.metadata.model.tools);
    _ = rig.live.commit(&effort_only);
    try std.testing.expectEqual(@as(u64, 999), rig.live.current().model_metadata.context_window);

    var reset = try rig.live.prepare(.{
        .model = "old-model",
        .model_label = "old-model",
        .effort = "low",
        .reported_metadata = .{ .replace = null },
    });
    defer reset.deinit();
    try std.testing.expectEqual(@as(u64, 0), reset.built.runtime.metadata.model.context_window);
    _ = rig.live.commit(&reset);
    try std.testing.expectEqual(@as(u64, 0), rig.live.current().model_metadata.context_window);
}

const TestStateWriter = struct {
    outcome: config.StateWriter.Outcome,
    expected_model: ?[]const u8,
    expected_effort: ?[]const u8,
    expected_live_effort: ?[]const u8,
    live: *Owner,
    calls: usize = 0,
    valid: bool = false,

    fn erasedWrite(
        context: *anyopaque,
        selection: config.StateWriter.Selection,
    ) error{OutOfMemory}!config.StateWriter.Outcome {
        const self: *TestStateWriter = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.valid = std.mem.eql(u8, selection.provider, "selection-test") and
            optionalEqual(selection.model, self.expected_model) and
            optionalEqual(selection.effort, self.expected_effort) and
            optionalEqual(self.live.runtime.effort, self.expected_live_effort) and
            selection.preset == null;
        return self.outcome;
    }

    fn writer(self: *TestStateWriter) config.StateWriter.Writer {
        return .{ .context = self, .write_fn = erasedWrite };
    }
};

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

test "candidate owns temporary requested model and effort through commit" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();

    var writer: TestStateWriter = .{
        .outcome = .written,
        .expected_model = "temporary-model",
        .expected_effort = "high",
        .expected_live_effort = "high",
        .live = &rig.live,
    };
    rig.live.state_writer = writer.writer();
    const requested_model = try std.testing.allocator.dupe(u8, "temporary-model");
    const requested_effort = try std.testing.allocator.dupe(u8, "high");
    var candidate = try rig.live.prepare(.{
        .model = requested_model,
        .model_label = requested_model,
        .effort = requested_effort,
        .model_provenance = .concrete,
        .effort_selected = true,
    });
    defer candidate.deinit();
    @memset(requested_model, 'x');
    @memset(requested_effort, 'x');
    std.testing.allocator.free(requested_model);
    std.testing.allocator.free(requested_effort);

    try std.testing.expectEqual(CommitResult.written, rig.live.commit(&candidate));
    try std.testing.expect(writer.valid);
    try std.testing.expectEqual(ModelProvenance.concrete, rig.live.current().model_provenance);
}

test "commit publishes first and maps persistence outcomes without rollback" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();

    var writer: TestStateWriter = .{
        .outcome = .written,
        .expected_model = "old-model",
        .expected_effort = config.Store.default_sentinel,
        .expected_live_effort = null,
        .live = &rig.live,
    };
    rig.live.state_writer = writer.writer();
    var explicit = try rig.live.prepare(.{
        .model = "old-model",
        .model_label = "old-model",
        .effort = null,
        .model_provenance = .explicit,
        .effort_selected = true,
    });
    defer explicit.deinit();
    try std.testing.expectEqual(CommitResult.written, rig.live.commit(&explicit));
    try std.testing.expect(writer.valid);

    writer.outcome = .unchanged;
    writer.expected_model = null;
    writer.expected_effort = "low";
    writer.expected_live_effort = "low";
    writer.valid = false;
    var inherited = try rig.live.prepare(.{
        .model = "old-model",
        .model_label = "old-model",
        .effort = "low",
        .model_provenance = .inherited,
        .effort_selected = true,
    });
    defer inherited.deinit();
    try std.testing.expectEqual(CommitResult.unchanged, rig.live.commit(&inherited));
    try std.testing.expect(writer.valid);
    try std.testing.expectEqual(ModelProvenance.explicit, rig.live.current().model_provenance);

    writer.outcome = .failed;
    writer.expected_effort = "high";
    writer.expected_live_effort = "high";
    writer.valid = false;
    var failed = try rig.live.prepare(.{
        .model_label = "old-model",
        .effort = "high",
        .effort_selected = true,
    });
    defer failed.deinit();
    try std.testing.expectEqual(CommitResult.run_only, rig.live.commit(&failed));
    try std.testing.expect(writer.valid);
    try std.testing.expectEqualStrings("high", rig.live.current().effort.?);
    try std.testing.expectEqual(@as(usize, 3), writer.calls);
}

const CountingStateWriter = struct {
    calls: usize = 0,

    fn write(
        context: *anyopaque,
        _: config.StateWriter.Selection,
    ) error{OutOfMemory}!config.StateWriter.Outcome {
        const self: *CountingStateWriter = @ptrCast(@alignCast(context));
        self.calls += 1;
        return .written;
    }

    fn writer(self: *CountingStateWriter) config.StateWriter.Writer {
        return .{ .context = self, .write_fn = write };
    }
};

fn restoreMeta(preset: ?[]u8) persistence.SessionFile.Meta {
    return .{ .selection = .{ .preset = preset } };
}

fn restoreSelection() persistence.SessionFile.Selection {
    return restoreSelectionWithPreset(null);
}

fn restoreSelectionWithPreset(preset: ?[]const u8) persistence.SessionFile.Selection {
    return .{
        .provider = "selection-test",
        .model = "recorded-model",
        .model_label = "Recorded model",
        .effort = "high",
        .preset = preset,
    };
}

test "detached restore classifies full and every core-only preset outcome" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();
    const plan: config.Preset.Plan = .{
        .name = @constCast("review"),
        .provider = @constCast("selection-test"),
        .model = .{ .value = @constCast("preset-model") },
        .effort = .{ .value = @constCast("high") },
        .system_prompt = .{},
        .system_prompt_append = .{},
        .tint = .{},
        .description = .{},
    };
    const invalid: config.Preset.Invalid = .{
        .name = @constCast("broken"),
        .field = null,
        .reason = .missing_provider,
    };

    var full_meta = restoreMeta(@constCast("review"));
    rig.config_source.lookup_override = .{ .plan = &plan };
    var full = try rig.live.prepareDetached(.{ .restore = .{
        .meta = &full_meta,
        .selection = restoreSelectionWithPreset("review"),
    } }, .session_restore);
    defer full.deinit();
    try std.testing.expectEqual(config.Selection.RestoreOutcome.restored, full.restore_outcome.?);
    try std.testing.expectEqualStrings("preset-model", full.session_selection.model.?);
    try std.testing.expectEqualStrings("review", full.session_selection.preset.?);

    const cases = [_]struct {
        preset: ?[]u8,
        lookup: ?config.Preset.BorrowedLookup,
        outcome: config.Selection.RestoreOutcome,
    }{
        .{ .preset = null, .lookup = null, .outcome = .no_preset },
        .{ .preset = @constCast("missing"), .lookup = .missing, .outcome = .missing_preset },
        .{ .preset = @constCast("broken"), .lookup = .{ .invalid = &invalid }, .outcome = .invalid_preset },
        .{ .preset = @constCast("other"), .lookup = .{ .plan = &plan }, .outcome = .mismatched_preset },
    };
    for (cases) |case| {
        var meta = restoreMeta(@constCast("stale-header-preset"));
        rig.config_source.lookup_override = case.lookup;
        var candidate = try rig.live.prepareDetached(.{ .restore = .{
            .meta = &meta,
            .selection = restoreSelectionWithPreset(case.preset),
        } }, .session_restore);
        defer candidate.deinit();
        try std.testing.expectEqual(case.outcome, candidate.restore_outcome.?);
        try std.testing.expectEqualStrings("selection-test", candidate.session_selection.provider_id.?);
        try std.testing.expectEqualStrings("recorded-model", candidate.session_selection.model.?);
        try std.testing.expectEqualStrings("high", candidate.session_selection.effort.?);
        try std.testing.expect(candidate.session_selection.preset == null);
    }
}

test "restore preparation maps provider runtime model prompt and tool failures without mutation" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();
    var meta = restoreMeta(null);
    const request: Request = .{ .restore = .{ .meta = &meta, .selection = restoreSelection() } };
    const cases = [_]struct { err: anyerror, failure: RestoreFailure }{
        .{ .err = error.UnknownProvider, .failure = .unknown_provider },
        .{ .err = error.AdapterUnavailable, .failure = .runtime_unavailable },
        .{ .err = error.MissingModel, .failure = .model_unavailable },
        .{ .err = error.PromptPreparationFailed, .failure = .preparation_failed },
    };
    for (cases) |case| {
        rig.builder.failure = case.err;
        const result = rig.live.prepareDetached(request, .session_restore);
        if (result) |candidate_value| {
            var candidate = candidate_value;
            candidate.deinit();
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expectEqual(case.failure, restoreFailure(err).?);
        }
        try std.testing.expectEqual(@as(u64, 0), rig.live.generation);
        try std.testing.expectEqualStrings("old-model", rig.live.snapshot().model);
    }
    rig.builder.failure = null;
    rig.tools.fail_validation = true;
    const result = rig.live.prepareDetached(request, .session_restore);
    if (result) |candidate_value| {
        var candidate = candidate_value;
        candidate.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(RestoreFailure.preparation_failed, restoreFailure(err).?);
    }
    try std.testing.expectEqual(@as(usize, 0), rig.tools.publications);
}

test "detached restore publication skips StateWriter and retires cleanup ownership" {
    var observer: PublicationObserver = .{ .backing = std.testing.allocator };
    var rig = try TestRig.init(observer.allocator());
    defer rig.deinit();
    rig.stabilize();
    var writer: CountingStateWriter = .{};
    rig.live.state_writer = writer.writer();
    var meta = restoreMeta(null);
    var candidate = try rig.live.prepareDetached(.{ .restore = .{
        .meta = &meta,
        .selection = restoreSelection(),
    } }, .session_restore);
    defer if (candidate.active) candidate.deinit();
    const frees_before = observer.frees;
    try validateDetached(&rig.live, &candidate);
    rig.live.committing = true;
    var retired = publishDetached(&rig.live, &candidate);
    rig.live.committing = false;
    try std.testing.expectEqual(frees_before, observer.frees);
    try std.testing.expectEqual(@as(usize, 0), writer.calls);
    try std.testing.expectEqual(@as(usize, 1), rig.tools.publications);
    try std.testing.expectEqualStrings("recorded-model", rig.live.snapshot().model);
    try std.testing.expectEqualStrings("recorded-model", rig.views.model.?);
    try std.testing.expectEqualStrings(rig.live.snapshot().system_prompt, rig.views.prompt.?);
    retired.deinit();
    try std.testing.expect(observer.frees > frees_before);
    try std.testing.expectEqualStrings("recorded-model", rig.views.model.?);
}

test "detached run and preset overlays retire every publication owner" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();

    var run = try rig.live.prepareDetached(.{ .run = .{
        .model = "run-model",
        .model_label = "Run model",
        .effort = "high",
    } }, .user_persistent);
    rig.live.committing = true;
    var retired_run = publishDetached(&rig.live, &run);
    rig.live.committing = false;
    retired_run.deinit();
    try std.testing.expectEqualStrings("run-model", rig.live.snapshot().model);

    const plan: config.Preset.Plan = .{
        .name = @constCast("review"),
        .provider = @constCast("selection-test"),
        .model = .{ .value = @constCast("preset-model") },
        .effort = .{ .value = @constCast("low") },
        .system_prompt = .{},
        .system_prompt_append = .{},
        .tint = .{},
        .description = .{},
    };
    rig.config_source.plans = &.{plan};
    var preset = try rig.live.prepareDetached(.{ .preset = "review" }, .user_persistent);
    rig.live.committing = true;
    var retired_preset = publishDetached(&rig.live, &preset);
    rig.live.committing = false;
    retired_preset.deinit();
    try std.testing.expectEqualStrings("preset-model", rig.live.snapshot().model);
    try std.testing.expectEqual(@as(usize, 2), rig.tools.publications);
}

test "stale detached generation rejects before publication" {
    var rig = try TestRig.init(std.testing.allocator);
    defer rig.deinit();
    rig.stabilize();
    var meta = restoreMeta(null);
    var candidate = try rig.live.prepareDetached(.{ .restore = .{
        .meta = &meta,
        .selection = restoreSelection(),
    } }, .session_restore);
    defer candidate.deinit();
    rig.live.generation +%= 1;
    try std.testing.expectError(error.StaleCandidate, validateDetached(&rig.live, &candidate));
    try std.testing.expectEqualStrings("old-model", rig.live.snapshot().model);
    try std.testing.expectEqual(@as(usize, 0), rig.tools.publications);
}

fn exerciseDetachedRestoreAllocationFailures(allocator: std.mem.Allocator) !void {
    var rig = try TestRig.init(allocator);
    defer rig.deinit();
    rig.stabilize();
    var meta = restoreMeta(null);
    var candidate = rig.live.prepareDetached(.{ .restore = .{
        .meta = &meta,
        .selection = restoreSelection(),
    } }, .session_restore) catch |err| {
        try std.testing.expectEqualStrings("old-model", rig.live.snapshot().model);
        try std.testing.expectEqual(@as(u64, 0), rig.live.generation);
        try std.testing.expectEqual(@as(usize, 0), rig.tools.publications);
        return err;
    };
    candidate.deinit();
    try std.testing.expectEqualStrings("old-model", rig.live.snapshot().model);
    try std.testing.expectEqual(@as(u64, 0), rig.live.generation);
}

test "detached cancellation and OOM leave live selection unchanged" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDetachedRestoreAllocationFailures,
        .{},
    );
}
