//! Owns the replaceable authoritative session log and routes the agent loop's
//! synchronous durability seam to the current authority.
//!
//! `Owner` is heap-stable because `agent.Loop.SeamHook` erases its address.
//! Stream seam calls are synchronous and serialized with adoption, selection,
//! reconciliation, quarantine, and destruction.

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

/// Synchronous callback. The callback must not retain its context or any data
/// borrowed from the durability owner.
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

pub const QuarantineReason = enum {
    external_change,
    removed,
    append_indeterminate,
    truncate_indeterminate,
    sync_failed,
    high_water_diverged,
};

pub const Authority = union(enum) {
    unrecorded,
    active: persistence.SessionFile.Log,
    quarantined: struct {
        log: persistence.SessionFile.Log,
        reason: QuarantineReason,
    },
};

pub const State = union(enum) {
    unrecorded,
    synchronized: usize,
    pending_append: struct {
        durable: usize,
        memory: usize,
    },
    quarantined: QuarantineReason,
};

pub const ReconcileFailure = enum {
    out_of_memory,
    serialization_failed,
    bounded_output,
    io_retryable,
};

pub const ReconcileOutcome = union(enum) {
    synchronized,
    unrecorded,
    retryable: ReconcileFailure,
    quarantined: QuarantineReason,
};

pub const TransitionSelectionFlush = union(enum) {
    synchronized,
    unrecorded,
    retryable: ReconcileFailure,
    quarantined: QuarantineReason,
};

/// A known split means the requested selection reached the log while the live
/// session retained its old selection. The prepared API avoids creating it.
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
    PendingAppend,
    Quarantined,
};

/// Move-only coordinated session and optional-log selection replacement.
pub const PreparedSelection = struct {
    owner: *Owner,
    generation: u64,
    session: agent.Session.PreparedSelection,
    log: ?persistence.SessionFile.PreparedSelection,
    changed: bool,
    active: bool = true,

    pub fn deinit(self: *PreparedSelection) void {
        if (self.active) {
            if (self.log) |*prepared| prepared.deinit();
            self.session.deinit();
        }
        self.* = undefined;
    }
};

/// Move-only session metadata update used only when a lifecycle transition is
/// abandoning authority that was already quarantined at command entry.
pub const PreparedQuarantinedTransitionSelection = struct {
    owner: *Owner,
    generation: u64,
    session: agent.Session.PreparedSelection,
    reason: QuarantineReason,
    active: bool = true,

    pub fn deinit(self: *PreparedQuarantinedTransitionSelection) void {
        if (self.active) self.session.deinit();
        self.* = undefined;
    }
};

/// Move-only session and optional-log selections displaced by publication.
pub const RetiredSelection = struct {
    session: agent.Session.RetiredSelection,
    log: ?persistence.SessionFile.RetiredSelection,
    active: bool = true,

    pub fn deinit(self: *RetiredSelection) void {
        if (self.active) {
            if (self.log) |*selection| selection.deinit();
            self.session.deinit();
        }
        self.* = undefined;
    }
};

/// Move-only old-branch settlement selection. Deinit keeps the old selection live;
/// restore puts the published selection back and leaves the token owning the old one.
pub const TransitionSelection = struct {
    owner: *Owner,
    generation: u64,
    log: ?persistence.SessionFile.TransitionSelection,
    restored: bool = false,
    active: bool = true,

    pub fn restore(self: *TransitionSelection) void {
        std.debug.assert(self.active);
        std.debug.assert(!self.restored);
        if (self.log) |*selection| switch (self.owner.authority) {
            .active => |*log| log.restoreTransitionSelection(selection),
            .quarantined => |*value| value.log.restoreTransitionSelection(selection),
            .unrecorded => unreachable,
        };
        self.owner.generation +%= 1;
        self.generation = self.owner.generation;
        self.restored = true;
    }

    pub fn deinit(self: *TransitionSelection) void {
        if (self.active) if (self.log) |*selection| selection.deinit();
        self.* = undefined;
    }
};

/// Move-only prospective authority. Preparation consumes `replacement` on
/// success by setting it to null.
pub const PreparedAdoption = struct {
    owner: *Owner,
    generation: u64,
    replacement: ?persistence.SessionFile.Log,
    active: bool = true,

    pub fn deinit(self: *PreparedAdoption) void {
        if (self.active) if (self.replacement) |*log| log.deinit();
        self.* = undefined;
    }
};

/// Move-only authority displaced by publication.
pub const RetiredAuthority = struct {
    authority: Authority,
    active: bool = true,

    pub fn deinit(self: *RetiredAuthority) void {
        if (self.active) deinitAuthority(&self.authority);
        self.* = undefined;
    }
};

pub const PrepareCutError = error{
    OutOfMemory,
    InvalidPlan,
    FileTooLarge,
    LineTooLarge,
    TooManyItems,
    Failed,
    PendingAppend,
    Quarantined,
    Mismatch,
};

/// Move-only durability half of an undo cut. It never exposes the active Log.
pub const PreparedCut = struct {
    owner: *Owner,
    generation: u64,
    session: *agent.Session.Session,
    session_generation: u64,
    original_items: usize,
    retained_items: usize,
    original_typed_turns: usize,
    retained_typed_turns: usize,
    disk: ?persistence.SessionFile.PreparedCut,
    active: bool = true,

    pub fn deinit(self: *PreparedCut) void {
        if (self.active) if (self.disk) |*disk| disk.deinit();
        self.* = undefined;
    }
};

/// Must be finished after matching memory publication. Deinit also applies the
/// required quarantine, so a committed sync failure cannot resume appending.
pub const CutCommit = struct {
    owner: *Owner,
    generation: u64,
    session: *const agent.Session.Session,
    durability: persistence.SessionFile.MutationDurability,
    retained_items: usize,
    active: bool = true,

    pub fn finish(self: *CutCommit) void {
        std.debug.assert(self.active);
        std.debug.assert(self.owner.generation == self.generation);
        std.debug.assert(self.session.items().len == self.retained_items);
        if (self.durability == .sync_failed) self.owner.quarantine(.sync_failed);
        self.active = false;
    }

    pub fn deinit(self: *CutCommit) void {
        if (self.active) self.finish();
        self.* = undefined;
    }
};

