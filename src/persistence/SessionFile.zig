const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const ItemJson = @import("ItemJson.zig");
const NativeIdentity = @import("NativeIdentity.zig");
const Paths = @import("Paths.zig");
const SessionCut = @import("SessionCut.zig");

pub const format_version: u32 = 1;
pub const maximum_selection_field_bytes: usize = 64 * 1024;
pub const maximum_selection_bytes: usize = 256 * 1024;
pub const maximum_writer_version_bytes: usize = 128;

pub const Selection = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_label: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    preset: ?[]const u8 = null,
};

pub const GitState = struct {
    branch: ?[]u8 = null,
    commit: ?[]u8 = null,
    subject: ?[]u8 = null,

    pub fn deinit(self: *GitState, allocator: std.mem.Allocator) void {
        if (self.branch) |value| allocator.free(value);
        if (self.commit) |value| allocator.free(value);
        if (self.subject) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Borrowed lazy collaborator. Its context must outlive the Log, including
/// resets. Returned slices must use the supplied allocator and each field must
/// be bounded, valid UTF-8 without NUL, and owned by that allocator.
pub const GitProbe = struct {
    context: *anyopaque,
    probe_fn: *const fn (
        allocator: std.mem.Allocator,
        io: std.Io,
        context: *anyopaque,
        cwd: []const u8,
    ) error{ OutOfMemory, Cancelled, Unavailable }!GitState,

    pub fn probe(
        self: GitProbe,
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
    ) error{ OutOfMemory, Cancelled, Unavailable }!GitState {
        return self.probe_fn(allocator, io, self.context, cwd);
    }

    pub fn from(implementation: anytype) GitProbe {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("GitProbe.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn probeFn(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                cwd: []const u8,
            ) error{ OutOfMemory, Cancelled, Unavailable }!GitState {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.probe(allocator, io, self, cwd);
            }
        };
        return .{ .context = implementation, .probe_fn = Adapter.probeFn };
    }
};

pub const Meta = struct {
    id: ?[]u8 = null,
    timestamp: ?[]u8 = null,
    cwd: ?[]u8 = null,
    selection: OwnedSelection = .{},
    git_branch: ?[]u8 = null,
    git_commit: ?[]u8 = null,
    git_subject: ?[]u8 = null,

    pub fn deinit(self: *Meta, allocator: std.mem.Allocator) void {
        if (self.id) |value| allocator.free(value);
        if (self.timestamp) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        self.selection.deinit(allocator);
        if (self.git_branch) |value| allocator.free(value);
        if (self.git_commit) |value| allocator.free(value);
        if (self.git_subject) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Limits = struct {
    max_file_bytes: usize = 8 * 1024 * 1024,
    max_line_bytes: usize = 8 * 1024 * 1024,
    max_items: usize = 4096,
    retained_bytes: usize = 64 * 1024 * 1024,
    max_images: usize = 256,
    max_image_base64_bytes: usize = 256 * 1024 * 1024,
    paths: Paths.Limits = .{},
    item_json: ItemJson.Limits = .{},
};

pub const Recovery = struct {
    malformed_lines: usize = 0,
    unknown_records: usize = 0,
    torn_tail_lines: usize = 0,
    dangling_tool_calls_removed: usize = 0,
    images_degraded: usize = 0,
};

pub const Loaded = struct {
    pub const Parts = struct {
        session: agent.Session.Session,
        meta: Meta,
        recovery: Recovery,
    };

    session: agent.Session.Session,
    meta: Meta,
    last_selection: OwnedSelection,
    item_high_water: usize,
    recovery: Recovery,

    pub fn deinit(self: *Loaded) void {
        const allocator = self.session.allocator;
        self.session.deinit();
        self.meta.deinit(allocator);
        self.last_selection.deinit(allocator);
        self.* = undefined;
    }

    /// Moves the session and metadata out while releasing loader-only selection state.
    pub fn takeParts(self: *Loaded) Parts {
        const allocator = self.session.allocator;
        const parts: Parts = .{
            .session = self.session,
            .meta = self.meta,
            .recovery = self.recovery,
        };
        self.last_selection.deinit(allocator);
        self.* = undefined;
        return parts;
    }
};

/// Move-only result of an atomic resume open. `log` retains the exclusive
/// lock acquired before `loaded` was read, so its append offset and high-water
/// mark describe that exact snapshot.
pub const ResumeLoaded = struct {
    loaded: Loaded,
    log: Log,

    pub fn deinit(self: *ResumeLoaded) void {
        self.log.deinit();
        self.loaded.deinit();
        self.* = undefined;
    }
};

/// `state_root` and its existing parents are trusted private configuration.
/// New descendants are created with owner-only permissions.
pub const PrepareOptions = struct {
    state_root: []const u8,
    cwd: []const u8,
    selection: Selection,
    timestamp: Paths.Timestamp,
    uuid: [16]u8,
    writer_version: []const u8,
    git_probe: ?GitProbe = null,
    limits: Limits = .{},
};

/// `path` and all parent components must come from a trusted, private state
/// root. `loaded_item_count` must be the high-water value returned by `load`.
pub const ResumeOptions = struct {
    path: []const u8,
    selection: Selection,
    loaded_item_count: usize,
    limits: Limits = .{},
};

pub const TouchError = error{
    Canceled,
    Busy,
    InvalidPath,
    PathTooLong,
    NotRegular,
    Removed,
    IoFailure,
};

pub const MutationDurability = enum { synced, sync_failed };
pub const FileIdentity = NativeIdentity.Identity;

/// Allocation-free authority retained only by a locked resume candidate until
/// its one post-publication privacy check succeeds.
pub const StatToken = struct {
    device: u64,
    inode: std.Io.File.INode,
    nlink: std.Io.File.NLink,
    size: u64,
    kind: std.Io.File.Kind,
    mtime_nanoseconds: i96,
    ctime_nanoseconds: i96,

    fn init(identity: NativeIdentity.Identity, stat: std.Io.File.Stat) StatToken {
        return .{
            .device = identity.device,
            .inode = identity.inode,
            .nlink = stat.nlink,
            .size = stat.size,
            .kind = stat.kind,
            .mtime_nanoseconds = stat.mtime.nanoseconds,
            .ctime_nanoseconds = stat.ctime.nanoseconds,
        };
    }

    fn matches(self: StatToken, identity: NativeIdentity.Identity, stat: std.Io.File.Stat) bool {
        return self.device == identity.device and self.inode == identity.inode and
            self.inode == stat.inode and self.nlink == stat.nlink and self.size == stat.size and
            self.kind == stat.kind and self.mtime_nanoseconds == stat.mtime.nanoseconds and
            self.ctime_nanoseconds == stat.ctime.nanoseconds;
    }

    fn matchesPrivate(self: StatToken, identity: NativeIdentity.Identity, stat: std.Io.File.Stat) bool {
        return self.device == identity.device and self.inode == identity.inode and
            self.inode == stat.inode and self.nlink == stat.nlink and self.size == stat.size and
            self.kind == stat.kind and self.mtime_nanoseconds == stat.mtime.nanoseconds and
            stat.permissions.toMode() & 0o777 == 0o600;
    }
};

/// Move-only verified source snapshot for one truncate or future fork.
pub const PreparedCut = struct {
    owner: *Log,
    generation: u64,
    allocator: std.mem.Allocator,
    plan: SessionCut.Plan,
    opened_identity: FileIdentity,
    named_identity: FileIdentity,
    link_count: u64,
    original_size: u64,
    stat_token: StatToken,
    original_bytes: []u8,
    selection_pending_after_cut: bool,
    active: bool = true,

    pub fn deinit(self: *PreparedCut) void {
        if (self.active) self.allocator.free(self.original_bytes);
        self.* = undefined;
    }
};

pub const TruncateUnchanged = enum { set_length_failed_verified_original };

pub const TruncateIndeterminate = enum {
    changed,
    removed,
    replaced,
    unreadable,
    content_mismatch,
};

pub const TruncateOutcome = union(enum) {
    unchanged: TruncateUnchanged,
    committed: struct {
        durability: MutationDurability,
        retained_items: usize,
    },
    indeterminate: TruncateIndeterminate,
};

pub const CutError = error{
    OutOfMemory,
    InvalidPlan,
    FileTooLarge,
    LineTooLarge,
    TooManyItems,
    Poisoned,
    IoFailure,
    NotRegular,
    Removed,
};

pub const TruncateError = error{
    OutOfMemory,
    InvalidPlan,
    FileTooLarge,
    LineTooLarge,
    TooManyItems,
    Poisoned,
    IoFailure,
    NotRegular,
    Removed,
    StaleCut,
    HighWaterMismatch,
};

pub const AppendFailure = enum {
    path_collision,
    lock_failed_after_create,
    identity_changed,
    partial_write,
    verification_failed,
    cleanup_indeterminate,
};

pub const AppendOutcome = union(enum) {
    unchanged,
    committed: MutationDurability,
    indeterminate: AppendFailure,
};

/// Failures proven before append bytes may have changed.
pub const AppendError = error{
    OutOfMemory,
    InvalidPath,
    InvalidSelection,
    InvalidHeader,
    FileTooLarge,
    LineTooLarge,
    TooManyItems,
    HighWaterMismatch,
    Poisoned,
    Cancelled,
    IoFailure,
    NotRegular,
    Removed,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    InvalidPath,
    PathTooLong,
    InvalidSelection,
    InvalidHeader,
    UnsupportedVersion,
    FileTooLarge,
    LineTooLarge,
    TooManyItems,
    ResourceLimit,
    NotRegular,
    Removed,
    SessionBusy,
    HighWaterMismatch,
    Poisoned,
    Cancelled,
    Unavailable,
    IoFailure,
    /// A failed fork could not prove deletion of its deterministic target path.
    IndeterminateCleanup,
};

pub const OwnedSelection = struct {
    provider: ?[]u8 = null,
    model: ?[]u8 = null,
    model_label: ?[]u8 = null,
    effort: ?[]u8 = null,
    preset: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, value: Selection) !OwnedSelection {
        try validateSelection(value);
        var result: OwnedSelection = .{};
        errdefer result.deinit(allocator);
        result.provider = try dupeOptional(allocator, value.provider);
        result.model = try dupeOptional(allocator, value.model);
        result.model_label = try dupeOptional(allocator, value.model_label);
        result.effort = try dupeOptional(allocator, value.effort);
        result.preset = try dupeOptional(allocator, nonEmpty(value.preset));
        return result;
    }

    fn clone(self: OwnedSelection, allocator: std.mem.Allocator) !OwnedSelection {
        return init(allocator, self.borrow());
    }

    pub fn borrow(self: OwnedSelection) Selection {
        return .{
            .provider = self.provider,
            .model = self.model,
            .model_label = self.model_label,
            .effort = self.effort,
            .preset = self.preset,
        };
    }

    fn deinit(self: *OwnedSelection, allocator: std.mem.Allocator) void {
        if (self.provider) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        if (self.model_label) |value| allocator.free(value);
        if (self.effort) |value| allocator.free(value);
        if (self.preset) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Move-only log selection replacement prepared without changing the log.
pub const PreparedSelection = struct {
    owner: *Log,
    generation: u64,
    allocator: std.mem.Allocator,
    replacement: ?OwnedSelection,
    core_changed: bool,
    active: bool = true,

    pub fn deinit(self: *PreparedSelection) void {
        if (self.active) if (self.replacement) |*replacement| replacement.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Move-only log selection strings displaced by publication.
pub const RetiredSelection = struct {
    allocator: std.mem.Allocator,
    selection: ?OwnedSelection,
    active: bool = true,

    pub fn deinit(self: *RetiredSelection) void {
        if (self.active) if (self.selection) |*selection| selection.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Move-only selection displaced while the old branch receives terminal notes.
pub const TransitionSelection = struct {
    generation: u64,
    allocator: std.mem.Allocator,
    selection: ?OwnedSelection,
    restored: bool = false,
    active: bool = true,

    pub fn deinit(self: *TransitionSelection) void {
        if (self.active) if (self.selection) |*selection| selection.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Owns a lazy or resumed append writer. A materialized Log holds an exclusive
/// lifetime lock. This deliberately narrows hax's shared writer lock because
/// std.Io has no O_APPEND open option; exclusive ownership makes positional
/// append safe and returns SessionBusy instead of admitting a second writer.
pub const Log = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: Limits,
    state_root: ?[]u8,
    cwd: ?[]u8,
    path_value: []u8,
    id: ?[]u8,
    timestamp: ?[]u8,
    writer_version: ?[]u8,
    selection: OwnedSelection,
    git_probe: ?GitProbe,
    commit_fn: *const fn (std.Io, std.Io.File, []const u8, u64) error{IoFailure}!void = commitAll,
    append_sync_file_fn: *const fn (std.Io, std.Io.File) error{IoFailure}!void = syncFile,
    append_delete_fn: *const fn (std.Io, []const u8) error{IoFailure}!void = deleteForkTarget,
    append_sync_directory_fn: *const fn (std.Io, []const u8) error{IoFailure}!void = syncParentDirectory,
    set_length_fn: *const fn (std.Io, std.Io.File, u64) error{IoFailure}!void = setLength,
    truncate_post_fn: *const fn (*Log, std.Io.File) void = noTruncatePost,
    set_permissions_fn: *const fn (std.Io, std.Io.File) error{IoFailure}!void = setPrivatePermissions,
    opened_identity_fn: *const fn (std.Io.File) error{IoFailure}!NativeIdentity.Identity = NativeIdentity.opened,
    named_identity_fn: *const fn (std.Io, []const u8) error{IoFailure}!NativeIdentity.Identity = NativeIdentity.named,
    fork_verify_fn: *const fn (
        std.Io,
        std.Io.File,
        std.Io.File.Stat,
        []const u8,
    ) error{IoFailure}!void = verifySnapshot,
    fork_delete_fn: *const fn (std.Io, []const u8) error{IoFailure}!void = deleteForkTarget,
    fork_sync_directory_fn: *const fn (std.Io, []const u8) error{IoFailure}!void = syncParentDirectory,
    read_effective_selection_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        std.Io.File,
        Limits,
    ) Error!OwnedSelection = readEffectiveSelectionOpened,
    file: ?std.Io.File = null,
    append_offset: u64 = 0,
    header_written: bool = false,
    selection_pending: bool = false,
    separator_pending: bool = false,
    selection_generation: u64 = 0,
    written_items: usize = 0,
    poisoned: bool = false,
    mutation_generation: u64 = 0,
    verified_snapshot: ?StatToken = null,

    pub fn prepare(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: PrepareOptions,
    ) Error!Log {
        try validateLimits(options.limits);
        if (options.writer_version.len == 0 or
            options.writer_version.len > maximum_writer_version_bytes or
            !std.unicode.utf8ValidateSlice(options.writer_version))
        {
            return error.InvalidHeader;
        }
        if (!safeAbsolutePath(options.state_root)) return error.InvalidPath;
        validateSelection(options.selection) catch return error.InvalidSelection;
        const directory_length = Paths.sessionDirectoryLength(
            options.state_root,
            options.cwd,
            options.limits.paths,
        ) catch |err| return mapPath(err);
        const name = Paths.canonicalName(options.timestamp, options.uuid) catch |err| return mapPath(err);
        const session_path_length = std.math.add(
            usize,
            directory_length,
            1 + Paths.canonical_name_bytes,
        ) catch return error.PathTooLong;
        if (session_path_length > options.limits.paths.max_path_bytes or
            session_path_length >= std.fs.max_path_bytes)
        {
            return error.PathTooLong;
        }

        var selection = OwnedSelection.init(allocator, options.selection) catch |err| return mapAlloc(err);
        errdefer selection.deinit(allocator);
        const directory = Paths.sessionDirectory(
            allocator,
            options.state_root,
            options.cwd,
            options.limits.paths,
        ) catch |err| return mapPath(err);
        defer allocator.free(directory);
        std.debug.assert(directory.len == directory_length);
        const session_path = try joinPath(
            allocator,
            directory,
            &name,
            options.limits.paths.max_path_bytes,
        );
        errdefer allocator.free(session_path);
        std.debug.assert(session_path.len == session_path_length);
        const id = allocator.dupe(u8, name[21..57]) catch return error.OutOfMemory;
        errdefer allocator.free(id);
        const timestamp_array = Paths.headerTimestamp(options.timestamp) catch |err| return mapPath(err);
        const timestamp = allocator.dupe(u8, &timestamp_array) catch return error.OutOfMemory;
        errdefer allocator.free(timestamp);
        const root_copy = allocator.dupe(u8, options.state_root) catch return error.OutOfMemory;
        errdefer allocator.free(root_copy);
        const cwd_copy = allocator.dupe(u8, options.cwd) catch return error.OutOfMemory;
        errdefer allocator.free(cwd_copy);
        const version = allocator.dupe(u8, options.writer_version) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .io = io,
            .limits = options.limits,
            .state_root = root_copy,
            .cwd = cwd_copy,
            .path_value = session_path,
            .id = id,
            .timestamp = timestamp,
            .writer_version = version,
            .selection = selection,
            .git_probe = options.git_probe,
        };
    }

    pub fn resumeExisting(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: ResumeOptions,
    ) Error!Log {
        try validateLimits(options.limits);
        if (options.loaded_item_count > options.limits.max_items) return error.TooManyItems;
        if (!safeAbsolutePath(options.path)) return error.InvalidPath;
        try validateIoPathLength(options.path, options.limits.paths.max_path_bytes);
        var selection = OwnedSelection.init(allocator, options.selection) catch |err| return mapAlloc(err);
        errdefer selection.deinit(allocator);
        const session_path = allocator.dupe(u8, options.path) catch return error.OutOfMemory;
        errdefer allocator.free(session_path);
        const file = std.Io.Dir.openFile(.cwd(), io, session_path, .{
            .mode = .read_write,
            .follow_symlinks = false,
        }) catch return error.IoFailure;
        errdefer file.close(io);
        const locked = file.tryLock(io, .exclusive) catch return error.IoFailure;
        if (!locked) return error.SessionBusy;
        const stat = file.stat(io) catch return error.IoFailure;
        if (stat.kind != .file) return error.NotRegular;
        if (stat.nlink == 0) return error.Removed;
        if (stat.size > options.limits.max_file_bytes) return error.FileTooLarge;
        const id = try readStoredSessionId(allocator, io, file, stat.size, options.limits);
        errdefer if (id) |value| allocator.free(value);
        var append_offset = stat.size;
        if (stat.size != 0) {
            var last: [1]u8 = undefined;
            const read = file.readPositionalAll(io, &last, stat.size - 1) catch return error.IoFailure;
            if (read != 1) return error.IoFailure;
            if (last[0] != '\n') {
                if (stat.size >= options.limits.max_file_bytes) return error.FileTooLarge;
                file.writePositionalAll(io, "\n", stat.size) catch return error.IoFailure;
                append_offset += 1;
            }
        }
        file.setPermissions(io, .fromMode(0o600)) catch return error.IoFailure;
        return .{
            .allocator = allocator,
            .io = io,
            .limits = options.limits,
            .state_root = null,
            .cwd = null,
            .path_value = session_path,
            .id = id,
            .timestamp = null,
            .writer_version = null,
            .selection = selection,
            .git_probe = null,
            .file = file,
            .append_offset = append_offset,
            .header_written = true,
            .written_items = options.loaded_item_count,
        };
    }

    pub fn deinit(self: *Log) void {
        if (self.file) |file| file.close(self.io);
        if (self.state_root) |value| self.allocator.free(value);
        if (self.cwd) |value| self.allocator.free(value);
        self.allocator.free(self.path_value);
        if (self.id) |value| self.allocator.free(value);
        if (self.timestamp) |value| self.allocator.free(value);
        if (self.writer_version) |value| self.allocator.free(value);
        self.selection.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn path(self: *const Log) []const u8 {
        return self.path_value;
    }

    /// Returns a borrowed stable ID suitable for a resume banner. The slice
    /// remains valid until `deinit`. Stored header identity wins over the
    /// canonical filename identity.
    pub fn resumeHint(self: *const Log) ?[]const u8 {
        if (self.id) |id| return id;
        const name = std.fs.path.basename(self.path_value);
        if (!Paths.isCanonicalName(name)) return null;
        return name[21..57];
    }

    /// Verifies the exact locked resume snapshot, then tightens and verifies
    /// its permissions. Success consumes the one-shot snapshot token. Failure
    /// retains the descriptor and token for the durability owner to drop.
    pub fn tightenPrivate(self: *Log) Error!void {
        const file = self.file orelse return error.Unavailable;
        const token = self.verified_snapshot orelse return error.Unavailable;
        if (!self.matchesVerifiedSnapshot(file, token, false)) return error.IoFailure;
        self.set_permissions_fn(self.io, file) catch return error.IoFailure;
        if (!self.matchesVerifiedSnapshot(file, token, true)) return error.IoFailure;
        self.verified_snapshot = null;
    }

    fn matchesVerifiedSnapshot(
        self: *Log,
        file: std.Io.File,
        token: StatToken,
        private: bool,
    ) bool {
        const opened_stat = file.stat(self.io) catch return false;
        const opened_identity = self.opened_identity_fn(file) catch return false;
        const named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return false;
        const named_identity = self.named_identity_fn(self.io, self.path_value) catch return false;
        if (private) {
            return token.matchesPrivate(opened_identity, opened_stat) and
                token.matchesPrivate(named_identity, named_stat);
        }
        return token.matches(opened_identity, opened_stat) and token.matches(named_identity, named_stat);
    }

    pub fn materialized(self: *const Log) bool {
        return self.header_written;
    }

    pub fn highWater(self: *const Log) usize {
        return self.written_items;
    }

    pub fn hasPendingSelection(self: *const Log) bool {
        return self.selection_pending;
    }

    /// Returns the configured selection borrowed until setSelection or deinit.
    pub fn currentSelection(self: *const Log) Selection {
        return self.selection.borrow();
    }

    pub fn appendSnapshot(
        self: *Log,
        start_index: usize,
        items: []const ai.Item.Item,
    ) Error!void {
        const outcome = try self.appendSnapshotClassified(start_index, items);
        switch (outcome) {
            .unchanged => if (start_index != items.len) return error.IoFailure,
            .committed => |durability| if (durability == .sync_failed) return error.IoFailure,
            .indeterminate => return error.IoFailure,
        }
    }

    /// Appends a prepared snapshot while separating pre-mutation errors from
    /// verified unchanged, committed, and indeterminate write outcomes.
    pub fn appendSnapshotClassified(
        self: *Log,
        start_index: usize,
        items: []const ai.Item.Item,
    ) AppendError!AppendOutcome {
        if (self.poisoned) return error.Poisoned;
        if (start_index != self.written_items or start_index > items.len) return error.HighWaterMismatch;
        if (start_index == items.len and (!self.header_written or !self.selection_pending)) return .unchanged;
        if (items.len > self.limits.max_items) return error.TooManyItems;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        if (self.separator_pending) output.writer.writeByte('\n') catch return error.OutOfMemory;
        if (!self.header_written) {
            try self.encodeHeader(&output.writer);
            if (output.written().len > self.limits.max_file_bytes) return error.FileTooLarge;
        }
        if (self.header_written and self.selection_pending) {
            try encodeSelection(&output.writer, self.selection.borrow(), self.limits.max_line_bytes);
            if (output.written().len > self.limits.max_file_bytes) return error.FileTooLarge;
        }
        for (items[start_index..]) |item| {
            const line = ItemJson.encode(self.allocator, item, self.limits.item_json) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LineTooLarge => return error.LineTooLarge,
                else => return error.InvalidSelection,
            };
            defer self.allocator.free(line);
            if (line.len > self.limits.max_line_bytes) return error.LineTooLarge;
            const record_bytes = std.math.add(usize, line.len, 1) catch return error.FileTooLarge;
            if (record_bytes > self.limits.max_file_bytes -| output.written().len) return error.FileTooLarge;
            output.writer.writeAll(line) catch return error.OutOfMemory;
            output.writer.writeByte('\n') catch return error.OutOfMemory;
        }
        if (output.written().len > self.limits.max_file_bytes) return error.FileTooLarge;

        const was_materialized = self.file != null;
        if (!was_materialized) {
            if (try self.ensureFileClassified()) |outcome| return outcome;
        }
        const file = self.file.?;
        const initial_stat = file.stat(self.io) catch {
            if (!was_materialized) return self.cleanupCreatedOrIndeterminate(.verification_failed);
            return error.IoFailure;
        };
        if (initial_stat.kind != .file or initial_stat.nlink == 0 or
            !self.namedFileMatches(initial_stat) or initial_stat.size != self.append_offset)
        {
            self.poison();
            if (!was_materialized) return .{ .indeterminate = .identity_changed };
            return error.Poisoned;
        }
        const old_size = std.math.cast(usize, initial_stat.size) orelse return error.FileTooLarge;
        if (output.written().len > self.limits.max_file_bytes -| old_size) return error.FileTooLarge;
        const old_bytes = self.allocator.alloc(u8, old_size) catch return error.OutOfMemory;
        defer self.allocator.free(old_bytes);
        if (old_size != 0) {
            const read = file.readPositionalAll(self.io, old_bytes, 0) catch return error.IoFailure;
            if (read != old_size) return error.IoFailure;
        }
        const stable_stat = file.stat(self.io) catch {
            if (!was_materialized) return self.cleanupCreatedOrIndeterminate(.verification_failed);
            return error.IoFailure;
        };
        if (!sameSnapshotStat(initial_stat, stable_stat) or !self.namedFileMatches(stable_stat)) {
            self.poison();
            if (!was_materialized) return .{ .indeterminate = .identity_changed };
            return error.Poisoned;
        }

        self.commit_fn(self.io, file, output.written(), self.append_offset) catch {
            return self.classifyFailedAppend(
                initial_stat,
                old_bytes,
                output.written(),
                items.len,
                !was_materialized,
            );
        };
        return self.classifyPopulatedAppend(
            initial_stat,
            old_bytes,
            output.written(),
            items.len,
        );
    }

    /// Captures one exact bounded snapshot through the retained locked descriptor.
    pub fn prepareCut(self: *Log, retained_typed_turns: usize) CutError!PreparedCut {
        const file = self.file orelse return error.InvalidPlan;
        if (self.poisoned) return error.Poisoned;
        const initial_stat = file.stat(self.io) catch return error.IoFailure;
        if (initial_stat.kind != .file) return error.NotRegular;
        if (initial_stat.nlink == 0) return error.Removed;
        if (initial_stat.size > self.limits.max_file_bytes) return error.FileTooLarge;
        if (initial_stat.size != self.append_offset) return error.InvalidPlan;
        const opened_identity = self.opened_identity_fn(file) catch return error.IoFailure;
        const named_identity = self.named_identity_fn(self.io, self.path_value) catch return error.IoFailure;
        if (!opened_identity.eql(named_identity)) return error.InvalidPlan;
        const named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return error.IoFailure;
        const token = StatToken.init(opened_identity, initial_stat);
        if (!token.matches(named_identity, named_stat)) return error.InvalidPlan;

        const size: usize = std.math.cast(usize, initial_stat.size) orelse return error.FileTooLarge;
        const original_bytes = self.allocator.alloc(u8, size) catch return error.OutOfMemory;
        errdefer self.allocator.free(original_bytes);
        if (size != 0) {
            const read = file.readPositionalAll(self.io, original_bytes, 0) catch return error.IoFailure;
            if (read != size) return error.IoFailure;
        }
        const value = SessionCut.plan(self.allocator, original_bytes, retained_typed_turns, .{
            .max_file_bytes = self.limits.max_file_bytes,
            .max_line_bytes = self.limits.max_line_bytes,
            .max_tokens = self.limits.item_json.max_tokens,
            .max_nesting = self.limits.item_json.max_nesting,
            .max_turns = self.limits.max_items,
        }) catch |err| return mapCutForPlan(err);
        if (value.original_size != initial_stat.size or value.cut_offset > value.original_size) {
            return error.InvalidPlan;
        }
        var effective = effectiveSelectionFromBytes(
            self.allocator,
            original_bytes[0..@intCast(value.cut_offset)],
            self.limits,
        ) catch |err| return mapCutSelectionError(err);
        defer effective.deinit(self.allocator);

        const stable_stat = file.stat(self.io) catch return error.IoFailure;
        const stable_opened = self.opened_identity_fn(file) catch return error.IoFailure;
        const stable_named = self.named_identity_fn(self.io, self.path_value) catch return error.IoFailure;
        const stable_named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return error.IoFailure;
        if (!token.matches(stable_opened, stable_stat) or
            !token.matches(stable_named, stable_named_stat) or
            !opened_identity.eql(stable_named))
        {
            return error.InvalidPlan;
        }
        return .{
            .owner = self,
            .generation = self.mutation_generation,
            .allocator = self.allocator,
            .plan = value,
            .opened_identity = opened_identity,
            .named_identity = named_identity,
            .link_count = @intCast(initial_stat.nlink),
            .original_size = initial_stat.size,
            .stat_token = token,
            .original_bytes = original_bytes,
            .selection_pending_after_cut = !selectionEqual(effective.borrow(), self.selection.borrow()),
        };
    }

    /// Performs an authoritative truncate. Once setLength starts this function
    /// returns only a classified outcome and performs no allocation.
    pub fn truncatePrepared(
        self: *Log,
        prepared: *PreparedCut,
        retained_items: usize,
    ) TruncateError!TruncateOutcome {
        if (self.poisoned) return error.Poisoned;
        if (!prepared.active or prepared.owner != self or
            prepared.allocator.ptr != self.allocator.ptr or
            prepared.allocator.vtable != self.allocator.vtable or
            prepared.generation != self.mutation_generation)
        {
            return error.StaleCut;
        }
        if (retained_items > self.limits.max_items) return error.TooManyItems;
        if (retained_items != prepared.plan.retained_item_records or
            prepared.original_size != self.append_offset)
        {
            return error.HighWaterMismatch;
        }
        if (prepared.plan.original_size != prepared.original_size or
            prepared.plan.cut_offset >= prepared.original_size)
        {
            return error.InvalidPlan;
        }
        const file = self.file orelse return error.InvalidPlan;
        try self.validatePreparedCut(file, prepared);

        prepared.active = false;
        defer {
            prepared.allocator.free(prepared.original_bytes);
            prepared.original_bytes = &.{};
        }
        const set_length_failed = failed: {
            self.set_length_fn(self.io, file, prepared.plan.cut_offset) catch break :failed true;
            break :failed false;
        };
        self.truncate_post_fn(self, file);
        const classification = self.classifyTruncate(file, prepared);
        switch (classification) {
            .original => {
                if (!set_length_failed) {
                    self.poison();
                    return .{ .indeterminate = .changed };
                }
                return .{ .unchanged = .set_length_failed_verified_original };
            },
            .retained => {
                self.append_offset = prepared.plan.cut_offset;
                self.written_items = retained_items;
                self.selection_pending = prepared.selection_pending_after_cut;
                self.mutation_generation +%= 1;
                var durability: MutationDurability = .synced;
                self.append_sync_file_fn(self.io, file) catch {
                    durability = .sync_failed;
                };
                if (durability == .sync_failed) self.poison();
                return .{ .committed = .{
                    .durability = durability,
                    .retained_items = retained_items,
                } };
            },
            .indeterminate => |reason| {
                self.poison();
                return .{ .indeterminate = reason };
            },
        }
    }

    /// Backward-compatible wrapper used by the legacy fork/truncate tests.
    pub fn truncate(self: *Log, keep_turns: usize, retained_item_count: usize) Error!void {
        if (self.file == null) return;
        var prepared = self.prepareCut(keep_turns) catch |err| return mapLegacyCutError(err);
        defer prepared.deinit();
        if (prepared.plan.cut_offset == prepared.plan.original_size) {
            self.selection_pending = prepared.selection_pending_after_cut;
            return;
        }
        const outcome = self.truncatePrepared(&prepared, retained_item_count) catch |err|
            return mapLegacyTruncateError(err);
        switch (outcome) {
            .unchanged, .indeterminate => return error.IoFailure,
            .committed => |value| if (value.durability == .sync_failed) return error.IoFailure,
        }
    }

    const TruncateClassification = union(enum) {
        original,
        retained,
        indeterminate: TruncateIndeterminate,
    };

    fn validatePreparedCut(
        self: *Log,
        file: std.Io.File,
        prepared: *const PreparedCut,
    ) TruncateError!void {
        const opened_stat = file.stat(self.io) catch return error.IoFailure;
        if (opened_stat.kind != .file) return error.NotRegular;
        if (opened_stat.nlink == 0) return error.Removed;
        const opened_identity = self.opened_identity_fn(file) catch return error.IoFailure;
        const named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return error.Removed;
        const named_identity = self.named_identity_fn(self.io, self.path_value) catch return error.Removed;
        if (!prepared.stat_token.matches(opened_identity, opened_stat) or
            !prepared.stat_token.matches(named_identity, named_stat) or
            !prepared.opened_identity.eql(opened_identity) or
            !prepared.named_identity.eql(named_identity))
        {
            return error.InvalidPlan;
        }
        if (!(self.matchesFileBytes(
            file,
            prepared.original_bytes,
            prepared.plan.original_fingerprint,
        ) catch return error.IoFailure)) return error.InvalidPlan;
        const final_opened_stat = file.stat(self.io) catch return error.IoFailure;
        const final_opened_identity = self.opened_identity_fn(file) catch return error.IoFailure;
        const final_named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return error.Removed;
        const final_named_identity = self.named_identity_fn(self.io, self.path_value) catch return error.Removed;
        if (!prepared.stat_token.matches(final_opened_identity, final_opened_stat) or
            !prepared.stat_token.matches(final_named_identity, final_named_stat))
        {
            return error.InvalidPlan;
        }
    }

    fn classifyTruncate(self: *Log, file: std.Io.File, prepared: *PreparedCut) TruncateClassification {
        const opened_stat = file.stat(self.io) catch return .{ .indeterminate = .unreadable };
        if (opened_stat.kind != .file) return .{ .indeterminate = .changed };
        if (opened_stat.nlink == 0) return .{ .indeterminate = .removed };
        const opened_identity = self.opened_identity_fn(file) catch return .{ .indeterminate = .unreadable };
        if (!prepared.opened_identity.eql(opened_identity)) return .{ .indeterminate = .replaced };
        const named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return .{ .indeterminate = .removed };
        if (named_stat.kind != .file or named_stat.nlink == 0) return .{ .indeterminate = .removed };
        const named_identity = self.named_identity_fn(self.io, self.path_value) catch
            return .{ .indeterminate = .removed };
        if (!prepared.named_identity.eql(named_identity) or !opened_identity.eql(named_identity)) {
            return .{ .indeterminate = .replaced };
        }

        const expected_size: usize = if (opened_stat.size == prepared.original_size)
            @intCast(prepared.original_size)
        else if (opened_stat.size == prepared.plan.cut_offset)
            @intCast(prepared.plan.cut_offset)
        else
            return .{ .indeterminate = .changed };
        const final_opened_stat = file.stat(self.io) catch return .{ .indeterminate = .unreadable };
        const final_opened_identity = self.opened_identity_fn(file) catch
            return .{ .indeterminate = .unreadable };
        const final_named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return .{ .indeterminate = .removed };
        const final_named_identity = self.named_identity_fn(self.io, self.path_value) catch
            return .{ .indeterminate = .removed };
        if (!sameSnapshotStat(opened_stat, final_opened_stat) or
            !sameSnapshotStat(final_opened_stat, final_named_stat) or
            !opened_identity.eql(final_opened_identity) or
            !opened_identity.eql(final_named_identity))
        {
            return .{ .indeterminate = .changed };
        }
        const expected_bytes = if (opened_stat.size == prepared.original_size)
            prepared.original_bytes
        else
            prepared.original_bytes[0..expected_size];
        const expected_fingerprint = if (opened_stat.size == prepared.original_size)
            prepared.plan.original_fingerprint
        else
            prepared.plan.retained_fingerprint;
        if (opened_stat.size == prepared.original_size and
            !prepared.stat_token.matches(final_opened_identity, final_opened_stat))
        {
            return .{ .indeterminate = .content_mismatch };
        }
        const matches = self.matchesFileBytes(file, expected_bytes, expected_fingerprint) catch
            return .{ .indeterminate = .unreadable };
        if (!matches) return .{ .indeterminate = .content_mismatch };
        const checked_stat = file.stat(self.io) catch return .{ .indeterminate = .unreadable };
        const checked_identity = self.opened_identity_fn(file) catch return .{ .indeterminate = .unreadable };
        const checked_named_stat = std.Io.Dir.statFile(
            .cwd(),
            self.io,
            self.path_value,
            .{ .follow_symlinks = false },
        ) catch return .{ .indeterminate = .removed };
        const checked_named_identity = self.named_identity_fn(self.io, self.path_value) catch
            return .{ .indeterminate = .removed };
        if (!sameSnapshotStat(final_opened_stat, checked_stat) or
            !sameSnapshotStat(checked_stat, checked_named_stat) or
            !final_opened_identity.eql(checked_identity) or
            !checked_identity.eql(checked_named_identity))
        {
            return .{ .indeterminate = .changed };
        }
        return if (opened_stat.size == prepared.original_size) .original else .retained;
    }

    fn matchesFileBytes(
        self: *Log,
        file: std.Io.File,
        expected: []const u8,
        expected_fingerprint: SessionCut.Fingerprint,
    ) error{IoFailure}!bool {
        var hasher = std.crypto.hash.Blake3.init(.{});
        var chunk: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < expected.len) {
            const length = @min(chunk.len, expected.len - offset);
            const read = file.readPositionalAll(self.io, chunk[0..length], @intCast(offset)) catch
                return error.IoFailure;
            if (read != length) return false;
            if (!std.mem.eql(u8, expected[offset..][0..length], chunk[0..length])) return false;
            hasher.update(chunk[0..length]);
            offset += length;
        }
        var observed: SessionCut.Fingerprint = undefined;
        hasher.final(&observed);
        return std.mem.eql(u8, &expected_fingerprint, &observed);
    }

    /// Creates a locked sibling session containing the first `keep_turns`
    /// typed turns. The source must already be materialized and remains
    /// unchanged. Time, identity, and the live selection are explicit inputs.
    pub fn fork(
        self: *Log,
        keep_turns: usize,
        retained_item_count: usize,
        timestamp_value: Paths.Timestamp,
        uuid: [16]u8,
        live_selection: Selection,
    ) Error!Log {
        const source = self.file orelse return error.Unavailable;
        if (self.poisoned) return error.Unavailable;
        if (retained_item_count > self.limits.max_items) return error.TooManyItems;
        var selection = OwnedSelection.init(self.allocator, live_selection) catch |err| return mapAlloc(err);
        errdefer selection.deinit(self.allocator);

        const initial_stat = source.stat(self.io) catch return error.IoFailure;
        if (initial_stat.kind != .file) return error.NotRegular;
        if (initial_stat.nlink == 0) return error.Removed;
        if (initial_stat.size > self.limits.max_file_bytes) return error.FileTooLarge;
        if (initial_stat.size != self.append_offset) {
            self.poison();
            return error.IoFailure;
        }
        const source_size: usize = std.math.cast(usize, initial_stat.size) orelse
            return error.FileTooLarge;
        const source_bytes = self.allocator.alloc(u8, source_size) catch return error.OutOfMemory;
        defer self.allocator.free(source_bytes);
        if (source_size != 0) {
            const read = source.readPositionalAll(self.io, source_bytes, 0) catch {
                self.poison();
                return error.IoFailure;
            };
            if (read != source_size) {
                self.poison();
                return error.IoFailure;
            }
        }
        const first_lf = std.mem.indexOfScalar(u8, source_bytes, '\n') orelse
            return error.InvalidHeader;
        if (first_lf > self.limits.max_line_bytes) return error.LineTooLarge;
        const cut = SessionCut.findCut(self.allocator, source_bytes, keep_turns, .{
            .max_file_bytes = self.limits.max_file_bytes,
            .max_line_bytes = self.limits.max_line_bytes,
            .max_tokens = self.limits.item_json.max_tokens,
            .max_nesting = self.limits.item_json.max_nesting,
            .max_turns = self.limits.max_items,
        }) catch |err| return mapCut(err);
        if (cut < first_lf + 1 or cut > source_bytes.len) return error.InvalidHeader;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, source_bytes[0..first_lf], .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidHeader;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidHeader;
        const object = parsed.value.object;
        const old_id: ?[]const u8 = old: {
            const value = object.get("id") orelse break :old null;
            break :old if (value == .string) value.string else null;
        };

        const timestamp_array = Paths.headerTimestamp(timestamp_value) catch |err| return mapPath(err);
        const new_id = uuidString(self.allocator, uuid) catch return error.OutOfMemory;
        defer self.allocator.free(new_id);
        var header: std.Io.Writer.Allocating = .init(self.allocator);
        defer header.deinit();
        var json: std.json.Stringify = .{ .writer = &header.writer };
        json.beginObject() catch return error.OutOfMemory;
        var saw_id = false;
        var saw_timestamp = false;
        var saw_forked_from = false;
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "id")) {
                jsonField(&json, key, new_id) catch return error.OutOfMemory;
                saw_id = true;
            } else if (std.mem.eql(u8, key, "timestamp")) {
                jsonField(&json, key, &timestamp_array) catch return error.OutOfMemory;
                saw_timestamp = true;
            } else if (std.mem.eql(u8, key, "forked_from") and old_id != null) {
                jsonField(&json, key, old_id.?) catch return error.OutOfMemory;
                saw_forked_from = true;
            } else {
                jsonField(&json, key, entry.value_ptr.*) catch return error.OutOfMemory;
            }
        }
        if (!saw_id) jsonField(&json, "id", new_id) catch return error.OutOfMemory;
        if (!saw_timestamp) jsonField(&json, "timestamp", &timestamp_array) catch return error.OutOfMemory;
        if (!saw_forked_from and old_id != null) {
            jsonField(&json, "forked_from", old_id.?) catch return error.OutOfMemory;
        }
        json.endObject() catch return error.OutOfMemory;
        header.writer.writeByte('\n') catch return error.OutOfMemory;
        if (header.written().len > self.limits.max_line_bytes + 1) return error.LineTooLarge;
        const raw_tail = source_bytes[first_lf + 1 .. cut];
        const target_size = std.math.add(usize, header.written().len, raw_tail.len) catch
            return error.FileTooLarge;
        if (target_size > self.limits.max_file_bytes) return error.FileTooLarge;

        const directory = std.fs.path.dirname(self.path_value) orelse return error.InvalidPath;
        const name = Paths.canonicalName(timestamp_value, uuid) catch |err| return mapPath(err);
        const target_path = try joinPath(self.allocator, directory, &name, self.limits.paths.max_path_bytes);
        errdefer self.allocator.free(target_path);

        self.fork_verify_fn(self.io, source, initial_stat, source_bytes) catch {
            self.poison();
            return error.IoFailure;
        };

        const created = std.Io.Dir.createFile(.cwd(), self.io, target_path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch return error.IoFailure;
        const pending = self.populateForkTarget(
            source,
            initial_stat,
            source_bytes,
            created,
            directory,
            header.written(),
            raw_tail,
            target_size,
            selection.borrow(),
        ) catch |operation_error| {
            created.close(self.io);
            self.cleanupForkTarget(target_path, directory) catch
                return error.IndeterminateCleanup;
            return operation_error;
        };

        return .{
            .allocator = self.allocator,
            .io = self.io,
            .limits = self.limits,
            .state_root = null,
            .cwd = null,
            .path_value = target_path,
            .id = null,
            .timestamp = null,
            .writer_version = null,
            .selection = selection,
            .git_probe = null,
            .file = created,
            .append_offset = @intCast(target_size),
            .header_written = true,
            .selection_pending = pending,
            .written_items = retained_item_count,
        };
    }

    fn populateForkTarget(
        self: *Log,
        source: std.Io.File,
        initial_stat: std.Io.File.Stat,
        source_bytes: []const u8,
        target: std.Io.File,
        directory: []const u8,
        header: []const u8,
        raw_tail: []const u8,
        target_size: usize,
        live_selection: Selection,
    ) Error!bool {
        const locked = target.tryLock(self.io, .exclusive) catch return error.IoFailure;
        if (!locked) return error.SessionBusy;
        target.setPermissions(self.io, .fromMode(0o600)) catch return error.IoFailure;
        self.commit_fn(self.io, target, header, 0) catch return error.IoFailure;
        self.commit_fn(self.io, target, raw_tail, @intCast(header.len)) catch
            return error.IoFailure;
        const target_stat = target.stat(self.io) catch return error.IoFailure;
        if (target_stat.kind != .file or target_stat.nlink == 0 or target_stat.size != target_size) {
            return error.IoFailure;
        }
        target.sync(self.io) catch return error.IoFailure;
        self.fork_sync_directory_fn(self.io, directory) catch return error.IoFailure;

        var effective = try readEffectiveSelectionOpened(self.allocator, self.io, target, self.limits);
        defer effective.deinit(self.allocator);
        const pending = !selectionCoreEqual(effective.borrow(), live_selection);
        self.fork_verify_fn(self.io, source, initial_stat, source_bytes) catch {
            self.poison();
            return error.IoFailure;
        };
        return pending;
    }

    /// The fork target path is deterministic from the source directory and
    /// explicit timestamp/UUID. If cleanup is indeterminate, callers can use
    /// those same inputs to inspect or remove the owner-only sibling.
    fn cleanupForkTarget(self: *Log, target_path: []const u8, directory: []const u8) error{IndeterminateCleanup}!void {
        self.fork_delete_fn(self.io, target_path) catch return error.IndeterminateCleanup;
        self.fork_sync_directory_fn(self.io, directory) catch return error.IndeterminateCleanup;
    }

    /// Owns a prospective selection without changing the log. Core selection
    /// changes and display-label-only changes remain distinct at publication.
    pub fn prepareSelection(self: *Log, selection: Selection) Error!PreparedSelection {
        if (self.poisoned) return error.Poisoned;
        validateSelection(selection) catch return error.InvalidSelection;
        if (selectionEqual(self.selection.borrow(), selection)) return .{
            .owner = self,
            .generation = self.selection_generation,
            .allocator = self.allocator,
            .replacement = null,
            .core_changed = false,
        };
        var replacement = OwnedSelection.init(self.allocator, selection) catch |err| return mapAlloc(err);
        errdefer replacement.deinit(self.allocator);
        return .{
            .owner = self,
            .generation = self.selection_generation,
            .allocator = self.allocator,
            .core_changed = !selectionCoreEqual(self.selection.borrow(), replacement.borrow()),
            .replacement = replacement,
        };
    }

    /// Publishes a prepared replacement without allocating or freeing. Consumes
    /// `prepared`; the caller must later deinitialize the returned owner.
    pub fn publishSelectionRetired(
        self: *Log,
        prepared: *PreparedSelection,
    ) RetiredSelection {
        std.debug.assert(prepared.active);
        std.debug.assert(prepared.owner == self);
        std.debug.assert(prepared.generation == self.selection_generation);
        prepared.active = false;
        self.selection_generation +%= 1;
        self.mutation_generation +%= 1;
        const replacement = prepared.replacement orelse return .{
            .allocator = self.allocator,
            .selection = null,
        };
        prepared.replacement = null;
        const previous = self.selection;
        self.selection = replacement;
        if (prepared.core_changed and self.header_written) self.selection_pending = true;
        return .{ .allocator = self.allocator, .selection = previous };
    }

    /// Publishes and immediately releases displaced selection strings.
    pub fn publishSelection(self: *Log, prepared: *PreparedSelection) void {
        var retired = self.publishSelectionRetired(prepared);
        retired.deinit();
    }

    /// Moves the retired old selection back into the live log for settlement.
    /// The token owns the temporary next-conversation selection until deinit or restore.
    pub fn beginTransitionSelection(self: *Log, retired: *RetiredSelection) TransitionSelection {
        std.debug.assert(retired.active);
        std.debug.assert(retired.allocator.ptr == self.allocator.ptr);
        const old = retired.selection orelse return .{
            .generation = self.selection_generation,
            .allocator = self.allocator,
            .selection = null,
        };
        retired.selection = null;
        const next = self.selection;
        self.selection = old;
        self.selection_pending = false;
        self.selection_generation +%= 1;
        self.mutation_generation +%= 1;
        return .{
            .generation = self.selection_generation,
            .allocator = self.allocator,
            .selection = next,
        };
    }

    pub fn restoreTransitionSelection(self: *Log, transition: *TransitionSelection) void {
        std.debug.assert(transition.active);
        std.debug.assert(!transition.restored);
        std.debug.assert(transition.generation == self.selection_generation);
        if (transition.selection) |next| {
            const old = self.selection;
            self.selection = next;
            transition.selection = old;
            self.selection_pending = self.header_written;
            self.selection_generation +%= 1;
            self.mutation_generation +%= 1;
            transition.generation = self.selection_generation;
        }
        transition.restored = true;
    }

    pub fn setSelection(self: *Log, selection: Selection) Error!void {
        var prepared = try self.prepareSelection(selection);
        defer prepared.deinit();
        self.publishSelection(&prepared);
    }

    pub fn discardSelection(self: *Log) void {
        if (self.selection_pending) self.mutation_generation +%= 1;
        self.selection_pending = false;
    }

    pub fn sync(self: *Log) Error!void {
        if (self.poisoned) return error.Poisoned;
        if (self.file) |file| file.sync(self.io) catch {
            self.poison();
            return error.IoFailure;
        };
    }

    pub fn reset(self: *Log, cwd: []const u8, timestamp_value: Paths.Timestamp, uuid: [16]u8) Error!void {
        if (self.state_root == null or self.writer_version == null) return error.Unavailable;
        const options: PrepareOptions = .{
            .state_root = self.state_root.?,
            .cwd = cwd,
            .selection = self.selection.borrow(),
            .timestamp = timestamp_value,
            .uuid = uuid,
            .writer_version = self.writer_version.?,
            .git_probe = self.git_probe,
            .limits = self.limits,
        };
        const replacement = try prepare(self.allocator, self.io, options);
        self.deinit();
        self.* = replacement;
    }

    fn encodeHeader(self: *Log, writer: *std.Io.Writer) AppendError!void {
        var git: ?GitState = null;
        if (self.git_probe) |probe_value| {
            git = probe_value.probe(self.allocator, self.io, self.cwd.?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Cancelled => return error.Cancelled,
                error.Unavailable => null,
            };
        }
        defer if (git) |*state| state.deinit(self.allocator);
        if (git) |state| try validateGitState(state);
        const start = writer.end;
        var json: std.json.Stringify = .{ .writer = writer };
        json.beginObject() catch return error.OutOfMemory;
        jsonField(&json, "type", "session") catch return error.OutOfMemory;
        jsonField(&json, "version", format_version) catch return error.OutOfMemory;
        jsonField(&json, "zi_version", self.writer_version.?) catch return error.OutOfMemory;
        jsonOptional(&json, "id", self.id) catch return error.OutOfMemory;
        jsonOptional(&json, "timestamp", self.timestamp) catch return error.OutOfMemory;
        jsonOptional(&json, "cwd", self.cwd) catch return error.OutOfMemory;
        try jsonSelection(&json, self.selection.borrow());
        if (git) |state| {
            jsonOptional(&json, "git_branch", state.branch) catch return error.OutOfMemory;
            jsonOptional(&json, "git_commit", state.commit) catch return error.OutOfMemory;
            jsonOptional(&json, "git_subject", state.subject) catch return error.OutOfMemory;
        }
        json.endObject() catch return error.OutOfMemory;
        writer.writeByte('\n') catch return error.OutOfMemory;
        if (writer.end - start > self.limits.max_line_bytes + 1) return error.LineTooLarge;
    }

    fn ensureFileClassified(self: *Log) AppendError!?AppendOutcome {
        if (self.file != null) return null;
        const directory = std.fs.path.dirname(self.path_value) orelse return error.InvalidPath;
        _ = std.Io.Dir.createDirPathStatus(
            .cwd(),
            self.io,
            directory,
            .fromMode(0o700),
        ) catch return error.IoFailure;
        const sessions_dir = std.fs.path.dirname(directory) orelse return error.InvalidPath;
        setDirectoryMode(self.io, sessions_dir) catch return error.IoFailure;
        setDirectoryMode(self.io, directory) catch return error.IoFailure;
        const file = std.Io.Dir.createFile(.cwd(), self.io, self.path_value, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |err| {
            if (err == error.PathAlreadyExists) {
                self.poison();
                return .{ .indeterminate = .path_collision };
            }
            return error.IoFailure;
        };
        self.file = file;
        const locked = file.tryLock(self.io, .exclusive) catch {
            self.poison();
            return .{ .indeterminate = .lock_failed_after_create };
        };
        if (!locked) {
            self.poison();
            return .{ .indeterminate = .lock_failed_after_create };
        }
        const stat = file.stat(self.io) catch {
            return self.cleanupCreatedOrIndeterminate(.verification_failed);
        };
        if (stat.kind != .file or stat.nlink == 0 or !self.namedFileMatches(stat)) {
            self.poison();
            return .{ .indeterminate = .identity_changed };
        }
        file.setPermissions(self.io, .fromMode(0o600)) catch {
            return self.cleanupCreatedOrIndeterminate(.verification_failed);
        };
        return null;
    }

    fn classifyFailedAppend(
        self: *Log,
        initial_stat: std.Io.File.Stat,
        old_bytes: []const u8,
        appended: []const u8,
        item_count: usize,
        created: bool,
    ) AppendOutcome {
        const content = self.classifyAppendContent(initial_stat, old_bytes, appended);
        return switch (content) {
            .old => if (created)
                self.cleanupCreatedOrIndeterminate(.cleanup_indeterminate)
            else
                .unchanged,
            .final => self.finishCommittedAppend(appended.len, item_count),
            .partial => blk: {
                self.poison();
                break :blk .{ .indeterminate = .partial_write };
            },
            .identity_changed => blk: {
                self.poison();
                break :blk .{ .indeterminate = .identity_changed };
            },
            .verification_failed => blk: {
                self.poison();
                break :blk .{ .indeterminate = .verification_failed };
            },
        };
    }

    fn classifyPopulatedAppend(
        self: *Log,
        initial_stat: std.Io.File.Stat,
        old_bytes: []const u8,
        appended: []const u8,
        item_count: usize,
    ) AppendOutcome {
        const content = self.classifyAppendContent(initial_stat, old_bytes, appended);
        if (content == .final) return self.finishCommittedAppend(appended.len, item_count);
        self.poison();
        return .{ .indeterminate = switch (content) {
            .identity_changed => .identity_changed,
            .verification_failed => .verification_failed,
            .old, .partial => .partial_write,
            .final => unreachable,
        } };
    }

    const AppendContent = enum { old, final, partial, identity_changed, verification_failed };

    fn classifyAppendContent(
        self: *Log,
        initial_stat: std.Io.File.Stat,
        old_bytes: []const u8,
        appended: []const u8,
    ) AppendContent {
        const file = self.file.?;
        const stat = file.stat(self.io) catch return .verification_failed;
        if (stat.kind != .file or stat.nlink == 0 or stat.inode != initial_stat.inode) {
            return .identity_changed;
        }
        if (!self.namedFileMatches(stat)) return .identity_changed;
        if (stat.size == old_bytes.len) {
            const matches = fileContentMatches(self.io, file, old_bytes, &.{}) orelse
                return .verification_failed;
            if (!matches or !self.snapshotStillMatches(stat)) return .partial;
            return .old;
        }
        const final_size = std.math.add(usize, old_bytes.len, appended.len) catch return .partial;
        if (stat.size == final_size) {
            const matches = fileContentMatches(self.io, file, old_bytes, appended) orelse
                return .verification_failed;
            if (!matches or !self.snapshotStillMatches(stat)) return .partial;
            return .final;
        }
        return .partial;
    }

    fn snapshotStillMatches(self: *Log, before: std.Io.File.Stat) bool {
        const after = self.file.?.stat(self.io) catch return false;
        return sameSnapshotStat(before, after) and self.namedFileMatches(after);
    }

    fn finishCommittedAppend(self: *Log, appended_bytes: usize, item_count: usize) AppendOutcome {
        self.header_written = true;
        self.selection_pending = false;
        self.separator_pending = false;
        self.append_offset += @intCast(appended_bytes);
        self.written_items = item_count;
        self.mutation_generation +%= 1;
        self.append_sync_file_fn(self.io, self.file.?) catch {
            self.poison();
            return .{ .committed = .sync_failed };
        };
        if (self.append_offset == appended_bytes) {
            const directory = std.fs.path.dirname(self.path_value) orelse {
                self.poison();
                return .{ .committed = .sync_failed };
            };
            self.append_sync_directory_fn(self.io, directory) catch {
                self.poison();
                return .{ .committed = .sync_failed };
            };
        }
        return .{ .committed = .synced };
    }

    fn cleanupCreatedOrIndeterminate(self: *Log, failure: AppendFailure) AppendOutcome {
        const file = self.file.?;
        const opened = file.stat(self.io) catch {
            self.poison();
            return .{ .indeterminate = failure };
        };
        if (!self.namedFileMatches(opened)) {
            self.poison();
            return .{ .indeterminate = .identity_changed };
        }
        self.append_delete_fn(self.io, self.path_value) catch {
            self.poison();
            return .{ .indeterminate = .cleanup_indeterminate };
        };
        const unlinked = file.stat(self.io) catch {
            self.poison();
            return .{ .indeterminate = .cleanup_indeterminate };
        };
        if (unlinked.inode != opened.inode or unlinked.nlink != 0) {
            self.poison();
            return .{ .indeterminate = .cleanup_indeterminate };
        }
        if (std.Io.Dir.statFile(.cwd(), self.io, self.path_value, .{ .follow_symlinks = false })) |_| {
            self.poison();
            return .{ .indeterminate = .cleanup_indeterminate };
        } else |err| if (err != error.FileNotFound) {
            self.poison();
            return .{ .indeterminate = .cleanup_indeterminate };
        }
        const directory = std.fs.path.dirname(self.path_value) orelse {
            self.poison();
            return .{ .indeterminate = .cleanup_indeterminate };
        };
        self.append_sync_directory_fn(self.io, directory) catch {
            self.poison();
            return .{ .indeterminate = .cleanup_indeterminate };
        };
        file.close(self.io);
        self.file = null;
        return .unchanged;
    }

    fn namedFileMatches(self: *Log, opened: std.Io.File.Stat) bool {
        if (opened.kind != .file or opened.nlink == 0) return false;
        const file = self.file orelse return false;
        const opened_identity = self.opened_identity_fn(file) catch return false;
        const named_identity = self.named_identity_fn(self.io, self.path_value) catch return false;
        return opened_identity.eql(named_identity);
    }

    fn poison(self: *Log) void {
        // Keep the exclusive lock until deinit. A later owner can then load
        // and repair a torn final record before it resumes appending.
        self.poisoned = true;
    }
};

fn commitAll(io: std.Io, file: std.Io.File, bytes: []const u8, offset: u64) error{IoFailure}!void {
    file.writePositionalAll(io, bytes, offset) catch return error.IoFailure;
}

fn syncFile(io: std.Io, file: std.Io.File) error{IoFailure}!void {
    file.sync(io) catch return error.IoFailure;
}

fn fileContentMatches(
    io: std.Io,
    file: std.Io.File,
    prefix: []const u8,
    suffix: []const u8,
) ?bool {
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    const total = prefix.len + suffix.len;
    while (offset < total) {
        const length = @min(buffer.len, total - offset);
        const read = file.readPositionalAll(io, buffer[0..length], @intCast(offset)) catch return null;
        if (read != length) return false;
        for (buffer[0..length], offset..) |byte, index| {
            const expected = if (index < prefix.len) prefix[index] else suffix[index - prefix.len];
            if (byte != expected) return false;
        }
        offset += length;
    }
    return true;
}

fn setLength(io: std.Io, file: std.Io.File, length: u64) error{IoFailure}!void {
    file.setLength(io, length) catch return error.IoFailure;
}

fn noTruncatePost(_: *Log, _: std.Io.File) void {}

fn setPrivatePermissions(io: std.Io, file: std.Io.File) error{IoFailure}!void {
    file.setPermissions(io, .fromMode(0o600)) catch return error.IoFailure;
}

fn syncParentDirectory(io: std.Io, path: []const u8) error{IoFailure}!void {
    const directory = std.Io.Dir.openDir(.cwd(), io, path, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    defer directory.close(io);
    const file: std.Io.File = .{ .handle = directory.handle, .flags = .{ .nonblocking = false } };
    file.sync(io) catch return error.IoFailure;
}

fn deleteForkTarget(io: std.Io, path: []const u8) error{IoFailure}!void {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch return error.IoFailure;
}

fn sameSnapshotStat(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.nlink == b.nlink and a.size == b.size and
        a.kind == b.kind and a.mtime.nanoseconds == b.mtime.nanoseconds and
        a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn verifySnapshot(
    io: std.Io,
    file: std.Io.File,
    initial_stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    const before = file.stat(io) catch return error.IoFailure;
    if (!sameSnapshotStat(initial_stat, before) or before.size != expected.len) {
        return error.IoFailure;
    }
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const length = @min(buffer.len, expected.len - offset);
        const read = file.readPositionalAll(io, buffer[0..length], @intCast(offset)) catch
            return error.IoFailure;
        if (read != length or !std.mem.eql(u8, expected[offset .. offset + length], buffer[0..length])) {
            return error.IoFailure;
        }
        offset += length;
    }
    const after = file.stat(io) catch return error.IoFailure;
    if (!sameSnapshotStat(initial_stat, after)) return error.IoFailure;
}

fn failSetLength(_: std.Io, _: std.Io.File, _: u64) error{IoFailure}!void {
    return error.IoFailure;
}

fn mutateThenFailSetLength(io: std.Io, file: std.Io.File, length: u64) error{IoFailure}!void {
    file.setLength(io, length) catch return error.IoFailure;
    return error.IoFailure;
}

fn setUnexpectedLength(io: std.Io, file: std.Io.File, length: u64) error{IoFailure}!void {
    file.setLength(io, length + 1) catch return error.IoFailure;
}

fn postTruncateContentMismatch(log: *Log, file: std.Io.File) void {
    file.writePositionalAll(log.io, "X", 0) catch return;
}

fn failOpenedIdentity(_: std.Io.File) error{IoFailure}!NativeIdentity.Identity {
    return error.IoFailure;
}

fn postTruncateUnreadable(log: *Log, _: std.Io.File) void {
    log.opened_identity_fn = failOpenedIdentity;
}

fn postTruncateRemoved(log: *Log, _: std.Io.File) void {
    std.Io.Dir.deleteFile(.cwd(), log.io, log.path_value) catch return;
}

fn postTruncateReplaced(log: *Log, _: std.Io.File) void {
    var moved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const moved = std.fmt.bufPrint(&moved_buffer, "{s}.moved", .{log.path_value}) catch return;
    std.Io.Dir.rename(.cwd(), log.path_value, .cwd(), moved, log.io) catch return;
    const replacement = std.Io.Dir.createFile(.cwd(), log.io, log.path_value, .{
        .read = true,
        .permissions = .fromMode(0o600),
    }) catch return;
    replacement.close(log.io);
}

fn failEffectiveSelection(
    _: std.mem.Allocator,
    _: std.Io,
    _: std.Io.File,
    _: Limits,
) Error!OwnedSelection {
    return error.IoFailure;
}

/// Updates both timestamps on an existing session, matching hax's
/// `session_touch`. The absolute path and its parents are a trusted private
/// boundary. The no-follow pre-stat prevents blocking on an existing FIFO;
/// that boundary must prevent replacement before the no-follow open. Lock
/// contention or an unsupported lock facility returns `Busy`; cancellation
/// and resource failures abort before changing timestamps.
pub fn touch(io: std.Io, path: []const u8) TouchError!void {
    if (!safeAbsolutePath(path)) return error.InvalidPath;
    if (path.len >= std.fs.max_path_bytes) return error.PathTooLong;
    const named_stat = std.Io.Dir.statFile(.cwd(), io, path, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    if (named_stat.kind != .file) return error.NotRegular;
    if (named_stat.nlink == 0) return error.Removed;

    const file = std.Io.Dir.openFile(.cwd(), io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.IoFailure;
    defer file.close(io);

    const locked = file.tryLock(io, .shared) catch |err| switch (err) {
        error.FileLocksUnsupported => false,
        error.Canceled => return error.Canceled,
        else => return error.IoFailure,
    };
    if (!locked) return error.Busy;
    defer file.unlock(io);

    const opened_stat = file.stat(io) catch return error.IoFailure;
    if (opened_stat.kind != .file) return error.NotRegular;
    if (opened_stat.nlink == 0) return error.Removed;
    file.setTimestampsNow(io) catch return error.IoFailure;
}

fn readEffectiveSelectionOpened(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    limits: Limits,
) Error!OwnedSelection {
    const stat = file.stat(io) catch return error.IoFailure;
    if (stat.kind != .file) return error.NotRegular;
    if (stat.nlink == 0) return error.Removed;
    if (stat.size > limits.max_file_bytes) return error.FileTooLarge;
    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    const data = allocator.alloc(u8, size) catch return error.OutOfMemory;
    defer allocator.free(data);
    if (size != 0) {
        const read = file.readPositionalAll(io, data, 0) catch return error.IoFailure;
        if (read != size) return error.IoFailure;
    }

    return effectiveSelectionFromBytes(allocator, data, limits);
}

fn effectiveSelectionFromBytes(
    allocator: std.mem.Allocator,
    data: []const u8,
    limits: Limits,
) Error!OwnedSelection {
    var current: OwnedSelection = .{};
    errdefer current.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < data.len) {
        const newline = std.mem.findScalarPos(u8, data, cursor, '\n');
        const end = newline orelse data.len;
        const line = data[cursor..end];
        cursor = if (newline != null) end + 1 else data.len;
        if (line.len > limits.max_line_bytes) return error.LineTooLarge;
        if (line.len == 0 or !try recordWithinBounds(allocator, line, limits.item_json)) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const record_type = optionalJsonString(object, "type") orelse continue;
        if (!std.mem.eql(u8, record_type, "session") and
            !std.mem.eql(u8, record_type, "selection")) continue;
        const replacement = decodeSelection(allocator, object) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        current.deinit(allocator);
        current = replacement;
    }
    return current;
}

fn readStoredSessionId(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_size: u64,
    limits: Limits,
) Error!?[]u8 {
    if (file_size == 0) return null;
    const bounded_size: usize = std.math.cast(usize, @min(
        file_size,
        @as(u64, @intCast(limits.max_line_bytes)) + 1,
    )) orelse return null;
    const data = allocator.alloc(u8, bounded_size) catch return error.OutOfMemory;
    defer allocator.free(data);
    const read = file.readPositionalAll(io, data, 0) catch return error.IoFailure;
    if (read != bounded_size) return error.IoFailure;
    const newline = std.mem.findScalar(u8, data, '\n');
    if (newline == null and file_size > limits.max_line_bytes) return null;
    const line = data[0 .. newline orelse data.len];
    if (line.len == 0 or line.len > limits.max_line_bytes) return null;
    if (!try recordWithinBounds(allocator, line, limits.item_json)) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    const record_type = optionalJsonString(object, "type") orelse return null;
    if (!std.mem.eql(u8, record_type, "session")) return null;
    const id = optionalJsonString(object, "id") orelse return null;
    if (id.len == 0) return null;
    return allocator.dupe(u8, id) catch return error.OutOfMemory;
}

/// Reads only session and selection records. Malformed, item, and future
/// records are skipped, matching hax's metadata reader under Zi's bounds.
pub fn readMeta(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
) Error!Meta {
    try validateLimits(limits);
    if (!safeAbsolutePath(path)) return error.InvalidPath;
    try validateIoPathLength(path, limits.paths.max_path_bytes);
    const named_stat = std.Io.Dir.statFile(.cwd(), io, path, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    if (named_stat.kind != .file) return error.NotRegular;
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{
        .mode = .read_only,
        .follow_symlinks = false,
    }) catch return error.IoFailure;
    defer file.close(io);
    return readMetaOpened(allocator, io, file, limits);
}

/// Reads metadata relative to an already-open trusted private bucket. The
/// bucket may not be replaced by an uncoordinated writer during this call.
pub fn readMetaAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    bucket: std.Io.Dir,
    name: []const u8,
    limits: Limits,
) Error!Meta {
    try validateLimits(limits);
    if (name.len == 0 or name.len > std.Io.Dir.max_name_bytes or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null)
        return error.InvalidPath;
    const named_stat = bucket.statFile(io, name, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    if (named_stat.kind != .file) return error.NotRegular;
    const file = bucket.openFile(io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.IoFailure;
    defer file.close(io);
    return readMetaOpened(allocator, io, file, limits);
}

fn readMetaOpened(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    limits: Limits,
) Error!Meta {
    const locked = file.tryLock(io, .shared) catch return error.IoFailure;
    if (!locked) return error.SessionBusy;
    const stat = file.stat(io) catch return error.IoFailure;
    if (stat.kind != .file) return error.NotRegular;
    if (stat.nlink == 0) return error.Removed;
    if (stat.size > limits.max_file_bytes) return error.FileTooLarge;
    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    const data = allocator.alloc(u8, size) catch return error.OutOfMemory;
    defer allocator.free(data);
    if (size != 0) {
        const read = file.readPositionalAll(io, data, 0) catch return error.IoFailure;
        if (read != size) return error.IoFailure;
    }

    var meta: Meta = .{};
    errdefer meta.deinit(allocator);
    var current: OwnedSelection = .{};
    defer current.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < data.len) {
        const newline = std.mem.findScalarPos(u8, data, cursor, '\n');
        const end = newline orelse data.len;
        const line = data[cursor..end];
        cursor = if (newline != null) end + 1 else data.len;
        if (line.len > limits.max_line_bytes) return error.LineTooLarge;
        if (line.len == 0 or !try recordWithinBounds(allocator, line, limits.item_json)) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const record_type = optionalJsonString(object, "type") orelse continue;
        if (std.mem.eql(u8, record_type, "session")) {
            decodeHeader(allocator, object, &meta, &current) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                continue;
            };
        } else if (std.mem.eql(u8, record_type, "selection")) {
            const replacement = decodeSelection(allocator, object) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                continue;
            };
            current.deinit(allocator);
            current = replacement;
        }
    }
    var final_selection = current.clone(allocator) catch return error.OutOfMemory;
    errdefer final_selection.deinit(allocator);
    meta.selection.deinit(allocator);
    meta.selection = final_selection;
    return meta;
}

/// Backward-compatible stable snapshot loader used by unrecorded startup.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
) Error!Loaded {
    return loadStableForResume(allocator, io, path, limits);
}

fn decodeSnapshot(
    allocator: std.mem.Allocator,
    data: []const u8,
    limits: Limits,
) Error!Loaded {
    var meta: Meta = .{};
    errdefer meta.deinit(allocator);
    var current: OwnedSelection = .{};
    defer current.deinit(allocator);
    var decoded: std.ArrayList(ai.Item.Item) = .empty;
    var retained_bytes: usize = 0;
    var image_count: usize = 0;
    var image_base64_bytes: usize = 0;
    defer {
        for (decoded.items) |*item| item.deinit(allocator);
        decoded.deinit(allocator);
    }
    var recovery: Recovery = .{};
    var header_provider: ?[]u8 = null;
    defer if (header_provider) |value| allocator.free(value);
    var header_model: ?[]u8 = null;
    defer if (header_model) |value| allocator.free(value);

    var cursor: usize = 0;
    while (cursor < data.len) {
        const newline = std.mem.findScalarPos(u8, data, cursor, '\n');
        const end = newline orelse data.len;
        const terminated = newline != null;
        const line = data[cursor..end];
        cursor = if (terminated) end + 1 else data.len;
        if (line.len > limits.max_line_bytes) return error.LineTooLarge;
        if (line.len == 0) continue;

        const bounded = try recordWithinBounds(allocator, line, limits.item_json);
        if (!bounded) {
            if (!terminated and end == data.len) recovery.torn_tail_lines += 1 else recovery.malformed_lines += 1;
            continue;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .duplicate_field_behavior = .use_last,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (!terminated and end == data.len) recovery.torn_tail_lines += 1 else recovery.malformed_lines += 1;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            recovery.malformed_lines += 1;
            continue;
        }
        const object = parsed.value.object;
        const record_type = optionalJsonString(object, "type");
        if (record_type) |kind| {
            if (std.mem.eql(u8, kind, "session")) {
                decodeHeader(allocator, object, &meta, &current) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    recovery.malformed_lines += 1;
                    continue;
                };
                if (header_provider == null) {
                    header_provider = try dupeOptional(allocator, current.provider);
                }
                if (header_model == null) {
                    header_model = try dupeOptional(allocator, current.model);
                }
                continue;
            }
            if (std.mem.eql(u8, kind, "selection")) {
                const replacement = decodeSelection(allocator, object) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    recovery.malformed_lines += 1;
                    continue;
                };
                current.deinit(allocator);
                current = replacement;
                continue;
            }
        }
        if (decoded.items.len >= limits.max_items) return error.TooManyItems;
        var item = ItemJson.decodeWithContext(allocator, line, limits.item_json, .{
            .provider = header_provider,
            .model = header_model,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LineTooLarge => return error.LineTooLarge,
            error.UnknownKind => {
                recovery.unknown_records += 1;
                continue;
            },
            else => {
                recovery.malformed_lines += 1;
                continue;
            },
        };
        errdefer item.deinit(allocator);
        const item_retained = ai.Item.retainedBytes(item);
        const item_image_count = itemImageCount(item);
        const item_image_bytes = itemImageBase64Bytes(item);
        if (item_retained > limits.retained_bytes -| retained_bytes or
            item_image_count > limits.max_images -| image_count or
            item_image_bytes > limits.max_image_base64_bytes -| image_base64_bytes)
        {
            return error.ResourceLimit;
        }
        retained_bytes += item_retained;
        image_count += item_image_count;
        image_base64_bytes += item_image_bytes;
        decoded.append(allocator, item) catch return error.OutOfMemory;
    }
    removeDangling(allocator, &decoded, &recovery);
    try degradeExcessImages(allocator, decoded.items, &recovery);
    const session_limits: agent.Session.Limits = .{
        .items = limits.max_items,
        .retained_bytes = limits.retained_bytes,
        .images = limits.max_images,
        .image_base64_bytes = limits.max_image_base64_bytes,
    };
    var session = agent.Session.Session.initAdoptingItems(allocator, .{
        .provider_id = current.provider,
        .model = current.model,
        .model_label = current.model_label,
        .effort = current.effort,
        .preset = current.preset,
        .limits = session_limits,
    }, &decoded) catch |err| return mapSession(err);
    errdefer session.deinit();
    const last_selection = current.clone(allocator) catch return error.OutOfMemory;
    errdefer {
        var value = last_selection;
        value.deinit(allocator);
    }
    var final_selection = current.clone(allocator) catch return error.OutOfMemory;
    errdefer final_selection.deinit(allocator);
    meta.selection.deinit(allocator);
    meta.selection = final_selection;
    return .{
        .session = session,
        .meta = meta,
        .last_selection = last_selection,
        .item_high_water = session.items().len,
        .recovery = recovery,
    };
}

const SnapshotVerifier = *const fn (
    std.Io,
    std.Io.File,
    []const u8,
    std.Io.File.Stat,
    []const u8,
) error{IoFailure}!void;

/// Opens one no-follow snapshot, takes its exclusive lifetime lock, and moves
/// that same descriptor into the returned append log.
pub fn loadLockedForResume(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
) Error!ResumeLoaded {
    return loadLockedForResumeWithVerifier(allocator, io, path, limits, verifyStableSnapshot);
}

fn loadLockedForResumeWithVerifier(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
    verifier: SnapshotVerifier,
) Error!ResumeLoaded {
    try validateLoadPath(path, limits);
    try preflightNamedSnapshot(io, path, limits);
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.IoFailure;
    var file_owned = true;
    errdefer if (file_owned) file.close(io);
    const locked = file.tryLock(io, .exclusive) catch return error.IoFailure;
    if (!locked) return error.SessionBusy;

    const stat = try openedSnapshotStat(io, file, path, limits);
    const data = try readSnapshot(allocator, io, file, stat);
    defer allocator.free(data);
    try validateSeparatorCapacity(data, limits);
    var loaded = try decodeSnapshot(allocator, data, limits);
    errdefer loaded.deinit();
    verifier(io, file, path, stat, data) catch return error.IoFailure;
    const verified_stat = file.stat(io) catch return error.IoFailure;
    const verified_identity = NativeIdentity.opened(file) catch return error.IoFailure;
    if (!sameSnapshotStat(stat, verified_stat)) return error.IoFailure;
    const verified_snapshot = StatToken.init(verified_identity, verified_stat);

    var selection = OwnedSelection.init(allocator, loaded.meta.selection.borrow()) catch |err| return mapAlloc(err);
    errdefer selection.deinit(allocator);
    const session_path = allocator.dupe(u8, path) catch return error.OutOfMemory;
    errdefer allocator.free(session_path);
    const id = dupeOptional(allocator, loaded.meta.id) catch return error.OutOfMemory;
    errdefer if (id) |value| allocator.free(value);
    const separator_pending = data.len != 0 and data[data.len - 1] != '\n';

    const log: Log = .{
        .allocator = allocator,
        .io = io,
        .limits = limits,
        .state_root = null,
        .cwd = null,
        .path_value = session_path,
        .id = id,
        .timestamp = null,
        .writer_version = null,
        .selection = selection,
        .git_probe = null,
        .file = file,
        .append_offset = stat.size,
        .header_written = true,
        .separator_pending = separator_pending,
        .written_items = loaded.item_high_water,
        .verified_snapshot = verified_snapshot,
    };
    file_owned = false;
    return .{ .loaded = loaded, .log = log };
}

/// Loads one no-follow snapshot without retaining a descriptor. The named path
/// and opened file must still identify the exact same bytes before close.
pub fn loadStableForResume(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
) Error!Loaded {
    return loadStableForResumeWithVerifier(allocator, io, path, limits, verifyStableSnapshot);
}

fn loadStableForResumeWithVerifier(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
    verifier: SnapshotVerifier,
) Error!Loaded {
    try validateLoadPath(path, limits);
    try preflightNamedSnapshot(io, path, limits);
    const file = std.Io.Dir.openFile(.cwd(), io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.IoFailure;
    defer file.close(io);
    const stat = try openedSnapshotStat(io, file, path, limits);
    const data = try readSnapshot(allocator, io, file, stat);
    defer allocator.free(data);
    try validateSeparatorCapacity(data, limits);
    var loaded = try decodeSnapshot(allocator, data, limits);
    errdefer loaded.deinit();
    verifier(io, file, path, stat, data) catch return error.IoFailure;
    return loaded;
}

/// Backward-compatible startup wrapper.
pub fn loadForResume(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limits: Limits,
) Error!ResumeLoaded {
    return loadLockedForResume(allocator, io, path, limits);
}

fn validateLoadPath(path: []const u8, limits: Limits) Error!void {
    try validateLimits(limits);
    if (!safeAbsolutePath(path)) return error.InvalidPath;
    try validateIoPathLength(path, limits.paths.max_path_bytes);
}

fn preflightNamedSnapshot(io: std.Io, path: []const u8, limits: Limits) Error!void {
    const named = std.Io.Dir.statFile(.cwd(), io, path, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    if (named.kind != .file) return error.NotRegular;
    if (named.nlink == 0) return error.Removed;
    if (named.size > limits.max_file_bytes) return error.FileTooLarge;
}

fn openedSnapshotStat(
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    limits: Limits,
) Error!std.Io.File.Stat {
    const opened = file.stat(io) catch return error.IoFailure;
    if (opened.kind != .file) return error.NotRegular;
    if (opened.nlink == 0) return error.Removed;
    if (opened.size > limits.max_file_bytes) return error.FileTooLarge;
    const named = std.Io.Dir.statFile(.cwd(), io, path, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    if (named.kind != .file) return error.NotRegular;
    if (named.nlink == 0) return error.Removed;
    if (!sameSnapshotStat(opened, named)) return error.IoFailure;
    const opened_identity = NativeIdentity.opened(file) catch return error.IoFailure;
    const named_identity = NativeIdentity.named(io, path) catch return error.IoFailure;
    if (!opened_identity.eql(named_identity)) return error.IoFailure;
    return opened;
}

fn validateSeparatorCapacity(data: []const u8, limits: Limits) Error!void {
    if (data.len != 0 and data[data.len - 1] != '\n' and data.len >= limits.max_file_bytes) {
        return error.FileTooLarge;
    }
}

fn readSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    stat: std.Io.File.Stat,
) Error![]u8 {
    const size: usize = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
    const data = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(data);
    if (size != 0) {
        const read = file.readPositionalAll(io, data, 0) catch return error.IoFailure;
        if (read != size) return error.IoFailure;
    }
    return data;
}

fn verifyStableSnapshot(
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    initial_stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    verifySnapshot(io, file, initial_stat, expected) catch return error.IoFailure;
    const named = std.Io.Dir.statFile(.cwd(), io, path, .{ .follow_symlinks = false }) catch
        return error.IoFailure;
    if (named.kind != .file or named.nlink == 0 or !sameSnapshotStat(initial_stat, named)) {
        return error.IoFailure;
    }
    const opened_identity = NativeIdentity.opened(file) catch return error.IoFailure;
    const named_identity = NativeIdentity.named(io, path) catch return error.IoFailure;
    if (!opened_identity.eql(named_identity)) return error.IoFailure;
}

fn decodeHeader(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    meta: *Meta,
    selection: *OwnedSelection,
) Error!void {
    var new_meta: Meta = .{};
    errdefer new_meta.deinit(allocator);
    new_meta.id = try dupeJsonOptional(allocator, object, "id");
    new_meta.timestamp = try dupeJsonOptional(allocator, object, "timestamp");
    new_meta.cwd = try dupeJsonOptional(allocator, object, "cwd");
    new_meta.git_branch = try dupeJsonOptional(allocator, object, "git_branch");
    new_meta.git_commit = try dupeJsonOptional(allocator, object, "git_commit");
    new_meta.git_subject = try dupeJsonOptional(allocator, object, "git_subject");
    var new_selection = try decodeSelection(allocator, object);
    errdefer new_selection.deinit(allocator);
    new_meta.selection = try new_selection.clone(allocator);
    meta.deinit(allocator);
    meta.* = new_meta;
    selection.deinit(allocator);
    selection.* = new_selection;
}

fn decodeSelection(allocator: std.mem.Allocator, object: std.json.ObjectMap) !OwnedSelection {
    var result: OwnedSelection = .{};
    errdefer result.deinit(allocator);
    result.provider = try dupeJsonOptional(allocator, object, "provider");
    result.model = try dupeJsonOptional(allocator, object, "model");
    result.model_label = try dupeJsonOptional(allocator, object, "model_label");
    result.effort = try dupeJsonOptional(allocator, object, "effort");
    result.preset = try dupeJsonOptional(allocator, object, "preset");
    try validateSelection(result.borrow());
    return result;
}

fn itemImages(item: ai.Item.Item) []const ai.Item.Image {
    return switch (item) {
        .user_message => |value| value.images,
        .tool_result => |value| value.images,
        else => &.{},
    };
}

fn itemImageCount(item: ai.Item.Item) usize {
    return itemImages(item).len;
}

fn itemImageBase64Bytes(item: ai.Item.Item) usize {
    var total: usize = 0;
    for (itemImages(item)) |image| total +|= image.data_base64.len;
    return total;
}

fn degradeExcessImages(
    allocator: std.mem.Allocator,
    items: []ai.Item.Item,
    recovery: *Recovery,
) error{OutOfMemory}!void {
    const context_floor = contextFloor(items);
    var encoded_bytes: usize = 0;
    var image_count: usize = 0;
    for (items[context_floor..]) |*item| {
        const images = itemImages(item.*);
        if (images.len == 0) continue;
        const item_bytes = itemImageBase64Bytes(item.*);
        if (item_bytes <= 20 * 1024 * 1024 -| encoded_bytes and
            images.len <= 20 -| image_count)
        {
            encoded_bytes += item_bytes;
            image_count += images.len;
            continue;
        }
        if (item.* == .tool_result) {
            var output: std.Io.Writer.Allocating = .init(allocator);
            defer output.deinit();
            output.writer.writeAll(item.tool_result.output) catch return error.OutOfMemory;
            for (images) |image| {
                output.writer.writeByte('\n') catch return error.OutOfMemory;
                writeImagePlaceholder(&output.writer, image) catch return error.OutOfMemory;
            }
            const replacement = output.toOwnedSlice() catch return error.OutOfMemory;
            allocator.free(item.tool_result.output);
            item.tool_result.output = replacement;
        }
        freeImages(allocator, images);
        switch (item.*) {
            .user_message => item.user_message.images = &.{},
            .tool_result => item.tool_result.images = &.{},
            else => unreachable,
        }
        recovery.images_degraded += images.len;
    }
}

fn contextFloor(items: []const ai.Item.Item) usize {
    var index = items.len;
    while (index != 0) {
        index -= 1;
        const item = items[index];
        if (item == .user_message and item.user_message.origin == .compact_seed) return index;
    }
    return 0;
}

fn freeImages(allocator: std.mem.Allocator, images: []const ai.Item.Image) void {
    for (images) |image| {
        allocator.free(image.mime);
        allocator.free(image.data_base64);
    }
    if (images.len != 0) allocator.free(@constCast(images));
}

fn writeImagePlaceholder(writer: *std.Io.Writer, image: ai.Item.Image) !void {
    const decoded_bytes = image.data_base64.len / 4 * 3;
    try writer.print("[image: {s}, ", .{image.mime});
    if (image.width != null and image.height != null and image.width.? > 0 and image.height.? > 0) {
        try writer.print("{d}x{d}, ", .{ image.width.?, image.height.? });
    }
    if (decoded_bytes >= 1024 * 1024) {
        try writer.print("{d:.1} MiB]", .{@as(f64, @floatFromInt(decoded_bytes)) / (1024 * 1024)});
    } else if (decoded_bytes >= 1024) {
        try writer.print("{d:.1} KiB]", .{@as(f64, @floatFromInt(decoded_bytes)) / 1024});
    } else {
        try writer.print("{d} bytes]", .{decoded_bytes});
    }
}

fn removeDangling(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ai.Item.Item),
    recovery: *Recovery,
) void {
    var kept: usize = 0;
    for (items.items, 0..) |*item, index| {
        var remove = false;
        if (item.* == .tool_call) {
            remove = true;
            for (items.items) |candidate| {
                if (candidate == .tool_result and
                    std.mem.eql(u8, candidate.tool_result.call_id, item.tool_call.id))
                {
                    remove = false;
                    break;
                }
            }
        }
        if (remove) {
            item.deinit(allocator);
            recovery.dangling_tool_calls_removed += 1;
        } else {
            if (kept != index) items.items[kept] = item.*;
            kept += 1;
        }
    }
    items.items.len = kept;
}

fn encodeSelection(
    writer: *std.Io.Writer,
    selection: Selection,
    max_line: usize,
) error{ OutOfMemory, LineTooLarge }!void {
    const start = writer.end;
    var json: std.json.Stringify = .{ .writer = writer };
    json.beginObject() catch return error.OutOfMemory;
    jsonField(&json, "type", "selection") catch return error.OutOfMemory;
    try jsonSelection(&json, selection);
    json.endObject() catch return error.OutOfMemory;
    writer.writeByte('\n') catch return error.OutOfMemory;
    if (writer.end - start > max_line + 1) return error.LineTooLarge;
}

fn jsonSelection(json: *std.json.Stringify, selection: Selection) error{OutOfMemory}!void {
    jsonOptional(json, "provider", selection.provider) catch return error.OutOfMemory;
    jsonOptional(json, "model", selection.model) catch return error.OutOfMemory;
    jsonOptional(json, "model_label", persistedModelLabel(selection)) catch return error.OutOfMemory;
    jsonOptional(json, "effort", selection.effort) catch return error.OutOfMemory;
    jsonOptional(json, "preset", nonEmpty(selection.preset)) catch return error.OutOfMemory;
}

fn jsonField(json: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try json.objectField(name);
    try json.write(value);
}

fn jsonOptional(json: *std.json.Stringify, name: []const u8, value: ?[]const u8) !void {
    if (value) |bytes| try jsonField(json, name, bytes);
}

fn recordWithinBounds(
    allocator: std.mem.Allocator,
    line: []const u8,
    limits: ItemJson.Limits,
) error{OutOfMemory}!bool {
    var scanner = std.json.Scanner.initCompleteInput(allocator, line);
    defer scanner.deinit();
    var depth: usize = 0;
    var fields: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            limits.max_line_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer if (token == .allocated_string) allocator.free(token.allocated_string);
        tokens += 1;
        if (tokens > limits.max_tokens) return false;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.max_nesting) return false;
            },
            .object_end, .array_end => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .string, .allocated_string => if (scanner.string_is_object_key) {
                fields += 1;
                if (fields > limits.max_fields) return false;
            },
            .end_of_document => return depth == 0,
            else => {},
        }
    }
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_file_bytes == 0 or limits.max_file_bytes > 8 * 1024 * 1024 or
        limits.max_line_bytes == 0 or limits.max_line_bytes > 8 * 1024 * 1024 or
        limits.max_line_bytes > limits.max_file_bytes or limits.max_items == 0 or
        limits.max_items > 4096 or limits.retained_bytes == 0 or
        limits.retained_bytes > 64 * 1024 * 1024 or limits.max_images == 0 or
        limits.max_images > 4096 or limits.max_image_base64_bytes == 0 or
        limits.max_image_base64_bytes > 256 * 1024 * 1024 or
        limits.paths.max_cwd_bytes == 0 or
        limits.paths.max_cwd_bytes > Paths.hard_max_bytes or
        limits.paths.max_path_bytes == 0 or
        limits.paths.max_path_bytes > Paths.hard_max_bytes or
        limits.item_json.max_line_bytes == 0 or
        limits.item_json.max_line_bytes > ItemJson.default_max_line_bytes or
        limits.item_json.max_nesting == 0 or
        limits.item_json.max_nesting > ItemJson.default_max_nesting or
        limits.item_json.max_fields == 0 or
        limits.item_json.max_fields > ItemJson.default_max_fields or
        limits.item_json.max_tokens == 0 or
        limits.item_json.max_tokens > ItemJson.default_max_tokens)
    {
        return error.InvalidLimits;
    }
}

