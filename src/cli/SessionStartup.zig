const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const persistence = @import("../persistence/root.zig");
const Args = @import("Args.zig");

const SessionStartup = @This();

pub const Toucher = struct {
    context: ?*anyopaque = null,
    touch_fn: *const fn (std.Io, ?*anyopaque, []const u8) persistence.SessionFile.TouchError!void = standardTouch,

    pub const standard: Toucher = .{};

    pub fn touch(self: Toucher, io: std.Io, path: []const u8) persistence.SessionFile.TouchError!void {
        return self.touch_fn(io, self.context, path);
    }

    pub fn from(implementation: anytype) Toucher {
        const Pointer = @TypeOf(implementation);
        const Implementation = @typeInfo(Pointer).pointer.child;
        const Adapter = struct {
            fn touchFn(
                io: std.Io,
                context: ?*anyopaque,
                path: []const u8,
            ) persistence.SessionFile.TouchError!void {
                const self: *Implementation = @ptrCast(@alignCast(context.?));
                return self.touch(io, path);
            }
        };
        return .{ .context = implementation, .touch_fn = Adapter.touchFn };
    }

    fn standardTouch(io: std.Io, _: ?*anyopaque, path: []const u8) persistence.SessionFile.TouchError!void {
        return persistence.SessionFile.touch(io, path);
    }
};

pub const ResolveInputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: ?[]const u8,
    /// Canonical absolute working directory.
    cwd: []const u8,
    resume_state: Args.Resume,
    cutoff_epoch_seconds: i64,
    limits: persistence.SessionIndex.Limits = .{},
    toucher: Toucher = .standard,
};

pub const ResolveError = persistence.SessionIndex.Error;