pub const CutOutcome = union(enum) {
    unchanged: persistence.SessionFile.TruncateUnchanged,
    committed: CutCommit,
    indeterminate: persistence.SessionFile.TruncateIndeterminate,
};

pub const ExecuteCutError = error{
    InvalidPlan,
    StaleCut,
    HighWaterMismatch,
    Failed,
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    authority: Authority,
    observer: ?Observer,
    generation: u64 = 0,

    /// Creates the mandatory stable owner. On success this consumes `log` and
    /// sets `log.*` to null. On failure the caller retains it unchanged.
    pub fn create(
        allocator: std.mem.Allocator,
        log: *?persistence.SessionFile.Log,
        options: Options,
    ) CreateError!*Owner {
        const self = try allocator.create(Owner);
        self.* = .{
            .allocator = allocator,
            .authority = if (log.*) |value| .{ .active = value } else .unrecorded,
            .observer = options.observer,
        };
        log.* = null;
        return self;
    }

    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        const allocator = self.allocator;
        deinitAuthority(&self.authority);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn state(self: *const Owner, session: *const agent.Session.Session) State {
        const memory = session.items().len;
        return switch (self.authority) {
            .unrecorded => .unrecorded,
            .quarantined => |value| .{ .quarantined = value.reason },
            .active => |*log| if (log.hasPendingSelection())
                .{ .pending_append = .{ .durable = log.highWater(), .memory = memory } }
            else
                stateFromCounts(log.highWater(), memory),
        };
    }

    pub fn activePath(self: *const Owner) ?[]const u8 {
        return switch (self.authority) {
            .unrecorded => null,
            .active => |*log| log.path(),
            .quarantined => |*value| value.log.path(),
        };
    }

    pub fn materialized(self: *const Owner) bool {
        return switch (self.authority) {
            .unrecorded => false,
            .active => |*log| log.materialized(),
            .quarantined => |*value| value.log.materialized(),
        };
    }

    pub fn resumeHint(self: *const Owner) ?[]const u8 {
        return switch (self.authority) {
            .unrecorded => null,
            .active => |*log| log.resumeHint(),
            .quarantined => |*value| value.log.resumeHint(),
        };
    }

    pub fn generationValue(self: *const Owner) u64 {
        return self.generation;
    }

    pub fn seamHook(self: *Owner) agent.Loop.SeamHook {
        return agent.Loop.SeamHook.from(self);
    }

    pub fn call(
        self: *Owner,
        session: *const agent.Session.Session,
        kind: agent.Loop.SeamKind,
        next_action: bool,
    ) agent.Loop.HookError!agent.Loop.SeamDisposition {
        switch (self.authority) {
            .unrecorded => return .unrecorded,
            .quarantined => return error.Indeterminate,
            .active => {},
        }

        const items = session.items();
        const durable = self.activeLog().highWater();
        if (items.len < durable) {
            self.quarantine(.high_water_diverged);
            return error.Indeterminate;
        }
        if (items.len == durable and !self.activeLog().hasPendingSelection()) return .synchronized;

        const outcome = self.activeLog().appendSnapshotClassified(durable, items) catch |err| {
            const classification = classifyAppendError(err);
            return switch (classification) {
                .retryable => |failure| mapReconcileFailure(failure),
                .quarantined => |reason| blk: {
                    self.quarantine(reason);
                    break :blk error.Indeterminate;
                },
            };
        };
        switch (outcome) {
            .unchanged => return error.Failed,
            .indeterminate => {
                self.quarantine(.append_indeterminate);
                return error.Indeterminate;
            },
            .committed => |durability| {
                if (durability == .sync_failed) {
                    self.quarantine(.sync_failed);
                    return error.Indeterminate;
                }
                self.generation +%= 1;
            },
        }
        if (self.observer) |observer| {
            observer.observe(.{
                .kind = kind,
                .next_action = next_action,
                .high_water = items.len,
            }) catch |err| return mapObservationError(err);
        }
        return .synchronized;
    }

    /// Retries an outstanding append. Quarantine is sticky until adoption or
    /// destruction, and an unrecorded conversation is an exact no-op.
    pub fn reconcile(
        self: *Owner,
        session: *const agent.Session.Session,
    ) ReconcileOutcome {
        switch (self.authority) {
            .unrecorded => return .unrecorded,
            .quarantined => |value| return .{ .quarantined = value.reason },
            .active => {},
        }

        const items = session.items();
        const durable = self.activeLog().highWater();
        if (items.len < durable) {
            self.quarantine(.high_water_diverged);
            return .{ .quarantined = .high_water_diverged };
        }
        if (items.len == durable and !self.activeLog().hasPendingSelection()) return .synchronized;

        const outcome = self.activeLog().appendSnapshotClassified(durable, items) catch |err| {
            return switch (classifyAppendError(err)) {
                .retryable => |failure| .{ .retryable = failure },
                .quarantined => |reason| blk: {
                    self.quarantine(reason);
                    break :blk .{ .quarantined = reason };
                },
            };
        };
        return switch (outcome) {
            .unchanged => .{ .retryable = .io_retryable },
            .indeterminate => blk: {
                self.quarantine(.append_indeterminate);
                break :blk .{ .quarantined = .append_indeterminate };
            },
            .committed => |durability| blk: {
                if (durability == .sync_failed) {
                    self.quarantine(.sync_failed);
                    break :blk .{ .quarantined = .sync_failed };
                }
                self.generation +%= 1;
                break :blk .synchronized;
            },
        };
    }

    /// Prepares disk agreement for an already-prepared in-memory undo cut.
    pub fn prepareCut(
        self: *Owner,
        session: *agent.Session.Session,
        memory: *const agent.Session.PreparedCut,
    ) PrepareCutError!PreparedCut {
        if (!memory.active or memory.owner != session or
            memory.generation != session.historyGeneration() or
            memory.original_items != session.items().len or
            memory.original_typed_turns != session.typedTurnCount())
        {
            return error.InvalidPlan;
        }
        const no_disk = switch (self.authority) {
            .unrecorded => true,
            .quarantined => return error.Quarantined,
            .active => |*log| !log.materialized(),
        };
        if (no_disk) return .{
            .owner = self,
            .generation = self.generation,
            .session = session,
            .session_generation = memory.generation,
            .original_items = memory.original_items,
            .retained_items = memory.retained_items,
            .original_typed_turns = memory.original_typed_turns,
            .retained_typed_turns = memory.retained_typed_turns,
            .disk = null,
        };
        switch (self.state(session)) {
            .pending_append => return error.PendingAppend,
            .quarantined => return error.Quarantined,
            .unrecorded => unreachable,
            .synchronized => {},
        }
        const log = self.activeLog();
        var disk = log.prepareCut(memory.retained_typed_turns) catch |err| switch (err) {
            error.Removed => {
                self.quarantine(.removed);
                return error.Quarantined;
            },
            error.Poisoned, error.InvalidPlan, error.IoFailure, error.NotRegular => {
                self.quarantine(.external_change);
                return error.Quarantined;
            },
            else => return mapPrepareCutError(err),
        };
        errdefer disk.deinit();
        if (disk.plan.original_typed_turns != memory.original_typed_turns or
            disk.plan.retained_typed_turns != memory.retained_typed_turns or
            disk.plan.retained_item_records != memory.retained_items)
        {
            return error.Mismatch;
        }
        return .{
            .owner = self,
            .generation = self.generation,
            .session = session,
            .session_generation = memory.generation,
            .original_items = memory.original_items,
            .retained_items = memory.retained_items,
            .original_typed_turns = memory.original_typed_turns,
            .retained_typed_turns = memory.retained_typed_turns,
            .disk = disk,
        };
    }

    /// Executes the classified file mutation before the caller publishes memory.
    pub fn executeCut(self: *Owner, prepared: *PreparedCut) ExecuteCutError!CutOutcome {
        if (!prepared.active or prepared.owner != self or prepared.generation != self.generation or
            prepared.session.historyGeneration() != prepared.session_generation or
            prepared.session.items().len != prepared.original_items or
            prepared.session.typedTurnCount() != prepared.original_typed_turns)
        {
            return error.StaleCut;
        }
        if (prepared.disk == null) {
            prepared.active = false;
            self.generation +%= 1;
            return .{ .committed = .{
                .owner = self,
                .generation = self.generation,
                .session = prepared.session,
                .durability = .synced,
                .retained_items = prepared.retained_items,
            } };
        }
        const outcome = self.activeLog().truncatePrepared(
            &prepared.disk.?,
            prepared.retained_items,
        ) catch |err| {
            switch (err) {
                error.Removed => self.quarantine(.removed),
                error.HighWaterMismatch => self.quarantine(.high_water_diverged),
                error.InvalidPlan, error.Poisoned, error.IoFailure, error.NotRegular => {
                    self.quarantine(.external_change);
                },
                error.OutOfMemory,
                error.FileTooLarge,
                error.LineTooLarge,
                error.TooManyItems,
                error.StaleCut,
                => {},
            }
            return mapExecuteCutError(err);
        };
        prepared.active = false;
        return switch (outcome) {
            .unchanged => |reason| .{ .unchanged = reason },
            .committed => |value| blk: {
                self.generation +%= 1;
                break :blk .{ .committed = .{
                    .owner = self,
                    .generation = self.generation,
                    .session = prepared.session,
                    .durability = value.durability,
                    .retained_items = value.retained_items,
                } };
            },
            .indeterminate => |reason| blk: {
                self.quarantine(.truncate_indeterminate);
                break :blk .{ .indeterminate = reason };
            },
        };
    }

    /// Consumes `replacement` into a generation-bound adoption candidate.
    pub fn prepareAdoption(
        self: *Owner,
        replacement: *?persistence.SessionFile.Log,
    ) error{StaleGeneration}!PreparedAdoption {
        const prepared: PreparedAdoption = .{
            .owner = self,
            .generation = self.generation,
            .replacement = replacement.*,
        };
        replacement.* = null;
        return prepared;
    }

    /// Installs a prepared authority without allocation and returns ownership
    /// of the displaced authority.
    pub fn publishAdoption(
        self: *Owner,
        prepared: *PreparedAdoption,
    ) RetiredAuthority {
        std.debug.assert(prepared.active);
        std.debug.assert(prepared.owner == self);
        std.debug.assert(prepared.generation == self.generation);
        const retired: RetiredAuthority = .{ .authority = self.authority };
        self.authority = if (prepared.replacement) |log| .{ .active = log } else .unrecorded;
        prepared.replacement = null;
        prepared.active = false;
        self.generation +%= 1;
        return retired;
    }

    /// Runs after coordinated resume publication. On failure, closes the
    /// selected log and leaves a genuine unrecorded authority so turns continue.
    pub fn tightenResumedAuthority(self: *Owner) bool {
        switch (self.authority) {
            .unrecorded => return true,
            .quarantined => return false,
            .active => |*log| log.tightenPrivate() catch {
                var dropped = log.*;
                self.authority = .unrecorded;
                self.generation +%= 1;
                dropped.deinit();
                return false;
            },
        }
        return true;
    }

    /// Quarantine keeps the logger and its lifetime lock owned until adoption
    /// or shutdown. The first reason is retained.
    pub fn quarantine(self: *Owner, reason: QuarantineReason) void {
        switch (self.authority) {
            .unrecorded, .quarantined => return,
            .active => |log| self.authority = .{ .quarantined = .{
                .log = log,
                .reason = reason,
            } },
        }
        self.generation +%= 1;
    }

    /// Stages a session selection and, when active, the matching log
    /// selection. Unrecorded owners stage only the session. Quarantine rejects
    /// ordinary selection preparation.
    pub fn prepareSelection(
        self: *Owner,
        session: *agent.Session.Session,
        requested: persistence.SessionFile.Selection,
    ) PrepareSelectionError!PreparedSelection {
        switch (self.state(session)) {
            .unrecorded, .synchronized => {},
            .pending_append => return error.PendingAppend,
            .quarantined => |reason| {
                self.quarantine(reason);
                return error.Quarantined;
            },
        }
        const normalized = normalizeSelection(requested);
        const old_session = session.currentSelection();

        var session_prepared = session.prepareSelection(normalized.session) catch |err|
            return mapSessionError(err);
        errdefer session_prepared.deinit();

        var log_prepared: ?persistence.SessionFile.PreparedSelection = null;
        errdefer if (log_prepared) |*prepared| prepared.deinit();
        switch (self.authority) {
            .unrecorded => {},
            .quarantined => unreachable,
            .active => |*log| {
                if (!crossSelectionEqual(log.currentSelection(), old_session)) return error.Diverged;
                log_prepared = log.prepareSelection(normalized.log) catch |err|
                    return mapSelectionLogError(err);
            },
        }
        return .{
            .owner = self,
            .generation = self.generation,
            .session = session_prepared,
            .log = log_prepared,
            .changed = !crossSelectionEqual(normalized.log, old_session),
        };
    }

    /// Stages only stable in-memory session metadata for a lifecycle transition
    /// that entered with quarantined authority. Ordinary selection must use
    /// prepareSelection and therefore continues to reject quarantine.
    pub fn prepareSelectionForQuarantinedTransition(
        self: *Owner,
        session: *agent.Session.Session,
        requested: persistence.SessionFile.Selection,
    ) PrepareSelectionError!PreparedQuarantinedTransitionSelection {
        const reason = switch (self.state(session)) {
            .quarantined => |value| value,
            .unrecorded, .synchronized, .pending_append => return error.Quarantined,
        };
        const normalized = normalizeSelection(requested);
        return .{
            .owner = self,
            .generation = self.generation,
            .session = session.prepareSelection(normalized.session) catch |err| return mapSessionError(err),
            .reason = reason,
        };
    }

    /// Publishes the narrowly scoped quarantined-transition metadata update
    /// without allocating or freeing. The unusable log remains unchanged.
    pub fn publishSelectionForQuarantinedTransitionRetired(
        self: *Owner,
        session: *agent.Session.Session,
        prepared: *PreparedQuarantinedTransitionSelection,
    ) RetiredSelection {
        std.debug.assert(prepared.active);
        std.debug.assert(prepared.owner == self);
        std.debug.assert(prepared.generation == self.generation);
        switch (self.authority) {
            .quarantined => |value| std.debug.assert(value.reason == prepared.reason),
            .unrecorded, .active => unreachable,
        }
        const retired_session = session.publishSelectionRetired(&prepared.session);
        prepared.active = false;
        self.generation +%= 1;
        return .{ .session = retired_session, .log = null };
    }

    pub fn publishSelectionForQuarantinedTransition(
        self: *Owner,
        session: *agent.Session.Session,
        prepared: *PreparedQuarantinedTransitionSelection,
    ) void {
        var retired = self.publishSelectionForQuarantinedTransitionRetired(session, prepared);
        retired.deinit();
    }

    /// Publishes a coordinated replacement without allocating or freeing.
    pub fn publishSelectionRetired(
        self: *Owner,
        session: *agent.Session.Session,
        prepared: *PreparedSelection,
    ) RetiredSelection {
        std.debug.assert(prepared.active);
        std.debug.assert(prepared.owner == self);
        std.debug.assert(prepared.generation == self.generation);
        const retired_log: ?persistence.SessionFile.RetiredSelection = switch (self.authority) {
            .unrecorded => blk: {
                std.debug.assert(prepared.log == null);
                break :blk null;
            },
            .active => |*log| blk: {
                std.debug.assert(prepared.log != null);
                break :blk log.publishSelectionRetired(&prepared.log.?);
            },
            .quarantined => unreachable,
        };
        const retired_session = session.publishSelectionRetired(&prepared.session);
        prepared.active = false;
        self.generation +%= 1;
        return .{ .session = retired_session, .log = retired_log };
    }

    pub fn publishSelection(
        self: *Owner,
        session: *agent.Session.Session,
        prepared: *PreparedSelection,
    ) void {
        var retired = self.publishSelectionRetired(session, prepared);
        retired.deinit();
    }

    /// Moves retired old-log metadata back into the active log before task settlement.
    pub fn beginTransitionSelection(self: *Owner, retired: *RetiredSelection) TransitionSelection {
        const log_selection: ?persistence.SessionFile.TransitionSelection = switch (self.authority) {
            .active => |*log| if (retired.log) |*selection| log.beginTransitionSelection(selection) else null,
            .unrecorded => null,
            .quarantined => unreachable,
        };
        self.generation +%= 1;
        return .{
            .owner = self,
            .generation = self.generation,
            .log = log_selection,
        };
    }

    /// Flushes only a restored transition selection. Item high-water may already match.
    pub fn flushRestoredTransitionSelection(
        self: *Owner,
        session: *const agent.Session.Session,
    ) TransitionSelectionFlush {
        switch (self.authority) {
            .unrecorded => return .unrecorded,
            .quarantined => |value| return .{ .quarantined = value.reason },
            .active => {},
        }
        const items = session.items();
        const log = self.activeLog();
        const durable = log.highWater();
        if (items.len < durable) {
            self.quarantine(.high_water_diverged);
            return .{ .quarantined = .high_water_diverged };
        }
        if (!log.hasPendingSelection()) return .synchronized;
        const outcome = log.appendSnapshotClassified(durable, items) catch |err| {
            return switch (classifyAppendError(err)) {
                .retryable => |failure| .{ .retryable = failure },
                .quarantined => |reason| blk: {
                    self.quarantine(reason);
                    break :blk .{ .quarantined = reason };
                },
            };
        };
        return switch (outcome) {
            .unchanged => .{ .retryable = .io_retryable },
            .indeterminate => blk: {
                self.quarantine(.append_indeterminate);
                break :blk .{ .quarantined = .append_indeterminate };
            },
            .committed => |durability| blk: {
                if (durability == .sync_failed) {
                    self.quarantine(.sync_failed);
                    break :blk .{ .quarantined = .sync_failed };
                }
                self.generation +%= 1;
                break :blk .synchronized;
            },
        };
    }

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
            error.Quarantined => return error.Indeterminate,
            error.PendingAppend => return error.Failed,
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => return error.Failed,
            error.Indeterminate => return error.Indeterminate,
        };
        defer prepared.deinit();
        const changed = prepared.changed;
        self.publishSelection(session, &prepared);
        return if (changed) .updated else .unchanged;
    }

    fn activeLog(self: *Owner) *persistence.SessionFile.Log {
        return switch (self.authority) {
            .active => |*log| log,
            .unrecorded, .quarantined => unreachable,
        };
    }
};