fn validateGitState(state: GitState) error{InvalidHeader}!void {
    for ([_]?[]const u8{ state.branch, state.commit, state.subject }) |value| {
        const bytes = value orelse continue;
        if (bytes.len > maximum_selection_field_bytes or
            !std.unicode.utf8ValidateSlice(bytes) or
            std.mem.findScalar(u8, bytes, 0) != null)
        {
            return error.InvalidHeader;
        }
    }
}

fn validateSelection(selection: Selection) !void {
    var total: usize = 0;
    for ([_]?[]const u8{
        selection.provider,
        selection.model,
        selection.model_label,
        selection.effort,
        selection.preset,
    }) |value| if (value) |bytes| {
        if (bytes.len > maximum_selection_field_bytes or
            !std.unicode.utf8ValidateSlice(bytes) or
            std.mem.findScalar(u8, bytes, 0) != null)
        {
            return error.InvalidSelection;
        }
        total = std.math.add(usize, total, bytes.len) catch return error.InvalidSelection;
        if (total > maximum_selection_bytes) return error.InvalidSelection;
    };
}

fn selectionCoreEqual(a: Selection, b: Selection) bool {
    return optionalEqual(a.provider, b.provider) and optionalEqual(a.model, b.model) and
        optionalEqual(a.effort, b.effort) and optionalEqual(a.preset, b.preset);
}

