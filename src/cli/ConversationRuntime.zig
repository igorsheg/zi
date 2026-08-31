const std = @import("std");
const agent = @import("../agent/root.zig");
const persistence = @import("../persistence/root.zig");
const SessionDurability = @import("../SessionDurability.zig");
const ToolRuntime = @import("../ToolRuntime.zig");
const RunSelection = @import("RunSelection.zig");
const SessionStartup = @import("SessionStartup.zig");

const ConversationRuntime = @This();

pub const TimestampProvider = struct {
    context: ?*anyopaque = null,
    next_fn: *const fn (?*anyopaque) persistence.Paths.Timestamp,

    pub fn next(self: TimestampProvider) persistence.Paths.Timestamp {
        return self.next_fn(self.context);
    }

    pub fn from(implementation: anytype) TimestampProvider {
        const Pointer = @TypeOf(implementation);
        const Implementation = @typeInfo(Pointer).pointer.child;
        const Adapter = struct {
            fn next(context: ?*anyopaque) persistence.Paths.Timestamp {
                const self: *Implementation = @ptrCast(@alignCast(context.?));
                return self.nextTimestamp();
            }
        };
        return .{ .context = implementation, .next_fn = Adapter.next };
    }
};

pub const UuidProvider = struct {
    pub const Error = error{Unavailable};

    context: ?*anyopaque = null,
    next_fn: *const fn (?*anyopaque) Error![16]u8,

    pub fn next(self: UuidProvider) Error![16]u8 {
        return self.next_fn(self.context);
    }

    pub fn from(implementation: anytype) UuidProvider {
        const Pointer = @TypeOf(implementation);
        const Implementation = @typeInfo(Pointer).pointer.child;
        const Adapter = struct {
            fn next(context: ?*anyopaque) Error![16]u8 {
                const self: *Implementation = @ptrCast(@alignCast(context.?));
                return self.nextUuid();
            }
        };
        return .{ .context = implementation, .next_fn = Adapter.next };
    }
};

pub const FreshFactory = struct {
    pub const Inputs = struct {
        state_root: ?[]const u8,
        cwd: []const u8,
        writer_version: []const u8,
        git_probe: ?persistence.SessionFile.GitProbe = null,
        session_limits: agent.Session.Limits = .{},
        file_limits: persistence.SessionFile.Limits = .{},
        timestamp_provider: TimestampProvider,
        uuid_provider: UuidProvider,
    };

    allocator: std.mem.Allocator,
    state_root: ?[]u8,
    cwd: []u8,
    writer_version: []u8,
    git_probe: ?persistence.SessionFile.GitProbe,
    session_limits: agent.Session.Limits,
    file_limits: persistence.SessionFile.Limits,
    timestamp_provider: TimestampProvider,
    uuid_provider: UuidProvider,

    fn init(allocator: std.mem.Allocator, inputs: Inputs) error{OutOfMemory}!FreshFactory {
        const state_root = if (inputs.state_root) |value| try allocator.dupe(u8, value) else null;
        errdefer if (state_root) |value| allocator.free(value);
        const cwd = try allocator.dupe(u8, inputs.cwd);
        errdefer allocator.free(cwd);
        const writer_version = try allocator.dupe(u8, inputs.writer_version);
        return .{
            .allocator = allocator,
            .state_root = state_root,
            .cwd = cwd,
            .writer_version = writer_version,
            .git_probe = inputs.git_probe,
            .session_limits = inputs.session_limits,
            .file_limits = inputs.file_limits,
            .timestamp_provider = inputs.timestamp_provider,
            .uuid_provider = inputs.uuid_provider,
        };
    }

    fn deinit(self: *FreshFactory) void {
        if (self.state_root) |value| self.allocator.free(value);
        self.allocator.free(self.cwd);
        self.allocator.free(self.writer_version);
        self.* = undefined;
    }
};

pub const CreateOptions = struct {
    io: std.Io,
    recording_policy: SessionStartup.RecordingPolicy,
    fresh: FreshFactory.Inputs,
    durability: SessionDurability.Options = .{},
};

pub const CreateError = error{OutOfMemory};

pub const Guard = struct {
    conversation: u64,
    session_history: u64,
    session_selection: u64,
    durability: u64,
    run_selection: u64,
};

pub const EntryState = struct {
    guard: Guard,
    authority: SessionDurability.State,
};

pub const Transition = enum { new, @"resume", undo, fork };

pub const PublicationAuthorization = struct {
    owner: *Owner,
    selection: *RunSelection.Owner,
    transition: Transition,
    candidate_address: *anyopaque,
    entry: EntryState,
    final_guard: Guard,
    settlement: union(enum) {
        none,
        completed: ToolRuntime.TransitionSettlement,
    },
    nonce: u64,
    active: bool = true,
};

