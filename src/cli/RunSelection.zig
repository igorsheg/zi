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

    pub fn prepare(self: ConfigSource, change: config.Selection.RunChange) !config.Selection.PreparedRun {
        return self.prepare_fn(self.context, change);
    }

    pub fn publish(self: ConfigSource, prepared: *config.Selection.PreparedRun) void {
        self.publish_fn(self.context, prepared);
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
        };
        return .{ .context = implementation, .prepare_fn = Adapter.prepare, .publish_fn = Adapter.publish };
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
};

pub const Views = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, Derived) void,

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
        };
    }
};

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

    pub fn build(
        self: *TestBuilder,
        store: config.Store,
        reported_metadata: ?ai.ModelMeta.Metadata,
    ) !Built {
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

    pub fn validateRunSelection(_: *TestTools, selection: tool.Bash.RunSelection) !void {
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

const TestViews = struct {
    publications: usize = 0,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    image_input: ai.Provider.ImageInput = .unknown,
    context_limit: ?u64 = null,

    pub fn publishSelectionViews(self: *TestViews, derived: Derived) void {
        self.publications += 1;
        self.provider = derived.runtime.metadata.provider_id;
        self.model = derived.runtime.model;
        self.prompt = derived.system_prompt;
        self.effort = derived.runtime.effort;
        self.image_input = derived.image_input;
        self.context_limit = derived.context_limit;
    }
};

const TestRig = struct {
    allocator: std.mem.Allocator,
    selection: config.Selection,
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
            .config_source = ConfigSource.from(&rig.selection),
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
        self.live.config_source = ConfigSource.from(&self.selection);
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