fn mapPrepareCutError(err: persistence.SessionFile.CutError) PrepareCutError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPlan => error.InvalidPlan,
        error.FileTooLarge => error.FileTooLarge,
        error.LineTooLarge => error.LineTooLarge,
        error.TooManyItems => error.TooManyItems,
        error.Poisoned, error.IoFailure, error.NotRegular, error.Removed => error.Failed,
    };
}

fn mapExecuteCutError(err: persistence.SessionFile.TruncateError) ExecuteCutError {
    return switch (err) {
        error.StaleCut => error.StaleCut,
        error.HighWaterMismatch => error.HighWaterMismatch,
        error.InvalidPlan => error.InvalidPlan,
        else => error.Failed,
    };
}

const AppendErrorClass = union(enum) {
    retryable: ReconcileFailure,
    quarantined: QuarantineReason,
};

fn classifyAppendError(err: persistence.SessionFile.AppendError) AppendErrorClass {
    return switch (err) {
        error.OutOfMemory => .{ .retryable = .out_of_memory },
        error.InvalidSelection, error.InvalidHeader => .{ .retryable = .serialization_failed },
        error.FileTooLarge, error.LineTooLarge, error.TooManyItems => .{ .retryable = .bounded_output },
        error.InvalidPath, error.Cancelled, error.IoFailure => .{ .retryable = .io_retryable },
        error.HighWaterMismatch => .{ .quarantined = .high_water_diverged },
        error.Removed => .{ .quarantined = .removed },
        error.Poisoned, error.NotRegular => .{ .quarantined = .external_change },
    };
}