pub const PublishLease = struct {
    authorization: PublicationAuthorization,
    conversation_phase_reserved: bool = true,
    selection_phase_reserved: bool = true,
    active: bool = true,

    pub fn cancel(self: *PublishLease) void {
        if (self.active) {
            std.debug.assert(self.authorization.owner.phase == .publishing);
            std.debug.assert(self.authorization.selection.committing);
            self.authorization.selection.committing = false;
            self.authorization.owner.phase = .idle;
            self.active = false;
        }
        self.* = undefined;
    }
};

const Phase = enum { idle, publishing };

pub const PrepareNewError = agent.Session.Error || persistence.SessionFile.Error || UuidProvider.Error || error{
    MissingStateRoot,
    Reentrant,
    StaleCandidate,
};
pub const BindError = agent.Session.Error || error{
    StaleCandidate,
    Quarantined,
    SettlementIncomplete,
};
pub const BeginPublishError = error{ Reentrant, StaleCandidate };

pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_value: agent.Session.Session,
    durability_value: *SessionDurability.Owner,
    identity: SessionStartup.Identity,
    recording_policy: SessionStartup.RecordingPolicy,
    fresh: FreshFactory,
    startup_meta: ?persistence.SessionFile.Meta,
    startup_recovery: ?persistence.SessionFile.Recovery,
    startup_index_recovery: ?persistence.SessionIndex.Recovery,
    startup_warning: ?SessionStartup.Warning,
    generation_value: u64 = 0,
    next_authorization_nonce: u64 = 1,
    issued_authorization_nonce: ?u64 = null,
    consumed_authorization_nonce: u64 = 0,
    phase: Phase = .idle,

    /// On success consumes `startup`. Failure leaves it owned by the caller.
    pub fn create(
        allocator: std.mem.Allocator,
        startup: *SessionStartup.Candidate,
        options: CreateOptions,
    ) CreateError!*Owner {
        std.debug.assert(startup.active);
        const self = try allocator.create(Owner);
        errdefer allocator.destroy(self);
        var fresh = try FreshFactory.init(allocator, options.fresh);
        errdefer fresh.deinit();
        const durability_owner = try SessionDurability.Owner.create(allocator, &startup.log, options.durability);
        errdefer durability_owner.deinit();
        self.* = .{
            .allocator = allocator,
            .io = options.io,
            .session_value = startup.session,
            .durability_value = durability_owner,
            .identity = startup.identity,
            .recording_policy = options.recording_policy,
            .fresh = fresh,
            .startup_meta = startup.meta,
            .startup_recovery = startup.recovery,
            .startup_index_recovery = startup.index_recovery,
            .startup_warning = startup.warning,
        };
        startup.active = false;
        return self;
    }

    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        std.debug.assert(self.phase == .idle);
        std.debug.assert(self.issued_authorization_nonce == null);
        const allocator = self.allocator;
        self.durability_value.deinit();
        self.session_value.deinit();
        self.identity.deinit(allocator);
        self.fresh.deinit();
        if (self.startup_meta) |*value| value.deinit(allocator);
        if (self.startup_warning) |*value| value.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn session(self: *Owner) *agent.Session.Session {
        return &self.session_value;
    }

    pub fn durability(self: *Owner) *SessionDurability.Owner {
        return self.durability_value;
    }

    pub fn activePath(self: *const Owner) ?[]const u8 {
        return self.identity.active_path;
    }

    pub fn resumeHint(self: *const Owner) ?[]const u8 {
        if (!self.durability_value.materialized()) return null;
        return self.identity.id;
    }

    pub fn generation(self: *const Owner) u64 {
        return self.generation_value;
    }

    pub fn policy(self: *const Owner) SessionStartup.RecordingPolicy {
        return self.recording_policy;
    }

    pub fn startupMeta(self: *const Owner) ?*const persistence.SessionFile.Meta {
        return if (self.startup_meta) |*value| value else null;
    }

    pub fn startupRecovery(self: *const Owner) ?persistence.SessionFile.Recovery {
        return self.startup_recovery;
    }

    pub fn startupIndexRecovery(self: *const Owner) ?persistence.SessionIndex.Recovery {
        return self.startup_index_recovery;
    }

    pub fn startupWarning(self: *const Owner) ?SessionStartup.Warning {
        return self.startup_warning;
    }

    pub fn captureEntryState(self: *Owner, selection: *RunSelection.Owner) EntryState {
        return .{
            .guard = self.currentGuard(selection),
            .authority = self.durability_value.state(&self.session_value),
        };
    }

    // ziglint-ignore: Z015
    pub fn prepareNew(
        self: *Owner,
        selection: *RunSelection.Owner,
        entry: EntryState,
    ) PrepareNewError!NewCandidate {
        const current = self.session_value.currentSelection();
        const log_selection: persistence.SessionFile.Selection = .{
            .provider = current.provider_id,
            .model = current.model,
            .model_label = current.model_label,
            .effort = current.effort,
            .preset = current.preset,
        };
        return self.prepareNewInternal(selection, entry, current, log_selection, false);
    }

    /// Prepares a detached fresh conversation against an explicit prospective
    /// selection before the corresponding live preset publication.
    // ziglint-ignore: Z015
    pub fn prepareNewForSelection(
        self: *Owner,
        selection: *RunSelection.Owner,
        entry: EntryState,
        prospective: agent.Session.Selection,
        log_selection: persistence.SessionFile.Selection,
    ) PrepareNewError!NewCandidate {
        return self.prepareNewInternal(selection, entry, prospective, log_selection, true);
    }

    fn prepareNewInternal(
        self: *Owner,
        selection: *RunSelection.Owner,
        entry: EntryState,
        prospective: agent.Session.Selection,
        log_selection: persistence.SessionFile.Selection,
        expects_preset_publication: bool,
    ) PrepareNewError!NewCandidate {
        if (self.phase != .idle or self.issued_authorization_nonce != null) return error.Reentrant;
        const prepared_guard = self.currentGuard(selection);
        if (entry.guard.conversation != prepared_guard.conversation or
            entry.guard.session_history != prepared_guard.session_history or
            entry.guard.session_selection != prepared_guard.session_selection or
            entry.guard.run_selection != prepared_guard.run_selection)
        {
            return error.StaleCandidate;
        }
        var replacement = try agent.Session.Session.init(self.allocator, .{
            .provider_id = prospective.provider_id,
            .model = prospective.model,
            .model_label = prospective.model_label,
            .effort = prospective.effort,
            .preset = prospective.preset,
            .limits = self.fresh.session_limits,
        });
        errdefer replacement.deinit();

        const timestamp = self.fresh.timestamp_provider.next();
        const uuid = try self.fresh.uuid_provider.next();
        var replacement_log: ?persistence.SessionFile.Log = null;
        errdefer if (replacement_log) |*value| value.deinit();
        if (self.durability_value.activePath() != null) {
            const state_root = self.fresh.state_root orelse return error.MissingStateRoot;
            replacement_log = try persistence.SessionFile.Log.prepare(self.allocator, self.io, .{
                .state_root = state_root,
                .cwd = self.fresh.cwd,
                .selection = log_selection,
                .timestamp = timestamp,
                .uuid = uuid,
                .writer_version = self.fresh.writer_version,
                .git_probe = self.fresh.git_probe,
                .limits = self.fresh.file_limits,
            });
        }
        var identity = try freshIdentity(self.allocator, timestamp, uuid, replacement_log);
        errdefer identity.deinit(self.allocator);
        const result: NewCandidate = .{
            .owner = self,
            .selection = selection,
            .entry = entry,
            .prepared_entry_guard = prepared_guard,
            .replacement = replacement,
            .replacement_log = replacement_log,
            .identity = identity,
            .expected_preset_publication = if (expects_preset_publication) .{
                .before = prepared_guard,
                .preset_transition_generation = selection.preset_transition_generation +% 1,
                .selection = prospective,
            } else null,
        };
        replacement_log = null;
        return result;
    }

    /// Acknowledges exactly the one preset publication anticipated by a
    /// detached fresh candidate. It may be called once and rebases only the
    /// run/session/durability generations changed by that commit.
    pub fn acknowledgeExpectedPresetPublication(
        self: *Owner,
        selection: *RunSelection.Owner,
        candidate: *NewCandidate,
    ) error{StaleCandidate}!void {
        if (!candidate.active or candidate.owner != self or candidate.selection != selection or candidate.bound) {
            return error.StaleCandidate;
        }
        const expected = candidate.expected_preset_publication orelse return error.StaleCandidate;
        if (candidate.preset_publication_acknowledged) return error.StaleCandidate;
        const current = self.currentGuard(selection);
        if (current.conversation != expected.before.conversation or
            current.session_history != expected.before.session_history or
            current.run_selection != expected.before.run_selection +% 1 or
            current.session_selection != expected.before.session_selection +% 1 or
            current.durability != expected.before.durability +% 1 or
            selection.preset_transition_generation != expected.preset_transition_generation or
            !sessionSelectionEqual(self.session_value.currentSelection(), expected.selection))
        {
            return error.StaleCandidate;
        }
        switch (candidate.entry.authority) {
            .quarantined => switch (self.durability_value.state(&self.session_value)) {
                .quarantined => {},
                else => return error.StaleCandidate,
            },
            .unrecorded, .synchronized, .pending_append => {},
        }
        candidate.prepared_entry_guard = current;
        candidate.preset_publication_acknowledged = true;
    }

    // ziglint-ignore: Z015
    pub fn bindNew(
        self: *Owner,
        selection: *RunSelection.Owner,
        candidate: *NewCandidate,
        final_guard: Guard,
        settlement: ToolRuntime.TransitionSettlement,
    ) BindError!void {
        if (!candidate.active or candidate.owner != self or candidate.selection != selection or candidate.bound) {
            return error.StaleCandidate;
        }
        const expects_preset = candidate.expected_preset_publication != null;
        if (expects_preset != candidate.preset_publication_acknowledged) return error.StaleCandidate;
        if (candidate.entry.guard.conversation != candidate.prepared_entry_guard.conversation or
            candidate.entry.guard.session_history != candidate.prepared_entry_guard.session_history or
            (!expects_preset and (candidate.entry.guard.session_selection !=
                candidate.prepared_entry_guard.session_selection or
                candidate.entry.guard.run_selection != candidate.prepared_entry_guard.run_selection)))
        {
            return error.StaleCandidate;
        }
        var authorization_entry = candidate.entry;
        if (expects_preset) authorization_entry.guard = candidate.prepared_entry_guard;
        try self.validateAuthorization(
            selection,
            candidate,
            authorization_entry,
            final_guard,
            .new,
            settlement,
        );

        var prepared_session = try self.session_value.prepareReplacement(&candidate.replacement);
        errdefer prepared_session.deinit();
        var prepared_adoption = self.durability_value.prepareAdoption(&candidate.replacement_log) catch
            return error.StaleCandidate;
        errdefer prepared_adoption.deinit();
        candidate.prepared_session = prepared_session;
        candidate.prepared_adoption = prepared_adoption;
        candidate.bound = true;
        try self.bindAuthorization(
            selection,
            candidate,
            &candidate.authorization,
            authorization_entry,
            final_guard,
            .new,
            settlement,
        );
    }

    // ziglint-ignore: Z015
    pub fn bindAuthorization(
        self: *Owner,
        selection: *RunSelection.Owner,
        candidate: *anyopaque,
        authorization_slot: *?PublicationAuthorization,
        entry: EntryState,
        final_guard: Guard,
        transition: Transition,
        settlement: ?ToolRuntime.TransitionSettlement,
    ) BindError!void {
        if (authorization_slot.* != null) return error.StaleCandidate;
        if (transition == .new or transition == .@"resume") {
            const completed = settlement orelse return error.SettlementIncomplete;
            try self.validateAuthorization(selection, candidate, entry, final_guard, transition, completed);
        } else {
            if (settlement != null) return error.SettlementIncomplete;
            try self.validateGuard(selection, final_guard);
            if (entry.authority == .quarantined) return error.Quarantined;
        }
        if (self.issued_authorization_nonce != null) return error.StaleCandidate;
        const nonce = self.next_authorization_nonce;
        self.next_authorization_nonce = std.math.add(u64, nonce, 1) catch @panic("authorization nonce exhausted");
        self.issued_authorization_nonce = nonce;
        authorization_slot.* = .{
            .owner = self,
            .selection = selection,
            .transition = transition,
            .candidate_address = candidate,
            .entry = entry,
            .final_guard = final_guard,
            .settlement = if (settlement) |value| .{ .completed = value } else .none,
            .nonce = nonce,
        };
    }

    pub fn beginPublish(
        self: *Owner,
        authorization: *PublicationAuthorization,
    ) BeginPublishError!PublishLease {
        if (self.phase != .idle or authorization.selection.committing or
            authorization.selection.catalog_lookup_active)
        {
            return error.Reentrant;
        }
        if (!authorization.active or authorization.owner != self) return error.StaleCandidate;
        if (self.issued_authorization_nonce != authorization.nonce or
            authorization.nonce <= self.consumed_authorization_nonce)
        {
            return error.StaleCandidate;
        }
        try self.validateGuard(authorization.selection, authorization.final_guard);
        self.phase = .publishing;
        authorization.selection.committing = true;
        self.issued_authorization_nonce = null;
        self.consumed_authorization_nonce = authorization.nonce;
        authorization.active = false;
        return .{ .authorization = authorization.* };
    }

    fn currentGuard(self: *Owner, selection: *RunSelection.Owner) Guard {
        return .{
            .conversation = self.generation_value,
            .session_history = self.session_value.historyGeneration(),
            .session_selection = self.session_value.selectionGeneration(),
            .durability = self.durability_value.generationValue(),
            .run_selection = selection.generation,
        };
    }

    fn validateGuard(
        self: *Owner,
        selection: *RunSelection.Owner,
        guard: Guard,
    ) error{StaleCandidate}!void {
        if (!guardEqual(guard, self.currentGuard(selection))) return error.StaleCandidate;
    }

    fn validateAuthorization(
        self: *Owner,
        selection: *RunSelection.Owner,
        candidate: *anyopaque,
        entry: EntryState,
        final_guard: Guard,
        transition: Transition,
        settlement: ToolRuntime.TransitionSettlement,
    ) BindError!void {
        _ = candidate;
        if (self.phase != .idle or self.issued_authorization_nonce != null) return error.StaleCandidate;
        if (transition != .new and transition != .@"resume") return error.SettlementIncomplete;
        try self.validateGuard(selection, final_guard);
        if (entry.guard.conversation != final_guard.conversation or
            entry.guard.run_selection != final_guard.run_selection)
        {
            return error.StaleCandidate;
        }
        const prior_quarantine = entry.authority == .quarantined;
        if (settlement.prior_quarantine != prior_quarantine or !settlement.permitsReplacement()) {
            return error.SettlementIncomplete;
        }
        if (!prior_quarantine) switch (self.durability_value.state(&self.session_value)) {
            .quarantined => return error.Quarantined,
            else => {},
        };
    }

    fn cancelAuthorization(self: *Owner, authorization: *PublicationAuthorization) void {
        if (!authorization.active) return;
        if (self.issued_authorization_nonce == authorization.nonce) {
            self.issued_authorization_nonce = null;
        }
        authorization.active = false;
    }
};

