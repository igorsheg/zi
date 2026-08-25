//! Process-owned background lifecycle for session retention.
//!
//! `Owner` is heap allocated. The worker and erased cancellation callback keep
//! its address until `deinit` joins the only thread. Paths passed to `create`
//! are borrowed, validated, and copied. The allocator and `std.Io` must remain
//! usable by both the caller and worker until `deinit` returns.

const std = @import("std");
const persistence = @import("persistence/root.zig");

pub const Options = struct {
    state_root: []const u8,
    now_epoch_seconds: i64,
    days: u32,
    exclude_path: ?[]const u8 = null,
    limits: persistence.SessionIndex.Limits = .{},
};

pub const CreateError = error{
    OutOfMemory,
    InvalidDays,
    InvalidPath,
    PathTooLong,
};

pub const StartFailure = enum {
    out_of_memory,
    system_resources,
    thread_quota_exceeded,
    locked_memory_limit_exceeded,
    unexpected,
};

pub const Completion = union(enum) {
    disabled,
    missing_root,
    retention: persistence.SessionRetention.Outcome,
    start_failed: StartFailure,
};

pub const StartResult = union(enum) {
    started,
    disabled,
    missing_root,
    fresh,
    busy,
    already_attempted,
    advisory: Completion,
};

pub const Summary = struct {
    attempted: bool,
    started: bool,
    running: bool,
    completion: ?Completion,
};