fn mapReconcileFailure(failure: ReconcileFailure) agent.Loop.HookError {
    return switch (failure) {
        .out_of_memory => error.OutOfMemory,
        .serialization_failed, .bounded_output, .io_retryable => error.Failed,
    };
}

fn mapObservationError(err: ObservationError) agent.Loop.HookError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.Failed,
        error.Indeterminate => error.Indeterminate,
    };
}

fn deinitAuthority(authority: *Authority) void {
    switch (authority.*) {
        .unrecorded => {},
        .active => |*log| log.deinit(),
        .quarantined => |*value| value.log.deinit(),
    }
}

fn stateFromCounts(durable: usize, memory: usize) State {
    if (memory < durable) return .{ .quarantined = .high_water_diverged };
    if (memory == durable) return .{ .synchronized = durable };
    return .{ .pending_append = .{ .durable = durable, .memory = memory } };
}

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

fn mapSelectionLogError(err: persistence.SessionFile.Error) SelectionError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Poisoned, error.Removed, error.IoFailure, error.IndeterminateCleanup => error.Indeterminate,
        else => error.Failed,
    };
}

fn mapSessionError(err: agent.Session.Error) SelectionError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
}

const TestRecorder = struct {
    values: [4]Observation = undefined,
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

fn failBeforeWrite(
    _: std.Io,
    _: std.Io.File,
    _: []const u8,
    _: u64,
) error{IoFailure}!void {
    return error.IoFailure;
}

fn commitWrite(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    offset: u64,
) error{IoFailure}!void {
    file.writePositionalAll(io, bytes, offset) catch return error.IoFailure;
}

fn writePrefixThenFail(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    offset: u64,
) error{IoFailure}!void {
    const prefix_len = @max(@as(usize, 1), bytes.len / 2);
    file.writePositionalAll(io, bytes[0..prefix_len], offset) catch return error.IoFailure;
    return error.IoFailure;
}

fn failSync(_: std.Io, _: std.Io.File) error{IoFailure}!void {
    return error.IoFailure;
}

fn failPermissions(_: std.Io, _: std.Io.File) error{IoFailure}!void {
    return error.IoFailure;
}

const FreeObserver = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,

    fn allocator(self: *FreeObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FreeObserver = @ptrCast(@alignCast(context));
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
        const self: *FreeObserver = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *FreeObserver = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *FreeObserver = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "owner consumes optional authority and owns unrecorded state" {
    const allocator = std.testing.allocator;
    var none: ?persistence.SessionFile.Log = null;
    const owner = try Owner.create(allocator, &none, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();

    try std.testing.expect(none == null);
    try std.testing.expectEqual(State.unrecorded, owner.state(&session));
    try std.testing.expect(owner.activePath() == null);
    try std.testing.expect(!owner.materialized());
    try std.testing.expect(owner.resumeHint() == null);
    try std.testing.expectEqual(ReconcileOutcome.unrecorded, owner.reconcile(&session));
    try std.testing.expectEqual(
        agent.Loop.SeamDisposition.unrecorded,
        owner.seamHook().call(&session, .completion, false),
    );
}

test "create allocation failure leaves optional log with caller" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{});
    defer if (optional_log) |*log| log.deinit();
    var storage: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    try std.testing.expectError(error.OutOfMemory, Owner.create(fixed.allocator(), &optional_log, .{}));
    try std.testing.expect(optional_log != null);
}

test "active seam exposes pending state then synchronizes through classified append" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{});
    var recorder: TestRecorder = .{};
    const owner = try Owner.create(allocator, &optional_log, .{ .observer = Observer.from(&recorder) });
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.appendCopy(&.{ .user_message = .{ .text = @constCast("one") } });

    const pending = owner.state(&session).pending_append;
    try std.testing.expectEqual(@as(usize, 0), pending.durable);
    try std.testing.expectError(error.PendingAppend, owner.prepareSelection(&session, .{}));
    try std.testing.expectEqual(@as(usize, 1), pending.memory);
    try std.testing.expectEqual(
        agent.Loop.SeamDisposition.synchronized,
        owner.seamHook().call(&session, .completion, true),
    );
    try std.testing.expectEqual(@as(u64, 1), owner.generationValue());
    try std.testing.expectEqual(@as(usize, 1), owner.state(&session).synchronized);
    try std.testing.expect(owner.materialized());
    try std.testing.expectEqual(@as(usize, 1), recorder.length);
    try std.testing.expectEqual(agent.Loop.SeamKind.completion, recorder.values[0].kind);
    try std.testing.expect(recorder.values[0].next_action);
}