const ExpectedPresetPublication = struct {
    before: Guard,
    preset_transition_generation: u64,
    selection: agent.Session.Selection,
};

pub const NewCandidate = struct {
    owner: *Owner,
    selection: *RunSelection.Owner,
    entry: EntryState,
    prepared_entry_guard: Guard = undefined,
    replacement: agent.Session.Session,
    replacement_log: ?persistence.SessionFile.Log,
    identity: SessionStartup.Identity,
    expected_preset_publication: ?ExpectedPresetPublication = null,
    preset_publication_acknowledged: bool = false,
    prepared_session: ?agent.Session.PreparedReplacement = null,
    prepared_adoption: ?SessionDurability.PreparedAdoption = null,
    authorization: ?PublicationAuthorization = null,
    bound: bool = false,
    active: bool = true,

    pub fn deinit(self: *NewCandidate) void {
        if (self.active) {
            if (self.authorization) |*value| self.owner.cancelAuthorization(value);
            if (self.prepared_adoption) |*value| value.deinit() else if (self.replacement_log) |*value| value.deinit();
            if (self.prepared_session) |*value| value.deinit() else if (!self.bound) self.replacement.deinit();
            self.identity.deinit(self.owner.allocator);
        }
        self.* = undefined;
    }
};

pub const Retired = struct {
    allocator: std.mem.Allocator,
    session: agent.Session.Retired,
    authority: SessionDurability.RetiredAuthority,
    identity: SessionStartup.Identity,
    meta: ?persistence.SessionFile.Meta,
    recovery: ?persistence.SessionFile.Recovery,
    index_recovery: ?persistence.SessionIndex.Recovery,
    warning: ?SessionStartup.Warning,
    active: bool = true,

    pub fn deinit(self: *Retired) void {
        if (self.active) {
            self.session.deinit();
            self.authority.deinit();
            self.identity.deinit(self.allocator);
            if (self.meta) |*value| value.deinit(self.allocator);
            if (self.warning) |*value| value.deinit(self.allocator);
        }
        self.* = undefined;
    }
};

