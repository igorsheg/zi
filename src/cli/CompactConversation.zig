//! Provider-independent orchestration for manual conversation compaction.

const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const Interactive = @import("Interactive.zig");

pub const no_provider = "no provider selected — use /provider";
pub const no_model = "no model selected — use /model (or /provider)";
pub const nothing = "nothing to compact";

pub const SelectionSource = struct {
    context: *anyopaque,
    snapshot_fn: *const fn (*anyopaque) Interactive.TurnSnapshot,

    pub fn snapshot(self: SelectionSource) Interactive.TurnSnapshot {
        return self.snapshot_fn(self.context);
    }

    pub fn from(implementation: anytype) SelectionSource {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("CompactConversation.SelectionSource.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn snapshot(context: *anyopaque) Interactive.TurnSnapshot {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.snapshot();
            }
        };
        return .{ .context = implementation, .snapshot_fn = Adapter.snapshot };
    }
};

/// Clears conversation-local continuation and deferred-compaction state after
/// an accepted seed. Calls are synchronous, infallible, and non-retaining.
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
            @compileError("CompactConversation.ResetSink.from expects a mutable single-item pointer");
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

/// Optional command activity. Raw mode arms terminal interruption and displays
/// a spinner. Cooked mode leaves this null.
pub const Activity = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque) anyerror!?agent.CompactRunner.Cancellation,
    finish_fn: *const fn (*anyopaque) anyerror!void,

    pub fn begin(self: Activity) !?agent.CompactRunner.Cancellation {
        return self.begin_fn(self.context);
    }

    pub fn finish(self: Activity) !void {
        return self.finish_fn(self.context);
    }

    pub fn from(implementation: anytype) Activity {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("CompactConversation.Activity.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn begin(context: *anyopaque) anyerror!?agent.CompactRunner.Cancellation {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.begin();
            }

            fn finish(context: *anyopaque) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.finish();
            }
        };
        return .{ .context = implementation, .begin_fn = Adapter.begin, .finish_fn = Adapter.finish };
    }
};

pub const Outcome = enum {
    no_provider,
    no_model,
    empty,
    compacted,
    cancelled,
    provider_failure,
    no_summary,
};