test "reconcile keeps proven unchanged retryable and quarantines sync failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{});
    optional_log.?.commit_fn = failBeforeWrite;
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.appendCopy(&.{ .user_message = .{ .text = @constCast("one") } });

    const retry = owner.reconcile(&session);
    try std.testing.expectEqual(ReconcileFailure.io_retryable, retry.retryable);
    try std.testing.expectEqual(@as(usize, 0), owner.state(&session).pending_append.durable);

    owner.activeLog().commit_fn = commitWrite;
    owner.activeLog().append_sync_file_fn = failSync;
    const quarantined = owner.reconcile(&session);
    try std.testing.expectEqual(QuarantineReason.sync_failed, quarantined.quarantined);
    try std.testing.expectEqual(QuarantineReason.sync_failed, owner.state(&session).quarantined);
    try std.testing.expectError(error.Indeterminate, owner.seamHook().call(&session, .completion, false));
}

test "indeterminate append quarantines and retains the owned log" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{});
    optional_log.?.commit_fn = writePrefixThenFail;
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.appendCopy(&.{ .user_message = .{ .text = @constCast("one") } });

    const outcome = owner.reconcile(&session);
    try std.testing.expectEqual(QuarantineReason.append_indeterminate, outcome.quarantined);
    try std.testing.expectEqual(QuarantineReason.append_indeterminate, owner.state(&session).quarantined);
    try std.testing.expect(owner.activePath() != null);
    try std.testing.expectEqual(@as(u64, 1), owner.generationValue());
}