/// Heap-stable owner of the scanned index. Every returned view borrows this
/// owner. `resolve` touches the selected file before constructing this value.
pub const Resolved = struct {
    allocator: std.mem.Allocator,
    index: persistence.SessionIndex.Index,
    selected_index: usize,

    pub fn deinit(self: *Resolved) void { // ziglint-ignore: Z030
        const allocator = self.allocator;
        self.index.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn entry(self: *const Resolved) *const persistence.SessionIndex.Entry {
        return &self.index.entries[self.selected_index];
    }

    pub fn path(self: *const Resolved) []const u8 {
        return self.entry().path;
    }

    pub fn id(self: *const Resolved) ?[]const u8 {
        return self.entry().id;
    }

    pub fn meta(self: *const Resolved) *const persistence.SessionFile.Meta {
        return &self.entry().meta;
    }

    pub fn selection(self: *const Resolved) persistence.SessionFile.Selection {
        const value = self.entry().meta.selection;
        return .{
            .provider = value.provider,
            .model = value.model,
            .model_label = value.model_label,
            .effort = value.effort,
            .preset = value.preset,
        };
    }

    pub fn recovery(self: *const Resolved) persistence.SessionIndex.Recovery {
        return self.index.recovery;
    }
};

pub const Candidates = struct {
    allocator: std.mem.Allocator,
    index: persistence.SessionIndex.Index,

    pub fn deinit(self: *Candidates) void { // ziglint-ignore: Z030
        const allocator = self.allocator;
        self.index.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn entries(self: *const Candidates) []const persistence.SessionIndex.Entry {
        return self.index.entries;
    }

    pub fn resolve(
        self: *Candidates,
        io: std.Io,
        toucher: Toucher,
        selected_index: usize,
    ) error{OutOfMemory}!*Resolved {
        std.debug.assert(selected_index < self.index.entries.len);
        const owner = self.allocator.create(Resolved) catch return error.OutOfMemory;
        toucher.touch(io, self.index.entries[selected_index].path) catch {}; // ziglint-ignore: Z026
        owner.* = .{
            .allocator = self.allocator,
            .index = self.index,
            .selected_index = selected_index,
        };
        self.allocator.destroy(self);
        return owner;
    }
};

pub const ResolveResult = union(enum) {
    absent,
    found: *Resolved,
    candidates: *Candidates,
    not_found,
    ambiguous,
    id_is_path,
};

/// Resolves only explicit resume requests. `.absent` performs no filesystem
/// scan. A null state root is an ordinary `.not_found` for latest or ID resume.
// ziglint-ignore: Z015
pub fn resolve(inputs: ResolveInputs) ResolveError!ResolveResult {
    const selector: persistence.SessionResolver.Selector = switch (inputs.resume_state) {
        .absent => return .absent,
        .select => {
            const owner = inputs.allocator.create(Candidates) catch return error.OutOfMemory;
            errdefer inputs.allocator.destroy(owner);
            const index = if (inputs.state_root) |state_root|
                try persistence.SessionIndex.list(
                    inputs.allocator,
                    inputs.io,
                    state_root,
                    inputs.cwd,
                    inputs.cutoff_epoch_seconds,
                    inputs.limits,
                )
            else
                persistence.SessionIndex.Index{ .entries = &.{}, .recovery = .{} };
            owner.* = .{ .allocator = inputs.allocator, .index = index };
            return .{ .candidates = owner };
        },
        .latest => .latest,
        .id => |id| id_selector: {
            // hax is Unix-only: a slash means a path was supplied where an ID
            // was required. Backslash is an ordinary unmatched ID byte.
            if (std.mem.findScalar(u8, id, '/') != null) return .id_is_path;
            break :id_selector .{ .id = id };
        },
    };
    const state_root = inputs.state_root orelse return .not_found;
    var index = try persistence.SessionIndex.list(
        inputs.allocator,
        inputs.io,
        state_root,
        inputs.cwd,
        inputs.cutoff_epoch_seconds,
        inputs.limits,
    );
    errdefer index.deinit(inputs.allocator);
    const selected_index = switch (persistence.SessionResolver.resolve(index.entries, selector)) {
        .found => |value| value,
        .not_found => {
            index.deinit(inputs.allocator);
            return .not_found;
        },
        .ambiguous => {
            index.deinit(inputs.allocator);
            return .ambiguous;
        },
    };
    inputs.toucher.touch(inputs.io, index.entries[selected_index].path) catch {}; // ziglint-ignore: Z026
    const owner = try inputs.allocator.create(Resolved);
    owner.* = .{
        .allocator = inputs.allocator,
        .index = index,
        .selected_index = selected_index,
    };
    return .{ .found = owner };
}

pub const NewIdentity = struct {
    timestamp: persistence.Paths.Timestamp,
    uuid: [16]u8,
    git_probe: ?persistence.SessionFile.GitProbe = null,
};

pub const StartOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: ?[]const u8,
    /// Canonical absolute working directory.
    cwd: []const u8,
    no_session: bool = false,
    new_identity: ?NewIdentity = null,
    writer_version: []const u8,
    session_limits: agent.Session.Limits = .{},
    file_limits: persistence.SessionFile.Limits = .{},
};

pub const StartError = persistence.SessionFile.Error || agent.Session.Error || error{MissingIdentity};

pub const RecordingPolicy = enum {
    disabled,
    enabled,
    automatic,

    pub fn permits(self: RecordingPolicy, provider: []const u8) bool {
        return switch (self) {
            .disabled => false,
            .enabled => true,
            .automatic => !std.mem.eql(u8, provider, "mock"),
        };
    }
};

pub const Identity = struct {
    pub const Origin = enum { fresh, resumed };

    active_path: ?[]u8 = null,
    id: ?[]u8 = null,
    origin: Origin,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        if (self.active_path) |value| allocator.free(value);
        if (self.id) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Warning = union(enum) {
    resume_append_unavailable: []u8,

    pub fn deinit(self: *Warning, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .resume_append_unavailable => |path| allocator.free(path),
        }
        self.* = undefined;
    }
};

/// Move-only startup value. Every retained fact is independent of `Resolved`.
pub const Candidate = struct {
    allocator: std.mem.Allocator,
    session: agent.Session.Session,
    log: ?persistence.SessionFile.Log,
    identity: Identity,
    meta: ?persistence.SessionFile.Meta,
    recovery: ?persistence.SessionFile.Recovery,
    index_recovery: ?persistence.SessionIndex.Recovery,
    warning: ?Warning,
    active: bool = true,

    pub fn deinit(self: *Candidate) void {
        if (self.active) {
            if (self.log) |*value| value.deinit();
            self.session.deinit();
            self.identity.deinit(self.allocator);
            if (self.meta) |*value| value.deinit(self.allocator);
            if (self.warning) |*value| value.deinit(self.allocator);
        }
        self.* = undefined;
    }
};

/// Temporary compatibility owner for composition code not yet converted to
/// `ConversationRuntime`. New code should call `startCandidate`.
pub const Run = struct {
    allocator: std.mem.Allocator,
    candidate: Candidate,

    pub fn deinit(self: *Run) void { // ziglint-ignore: Z030
        const allocator = self.allocator;
        self.candidate.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn session(self: *Run) *agent.Session.Session {
        return &self.candidate.session;
    }

    pub fn meta(self: *const Run) ?*const persistence.SessionFile.Meta {
        return if (self.candidate.meta) |*value| value else null;
    }

    pub fn recovery(self: *const Run) ?persistence.SessionFile.Recovery {
        return self.candidate.recovery;
    }

    pub fn indexRecovery(self: *const Run) ?persistence.SessionIndex.Recovery {
        return self.candidate.index_recovery;
    }

    pub fn log(self: *Run) ?*persistence.SessionFile.Log {
        return if (self.candidate.log) |*value| value else null;
    }

    pub fn takeLog(self: *Run) ?persistence.SessionFile.Log {
        const value = self.candidate.log;
        self.candidate.log = null;
        return value;
    }

    pub fn warning(self: *const Run) ?Warning {
        return self.candidate.warning;
    }

    pub fn recordingAvailable(self: *const Run) bool {
        return self.candidate.log != null;
    }

    pub fn materialized(self: *const Run) bool {
        return if (self.candidate.log) |*value| value.materialized() else false;
    }

    pub fn resumeHint(self: *const Run) ?[]const u8 {
        if (self.candidate.log) |*value| {
            if (value.materialized()) return value.resumeHint();
        }
        return null;
    }
};

/// Builds a complete startup candidate. On success this consumes and destroys
/// `resolved`. On error the caller still owns it.
// ziglint-ignore: Z015
pub fn startCandidate(
    resolved: ?*Resolved,
    final_selection: persistence.SessionFile.Selection,
    options: StartOptions,
) StartError!Candidate {
    var pending_log: ?persistence.SessionFile.Log = null;
    errdefer if (pending_log) |*value| value.deinit();
    var pending_warning: ?Warning = null;
    errdefer if (pending_warning) |*value| value.deinit(options.allocator);

    var session: agent.Session.Session = undefined;
    var meta: ?persistence.SessionFile.Meta = null;
    var recovery: ?persistence.SessionFile.Recovery = null;
    var session_owned = false;
    errdefer if (session_owned) session.deinit();
    errdefer if (meta) |*value| value.deinit(options.allocator);

    if (resolved) |selected| {
        var loaded: persistence.SessionFile.Loaded = undefined;
        if (options.no_session) {
            loaded = try persistence.SessionFile.loadStableForResume(
                options.allocator,
                options.io,
                selected.path(),
                options.file_limits,
            );
        } else if (persistence.SessionFile.loadLockedForResume(
            options.allocator,
            options.io,
            selected.path(),
            options.file_limits,
        )) |atomic_value| {
            const atomic = atomic_value;
            loaded = atomic.loaded;
            pending_log = atomic.log;
        } else |resume_err| {
            if (resume_err == error.OutOfMemory) return error.OutOfMemory;
            loaded = try persistence.SessionFile.loadStableForResume(
                options.allocator,
                options.io,
                selected.path(),
                options.file_limits,
            );
            pending_warning = .{ .resume_append_unavailable = try options.allocator.dupe(u8, selected.path()) };
        }
        errdefer loaded.deinit();
        try loaded.session.reconfigureLimits(options.session_limits);
        try loaded.session.reconfigureSelection(toAgentSelection(final_selection));
        if (pending_log) |*log_value| {
            log_value.setSelection(final_selection) catch {
                log_value.deinit();
                pending_log = null;
                if (pending_warning == null) {
                    pending_warning = .{
                        .resume_append_unavailable = try options.allocator.dupe(u8, selected.path()),
                    };
                }
            };
        }
        const parts = loaded.takeParts();
        session = parts.session;
        meta = parts.meta;
        recovery = parts.recovery;
        session_owned = true;
    } else {
        session = try agent.Session.Session.init(options.allocator, .{
            .provider_id = final_selection.provider,
            .model = final_selection.model,
            .model_label = final_selection.model_label,
            .effort = final_selection.effort,
            .preset = nonEmpty(final_selection.preset),
            .limits = options.session_limits,
        });
        session_owned = true;
        if (!options.no_session) {
            if (options.state_root) |state_root| {
                const identity_value = options.new_identity orelse return error.MissingIdentity;
                pending_log = persistence.SessionFile.Log.prepare(options.allocator, options.io, .{
                    .state_root = state_root,
                    .cwd = options.cwd,
                    .selection = final_selection,
                    .timestamp = identity_value.timestamp,
                    .uuid = identity_value.uuid,
                    .writer_version = options.writer_version,
                    .git_probe = identity_value.git_probe,
                    .limits = options.file_limits,
                }) catch null;
            }
        }
    }

    var identity = try makeIdentity(options.allocator, resolved, pending_log, options.new_identity);
    errdefer identity.deinit(options.allocator);
    const index_recovery = if (resolved) |selected| selected.recovery() else null;
    const candidate: Candidate = .{
        .allocator = options.allocator,
        .session = session,
        .log = pending_log,
        .identity = identity,
        .meta = meta,
        .recovery = recovery,
        .index_recovery = index_recovery,
        .warning = pending_warning,
    };
    session_owned = false;
    pending_log = null;
    meta = null;
    pending_warning = null;
    if (resolved) |selected| selected.deinit();
    return candidate;
}

/// Compatibility wrapper around `startCandidate`.
// ziglint-ignore: Z015
pub fn start(
    resolved: ?*Resolved,
    final_selection: persistence.SessionFile.Selection,
    options: StartOptions,
) StartError!*Run {
    const run = try options.allocator.create(Run);
    errdefer options.allocator.destroy(run);
    var candidate = try startCandidate(resolved, final_selection, options);
    run.* = .{ .allocator = options.allocator, .candidate = candidate };
    candidate.active = false;
    return run;
}

fn makeIdentity(
    allocator: std.mem.Allocator,
    resolved: ?*Resolved,
    log: ?persistence.SessionFile.Log,
    new_identity: ?NewIdentity,
) error{OutOfMemory}!Identity {
    if (resolved) |selected| {
        const active_path = try allocator.dupe(u8, selected.path());
        errdefer allocator.free(active_path);
        return .{
            .active_path = active_path,
            .id = try dupeOptional(allocator, selected.id()),
            .origin = .resumed,
        };
    }
    if (log) |log_value| {
        const active_path = try allocator.dupe(u8, log_value.path());
        errdefer allocator.free(active_path);
        return .{
            .active_path = active_path,
            .id = try dupeOptional(allocator, log_value.resumeHint()),
            .origin = .fresh,
        };
    }
    const identity = new_identity orelse return .{ .origin = .fresh };
    const name = persistence.Paths.canonicalName(identity.timestamp, identity.uuid) catch
        return .{ .origin = .fresh };
    return .{
        .id = try allocator.dupe(u8, name[21..57]),
        .origin = .fresh,
    };
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) error{OutOfMemory}!?[]u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

fn toAgentSelection(value: persistence.SessionFile.Selection) agent.Session.Selection {
    return .{
        .provider_id = value.provider,
        .model = value.model,
        .model_label = value.model_label,
        .effort = value.effort,
        .preset = nonEmpty(value.preset),
    };
}

fn loadedSelection(meta_value: *const persistence.SessionFile.Meta) persistence.SessionFile.Selection {
    const value = meta_value.selection;
    return .{
        .provider = value.provider,
        .model = value.model,
        .model_label = value.model_label,
        .effort = value.effort,
        .preset = value.preset,
    };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    if (value) |bytes| if (bytes.len != 0) return bytes;
    return null;
}

test {
    _ = SessionStartup;
}

test "absent and picker candidates do not need a state root" {
    const base: ResolveInputs = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .state_root = null,
        .cwd = "/work",
        .resume_state = .absent,
        .cutoff_epoch_seconds = 0,
    };
    try std.testing.expect((try resolve(base)) == .absent);
    var picker = base;
    picker.resume_state = .select;
    const picker_result = try resolve(picker);
    defer picker_result.candidates.deinit();
    try std.testing.expectEqual(@as(usize, 0), picker_result.candidates.entries().len);
    var latest = base;
    latest.resume_state = .latest;
    try std.testing.expect((try resolve(latest)) == .not_found);
}

test "only Unix slash makes a resume id a path" {
    var inputs: ResolveInputs = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .state_root = null,
        .cwd = "/work",
        .resume_state = .{ .id = "part/id" },
        .cutoff_epoch_seconds = 0,
    };
    try std.testing.expect((try resolve(inputs)) == .id_is_path);
    inputs.resume_state = .{ .id = "part\\id" };
    try std.testing.expect((try resolve(inputs)) == .not_found);
}

