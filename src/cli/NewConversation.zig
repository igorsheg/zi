const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const config = @import("../config/root.zig");
const persistence = @import("../persistence/root.zig");
const tool = @import("../tool/root.zig");
const transcript = @import("../transcript/root.zig");
const ProviderRuntime = @import("../ProviderRuntime.zig");
const SessionDurability = @import("../SessionDurability.zig");
const ToolRuntime = @import("../ToolRuntime.zig");
const ConversationRuntime = @import("ConversationRuntime.zig");
const RunLogSeam = @import("RunLogSeam.zig");
const RunSelection = @import("RunSelection.zig");
const SessionStartup = @import("SessionStartup.zig");

/// Clears deferred compaction and other conversation-local temporary state.
/// Calls are synchronous, infallible, non-retaining, and non-reentrant.
pub const ResetSink = struct {
    context: *anyopaque,
    reset_fn: *const fn (*anyopaque) void,

    pub fn reset(self: ResetSink) void {
        self.reset_fn(self.context);
    }

    pub fn from(implementation: anytype) ResetSink {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("NewConversation.ResetSink.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn reset(context: *anyopaque) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.reset();
            }
        };
        return .{ .context = implementation, .reset_fn = Adapter.reset };
    }
};

pub const PresetUnchanged = union(enum) {
    missing,
    invalid,
    preparation: anyerror,
};

pub const Unchanged = union(enum) {
    reconcile_retryable: SessionDurability.ReconcileFailure,
    reconcile_quarantined: SessionDurability.QuarantineReason,
    preparation: ConversationRuntime.PrepareNewError,
    preset: PresetUnchanged,
};

pub const PartialCause = union(enum) {
    settlement: ToolRuntime.TransitionSettlement,
    binding: ConversationRuntime.BindError,
    publication: ConversationRuntime.BeginPublishError,
    unexpected_preset_publication,
};

pub const Result = struct {
    /// Non-null only when `/new PRESET` attempted persistent preset state.
    preset_persistence: ?RunSelection.CommitResult = null,
    /// The abandoned old branch entered quarantined and could not receive metadata or notes.
    old_branch_incomplete: bool = false,
};

pub const Partial = struct {
    cause: PartialCause,
    preset_committed: bool,
    preset_persistence: ?RunSelection.CommitResult,
    selection_restore: ?SessionDurability.TransitionSelectionFlush = null,
};

pub const Outcome = union(enum) {
    changed: Result,
    unchanged: Unchanged,
    partial: Partial,
};