test "memory behind high water quarantines without appending" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var log = try testLog(allocator, io, root, .{});
    const item = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("persisted") } },
    };
    try log.appendSnapshot(0, &item);
    var optional_log: ?persistence.SessionFile.Log = log;
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();

    try std.testing.expectEqual(QuarantineReason.high_water_diverged, owner.state(&session).quarantined);
    try std.testing.expectError(error.Quarantined, owner.prepareSelection(&session, .{}));
    try std.testing.expectEqual(QuarantineReason.high_water_diverged, owner.state(&session).quarantined);
    const outcome = owner.reconcile(&session);
    try std.testing.expectEqual(QuarantineReason.high_water_diverged, outcome.quarantined);
    try std.testing.expectEqual(@as(u64, 1), owner.generationValue());
}

test "failed resumed privacy verification drops authority after commit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/resume.jsonl", .{root});
    defer allocator.free(path);
    const fixture =
        "{\"type\":\"session\",\"version\":1}\n" ++
        "{\"kind\":\"user\",\"text\":\"kept\"}\n";
    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    try file.writeStreamingAll(io, fixture);
    file.close(io);

    var resumed = try persistence.SessionFile.loadLockedForResume(allocator, io, path, .{});
    defer resumed.loaded.deinit();
    var log: ?persistence.SessionFile.Log = resumed.log;
    const owner = try Owner.create(allocator, &log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    const item: ai.Item.Item = .{ .user_message = .{ .text = @constCast("kept") } };
    try session.appendCopy(&item);
    owner.activeLog().set_permissions_fn = failPermissions;

    try std.testing.expect(!owner.tightenResumedAuthority());
    try std.testing.expectEqual(State.unrecorded, owner.state(&session));
    try std.testing.expect(owner.activePath() == null);
    _ = try owner.seamHook().call(&session, .completion, false);

    const reopened = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer reopened.close(io);
    try std.testing.expect(try reopened.tryLock(io, .exclusive));
    reopened.unlock(io);
}

test "adoption replaces quarantine and retires the held authority" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var first: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{});
    const owner = try Owner.create(allocator, &first, .{});
    defer owner.deinit();
    owner.quarantine(.external_change);
    const generation = owner.generationValue();

    var replacement: ?persistence.SessionFile.Log = null;
    var prepared = try owner.prepareAdoption(&replacement);
    defer prepared.deinit();
    var retired = owner.publishAdoption(&prepared);
    defer retired.deinit();

    try std.testing.expect(replacement == null);
    try std.testing.expectEqual(generation +% 1, owner.generationValue());
    try std.testing.expect(owner.activePath() == null);
    try std.testing.expect(retired.authority == .quarantined);
}