test "startup candidate owns a fresh session without a compatibility wrapper" {
    var candidate = try startCandidate(null, .{ .provider = "p", .model = "m" }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .state_root = null,
        .cwd = "/work",
        .no_session = true,
        .writer_version = "test",
    });
    defer candidate.deinit();
    try std.testing.expect(candidate.active);
    try std.testing.expect(candidate.identity.origin == .fresh);
    try std.testing.expectEqualStrings("p", candidate.session.currentSelection().provider_id.?);
}

test "new no-session run needs neither state root nor identity" {
    const run = try start(null, .{ .provider = "p", .model = "m" }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .state_root = null,
        .cwd = "/work",
        .no_session = true,
        .writer_version = "test",
    });
    defer run.deinit();
    try std.testing.expect(!run.recordingAvailable());
    try std.testing.expect(run.warning() == null);
    try std.testing.expectEqualStrings("p", run.session().currentSelection().provider_id.?);
}

test "recorded new run requires explicit identity" {
    try std.testing.expectError(error.MissingIdentity, start(null, .{}, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .state_root = "/state",
        .cwd = "/work",
        .writer_version = "test",
    }));
}

const test_uuid = [_]u8{
    0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
    0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x01,
};

fn materializeTestSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    cwd: []const u8,
    uuid: [16]u8,
    text: []const u8,
) ![]u8 {
    var log_value = try persistence.SessionFile.Log.prepare(allocator, io, .{
        .state_root = root,
        .cwd = cwd,
        .selection = .{ .provider = "recorded", .model = "old" },
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = uuid,
        .writer_version = "test",
    });
    defer log_value.deinit();
    const item = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast(text) } },
    };
    try log_value.appendSnapshot(0, &item);
    return allocator.dupe(u8, log_value.path());
}