/// Provider-independent plain `/new` application service. Dependencies are
/// borrowed and must remain stable for each synchronous call.
pub const Service = struct {
    conversation: *ConversationRuntime.Owner,
    selection: *RunSelection.Owner,
    tools: *ToolRuntime.Owner,
    usage: *agent.UsageStats.UsageStats,
    run_log: *RunLogSeam.Owner,
    reset_sink: ResetSink,

    pub fn run(self: *Service, preset: ?[]const u8) Outcome {
        const entry = self.conversation.captureEntryState(self.selection);
        const prior_quarantine = entry.authority == .quarantined;
        const old_branch_recorded = switch (self.conversation.durability().reconcile(self.conversation.session())) {
            .synchronized => true,
            .unrecorded => false,
            .retryable => |failure| return .{ .unchanged = .{ .reconcile_retryable = failure } },
            .quarantined => |reason| if (!prior_quarantine)
                return .{ .unchanged = .{ .reconcile_quarantined = reason } }
            else
                false,
        };

        var prepared_preset: ?RunSelection.PresetCandidate = null;
        defer if (prepared_preset) |*value| if (value.active) value.deinit();
        if (preset) |name| {
            prepared_preset = self.selection.preparePresetForTransition(name, prior_quarantine) catch |err| {
                return .{ .unchanged = .{ .preset = switch (err) {
                    error.PresetMissing => .missing,
                    error.PresetInvalid => .invalid,
                    else => .{ .preparation = err },
                } } };
            };
        }

        var candidate = if (prepared_preset) |*value|
            self.conversation.prepareNewForSelection(
                self.selection,
                entry,
                value.effectiveAgentSelection(),
                value.effectiveLogSelection(),
            ) catch |err| return .{ .unchanged = .{ .preparation = err } }
        else
            self.conversation.prepareNew(self.selection, entry) catch |err|
                return .{ .unchanged = .{ .preparation = err } };
        defer if (candidate.active) candidate.deinit();

        var preset_persistence: ?RunSelection.CommitResult = null;
        var transition_selection: ?RunSelection.TransitionSelection = null;
        defer if (transition_selection) |*value| if (value.active) value.deinit();
        if (prepared_preset) |*value| {
            var retired_preset: RunSelection.RetiredPreset = undefined;
            preset_persistence = self.selection.commitPresetForTransition(value, &retired_preset);
            self.conversation.acknowledgeExpectedPresetPublication(
                self.selection,
                &candidate,
            ) catch {
                if (old_branch_recorded) {
                    transition_selection = self.selection.beginTransitionSelection(&retired_preset);
                }
                retired_preset.deinit();
                return self.postPresetPartial(
                    &transition_selection,
                    .unexpected_preset_publication,
                    preset_persistence,
                );
            };
            if (old_branch_recorded) {
                transition_selection = self.selection.beginTransitionSelection(&retired_preset);
            }
            retired_preset.deinit();
            self.run_log.rebuildTranscript(transcript.Operation.selection, self.conversation.session());
        }

        const settlement = self.tools.finishForTransition(
            self.conversation.session(),
            self.conversation.durability(),
            prior_quarantine,
        );
        if (!settlement.permitsReplacement()) {
            return self.postPresetPartial(
                &transition_selection,
                .{ .settlement = settlement },
                preset_persistence,
            );
        }

        const final_guard = self.conversation.captureEntryState(self.selection).guard;
        self.conversation.bindNew(self.selection, &candidate, final_guard, settlement) catch |err| {
            return self.postPresetPartial(
                &transition_selection,
                .{ .binding = err },
                preset_persistence,
            );
        };
        var lease = self.conversation.beginPublish(&candidate.authorization.?) catch |err| {
            return self.postPresetPartial(
                &transition_selection,
                .{ .publication = err },
                preset_persistence,
            );
        };
        var retired = ConversationRuntime.publishNew(&lease, &candidate);
        retired.deinit();

        self.usage.reset();
        self.reset_sink.reset();
        self.run_log.rebuildTranscript(transcript.Operation.new, self.conversation.session());
        return .{ .changed = .{
            .preset_persistence = preset_persistence,
            .old_branch_incomplete = prior_quarantine,
        } };
    }

    fn postPresetPartial(
        self: *Service,
        transition_selection: *?RunSelection.TransitionSelection,
        cause: PartialCause,
        preset_persistence: ?RunSelection.CommitResult,
    ) Outcome {
        const selection_restore = if (transition_selection.*) |*token|
            self.selection.restoreTransitionSelection(token)
        else
            null;
        return .{ .partial = .{
            .cause = cause,
            .preset_committed = transition_selection.* != null or preset_persistence != null,
            .preset_persistence = preset_persistence,
            .selection_restore = selection_restore,
        } };
    }
};

/// Erased synchronous command-facing interface. Slash/UI wiring is intentionally deferred.
pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, ?[]const u8) Outcome,

    pub fn run(self: Runner, preset: ?[]const u8) Outcome {
        return self.run_fn(self.context, preset);
    }

    pub fn from(implementation: anytype) Runner {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("NewConversation.Runner.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn run(context: *anyopaque, preset: ?[]const u8) Outcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run(preset);
            }
        };
        return .{ .context = implementation, .run_fn = Adapter.run };
    }
};

test {
    _ = Service.run;
    _ = Runner.from;
    _ = ResetSink.from;
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
    fail: bool = false,

    pub fn build(
        self: *TestBuilder,
        store: config.Store,
        _: ?ai.ModelMeta.Metadata,
    ) anyerror!RunSelection.Built {
        if (self.fail) return error.TestUnexpectedResult;
        return .{
            .runtime = try ProviderRuntime.init(.{
                .allocator = self.allocator,
                .store = store,
                .api_key_environment = .from(self.environment),
                .provider_definitions = self.definition[0..1],
            }, ai.Transport.Transport.from(self.transport), 0),
            .prompt = null,
            .image_input = .unsupported,
            .context_limit = null,
            .sort_models = true,
        };
    }
};

