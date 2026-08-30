//! Binds the agent loop's synchronous durability seam to one session log.
//!
//! `Owner` is heap allocated because `agent.Loop.SeamHook` erases a pointer to
//! it. The log and optional observation context are borrowed through `deinit`.

const std = @import("std");
const agent = @import("agent/root.zig");
const ai = @import("ai/root.zig");
const persistence = @import("persistence/root.zig");

pub const Observation = struct {
    kind: agent.Loop.SeamKind,
    next_action: bool,
    high_water: usize,
};

pub const ObservationError = error{
    OutOfMemory,
    Failed,
    Indeterminate,
};

/// Synchronous output-coordination callback. `Observation` is entirely by
/// value. The callback must not retain the erased context beyond its lifetime.
pub const Observer = struct {
    context: *anyopaque,
    observe_fn: *const fn (*anyopaque, Observation) ObservationError!void,

    pub fn from(pointer: anytype) Observer {
        const Pointer = @TypeOf(pointer);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("Observer.from expects a mutable single-item pointer");
        }
        const Adapter = struct {
            fn observe(context: *anyopaque, observation: Observation) ObservationError!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.observe(observation);
            }
        };
        return .{ .context = pointer, .observe_fn = Adapter.observe };
    }

    pub fn observe(self: Observer, observation: Observation) ObservationError!void {
        return self.observe_fn(self.context, observation);
    }
};

pub const Options = struct {
    observer: ?Observer = null,
};

pub const CreateError = error{OutOfMemory};

/// A known split means the requested selection is staged on the log while the
/// live session still has its previous selection. Preexisting divergence means
/// this helper changed neither side because it could not establish a safe base.
pub const PartialState = enum {
    log_only,
    preexisting_divergence,
};

pub const FailureClass = enum {
    out_of_memory,
    failed,
    indeterminate,
};

pub const PartialSelection = struct {
    state: PartialState,
    failure: FailureClass,
};

pub const SelectionUpdate = union(enum) {
    unchanged,
    updated,
    partial: PartialSelection,
};

pub const SelectionError = error{
    OutOfMemory,
    Failed,
    Indeterminate,
};

pub const PrepareSelectionError = error{
    OutOfMemory,
    Failed,
    Indeterminate,
    Diverged,
};

/// Move-only coordinated session and log replacement. Preparation changes
/// neither owner; publication consumes both replacements without allocating.
pub const PreparedSelection = struct {
    session: agent.Session.PreparedSelection,
    log: persistence.SessionFile.PreparedSelection,
    changed: bool,
    active: bool = true,

    pub fn deinit(self: *PreparedSelection) void {
        if (self.active) {
            self.log.deinit();
            self.session.deinit();
        }
        self.* = undefined;
    }
};