pub fn publishNew(lease: *PublishLease, candidate: *NewCandidate) Retired {
    std.debug.assert(lease.active);
    const authorization = lease.authorization;
    const owner = authorization.owner;
    std.debug.assert(owner.phase == .publishing);
    std.debug.assert(authorization.transition == .new);
    std.debug.assert(authorization.candidate_address == @as(*anyopaque, @ptrCast(candidate)));
    std.debug.assert(authorization.nonce == owner.consumed_authorization_nonce);
    std.debug.assert(candidate.active);
    std.debug.assert(candidate.bound);
    std.debug.assert(candidate.authorization != null);
    std.debug.assert(candidate.authorization.?.nonce == authorization.nonce);
    std.debug.assert(guardEqual(authorization.final_guard, owner.currentGuard(authorization.selection)));

    const prepared_session = &candidate.prepared_session.?;
    const prepared_adoption = &candidate.prepared_adoption.?;
    const retired_session = owner.session_value.publishReplacement(prepared_session);
    const retired_authority = owner.durability_value.publishAdoption(prepared_adoption);
    const retired: Retired = .{
        .allocator = owner.allocator,
        .session = retired_session,
        .authority = retired_authority,
        .identity = owner.identity,
        .meta = owner.startup_meta,
        .recovery = owner.startup_recovery,
        .index_recovery = owner.startup_index_recovery,
        .warning = owner.startup_warning,
    };
    owner.identity = candidate.identity;
    owner.startup_meta = null;
    owner.startup_recovery = null;
    owner.startup_index_recovery = null;
    owner.startup_warning = null;
    owner.generation_value +%= 1;
    authorization.selection.committing = false;
    owner.phase = .idle;
    candidate.active = false;
    lease.active = false;
    return retired;
}

