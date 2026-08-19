const std = @import("std");
const format = @import("SessionFormat.zig");
const journal_api = @import("SessionJournal.zig");
const ZiPaths = @import("ZiPaths.zig");

const SessionSelection = @This();
const max_directory_entries = 4096;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);

const Error = ZiPaths.Error || journal_api.Error || error{
    InvalidSessionPath,
    MissingCwd,
    CwdUnavailable,
    SessionChanged,
    SessionStorageUnavailable,
    TooManySessions,
};

const Intent = union(enum) {
    new,
    open: []const u8,
    continue_recent,
};

const Origin = enum {
    new,
    opened,
    continued,
};

allocator: std.mem.Allocator,
paths: ZiPaths,
journal_path: []const u8,
opened: journal_api.Opened,
origin: Origin,

fn select(
    allocator: std.mem.Allocator,
    io: std.Io,
    startup_cwd: []const u8,
    home: []const u8,
    sources: format.Sources,
    intent: Intent,
) Error!SessionSelection {
    return switch (intent) {
        .new => createNew(allocator, io, startup_cwd, home, sources),
        .open => |path| openExact(allocator, io, startup_cwd, home, path, .opened),
        .continue_recent => continueRecent(allocator, io, startup_cwd, home, sources),
    };
}

fn deinit(self: *SessionSelection) void {
    self.opened.deinit();
    self.allocator.free(self.journal_path);
    self.paths.deinit();
    self.* = undefined;
}

fn createNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    sources: format.Sources,
) Error!SessionSelection {
    var paths = try ZiPaths.init(allocator, cwd, home);
    errdefer paths.deinit();
    try admitCwd(io, paths.cwd);
    try ensureSessionStorage(io, paths.global_sessions);

    const stamp = try sources.next();
    var filename_buffer: [42]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buffer, "{s}.jsonl", .{stamp.id()}) catch unreachable;
    const journal_path = std.fs.path.resolve(allocator, &.{ paths.global_sessions, filename }) catch
        return error.OutOfMemory;
    errdefer allocator.free(journal_path);
    if (journal_path.len > ZiPaths.max_path_bytes) return error.InvalidSessionPath;
    var directory = std.Io.Dir.openDir(.cwd(), io, paths.global_sessions, .{}) catch
        return error.SessionStorageUnavailable;
    defer directory.close(io);

    var opened = try journal_api.create(
        allocator,
        io,
        directory,
        filename,
        .{
            .id = stamp.id(),
            .timestamp = stamp.timestamp(),
            .cwd = paths.cwd,
        },
        .none(),
    );
    errdefer opened.deinit();
    return .{
        .allocator = allocator,
        .paths = paths,
        .journal_path = journal_path,
        .opened = opened,
        .origin = .new,
    };
}

fn openExact(
    allocator: std.mem.Allocator,
    io: std.Io,
    startup_cwd: []const u8,
    home: []const u8,
    input_path: []const u8,
    origin: Origin,
) Error!SessionSelection {
    var startup_paths = try ZiPaths.init(allocator, startup_cwd, home);
    defer startup_paths.deinit();
    try validateInputPath(input_path);
    const journal_path = std.fs.path.resolve(allocator, &.{ startup_paths.cwd, input_path }) catch
        return error.OutOfMemory;
    errdefer allocator.free(journal_path);
    if (journal_path.len > ZiPaths.max_path_bytes) return error.InvalidSessionPath;
    const parent_path = std.fs.path.dirname(journal_path) orelse return error.InvalidSessionPath;
    const filename = std.fs.path.basename(journal_path);
    if (filename.len == 0) return error.InvalidSessionPath;
    var directory = std.Io.Dir.openDir(.cwd(), io, parent_path, .{}) catch |failure| {
        return switch (failure) {
            error.FileNotFound => error.NotFound,
            else => error.OpenFailed,
        };
    };
    defer directory.close(io);

    var probe = try journal_api.probeHeader(allocator, io, directory, filename);
    defer probe.deinit();
    const probed = probe.header();
    var paths = try ZiPaths.init(allocator, probed.cwd, home);
    errdefer paths.deinit();
    try admitCwd(io, paths.cwd);

    var opened = try journal_api.openWritable(allocator, io, directory, filename);
    errdefer opened.deinit();
    if (!sameHeader(probed, opened.restore_candidate.header)) return error.SessionChanged;
    return .{
        .allocator = allocator,
        .paths = paths,
        .journal_path = journal_path,
        .opened = opened,
        .origin = origin,
    };
}