test "picker candidates transfer the accepted index into resolved" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try materializeTestSession(allocator, io, root, "/work", test_uuid, "picked");
    defer allocator.free(path);
    const result = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .select,
        .cutoff_epoch_seconds = 0,
    });
    const candidates = result.candidates;
    try std.testing.expectEqual(@as(usize, 1), candidates.entries().len);
    const selected = try candidates.resolve(io, .standard, 0);
    defer selected.deinit();
    try std.testing.expectEqualStrings(path, selected.path());
}

test "resolve is cwd isolated and accepts an exact or unique prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try materializeTestSession(allocator, io, root, "/one", test_uuid, "one");
    defer allocator.free(path);
    var other_uuid = test_uuid;
    other_uuid[15] = 2;
    const other_path = try materializeTestSession(allocator, io, root, "/two", other_uuid, "two");
    defer allocator.free(other_path);

    const missing_cwd = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/missing",
        .resume_state = .latest,
        .cutoff_epoch_seconds = 0,
    });
    try std.testing.expect(missing_cwd == .not_found);

    const full_id = "550e8400-e29b-41d4-a716-446655440001";
    var exact = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/one",
        .resume_state = .{ .id = full_id },
        .cutoff_epoch_seconds = 0,
    });
    defer exact.found.deinit();
    try std.testing.expectEqualStrings(path, exact.found.path());
    try std.testing.expectEqualStrings("recorded", exact.found.selection().provider.?);

    var prefix = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/one",
        .resume_state = .{ .id = "550e8400" },
        .cutoff_epoch_seconds = 0,
    });
    defer prefix.found.deinit();
    try std.testing.expectEqualStrings(full_id, prefix.found.id().?);
}

