const std = @import("std");
const agent = @import("../agent/root.zig");
const persistence = @import("../persistence/root.zig");
const tool = @import("../tool/root.zig");
const transcript = @import("../transcript/root.zig");
const SessionDurability = @import("../SessionDurability.zig");
const ToolRuntime = @import("../ToolRuntime.zig");
const ConversationRuntime = @import("ConversationRuntime.zig");
const NewConversation = @import("NewConversation.zig");
const RunLogSeam = @import("RunLogSeam.zig");
const RunSelection = @import("RunSelection.zig");
const SessionPicker = @import("SessionPicker.zig");
const SessionStartup = @import("SessionStartup.zig");

pub const ReplaySink = struct {
    context: *anyopaque,
    replay_fn: *const fn (*anyopaque, *const agent.Session.Session, []const tool.Tool.Tool, []const u8) anyerror!void,

    pub fn replay(
        self: ReplaySink,
        session: *const agent.Session.Session,
        tools: []const tool.Tool.Tool,
        heading: []const u8,
    ) !void {
        return self.replay_fn(self.context, session, tools, heading);
    }

    pub fn from(implementation: anytype) ReplaySink {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("ResumeConversation.ReplaySink.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn replayFn(
                context: *anyopaque,
                session: *const agent.Session.Session,
                tools: []const tool.Tool.Tool,
                heading: []const u8,
            ) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.replay(session, tools, heading);
            }
        };
        return .{ .context = implementation, .replay_fn = Adapter.replayFn };
    }
};

pub const Unchanged = union(enum) {
    no_candidates,
    canceled,
    could_not_read,
    reconcile_retryable: SessionDurability.ReconcileFailure,
    reconcile_quarantined: SessionDurability.QuarantineReason,
    preparation: anyerror,
};

pub const Partial = union(enum) {
    settlement: ToolRuntime.TransitionSettlement,
    binding: ConversationRuntime.BindError,
    publication: ConversationRuntime.BeginPublishError,
};

pub const Changed = struct {
    result: ConversationRuntime.ResumeResult,
    old_branch_incomplete: bool,
};

pub const Outcome = union(enum) {
    changed: Changed,
    unchanged: Unchanged,
    partial: Partial,
};

const LoadedAuthority = struct {
    id: ?[]const u8,
    selection: persistence.SessionFile.Selection,
};

fn loadedAuthority(loaded: *const persistence.SessionFile.Loaded) LoadedAuthority {
    return .{
        .id = loaded.meta.id,
        .selection = loaded.meta.selection.borrow(),
    };
}

fn hasRecordedProvider(provider: ?[]const u8) bool {
    const value = provider orelse return false;
    return value.len != 0 and !std.mem.eql(u8, value, "none");
}