/// Heap-stable owner of one background retention election.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []u8,
    sessions_root: []u8,
    exclude_path: ?[]u8,
    now_epoch_seconds: i64,
    days: u32,
    limits: persistence.SessionIndex.Limits,

    canceled: std.atomic.Value(bool) = .init(false),
    lifecycle_mutex: std.Io.Mutex = .init,
    lifecycle_condition: std.Io.Condition = .init,
    result_mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    election: ?persistence.SessionRetention.Election = null,
    attempted: std.atomic.Value(bool) = .init(false),
    joining: bool = false,
    joined: bool = false,
    started: bool = false,
    running: bool = false,
    completion: ?Completion = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) CreateError!*Owner {
        if (options.days > persistence.SessionRetention.maximum_days) return error.InvalidDays;
        try validatePath(options.state_root, false);
        if (options.exclude_path) |path| try validatePath(path, true);

        const self = allocator.create(Owner) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        const state_root = allocator.dupe(u8, options.state_root) catch return error.OutOfMemory;
        errdefer allocator.free(state_root);
        const sessions_root = try deriveSessionsRoot(allocator, options.state_root);
        errdefer allocator.free(sessions_root);
        const exclude_path = if (options.exclude_path) |path|
            allocator.dupe(u8, path) catch return error.OutOfMemory
        else
            null;
        errdefer if (exclude_path) |path| allocator.free(path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .state_root = state_root,
            .sessions_root = sessions_root,
            .exclude_path = exclude_path,
            .now_epoch_seconds = options.now_epoch_seconds,
            .days = options.days,
            .limits = options.limits,
        };
        return self;
    }

    /// Starts at most one worker. Disabled and missing roots do not spawn.
    /// Thread creation failure is an advisory completion, not a panic.
    pub fn start(self: *Owner) StartResult {
        self.lifecycle_mutex.lockUncancelable(self.io);
        defer self.lifecycle_mutex.unlock(self.io);
        if (self.attempted.swap(true, .acq_rel)) return .already_attempted;

        const prepared = persistence.SessionRetention.prepare(
            self.io,
            self.sessions_root,
            self.now_epoch_seconds,
            self.days,
        ) catch |err| {
            const completion: Completion = .{ .retention = .{ .incomplete = err } };
            self.setResult(false, false, completion);
            self.joined = true;
            return .{ .advisory = completion };
        };
        switch (prepared) {
            .disabled => {
                self.setResult(false, false, .disabled);
                self.joined = true;
                return .disabled;
            },
            .missing_root => {
                self.setResult(false, false, .missing_root);
                self.joined = true;
                return .missing_root;
            },
            .fresh => {
                self.setResult(false, false, .{ .retention = .fresh });
                self.joined = true;
                return .fresh;
            },
            .busy => {
                self.setResult(false, false, .{ .retention = .busy });
                self.joined = true;
                return .busy;
            },
            .incomplete => |err| {
                const completion: Completion = .{ .retention = .{ .incomplete = err } };
                self.setResult(false, false, completion);
                self.joined = true;
                return .{ .advisory = completion };
            },
            .elected => |election| self.election = election,
        }

        self.setResult(true, true, null);
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            self.election.?.deinit(self.io);
            self.election = null;
            const completion: Completion = .{ .start_failed = startFailure(err) };
            self.setResult(false, false, completion);
            self.joined = true;
            return .{ .advisory = completion };
        };
        return .started;
    }

    pub fn poll(self: *Owner) Summary {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        return .{
            .attempted = self.attempted.load(.acquire),
            .started = self.started,
            .running = self.running,
            .completion = self.completion,
        };
    }

    /// Requests cancellation and performs the sole join. Concurrent callers
    /// wait for the in-progress join rather than joining the thread twice.
    pub fn cancelAndDrain(self: *Owner) Summary {
        self.lifecycle_mutex.lockUncancelable(self.io);
        while (self.joining) self.lifecycle_condition.waitUncancelable(
            self.io,
            &self.lifecycle_mutex,
        );
        if (self.joined) {
            self.lifecycle_mutex.unlock(self.io);
            return self.poll();
        }
        const thread = self.thread orelse {
            _ = self.attempted.swap(true, .acq_rel);
            self.joined = true;
            self.lifecycle_mutex.unlock(self.io);
            return self.poll();
        };
        self.joining = true;
        self.canceled.store(true, .release);
        self.lifecycle_mutex.unlock(self.io);

        thread.join();

        self.lifecycle_mutex.lockUncancelable(self.io);
        self.thread = null;
        self.joining = false;
        self.joined = true;
        self.lifecycle_condition.broadcast(self.io);
        self.lifecycle_mutex.unlock(self.io);
        return self.poll();
    }

    /// Requires exclusive ownership. No method may overlap this call.
    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        _ = self.cancelAndDrain();
        const allocator = self.allocator;
        allocator.free(self.state_root);
        allocator.free(self.sessions_root);
        if (self.exclude_path) |path| allocator.free(path);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn workerMain(self: *Owner) void {
        var adapter: persistence.SessionRetention.SessionIndexPruner = .{
            .state_root = self.state_root,
            .limits = self.limits,
            .tick = .{ .context = self, .check_fn = checkCancellation },
        };
        const outcome = self.election.?.run(
            self.allocator,
            self.io,
            self.exclude_path,
            persistence.SessionRetention.sessionIndexPruner(&adapter),
        ) catch |err| persistence.SessionRetention.Outcome{ .incomplete = err };
        self.election = null;
        self.setResult(true, false, .{ .retention = outcome });
    }

    fn checkCancellation(context: ?*anyopaque) error{Cancelled}!void {
        const self: *Owner = @ptrCast(@alignCast(context.?));
        if (self.canceled.load(.acquire)) return error.Cancelled;
    }

    fn setResult(self: *Owner, started: bool, running: bool, completion: ?Completion) void {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        self.started = started;
        self.running = running;
        self.completion = completion;
    }
};

fn deriveSessionsRoot(allocator: std.mem.Allocator, state_root: []const u8) CreateError![]u8 {
    const suffix = "/sessions";
    const size = std.math.add(usize, state_root.len, suffix.len) catch return error.PathTooLong;
    if (size > persistence.Paths.default_max_path_bytes) return error.PathTooLong;
    const result = allocator.alloc(u8, size) catch return error.OutOfMemory;
    @memcpy(result[0..state_root.len], state_root);
    @memcpy(result[state_root.len..], suffix);
    return result;
}

