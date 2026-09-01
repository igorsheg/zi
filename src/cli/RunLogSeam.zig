//! Heap-stable composition of the advisory transcript and authoritative session log.
//!
//! Calls are synchronous, thread-confined, non-retaining, and non-reentrant.

const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const persistence = @import("../persistence/root.zig");
const tool = @import("../tool/root.zig");
const transcript = @import("../transcript/root.zig");
const SessionDurability = @import("../SessionDurability.zig");
const RunSelection = @import("RunSelection.zig");

/// Synchronous, infallible, and non-retaining. Implementations consume any
/// presentation failure internally.
pub const WarningSink = struct {
    context: *anyopaque,
    warn_fn: *const fn (*anyopaque, transcript.Warning) void,

    pub fn warn(self: WarningSink, warning: transcript.Warning) void {
        self.warn_fn(self.context, warning);
    }

    pub fn from(implementation: anytype) WarningSink {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("RunLogSeam.WarningSink.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn warn(context: *anyopaque, warning: transcript.Warning) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.warn(warning);
            }
        };
        return .{ .context = implementation, .warn_fn = Adapter.warn };
    }
};

/// Synchronously emits and clears a pending automatic-compaction marker only
/// after successful authoritative durability. Failure must leave it pending.
pub const Marker = struct {
    context: *anyopaque,
    emit_pending_fn: *const fn (*anyopaque) agent.Loop.HookError!void,

    pub fn emitPending(self: Marker) agent.Loop.HookError!void {
        return self.emit_pending_fn(self.context);
    }

    pub fn from(implementation: anytype) Marker {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
            @compileError("RunLogSeam.Marker.from expects a mutable single-item pointer");
        }
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn emitPending(context: *anyopaque) agent.Loop.HookError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.emitPending();
            }
        };
        return .{ .context = implementation, .emit_pending_fn = Adapter.emitPending };
    }
};

pub const Options = struct {
    marker: ?Marker = null,
    warning_sink: ?WarningSink = null,
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    selection: ?*RunSelection.Owner = null,
    transcript_owner: *transcript.Owner.Owner,
    durability: *SessionDurability.Owner,
    marker: ?Marker,
    warning_sink: ?WarningSink,
    active: bool = false,
    address: usize,

    /// Allocates only the stable seam owner. The transcript and durability
    /// owners remain borrowed and must outlive it.
    pub fn create(
        allocator: std.mem.Allocator,
        transcript_owner: *transcript.Owner.Owner,
        durability: *SessionDurability.Owner,
        options: Options,
    ) error{OutOfMemory}!*Owner {
        const self = try allocator.create(Owner);
        self.* = .{
            .allocator = allocator,
            .transcript_owner = transcript_owner,
            .durability = durability,
            .marker = options.marker,
            .warning_sink = options.warning_sink,
            .address = @intFromPtr(self),
        };
        return self;
    }

    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        self.assertStable();
        std.debug.assert(!self.active);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Binds the stable live selection exactly once. Rebinding, including to
    /// the same pointer, is a programmer bug.
    pub fn bindSelection(self: *Owner, selection: *RunSelection.Owner) void {
        self.assertStable();
        std.debug.assert(!self.active);
        if (self.selection != null) @panic("RunLogSeam RunSelection bound more than once");
        self.selection = selection;
    }

    pub fn seamHook(self: *Owner) agent.Loop.SeamHook {
        self.assertStable();
        return agent.Loop.SeamHook.from(self);
    }

    /// Manual compaction uses the same transcript and durability route without
    /// touching the automatic compaction marker.
    pub fn manualCompactionSeamHook(self: *Owner) agent.Loop.SeamHook {
        self.assertStable();
        return .{ .context = self, .call_fn = callManual };
    }

    fn callManual(
        context: *anyopaque,
        session: *const agent.Session.Session,
        kind: agent.Loop.SeamKind,
        next_action: bool,
    ) agent.Loop.HookError!agent.Loop.SeamDisposition {
        const self: *Owner = @ptrCast(@alignCast(context));
        self.enter();
        defer self.leave();
        const selection = self.selection orelse @panic("RunLogSeam used before binding RunSelection");
        const snapshot = selection.snapshot();
        return self.callView(session, kind, next_action, snapshot.system_prompt, snapshot.tools, false);
    }

    pub fn call(
        self: *Owner,
        session: *const agent.Session.Session,
        kind: agent.Loop.SeamKind,
        next_action: bool,
    ) agent.Loop.HookError!agent.Loop.SeamDisposition {
        self.enter();
        defer self.leave();
        const selection = self.selection orelse @panic("RunLogSeam used before binding RunSelection");
        const snapshot = selection.snapshot();
        return self.callView(
            session,
            kind,
            next_action,
            snapshot.system_prompt,
            snapshot.tools,
            true,
        );
    }

    /// Rebuilds only the advisory transcript. Lifecycle and selection callers
    /// invoke this after authoritative publication.
    pub fn rebuildTranscript(
        self: *Owner,
        operation: transcript.Operation,
        session: *const agent.Session.Session,
    ) void {
        self.enter();
        defer self.leave();
        const selection = self.selection orelse @panic("RunLogSeam used before binding RunSelection");
        const snapshot = selection.snapshot();
        self.rebuildView(operation, session, snapshot.system_prompt, snapshot.tools);
    }

    fn callView(
        self: *Owner,
        session: *const agent.Session.Session,
        kind: agent.Loop.SeamKind,
        next_action: bool,
        system_prompt: []const u8,
        tools: []const tool.Tool.Tool,
        emit_marker: bool,
    ) agent.Loop.HookError!agent.Loop.SeamDisposition {
        self.appendTranscript(session, system_prompt, tools);
        const disposition = try self.durability.call(session, kind, next_action);
        if (emit_marker and kind == .compaction) if (self.marker) |marker| try marker.emitPending();
        return disposition;
    }

    fn rebuildView(
        self: *Owner,
        operation: transcript.Operation,
        session: *const agent.Session.Session,
        system_prompt: []const u8,
        tools: []const tool.Tool.Tool,
    ) void {
        var definitions: [tool.Dispatch.default_maximum_tools]ai.Provider.ToolDefinition = undefined;
        const advertised = advertisedDefinitions(tools, &definitions);
        _ = self.transcript_owner.rebuild(operation, .{
            .system_prompt = system_prompt,
            .tools = advertised,
            .items = session.items(),
        });
        self.drainWarning();
    }

    fn appendTranscript(
        self: *Owner,
        session: *const agent.Session.Session,
        system_prompt: []const u8,
        tools: []const tool.Tool.Tool,
    ) void {
        var definitions: [tool.Dispatch.default_maximum_tools]ai.Provider.ToolDefinition = undefined;
        const advertised = advertisedDefinitions(tools, &definitions);
        _ = self.transcript_owner.append(.{
            .system_prompt = system_prompt,
            .tools = advertised,
            .items = session.items(),
        });
        self.drainWarning();
    }

    fn drainWarning(self: *Owner) void {
        const sink = self.warning_sink orelse return;
        const warning = self.transcript_owner.pendingWarning() orelse return;
        sink.warn(warning);
        self.transcript_owner.ackWarning();
    }

    fn enter(self: *Owner) void {
        self.assertStable();
        std.debug.assert(!self.active);
        self.active = true;
    }

    fn leave(self: *Owner) void {
        self.assertStable();
        std.debug.assert(self.active);
        self.active = false;
    }

    fn assertStable(self: *const Owner) void {
        std.debug.assert(self.address == @intFromPtr(self));
    }
};