/// Provider-independent synchronous `/resume` transaction.
pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    conversation: *ConversationRuntime.Owner,
    selection: *RunSelection.Owner,
    tools: *ToolRuntime.Owner,
    usage: *agent.UsageStats.UsageStats,
    run_log: *RunLogSeam.Owner,
    reset_sink: NewConversation.ResetSink,
    picker: ?SessionPicker.Runner = null,
    replay_sink: ?ReplaySink = null,
    cutoff_epoch_seconds: i64,
    index_limits: persistence.SessionIndex.Limits = .{},
    toucher: SessionStartup.Toucher = .standard,

    pub fn run(self: *Service) Outcome {
        const entry = self.conversation.captureEntryState(self.selection);
        const prior_quarantine = entry.authority == .quarantined;
        switch (self.conversation.durability().reconcile(self.conversation.session())) {
            .synchronized, .unrecorded => {},
            .retryable => |failure| return .{ .unchanged = .{ .reconcile_retryable = failure } },
            .quarantined => |reason| if (!prior_quarantine)
                return .{ .unchanged = .{ .reconcile_quarantined = reason } },
        }

        const resolution = SessionStartup.resolve(.{
            .allocator = self.allocator,
            .io = self.io,
            .state_root = self.conversation.stateRoot(),
            .cwd = self.conversation.cwd(),
            .resume_state = .select,
            .cutoff_epoch_seconds = self.cutoff_epoch_seconds,
            .limits = self.index_limits,
        }) catch |err| return .{ .unchanged = .{ .preparation = err } };
        var candidates = switch (resolution) {
            .candidates => |value| value,
            else => return .{ .unchanged = .no_candidates },
        };
        var candidates_owned = true;
        defer if (candidates_owned) candidates.deinit();
        const picker = self.picker orelse return .{ .unchanged = .canceled };
        const choice = picker.run(.{
            .entries = candidates.entries(),
            .exclude_path = self.conversation.activePath(),
        }) catch |err| return .{ .unchanged = .{ .preparation = err } };
        const selected_index = switch (choice) {
            .empty => return .{ .unchanged = .no_candidates },
            .canceled => return .{ .unchanged = .canceled },
            .selected => |value| value,
        };
        if (selected_index >= candidates.entries().len) return .{ .unchanged = .canceled };
        if (self.conversation.activePath()) |active_path| {
            if (std.mem.eql(u8, active_path, candidates.entries()[selected_index].path)) {
                return .{ .unchanged = .canceled };
            }
        }
        var resolved = candidates.resolve(self.io, self.toucher, selected_index) catch |err|
            return .{ .unchanged = .{ .preparation = err } };
        candidates_owned = false;
        var resolved_owned = true;
        defer if (resolved_owned) resolved.deinit();

        var loaded_log: ?persistence.SessionFile.Log = null;
        var loaded: persistence.SessionFile.Loaded = undefined;
        var recording: ConversationRuntime.ResumeRecording = undefined;
        if (self.conversation.policy() == .disabled) {
            loaded = persistence.SessionFile.loadStableForResume(
                self.allocator,
                self.io,
                resolved.path(),
                self.conversation.fileLimits(),
            ) catch return .{ .unchanged = .could_not_read };
            recording = .unrecorded_explicit;
        } else if (persistence.SessionFile.loadLockedForResume(
            self.allocator,
            self.io,
            resolved.path(),
            self.conversation.fileLimits(),
        )) |locked_value| {
            var locked = locked_value;
            loaded = locked.loaded;
            loaded_log = locked.log;
            locked = undefined;
            recording = .appending;
        } else |locked_error| {
            if (locked_error == error.OutOfMemory) return .{ .unchanged = .{ .preparation = locked_error } };
            loaded = persistence.SessionFile.loadStableForResume(
                self.allocator,
                self.io,
                resolved.path(),
                self.conversation.fileLimits(),
            ) catch return .{ .unchanged = .could_not_read };
            recording = .unrecorded_unavailable;
        }
        var loaded_owned = true;
        defer if (loaded_owned) loaded.deinit();
        defer if (loaded_log) |*value| value.deinit();
        if (loaded.session.items().len == 0) return .{ .unchanged = .could_not_read };

        const loaded_authority = loadedAuthority(&loaded);
        var restore_failure: ?RunSelection.RestoreFailure = null;
        var detached: ?RunSelection.DetachedCandidate = if (hasRecordedProvider(loaded_authority.selection.provider))
            self.selection.prepareDetached(.{ .restore = .{
                .meta = &loaded.meta,
                .selection = loaded_authority.selection,
            } }, .session_restore) catch |err| failure: {
                if (err == error.OutOfMemory) return .{ .unchanged = .{ .preparation = err } };
                restore_failure = RunSelection.restoreFailure(err) orelse .preparation_failed;
                break :failure null;
            }
        else no_provider: {
            restore_failure = .no_recorded_provider;
            break :no_provider null;
        };
        defer if (detached) |*value| value.deinit();

        const resume_selection: ConversationRuntime.ResumeSelection = if (detached) |*value|
            if (value.restore_outcome.? == .restored)
                .restored
            else
                .{ .core_restored = value.restore_outcome.? }
        else
            .{ .kept_current = restore_failure.? };
        const effective_agent = if (detached) |*value|
            value.session_selection
        else
            self.conversation.session().currentSelection();
        const effective_log: persistence.SessionFile.Selection = if (detached) |*value| value.log_selection else .{
            .provider = effective_agent.provider_id,
            .model = effective_agent.model,
            .model_label = effective_agent.model_label,
            .effort = effective_agent.effort,
            .preset = effective_agent.preset,
        };
        loaded.session.reconfigureSelection(effective_agent) catch |err|
            return .{ .unchanged = .{ .preparation = err } };

        if (loaded_log) |*log_value| {
            const provider = effective_agent.provider_id orelse "";
            if (!self.conversation.policy().permits(provider)) {
                log_value.deinit();
                loaded_log = null;
                recording = .unrecorded_provider_policy;
            } else log_value.setSelection(effective_log) catch |err| {
                if (err == error.OutOfMemory) return .{ .unchanged = .{ .preparation = err } };
                log_value.deinit();
                loaded_log = null;
                recording = .unrecorded_unavailable;
            };
        }

        const active_path = self.allocator.dupe(u8, resolved.path()) catch |err|
            return .{ .unchanged = .{ .preparation = err } };
        var identity: SessionStartup.Identity = .{
            .active_path = active_path,
            .id = if (loaded_authority.id) |value| self.allocator.dupe(u8, value) catch |err| {
                self.allocator.free(active_path);
                return .{ .unchanged = .{ .preparation = err } };
            } else null,
            .origin = .resumed,
        };
        var identity_owned = true;
        defer if (identity_owned) identity.deinit(self.allocator);

        const parts = loaded.takeParts();
        loaded_owned = false;
        var replacement = parts.session;
        var replacement_owned = true;
        defer if (replacement_owned) replacement.deinit();
        var meta: ?persistence.SessionFile.Meta = parts.meta;
        defer if (meta) |*value| value.deinit(self.allocator);
        var candidate = self.conversation.prepareResume(
            self.selection,
            entry,
            &replacement,
            &loaded_log,
            &identity,
            &meta,
            parts.recovery,
            resolved.recovery(),
            &detached,
            .{ .selection = resume_selection, .recording = recording },
        ) catch |err| return .{ .unchanged = .{ .preparation = err } };
        replacement_owned = false;
        identity_owned = false;
        defer if (candidate.active) candidate.deinit();
        resolved.deinit();
        resolved_owned = false;

        const settlement = self.tools.finishForTransition(
            self.conversation.session(),
            self.conversation.durability(),
            prior_quarantine,
        );
        if (!settlement.permitsReplacement()) return .{ .partial = .{ .settlement = settlement } };

        const final_guard = self.conversation.captureEntryState(self.selection).guard;
        self.conversation.bindResume(self.selection, &candidate, final_guard, settlement) catch |err|
            return .{ .partial = .{ .binding = err } };
        var lease = self.conversation.beginPublish(&candidate.authorization.?) catch |err|
            return .{ .partial = .{ .publication = err } };
        var retired = ConversationRuntime.publishResume(&lease, &candidate);
        var result = retired.result;
        retired.deinit();

        if (result.recording == .appending and
            !self.conversation.durability().tightenResumedAuthority())
        {
            result.recording = .unrecorded_unavailable;
        }
        self.usage.invalidateContext();
        self.reset_sink.reset();
        self.run_log.rebuildTranscript(transcript.Operation.resume_conversation, self.conversation.session());
        return .{ .changed = .{ .result = result, .old_branch_incomplete = prior_quarantine } };
    }

    /// Advisory presentation performed by the command only after diagnostics.
    pub fn replay(self: *Service) void {
        if (self.replay_sink) |sink| sink.replay(
            self.conversation.session(),
            self.selection.tool_list,
            "resumed",
        ) catch |err| ignoreReplayFailure(err);
    }
};