const TestConfigSource = struct {
    selection: *config.Selection,
    plans: []const config.Preset.Plan = &.{},
    invalid: []const config.Preset.Invalid = &.{},

    pub fn prepareRun(
        self: *const TestConfigSource,
        change: config.Selection.RunChange,
    ) !config.Selection.PreparedRun {
        return self.selection.prepareRun(change);
    }

    pub fn publishRun(self: *TestConfigSource, prepared: *config.Selection.PreparedRun) void {
        self.selection.publishRun(prepared);
    }

    pub fn lookupPreset(self: *const TestConfigSource, name: []const u8) config.Preset.BorrowedLookup {
        for (self.plans) |*plan| if (std.mem.eql(u8, plan.name, name)) return .{ .plan = plan };
        for (self.invalid) |*invalid| if (std.mem.eql(u8, invalid.name, name)) return .{ .invalid = invalid };
        return .missing;
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
        return self.selection.publishPreset(prepared);
    }
};

const TestToolSelection = struct {
    publications: usize = 0,

    pub fn validateRunSelection(_: *TestToolSelection, selection: tool.Bash.RunSelection) !void {
        try tool.Bash.validateRunSelection(selection);
    }

    pub fn publishRunSelection(self: *TestToolSelection, _: tool.Bash.RunSelection) void {
        self.publications += 1;
    }
};

const MemoryTranscript = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    generation: i96 = 1,
    locked: bool = false,
    truncations: usize = 0,
    conversation: ?*ConversationRuntime.Owner = null,
    quarantine_on_truncate: bool = false,

    pub fn open(
        self: *MemoryTranscript,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
    ) transcript.SecureOpen.Error!transcript.SecureOpen.Opened {
        const opened = allocator.create(MemoryTranscriptOpen) catch return error.OutOfMemory;
        opened.* = .{ .owner = self };
        return .from(opened);
    }

    fn snapshot(self: *MemoryTranscript) transcript.SecureOpen.Snapshot {
        return .{
            .identity = .{ .device = 1, .inode = 7 },
            .token = .{
                .size = self.bytes.items.len,
                .mode = 0o600,
                .mtime_ns = self.generation,
                .ctime_ns = self.generation,
            },
            .nlink = 1,
            .regular = true,
        };
    }

    fn deinit(self: *MemoryTranscript) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }
};

const MemoryTranscriptOpen = struct {
    owner: *MemoryTranscript,

    pub fn close(self: *MemoryTranscriptOpen, allocator: std.mem.Allocator, _: std.Io) void {
        self.owner.locked = false;
        allocator.destroy(self);
    }

    pub fn tryLock(self: *MemoryTranscriptOpen, _: std.Io) transcript.SecureOpen.Error!bool {
        if (self.owner.locked) return false;
        self.owner.locked = true;
        return true;
    }

    pub fn statOpened(
        self: *MemoryTranscriptOpen,
        _: std.Io,
    ) transcript.SecureOpen.Error!transcript.SecureOpen.Snapshot {
        return self.owner.snapshot();
    }

    pub fn statNamed(
        self: *MemoryTranscriptOpen,
        _: std.Io,
    ) transcript.SecureOpen.Error!transcript.SecureOpen.Snapshot {
        return self.owner.snapshot();
    }

    pub fn setPermissions(_: *MemoryTranscriptOpen, _: std.Io) transcript.SecureOpen.Error!void {}

    pub fn setLength(self: *MemoryTranscriptOpen, _: std.Io, length: u64) transcript.SecureOpen.Error!void {
        self.owner.bytes.resize(self.owner.allocator, @intCast(length)) catch return error.OutOfMemory;
        self.owner.generation += 1;
        self.owner.truncations += 1;
        if (self.owner.quarantine_on_truncate) {
            self.owner.quarantine_on_truncate = false;
            const conversation = self.owner.conversation.?;
            conversation.session().addUser("settlement mutation") catch return error.OutOfMemory;
            conversation.durability().seamHook().call(
                conversation.session(),
                .completion,
                false,
            ) catch |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        }
    }

    pub fn writeAll(
        self: *MemoryTranscriptOpen,
        _: std.Io,
        bytes: []const u8,
        offset: u64,
    ) transcript.SecureOpen.Error!void {
        const start: usize = @intCast(offset);
        self.owner.bytes.resize(self.owner.allocator, start + bytes.len) catch return error.OutOfMemory;
        @memcpy(self.owner.bytes.items[start..][0..bytes.len], bytes);
        self.owner.generation += 1;
    }
};