test "takeLog transfers ownership once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const run = try start(null, .{ .provider = "p" }, .{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .new_identity = .{ .timestamp = .{ .epoch_seconds = 0 }, .uuid = test_uuid },
        .writer_version = "test",
    });
    defer run.deinit();

    var moved = run.takeLog();
    defer if (moved) |*log_value| log_value.deinit();
    try std.testing.expect(moved != null);
    try std.testing.expect(run.takeLog() == null);
    try std.testing.expect(!run.recordingAvailable());
}

test "new recording is lazy and caller materialization creates mode 0600" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const run = try start(null, .{ .provider = "p" }, .{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .new_identity = .{ .timestamp = .{ .epoch_seconds = 0 }, .uuid = test_uuid },
        .writer_version = "test",
    });
    defer run.deinit();
    try std.testing.expect(!run.materialized());
    try run.session().appendCopy(&.{ .user_message = .{ .text = @constCast("hello") } });
    try run.log().?.appendSnapshot(0, run.session().items());
    try std.testing.expect(run.materialized());
    const stat = try std.Io.Dir.statFile(.cwd(), io, run.log().?.path(), .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "resume no-session loads history without opening an append log" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try materializeTestSession(allocator, io, root, "/work", test_uuid, "old");
    defer allocator.free(path);
    const resolution = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .latest,
        .cutoff_epoch_seconds = 0,
    });
    const run = try start(resolution.found, .{ .provider = "final", .model = "new" }, .{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .no_session = true,
        .writer_version = "test",
    });
    defer run.deinit();
    try std.testing.expectEqual(@as(usize, 1), run.session().items().len);
    try std.testing.expect(!run.recordingAvailable());
    try std.testing.expectEqualStrings("final", run.session().currentSelection().provider_id.?);
    try std.testing.expect(run.resumeHint() == null);
}