fn sessionSelectionEqual(a: agent.Session.Selection, b: agent.Session.Selection) bool {
    return optionalEqual(a.provider_id, b.provider_id) and
        optionalEqual(a.model, b.model) and
        optionalEqual(a.model_label, b.model_label) and
        optionalEqual(a.effort, b.effort) and
        optionalEqual(a.preset, b.preset);
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn guardEqual(a: Guard, b: Guard) bool {
    return a.conversation == b.conversation and
        a.session_history == b.session_history and
        a.session_selection == b.session_selection and
        a.durability == b.durability and
        a.run_selection == b.run_selection;
}

fn freshIdentity(
    allocator: std.mem.Allocator,
    timestamp: persistence.Paths.Timestamp,
    uuid: [16]u8,
    log: ?persistence.SessionFile.Log,
) error{OutOfMemory}!SessionStartup.Identity {
    if (log) |log_value| {
        const active_path = try allocator.dupe(u8, log_value.path());
        errdefer allocator.free(active_path);
        return .{
            .active_path = active_path,
            .id = if (log_value.resumeHint()) |value| try allocator.dupe(u8, value) else null,
            .origin = .fresh,
        };
    }
    const name = persistence.Paths.canonicalName(timestamp, uuid) catch return .{ .origin = .fresh };
    return .{
        .id = try allocator.dupe(u8, name[21..57]),
        .origin = .fresh,
    };
}

test {
    _ = ConversationRuntime;
    _ = Owner.create;
    _ = Owner.prepareNew;
    _ = Owner.bindNew;
    _ = Owner.bindAuthorization;
    _ = Owner.beginPublish;
    _ = publishNew;
}

test "recording policy permits mock only when explicitly enabled" {
    try std.testing.expect(!SessionStartup.RecordingPolicy.disabled.permits("openai"));
    try std.testing.expect(SessionStartup.RecordingPolicy.enabled.permits("mock"));
    try std.testing.expect(SessionStartup.RecordingPolicy.automatic.permits("openai"));
    try std.testing.expect(!SessionStartup.RecordingPolicy.automatic.permits("mock"));
}

const TestIdentityProvider = struct {
    timestamp: persistence.Paths.Timestamp = .{ .epoch_seconds = 0 },
    uuid: [16]u8 = [_]u8{0} ** 16,

    fn nextTimestamp(self: *TestIdentityProvider) persistence.Paths.Timestamp {
        return self.timestamp;
    }

    fn nextUuid(self: *TestIdentityProvider) UuidProvider.Error![16]u8 {
        return self.uuid;
    }
};

fn fixedTimestamp(_: ?*anyopaque) persistence.Paths.Timestamp {
    return .{ .epoch_seconds = 1 };
}

fn fixedUuid(_: ?*anyopaque) UuidProvider.Error![16]u8 {
    return .{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x02,
    };
}

fn failingUuid(_: ?*anyopaque) UuidProvider.Error![16]u8 {
    return error.Unavailable;
}

fn testSelection() RunSelection.Owner {
    var selection: RunSelection.Owner = undefined;
    selection.generation = 0;
    selection.committing = false;
    selection.preset_transition_generation = 0;
    selection.catalog_lookup_active = false;
    return selection;
}

fn testSettlement() ToolRuntime.TransitionSettlement {
    return .{
        .note = .none,
        .flush = .unrecorded,
        .shutdown = .no_tasks,
        .prior_quarantine = false,
    };
}

test "owner consumes startup into stable session and durability addresses" {
    const allocator = std.testing.allocator;
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = try agent.Session.Session.init(allocator, .{ .provider_id = "p", .model = "m" }),
        .log = null,
        .identity = .{ .id = try allocator.dupe(u8, "id"), .origin = .fresh },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    defer if (startup.active) startup.deinit();
    var identity_provider: TestIdentityProvider = .{};
    const owner = try Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .automatic,
        .fresh = .{
            .state_root = null,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = TimestampProvider.from(&identity_provider),
            .uuid_provider = UuidProvider.from(&identity_provider),
        },
    });
    defer owner.deinit();

    const session_address = owner.session();
    const durability_address = owner.durability();
    try std.testing.expect(!startup.active);
    try std.testing.expectEqual(session_address, owner.session());
    try std.testing.expectEqual(durability_address, owner.durability());
    try std.testing.expectEqualStrings("id", owner.identity.id.?);
    try std.testing.expectEqual(@as(u64, 0), owner.generation());
}