pub const Issue = struct {
    usage_observer_failed: bool = false,
    durability: agent.CompactRunner.Durability = .not_attempted,
    activity_failed: bool = false,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    outcome: Outcome,
    mutation: agent.CompactRunner.Mutation = .none,
    issue: Issue = .{},
    diagnostic: ?[]const u8 = null,
    owned_diagnostic: ?[]u8 = null,

    pub fn deinit(self: *Result) void {
        if (self.owned_diagnostic) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

/// Synchronous manual-compaction service. Every dependency is borrowed for the
/// call. The current selection is sampled once after all preflights.
pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *agent.Session.Session,
    selection: SelectionSource,
    usage: *agent.UsageStats.UsageStats,
    seam_hook: agent.Loop.SeamHook,
    reset_sink: ResetSink,
    activity: ?Activity = null,

    pub fn run(self: *Service, focus: ?[]const u8) Result {
        const snapshot = self.selection.snapshot();
        if (snapshot.provider.id.len == 0) return .{ .allocator = self.allocator, .outcome = .no_provider };
        if (snapshot.model.len == 0) return .{ .allocator = self.allocator, .outcome = .no_model };
        if (self.session.items().len == 0) return .{ .allocator = self.allocator, .outcome = .empty };

        var cancellation: ?agent.CompactRunner.Cancellation = null;
        var activity_started = false;
        if (self.activity) |activity| {
            cancellation = activity.begin() catch |err| return failureFromError(self.allocator, err);
            activity_started = true;
        }

        var compact_result = agent.CompactRunner.run(self.allocator, self.io, .{
            .session = self.session,
            .provider = snapshot.provider,
            .model = snapshot.model,
            .model_metadata = snapshot.model_metadata,
            .model_metadata_source = snapshot.model_metadata_source,
            .system_prompt = snapshot.system_prompt,
            .tools = snapshot.tools,
            .effort = snapshot.effort,
            .focus = focus,
            .cancellation = cancellation,
            .seam_hook = self.seam_hook,
            .usage_observer = agent.Loop.UsageObserver.from(self.usage),
        }) catch |err| {
            var result = failureFromError(self.allocator, err);
            if (activity_started) self.activity.?.finish() catch {
                result.issue.activity_failed = true;
            };
            return result;
        };

        var result: Result = .{
            .allocator = self.allocator,
            .outcome = switch (compact_result.outcome) {
                .compacted => .compacted,
                .cancelled => .cancelled,
                .provider_failure => .provider_failure,
                .no_summary => .no_summary,
            },
            .mutation = compact_result.mutation,
            .issue = .{
                .usage_observer_failed = compact_result.issue.usage_observer_failed,
                .durability = compact_result.issue.durability,
            },
            .diagnostic = compact_result.diagnostic,
            .owned_diagnostic = compact_result.diagnostic,
        };
        compact_result.diagnostic = null;
        compact_result.deinit(self.allocator);

        // Mutation classification is authoritative even when observation,
        // durability, or terminal cleanup reports a later issue.
        if (result.mutation == .seed_committed) {
            self.usage.invalidateContext();
            self.reset_sink.reset();
        }
        if (activity_started) self.activity.?.finish() catch {
            result.issue.activity_failed = true;
        };
        return result;
    }
};

fn failureFromError(allocator: std.mem.Allocator, err: anyerror) Result {
    const name = @errorName(err);
    const owned = allocator.dupe(u8, name) catch null;
    return .{
        .allocator = allocator,
        .outcome = .provider_failure,
        .diagnostic = if (owned) |value| value else name,
        .owned_diagnostic = owned,
    };
}

/// Erased synchronous command-facing service.
pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, ?[]const u8) Result,

    pub fn run(self: Runner, focus: ?[]const u8) Result {
        return self.run_fn(self.context, focus);
    }

    pub fn from(implementation: anytype) Runner {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("CompactConversation.Runner.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn run(context: *anyopaque, focus: ?[]const u8) Result {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.run(focus);
            }
        };
        return .{ .context = implementation, .run_fn = Adapter.run };
    }
};

const FakeSelection = struct {
    provider: ai.Provider.Provider,
    model: []const u8,

    pub fn snapshot(self: *FakeSelection) Interactive.TurnSnapshot {
        return .{
            .provider = self.provider,
            .model = self.model,
            .model_metadata = .{},
            .model_metadata_source = null,
            .system_prompt = "system",
            .tools = &.{},
            .effort = null,
            .image_input = .unknown,
            .image_input_source = null,
            .max_turns = agent.Loop.maximum_max_turns,
        };
    }
};

const FakeProvider = struct {
    mode: enum { success, empty, failure, cancelled } = .success,
    calls: usize = 0,
    focus_seen: bool = false,

    pub fn stream(
        _: std.mem.Allocator,
        _: std.Io,
        self: *FakeProvider,
        request: ai.Provider.Request,
        sink: ai.Provider.EventSink,
    ) ai.Provider.StreamError!void {
        self.calls += 1;
        const checkpoint = request.context.items[request.context.items.len - 1].user_message.text;
        self.focus_seen = std.mem.endsWith(u8, checkpoint, "\nkeep exact paths");
        switch (self.mode) {
            .success => {
                try sink.emit(.{ .text_delta = "summary" });
                try sink.emit(.{ .done = .{} });
            },
            .empty => try sink.emit(.{ .done = .{} }),
            .failure => return error.ProviderUnavailable,
            .cancelled => return error.Cancelled,
        }
    }
};

const FakeSeam = struct {
    disposition: agent.Loop.SeamDisposition = .synchronized,
    failure: ?agent.Loop.HookError = null,
    calls: usize = 0,

    pub fn call(
        self: *FakeSeam,
        _: *const agent.Session.Session,
        _: agent.Loop.SeamKind,
        _: bool,
    ) agent.Loop.HookError!agent.Loop.SeamDisposition {
        self.calls += 1;
        if (self.failure) |err| return err;
        return self.disposition;
    }
};