/// Heap-stable owner of the erased seam hook. `log` is borrowed and must
/// outlive this owner. Calls must remain synchronous and serialized with all
/// other mutations of the log.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    log: *persistence.SessionFile.Log,
    observer: ?Observer,

    pub fn create(
        allocator: std.mem.Allocator,
        log: *persistence.SessionFile.Log,
        options: Options,
    ) CreateError!*Owner {
        const self = try allocator.create(Owner);
        self.* = .{
            .allocator = allocator,
            .log = log,
            .observer = options.observer,
        };
        return self;
    }

    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn seamHook(self: *Owner) agent.Loop.SeamHook {
        return agent.Loop.SeamHook.from(self);
    }

    pub fn call(
        self: *Owner,
        session: *const agent.Session.Session,
        kind: agent.Loop.SeamKind,
        next_action: bool,
    ) agent.Loop.HookError!void {
        const items = session.items();
        const high_water = self.log.highWater();
        self.log.appendSnapshot(high_water, items) catch |err| return mapLogError(err);
        if (items.len == high_water) return;
        if (self.observer) |observer| {
            observer.observe(.{
                .kind = kind,
                .next_action = next_action,
                .high_water = self.log.highWater(),
            }) catch |err| return mapObservationError(err);
        }
    }

    /// Verifies the current session and log agree, then owns both prospective
    /// replacements without changing either side.
    pub fn prepareSelection(
        self: *Owner,
        session: *agent.Session.Session,
        requested: persistence.SessionFile.Selection,
    ) PrepareSelectionError!PreparedSelection {
        const old_session = session.currentSelection();
        if (!crossSelectionEqual(self.log.currentSelection(), old_session)) return error.Diverged;

        const normalized = normalizeSelection(requested);
        const changed = !crossSelectionEqual(normalized.log, old_session);
        var session_prepared = session.prepareSelection(normalized.session) catch |err|
            return mapSessionError(err);
        errdefer session_prepared.deinit();
        var log_prepared = self.log.prepareSelection(normalized.log) catch |err|
            return mapSelectionLogError(err);
        errdefer log_prepared.deinit();
        return .{
            .session = session_prepared,
            .log = log_prepared,
            .changed = changed,
        };
    }

    /// Publishes a coordinated replacement without allocating. Consumes `prepared`.
    pub fn publishSelection(
        self: *Owner,
        session: *agent.Session.Session,
        prepared: *PreparedSelection,
    ) void {
        std.debug.assert(prepared.active);
        session.publishSelection(&prepared.session);
        self.log.publishSelection(&prepared.log);
        prepared.active = false;
    }

    /// Preserves the original unchanged, updated, and divergence outcomes while
    /// delegating all fallible work to preparation.
    pub fn updateSelection(
        self: *Owner,
        session: *agent.Session.Session,
        requested: persistence.SessionFile.Selection,
    ) SelectionError!SelectionUpdate {
        var prepared = self.prepareSelection(session, requested) catch |err| switch (err) {
            error.Diverged => return .{ .partial = .{
                .state = .preexisting_divergence,
                .failure = .indeterminate,
            } },
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => return error.Failed,
            error.Indeterminate => return error.Indeterminate,
        };
        defer prepared.deinit();
        const changed = prepared.changed;
        self.publishSelection(session, &prepared);
        return if (changed) .updated else .unchanged;
    }
};

const NormalizedSelection = struct {
    log: persistence.SessionFile.Selection,
    session: agent.Session.Selection,
};

fn normalizeSelection(value: persistence.SessionFile.Selection) NormalizedSelection {
    const preset = if (value.preset) |preset_value|
        if (preset_value.len == 0) null else preset_value
    else
        null;
    return .{
        .log = .{
            .provider = value.provider,
            .model = value.model,
            .model_label = value.model_label,
            .effort = value.effort,
            .preset = preset,
        },
        .session = .{
            .provider_id = value.provider,
            .model = value.model,
            .model_label = value.model_label,
            .effort = value.effort,
            .preset = preset,
        },
    };
}

fn crossSelectionEqual(
    log: persistence.SessionFile.Selection,
    session: agent.Session.Selection,
) bool {
    return optionalEqual(log.provider, session.provider_id) and
        optionalEqual(log.model, session.model) and
        optionalEqual(log.model_label, session.model_label) and
        optionalEqual(log.effort, session.effort) and
        optionalEqual(log.preset, session.preset);
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn mapLogError(err: persistence.SessionFile.Error) agent.Loop.HookError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Poisoned, error.Removed, error.IoFailure, error.IndeterminateCleanup => error.Indeterminate,
        else => error.Failed,
    };
}

fn mapObservationError(err: ObservationError) agent.Loop.HookError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.Failed,
        error.Indeterminate => error.Indeterminate,
    };
}

fn mapSelectionLogError(err: persistence.SessionFile.Error) SelectionError {
    return switch (mapLogError(err)) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.Failed,
        error.Indeterminate => error.Indeterminate,
    };
}

fn mapSessionError(err: agent.Session.Error) SelectionError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

const TestRecorder = struct {
    values: [8]Observation = undefined,
    length: usize = 0,
    failure: ?ObservationError = null,

    fn observe(self: *TestRecorder, observation: Observation) ObservationError!void {
        if (self.failure) |failure| return failure;
        self.values[self.length] = observation;
        self.length += 1;
    }
};