fn continueRecent(
    allocator: std.mem.Allocator,
    io: std.Io,
    startup_cwd: []const u8,
    home: []const u8,
    sources: format.Sources,
) Error!SessionSelection {
    var paths = try ZiPaths.init(allocator, startup_cwd, home);
    defer paths.deinit();
    try admitCwd(io, paths.cwd);
    const recent_path = try findRecent(allocator, io, &paths);
    if (recent_path) |path| {
        defer allocator.free(path);
        return openExact(allocator, io, paths.cwd, home, path, .continued);
    }
    return createNew(allocator, io, paths.cwd, home, sources);
}

fn findRecent(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
) Error!?[]u8 {
    var directory = std.Io.Dir.openDir(.cwd(), io, paths.global_sessions, .{ .iterate = true }) catch |failure| {
        return switch (failure) {
            error.FileNotFound => null,
            else => error.SessionStorageUnavailable,
        };
    };
    defer directory.close(io);
    var iterator = directory.iterateAssumeFirstIteration();
    var inspected: usize = 0;
    var best_name: ?[]u8 = null;
    defer if (best_name) |name| allocator.free(name);
    var best_mtime: i96 = 0;

    while (iterator.next(io) catch return error.SessionStorageUnavailable) |entry| {
        inspected += 1;
        if (inspected > max_directory_entries) return error.TooManySessions;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const stat = directory.statFile(io, entry.name, .{}) catch |failure| switch (failure) {
            error.FileNotFound => continue,
            else => return error.SessionStorageUnavailable,
        };
        if (stat.kind != .file) continue;
        var probe = journal_api.probeHeader(allocator, io, directory, entry.name) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer probe.deinit();
        if (!std.mem.eql(u8, probe.header().cwd, paths.cwd)) continue;
        const newer = best_name == null or stat.mtime.nanoseconds > best_mtime or
            (stat.mtime.nanoseconds == best_mtime and
                std.mem.order(u8, entry.name, best_name.?) == .gt);
        if (!newer) continue;
        const owned_name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
        if (best_name) |name| allocator.free(name);
        best_name = owned_name;
        best_mtime = stat.mtime.nanoseconds;
    }

    const name = best_name orelse return null;
    const result = std.fs.path.resolve(allocator, &.{ paths.global_sessions, name }) catch
        return error.OutOfMemory;
    if (result.len > ZiPaths.max_path_bytes) {
        allocator.free(result);
        return error.InvalidSessionPath;
    }
    return result;
}

fn admitCwd(io: std.Io, cwd: []const u8) Error!void {
    const stat = std.Io.Dir.statFile(.cwd(), io, cwd, .{}) catch |failure| {
        return switch (failure) {
            error.FileNotFound => error.MissingCwd,
            else => error.CwdUnavailable,
        };
    };
    if (stat.kind != .directory) return error.MissingCwd;
}

fn ensureSessionStorage(io: std.Io, path: []const u8) Error!void {
    _ = std.Io.Dir.createDirPathStatus(.cwd(), io, path, private_dir_permissions) catch
        return error.SessionStorageUnavailable;
    const agent_path = std.fs.path.dirname(path) orelse return error.SessionStorageUnavailable;
    const zi_path = std.fs.path.dirname(agent_path) orelse return error.SessionStorageUnavailable;
    const home_path = std.fs.path.dirname(zi_path) orelse return error.SessionStorageUnavailable;
    const sync_paths = [_][]const u8{ path, agent_path, zi_path, home_path };
    for (sync_paths) |sync_path| {
        var directory = std.Io.Dir.openDir(.cwd(), io, sync_path, .{}) catch
            return error.SessionStorageUnavailable;
        defer directory.close(io);
        journal_api.syncDirectory(directory) catch return error.SessionStorageUnavailable;
    }
}