const TestReset = struct {
    usage: *agent.UsageStats.UsageStats,
    calls: usize = 0,
    saw_reset_usage: bool = false,

    pub fn reset(self: *TestReset) void {
        self.calls += 1;
        self.saw_reset_usage = self.usage.input_tokens == 0 and self.usage.attempts.items.len == 0;
    }
};

const TestIdentity = struct {
    conversation: ?*ConversationRuntime.Owner = null,
    quarantine_during_prepare: bool = false,
    fail_uuid: bool = false,

    pub fn nextTimestamp(_: *TestIdentity) persistence.Paths.Timestamp {
        return .{ .epoch_seconds = 1 };
    }

    pub fn nextUuid(self: *TestIdentity) ConversationRuntime.UuidProvider.Error![16]u8 {
        if (self.fail_uuid) return error.Unavailable;
        if (self.quarantine_during_prepare) {
            const conversation = self.conversation.?;
            conversation.session().addUser("late settlement history") catch return error.Unavailable;
            conversation.durability().seamHook().call(
                conversation.session(),
                .completion,
                false,
            ) catch |err| if (err != error.Indeterminate) return error.Unavailable;
        }
        return .{
            0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
            0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x02,
        };
    }
};

const TestRig = struct {
    allocator: std.mem.Allocator,
    environment: *TestEnvironment,
    definition: *config.ProviderDefinitions.Definition,
    transport: *TestTransport,
    config_selection: config.Selection,
    config_source: TestConfigSource,
    builder: TestBuilder,
    tool_selection: TestToolSelection = .{},
    conversation: *ConversationRuntime.Owner,
    selection: RunSelection.Owner,
    tools: ToolRuntime.Owner,
    usage: agent.UsageStats.UsageStats,
    transcript_memory: *MemoryTranscript,
    transcript_owner: *transcript.Owner.Owner,
    run_log: *RunLogSeam.Owner,
    identity: *TestIdentity,
    reset: TestReset = undefined,

    fn init(
        allocator: std.mem.Allocator,
        state_root: ?[]const u8,
        initial_log: ?persistence.SessionFile.Log,
    ) !TestRig {
        const environment = try allocator.create(TestEnvironment);
        errdefer allocator.destroy(environment);
        environment.* = .{};
        const definition = try allocator.create(config.ProviderDefinitions.Definition);
        errdefer allocator.destroy(definition);
        definition.* = .{
            .id = @constCast("new-test"),
            .api = .openai_responses,
            .base_url = @constCast("https://new.test/v1"),
        };
        const transport = try allocator.create(TestTransport);
        errdefer allocator.destroy(transport);
        transport.* = .{};
        const identity = try allocator.create(TestIdentity);
        errdefer allocator.destroy(identity);
        identity.* = .{};

        var config_selection = config.Selection.init(allocator, .{
            .registry = config.Settings.storeRegistry(),
            .environment = config.Store.Environment.from(environment),
        });
        errdefer config_selection.deinit();
        try config_selection.setRun(.{ .provider = "new-test", .model = "model" });
        var runtime = try ProviderRuntime.init(.{
            .allocator = allocator,
            .store = config_selection.store(),
            .api_key_environment = .from(environment),
            .provider_definitions = definition[0..1],
        }, ai.Transport.Transport.from(transport), 0);
        errdefer runtime.deinit();

        var startup_log = initial_log;
        var startup: SessionStartup.Candidate = .{
            .allocator = allocator,
            .session = try agent.Session.Session.init(allocator, .{
                .provider_id = "new-test",
                .model = "model",
                .model_label = "model",
            }),
            .log = startup_log,
            .identity = .{ .origin = .fresh },
            .meta = null,
            .recovery = null,
            .index_recovery = null,
            .warning = null,
        };
        startup_log = null;
        errdefer if (startup.active) startup.deinit();
        const conversation = try ConversationRuntime.Owner.create(allocator, &startup, .{
            .io = std.testing.io,
            .recording_policy = if (initial_log == null) .disabled else .enabled,
            .fresh = .{
                .state_root = state_root,
                .cwd = "/work",
                .writer_version = "test",
                .timestamp_provider = ConversationRuntime.TimestampProvider.from(identity),
                .uuid_provider = ConversationRuntime.UuidProvider.from(identity),
            },
        });
        errdefer conversation.deinit();
        identity.conversation = conversation;

        var tools = try ToolRuntime.init(.{
            .allocator = allocator,
            .io = std.testing.io,
            .environ = std.testing.environ,
            .home = null,
            .path_env = null,
            .enable_tools = false,
            .enable_tasks = false,
        });
        errdefer tools.deinit();
        var usage = try agent.UsageStats.UsageStats.init(allocator, 8);
        errdefer usage.deinit();
        const transcript_memory = try allocator.create(MemoryTranscript);
        transcript_memory.* = .{ .allocator = allocator };
        errdefer {
            transcript_memory.deinit();
            allocator.destroy(transcript_memory);
        }
        const transcript_owner = try transcript.Owner.Owner.create(
            allocator,
            std.testing.io,
            transcript.SecureOpen.Capability.from(transcript_memory),
            "transcript",
            .{},
        );
        errdefer transcript_owner.deinit();
        const run_log = try RunLogSeam.Owner.create(
            allocator,
            transcript_owner,
            conversation.durability(),
            .{},
        );
        errdefer run_log.deinit();

        var rig: TestRig = undefined;
        rig.allocator = allocator;
        rig.environment = environment;
        rig.definition = definition;
        rig.transport = transport;
        rig.config_selection = config_selection;
        rig.config_source = .{ .selection = &rig.config_selection };
        rig.builder = .{
            .allocator = allocator,
            .environment = environment,
            .definition = definition,
            .transport = transport,
        };
        rig.tool_selection = .{};
        rig.conversation = conversation;
        rig.selection = .{
            .allocator = allocator,
            .config_source = RunSelection.ConfigSource.from(&rig.config_source),
            .builder = RunSelection.Builder.from(&rig.builder),
            .tools = RunSelection.ToolSelection.from(&rig.tool_selection),
            .session = conversation.session(),
            .durability = conversation.durability(),
            .runtime = runtime,
            .prompt = null,
            .tool_list = tools.tools(),
            .image_input = .unsupported,
            .context_limit = null,
            .model_metadata_source = null,
            .image_input_source = null,
        };
        rig.tools = tools;
        rig.usage = usage;
        rig.transcript_memory = transcript_memory;
        rig.transcript_memory.conversation = conversation;
        rig.transcript_owner = transcript_owner;
        rig.run_log = run_log;
        rig.identity = identity;
        rig.reset = .{ .usage = &rig.usage };
        return rig;
    }

    fn stabilize(self: *TestRig) void {
        self.config_source.selection = &self.config_selection;
        self.selection.config_source = RunSelection.ConfigSource.from(&self.config_source);
        self.selection.builder = RunSelection.Builder.from(&self.builder);
        self.selection.tools = RunSelection.ToolSelection.from(&self.tool_selection);
        self.selection.session = self.conversation.session();
        self.selection.durability = self.conversation.durability();
        self.selection.tool_list = self.tools.tools();
        self.run_log.bindSelection(&self.selection);
        self.reset.usage = &self.usage;
    }

    fn service(self: *TestRig) Service {
        return .{
            .conversation = self.conversation,
            .selection = &self.selection,
            .tools = &self.tools,
            .usage = &self.usage,
            .run_log = self.run_log,
            .reset_sink = ResetSink.from(&self.reset),
        };
    }

    fn deinit(self: *TestRig) void {
        self.run_log.deinit();
        self.transcript_owner.deinit();
        self.transcript_memory.deinit();
        self.allocator.destroy(self.transcript_memory);
        self.usage.deinit();
        self.tools.deinit();
        self.selection.deinit();
        self.conversation.deinit();
        self.config_selection.deinit();
        self.allocator.destroy(self.identity);
        self.allocator.destroy(self.transport);
        self.allocator.destroy(self.definition);
        self.allocator.destroy(self.environment);
        self.* = undefined;
    }
};