test "new preparation propagates UUID failure without changing the conversation" {
    const allocator = std.testing.allocator;
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = try agent.Session.Session.init(allocator, .{ .provider_id = "p", .model = "m" }),
        .log = null,
        .identity = .{ .origin = .fresh },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    defer if (startup.active) startup.deinit();
    const owner = try Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .disabled,
        .fresh = .{
            .state_root = null,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = .{ .next_fn = fixedTimestamp },
            .uuid_provider = .{ .next_fn = failingUuid },
        },
    });
    defer owner.deinit();
    var selection = testSelection();

    try std.testing.expectError(
        error.Unavailable,
        owner.prepareNew(&selection, owner.captureEntryState(&selection)),
    );
    try std.testing.expectEqual(@as(u64, 0), owner.generation());
    try std.testing.expectEqualStrings("p", owner.session().currentSelection().provider_id.?);
}

test "plain new publishes once, preserves addresses, and keeps unrecorded continuity" {
    const allocator = std.testing.allocator;
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = try agent.Session.Session.init(allocator, .{ .provider_id = "p", .model = "m" }),
        .log = null,
        .identity = .{ .id = try allocator.dupe(u8, "old"), .origin = .fresh },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    try startup.session.addUser("old history");
    defer if (startup.active) startup.deinit();
    const owner = try Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .enabled,
        .fresh = .{
            .state_root = null,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = .{ .next_fn = fixedTimestamp },
            .uuid_provider = .{ .next_fn = fixedUuid },
        },
    });
    defer owner.deinit();
    var selection = testSelection();
    const session_address = owner.session();
    const durability_address = owner.durability();
    const entry = owner.captureEntryState(&selection);
    var candidate = try owner.prepareNew(&selection, entry);
    defer if (candidate.active) candidate.deinit();
    const final_guard = owner.captureEntryState(&selection).guard;
    try owner.bindNew(&selection, &candidate, final_guard, testSettlement());
    var lease = try owner.beginPublish(&candidate.authorization.?);
    defer if (lease.active) lease.cancel();
    var retired = publishNew(&lease, &candidate);
    defer retired.deinit();

    try std.testing.expectEqual(session_address, owner.session());
    try std.testing.expectEqual(durability_address, owner.durability());
    try std.testing.expectEqual(@as(usize, 0), owner.session().items().len);
    try std.testing.expect(owner.durability().state(owner.session()) == .unrecorded);
    try std.testing.expectEqual(@as(u64, 1), owner.generation());
    try std.testing.expectEqualStrings("old history", retired.session.session.items()[1].user_message.text);
}

