const std = @import("std");

const paths_mod = @import("paths.zig");

const SessionListOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    max_sessions: usize = 128,
    max_directory_entries: usize = 512,
};

pub const SessionSelectionOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    explicit_file_name: ?[]const u8 = null,
    max_sessions: usize = 128,
    max_directory_entries: usize = 512,
};

const SessionList = struct {
    file_names: [][]const u8,
    truncated: bool,

    pub fn deinit(self: *SessionList, allocator: std.mem.Allocator) void {
        for (self.file_names) |file_name| allocator.free(file_name);
        allocator.free(self.file_names);
        self.* = undefined;
    }
};

fn listRuntimeSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SessionListOptions,
) !SessionList {
    const sessions_dir = try runtimeSessionsDir(allocator, .{
        .cwd = options.cwd,
        .dir = options.dir,
        .agent_dir_override = options.agent_dir_override,
        .environ = options.environ,
    });
    defer allocator.free(sessions_dir);

    var dir = options.dir.openDir(io, sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{
            .file_names = try allocator.alloc([]const u8, 0),
            .truncated = false,
        },
        else => return err,
    };
    defer dir.close(io);

    var file_names = std.ArrayList([]const u8).empty;
    errdefer {
        for (file_names.items) |file_name| allocator.free(file_name);
        file_names.deinit(allocator);
    }

    var iterator = dir.iterate();
    var directory_entries_seen: usize = 0;
    var truncated = false;
    while (try iterator.next(io)) |entry| {
        if (directory_entries_seen == options.max_directory_entries) {
            truncated = true;
            break;
        }
        directory_entries_seen += 1;
        if (entry.kind != .file) continue;
        if (!paths_mod.isSessionFileLeafName(entry.name)) continue;
        const copy = try allocator.dupe(u8, entry.name);
        file_names.append(allocator, copy) catch |err| {
            allocator.free(copy);
            return err;
        };
    }

    std.mem.sort([]const u8, file_names.items, {}, newerSessionFile);
    while (file_names.items.len > options.max_sessions) {
        allocator.free(file_names.pop().?);
        truncated = true;
    }
    return .{
        .file_names = try file_names.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

pub fn selectRuntimeSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SessionSelectionOptions,
) !?[]const u8 {
    if (options.explicit_file_name) |file_name| {
        if (!paths_mod.isSessionFileLeafName(file_name)) return error.InvalidSessionFileName;
        const sessions_dir = try runtimeSessionsDir(allocator, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .dir = options.dir,
            .environ = options.environ,
        });
        defer allocator.free(sessions_dir);
        const store_file_name = try std.fs.path.join(allocator, &.{ sessions_dir, file_name });
        defer allocator.free(store_file_name);
        options.dir.access(io, store_file_name, .{
            .follow_symlinks = false,
            .read = true,
            .write = false,
            .execute = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const selected = try allocator.dupe(u8, file_name);
        return selected;
    }

    var list = try listRuntimeSessions(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .max_sessions = options.max_sessions,
        .max_directory_entries = options.max_directory_entries,
    });
    defer list.deinit(allocator);

    if (list.truncated) return error.SessionListTruncated;
    if (list.file_names.len == 0) return null;
    const selected = try allocator.dupe(u8, list.file_names[0]);
    return selected;
}

const RuntimeSessionDirOptions = struct {
    cwd: []const u8,
    agent_dir_override: ?[]const u8,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
};

fn runtimeSessionsDir(
    allocator: std.mem.Allocator,
    options: RuntimeSessionDirOptions,
) ![]const u8 {
    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    const paths: paths_mod.PersistencePaths = .{
        .global_dir = resolved_agent_dir,
        .cwd = options.cwd,
    };
    return paths.sessionsDirForCwd(allocator);
}

fn newerSessionFile(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .gt;
}

fn createSessionListingTestDirs(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "agent");
    try dir.createDirPath(std.testing.io, "repo");
}

fn writeSessionListingTestFile(dir: std.Io.Dir, file_name: []const u8) !void {
    try dir.createDirPath(std.testing.io, "agent/sessions/--repo--");
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "agent/sessions/--repo--/{s}", .{file_name});
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "{}\n" });
}

test "session listing returns resumable leaf names newest first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");

    var list = try listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), list.file_names.len);
    try std.testing.expect(!list.truncated);
    try std.testing.expectEqualStrings("2026-05-28T00:00:00Z_second.jsonl", list.file_names[0]);
    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_first.jsonl", list.file_names[1]);
}

test "session listing is bounded and ignores non session files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/sessions/--repo--/notes.txt",
        .data = "ignore",
    });

    var list = try listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .max_sessions = 1,
    });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), list.file_names.len);
    try std.testing.expect(list.truncated);
    try std.testing.expect(std.mem.endsWith(u8, list.file_names[0], ".jsonl"));
}

test "session listing returns empty when session directory is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);

    var list = try listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), list.file_names.len);
    try std.testing.expect(!list.truncated);
}

test "session selection accepts explicit resumable leaf name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_session.jsonl");

    const selected = (try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .explicit_file_name = "2026-05-27T00:00:00Z_session.jsonl",
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_session.jsonl", selected);
}

test "session selection chooses newest only from complete listing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");

    const selected = (try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-28T00:00:00Z_second.jsonl", selected);
}

test "session selection rejects traversal and reports absent sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);

    try std.testing.expectError(
        error.InvalidSessionFileName,
        selectRuntimeSession(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .dir = tmp.dir,
            .explicit_file_name = "../outside.jsonl",
        }),
    );

    const selected = try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .explicit_file_name = "2026-05-27T00:00:00Z_missing.jsonl",
    });

    try std.testing.expect(selected == null);
}

test "session selection fails when newest listing is truncated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");

    try std.testing.expectError(
        error.SessionListTruncated,
        selectRuntimeSession(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .dir = tmp.dir,
            .max_sessions = 1,
        }),
    );
}