fn selectionEqual(a: Selection, b: Selection) bool {
    return selectionCoreEqual(a, b) and optionalEqual(a.model_label, b.model_label);
}

fn persistedModelLabel(selection: Selection) ?[]const u8 {
    const label = nonEmpty(selection.model_label) orelse return null;
    const model = nonEmpty(selection.model) orelse return label;
    return if (std.mem.eql(u8, label, model)) null else label;
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const left = nonEmpty(a);
    const right = nonEmpty(b);
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const bytes = value orelse return null;
    return if (bytes.len == 0) null else bytes;
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

fn optionalJsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn dupeJsonOptional(allocator: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) !?[]u8 {
    return dupeOptional(allocator, optionalJsonString(object, name));
}

fn safeAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or std.mem.findScalar(u8, path, 0) != null) return false;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validateIoPathLength(path: []const u8, max: usize) Error!void {
    if (path.len > max or path.len >= std.fs.max_path_bytes) return error.PathTooLong;
}

fn joinPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8, max: usize) Error![]u8 {
    const length = std.math.add(usize, directory.len, name.len + 1) catch return error.PathTooLong;
    if (length > max or length >= std.fs.max_path_bytes) return error.PathTooLong;
    const result = allocator.alloc(u8, length) catch return error.OutOfMemory;
    @memcpy(result[0..directory.len], directory);
    result[directory.len] = '/';
    @memcpy(result[directory.len + 1 ..], name);
    return result;
}