fn testLog(allocator: std.mem.Allocator, root: []const u8) !persistence.SessionFile.Log {
    return persistence.SessionFile.Log.prepare(allocator, std.testing.io, .{
        .state_root = root,
        .cwd = "/work",
        .selection = .{ .provider = "new-test", .model = "model", .model_label = "model" },
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = .{
            0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
            0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x01,
        },
        .writer_version = "test",
    });
}

fn failBeforeWrite(_: std.Io, _: std.Io.File, _: []const u8, _: u64) error{IoFailure}!void {
    return error.IoFailure;
}

fn failSync(_: std.Io, _: std.Io.File) error{IoFailure}!void {
    return error.IoFailure;
}

fn commitFirstThenPartial(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    offset: u64,
) error{IoFailure}!void {
    if (offset == 0) return file.writePositionalAll(io, bytes, offset) catch error.IoFailure;
    const prefix_len = @max(@as(usize, 1), bytes.len / 2);
    file.writePositionalAll(io, bytes[0..prefix_len], offset) catch return error.IoFailure;
    return error.IoFailure;
}

fn seedUsage(usage: *agent.UsageStats.UsageStats) !void {
    try usage.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 9 } },
        .spend = .{},
        .attempts = &.{.{ .input_tokens = 9 }},
        .kind = .ordinary,
        .terminal_context_tokens = 9,
    });
}

