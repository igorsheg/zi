const std = @import("std");
const agent = @import("../agent/root.zig");
const persistence = @import("../persistence/root.zig");
const terminal = @import("../terminal/root.zig");
const tool = @import("../tool/root.zig");
const transcript = @import("../transcript/root.zig");
const SessionDurability = @import("../SessionDurability.zig");
const ConversationRuntime = @import("ConversationRuntime.zig");
const RunSelection = @import("RunSelection.zig");
const SessionStartup = @import("SessionStartup.zig");
const TurnPicker = @import("TurnPicker.zig");

pub const needs_number = "/undo needs a number of turns when not interactive";
pub const nothing_to_undo = "nothing to undo yet";
pub const disk_failure = "could not truncate the session file; conversation left unchanged";

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
            @compileError("UndoConversation.ResetSink.from expects a mutable single-item pointer");
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

pub const TranscriptSink = struct {
    context: *anyopaque,
    rebuild_fn: *const fn (*anyopaque, *const agent.Session.Session) void,

    pub fn rebuild(self: TranscriptSink, session: *const agent.Session.Session) void {
        self.rebuild_fn(self.context, session);
    }

    pub fn from(implementation: anytype) TranscriptSink {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("UndoConversation.TranscriptSink.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn rebuild(context: *anyopaque, session: *const agent.Session.Session) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.rebuildTranscript(.undo, session);
            }
        };
        return .{ .context = implementation, .rebuild_fn = Adapter.rebuild };
    }
};

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
            @compileError("UndoConversation.ReplaySink.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn replay(
                context: *anyopaque,
                session: *const agent.Session.Session,
                tools: []const tool.Tool.Tool,
                heading: []const u8,
            ) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.replay(session, tools, heading);
            }
        };
        return .{ .context = implementation, .replay_fn = Adapter.replay };
    }
};

pub const Unchanged = union(enum) {
    nothing,
    needs_number,
    invalid_range: usize,
    canceled,
    reconcile_retryable: SessionDurability.ReconcileFailure,
    reconcile_quarantined: SessionDurability.QuarantineReason,
    preparation: anyerror,
    disk_unchanged: persistence.SessionFile.TruncateUnchanged,
    disk_indeterminate: persistence.SessionFile.TruncateIndeterminate,
};

pub const Changed = struct {
    result: ConversationRuntime.UndoResult,
    sync_failed: bool,
};

