const std = @import("std");
const Paths = @import("Paths.zig");
const SessionIndex = @import("SessionIndex.zig");

pub const marker_name = ".prune";
pub const maximum_days: u16 = 36_500;
const election_interval_seconds: i64 = 86_400;

pub const Outcome = union(enum) {
    disabled,
    missing_root,
    fresh,
    busy,
    completed,
    incomplete: anyerror,
};

pub const Error = error{
    InvalidDays,
    InvalidPath,
    PathTooLong,
    InvalidCutoff,
};

/// An erased synchronous pruning operation. The slices are borrowed for the
/// call. Returning any error means the pass was incomplete and the election
/// marker is not stamped.
pub const Pruner = struct {
    context: ?*anyopaque,
    run_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        ?*anyopaque,
        i64,
        ?[]const u8,
    ) anyerror!void,

    pub fn run(
        self: Pruner,
        allocator: std.mem.Allocator,
        io: std.Io,
        cutoff_epoch_seconds: i64,
        exclude_path: ?[]const u8,
    ) anyerror!void {
        return self.run_fn(allocator, io, self.context, cutoff_epoch_seconds, exclude_path);
    }
};

/// Runs one retention election. `sessions_root` is a trusted private
/// directory. Existing parent components must not be writable by an
/// untrusted process. No clock, thread, or allocator is ambient.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions_root: []const u8,
    now_epoch_seconds: i64,
    days: u32,
    exclude_path: ?[]const u8,
    pruner: Pruner,
) Error!Outcome {
    return runWithStampOps(
        allocator,
        io,
        sessions_root,
        now_epoch_seconds,
        days,
        exclude_path,
        pruner,
        .standard,
    );
}

fn runWithStampOps(
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions_root: []const u8,
    now_epoch_seconds: i64,
    days: u32,
    exclude_path: ?[]const u8,
    pruner: Pruner,
    stamp_ops: StampOps,
) Error!Outcome {
    if (days == 0) return .disabled;
    if (days > maximum_days) return error.InvalidDays;
    try validatePath(sessions_root);
    if (sessions_root.len == 1 or sessions_root[sessions_root.len - 1] == '/') return error.InvalidPath;
    if (exclude_path) |path| try validatePath(path);

    const retained_seconds = std.math.mul(i64, @as(i64, @intCast(days)), election_interval_seconds) catch
        return error.InvalidCutoff;
    const cutoff = std.math.sub(i64, now_epoch_seconds, retained_seconds) catch
        return error.InvalidCutoff;

    const sessions = std.Io.Dir.openDir(.cwd(), io, sessions_root, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return .missing_root,
        else => return .{ .incomplete = err },
    };
    defer sessions.close(io);

    var marker = openMarker(io, sessions) catch |err| return .{ .incomplete = err };
    defer marker.close(io);

    const locked = marker.tryLock(io, .exclusive) catch |err| return .{ .incomplete = err };
    if (!locked) return .busy;
    defer marker.unlock(io);

    const stat = marker.stat(io) catch |err| return .{ .incomplete = err };
    if (stat.kind != .file or stat.nlink != 1) return .{ .incomplete = error.NotRegular };
    const named = sessions.statFile(io, marker_name, .{ .follow_symlinks = false }) catch |err|
        return .{ .incomplete = err };
    if (named.kind != .file or named.nlink != 1 or named.inode != stat.inode)
        return .{ .incomplete = error.NotRegular };
    marker.setPermissions(io, std.Io.File.Permissions.fromMode(0o600)) catch |err|
        return .{ .incomplete = err };

    if (stat.size != 0 and markerIsFresh(stat.mtime.nanoseconds, now_epoch_seconds)) return .fresh;

    pruner.run(allocator, io, cutoff, exclude_path) catch |err| return .{ .incomplete = err };
    stamp_ops.stamp(io, sessions, marker) catch |err| {
        // A failed best-effort rollback cannot replace the original stamp error.
        marker.setLength(io, 0) catch {}; // ziglint-ignore: Z026
        stamp_ops.syncFile(io, marker) catch {}; // ziglint-ignore: Z026
        return .{ .incomplete = err };
    };
    return .completed;
}

fn openMarker(io: std.Io, sessions: std.Io.Dir) !std.Io.File {
    const permissions = std.Io.File.Permissions.fromMode(0o600);
    return sessions.openFile(io, marker_name, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |open_err| switch (open_err) {
        error.FileNotFound => sessions.createFile(io, marker_name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = permissions,
            .resolve_beneath = true,
        }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => sessions.openFile(io, marker_name, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }),
            else => create_err,
        },
        else => open_err,
    };
}

