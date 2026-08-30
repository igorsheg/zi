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

const PreparedSession = union(enum) {
    session: agent.Session.PreparedSelection,
    durability: SessionDurability.PreparedSelection,

    fn deinit(self: *PreparedSession) void {
        switch (self.*) {
            .session => |*prepared| prepared.deinit(),
            .durability => |*prepared| prepared.deinit(),
        }
        self.* = undefined;
    }
};

pub const Candidate = struct {
    allocator: std.mem.Allocator,
    config_run: config.Selection.PreparedRun,
    built: Built,
    session: PreparedSession,
    tool_selection: tool.Bash.RunSelection,
    reported_metadata: ?ai.ModelMeta.Metadata,
    model_provenance: ModelProvenance,
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
};

/// Heap-stable live interactive selection. The owner is the only writer of
/// runtime and prompt state. Snapshots are borrowed only between commands.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    config_source: ConfigSource,
    builder: Builder,
    tools: ToolSelection,
    session: *agent.Session.Session,
    durability: ?*SessionDurability.Owner,
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
        const source = self.model_hints_source orelse return;
        const catalog_id = self.runtime.metadata.catalog_id orelse return;
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
        const selection: agent.Session.Selection = .{
            .provider_id = built.runtime.metadata.provider_id,
            .model = built.runtime.model,
            .model_label = requested.model_label orelse self.session.currentSelection().model_label orelse
                built.runtime.model,
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
        var prepared_session: PreparedSession = if (self.durability) |durability|
            .{ .durability = try durability.prepareSelection(self.session, log_selection) }
        else
            .{ .session = try self.session.prepareSelection(selection) };
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
            .model_provenance = if (requested.model_provenance == .inherited)
                self.model_provenance
            else
                requested.model_provenance,
        };
    }

    /// Publishes a fully prepared candidate without allocation or callbacks
    /// that can fail. Persistence intentionally starts in Slice 5.
    pub fn commit(self: *Owner, candidate: *Candidate) void {
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

        switch (candidate.session) {
            .session => |*prepared| self.session.publishSelection(prepared),
            .durability => |*prepared| self.durability.?.publishSelection(self.session, prepared),
        }
        self.tools.publish(candidate.tool_selection);
        self.reported_metadata = candidate.reported_metadata;
        self.model_provenance = candidate.model_provenance;
        self.generation +%= 1;
        if (self.views) |views| views.publish(self.derived());
        candidate.active = false;

        if (old_prompt) |*prompt| prompt.deinit(self.allocator);
        old_runtime.deinit();
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

        var rig: TestRig = undefined;
        rig.allocator = allocator;
        rig.selection = selection;
        rig.session = session;
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
            .durability = null,
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
        self.live.setViews(Views.from(&self.views));
    }

    fn deinit(self: *TestRig) void {
        const environment = self.builder.environment;
        const definition = self.builder.definition;
        const transport = self.builder.transport;
        const metadata = self.builder.metadata;
        self.live.deinit();
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
    var log = try persistence.SessionFile.Log.prepare(std.testing.allocator, std.testing.io, .{
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
    });
    defer log.deinit();
    const durability = try SessionDurability.Owner.create(std.testing.allocator, &log, .{});
    defer durability.deinit();
    rig.live.durability = durability;
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
    rig.live.commit(&candidate);

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
    try std.testing.expectEqualStrings("high", log.currentSelection().effort.?);
    try std.testing.expect(log.currentSelection().preset == null);
    try std.testing.expect(!log.materialized());
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
    rig.live.commit(&selected);

    var effort_only = try rig.live.prepare(.{
        .model_label = "old-model",
        .effort = "low",
    });
    defer effort_only.deinit();
    try std.testing.expectEqual(@as(u64, 999), effort_only.built.runtime.metadata.model.context_window);
    try std.testing.expectEqual(ai.ModelMeta.Support.no, effort_only.built.runtime.metadata.model.tools);
    rig.live.commit(&effort_only);
    try std.testing.expectEqual(@as(u64, 999), rig.live.current().model_metadata.context_window);

    var reset = try rig.live.prepare(.{
        .model = "old-model",
        .model_label = "old-model",
        .effort = "low",
        .reported_metadata = .{ .replace = null },
    });
    defer reset.deinit();
    try std.testing.expectEqual(@as(u64, 0), reset.built.runtime.metadata.model.context_window);
    rig.live.commit(&reset);
    try std.testing.expectEqual(@as(u64, 0), rig.live.current().model_metadata.context_window);
}