test "active new keeps the old log resumable and prepares the next log lazily" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const old_uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x01,
    };
    var log: ?persistence.SessionFile.Log = try persistence.SessionFile.Log.prepare(allocator, io, .{
        .state_root = root,
        .cwd = "/work",
        .selection = .{ .provider = "p", .model = "m" },
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = old_uuid,
        .writer_version = "test",
    });
    errdefer if (log) |*value| value.deinit();
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = try agent.Session.Session.init(allocator, .{ .provider_id = "p", .model = "m" }),
        .log = log,
        .identity = .{
            .active_path = try allocator.dupe(u8, log.?.path()),
            .id = try allocator.dupe(u8, log.?.resumeHint().?),
            .origin = .fresh,
        },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    log = null;
    try startup.session.addUser("old history");
    try startup.log.?.appendSnapshot(0, startup.session.items());
    defer if (startup.active) startup.deinit();
    const old_path = try allocator.dupe(u8, startup.identity.active_path.?);
    defer allocator.free(old_path);
    const owner = try Owner.create(allocator, &startup, .{
        .io = io,
        .recording_policy = .enabled,
        .fresh = .{
            .state_root = root,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = .{ .next_fn = fixedTimestamp },
            .uuid_provider = .{ .next_fn = fixedUuid },
        },
    });
    defer owner.deinit();
    var selection = testSelection();
    const entry = owner.captureEntryState(&selection);
    var candidate = try owner.prepareNew(&selection, entry);
    defer if (candidate.active) candidate.deinit();
    const next_path = try allocator.dupe(u8, candidate.identity.active_path.?);
    defer allocator.free(next_path);
    try std.testing.expect(!std.mem.eql(u8, old_path, next_path));
    try std.testing.expect(!candidate.replacement_log.?.materialized());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), io, next_path, .{}));

    try owner.bindNew(
        &selection,
        &candidate,
        owner.captureEntryState(&selection).guard,
        .{ .note = .none, .flush = .synchronized, .shutdown = .no_tasks, .prior_quarantine = false },
    );
    var lease = try owner.beginPublish(&candidate.authorization.?);
    var retired = publishNew(&lease, &candidate);
    retired.deinit();

    _ = try std.Io.Dir.statFile(.cwd(), io, old_path, .{});
    try std.testing.expectEqualStrings(next_path, owner.activePath().?);
    try std.testing.expect(!owner.durability().materialized());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), io, next_path, .{}));
}