fn testPresetPlan() config.Preset.Plan {
    return .{
        .name = @constCast("review"),
        .provider = @constCast("new-test"),
        .model = .{ .value = @constCast("preset-model") },
        .effort = .{},
        .system_prompt = .{ .value = @constCast("preset prompt") },
        .system_prompt_append = .{},
        .tint = .{},
        .description = .{},
    };
}

fn expectOldConversation(rig: *TestRig, generation: u64, item_count: usize) !void {
    try std.testing.expectEqual(generation, rig.conversation.generation());
    try std.testing.expectEqual(item_count, rig.conversation.session().items().len);
    try std.testing.expectEqual(@as(u64, 9), rig.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), rig.reset.calls);
}

test "missing invalid and unbuildable presets are typed no-ops" {
    var rig = try TestRig.init(std.testing.allocator, null, null);
    defer rig.deinit();
    rig.stabilize();
    try rig.conversation.session().addUser("old history");
    const item_count = rig.conversation.session().items().len;
    var service = rig.service();

    const missing = service.run("missing");
    try std.testing.expect(missing == .unchanged);
    try std.testing.expect(missing.unchanged.preset == .missing);

    const invalid_values = [_]config.Preset.Invalid{.{
        .name = @constCast("broken"),
        .field = null,
        .reason = .missing_provider,
    }};
    rig.config_source.invalid = &invalid_values;
    const invalid = service.run("broken");
    try std.testing.expect(invalid == .unchanged);
    try std.testing.expect(invalid.unchanged.preset == .invalid);

    const plans = [_]config.Preset.Plan{testPresetPlan()};
    rig.config_source.plans = &plans;
    rig.builder.fail = true;
    const unbuildable = service.run("review");
    try std.testing.expect(unbuildable == .unchanged);
    try std.testing.expect(unbuildable.unchanged.preset == .preparation);
    try std.testing.expectEqual(error.TestUnexpectedResult, unbuildable.unchanged.preset.preparation);

    try std.testing.expectEqual(item_count, rig.conversation.session().items().len);
    try std.testing.expectEqual(@as(u64, 0), rig.selection.generation);
    try std.testing.expectEqual(@as(usize, 0), rig.tool_selection.publications);
}