/// The returned definitions borrow capability-owned schema data only until the
/// current synchronous transcript operation returns.
fn advertisedDefinitions(
    tools: []const tool.Tool.Tool,
    storage: *[tool.Dispatch.default_maximum_tools]ai.Provider.ToolDefinition,
) []const ai.Provider.ToolDefinition {
    std.debug.assert(tools.len <= storage.len);
    var count: usize = 0;
    for (tools) |handle| {
        if (handle.advertised()) |definition| {
            std.debug.assert(std.mem.eql(u8, definition.name, handle.definition.name));
            storage[count] = definition;
            count += 1;
        }
    }
    return storage[0..count];
}

const TestEvents = struct {
    bytes: [8]u8 = undefined,
    len: usize = 0,

    fn push(self: *TestEvents, byte: u8) void {
        self.bytes[self.len] = byte;
        self.len += 1;
    }
};

const TestWarningSink = struct {
    events: *TestEvents,
    calls: usize = 0,
    failure: ?transcript.Failure = null,
    sequence: u64 = 0,

    pub fn warn(self: *TestWarningSink, warning: transcript.Warning) void {
        self.events.push('W');
        self.calls += 1;
        self.failure = warning.failure;
        self.sequence = warning.sequence;
    }
};

const TestMarker = struct {
    events: *TestEvents,
    pending: bool = true,
    calls: usize = 0,

    pub fn emitPending(self: *TestMarker) agent.Loop.HookError!void {
        if (!self.pending) return;
        self.events.push('M');
        self.calls += 1;
        self.pending = false;
    }
};

const TestDurabilityObserver = struct {
    events: *TestEvents,

    pub fn observe(
        self: *TestDurabilityObserver,
        _: SessionDurability.Observation,
    ) SessionDurability.ObservationError!void {
        self.events.push('D');
    }
};

const FailingTranscriptOpen = struct {
    pub fn open(
        _: *FailingTranscriptOpen,
        _: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
    ) transcript.SecureOpen.Error!transcript.SecureOpen.Opened {
        return error.IoFailure;
    }
};

const MemoryTranscript = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    generation: i96 = 1,
    locked: bool = false,

    fn capability(self: *MemoryTranscript) transcript.SecureOpen.Capability {
        return .from(self);
    }

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

fn testLog(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
) !persistence.SessionFile.Log {
    return persistence.SessionFile.Log.prepare(allocator, io, .{
        .state_root = root,
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = [_]u8{
            0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
            0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
        },
        .writer_version = "test",
    });
}