fn uuidString(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    const name = try Paths.canonicalNameFromEpoch(0, uuid);
    return allocator.dupe(u8, name[21..57]);
}

fn setDirectoryMode(io: std.Io, path: []const u8) !void {
    var directory = try std.Io.Dir.openDir(.cwd(), io, path, .{ .follow_symlinks = false });
    defer directory.close(io);
    const file: std.Io.File = .{ .handle = directory.handle, .flags = .{ .nonblocking = false } };
    try file.setPermissions(io, .fromMode(0o700));
}

fn mapAlloc(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSelection,
    };
}

fn mapPath(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PathTooLong, error.CwdTooLong => error.PathTooLong,
        else => error.InvalidPath,
    };
}

fn mapCut(err: SessionCut.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidLimits => error.InvalidLimits,
        error.FileTooLarge => error.FileTooLarge,
        error.LineTooLarge => error.LineTooLarge,
        error.TooManyTokens, error.TooDeep, error.TooManyTurns => error.ResourceLimit,
    };
}

fn mapCutForPlan(err: SessionCut.Error) CutError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooLarge => error.FileTooLarge,
        error.LineTooLarge => error.LineTooLarge,
        error.InvalidLimits, error.TooManyTokens, error.TooDeep, error.TooManyTurns => error.InvalidPlan,
    };
}