fn validatePath(path: []const u8, allow_trailing_slash: bool) CreateError!void {
    if (path.len > persistence.Paths.default_max_path_bytes) return error.PathTooLong;
    if (path.len == 0 or path[0] != '/' or std.mem.findScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path) or
        (!allow_trailing_slash and (path.len == 1 or path[path.len - 1] == '/')))
    {
        return error.InvalidPath;
    }
}

fn startFailure(err: std.Thread.SpawnError) StartFailure {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.SystemResources => .system_resources,
        error.ThreadQuotaExceeded => .thread_quota_exceeded,
        error.LockedMemoryLimitExceeded => .locked_memory_limit_exceeded,
        error.Unexpected => .unexpected,
    };
}

fn sessionsPath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions", .{state_root});
}

fn testOwner(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    days: u32,
    exclude_path: ?[]const u8,
) !*Owner {
    return Owner.create(allocator, io, .{
        .state_root = state_root,
        .now_epoch_seconds = 100_000,
        .days = days,
        .exclude_path = exclude_path,
    });
}

test "disabled and missing retention services do not start workers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var disabled = try testOwner(allocator, io, "/not/used", 0, null);
    defer disabled.deinit();
    try std.testing.expectEqual(@as(std.meta.Tag(StartResult), .disabled), std.meta.activeTag(disabled.start()));
    try std.testing.expect(!disabled.poll().started);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var missing = try testOwner(allocator, io, root, 1, null);
    defer missing.deinit();
    try std.testing.expectEqual(@as(std.meta.Tag(StartResult), .missing_root), std.meta.activeTag(missing.start()));
    try std.testing.expect(!missing.poll().started);
}

test "worker completes election and copied paths survive caller mutation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sessions_root = try sessionsPath(allocator, root);
    defer allocator.free(sessions_root);
    try std.Io.Dir.createDir(.cwd(), io, sessions_root, .default_dir);

    const root_copy = try allocator.dupe(u8, root);
    defer allocator.free(root_copy);
    var owner = try Owner.create(allocator, io, .{
        .state_root = root_copy,
        .now_epoch_seconds = 100_000,
        .days = 1,
    });
    defer owner.deinit();
    @memset(root_copy, 'x');
    try std.testing.expectEqual(@as(std.meta.Tag(StartResult), .started), std.meta.activeTag(owner.start()));
    const summary = owner.cancelAndDrain();
    try std.testing.expect(summary.started);
    try std.testing.expect(!summary.running);
    try std.testing.expect(summary.completion != null);
}

fn exerciseCreateFailure(allocator: std.mem.Allocator, io: std.Io) !void {
    const owner = try Owner.create(allocator, io, .{
        .state_root = "/tmp/state",
        .now_epoch_seconds = 0,
        .days = 1,
        .exclude_path = "/tmp/state/sessions/bucket/resume.jsonl",
    });
    owner.deinit();
}

test "create releases all partial allocations before any spawn" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCreateFailure,
        .{std.testing.io},
    );
}