fn failBeforeWrite(
    _: std.Io,
    _: std.Io.File,
    _: []const u8,
    _: u64,
) error{IoFailure}!void {
    return error.IoFailure;
}

fn mutable(bytes: []const u8) []u8 {
    return @constCast(bytes);
}

test "warning drains before mandatory durability and marker follows success" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var transcript_open: FailingTranscriptOpen = .{};
    const transcript_owner = try transcript.Owner.Owner.create(
        allocator,
        io,
        .from(&transcript_open),
        "transcript",
        .{},
    );
    defer transcript_owner.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root);
    var events: TestEvents = .{};
    var observer: TestDurabilityObserver = .{ .events = &events };
    const durability = try SessionDurability.Owner.create(
        allocator,
        &optional_log,
        .{ .observer = SessionDurability.Observer.from(&observer) },
    );
    defer durability.deinit();
    var warning_sink: TestWarningSink = .{ .events = &events };
    var marker: TestMarker = .{ .events = &events };
    const seam = try Owner.create(allocator, transcript_owner, durability, .{
        .marker = Marker.from(&marker),
        .warning_sink = WarningSink.from(&warning_sink),
    });
    defer seam.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.appendCopy(&.{ .assistant_message = .{ .text = mutable("answer") } });

    try std.testing.expectEqual(
        agent.Loop.SeamDisposition.synchronized,
        seam.callView(&session, .compaction, false, "system", &.{}, true),
    );
    try std.testing.expectEqualStrings("WDM", events.bytes[0..events.len]);
    try std.testing.expectEqual(@as(usize, 1), warning_sink.calls);
    try std.testing.expect(warning_sink.sequence != 0);
    try std.testing.expect(transcript_owner.pendingWarning() == null);
    try std.testing.expect(!marker.pending);
}

test "durability failure retains pending marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var transcript_open: FailingTranscriptOpen = .{};
    const transcript_owner = try transcript.Owner.Owner.create(allocator, io, .from(&transcript_open), null, .{});
    defer transcript_owner.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root);
    optional_log.?.commit_fn = failBeforeWrite;
    const durability = try SessionDurability.Owner.create(allocator, &optional_log, .{});
    defer durability.deinit();
    var events: TestEvents = .{};
    var marker: TestMarker = .{ .events = &events };
    const seam = try Owner.create(allocator, transcript_owner, durability, .{
        .marker = Marker.from(&marker),
    });
    defer seam.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.appendCopy(&.{ .assistant_message = .{ .text = mutable("answer") } });

    try std.testing.expectError(
        error.Failed,
        seam.callView(&session, .compaction, false, "system", &.{}, true),
    );
    try std.testing.expect(marker.pending);
    try std.testing.expectEqual(@as(usize, 0), marker.calls);
}

test "disabled transcript and unrecorded durability are exact no-ops" {
    const allocator = std.testing.allocator;
    var transcript_open: FailingTranscriptOpen = .{};
    const transcript_owner = try transcript.Owner.Owner.create(
        allocator,
        std.testing.io,
        .from(&transcript_open),
        null,
        .{},
    );
    defer transcript_owner.deinit();
    var no_log: ?persistence.SessionFile.Log = null;
    const durability = try SessionDurability.Owner.create(allocator, &no_log, .{});
    defer durability.deinit();
    var events: TestEvents = .{};
    var marker: TestMarker = .{ .events = &events };
    const seam = try Owner.create(allocator, transcript_owner, durability, .{
        .marker = Marker.from(&marker),
    });
    defer seam.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();

    try std.testing.expectEqual(
        agent.Loop.SeamDisposition.unrecorded,
        seam.callView(&session, .completion, false, "system", &.{}, true),
    );
    try std.testing.expect(transcript_owner.status() == .disabled);
    try std.testing.expectEqual(SessionDurability.State.unrecorded, durability.state(&session));

    try std.testing.expectEqual(
        agent.Loop.SeamDisposition.unrecorded,
        seam.callView(&session, .compaction, false, "system", &.{}, false),
    );
    try std.testing.expect(marker.pending);
    try std.testing.expectEqual(@as(usize, 0), marker.calls);
}

test "rebuild replaces the advisory transcript from current history" {
    const allocator = std.testing.allocator;
    var memory: MemoryTranscript = .{ .allocator = allocator };
    defer memory.deinit();
    const transcript_owner = try transcript.Owner.Owner.create(
        allocator,
        std.testing.io,
        memory.capability(),
        "transcript",
        .{},
    );
    defer transcript_owner.deinit();
    var no_log: ?persistence.SessionFile.Log = null;
    const durability = try SessionDurability.Owner.create(allocator, &no_log, .{});
    defer durability.deinit();
    const seam = try Owner.create(allocator, transcript_owner, durability, .{});
    defer seam.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.appendCopy(&.{ .assistant_message = .{ .text = mutable("rebuilt answer") } });

    seam.rebuildView(.selection, &session, "rebuilt system", &.{});
    try std.testing.expect(transcript_owner.status() == .clean);
    try std.testing.expect(std.mem.indexOf(u8, memory.bytes.items, "rebuilt system") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.bytes.items, "rebuilt answer") != null);
}