fn testLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    selection: persistence.SessionFile.Selection,
) !persistence.SessionFile.Log {
    return persistence.SessionFile.Log.prepare(allocator, io, .{
        .state_root = root,
        .cwd = "/work",
        .selection = selection,
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = [_]u8{
            0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
            0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
        },
        .writer_version = "test",
    });
}

test "every loop seam durably appends and preserves observation values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var log = try testLog(allocator, io, root, .{});
    defer log.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    var recorder: TestRecorder = .{};
    const owner = try Owner.create(allocator, &log, .{ .observer = Observer.from(&recorder) });
    defer owner.deinit();
    const hook = owner.seamHook();

    // An empty seam is an exact no-op: it neither writes the lazy header nor
    // reports an observation that could be mistaken for a durable append.
    try hook.call(&session, .completion, true);
    try std.testing.expect(!log.materialized());
    try std.testing.expectEqual(@as(usize, 0), recorder.length);

    const kinds = [_]agent.Loop.SeamKind{
        .provider_failure,
        .completion,
        .tool_batch,
        .compaction,
        .interruption,
        .pause,
    };
    for (kinds, 0..) |kind, index| {
        try session.appendCopy(&.{ .user_message = .{ .text = @constCast("item") } });
        const next_action = index % 2 == 0;
        try hook.call(&session, kind, next_action);
        try std.testing.expectEqual(kind, recorder.values[index].kind);
        try std.testing.expectEqual(next_action, recorder.values[index].next_action);
        try std.testing.expectEqual(index + 1, recorder.values[index].high_water);
    }
    try std.testing.expect(log.materialized());
    try std.testing.expectEqual(session.items().len, log.highWater());
}

test "hook maps mismatch and callback failures without advancing observations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var log = try testLog(allocator, io, root, .{});
    defer log.deinit();
    const initial = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("persisted") } },
    };
    try log.appendSnapshot(0, &initial);
    var empty = try agent.Session.Session.init(allocator, .{});
    defer empty.deinit();
    var recorder: TestRecorder = .{ .failure = error.Indeterminate };
    const owner = try Owner.create(allocator, &log, .{ .observer = Observer.from(&recorder) });
    defer owner.deinit();
    try std.testing.expectError(error.Failed, owner.seamHook().call(&empty, .completion, false));

    try empty.appendCopy(&initial[0]);
    try empty.appendCopy(&.{ .assistant_message = .{ .text = @constCast("new") } });
    try std.testing.expectError(
        error.Indeterminate,
        owner.seamHook().call(&empty, .tool_batch, true),
    );
    // Callback failure happens after the append and cannot roll it back.
    try std.testing.expectEqual(@as(usize, 2), log.highWater());

    try std.testing.expectEqual(error.Indeterminate, mapLogError(error.IoFailure));
    try std.testing.expectEqual(error.Indeterminate, mapLogError(error.Removed));
    try std.testing.expectEqual(error.Indeterminate, mapLogError(error.Poisoned));
    try std.testing.expectEqual(error.OutOfMemory, mapLogError(error.OutOfMemory));
    try std.testing.expectEqual(error.Failed, mapLogError(error.FileTooLarge));
}