fn ignoreReplayFailure(err: anyerror) void {
    _ = @errorName(err);
}

pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) Outcome,
    replay_fn: *const fn (*anyopaque) void,

    pub fn run(self: Runner) Outcome {
        return self.run_fn(self.context);
    }

    pub fn replay(self: Runner) void {
        self.replay_fn(self.context);
    }

    pub fn from(implementation: anytype) Runner {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("ResumeConversation.Runner.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn run(context: *anyopaque) Outcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run();
            }

            fn replay(context: *anyopaque) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.replay();
            }
        };
        return .{ .context = implementation, .run_fn = Adapter.run, .replay_fn = Adapter.replay };
    }
};

const TestRunner = struct {
    runs: usize = 0,
    replays: usize = 0,

    fn run(self: *TestRunner) Outcome {
        self.runs += 1;
        return .{ .unchanged = .canceled };
    }

    fn replay(self: *TestRunner) void {
        self.replays += 1;
    }
};

test "runner keeps transaction and advisory replay as separate operations" {
    var implementation: TestRunner = .{};
    const runner = Runner.from(&implementation);
    try std.testing.expectEqual(Unchanged.canceled, runner.run().unchanged);
    try std.testing.expectEqual(@as(usize, 1), implementation.runs);
    try std.testing.expectEqual(@as(usize, 0), implementation.replays);
    runner.replay();
    try std.testing.expectEqual(@as(usize, 1), implementation.replays);
}

test "loaded snapshot metadata wins a stale index observation" {
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    var loaded: persistence.SessionFile.Loaded = .{
        .session = session,
        .meta = .{
            .id = try std.testing.allocator.dupe(u8, "loaded-id"),
            .selection = .{
                .provider = try std.testing.allocator.dupe(u8, "loaded-provider"),
                .model = try std.testing.allocator.dupe(u8, "loaded-model"),
                .effort = try std.testing.allocator.dupe(u8, "high"),
                .preset = try std.testing.allocator.dupe(u8, "loaded-preset"),
            },
        },
        .last_selection = .{},
        .item_high_water = 0,
        .recovery = .{},
    };
    session = undefined;
    defer loaded.deinit();
    const stale_index: persistence.SessionFile.Selection = .{
        .provider = "stale-provider",
        .model = "stale-model",
        .effort = "low",
        .preset = "stale-preset",
    };

    const authority = loadedAuthority(&loaded);
    try std.testing.expectEqualStrings("loaded-id", authority.id.?);
    try std.testing.expectEqualStrings("loaded-provider", authority.selection.provider.?);
    try std.testing.expectEqualStrings("loaded-model", authority.selection.model.?);
    try std.testing.expectEqualStrings("high", authority.selection.effort.?);
    try std.testing.expectEqualStrings("loaded-preset", authority.selection.preset.?);
    try std.testing.expect(!std.mem.eql(u8, stale_index.provider.?, authority.selection.provider.?));
}

test "provider-less resume keeps the current selection" {
    try std.testing.expect(!hasRecordedProvider(null));
    try std.testing.expect(!hasRecordedProvider(""));
    try std.testing.expect(!hasRecordedProvider("none"));
    try std.testing.expect(hasRecordedProvider("mock"));
}
