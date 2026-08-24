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

    /// Stages the log selection, then changes the live session. If the second
    /// step fails, this restores the old log selection before returning the
    /// definite error. A failed rollback is returned as an explicit split.
    /// Selection records become durable with the next non-empty seam append.
    pub fn updateSelection(
        self: *Owner,
        session: *agent.Session.Session,
        requested: persistence.SessionFile.Selection,
    ) SelectionError!SelectionUpdate {
        const old_session = session.currentSelection();
        const old_log = self.log.currentSelection();
        if (!crossSelectionEqual(old_log, old_session)) return .{ .partial = .{
            .state = .preexisting_divergence,
            .failure = .indeterminate,
        } };

        const normalized = normalizeSelection(requested);
        if (crossSelectionEqual(normalized.log, old_session)) return .unchanged;

        self.log.setSelection(normalized.log) catch |err| return mapSelectionLogError(err);
        session.reconfigureSelection(normalized.session) catch |session_err| {
            self.log.setSelection(sessionToLog(old_session)) catch |rollback_err| return .{ .partial = .{
                .state = .log_only,
                .failure = classifyLogError(rollback_err),
            } };
            return mapSessionError(session_err);
        };
        return .updated;
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

fn sessionToLog(value: agent.Session.Selection) persistence.SessionFile.Selection {
    return .{
        .provider = value.provider_id,
        .model = value.model,
        .model_label = value.model_label,
        .effort = value.effort,
        .preset = value.preset,
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

fn classifyLogError(err: persistence.SessionFile.Error) FailureClass {
    return switch (mapLogError(err)) {
        error.OutOfMemory => .out_of_memory,
        error.Failed => .failed,
        error.Indeterminate => .indeterminate,
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

test "selection update handles same change rollback and preexisting divergence" {
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

    try std.testing.expectEqual(SelectionUpdate.unchanged, try owner.updateSelection(&session, original));
    const changed = try owner.updateSelection(&session, .{ .provider = "b", .model = "m2" });
    try std.testing.expectEqual(SelectionUpdate.updated, changed);
    try std.testing.expectEqualStrings("b", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("b", log.currentSelection().provider.?);

    // The log stages first. A deterministic session cap failure is rolled back.
    try std.testing.expectError(
        error.Failed,
        owner.updateSelection(&session, .{ .provider = "too-long", .model = "m2" }),
    );
    try std.testing.expectEqualStrings("b", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("b", log.currentSelection().provider.?);

    try log.setSelection(.{ .provider = "other", .model = "m2" });
    const partial = try owner.updateSelection(&session, .{ .provider = "c", .model = "m2" });
    try std.testing.expectEqual(PartialState.preexisting_divergence, partial.partial.state);
    try std.testing.expectEqual(FailureClass.indeterminate, partial.partial.failure);
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