fn markerIsFresh(mtime_nanoseconds: i96, now_epoch_seconds: i64) bool {
    const now_nanoseconds = std.math.mul(i96, now_epoch_seconds, std.time.ns_per_s) catch
        if (now_epoch_seconds < 0) @as(i96, std.math.minInt(i96)) else @as(i96, std.math.maxInt(i96));
    if (now_nanoseconds <= mtime_nanoseconds) return true;
    return now_nanoseconds - mtime_nanoseconds < election_interval_seconds * std.time.ns_per_s;
}

const StampOps = struct {
    context: ?*anyopaque = null,
    sync_file_fn: *const fn (std.Io, std.Io.File, ?*anyopaque) anyerror!void = standardSyncFile,
    sync_dir_fn: *const fn (std.Io, std.Io.Dir, ?*anyopaque) anyerror!void = standardSyncDir,

    const standard: StampOps = .{};

    fn stamp(self: StampOps, io: std.Io, sessions: std.Io.Dir, marker: std.Io.File) !void {
        try marker.setLength(io, 0);
        try marker.writePositionalAll(io, "1", 0);
        try marker.setLength(io, 1);
        try self.syncFile(io, marker);
        try self.sync_dir_fn(io, sessions, self.context);
    }

    fn syncFile(self: StampOps, io: std.Io, marker: std.Io.File) !void {
        try self.sync_file_fn(io, marker, self.context);
    }

    fn standardSyncFile(io: std.Io, marker: std.Io.File, _: ?*anyopaque) !void {
        try marker.sync(io);
    }

    fn standardSyncDir(io: std.Io, sessions: std.Io.Dir, _: ?*anyopaque) !void {
        // Unix directory and file descriptors use the same handle type. This
        // borrowed facade is never closed.
        const directory_file: std.Io.File = .{
            .handle = sessions.handle,
            .flags = .{ .nonblocking = false },
        };
        try directory_file.sync(io);
    }
};

fn validatePath(path: []const u8) Error!void {
    if (path.len > Paths.default_max_path_bytes) return error.PathTooLong;
    if (path.len == 0 or path[0] != '/' or std.mem.findScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path))
    {
        return error.InvalidPath;
    }
}

/// Adapter context for the production SessionIndex pruner. `state_root` and
/// `limits` are borrowed for the synchronous call.
pub fn sessionIndexPruner(context: *SessionIndexPruner) Pruner {
    return context.erased();
}

pub const SessionIndexPruner = struct {
    state_root: []const u8,
    limits: SessionIndex.Limits = .{},

    pub fn erased(self: *SessionIndexPruner) Pruner {
        return .{ .context = self, .run_fn = prune };
    }

    fn prune(
        allocator: std.mem.Allocator,
        io: std.Io,
        context: ?*anyopaque,
        cutoff_epoch_seconds: i64,
        exclude_path: ?[]const u8,
    ) anyerror!void {
        const self: *SessionIndexPruner = @ptrCast(@alignCast(context.?));
        _ = try SessionIndex.pruneBefore(
            allocator,
            io,
            self.state_root,
            cutoff_epoch_seconds,
            exclude_path,
            self.limits,
        );
    }
};

const TestPruner = struct {
    calls: usize = 0,
    cutoff: i64 = 0,
    failure: ?anyerror = null,

    fn erased(self: *TestPruner) Pruner {
        return .{ .context = self, .run_fn = invoke };
    }

    fn invoke(
        _: std.mem.Allocator,
        _: std.Io,
        context: ?*anyopaque,
        cutoff: i64,
        _: ?[]const u8,
    ) anyerror!void {
        const self: *TestPruner = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.cutoff = cutoff;
        if (self.failure) |failure| return failure;
    }
};

const FaultStamp = struct {
    file_syncs: usize = 0,
    dir_syncs: usize = 0,

    fn ops(self: *FaultStamp) StampOps {
        return .{
            .context = self,
            .sync_file_fn = syncFile,
            .sync_dir_fn = syncDir,
        };
    }

    fn syncFile(io: std.Io, file: std.Io.File, context: ?*anyopaque) anyerror!void {
        const self: *FaultStamp = @ptrCast(@alignCast(context.?));
        self.file_syncs += 1;
        try file.sync(io);
    }

    fn syncDir(_: std.Io, _: std.Io.Dir, context: ?*anyopaque) anyerror!void {
        const self: *FaultStamp = @ptrCast(@alignCast(context.?));
        self.dir_syncs += 1;
        return error.DirSyncFailure;
    }
};