fn mapCutSelectionError(err: Error) CutError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooLarge => error.FileTooLarge,
        error.LineTooLarge => error.LineTooLarge,
        error.NotRegular => error.NotRegular,
        error.Removed => error.Removed,
        else => error.InvalidPlan,
    };
}

fn mapLegacyCutError(err: CutError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooLarge => error.FileTooLarge,
        error.LineTooLarge => error.LineTooLarge,
        error.TooManyItems => error.TooManyItems,
        error.Poisoned => error.Poisoned,
        error.NotRegular => error.NotRegular,
        error.Removed => error.Removed,
        error.InvalidPlan, error.IoFailure => error.IoFailure,
    };
}

fn mapLegacyTruncateError(err: TruncateError) Error {
    return switch (err) {
        error.StaleCut, error.HighWaterMismatch => error.IoFailure,
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooLarge => error.FileTooLarge,
        error.LineTooLarge => error.LineTooLarge,
        error.TooManyItems => error.TooManyItems,
        error.Poisoned => error.Poisoned,
        error.NotRegular => error.NotRegular,
        error.Removed => error.Removed,
        error.InvalidPlan, error.IoFailure => error.IoFailure,
    };
}

fn mapSession(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyItems => error.TooManyItems,
        else => error.InvalidSelection,
    };
}