test "active selection preparation coordinates log and session and detects divergence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{
        .provider = "old",
        .model = "model",
    });
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{
        .provider_id = "old",
        .model = "model",
    });
    defer session.deinit();

    var dropped = try owner.prepareSelection(&session, .{ .provider = "new", .model = "next" });
    dropped.deinit();
    try std.testing.expectEqualStrings("old", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("old", owner.activeLog().currentSelection().provider.?);

    var prepared = try owner.prepareSelection(&session, .{ .provider = "new", .model = "next" });
    defer prepared.deinit();
    try std.testing.expect(prepared.log != null);
    owner.publishSelection(&session, &prepared);
    try std.testing.expectEqualStrings("new", session.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("new", owner.activeLog().currentSelection().provider.?);

    try owner.activeLog().setSelection(.{ .provider = "other", .model = "next" });
    try std.testing.expectError(
        error.Diverged,
        owner.prepareSelection(&session, .{ .provider = "third", .model = "next" }),
    );
}

test "retired coordinated publication defers all ten selection frees" {
    var observer: FreeObserver = .{ .backing = std.testing.allocator };
    const allocator = observer.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const old: persistence.SessionFile.Selection = .{
        .provider = "old-provider",
        .model = "old-model",
        .model_label = "old-label",
        .effort = "old-effort",
        .preset = "old-preset",
    };
    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, std.testing.io, root, old);
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{
        .provider_id = old.provider,
        .model = old.model,
        .model_label = old.model_label,
        .effort = old.effort,
        .preset = old.preset,
    });
    defer session.deinit();
    var prepared = try owner.prepareSelection(&session, .{
        .provider = "new-provider",
        .model = "new-model",
        .model_label = "new-label",
        .effort = "new-effort",
        .preset = "new-preset",
    });

    const frees_before = observer.frees;
    var retired = owner.publishSelectionRetired(&session, &prepared);
    try std.testing.expectEqual(frees_before, observer.frees);
    retired.deinit();
    try std.testing.expectEqual(frees_before + 10, observer.frees);
}

test "lazy old log task note materializes with old selection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{
        .provider = "old",
        .model = "old-model",
    });
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{
        .provider_id = "old",
        .model = "old-model",
    });
    defer session.deinit();

    var prepared = try owner.prepareSelection(&session, .{
        .provider = "new",
        .model = "new-model",
        .preset = "review",
    });
    var retired = owner.publishSelectionRetired(&session, &prepared);
    var transition = owner.beginTransitionSelection(&retired);
    retired.deinit();
    defer transition.deinit();
    try session.addTaskNote("[task t1 killed at exit]");
    _ = try owner.seamHook().call(&session, .task_note, false);

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, owner.activePath().?, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "task_note") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"provider\":\"old\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"preset\":\"review\"") == null);
}

test "materialized old log omits published preset selection after settlement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{
        .provider = "old",
        .model = "old-model",
    });
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{
        .provider_id = "old",
        .model = "old-model",
    });
    defer session.deinit();
    try session.addUser("old conversation");
    _ = try owner.seamHook().call(&session, .completion, false);

    var prepared = try owner.prepareSelection(&session, .{
        .provider = "new",
        .model = "new-model",
        .preset = "review",
    });
    var retired = owner.publishSelectionRetired(&session, &prepared);
    var transition = owner.beginTransitionSelection(&retired);
    retired.deinit();
    defer transition.deinit();
    try session.addTaskNote("[task t1 killed at exit]");
    _ = try owner.seamHook().call(&session, .task_note, false);

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, owner.activePath().?, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "task_note") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"type\":\"selection\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"preset\":\"review\"") == null);
}

test "restored transition selection flushes without a new item" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var optional_log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{
        .provider = "old",
        .model = "old-model",
    });
    const owner = try Owner.create(allocator, &optional_log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{
        .provider_id = "old",
        .model = "old-model",
    });
    defer session.deinit();
    try session.addUser("old conversation");
    _ = try owner.seamHook().call(&session, .completion, false);

    var prepared = try owner.prepareSelection(&session, .{
        .provider = "new",
        .model = "new-model",
        .preset = "review",
    });
    var retired = owner.publishSelectionRetired(&session, &prepared);
    var transition = owner.beginTransitionSelection(&retired);
    retired.deinit();
    defer transition.deinit();
    transition.restore();
    const commit_fn = owner.activeLog().commit_fn;
    owner.activeLog().commit_fn = failBeforeWrite;
    const retryable: TransitionSelectionFlush = .{ .retryable = .io_retryable };
    try std.testing.expectEqual(retryable, owner.flushRestoredTransitionSelection(&session));
    switch (owner.state(&session)) {
        .pending_append => |pending| try std.testing.expectEqual(pending.durable, pending.memory),
        else => return error.TestUnexpectedResult,
    }
    owner.activeLog().commit_fn = commit_fn;
    try std.testing.expectEqual(
        TransitionSelectionFlush.synchronized,
        owner.flushRestoredTransitionSelection(&session),
    );

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, owner.activePath().?, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"type\":\"selection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"preset\":\"review\"") != null);
}