fn markerPath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, marker_name });
}

fn setMarkerMtime(io: std.Io, root: []const u8, seconds: i64) !void {
    const directory = try std.Io.Dir.openDir(.cwd(), io, root, .{});
    defer directory.close(io);
    const file = try directory.openFile(io, marker_name, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{
        .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s) },
    });
}

test "retention marker due table and exact boundary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]struct { size: []const u8, mtime: i64, now: i64, calls: usize }{
        .{ .size = "", .mtime = 100, .now = 100, .calls = 1 },
        .{ .size = "1", .mtime = 100, .now = 100, .calls = 0 },
        .{ .size = "1", .mtime = 100, .now = 100 + election_interval_seconds - 1, .calls = 0 },
        .{ .size = "1", .mtime = 100, .now = 100 + election_interval_seconds, .calls = 1 },
        .{ .size = "1", .mtime = 101, .now = 100, .calls = 0 },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const path = try markerPath(allocator, root);
        defer allocator.free(path);
        try std.Io.Dir.writeFile(.cwd(), io, .{
            .sub_path = path,
            .data = case.size,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        try setMarkerMtime(io, root, case.mtime);
        var callback: TestPruner = .{};
        const outcome = try run(allocator, io, root, case.now, 1, null, callback.erased());
        try std.testing.expectEqual(case.calls, callback.calls);
        try std.testing.expectEqual(
            if (case.calls == 0) @as(std.meta.Tag(Outcome), .fresh) else @as(std.meta.Tag(Outcome), .completed),
            std.meta.activeTag(outcome),
        );
    }
}

test "disabled, callback failure, missing root, and symlink marker do not stamp" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var callback: TestPruner = .{ .failure = error.Cancelled };
    try std.testing.expectEqual(Outcome.disabled, try run(allocator, io, "/not/used", 0, 0, null, callback.erased()));
    try std.testing.expectError(
        error.InvalidDays,
        run(allocator, io, "/not/used", 0, maximum_days + 1, null, callback.erased()),
    );
    try std.testing.expectEqual(
        Outcome.missing_root,
        try run(allocator, io, "/definitely/missing/zi-sessions", 0, 1, null, callback.erased()),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const outcome = try run(allocator, io, root, 100, 1, null, callback.erased());
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .incomplete), std.meta.activeTag(outcome));
    try std.testing.expectEqual(error.Cancelled, outcome.incomplete);
    const path = try markerPath(allocator, root);
    defer allocator.free(path);
    const marker = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer marker.close(io);
    try std.testing.expectEqual(@as(u64, 0), try marker.length(io));

    try std.Io.Dir.deleteFile(.cwd(), io, path);
    try std.Io.Dir.symLink(.cwd(), io, "target", path, .{});
    const linked = try run(allocator, io, root, 100, 1, null, callback.erased());
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .incomplete), std.meta.activeTag(linked));
}

test "election is nonblocking and incomplete retains callback cause" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try markerPath(allocator, root);
    defer allocator.free(path);
    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = path,
        .data = "",
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    const marker_file = try std.Io.Dir.openFile(.cwd(), io, path, .{ .mode = .read_write });
    defer marker_file.close(io);
    try std.testing.expect(try marker_file.tryLock(io, .exclusive));
    defer marker_file.unlock(io);
    var callback: TestPruner = .{};
    const busy = try run(allocator, io, root, 100, 1, null, callback.erased());
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .busy), std.meta.activeTag(busy));
    try std.testing.expectEqual(@as(usize, 0), callback.calls);

    marker_file.unlock(io);
    callback.failure = error.OutOfMemory;
    const incomplete = try run(allocator, io, root, 100, 1, null, callback.erased());
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .incomplete), std.meta.activeTag(incomplete));
    try std.testing.expectEqual(error.OutOfMemory, incomplete.incomplete);
    try std.testing.expect(try marker_file.tryLock(io, .exclusive));
}

test "directory sync failure durably rolls marker back to empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var callback: TestPruner = .{};
    var fault: FaultStamp = .{};
    const outcome = try runWithStampOps(
        allocator,
        io,
        root,
        100,
        1,
        null,
        callback.erased(),
        fault.ops(),
    );
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .incomplete), std.meta.activeTag(outcome));
    try std.testing.expectEqual(error.DirSyncFailure, outcome.incomplete);
    try std.testing.expectEqual(@as(usize, 2), fault.file_syncs);
    try std.testing.expectEqual(@as(usize, 1), fault.dir_syncs);
    const path = try markerPath(allocator, root);
    defer allocator.free(path);
    const marker = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer marker.close(io);
    try std.testing.expectEqual(@as(u64, 0), try marker.length(io));
}