fn waitForWorker(owner: *Owner) !Summary {
    for (0..100_000) |_| {
        const summary = owner.poll();
        if (!summary.running) return owner.cancelAndDrain();
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    _ = owner.cancelAndDrain();
    return error.TestUnexpectedResult;
}

fn testSessionName() ![persistence.Paths.canonical_name_bytes]u8 {
    return persistence.Paths.canonicalNameFromEpoch(0, [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x01,
    });
}

test "completed retention preserves copied selected resume path and next election is fresh" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sessions_root = try sessionsPath(allocator, root);
    defer allocator.free(sessions_root);
    const bucket = try std.fmt.allocPrint(allocator, "{s}/bucket", .{sessions_root});
    defer allocator.free(bucket);
    try std.Io.Dir.createDirPath(.cwd(), io, bucket);
    const name = try testSessionName();
    const selected = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bucket, &name });
    defer allocator.free(selected);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = selected, .data = "old" });
    const bucket_dir = try std.Io.Dir.openDir(.cwd(), io, bucket, .{});
    defer bucket_dir.close(io);
    const selected_file = try bucket_dir.openFile(io, &name, .{ .mode = .read_write });
    try selected_file.setTimestamps(io, .{
        .modify_timestamp = .{ .new = .fromNanoseconds(0) },
    });
    selected_file.close(io);

    const selected_copy = try allocator.dupe(u8, selected);
    defer allocator.free(selected_copy);
    var owner = try Owner.create(allocator, io, .{
        .state_root = root,
        .now_epoch_seconds = 200_000,
        .days = 1,
        .exclude_path = selected_copy,
    });
    defer owner.deinit();
    @memset(selected_copy, 'x');
    try std.testing.expectEqual(@as(std.meta.Tag(StartResult), .started), std.meta.activeTag(owner.start()));
    const completed = try waitForWorker(owner);
    try std.testing.expectEqual(
        @as(std.meta.Tag(persistence.SessionRetention.Outcome), .completed),
        std.meta.activeTag(completed.completion.?.retention),
    );
    const kept = try std.Io.Dir.openFile(.cwd(), io, selected, .{});
    kept.close(io);

    var fresh = try Owner.create(allocator, io, .{
        .state_root = root,
        .now_epoch_seconds = 200_001,
        .days = 1,
    });
    defer fresh.deinit();
    try std.testing.expectEqual(@as(std.meta.Tag(StartResult), .fresh), std.meta.activeTag(fresh.start()));
    const fresh_summary = fresh.poll();
    try std.testing.expect(!fresh_summary.started);
    try std.testing.expectEqual(
        @as(std.meta.Tag(persistence.SessionRetention.Outcome), .fresh),
        std.meta.activeTag(fresh_summary.completion.?.retention),
    );
}

test "busy retention election is an advisory worker outcome" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const sessions_root = try sessionsPath(allocator, root);
    defer allocator.free(sessions_root);
    try std.Io.Dir.createDir(.cwd(), io, sessions_root, .default_dir);
    const marker_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ sessions_root, persistence.SessionRetention.marker_name },
    );
    defer allocator.free(marker_path);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = marker_path, .data = "" });
    const marker = try std.Io.Dir.openFile(.cwd(), io, marker_path, .{ .mode = .read_write });
    defer marker.close(io);
    try std.testing.expect(try marker.tryLock(io, .exclusive));
    defer marker.unlock(io);

    var owner = try testOwner(allocator, io, root, 1, null);
    defer owner.deinit();
    try std.testing.expectEqual(@as(std.meta.Tag(StartResult), .busy), std.meta.activeTag(owner.start()));
    const summary = owner.poll();
    try std.testing.expect(!summary.started);
    try std.testing.expectEqual(
        @as(std.meta.Tag(persistence.SessionRetention.Outcome), .busy),
        std.meta.activeTag(summary.completion.?.retention),
    );
}

test "create requires one canonical bounded state root before deriving sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.InvalidPath, Owner.create(allocator, io, .{
        .state_root = "/",
        .now_epoch_seconds = 0,
        .days = 0,
    }));
    try std.testing.expectError(error.InvalidPath, Owner.create(allocator, io, .{
        .state_root = "/tmp/state/",
        .now_epoch_seconds = 0,
        .days = 0,
    }));
    const root = try allocator.alloc(u8, persistence.Paths.default_max_path_bytes);
    defer allocator.free(root);
    root[0] = '/';
    @memset(root[1..], 'a');
    try std.testing.expectError(error.PathTooLong, Owner.create(allocator, io, .{
        .state_root = root,
        .now_epoch_seconds = 0,
        .days = 0,
    }));
}