fn validateInputPath(path: []const u8) error{InvalidSessionPath}!void {
    if (path.len == 0 or path.len > ZiPaths.max_path_bytes) return error.InvalidSessionPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidSessionPath;
    if (std.mem.findScalar(u8, path, 0) != null) return error.InvalidSessionPath;
}

fn sameHeader(left: format.Header, right: format.Header) bool {
    return std.mem.eql(u8, left.id, right.id) and
        std.mem.eql(u8, left.timestamp, right.timestamp) and
        std.mem.eql(u8, left.cwd, right.cwd);
}

const TestSources = struct {
    next_id: u64 = 0,
    next_ms: u64 = 1_777_800_000_000,

    fn nextId(context: *anyopaque) [16]u8 {
        const self: *TestSources = @ptrCast(@alignCast(context));
        self.next_id += 1;
        var bytes: [16]u8 = @splat(0);
        std.mem.writeInt(u64, bytes[8..16], self.next_id, .big);
        return bytes;
    }

    fn nowMs(context: *anyopaque) u64 {
        const self: *TestSources = @ptrCast(@alignCast(context));
        defer self.next_ms += 1;
        return self.next_ms;
    }

    fn view(self: *TestSources) format.Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

test "session selection creates a private journal from admitted paths" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var sources: TestSources = .{};

    var selected = try select(
        std.testing.allocator,
        std.testing.io,
        root,
        root,
        sources.view(),
        .new,
    );
    defer selected.deinit();

    try std.testing.expect(selected.origin == .new);
    try std.testing.expectEqualStrings(root, selected.paths.cwd);
    try std.testing.expectEqualStrings(root, selected.opened.restore_candidate.header.cwd);
    try std.testing.expect(std.mem.startsWith(u8, selected.journal_path, selected.paths.global_sessions));
    const stat = try std.Io.Dir.statFile(.cwd(), std.testing.io, selected.journal_path, .{});
    try std.testing.expectEqual(@as(u16, 0), stat.permissions.toMode() & 0o077);
}

test "session selection opens an exact relative path with the stored cwd" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "launch", .default_dir);
    try temporary.dir.createDir(std.testing.io, "stored", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const launch = try std.fs.path.resolve(std.testing.allocator, &.{ root, "launch" });
    defer std.testing.allocator.free(launch);
    const stored = try std.fs.path.resolve(std.testing.allocator, &.{ root, "stored" });
    defer std.testing.allocator.free(stored);
    var sources: TestSources = .{};
    var created = try select(
        std.testing.allocator,
        std.testing.io,
        stored,
        root,
        sources.view(),
        .new,
    );
    const relative = try std.fs.path.relative(
        std.testing.allocator,
        launch,
        null,
        launch,
        created.journal_path,
    );
    defer std.testing.allocator.free(relative);
    created.deinit();

    var opened = try select(
        std.testing.allocator,
        std.testing.io,
        launch,
        root,
        sources.view(),
        .{ .open = relative },
    );
    defer opened.deinit();
    try std.testing.expect(opened.origin == .opened);
    try std.testing.expectEqualStrings(stored, opened.paths.cwd);
}

