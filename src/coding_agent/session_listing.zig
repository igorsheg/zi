const std = @import("std");

const paths_mod = @import("paths.zig");

pub const SessionListOptions = struct {
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

pub const SessionList = struct {
    file_names: [][]const u8,
    truncated: bool,

    pub fn deinit(self: *SessionList, allocator: std.mem.Allocator) void {
        for (self.file_names) |file_name| allocator.free(file_name);
        allocator.free(self.file_names);
        self.* = undefined;
    }
};

pub fn listRuntimeSessions(
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
        if (!isSessionLeafName(entry.name)) continue;
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
        if (!isSessionLeafName(file_name)) return error.InvalidSessionFileName;
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

fn isSessionLeafName(file_name: []const u8) bool {
    if (!std.mem.eql(u8, std.fs.path.basename(file_name), file_name)) return false;
    if (!std.mem.endsWith(u8, file_name, ".jsonl")) return false;
    return std.mem.indexOfScalar(u8, file_name, '_') != null;
}

fn newerSessionFile(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .gt;
}