test "busy resume keeps loaded session and warns that recording is unavailable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try materializeTestSession(allocator, io, root, "/work", test_uuid, "old");
    defer allocator.free(path);
    const resolution = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .latest,
        .cutoff_epoch_seconds = 0,
    });
    const blocker = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer blocker.close(io);
    try blocker.lock(io, .shared);
    defer blocker.unlock(io);

    const run = try start(resolution.found, .{ .provider = "final" }, .{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .writer_version = "test",
    });
    defer run.deinit();
    try std.testing.expectEqual(@as(usize, 1), run.session().items().len);
    try std.testing.expect(run.warning().? == .resume_append_unavailable);
    try std.testing.expectEqualStrings(path, run.warning().?.resume_append_unavailable);
    try std.testing.expect(path.ptr != run.warning().?.resume_append_unavailable.ptr);
    try std.testing.expect(!run.recordingAvailable());
    try std.testing.expect(run.resumeHint() == null);
}

fn exerciseFreshStartAllocationFailures(allocator: std.mem.Allocator) !void {
    const run = try start(null, .{ .provider = "provider", .model = "model" }, .{
        .allocator = allocator,
        .io = std.testing.io,
        .state_root = null,
        .cwd = "/work",
        .no_session = true,
        .writer_version = "test",
    });
    defer run.deinit();
    try std.testing.expectEqualStrings("provider", run.session().currentSelection().provider_id.?);
}