test "preset commits once before fresh publication and persists run-only" {
    var rig = try TestRig.init(std.testing.allocator, null, null);
    defer rig.deinit();
    rig.stabilize();
    const plans = [_]config.Preset.Plan{testPresetPlan()};
    rig.config_source.plans = &plans;
    try rig.conversation.session().addUser("old history");
    var service = rig.service();

    const outcome = service.run("review");
    try std.testing.expect(outcome == .changed);
    try std.testing.expectEqual(RunSelection.CommitResult.run_only, outcome.changed.preset_persistence.?);
    try std.testing.expectEqual(@as(u64, 1), rig.selection.generation);
    try std.testing.expectEqual(@as(usize, 1), rig.tool_selection.publications);
    try std.testing.expectEqual(@as(usize, 0), rig.conversation.session().items().len);
    const current = rig.conversation.session().currentSelection();
    try std.testing.expectEqualStrings("new-test", current.provider_id.?);
    try std.testing.expectEqualStrings("preset-model", current.model.?);
    try std.testing.expectEqualStrings("review", current.preset.?);
}

test "post-preset settlement failure retains preset and old history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var log = try testLog(std.testing.allocator, root);
    log.commit_fn = commitFirstThenPartial;
    var rig = try TestRig.init(std.testing.allocator, root, log);
    defer rig.deinit();
    rig.stabilize();
    const plans = [_]config.Preset.Plan{testPresetPlan()};
    rig.config_source.plans = &plans;
    try rig.conversation.session().addUser("old history");
    try rig.conversation.durability().seamHook().call(rig.conversation.session(), .completion, false);
    const old_items = rig.conversation.session().items().len;
    rig.transcript_memory.quarantine_on_truncate = true;
    var service = rig.service();

    const outcome = service.run("review");
    try std.testing.expect(outcome == .partial);
    try std.testing.expect(outcome.partial.preset_committed);
    try std.testing.expect(outcome.partial.cause == .settlement);
    try std.testing.expectEqual(@as(u64, 1), rig.selection.generation);
    try std.testing.expectEqualStrings("review", rig.conversation.session().currentSelection().preset.?);
    try std.testing.expect(rig.conversation.session().items().len > old_items);
    try std.testing.expectEqual(@as(u64, 0), rig.conversation.generation());
}

test "preset transition uses session-only metadata for entry quarantine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var log = try testLog(std.testing.allocator, root);
    log.append_sync_file_fn = failSync;
    var rig = try TestRig.init(std.testing.allocator, root, log);
    defer rig.deinit();
    rig.stabilize();
    try rig.conversation.session().addUser("quarantined old history");
    try std.testing.expectError(
        error.Indeterminate,
        rig.conversation.durability().seamHook().call(rig.conversation.session(), .completion, false),
    );
    const plans = [_]config.Preset.Plan{testPresetPlan()};
    rig.config_source.plans = &plans;
    var service = rig.service();

    const outcome = service.run("review");
    try std.testing.expect(outcome == .changed);
    try std.testing.expect(outcome.changed.old_branch_incomplete);
    try std.testing.expectEqual(@as(u64, 1), rig.selection.generation);
    try std.testing.expectEqualStrings("review", rig.conversation.session().currentSelection().preset.?);
    switch (rig.conversation.durability().state(rig.conversation.session())) {
        .synchronized => |high_water| try std.testing.expectEqual(@as(usize, 0), high_water),
        else => return error.TestUnexpectedResult,
    }
}

test "unrecorded new succeeds and preserves stable owner addresses" {
    var rig = try TestRig.init(std.testing.allocator, null, null);
    defer rig.deinit();
    rig.stabilize();
    try rig.conversation.session().addUser("old history");
    try seedUsage(&rig.usage);
    const session_address = rig.conversation.session();
    const durability_address = rig.conversation.durability();
    const selection_address = &rig.selection;
    var service = rig.service();

    try std.testing.expect(service.run(null) == .changed);
    try std.testing.expectEqual(session_address, rig.conversation.session());
    try std.testing.expectEqual(durability_address, rig.conversation.durability());
    try std.testing.expectEqual(selection_address, &rig.selection);
    try std.testing.expectEqual(@as(usize, 0), rig.conversation.session().items().len);
    try std.testing.expectEqual(@as(u64, 1), rig.conversation.generation());
}

test "reconcile retry blocks new before settlement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var log = try testLog(std.testing.allocator, root);
    log.commit_fn = failBeforeWrite;
    var rig = try TestRig.init(std.testing.allocator, root, log);
    defer rig.deinit();
    rig.stabilize();
    try rig.conversation.session().addUser("pending");
    try seedUsage(&rig.usage);
    const item_count = rig.conversation.session().items().len;
    var service = rig.service();

    const outcome = service.run(null);
    try std.testing.expect(outcome == .unchanged);
    try std.testing.expect(outcome.unchanged == .reconcile_retryable);
    try expectOldConversation(&rig, 0, item_count);
}