test "session continuation chooses the newest valid journal for the admitted cwd" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "project-a", .default_dir);
    try temporary.dir.createDir(std.testing.io, "project-b", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const project_a = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project-a" });
    defer std.testing.allocator.free(project_a);
    const project_b = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project-b" });
    defer std.testing.allocator.free(project_b);
    var sources: TestSources = .{};
    var older = try select(
        std.testing.allocator,
        std.testing.io,
        project_a,
        root,
        sources.view(),
        .new,
    );
    const older_id = try std.testing.allocator.dupe(u8, older.opened.restore_candidate.header.id);
    defer std.testing.allocator.free(older_id);
    var older_file = try std.Io.Dir.openFile(.cwd(), std.testing.io, older.journal_path, .{ .mode = .read_write });
    defer older_file.close(std.testing.io);
    try older_file.setTimestamps(std.testing.io, .{
        .modify_timestamp = .{ .new = .fromNanoseconds(1_000_000) },
    });
    older.deinit();

    var other = try select(
        std.testing.allocator,
        std.testing.io,
        project_b,
        root,
        sources.view(),
        .new,
    );
    other.deinit();
    var newer = try select(
        std.testing.allocator,
        std.testing.io,
        project_a,
        root,
        sources.view(),
        .new,
    );
    const newer_id = try std.testing.allocator.dupe(u8, newer.opened.restore_candidate.header.id);
    defer std.testing.allocator.free(newer_id);
    newer.deinit();

    var continued = try select(
        std.testing.allocator,
        std.testing.io,
        project_a,
        root,
        sources.view(),
        .continue_recent,
    );
    defer continued.deinit();
    try std.testing.expect(continued.origin == .continued);
    try std.testing.expect(!std.mem.eql(u8, older_id, newer_id));
    try std.testing.expectEqualStrings(newer_id, continued.opened.restore_candidate.header.id);
}

test "session continuation ignores corrupt candidates and creates a new journal" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    try ensureSessionStorage(std.testing.io, paths.global_sessions);
    var directory = try std.Io.Dir.openDir(.cwd(), std.testing.io, paths.global_sessions, .{});
    defer directory.close(std.testing.io);
    try directory.writeFile(std.testing.io, .{
        .sub_path = "corrupt.jsonl",
        .data = "not a session\n",
    });
    var sources: TestSources = .{};

    var continued = try select(
        std.testing.allocator,
        std.testing.io,
        root,
        root,
        sources.view(),
        .continue_recent,
    );
    defer continued.deinit();
    try std.testing.expect(continued.origin == .new);
    try std.testing.expect(!std.mem.endsWith(u8, continued.journal_path, "corrupt.jsonl"));
}

test "session continuation bounds directory inspection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    try ensureSessionStorage(std.testing.io, paths.global_sessions);
    var directory = try std.Io.Dir.openDir(.cwd(), std.testing.io, paths.global_sessions, .{});
    defer directory.close(std.testing.io);
    var name_buffer: [32]u8 = undefined;
    for (0..max_directory_entries + 1) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "ignored-{d}", .{index});
        const file = try directory.createFile(std.testing.io, name, .{});
        file.close(std.testing.io);
    }
    var sources: TestSources = .{};

    try std.testing.expectError(error.TooManySessions, select(
        std.testing.allocator,
        std.testing.io,
        root,
        root,
        sources.view(),
        .continue_recent,
    ));
}

test "session selection rejects a missing stored cwd before full restoration" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const missing = try std.fs.path.resolve(std.testing.allocator, &.{ root, "missing" });
    defer std.testing.allocator.free(missing);
    var sources: TestSources = .{};
    const stamp = try sources.view().next();
    var opened = try journal_api.create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "missing-cwd.jsonl",
        .{ .id = stamp.id(), .timestamp = stamp.timestamp(), .cwd = missing },
        .none(),
    );
    opened.deinit();

    try std.testing.expectError(error.MissingCwd, select(
        std.testing.allocator,
        std.testing.io,
        root,
        root,
        sources.view(),
        .{ .open = "missing-cwd.jsonl" },
    ));
}

fn createAndDispose(allocator: std.mem.Allocator, root: []const u8) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/.zi/agent/sessions/00000000-0000-0000-0000-000000000001.jsonl",
        .{root},
    );
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch |failure| switch (failure) {
        error.FileNotFound => {},
        else => return failure,
    };
    var sources: TestSources = .{};
    var selected = try select(allocator, std.testing.io, root, root, sources.view(), .new);
    selected.deinit();
}

test "session selection settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDispose, .{root});
}