pub const Outcome = union(enum) {
    changed: Changed,
    unchanged: Unchanged,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    conversation: *ConversationRuntime.Owner,
    selection: *RunSelection.Owner,
    usage: *agent.UsageStats.UsageStats,
    transcript_sink: TranscriptSink,
    reset_sink: ResetSink,
    prompt_history: ?*terminal.PromptHistory = null,
    picker: ?TurnPicker.Runner = null,
    replay_sink: ?ReplaySink = null,
    replay_turns: usize = 0,

    pub fn run(self: *Service, argument: ?[]const u8) Outcome {
        const session = self.conversation.session();
        const typed_count = session.typedTurnCount();
        if (typed_count == 0) return .{ .unchanged = .nothing };

        const remove_count = if (argument) |value|
            parseCount(value, typed_count) orelse return .{ .unchanged = .{ .invalid_range = typed_count } }
        else selected: {
            const picker = self.picker orelse return .{ .unchanged = .needs_number };
            var turns: [TurnPicker.maximum_rows]agent.Session.TypedTurn = undefined;
            const start = typed_count -| TurnPicker.maximum_rows;
            for (start..typed_count, 0..) |ordinal, index| turns[index] = session.typedTurn(ordinal).?;
            const choice = picker.run(.{
                .title = "revert to before which message",
                .turns = turns[0 .. typed_count - start],
            }) catch |err| return .{ .unchanged = .{ .preparation = err } };
            const ordinal = switch (choice) {
                .canceled => return .{ .unchanged = .canceled },
                .selected => |selected_ordinal| selected_ordinal,
            };
            if (ordinal >= typed_count) return .{ .unchanged = .canceled };
            break :selected typed_count - ordinal;
        };

        switch (self.conversation.durability().reconcile(session)) {
            .synchronized, .unrecorded => {},
            .retryable => |failure| return .{ .unchanged = .{ .reconcile_retryable = failure } },
            .quarantined => |reason| return .{ .unchanged = .{ .reconcile_quarantined = reason } },
        }
        const entry = self.conversation.captureEntryState(self.selection);
        var memory = session.prepareTypedCut(typed_count - remove_count) catch |err|
            return .{ .unchanged = .{ .preparation = err } };
        var memory_owned = true;
        defer if (memory_owned) memory.deinit();

        var prompt_admission: ?terminal.PromptHistory.PreparedAdmission = if (self.prompt_history) |history|
            history.prepareAdmission(memory.first_removed_prompt.?, .session) catch |err|
                return .{ .unchanged = .{ .preparation = err } }
        else
            null;
        defer if (prompt_admission) |*prepared| prepared.deinit();

        var durability = self.conversation.durability().prepareCut(session, &memory) catch |err| {
            if (quarantinedCutReason(self.conversation.durability().state(session))) |reason| {
                return .{ .unchanged = .{ .disk_indeterminate = reason } };
            }
            return .{ .unchanged = .{ .preparation = err } };
        };
        defer if (durability.active) durability.deinit();
        var candidate = self.conversation.prepareUndo(
            self.selection,
            entry,
            &memory,
            &durability,
        ) catch |err| return .{ .unchanged = .{ .preparation = err } };
        memory_owned = false;
        defer if (candidate.active) candidate.deinit();

        if (prompt_admission) |*prepared| self.prompt_history.?.validateAdmission(prepared) catch |err|
            return .{ .unchanged = .{ .preparation = err } };

        const disk = self.conversation.durability().executeCut(&durability) catch |err| {
            if (quarantinedCutReason(self.conversation.durability().state(session))) |reason| {
                return .{ .unchanged = .{ .disk_indeterminate = reason } };
            }
            return .{ .unchanged = .{ .preparation = err } };
        };
        var commit = switch (disk) {
            .unchanged => |reason| return .{ .unchanged = .{ .disk_unchanged = reason } },
            .indeterminate => |reason| return .{ .unchanged = .{ .disk_indeterminate = reason } },
            .committed => |value| value,
        };
        defer commit.deinit();
        const sync_failed = commit.durability == .sync_failed;

        const final_guard = self.conversation.captureEntryState(self.selection).guard;
        self.conversation.bindUndo(self.selection, &candidate, final_guard) catch unreachable;
        var lease = self.conversation.beginPublish(&candidate.authorization.?) catch unreachable;
        var retired = ConversationRuntime.publishUndo(&lease, &candidate);
        if (prompt_admission) |*prepared| self.prompt_history.?.publishAdmission(prepared);
        commit.finish();
        const result = retired.result;
        retired.deinit();

        self.usage.invalidateContext();
        self.reset_sink.reset();
        self.transcript_sink.rebuild(session);
        self.replay_turns = result.removed_turns;
        return .{ .changed = .{ .result = result, .sync_failed = sync_failed } };
    }

    /// Advisory presentation performed only after command diagnostics.
    pub fn replay(self: *Service) void {
        const sink = self.replay_sink orelse return;
        var heading_buffer: [64]u8 = undefined;
        const heading = if (self.replay_turns == 1)
            std.fmt.bufPrint(&heading_buffer, "undid {d} turn", .{self.replay_turns}) catch return
        else
            std.fmt.bufPrint(&heading_buffer, "undid {d} turns", .{self.replay_turns}) catch return;
        sink.replay(self.conversation.session(), self.selection.tool_list, heading) catch |err| {
            _ = @errorName(err);
        };
    }
};

fn quarantinedCutReason(state: SessionDurability.State) ?persistence.SessionFile.TruncateIndeterminate {
    return switch (state) {
        .quarantined => |reason| switch (reason) {
            .removed => .removed,
            .external_change, .high_water_diverged, .truncate_indeterminate => .changed,
            .append_indeterminate, .sync_failed => null,
        },
        .unrecorded, .synchronized, .pending_append => null,
    };
}

fn parseCount(input: []const u8, typed_count: usize) ?usize {
    const trimmed = std.mem.trim(u8, input, " \t\r\n\x0b\x0c");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    if (value <= 0) return null;
    const positive: u64 = @intCast(value);
    if (positive > typed_count) return null;
    return @intCast(positive);
}

pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, ?[]const u8) Outcome,
    replay_fn: *const fn (*anyopaque) void,

    pub fn run(self: Runner, argument: ?[]const u8) Outcome {
        return self.run_fn(self.context, argument);
    }

    pub fn replay(self: Runner) void {
        self.replay_fn(self.context);
    }

    pub fn from(implementation: anytype) Runner {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("UndoConversation.Runner.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn run(context: *anyopaque, argument: ?[]const u8) Outcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run(argument);
            }

            fn replay(context: *anyopaque) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.replay();
            }
        };
        return .{ .context = implementation, .run_fn = Adapter.run, .replay_fn = Adapter.replay };
    }
};

const TestIdentity = struct {
    pub fn nextTimestamp(_: *TestIdentity) persistence.Paths.Timestamp {
        return .{ .epoch_seconds = 0 };
    }

    pub fn nextUuid(_: *TestIdentity) ConversationRuntime.UuidProvider.Error![16]u8 {
        return [_]u8{0} ** 16;
    }
};

const TestOrder = struct {
    next: usize = 0,
    reset_at: ?usize = null,
    rebuild_at: ?usize = null,
    rebuilt_turns: usize = 0,
};

const TestReset = struct {
    order: *TestOrder,

    fn reset(self: *TestReset) void {
        self.order.reset_at = self.order.next;
        self.order.next += 1;
    }
};

const TestTranscript = struct {
    order: *TestOrder,

    fn rebuildTranscript(
        self: *TestTranscript,
        operation: transcript.Operation,
        session: *const agent.Session.Session,
    ) void {
        std.debug.assert(operation == .undo);
        self.order.rebuild_at = self.order.next;
        self.order.next += 1;
        self.order.rebuilt_turns = session.typedTurnCount();
    }
};

test "service publishes recall then invalidates resets and rebuilds the retained branch" {
    const allocator = std.testing.allocator;
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = try agent.Session.Session.init(allocator, .{}),
        .log = null,
        .identity = .{ .origin = .fresh },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    defer if (startup.active) startup.deinit();
    try startup.session.addUser("first");
    try startup.session.addUser("second");
    var identity: TestIdentity = .{};
    const conversation = try ConversationRuntime.Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .disabled,
        .fresh = .{
            .state_root = null,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = ConversationRuntime.TimestampProvider.from(&identity),
            .uuid_provider = ConversationRuntime.UuidProvider.from(&identity),
        },
    });
    defer conversation.deinit();
    var selection: RunSelection.Owner = undefined;
    selection.generation = 0;
    selection.committing = false;
    selection.preset_transition_generation = 0;
    selection.catalog_lookup_active = false;
    selection.tool_list = &.{};
    var usage = try agent.UsageStats.UsageStats.init(allocator, 2);
    defer usage.deinit();
    try usage.observe(.{
        .footer = .{},
        .spend = .{},
        .attempts = &.{},
        .kind = .ordinary,
        .terminal_context_tokens = 9,
    });
    var history = terminal.PromptHistory.init(allocator);
    defer history.deinit();
    try history.admit("/undo 1", .session);
    var order: TestOrder = .{};
    var reset: TestReset = .{ .order = &order };
    var transcript_sink: TestTranscript = .{ .order = &order };
    var service: Service = .{
        .allocator = allocator,
        .conversation = conversation,
        .selection = &selection,
        .usage = &usage,
        .transcript_sink = TranscriptSink.from(&transcript_sink),
        .reset_sink = ResetSink.from(&reset),
        .prompt_history = &history,
    };

    const outcome = service.run("1");
    try std.testing.expect(outcome == .changed);
    try std.testing.expectEqual(@as(usize, 1), conversation.session().typedTurnCount());
    try std.testing.expectEqual(@as(usize, 2), history.count());
    try std.testing.expectEqualStrings("/undo 1", history.entry(0).?);
    try std.testing.expectEqualStrings("second", history.entry(1).?);
    try std.testing.expect(usage.last_ordinary_context_tokens == null);
    try std.testing.expectEqual(@as(?usize, 0), order.reset_at);
    try std.testing.expectEqual(@as(?usize, 1), order.rebuild_at);
    try std.testing.expectEqual(@as(usize, 1), order.rebuilt_turns);
}