fn loadAllocationExercise(allocator: std.mem.Allocator, path: []const u8) !void {
    var loaded = try load(allocator, std.testing.io, path, .{});
    loaded.deinit();
}

fn mutateSnapshotByte(
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    if (expected.len == 0) return error.IoFailure;
    const writer = std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_write }) catch
        return error.IoFailure;
    defer writer.close(io);
    const byte = [_]u8{expected[0] ^ 1};
    writer.writePositionalAll(io, &byte, 0) catch return error.IoFailure;
    return verifyStableSnapshot(io, file, path, stat, expected);
}

fn growSnapshot(
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    const writer = std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_write }) catch
        return error.IoFailure;
    defer writer.close(io);
    writer.writePositionalAll(io, "x", @intCast(expected.len)) catch return error.IoFailure;
    return verifyStableSnapshot(io, file, path, stat, expected);
}

fn unlinkSnapshot(
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch return error.IoFailure;
    return verifyStableSnapshot(io, file, path, stat, expected);
}

fn renameSnapshot(
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const moved = std.fmt.bufPrint(&buffer, "{s}.moved", .{path}) catch return error.IoFailure;
    std.Io.Dir.rename(.cwd(), path, .cwd(), moved, io) catch return error.IoFailure;
    return verifyStableSnapshot(io, file, path, stat, expected);
}

fn replaceSnapshot(
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const moved = std.fmt.bufPrint(&buffer, "{s}.old", .{path}) catch return error.IoFailure;
    std.Io.Dir.rename(.cwd(), path, .cwd(), moved, io) catch return error.IoFailure;
    const replacement = std.Io.Dir.createFile(.cwd(), io, path, .{}) catch return error.IoFailure;
    defer replacement.close(io);
    replacement.writeStreamingAll(io, expected) catch return error.IoFailure;
    return verifyStableSnapshot(io, file, path, stat, expected);
}

test "lazy builder and direct APIs enforce the syscall path boundary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    const suffix_bytes = "/sessions/".len + "root.44bd54d473cd3d44".len +
        1 + Paths.canonical_name_bytes;
    const accepted_root_len = std.fs.max_path_bytes - 1 - suffix_bytes;
    const accepted_root = try allocator.alloc(u8, accepted_root_len);
    defer allocator.free(accepted_root);
    @memset(accepted_root, 'a');
    accepted_root[0] = '/';
    var log = try Log.prepare(allocator, io, .{
        .state_root = accepted_root,
        .cwd = "/",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = uuid,
        .writer_version = "test",
    });
    defer log.deinit();
    try std.testing.expectEqual(std.fs.max_path_bytes - 1, log.path().len);

    const rejected_root = try allocator.alloc(u8, accepted_root_len + 1);
    defer allocator.free(rejected_root);
    @memset(rejected_root, 'a');
    rejected_root[0] = '/';
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.PathTooLong, Log.prepare(failing.allocator(), io, .{
        .state_root = rejected_root,
        .cwd = "/",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = uuid,
        .writer_version = "test",
    }));

    const accepted_path = try allocator.alloc(u8, std.fs.max_path_bytes - 1);
    defer allocator.free(accepted_path);
    @memset(accepted_path, 'a');
    accepted_path[0] = '/';
    const rejected_path = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(rejected_path);
    @memset(rejected_path, 'a');
    rejected_path[0] = '/';

    try std.testing.expectError(error.IoFailure, readMeta(allocator, io, accepted_path, .{}));
    try std.testing.expectError(error.IoFailure, load(allocator, io, accepted_path, .{}));
    try std.testing.expectError(error.IoFailure, loadForResume(allocator, io, accepted_path, .{}));
    try std.testing.expectError(error.IoFailure, Log.resumeExisting(allocator, io, .{
        .path = accepted_path,
        .selection = .{},
        .loaded_item_count = 0,
    }));
    try std.testing.expectError(error.IoFailure, touch(io, accepted_path));

    try std.testing.expectError(error.PathTooLong, readMeta(allocator, io, rejected_path, .{}));
    try std.testing.expectError(error.PathTooLong, load(allocator, io, rejected_path, .{}));
    try std.testing.expectError(error.PathTooLong, loadForResume(allocator, io, rejected_path, .{}));
    try std.testing.expectError(error.PathTooLong, Log.resumeExisting(allocator, io, .{
        .path = rejected_path,
        .selection = .{},
        .loaded_item_count = 0,
    }));
    try std.testing.expectError(error.PathTooLong, touch(io, rejected_path));
}

fn mismatchedNamedIdentity(_: std.Io, _: []const u8) error{IoFailure}!NativeIdentity.Identity {
    return .{ .device = std.math.maxInt(u64), .inode = 0 };
}

fn failPrivatePermissions(_: std.Io, _: std.Io.File) error{IoFailure}!void {
    return error.IoFailure;
}

test "resume loaders reserve a missing separator without mutating the candidate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/bounded.jsonl", .{root});
    defer allocator.free(path);
    const fixture = "{\"type\":\"session\",\"version\":1}";
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    try file.writeStreamingAll(io, fixture);
    try file.setPermissions(io, .fromMode(0o644));
    file.close(io);
    const limits: Limits = .{ .max_file_bytes = fixture.len, .max_line_bytes = fixture.len };

    try std.testing.expectError(error.FileTooLarge, loadStableForResume(allocator, io, path, limits));
    try std.testing.expectError(error.FileTooLarge, loadLockedForResume(allocator, io, path, limits));
    file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    try std.testing.expectEqual(@as(u64, fixture.len), stat.size);
    try std.testing.expectEqual(@as(u16, 0o644), @as(u16, @intCast(stat.permissions.toMode() & 0o777)));
}

test "locked resume preparation preserves mode and post-publication operation verifies identity and privacy" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/candidate.jsonl", .{root});
    defer allocator.free(path);
    const fixture =
        "{\"type\":\"session\",\"version\":1}\n" ++
        "{\"kind\":\"user\",\"text\":\"kept\"}\n";
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    try file.writeStreamingAll(io, fixture);
    try file.setPermissions(io, .fromMode(0o644));
    file.close(io);

    var resumed = try loadLockedForResume(allocator, io, path, .{});
    defer resumed.deinit();
    file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    var stat = try file.stat(io);
    try std.testing.expectEqual(@as(u16, 0o644), @as(u16, @intCast(stat.permissions.toMode() & 0o777)));
    file.close(io);

    resumed.log.named_identity_fn = mismatchedNamedIdentity;
    try std.testing.expectError(error.IoFailure, resumed.log.tightenPrivate());
    resumed.log.named_identity_fn = NativeIdentity.named;
    resumed.log.set_permissions_fn = failPrivatePermissions;
    try std.testing.expectError(error.IoFailure, resumed.log.tightenPrivate());
    resumed.log.set_permissions_fn = setPrivatePermissions;
    try resumed.log.tightenPrivate();
    try std.testing.expectError(error.Unavailable, resumed.log.tightenPrivate());
    file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    stat = try file.stat(io);
    file.close(io);
    try std.testing.expectEqual(@as(u16, 0o600), @as(u16, @intCast(stat.permissions.toMode() & 0o777)));
}

test "locked resume hardening rejects post-load snapshot drift" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const fixture =
        "{\"type\":\"session\",\"version\":1}\n" ++
        "{\"kind\":\"user\",\"text\":\"kept\"}\n";
    const Drift = enum { same_size, size, replacement };

    for ([_]Drift{ .same_size, .size, .replacement }, 0..) |drift, index| {
        const path = try std.fmt.allocPrint(allocator, "{s}/harden-{d}.jsonl", .{ root, index });
        defer allocator.free(path);
        var candidate = try std.Io.Dir.createFile(.cwd(), io, path, .{});
        try candidate.writeStreamingAll(io, fixture);
        try candidate.setPermissions(io, .fromMode(0o644));
        candidate.close(io);

        var resumed = try loadLockedForResume(allocator, io, path, .{});
        defer resumed.deinit();
        switch (drift) {
            .same_size => {
                const writer = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_write });
                defer writer.close(io);
                try writer.writePositionalAll(io, "X", 0);
            },
            .size => {
                const writer = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_write });
                defer writer.close(io);
                try writer.setLength(io, fixture.len + 1);
            },
            .replacement => {
                const moved = try std.fmt.allocPrint(allocator, "{s}.old", .{path});
                defer allocator.free(moved);
                try std.Io.Dir.rename(.cwd(), path, .cwd(), moved, io);
                const replacement = try std.Io.Dir.createFile(.cwd(), io, path, .{});
                defer replacement.close(io);
                try replacement.writeStreamingAll(io, fixture);
                try replacement.setPermissions(io, .fromMode(0o644));
            },
        }

        try std.testing.expectError(error.IoFailure, resumed.log.tightenPrivate());
        const named = try std.Io.Dir.openFile(.cwd(), io, path, .{});
        defer named.close(io);
        const named_stat = try named.stat(io);
        try std.testing.expectEqual(
            @as(u16, 0o644),
            @as(u16, @intCast(named_stat.permissions.toMode() & 0o777)),
        );
    }
}

test "stable resume rejects replacement unlink rename size drift and same-size mutation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const fixture =
        "{\"type\":\"session\",\"version\":1}\n" ++
        "{\"kind\":\"user\",\"text\":\"kept\"}\n";
    const verifiers = [_]SnapshotVerifier{
        replaceSnapshot,
        renameSnapshot,
        unlinkSnapshot,
        growSnapshot,
        mutateSnapshotByte,
    };

    for (verifiers, 0..) |verifier, index| {
        const path = try std.fmt.allocPrint(allocator, "{s}/candidate-{d}.jsonl", .{ root, index });
        defer allocator.free(path);
        var candidate = try std.Io.Dir.createFile(.cwd(), io, path, .{});
        try candidate.writeStreamingAll(io, fixture);
        candidate.close(io);
        try std.testing.expectError(error.IoFailure, loadStableForResumeWithVerifier(
            allocator,
            io,
            path,
            .{},
            verifier,
        ));
    }

    const locked_path = try std.fmt.allocPrint(allocator, "{s}/locked.jsonl", .{root});
    defer allocator.free(locked_path);
    var locked_candidate = try std.Io.Dir.createFile(.cwd(), io, locked_path, .{});
    try locked_candidate.writeStreamingAll(io, fixture);
    locked_candidate.close(io);
    try std.testing.expectError(error.IoFailure, loadLockedForResumeWithVerifier(
        allocator,
        io,
        locked_path,
        .{},
        mutateSnapshotByte,
    ));
}

test "locked and stable resume share empty recovery and bounds behavior" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const empty_path = try std.fmt.allocPrint(allocator, "{s}/empty.jsonl", .{root});
    defer allocator.free(empty_path);
    var file = try std.Io.Dir.createFile(.cwd(), io, empty_path, .{});
    file.close(io);

    var empty_stable = try loadStableForResume(allocator, io, empty_path, .{});
    defer empty_stable.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_stable.item_high_water);
    var empty_locked = try loadLockedForResume(allocator, io, empty_path, .{});
    defer empty_locked.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_locked.loaded.item_high_water);

    const path = try std.fmt.allocPrint(allocator, "{s}/recovery.jsonl", .{root});
    defer allocator.free(path);
    const fixture =
        "{\"type\":\"session\",\"version\":1}\n" ++
        "{\"kind\":\"user\",\"text\":\"kept\"}\n" ++
        "not-json\n" ++
        "{\"kind\":\"tool_call\",\"call_id\":\"c\",\"tool_name\":\"read\",\"arguments\":\"{}\"}\n";
    file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    try file.writeStreamingAll(io, fixture);
    file.close(io);

    var locked = try loadLockedForResume(allocator, io, path, .{});
    try std.testing.expectEqual(@as(usize, 1), locked.loaded.item_high_water);
    try std.testing.expectEqual(@as(usize, 1), locked.loaded.recovery.malformed_lines);
    try std.testing.expectEqual(@as(usize, 1), locked.loaded.recovery.dangling_tool_calls_removed);
    locked.deinit();
    var stable = try loadStableForResume(allocator, io, path, .{});
    defer stable.deinit();
    try std.testing.expectEqual(@as(usize, 1), stable.item_high_water);
    try std.testing.expectEqual(@as(usize, 1), stable.recovery.malformed_lines);
    try std.testing.expectEqual(@as(usize, 1), stable.recovery.dangling_tool_calls_removed);

    const competitor = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_only });
    defer competitor.close(io);
    try std.testing.expect(try competitor.tryLock(io, .exclusive));
    competitor.unlock(io);

    try std.testing.expectError(error.TooManyItems, loadStableForResume(
        allocator,
        io,
        path,
        .{ .max_items = 1 },
    ));
    try std.testing.expectError(error.TooManyItems, loadLockedForResume(
        allocator,
        io,
        path,
        .{ .max_items = 1 },
    ));
}

test "touch advances session timestamps and rejects unsafe paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fmt.allocPrint(allocator, "{s}/session.jsonl", .{root});
    defer allocator.free(path);
    const link_path = try std.fmt.allocPrint(allocator, "{s}/link.jsonl", .{root});
    defer allocator.free(link_path);
    const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing.jsonl", .{root});
    defer allocator.free(missing_path);

    var file = try tmp.dir.createFile(io, "session.jsonl", .{ .read = true });
    try file.setTimestamps(io, .{
        .access_timestamp = .{ .new = .fromNanoseconds(std.time.ns_per_s) },
        .modify_timestamp = .{ .new = .fromNanoseconds(std.time.ns_per_s) },
    });
    file.close(io);
    try tmp.dir.symLink(io, "session.jsonl", "link.jsonl", .{});

    try touch(io, path);
    file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    const stat = try file.stat(io);
    file.close(io);
    try std.testing.expect(stat.atime.?.nanoseconds > std.time.ns_per_s);
    try std.testing.expect(stat.mtime.nanoseconds > std.time.ns_per_s);
    try std.testing.expectError(error.NotRegular, touch(io, link_path));
    try std.testing.expectError(error.IoFailure, touch(io, missing_path));
    try std.testing.expectError(error.InvalidPath, touch(io, "relative.jsonl"));
}

test "resumed log hint prefers header id and falls back to canonical path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    const name = try Paths.canonicalName(.{ .epoch_seconds = 0 }, uuid);
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ root_buffer[0..root_len], name },
    );
    defer allocator.free(path);

    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{
        .read = true,
        .permissions = .fromMode(0o600),
    });
    try file.writeStreamingAll(io, "{\"type\":\"session\",\"id\":\"stored-id\"}\n");
    file.close(io);
    {
        var log = try Log.resumeExisting(allocator, io, .{
            .path = path,
            .selection = .{},
            .loaded_item_count = 0,
        });
        defer log.deinit();
        try std.testing.expectEqualStrings("stored-id", log.resumeHint().?);
    }

    file = try std.Io.Dir.createFile(.cwd(), io, path, .{
        .read = true,
        .truncate = true,
        .permissions = .fromMode(0o600),
    });
    try file.writeStreamingAll(io, "{\"type\":\"session\"}\n");
    file.close(io);
    var log = try Log.resumeExisting(allocator, io, .{
        .path = path,
        .selection = .{},
        .loaded_item_count = 0,
    });
    defer log.deinit();
    try std.testing.expectEqualStrings(
        "550e8400-e29b-41d4-a716-446655440000",
        log.resumeHint().?,
    );
}

test "prepared selection drop and publication preserve pending semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_length];
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    var log = try Log.prepare(allocator, io, .{
        .state_root = root,
        .cwd = "/work",
        .selection = .{ .provider = "alpha", .model = "m1", .model_label = "One" },
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = uuid,
        .writer_version = "test",
    });
    defer log.deinit();

    var dropped = try log.prepareSelection(.{ .provider = "beta", .model = "m2" });
    dropped.deinit();
    try std.testing.expectEqualStrings("alpha", log.currentSelection().provider.?);
    try std.testing.expect(!log.materialized());
    try std.testing.expect(!log.selection_pending);

    var label = try log.prepareSelection(.{
        .provider = "alpha",
        .model = "m1",
        .model_label = "First",
    });
    try std.testing.expect(!label.core_changed);
    log.publishSelection(&label);
    label.deinit();
    try std.testing.expectEqualStrings("First", log.currentSelection().model_label.?);
    try std.testing.expect(!log.selection_pending);

    const items = [_]ai.Item.Item{.{ .user_message = .{ .text = @constCast("hello") } }};
    try log.appendSnapshot(0, &items);
    var materialized_label = try log.prepareSelection(.{
        .provider = "alpha",
        .model = "m1",
        .model_label = "Uno",
    });
    log.publishSelection(&materialized_label);
    materialized_label.deinit();
    try std.testing.expect(!log.selection_pending);

    var core = try log.prepareSelection(.{ .provider = "beta", .model = "m2" });
    try std.testing.expect(core.core_changed);
    log.publishSelection(&core);
    core.deinit();
    try std.testing.expect(log.selection_pending);
}

test "lazy materialization and load round trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_length];
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    var session_path: []u8 = undefined;
    {
        var log = try Log.prepare(allocator, io, .{
            .state_root = root,
            .cwd = "/work",
            .selection = .{ .provider = "alpha", .model = "m1", .preset = "initial" },
            .timestamp = .{ .epoch_seconds = 0 },
            .uuid = uuid,
            .writer_version = "0.4.0",
        });
        defer log.deinit();
        try std.testing.expect(!log.materialized());
        try std.testing.expectEqualStrings(
            "550e8400-e29b-41d4-a716-446655440000",
            log.resumeHint().?,
        );
        const items = [_]ai.Item.Item{
            .{ .user_message = .{ .text = @constCast("hello") } },
            .{ .assistant_message = .{ .text = @constCast("world") } },
        };
        try log.appendSnapshot(0, items[0..1]);
        try log.setSelection(.{ .provider = "beta", .model = "m2", .preset = "resumed" });
        try log.appendSnapshot(1, &items);
        try std.testing.expect(log.materialized());
        try log.sync();
        try std.testing.expectError(error.SessionBusy, Log.resumeExisting(allocator, io, .{
            .path = log.path(),
            .selection = .{ .provider = "beta", .model = "m2" },
            .loaded_item_count = 2,
        }));
        try std.testing.expectError(error.SessionBusy, readMeta(allocator, io, log.path(), .{}));
        session_path = try allocator.dupe(u8, log.path());
    }
    defer allocator.free(session_path);
    const encoded = try std.Io.Dir.readFileAlloc(.cwd(), io, session_path, allocator, .unlimited);
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"zi_version\":\"0.4.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "hax" ++ "_version") == null);
    var loaded = try load(allocator, io, session_path, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.session.items().len);
    try std.testing.expectEqualStrings("hello", loaded.session.items()[0].user_message.text);
    try std.testing.expectEqualStrings("beta", loaded.meta.selection.provider.?);
    try std.testing.expectEqualStrings("m2", loaded.meta.selection.model.?);
    try std.testing.expectEqualStrings("resumed", loaded.session.preset.?);
    try std.testing.expectEqualStrings("beta", loaded.last_selection.provider.?);
    try std.testing.expectEqualStrings("m2", loaded.last_selection.model.?);
    var metadata = try readMeta(allocator, io, session_path, .{});
    defer metadata.deinit(allocator);
    try std.testing.expectEqualStrings("beta", metadata.selection.provider.?);
    try std.testing.expectEqualStrings("m2", metadata.selection.model.?);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    var log = try Log.prepare(allocator, std.testing.io, .{
        .state_root = "/tmp/zi-session-allocation-test",
        .cwd = "/work",
        .selection = .{
            .provider = "alpha",
            .model = "model",
            .model_label = "Model",
            .effort = "high",
            .preset = "default",
        },
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = uuid,
        .writer_version = "0.4.0",
    });
    log.deinit();
}