test "sessions root rejects slash spelling before nofollow symlink open" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const real = try std.fmt.allocPrint(allocator, "{s}/real", .{root});
    defer allocator.free(real);
    const linked = try std.fmt.allocPrint(allocator, "{s}/linked", .{root});
    defer allocator.free(linked);
    const linked_slash = try std.fmt.allocPrint(allocator, "{s}/", .{linked});
    defer allocator.free(linked_slash);
    try std.Io.Dir.createDir(.cwd(), io, real, .default_dir);
    try std.Io.Dir.symLink(.cwd(), io, real, linked, .{ .is_directory = true });
    var callback: TestPruner = .{};
    const no_slash = try run(allocator, io, linked, 100, 1, null, callback.erased());
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .incomplete), std.meta.activeTag(no_slash));
    try std.testing.expectError(
        error.InvalidPath,
        run(allocator, io, linked_slash, 100, 1, null, callback.erased()),
    );
    try std.testing.expectError(error.InvalidPath, run(allocator, io, "/", 100, 1, null, callback.erased()));
    try std.testing.expectEqual(@as(usize, 0), callback.calls);
}

test "successful prune stamps one private byte and computes strict cutoff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var callback: TestPruner = .{};
    try std.testing.expectEqual(Outcome.completed, try run(allocator, io, root, 200_000, 2, null, callback.erased()));
    try std.testing.expectEqual(@as(i64, 27_200), callback.cutoff);
    const path = try markerPath(allocator, root);
    defer allocator.free(path);
    const marker = try std.Io.Dir.openFile(.cwd(), io, path, .{});
    defer marker.close(io);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try marker.readPositionalAll(io, &byte, 0));
    try std.testing.expectEqualStrings("1", &byte);
    try std.testing.expectEqual(@as(u64, 1), try marker.length(io));
    const stat = try marker.stat(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "SessionIndex adapter prunes globally with strict cutoff and exclusion" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(state_root);
    const sessions_root = try std.fmt.allocPrint(allocator, "{s}/sessions", .{state_root});
    defer allocator.free(sessions_root);
    const first_bucket = try std.fmt.allocPrint(allocator, "{s}/first", .{sessions_root});
    defer allocator.free(first_bucket);
    const second_bucket = try std.fmt.allocPrint(allocator, "{s}/second", .{sessions_root});
    defer allocator.free(second_bucket);
    try std.Io.Dir.createDirPath(.cwd(), io, first_bucket);
    try std.Io.Dir.createDirPath(.cwd(), io, second_bucket);

    const old_name = try Paths.canonicalNameFromEpoch(0, [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x01,
    });
    const equal_name = try Paths.canonicalNameFromEpoch(1, [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x02,
    });
    const excluded_name = try Paths.canonicalNameFromEpoch(2, [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x03,
    });
    const old_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ first_bucket, &old_name });
    defer allocator.free(old_path);
    const equal_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ first_bucket, &equal_name });
    defer allocator.free(equal_path);
    const excluded_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ second_bucket, &excluded_name });
    defer allocator.free(excluded_path);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = old_path, .data = "old" });
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = equal_path, .data = "equal" });
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = excluded_path, .data = "excluded" });
    const first = try std.Io.Dir.openDir(.cwd(), io, first_bucket, .{});
    defer first.close(io);
    const second = try std.Io.Dir.openDir(.cwd(), io, second_bucket, .{});
    defer second.close(io);
    try setNamedMtime(io, first, &old_name, 99);
    try setNamedMtime(io, first, &equal_name, 100);
    try setNamedMtime(io, second, &excluded_name, 99);

    var adapter: SessionIndexPruner = .{ .state_root = state_root };
    const outcome = try run(
        allocator,
        io,
        sessions_root,
        86_500,
        1,
        excluded_path,
        sessionIndexPruner(&adapter),
    );
    try std.testing.expectEqual(@as(std.meta.Tag(Outcome), .completed), std.meta.activeTag(outcome));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFile(.cwd(), io, old_path, .{}));
    const equal = try std.Io.Dir.openFile(.cwd(), io, equal_path, .{});
    equal.close(io);
    const excluded = try std.Io.Dir.openFile(.cwd(), io, excluded_path, .{});
    excluded.close(io);
}

fn setNamedMtime(io: std.Io, directory: std.Io.Dir, name: []const u8, seconds: i64) !void {
    const file = try directory.openFile(io, name, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{
        .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s) },
    });
}