fn failTestSetLength(_: std.Io, _: std.Io.File, _: u64) error{IoFailure}!void {
    return error.IoFailure;
}

fn setTestUnexpectedLength(io: std.Io, file: std.Io.File, length: u64) error{IoFailure}!void {
    file.setLength(io, length + 1) catch return error.IoFailure;
}

fn exerciseDiskFailure(root: []const u8, indeterminate: bool) !void {
    const allocator = std.testing.allocator;
    var log: ?persistence.SessionFile.Log = try persistence.SessionFile.Log.prepare(allocator, std.testing.io, .{
        .state_root = root,
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = .{
            0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
            0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x03,
        },
        .writer_version = "test",
    });
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = try agent.Session.Session.init(allocator, .{}),
        .log = log,
        .identity = .{ .origin = .fresh },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    log = null;
    defer if (startup.active) startup.deinit();
    try startup.session.addUser("first");
    try startup.session.addUser("second");
    var identity: TestIdentity = .{};
    const conversation = try ConversationRuntime.Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .enabled,
        .fresh = .{
            .state_root = root,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = ConversationRuntime.TimestampProvider.from(&identity),
            .uuid_provider = ConversationRuntime.UuidProvider.from(&identity),
        },
    });
    defer conversation.deinit();
    try std.testing.expect(conversation.durability().reconcile(conversation.session()) == .synchronized);
    switch (conversation.durability().authority) {
        .active => |*active_log| active_log.set_length_fn = if (indeterminate)
            setTestUnexpectedLength
        else
            failTestSetLength,
        .unrecorded, .quarantined => unreachable,
    }

    var selection: RunSelection.Owner = undefined;
    selection.generation = 0;
    selection.committing = false;
    selection.preset_transition_generation = 0;
    selection.catalog_lookup_active = false;
    selection.tool_list = &.{};
    var usage = try agent.UsageStats.UsageStats.init(allocator, 1);
    defer usage.deinit();
    var history = terminal.PromptHistory.init(allocator);
    defer history.deinit();
    var order: TestOrder = .{};
    var reset: TestReset = .{ .order = &order };
    var transcript_sink: TestTranscript = .{ .order = &order };
    var service: Service = .{
        .allocator = allocator,
        .conversation = conversation,
        .selection = &selection,
        .usage = &usage,
        .transcript_sink = TranscriptSink.from(&transcript_sink),
        .reset_sink = ResetSink.from(&reset),
        .prompt_history = &history,
    };

    const outcome = service.run("1");
    if (indeterminate) {
        try std.testing.expect(outcome.unchanged == .disk_indeterminate);
        try std.testing.expectEqual(
            SessionDurability.QuarantineReason.truncate_indeterminate,
            conversation.durability().state(conversation.session()).quarantined,
        );
    } else {
        try std.testing.expect(outcome.unchanged == .disk_unchanged);
        try std.testing.expect(conversation.durability().state(conversation.session()) == .synchronized);
    }
    try std.testing.expectEqual(@as(usize, 2), conversation.session().typedTurnCount());
    try std.testing.expectEqual(@as(usize, 0), history.count());
    try std.testing.expect(order.reset_at == null);
    try std.testing.expect(order.rebuild_at == null);
}

test "service releases moved cuts after unchanged and indeterminate disk outcomes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(first);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    const second = try tmp.dir.realPathFileAlloc(std.testing.io, "second", std.testing.allocator);
    defer std.testing.allocator.free(second);
    try exerciseDiskFailure(first, false);
    try exerciseDiskFailure(second, true);
}

test "count parser matches strtol-style whitespace and rejects invalid ranges" {
    try std.testing.expectEqual(@as(?usize, 2), parseCount(" \t2\n", 3));
    try std.testing.expectEqual(@as(?usize, 2), parseCount("+2", 3));
    try std.testing.expectEqual(@as(?usize, null), parseCount("2x", 3));
    try std.testing.expectEqual(@as(?usize, null), parseCount("0", 3));
    try std.testing.expectEqual(@as(?usize, null), parseCount("-1", 3));
    try std.testing.expectEqual(@as(?usize, null), parseCount("4", 3));
    try std.testing.expectEqual(@as(?usize, null), parseCount("999999999999999999999999", 3));
}