test "prepare owns every lazy input and handles allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "hax header policy and torn resume preserve the first byte and repair on append" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/fixture.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(path);

    const fixture =
        "{\"type\":\"session\",\"version\":1,\"provider\":\"alpha\",\"model\":\"m1\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"old\"}\n" ++
        "{\"kind\":\"assistant\",\"text\":";
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{
        .read = true,
        .permissions = .fromMode(0o644),
    });
    try file.writeStreamingAll(io, fixture);
    file.close(io);

    var first_load = try loadStableForResume(allocator, io, path, .{});
    try std.testing.expectEqual(@as(usize, 1), first_load.session.items().len);
    try std.testing.expectEqual(@as(usize, 1), first_load.recovery.torn_tail_lines);
    first_load.deinit();

    var resumed = try loadLockedForResume(allocator, io, path, .{});
    file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    var stat = try file.stat(io);
    try std.testing.expectEqual(@as(u64, fixture.len), stat.size);
    try std.testing.expectEqual(@as(u16, 0o644), @as(u16, @intCast(stat.permissions.toMode() & 0o777)));
    file.close(io);

    const item: ai.Item.Item = .{ .assistant_message = .{ .text = @constCast("new") } };
    try resumed.loaded.session.appendCopy(&item);
    try resumed.log.appendSnapshot(resumed.log.highWater(), resumed.loaded.session.items());
    resumed.deinit();

    file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer file.close(io);
    var first: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try file.readPositionalAll(io, &first, 0));
    try std.testing.expectEqual(@as(u8, '{'), first[0]);
    stat = try file.stat(io);
    try std.testing.expectEqual(@as(u16, 0o644), @as(u16, @intCast(stat.permissions.toMode() & 0o777)));

    var repaired = try load(allocator, io, path, .{});
    defer repaired.deinit();
    try std.testing.expectEqual(@as(usize, 2), repaired.session.items().len);
    try std.testing.expectEqualStrings("new", repaired.session.items()[1].assistant_message.text);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        loadAllocationExercise,
        .{path},
    );
}

test "load ignores unknown session header metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/unknown-header.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(path);
    const fixture =
        "{\"type\":\"session\",\"version\":1,\"future_metadata\":{\"value\":7}," ++
        "\"provider\":\"alpha\",\"model\":\"m1\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"kept\"}\n";
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    try file.writeStreamingAll(io, fixture);
    file.close(io);

    var loaded = try load(allocator, io, path, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.session.items().len);
    try std.testing.expectEqualStrings("kept", loaded.session.items()[0].user_message.text);
    try std.testing.expectEqualStrings("alpha", loaded.meta.selection.provider.?);
    try std.testing.expectEqualStrings("m1", loaded.meta.selection.model.?);
}

test "headerless records, early selections, and unknown type fields follow hax" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/headerless.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(path);
    const fixture =
        "{\"type\":\"selection\",\"provider\":\"beta\",\"model\":\"m2\"}\n" ++
        "{\"type\":\"future\",\"kind\":\"user\",\"text\":\"kept\"}\n";
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    try file.writeStreamingAll(io, fixture);
    file.close(io);

    var loaded = try load(allocator, io, path, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.session.items().len);
    try std.testing.expectEqualStrings("kept", loaded.session.items()[0].user_message.text);
    try std.testing.expectEqualStrings("beta", loaded.meta.selection.provider.?);
    try std.testing.expectEqualStrings("m2", loaded.last_selection.model.?);

    try std.testing.expectError(error.ResourceLimit, load(allocator, io, path, .{
        .retained_bytes = 3,
    }));
}

test "load degrades image groups beyond hax request count" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x01,
    };
    var log = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{ .provider = "alpha", .model = "m1" },
        .timestamp = .{ .epoch_seconds = 1 },
        .uuid = uuid,
        .writer_version = "0.4.0",
    });
    var mime = "image/png".*;
    var data = "YQ==".*;
    var images: [21]ai.Item.Image = undefined;
    for (&images) |*image| image.* = .{ .mime = &mime, .data_base64 = &data };
    const items = [_]ai.Item.Item{.{ .user_message = .{
        .text = @constCast("images"),
        .images = &images,
    } }};
    try log.appendSnapshot(0, &items);
    const path = try allocator.dupe(u8, log.path());
    log.deinit();
    defer allocator.free(path);

    var locked = try loadLockedForResume(allocator, io, path, .{});
    try std.testing.expectEqual(@as(usize, 21), locked.loaded.recovery.images_degraded);
    try std.testing.expectEqual(@as(usize, 0), locked.loaded.session.items()[0].user_message.images.len);
    locked.deinit();

    var stable = try loadStableForResume(allocator, io, path, .{});
    defer stable.deinit();
    try std.testing.expectEqual(@as(usize, 21), stable.recovery.images_degraded);
    try std.testing.expectEqual(@as(usize, 0), stable.session.items()[0].user_message.images.len);
    try std.testing.expectEqualStrings("images", stable.session.items()[0].user_message.text);
}

fn failBeforeWrite(
    _: std.Io,
    _: std.Io.File,
    _: []const u8,
    _: u64,
) error{IoFailure}!void {
    return error.IoFailure;
}

fn commitThenFail(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    offset: u64,
) error{IoFailure}!void {
    file.writePositionalAll(io, bytes, offset) catch return error.IoFailure;
    return error.IoFailure;
}

fn failAfterPrefix(
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    offset: u64,
) error{IoFailure}!void {
    const prefix_len = @max(@as(usize, 1), bytes.len / 2);
    file.writePositionalAll(io, bytes[0..prefix_len], offset) catch return error.IoFailure;
    return error.IoFailure;
}

fn failSyncFile(_: std.Io, _: std.Io.File) error{IoFailure}!void {
    return error.IoFailure;
}

fn overwriteThenVerify(
    io: std.Io,
    file: std.Io.File,
    initial_stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    if (expected.len == 0) return error.IoFailure;
    const replacement = [_]u8{expected[0] ^ 1};
    file.writePositionalAll(io, &replacement, 0) catch return error.IoFailure;
    return verifySnapshot(io, file, initial_stat, expected);
}

fn shrinkThenVerify(
    io: std.Io,
    file: std.Io.File,
    initial_stat: std.Io.File.Stat,
    expected: []const u8,
) error{IoFailure}!void {
    if (expected.len == 0) return error.IoFailure;
    file.setLength(io, expected.len - 1) catch return error.IoFailure;
    return verifySnapshot(io, file, initial_stat, expected);
}

fn failDeleteForkTarget(_: std.Io, _: []const u8) error{IoFailure}!void {
    return error.IoFailure;
}

fn failSyncDirectory(_: std.Io, _: []const u8) error{IoFailure}!void {
    return error.IoFailure;
}

test "classified append distinguishes unchanged committed and indeterminate writes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const uuid = [_]u8{ 9, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 9 };
    var log = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{ .provider = "alpha", .model = "m1" },
        .timestamp = .{ .epoch_seconds = 9 },
        .uuid = uuid,
        .writer_version = "test",
    });
    defer log.deinit();
    const items = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("one") } },
        .{ .assistant_message = .{ .text = @constCast("two") } },
        .turn_boundary,
    };

    try std.testing.expectEqual(AppendOutcome.unchanged, try log.appendSnapshotClassified(0, items[0..0]));
    log.commit_fn = failBeforeWrite;
    try std.testing.expectEqual(AppendOutcome.unchanged, try log.appendSnapshotClassified(0, items[0..1]));
    try std.testing.expect(!log.materialized());
    try std.testing.expect(!log.poisoned);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(
        .cwd(),
        io,
        log.path(),
        .{ .follow_symlinks = false },
    ));

    const committed_synced: AppendOutcome = .{ .committed = .synced };
    log.commit_fn = commitAll;
    try std.testing.expectEqual(
        committed_synced,
        try log.appendSnapshotClassified(0, items[0..1]),
    );
    log.commit_fn = commitThenFail;
    try std.testing.expectEqual(
        committed_synced,
        try log.appendSnapshotClassified(1, items[0..2]),
    );
    try std.testing.expectEqual(@as(usize, 2), log.highWater());

    log.commit_fn = commitAll;
    log.append_sync_file_fn = failSyncFile;
    const committed_sync_failed: AppendOutcome = .{ .committed = .sync_failed };
    try std.testing.expectEqual(
        committed_sync_failed,
        try log.appendSnapshotClassified(2, &items),
    );
    try std.testing.expectEqual(@as(usize, 3), log.highWater());
    try std.testing.expect(log.poisoned);
}

test "classified append reports path collision and partial population" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const items = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("one") } },
        .{ .assistant_message = .{ .text = @constCast("two") } },
    };

    const collision_uuid = [_]u8{ 8, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 8 };
    var owner = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 8 },
        .uuid = collision_uuid,
        .writer_version = "test",
    });
    defer owner.deinit();
    try owner.appendSnapshot(0, items[0..1]);
    var collision = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 8 },
        .uuid = collision_uuid,
        .writer_version = "test",
    });
    defer collision.deinit();
    const path_collision: AppendOutcome = .{ .indeterminate = .path_collision };
    try std.testing.expectEqual(
        path_collision,
        try collision.appendSnapshotClassified(0, items[0..1]),
    );
    try std.testing.expect(collision.poisoned);

    const partial_uuid = [_]u8{ 7, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 7 };
    var partial = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 7 },
        .uuid = partial_uuid,
        .writer_version = "test",
    });
    defer partial.deinit();
    try partial.appendSnapshot(0, items[0..1]);
    partial.commit_fn = failAfterPrefix;
    const partial_write: AppendOutcome = .{ .indeterminate = .partial_write };
    try std.testing.expectEqual(
        partial_write,
        try partial.appendSnapshotClassified(1, &items),
    );
    try std.testing.expectEqual(@as(usize, 1), partial.highWater());
    try std.testing.expect(partial.poisoned);

    const bounded_uuid = [_]u8{ 6, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 6 };
    var bounded = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 6 },
        .uuid = bounded_uuid,
        .writer_version = "test",
        .limits = .{ .max_items = 1 },
    });
    defer bounded.deinit();
    try std.testing.expectError(error.TooManyItems, bounded.appendSnapshotClassified(0, &items));
    try std.testing.expect(!bounded.materialized());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(
        .cwd(),
        io,
        bounded.path(),
        .{ .follow_symlinks = false },
    ));

    const cleanup_uuid = [_]u8{ 5, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 5 };
    var cleanup = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 5 },
        .uuid = cleanup_uuid,
        .writer_version = "test",
    });
    defer cleanup.deinit();
    cleanup.commit_fn = failBeforeWrite;
    cleanup.append_delete_fn = failDeleteForkTarget;
    const cleanup_indeterminate: AppendOutcome = .{ .indeterminate = .cleanup_indeterminate };
    try std.testing.expectEqual(
        cleanup_indeterminate,
        try cleanup.appendSnapshotClassified(0, items[0..1]),
    );
    try std.testing.expect(cleanup.poisoned);
    try std.testing.expect(cleanup.file != null);
}

test "partial append poisons and locks until safe torn-tail recovery" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x02,
    };
    var log = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{ .provider = "alpha", .model = "m1" },
        .timestamp = .{ .epoch_seconds = 2 },
        .uuid = uuid,
        .writer_version = "0.4.0",
    });
    const items = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("first") } },
        .{ .assistant_message = .{ .text = @constCast("second") } },
    };
    try log.appendSnapshot(0, items[0..1]);
    log.commit_fn = failAfterPrefix;
    try std.testing.expectError(error.IoFailure, log.appendSnapshot(1, &items));
    try std.testing.expectEqual(@as(usize, 1), log.highWater());
    try std.testing.expectError(error.Poisoned, log.appendSnapshot(1, &items));
    const path = try allocator.dupe(u8, log.path());
    defer allocator.free(path);
    try std.testing.expectError(error.SessionBusy, Log.resumeExisting(allocator, io, .{
        .path = path,
        .selection = .{ .provider = "alpha", .model = "m1" },
        .loaded_item_count = 1,
    }));
    log.deinit();

    var loaded = try load(allocator, io, path, .{});
    try std.testing.expectEqual(@as(usize, 1), loaded.session.items().len);
    try std.testing.expect(loaded.recovery.torn_tail_lines + loaded.recovery.malformed_lines >= 1);
    const high_water = loaded.item_high_water;
    loaded.deinit();

    var resumed = try Log.resumeExisting(allocator, io, .{
        .path = path,
        .selection = .{ .provider = "alpha", .model = "m1" },
        .loaded_item_count = high_water,
    });
    try resumed.appendSnapshot(1, &items);
    resumed.deinit();
    loaded = try load(allocator, io, path, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.session.items().len);
}

test "truncate retains turns, restates selection, and reappends without a hole" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const uuid = [_]u8{ 1, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1 };
    var log = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{ .provider = "alpha", .model = "m1" },
        .timestamp = .{ .epoch_seconds = 1 },
        .uuid = uuid,
        .writer_version = "0.4.0",
    });
    errdefer log.deinit();
    const items = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("u1") } },
        .{ .assistant_message = .{ .text = @constCast("a1") } },
        .turn_boundary,
        .{ .user_message = .{ .text = @constCast("u2") } },
        .{ .assistant_message = .{ .text = @constCast("a2") } },
        .turn_boundary,
    };
    try log.appendSnapshot(0, items[0..2]);
    try log.setSelection(.{
        .provider = "beta",
        .model = "m2",
        .model_label = "Beta Two",
        .effort = "high",
    });
    try log.appendSnapshot(2, &items);
    const full_size = (try log.file.?.stat(io)).size;

    try log.truncate(2, items.len);
    try std.testing.expectEqual(full_size, (try log.file.?.stat(io)).size);
    try std.testing.expectEqual(items.len, log.highWater());

    try log.truncate(1, 2);
    const cut_size = (try log.file.?.stat(io)).size;
    try std.testing.expect(cut_size < full_size);
    try std.testing.expect(!log.selection_pending);
    try std.testing.expectEqual(@as(usize, 2), log.highWater());
    try log.appendSnapshot(2, items[0..3]);
    try std.testing.expectEqual(@as(u64, @intCast((try log.file.?.stat(io)).size)), log.append_offset);

    log.read_effective_selection_fn = failEffectiveSelection;
    try log.truncate(0, 0);
    try std.testing.expect(log.selection_pending);
    log.read_effective_selection_fn = readEffectiveSelectionOpened;
    try log.appendSnapshot(0, items[0..1]);
    const path = try allocator.dupe(u8, log.path());
    log.deinit();
    defer allocator.free(path);

    var file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    const size: usize = @intCast((try file.stat(io)).size);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    try std.testing.expectEqual(size, try file.readPositionalAll(io, bytes, 0));
    file.close(io);
    try std.testing.expect(std.mem.findScalar(u8, bytes, 0) == null);
    var metadata = try readMeta(allocator, io, path, .{});
    defer metadata.deinit(allocator);
    try std.testing.expectEqualStrings("beta", metadata.selection.provider.?);
    try std.testing.expectEqualStrings("m2", metadata.selection.model.?);
    try std.testing.expectEqualStrings("Beta Two", metadata.selection.model_label.?);
    try std.testing.expectEqualStrings("high", metadata.selection.effort.?);

    var loaded = try load(allocator, io, path, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.session.items().len);
    try std.testing.expectEqualStrings("u1", loaded.session.items()[0].user_message.text);
}

test "truncate keep zero and fresh log no-op" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const uuid = [_]u8{ 2, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 2 };
    var log = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{ .provider = "alpha", .model = "m1" },
        .timestamp = .{ .epoch_seconds = 2 },
        .uuid = uuid,
        .writer_version = "0.4.0",
    });
    defer log.deinit();
    try log.truncate(0, 99);
    try std.testing.expect(!log.materialized());
    try std.testing.expectEqual(@as(usize, 0), log.highWater());

    const items = [_]ai.Item.Item{
        .{ .user_message = .{ .text = @constCast("u") } },
        .{ .assistant_message = .{ .text = @constCast("a") } },
    };
    try log.appendSnapshot(0, &items);
    try log.truncate(0, 0);
    try std.testing.expectEqual(@as(usize, 0), log.highWater());
    const size_after_cut = (try log.file.?.stat(io)).size;
    try std.testing.expect(size_after_cut > 0);
    try log.appendSnapshot(0, items[0..1]);
    try std.testing.expect((try log.file.?.stat(io)).size > size_after_cut);
}

test "truncate failures classify verified original and reported failure after prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/failure.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(path);
    const fixture =
        "{\"type\":\"session\",\"provider\":\"p\",\"model\":\"m\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"u\"}\n" ++
        "{\"kind\":\"assistant\",\"text\":\"a\"}\n";
    var fixture_file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .read = true });
    try fixture_file.writeStreamingAll(io, fixture);
    fixture_file.close(io);
    var log = try Log.resumeExisting(allocator, io, .{
        .path = path,
        .selection = .{ .provider = "p", .model = "m" },
        .loaded_item_count = 2,
    });
    defer log.deinit();
    const old_offset = log.append_offset;
    log.set_length_fn = failSetLength;
    try std.testing.expectError(error.IoFailure, log.truncate(0, 0));
    try std.testing.expectEqual(old_offset, log.append_offset);
    try std.testing.expectEqual(@as(usize, 2), log.highWater());
    try std.testing.expect(!log.poisoned);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    log.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, log.truncate(0, 0));
    log.allocator = allocator;
    try std.testing.expectEqual(old_offset, log.append_offset);
    try std.testing.expectEqual(@as(u64, fixture.len), (try log.file.?.stat(io)).size);

    log.set_length_fn = mutateThenFailSetLength;
    try log.truncate(0, 0);
    try std.testing.expect(!log.poisoned);
    try std.testing.expect(log.append_offset < old_offset);
    try std.testing.expectEqual(@as(usize, 0), log.highWater());
}