test "preexisting quarantine permits replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var log = try testLog(std.testing.allocator, root);
    log.append_sync_file_fn = failSync;
    var rig = try TestRig.init(std.testing.allocator, root, log);
    defer rig.deinit();
    rig.stabilize();
    try rig.conversation.session().addUser("quarantined history");
    try std.testing.expectError(
        error.Indeterminate,
        rig.conversation.durability().seamHook().call(rig.conversation.session(), .completion, false),
    );
    try seedUsage(&rig.usage);
    var service = rig.service();

    try std.testing.expect(service.run(null) == .changed);
    try std.testing.expectEqual(@as(u64, 1), rig.conversation.generation());
    switch (rig.conversation.durability().state(rig.conversation.session())) {
        .synchronized => |high_water| try std.testing.expectEqual(@as(usize, 0), high_water),
        else => return error.TestUnexpectedResult,
    }
}

test "quarantine created by reconcile blocks replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var log = try testLog(std.testing.allocator, root);
    log.append_sync_file_fn = failSync;
    var rig = try TestRig.init(std.testing.allocator, root, log);
    defer rig.deinit();
    rig.stabilize();
    try rig.conversation.session().addUser("new quarantine");
    try seedUsage(&rig.usage);
    const item_count = rig.conversation.session().items().len;
    var service = rig.service();

    const outcome = service.run(null);
    try std.testing.expect(outcome == .unchanged);
    try std.testing.expect(outcome.unchanged == .reconcile_quarantined);
    try expectOldConversation(&rig, 0, item_count);
}

test "preparation failure is typed and keeps old state" {
    var rig = try TestRig.init(std.testing.allocator, null, null);
    defer rig.deinit();
    rig.stabilize();
    rig.identity.fail_uuid = true;
    try rig.conversation.session().addUser("old history");
    try seedUsage(&rig.usage);
    const item_count = rig.conversation.session().items().len;
    var service = rig.service();

    const outcome = service.run(null);
    try std.testing.expect(outcome == .unchanged);
    try std.testing.expect(outcome.unchanged == .preparation);
    try std.testing.expectEqual(error.Unavailable, outcome.unchanged.preparation);
    try expectOldConversation(&rig, 0, item_count);
}

test "settlement failure keeps old history and usage live" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var log = try testLog(std.testing.allocator, root);
    log.append_sync_file_fn = failSync;
    var rig = try TestRig.init(std.testing.allocator, root, log);
    defer rig.deinit();
    rig.stabilize();
    rig.identity.quarantine_during_prepare = true;
    try seedUsage(&rig.usage);
    const items_before = rig.conversation.session().items().len;
    var service = rig.service();

    const outcome = service.run(null);
    try std.testing.expect(outcome == .partial);
    try std.testing.expect(outcome.partial.cause == .settlement);
    try std.testing.expect(!outcome.partial.cause.settlement.permitsReplacement());
    try std.testing.expect(rig.conversation.session().items().len > items_before);
    try expectOldConversation(&rig, 0, rig.conversation.session().items().len);
}

test "success resets usage then reset state and rebuilds the new transcript" {
    var rig = try TestRig.init(std.testing.allocator, null, null);
    defer rig.deinit();
    rig.stabilize();
    try rig.conversation.session().addUser("old history");
    try seedUsage(&rig.usage);
    const truncations_before = rig.transcript_memory.truncations;
    var service = rig.service();
    const runner = Runner.from(&service);

    try std.testing.expect(runner.run(null) == .changed);
    try std.testing.expectEqual(@as(usize, 1), rig.reset.calls);
    try std.testing.expect(rig.reset.saw_reset_usage);
    try std.testing.expectEqual(@as(u64, 0), rig.usage.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), rig.usage.attempts.items.len);
    try std.testing.expectEqual(truncations_before + 1, rig.transcript_memory.truncations);
    try std.testing.expect(rig.transcript_owner.status() == .clean);
}