const FakeReset = struct {
    calls: usize = 0,
    pub fn reset(self: *FakeReset) void {
        self.calls += 1;
    }
};

fn makeService(
    session: *agent.Session.Session,
    selection: *FakeSelection,
    usage: *agent.UsageStats.UsageStats,
    seam: *FakeSeam,
    reset: *FakeReset,
) Service {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .session = session,
        .selection = SelectionSource.from(selection),
        .usage = usage,
        .seam_hook = agent.Loop.SeamHook.from(seam),
        .reset_sink = ResetSink.from(reset),
    };
}

test "manual compact preflights do not request a provider" {
    var provider: FakeProvider = .{};
    var selection: FakeSelection = .{
        .provider = ai.Provider.Provider.from(&provider, ""),
        .model = "model",
    };
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var usage = try agent.UsageStats.UsageStats.init(std.testing.allocator, 8);
    defer usage.deinit();
    var seam: FakeSeam = .{};
    var reset: FakeReset = .{};
    var service = makeService(&session, &selection, &usage, &seam, &reset);

    var result = service.run(null);
    defer result.deinit();
    try std.testing.expectEqual(Outcome.no_provider, result.outcome);
    selection.provider = ai.Provider.Provider.from(&provider, "provider");
    selection.model = "";
    result.deinit();
    result = service.run(null);
    try std.testing.expectEqual(Outcome.no_model, result.outcome);
    selection.model = "model";
    result.deinit();
    result = service.run(null);
    try std.testing.expectEqual(Outcome.empty, result.outcome);
    try std.testing.expectEqual(@as(usize, 0), provider.calls);
    try std.testing.expectEqual(@as(usize, 0), seam.calls);
}

test "manual compact forwards focus and classifies terminal outcomes" {
    inline for (.{
        .{ FakeProvider{ .mode = .success }, Outcome.compacted },
        .{ FakeProvider{ .mode = .empty }, Outcome.no_summary },
        .{ FakeProvider{ .mode = .failure }, Outcome.provider_failure },
        .{ FakeProvider{ .mode = .cancelled }, Outcome.cancelled },
    }) |case| {
        var provider = case[0];
        var selection: FakeSelection = .{
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
        };
        var session = try agent.Session.Session.init(std.testing.allocator, .{});
        defer session.deinit();
        try session.addUser("history");
        var usage = try agent.UsageStats.UsageStats.init(std.testing.allocator, 8);
        defer usage.deinit();
        var seam: FakeSeam = .{};
        var reset: FakeReset = .{};
        var service = makeService(&session, &selection, &usage, &seam, &reset);

        var result = service.run("keep exact paths");
        defer result.deinit();
        try std.testing.expectEqual(case[1], result.outcome);
        try std.testing.expect(provider.focus_seen);
        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqual(@as(usize, @intFromBool(case[1] == .compacted)), reset.calls);
    }
}

test "seed mutation wins over observer and durability issues" {
    var provider: FakeProvider = .{};
    var selection: FakeSelection = .{
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
    };
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.addUser("history");
    var usage = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer usage.deinit();
    // Fill the observer so compaction observation reports CapacityExceeded.
    try usage.observe(.{
        .footer = .{},
        .spend = .{},
        .attempts = &.{.{}},
        .kind = .ordinary,
        .terminal_context_tokens = 9,
    });
    var seam: FakeSeam = .{ .failure = error.Failed };
    var reset: FakeReset = .{};
    var service = makeService(&session, &selection, &usage, &seam, &reset);

    var result = service.run(null);
    defer result.deinit();
    try std.testing.expectEqual(Outcome.compacted, result.outcome);
    try std.testing.expectEqual(agent.CompactRunner.Mutation.seed_committed, result.mutation);
    try std.testing.expect(result.issue.usage_observer_failed);
    try std.testing.expectEqual(agent.CompactRunner.Durability.failed, result.issue.durability);
    try std.testing.expectEqual(@as(usize, 1), reset.calls);
    try std.testing.expectEqual(@as(?u64, null), usage.last_ordinary_context_tokens);
}