test "truncate compares model label and rejects an externally changed size before mutation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const label_path = try std.fmt.allocPrint(
        allocator,
        "{s}/label.jsonl",
        .{root_buffer[0..root_len]},
    );
    defer allocator.free(label_path);
    const fixture =
        "{\"type\":\"session\",\"provider\":\"p\",\"model\":\"m\",\"model_label\":\"Old\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"u\"}\n";
    var file = try std.Io.Dir.createFile(.cwd(), io, label_path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    var label_log = try Log.resumeExisting(allocator, io, .{
        .path = label_path,
        .selection = .{ .provider = "p", .model = "m", .model_label = "New" },
        .loaded_item_count = 1,
    });
    try label_log.truncate(1, 1);
    try std.testing.expect(label_log.selection_pending);
    label_log.deinit();

    const size_path = try std.fmt.allocPrint(
        allocator,
        "{s}/size.jsonl",
        .{root_buffer[0..root_len]},
    );
    defer allocator.free(size_path);
    file = try std.Io.Dir.createFile(.cwd(), io, size_path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    var size_log = try Log.resumeExisting(allocator, io, .{
        .path = size_path,
        .selection = .{ .provider = "p", .model = "m", .model_label = "Old" },
        .loaded_item_count = 1,
    });
    defer size_log.deinit();
    try size_log.file.?.setLength(io, fixture.len - 1);
    try std.testing.expectError(error.IoFailure, size_log.truncate(0, 0));
    try std.testing.expect(!size_log.poisoned);
    try std.testing.expectEqual(@as(u64, fixture.len - 1), (try size_log.file.?.stat(io)).size);
}

test "fork rewrites header preserves raw cut bytes and returns locked live log" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const source_path = try std.fmt.allocPrint(allocator, "{s}/source.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(source_path);
    const fixture =
        " { \"type\" : \"session\", \"id\" : \"old-id\", \"timestamp\":\"old\", " ++
        "\"forked_from\":\"older\", \"unknown\": {\"x\":1}, \"provider\":\"p\", " ++
        "\"model\":\"m\", \"model_label\":\"Old\" }\n" ++
        "raw-prefix\n" ++
        "{\"kind\":\"user\",\"text\":\"u1\"}\n" ++
        "{\"kind\":\"assistant\",\"text\":\"a1\"}\n" ++
        "{\"kind\":\"turn_boundary\"}\n" ++
        "{\"type\":\"selection\",\"provider\":\"q\",\"model\":\"n\",\"model_label\":\"N\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"u2\"}\n" ++
        "{\"kind\":\"assistant\",\"text\":\"a2\"}\n";
    var source_file = try std.Io.Dir.createFile(.cwd(), io, source_path, .{ .read = true });
    try source_file.writeStreamingAll(io, fixture);
    source_file.close(io);
    var source = try Log.resumeExisting(allocator, io, .{
        .path = source_path,
        .selection = .{ .provider = "q", .model = "n", .model_label = "N" },
        .loaded_item_count = 4,
    });
    defer source.deinit();
    const before = try allocator.dupe(u8, fixture);
    defer allocator.free(before);
    const uuid = [_]u8{ 9, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 9 };
    var forked = try source.fork(1, 2, .{ .epoch_seconds = 9 }, uuid, .{
        .provider = "live",
        .model = "z",
        .model_label = "Live Z",
        .effort = "high",
    });
    defer forked.deinit();
    try std.testing.expectEqual(@as(usize, 2), forked.highWater());
    try std.testing.expect(forked.selection_pending);
    const fork_size: usize = @intCast((try forked.file.?.stat(io)).size);
    const bytes = try allocator.alloc(u8, fork_size);
    defer allocator.free(bytes);
    try std.testing.expectEqual(fork_size, try forked.file.?.readPositionalAll(io, bytes, 0));
    const source_lf = std.mem.indexOfScalar(u8, before, '\n').?;
    const target_lf = std.mem.indexOfScalar(u8, bytes, '\n').?;
    const cut = try SessionCut.findCut(allocator, before, 1, .{});
    try std.testing.expectEqualSlices(u8, before[source_lf + 1 .. cut], bytes[target_lf + 1 ..]);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes[0..target_lf], .{});
    defer parsed.deinit();
    const header = parsed.value.object;
    try std.testing.expectEqualStrings("old-id", header.get("forked_from").?.string);
    try std.testing.expectEqual(@as(i64, 1), header.get("unknown").?.object.get("x").?.integer);
    try std.testing.expect(!std.mem.eql(u8, "old-id", header.get("id").?.string));
    try std.testing.expect(!std.mem.eql(u8, "old", header.get("timestamp").?.string));

    try std.testing.expectError(error.SessionBusy, Log.resumeExisting(allocator, io, .{
        .path = forked.path(),
        .selection = .{},
        .loaded_item_count = 2,
    }));
    try std.testing.expectError(error.IoFailure, source.fork(1, 2, .{ .epoch_seconds = 9 }, uuid, .{}));
    const source_stat = try source.file.?.stat(io);
    const source_copy = try allocator.alloc(u8, @intCast(source_stat.size));
    defer allocator.free(source_copy);
    try std.testing.expectEqual(source_copy.len, try source.file.?.readPositionalAll(io, source_copy, 0));
    try std.testing.expectEqualSlices(u8, before, source_copy);
}

test "fork keep zero failure cleanup OOM and unavailable states" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const source_path = try std.fmt.allocPrint(allocator, "{s}/source.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(source_path);
    const fixture =
        "{\"type\":\"session\",\"id\":\"source\",\"provider\":\"p\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"u\"}\n";
    var file = try std.Io.Dir.createFile(.cwd(), io, source_path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    var source = try Log.resumeExisting(allocator, io, .{
        .path = source_path,
        .selection = .{ .provider = "p" },
        .loaded_item_count = 1,
    });
    defer source.deinit();
    const zero_uuid = [_]u8{ 3, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 3 };
    var empty = try source.fork(0, 0, .{ .epoch_seconds = 3 }, zero_uuid, .{ .provider = "p" });
    defer empty.deinit();
    const empty_size: usize = @intCast((try empty.file.?.stat(io)).size);
    const empty_bytes = try allocator.alloc(u8, empty_size);
    defer allocator.free(empty_bytes);
    _ = try empty.file.?.readPositionalAll(io, empty_bytes, 0);
    try std.testing.expectEqual(empty_bytes.len - 1, std.mem.indexOfScalar(u8, empty_bytes, '\n').?);

    const tip_uuid = [_]u8{ 8, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 8 };
    var tip = try source.fork(99, 1, .{ .epoch_seconds = 8 }, tip_uuid, .{ .provider = "p" });
    defer tip.deinit();
    const tip_size: usize = @intCast((try tip.file.?.stat(io)).size);
    const tip_bytes = try allocator.alloc(u8, tip_size);
    defer allocator.free(tip_bytes);
    _ = try tip.file.?.readPositionalAll(io, tip_bytes, 0);
    const source_lf = std.mem.indexOfScalar(u8, fixture, '\n').?;
    const tip_lf = std.mem.indexOfScalar(u8, tip_bytes, '\n').?;
    try std.testing.expectEqualSlices(u8, fixture[source_lf + 1 ..], tip_bytes[tip_lf + 1 ..]);

    const failed_uuid = [_]u8{ 4, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 4 };
    source.commit_fn = failAfterPrefix;
    try std.testing.expectError(error.IoFailure, source.fork(1, 1, .{ .epoch_seconds = 4 }, failed_uuid, .{}));
    source.commit_fn = commitAll;
    const failed_name = try Paths.canonicalName(.{ .epoch_seconds = 4 }, failed_uuid);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(tmp.dir, io, &failed_name, .{}));

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    source.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, source.fork(1, 1, .{ .epoch_seconds = 5 }, failed_uuid, .{}));
    source.allocator = allocator;

    source.poisoned = true;
    try std.testing.expectError(error.Unavailable, source.fork(0, 0, .{ .epoch_seconds = 5 }, failed_uuid, .{}));
    source.poisoned = false;
    var fresh = try Log.prepare(allocator, io, .{
        .state_root = root_buffer[0..root_len],
        .cwd = "/work",
        .selection = .{},
        .timestamp = .{ .epoch_seconds = 6 },
        .uuid = failed_uuid,
        .writer_version = "test",
    });
    defer fresh.deinit();
    try std.testing.expectError(error.Unavailable, fresh.fork(0, 0, .{ .epoch_seconds = 7 }, failed_uuid, .{}));
}

test "fork poisons on same-size and size source snapshot drift" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const fixture = "{\"type\":\"session\",\"id\":\"source\"}\n{\"kind\":\"user\"}\n";
    const verifiers = [_]*const fn (std.Io, std.Io.File, std.Io.File.Stat, []const u8) error{IoFailure}!void{
        overwriteThenVerify,
        shrinkThenVerify,
    };
    for (verifiers, 0..) |verifier, index| {
        const path = try std.fmt.allocPrint(allocator, "{s}/drift-{d}.jsonl", .{ root_buffer[0..root_len], index });
        defer allocator.free(path);
        var file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .read = true });
        try file.writeStreamingAll(io, fixture);
        file.close(io);
        var source = try Log.resumeExisting(allocator, io, .{
            .path = path,
            .selection = .{},
            .loaded_item_count = 1,
        });
        defer source.deinit();
        source.fork_verify_fn = verifier;
        var uuid = [_]u8{ 5, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 5 };
        uuid[15] +%= @intCast(index);
        try std.testing.expectError(error.IoFailure, source.fork(1, 1, .{ .epoch_seconds = 10 }, uuid, .{}));
        try std.testing.expect(source.poisoned);
    }
}

test "fork reports indeterminate target cleanup without poisoning source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const source_path = try std.fmt.allocPrint(allocator, "{s}/cleanup-source.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(source_path);
    const fixture = "{\"type\":\"session\",\"id\":\"source\"}\n{\"kind\":\"user\"}\n";
    var file = try std.Io.Dir.createFile(.cwd(), io, source_path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    var source = try Log.resumeExisting(allocator, io, .{
        .path = source_path,
        .selection = .{},
        .loaded_item_count = 1,
    });
    defer source.deinit();

    const orphan_uuid = [_]u8{ 6, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 6 };
    source.commit_fn = failAfterPrefix;
    source.fork_delete_fn = failDeleteForkTarget;
    try std.testing.expectError(error.IndeterminateCleanup, source.fork(
        1,
        1,
        .{ .epoch_seconds = 11 },
        orphan_uuid,
        .{},
    ));
    try std.testing.expect(!source.poisoned);
    const orphan_name = try Paths.canonicalName(.{ .epoch_seconds = 11 }, orphan_uuid);
    _ = try tmp.dir.statFile(io, &orphan_name, .{});
    try tmp.dir.deleteFile(io, &orphan_name);

    const sync_uuid = [_]u8{ 7, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 7 };
    source.commit_fn = commitAll;
    source.fork_delete_fn = deleteForkTarget;
    source.fork_sync_directory_fn = failSyncDirectory;
    try std.testing.expectError(error.IndeterminateCleanup, source.fork(
        1,
        1,
        .{ .epoch_seconds = 12 },
        sync_uuid,
        .{},
    ));
    try std.testing.expect(!source.poisoned);
    const sync_name = try Paths.canonicalName(.{ .epoch_seconds = 12 }, sync_uuid);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, &sync_name, .{}));
}

test "fork handles absent and nonstring old ids and ignores label-only pending" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const headers = [_][]const u8{
        "{\"type\":\"session\",\"provider\":\"p\",\"model\":\"m\",\"model_label\":\"Old\"}\n",
        "{\"type\":\"session\",\"id\":42,\"forked_from\":\"keep\",\"provider\":\"p\",\"model\":\"m\"}\n",
    };
    for (headers, 0..) |header, index| {
        const source_path = try std.fmt.allocPrint(allocator, "{s}/id-{d}.jsonl", .{ root_buffer[0..root_len], index });
        defer allocator.free(source_path);
        var file = try std.Io.Dir.createFile(.cwd(), io, source_path, .{ .read = true });
        try file.writeStreamingAll(io, header);
        file.close(io);
        var source = try Log.resumeExisting(allocator, io, .{
            .path = source_path,
            .selection = .{ .provider = "p", .model = "m", .model_label = if (index == 0) "Old" else null },
            .loaded_item_count = 0,
        });
        defer source.deinit();
        var uuid = [_]u8{ 8, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 8 };
        uuid[15] +%= @intCast(index);
        var forked = try source.fork(0, 0, .{ .epoch_seconds = 13 + @as(i64, @intCast(index)) }, uuid, .{
            .provider = "p",
            .model = "m",
            .model_label = "New",
        });
        defer forked.deinit();
        try std.testing.expect(!forked.selection_pending);
        const size: usize = @intCast((try forked.file.?.stat(io)).size);
        const bytes = try allocator.alloc(u8, size);
        defer allocator.free(bytes);
        _ = try forked.file.?.readPositionalAll(io, bytes, 0);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes[0 .. bytes.len - 1], .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expect(object.get("id").? == .string);
        if (index == 0) {
            try std.testing.expect(object.get("forked_from") == null);
        } else {
            try std.testing.expectEqualStrings("keep", object.get("forked_from").?.string);
        }
    }
}

test "locked resume retains exclusive lock and appends through the loaded descriptor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const uuid = [_]u8{ 3, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 3 };
    var source = try Log.prepare(allocator, io, .{
        .state_root = root,
        .cwd = "/work",
        .selection = .{ .provider = "p" },
        .timestamp = .{ .epoch_seconds = 0 },
        .uuid = uuid,
        .writer_version = "test",
    });
    const first = [_]ai.Item.Item{.{ .user_message = .{ .text = @constCast("first") } }};
    try source.appendSnapshot(0, &first);
    const path_value = try allocator.dupe(u8, source.path());
    defer allocator.free(path_value);
    source.deinit();

    var resumed = try loadLockedForResume(allocator, io, path_value, .{});
    try std.testing.expectError(error.Busy, touch(io, path_value));
    const competitor = try std.Io.Dir.openFile(.cwd(), io, path_value, .{ .mode = .read_only });
    defer competitor.close(io);
    try std.testing.expect(!try competitor.tryLock(io, .shared));
    try resumed.loaded.session.addBoundary();
    try resumed.log.appendSnapshot(resumed.log.highWater(), resumed.loaded.session.items());
    resumed.deinit();

    try std.testing.expect(try competitor.tryLock(io, .shared));
    competitor.unlock(io);
    var loaded = try load(allocator, io, path_value, .{});
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.session.items().len);
}

test "prepared truncate classifies unchanged reported-prefix and sync failure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const fixture =
        "{\"type\":\"session\",\"provider\":\"p\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"first\"}\n" ++
        "{\"kind\":\"assistant\",\"text\":\"answer\"}\n" ++
        "{\"kind\":\"turn_boundary\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"second\"}\n" ++
        "{\"kind\":\"assistant\",\"text\":\"answer\"}\n";

    const unchanged_path = try std.fmt.allocPrint(allocator, "{s}/unchanged.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(unchanged_path);
    var file = try std.Io.Dir.createFile(.cwd(), io, unchanged_path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    var unchanged_log = try Log.resumeExisting(allocator, io, .{
        .path = unchanged_path,
        .selection = .{ .provider = "p" },
        .loaded_item_count = 5,
    });
    defer unchanged_log.deinit();
    var unchanged_cut = try unchanged_log.prepareCut(1);
    defer unchanged_cut.deinit();
    unchanged_log.set_length_fn = failSetLength;
    const unchanged = try unchanged_log.truncatePrepared(&unchanged_cut, 2);
    try std.testing.expectEqual(
        TruncateUnchanged.set_length_failed_verified_original,
        unchanged.unchanged,
    );
    try std.testing.expectEqual(@as(usize, 5), unchanged_log.highWater());

    const committed_path = try std.fmt.allocPrint(allocator, "{s}/committed.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(committed_path);
    file = try std.Io.Dir.createFile(.cwd(), io, committed_path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    var committed_log = try Log.resumeExisting(allocator, io, .{
        .path = committed_path,
        .selection = .{ .provider = "p" },
        .loaded_item_count = 5,
    });
    defer committed_log.deinit();
    var committed_cut = try committed_log.prepareCut(1);
    defer committed_cut.deinit();
    committed_log.set_length_fn = mutateThenFailSetLength;
    const committed = try committed_log.truncatePrepared(&committed_cut, 2);
    try std.testing.expectEqual(MutationDurability.synced, committed.committed.durability);
    try std.testing.expectEqual(@as(usize, 2), committed_log.highWater());

    const sync_path = try std.fmt.allocPrint(allocator, "{s}/sync.jsonl", .{root_buffer[0..root_len]});
    defer allocator.free(sync_path);
    file = try std.Io.Dir.createFile(.cwd(), io, sync_path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);
    var sync_log = try Log.resumeExisting(allocator, io, .{
        .path = sync_path,
        .selection = .{ .provider = "p" },
        .loaded_item_count = 5,
    });
    defer sync_log.deinit();
    var sync_cut = try sync_log.prepareCut(1);
    defer sync_cut.deinit();
    sync_log.append_sync_file_fn = failSyncFile;
    const sync_outcome = try sync_log.truncatePrepared(&sync_cut, 2);
    try std.testing.expectEqual(MutationDurability.sync_failed, sync_outcome.committed.durability);
    try std.testing.expect(sync_log.poisoned);
}

test "prepared truncate classifies every indeterminate post-mutation observation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const fixture =
        "{\"type\":\"session\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"first\"}\n" ++
        "{\"kind\":\"turn_boundary\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"second\"}\n";
    const cases = [_]struct {
        name: []const u8,
        set_length: *const fn (std.Io, std.Io.File, u64) error{IoFailure}!void,
        post: *const fn (*Log, std.Io.File) void,
        expected: TruncateIndeterminate,
    }{
        .{
            .name = "changed",
            .set_length = setUnexpectedLength,
            .post = noTruncatePost,
            .expected = .changed,
        },
        .{
            .name = "removed",
            .set_length = setLength,
            .post = postTruncateRemoved,
            .expected = .removed,
        },
        .{
            .name = "replaced",
            .set_length = setLength,
            .post = postTruncateReplaced,
            .expected = .replaced,
        },
        .{
            .name = "unreadable",
            .set_length = setLength,
            .post = postTruncateUnreadable,
            .expected = .unreadable,
        },
        .{
            .name = "content",
            .set_length = setLength,
            .post = postTruncateContentMismatch,
            .expected = .content_mismatch,
        },
    };
    for (cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{d}-{s}.jsonl",
            .{ root_buffer[0..root_len], index, case.name },
        );
        defer allocator.free(path);
        var file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .read = true });
        try file.writeStreamingAll(io, fixture);
        file.close(io);
        var log = try Log.resumeExisting(allocator, io, .{
            .path = path,
            .selection = .{},
            .loaded_item_count = 3,
        });
        defer log.deinit();
        var prepared = try log.prepareCut(1);
        defer prepared.deinit();
        log.set_length_fn = case.set_length;
        log.truncate_post_fn = case.post;
        const outcome = try log.truncatePrepared(&prepared, 1);
        try std.testing.expectEqual(case.expected, outcome.indeterminate);
        try std.testing.expect(log.poisoned);
    }
}

test "prepared truncate is stale after log mutation and allocates nothing after setLength" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/allocation.jsonl", .{root});
    defer std.testing.allocator.free(path);
    const fixture =
        "{\"type\":\"session\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"first\"}\n" ++
        "{\"kind\":\"turn_boundary\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"second\"}\n";
    var file = try std.Io.Dir.createFile(.cwd(), io, path, .{ .read = true });
    try file.writeStreamingAll(io, fixture);
    file.close(io);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var log = try Log.resumeExisting(failing.allocator(), io, .{
        .path = path,
        .selection = .{},
        .loaded_item_count = 3,
    });
    defer log.deinit();
    var stale = try log.prepareCut(1);
    defer stale.deinit();
    var selection = try log.prepareSelection(.{ .provider = "p" });
    defer selection.deinit();
    log.publishSelection(&selection);
    try std.testing.expectError(error.StaleCut, log.truncatePrepared(&stale, 1));

    var prepared = try log.prepareCut(1);
    defer prepared.deinit();
    failing.fail_index = failing.alloc_index;
    const allocations_before = failing.alloc_index;
    const outcome = try log.truncatePrepared(&prepared, 1);
    try std.testing.expectEqual(MutationDurability.synced, outcome.committed.durability);
    try std.testing.expectEqual(allocations_before, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
}