test "prepared selection can be dropped, published, and rejects divergence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const original: persistence.SessionFile.Selection = .{ .provider = "a", .model = "m" };

    var log = try testLog(allocator, io, root, original);
    defer log.deinit();
    var session = try agent.Session.Session.init(allocator, .{
        .provider_id = "a",
        .model = "m",
        .limits = .{ .provider_id_bytes = 1 },
    });
    defer session.deinit();
    const owner = try Owner.create(allocator, &log, .{});
    defer owner.deinit();

    var no_op = try owner.prepareSelection(&session, original);
    try std.testing.expect(!no_op.changed);
    owner.publishSelection(&session, &no_op);
    no_op.deinit();

    var dropped = try owner.prepareSelection(&session, .{ .provider = "b", .model = "m2" });
    dropped.deinit();
    try std.testing.expectEqualStrings("a", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("a", log.currentSelection().provider.?);

    try std.testing.expectEqual(SelectionUpdate.unchanged, try owner.updateSelection(&session, original));
    const changed = try owner.updateSelection(&session, .{ .provider = "b", .model = "m2" });
    try std.testing.expectEqual(SelectionUpdate.updated, changed);
    try std.testing.expectEqualStrings("b", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("b", log.currentSelection().provider.?);

    // Preparation validates both replacements before either side changes.
    try std.testing.expectError(
        error.Failed,
        owner.updateSelection(&session, .{ .provider = "too-long", .model = "m2" }),
    );
    try std.testing.expectEqualStrings("b", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("b", log.currentSelection().provider.?);

    try log.setSelection(.{ .provider = "other", .model = "m2" });
    try std.testing.expectError(
        error.Diverged,
        owner.prepareSelection(&session, .{ .provider = "c", .model = "m2" }),
    );
    const partial = try owner.updateSelection(&session, .{ .provider = "c", .model = "m2" });
    try std.testing.expectEqual(PartialState.preexisting_divergence, partial.partial.state);
    try std.testing.expectEqual(FailureClass.indeterminate, partial.partial.failure);
}

fn exerciseSelectionPreparationAllocations(
    allocator: std.mem.Allocator,
    root: []const u8,
) !void {
    const original: persistence.SessionFile.Selection = .{
        .provider = "old-provider",
        .model = "old-model",
        .model_label = "Old Model",
        .effort = "low",
        .preset = "old-preset",
    };
    var log = try testLog(allocator, std.testing.io, root, original);
    defer log.deinit();
    var session = try agent.Session.Session.init(allocator, .{
        .provider_id = original.provider,
        .model = original.model,
        .model_label = original.model_label,
        .effort = original.effort,
        .preset = original.preset,
    });
    defer session.deinit();
    const owner = try Owner.create(allocator, &log, .{});
    defer owner.deinit();

    var prepared = try owner.prepareSelection(&session, .{
        .provider = "new-provider",
        .model = "new-model",
        .model_label = "New Model",
        .effort = "high",
        .preset = "new-preset",
    });
    defer prepared.deinit();
    try std.testing.expectEqualStrings("old-provider", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("old-provider", log.currentSelection().provider.?);
}

test "coordinated selection preparation frees every allocation failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseSelectionPreparationAllocations,
        .{root},
    );
}

test "resumed log continues from loaded session high water" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var path: []u8 = undefined;
    {
        var prepared = try testLog(allocator, io, root, .{});
        defer prepared.deinit();
        const first = [_]ai.Item.Item{
            .{ .user_message = .{ .text = @constCast("first") } },
        };
        try prepared.appendSnapshot(0, &first);
        path = try allocator.dupe(u8, prepared.path());
    }
    defer allocator.free(path);

    var loaded = try persistence.SessionFile.load(allocator, io, path, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.item_high_water);
    var resumed = try persistence.SessionFile.Log.resumeExisting(allocator, io, .{
        .path = path,
        .selection = .{},
        .loaded_item_count = loaded.item_high_water,
    });
    defer resumed.deinit();
    const owner = try Owner.create(allocator, &resumed, .{});
    defer owner.deinit();

    try loaded.session.appendCopy(&.{ .assistant_message = .{ .text = @constCast("second") } });
    try owner.seamHook().call(&loaded.session, .completion, false);
    try std.testing.expectEqual(@as(usize, 2), resumed.highWater());
}

test "hook maps allocation failure before lazy commit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var storage: [32 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    const log_allocator = fixed.allocator();
    var log = try testLog(log_allocator, io, root, .{});
    defer log.deinit();
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.appendCopy(&.{ .user_message = .{ .text = @constCast("item") } });
    const owner = try Owner.create(std.testing.allocator, &log, .{});
    defer owner.deinit();

    const remaining = storage.len - fixed.end_index;
    _ = try log_allocator.alloc(u8, remaining);
    try std.testing.expectError(
        error.OutOfMemory,
        owner.seamHook().call(&session, .completion, false),
    );
    try std.testing.expect(!log.materialized());
    try std.testing.expectEqual(@as(usize, 0), log.highWater());
}