test "stale guard, settlement rejection, and authorization replay preserve the candidate" {
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
    const owner = try Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .disabled,
        .fresh = .{
            .state_root = null,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = .{ .next_fn = fixedTimestamp },
            .uuid_provider = .{ .next_fn = fixedUuid },
        },
    });
    defer owner.deinit();
    var selection = testSelection();
    const entry = owner.captureEntryState(&selection);
    var candidate = try owner.prepareNew(&selection, entry);
    defer if (candidate.active) candidate.deinit();

    var stale = owner.captureEntryState(&selection).guard;
    stale.run_selection +%= 1;
    try std.testing.expectError(error.StaleCandidate, owner.bindNew(
        &selection,
        &candidate,
        stale,
        testSettlement(),
    ));
    var rejected = testSettlement();
    rejected.shutdown = .partial;
    try std.testing.expectError(error.SettlementIncomplete, owner.bindNew(
        &selection,
        &candidate,
        owner.captureEntryState(&selection).guard,
        rejected,
    ));

    try owner.bindNew(
        &selection,
        &candidate,
        owner.captureEntryState(&selection).guard,
        testSettlement(),
    );
    var copied = candidate.authorization.?;
    var lease = try owner.beginPublish(&candidate.authorization.?);
    lease.cancel();
    try std.testing.expectError(error.StaleCandidate, owner.beginPublish(&copied));
}

test "expected preset acknowledgement is once-only and rejects unexpected generations" {
    const allocator = std.testing.allocator;
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = try agent.Session.Session.init(allocator, .{ .provider_id = "old", .model = "old" }),
        .log = null,
        .identity = .{ .origin = .fresh },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    defer if (startup.active) startup.deinit();
    const owner = try Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .disabled,
        .fresh = .{
            .state_root = null,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = .{ .next_fn = fixedTimestamp },
            .uuid_provider = .{ .next_fn = fixedUuid },
        },
    });
    defer owner.deinit();
    var selection = testSelection();
    const prospective: agent.Session.Selection = .{
        .provider_id = "new",
        .model = "model",
        .model_label = "Model",
        .effort = "high",
        .preset = "review",
    };
    const log_selection: persistence.SessionFile.Selection = .{
        .provider = prospective.provider_id,
        .model = prospective.model,
        .model_label = prospective.model_label,
        .effort = prospective.effort,
        .preset = prospective.preset,
    };

    const entry = owner.captureEntryState(&selection);
    var candidate = try owner.prepareNewForSelection(&selection, entry, prospective, log_selection);
    defer if (candidate.active) candidate.deinit();
    var metadata = try owner.durability().prepareSelection(owner.session(), log_selection);
    owner.durability().publishSelection(owner.session(), &metadata);
    selection.generation +%= 1;
    selection.preset_transition_generation +%= 1;
    try owner.acknowledgeExpectedPresetPublication(&selection, &candidate);
    try std.testing.expectError(
        error.StaleCandidate,
        owner.acknowledgeExpectedPresetPublication(&selection, &candidate),
    );
    candidate.deinit();

    const next_entry = owner.captureEntryState(&selection);
    var unexpected = try owner.prepareNewForSelection(&selection, next_entry, prospective, log_selection);
    defer if (unexpected.active) unexpected.deinit();
    var next_metadata = try owner.durability().prepareSelection(owner.session(), log_selection);
    owner.durability().publishSelection(owner.session(), &next_metadata);
    selection.generation +%= 2;
    selection.preset_transition_generation +%= 1;
    try std.testing.expectError(
        error.StaleCandidate,
        owner.acknowledgeExpectedPresetPublication(&selection, &unexpected),
    );
}

fn exerciseCancelledFreshAllocation(allocator: std.mem.Allocator) !void {
    var session = try agent.Session.Session.init(allocator, .{ .provider_id = "p", .model = "m" });
    var session_owned = true;
    errdefer if (session_owned) session.deinit();
    const id = try allocator.dupe(u8, "old");
    var id_owned = true;
    errdefer if (id_owned) allocator.free(id);
    var startup: SessionStartup.Candidate = .{
        .allocator = allocator,
        .session = session,
        .log = null,
        .identity = .{ .id = id, .origin = .fresh },
        .meta = null,
        .recovery = null,
        .index_recovery = null,
        .warning = null,
    };
    session_owned = false;
    id_owned = false;
    defer if (startup.active) startup.deinit();
    const owner = try Owner.create(allocator, &startup, .{
        .io = std.testing.io,
        .recording_policy = .disabled,
        .fresh = .{
            .state_root = null,
            .cwd = "/work",
            .writer_version = "test",
            .timestamp_provider = .{ .next_fn = fixedTimestamp },
            .uuid_provider = .{ .next_fn = fixedUuid },
        },
    });
    defer owner.deinit();
    var selection = testSelection();
    const entry = owner.captureEntryState(&selection);
    var candidate = try owner.prepareNew(&selection, entry);
    candidate.deinit();
    try std.testing.expectEqual(@as(u64, 0), owner.generation());
}

test "cancelled fresh preparation releases every allocation under OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCancelledFreshAllocation,
        .{},
    );
}