test "selection preparation supports unrecorded authority and rejects quarantine" {
    const allocator = std.testing.allocator;
    var none: ?persistence.SessionFile.Log = null;
    const owner = try Owner.create(allocator, &none, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{ .provider_id = "old" });
    defer session.deinit();

    var prepared = try owner.prepareSelection(&session, .{ .provider = "new", .preset = "" });
    defer prepared.deinit();
    try std.testing.expect(prepared.log == null);
    owner.publishSelection(&session, &prepared);
    try std.testing.expectEqualStrings("new", session.currentSelection().provider_id.?);
    try std.testing.expect(session.currentSelection().preset == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var next: ?persistence.SessionFile.Log = try testLog(allocator, std.testing.io, root, .{
        .provider = "new",
    });
    var adoption = try owner.prepareAdoption(&next);
    defer adoption.deinit();
    var retired = owner.publishAdoption(&adoption);
    retired.deinit();
    owner.quarantine(.append_indeterminate);
    try std.testing.expectError(
        error.Quarantined,
        owner.prepareSelection(&session, .{ .provider = "other" }),
    );
}

test "undo cut bridge commits unrecorded and lazy memory cuts without a disk mutation" {
    const allocator = std.testing.allocator;

    var none: ?persistence.SessionFile.Log = null;
    const unrecorded = try Owner.create(allocator, &none, .{});
    defer unrecorded.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.addUser("first");
    try session.addUser("second");
    var memory = try session.prepareTypedCut(1);
    defer memory.deinit();
    var prepared = try unrecorded.prepareCut(&session, &memory);
    defer prepared.deinit();
    const outcome = try unrecorded.executeCut(&prepared);
    var commit = outcome.committed;
    defer commit.deinit();
    session.publishTypedCut(&memory);
    commit.finish();
    try std.testing.expectEqual(@as(usize, 1), session.typedTurnCount());
    try std.testing.expect(unrecorded.state(&session) == .unrecorded);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var lazy_log: ?persistence.SessionFile.Log = try testLog(
        allocator,
        std.testing.io,
        root_buffer[0..root_len],
        .{},
    );
    const lazy = try Owner.create(allocator, &lazy_log, .{});
    defer lazy.deinit();
    var lazy_session = try agent.Session.Session.init(allocator, .{});
    defer lazy_session.deinit();
    try lazy_session.addUser("only");
    var lazy_memory = try lazy_session.prepareTypedCut(0);
    defer lazy_memory.deinit();
    var lazy_prepared = try lazy.prepareCut(&lazy_session, &lazy_memory);
    defer lazy_prepared.deinit();
    const lazy_outcome = try lazy.executeCut(&lazy_prepared);
    var lazy_commit = lazy_outcome.committed;
    defer lazy_commit.deinit();
    lazy_session.publishTypedCut(&lazy_memory);
    lazy_commit.finish();
    try std.testing.expectEqual(@as(usize, 0), lazy.activeLog().highWater());
    try std.testing.expect(!lazy.materialized());
}

test "undo cut bridge validates synchronized plans and rejects pending quarantine mismatch and stale candidates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    var log: ?persistence.SessionFile.Log = try testLog(allocator, io, root_buffer[0..root_len], .{});
    const owner = try Owner.create(allocator, &log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.addUser("first");
    try session.addUser("second");
    _ = try owner.call(&session, .completion, false);

    var memory = try session.prepareTypedCut(1);
    defer memory.deinit();
    var mismatched = memory;
    mismatched.retained_items += 1;
    try std.testing.expectError(error.Mismatch, owner.prepareCut(&session, &mismatched));

    var prepared = try owner.prepareCut(&session, &memory);
    defer prepared.deinit();
    var selection = try owner.prepareSelection(&session, .{ .provider = "p" });
    defer selection.deinit();
    owner.publishSelection(&session, &selection);
    try std.testing.expectError(error.StaleCut, owner.executeCut(&prepared));
    try std.testing.expect(owner.authority == .active);

    try session.addUser("pending");
    var pending_memory = try session.prepareTypedCut(2);
    defer pending_memory.deinit();
    try std.testing.expectError(error.PendingAppend, owner.prepareCut(&session, &pending_memory));
    owner.quarantine(.external_change);
    try std.testing.expectError(error.Quarantined, owner.prepareCut(&session, &pending_memory));
}

test "prepared undo quarantines same-size rewrites and named replacements before truncate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDir(io, "second", .default_dir);
    const second_root = try tmp.dir.realPathFileAlloc(io, "second", allocator);
    defer allocator.free(second_root);

    {
        var log: ?persistence.SessionFile.Log = try testLog(allocator, io, root, .{});
        const owner = try Owner.create(allocator, &log, .{});
        defer owner.deinit();
        var session = try agent.Session.Session.init(allocator, .{});
        defer session.deinit();
        try session.addUser("first");
        try session.addUser("second");
        _ = try owner.call(&session, .completion, false);
        var memory = try session.prepareTypedCut(1);
        defer memory.deinit();
        var prepared = try owner.prepareCut(&session, &memory);
        defer prepared.deinit();

        try owner.activeLog().file.?.writePositionalAll(io, "X", 0);
        try std.testing.expectError(error.InvalidPlan, owner.executeCut(&prepared));
        try std.testing.expectEqual(QuarantineReason.external_change, owner.state(&session).quarantined);
        try std.testing.expectError(error.Indeterminate, owner.call(&session, .completion, false));
    }

    {
        var log: ?persistence.SessionFile.Log = try testLog(allocator, io, second_root, .{});
        const owner = try Owner.create(allocator, &log, .{});
        defer owner.deinit();
        var session = try agent.Session.Session.init(allocator, .{});
        defer session.deinit();
        try session.addUser("first");
        try session.addUser("second");
        _ = try owner.call(&session, .completion, false);
        var memory = try session.prepareTypedCut(1);
        defer memory.deinit();
        var prepared = try owner.prepareCut(&session, &memory);
        defer prepared.deinit();

        const path = owner.activePath().?;
        const moved = try std.fmt.allocPrint(allocator, "{s}.old", .{path});
        defer allocator.free(moved);
        try std.Io.Dir.rename(.cwd(), path, .cwd(), moved, io);
        const replacement = try std.Io.Dir.createFile(.cwd(), io, path, .{});
        replacement.close(io);
        try std.testing.expectError(error.InvalidPlan, owner.executeCut(&prepared));
        try std.testing.expectEqual(QuarantineReason.external_change, owner.state(&session).quarantined);
        try std.testing.expectError(error.Indeterminate, owner.call(&session, .completion, false));
    }
}

test "undo cut bridge publishes committed sync failure before quarantine" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    var log: ?persistence.SessionFile.Log = try testLog(allocator, io, root_buffer[0..root_len], .{});
    const owner = try Owner.create(allocator, &log, .{});
    defer owner.deinit();
    var session = try agent.Session.Session.init(allocator, .{});
    defer session.deinit();
    try session.addUser("first");
    try session.addUser("second");
    _ = try owner.call(&session, .completion, false);
    var memory = try session.prepareTypedCut(1);
    defer memory.deinit();
    var prepared = try owner.prepareCut(&session, &memory);
    defer prepared.deinit();
    owner.activeLog().append_sync_file_fn = failSync;
    const outcome = try owner.executeCut(&prepared);
    var commit = outcome.committed;
    defer commit.deinit();
    try std.testing.expectEqual(persistence.SessionFile.MutationDurability.sync_failed, commit.durability);
    try std.testing.expect(owner.state(&session) == .pending_append);
    session.publishTypedCut(&memory);
    commit.finish();
    try std.testing.expectEqual(QuarantineReason.sync_failed, owner.state(&session).quarantined);
}