test "fresh run construction releases every allocation on OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFreshStartAllocationFailures,
        .{},
    );
}

const FailingTouch = struct {
    called: bool = false,

    fn touch(self: *FailingTouch, _: std.Io, _: []const u8) persistence.SessionFile.TouchError!void {
        self.called = true;
        return error.IoFailure;
    }
};

test "resolve ignores injected touch failure exactly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try materializeTestSession(allocator, io, root, "/work", test_uuid, "old");
    defer allocator.free(path);
    var failing: FailingTouch = .{};
    var resolution = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .latest,
        .cutoff_epoch_seconds = 0,
        .toucher = Toucher.from(&failing),
    });
    defer resolution.found.deinit();
    try std.testing.expect(failing.called);
    try std.testing.expectEqualStrings(path, resolution.found.path());
}

test "resume adopts caller session limits rather than file limits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try materializeTestSession(allocator, io, root, "/work", test_uuid, "old");
    defer allocator.free(path);
    const resolution = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .latest,
        .cutoff_epoch_seconds = 0,
    });
    const run = try start(resolution.found, .{}, .{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .no_session = true,
        .writer_version = "test",
        .session_limits = .{ .items = 1 },
    });
    defer run.deinit();
    try std.testing.expectError(error.TooManyItems, run.session().addBoundary());
}

test "fresh prepare degradation is silent and has no resume hint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const run = try start(null, .{}, .{
        .allocator = allocator,
        .io = io,
        .state_root = "relative",
        .cwd = "/work",
        .new_identity = .{ .timestamp = .{ .epoch_seconds = 0 }, .uuid = test_uuid },
        .writer_version = "test",
    });
    defer run.deinit();
    try std.testing.expect(run.warning() == null);
    try std.testing.expect(!run.recordingAvailable());
    try std.testing.expect(run.resumeHint() == null);
}

test "resolution reports ambiguous prefixes and honors the strict cutoff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const first = try materializeTestSession(allocator, io, root, "/work", test_uuid, "one");
    defer allocator.free(first);
    var second_uuid = test_uuid;
    second_uuid[15] = 2;
    const second = try materializeTestSession(allocator, io, root, "/work", second_uuid, "two");
    defer allocator.free(second);

    try std.testing.expect((try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .{ .id = "550e8400" },
        .cutoff_epoch_seconds = 0,
    })) == .ambiguous);
    try std.testing.expect((try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .latest,
        .cutoff_epoch_seconds = std.math.maxInt(i64),
    })) == .not_found);
}

test "resume load failure is fatal and leaves resolution ownership with caller" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try materializeTestSession(allocator, io, root, "/work", test_uuid, "old");
    defer allocator.free(path);
    var resolution = try resolve(.{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .resume_state = .latest,
        .cutoff_epoch_seconds = 0,
    });
    defer resolution.found.deinit();
    try std.testing.expectError(error.FileTooLarge, start(resolution.found, .{}, .{
        .allocator = allocator,
        .io = io,
        .state_root = root,
        .cwd = "/work",
        .writer_version = "test",
        .file_limits = .{ .max_file_bytes = 1, .max_line_bytes = 1 },
    }));
}
