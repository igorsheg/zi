/// Shared file storage primitives — lockdir protocol, file I/O with permissions,
/// and path resolution for all persistent data.
///
/// All zi data lives under ~/.zi/ (or ZI_CODING_AGENT_DIR override).
/// Lock protocol uses proper-lockfile compatible mkdir-based locking (30s stale).
const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.storage);

const stale_threshold_ns: i128 = 30 * std.time.ns_per_s;
const max_retries: u32 = 10;
const retry_delay_ns: u64 = 20 * std.time.ns_per_ms;
const max_file_size: usize = 1 * 1024 * 1024;

/// A file with proper-lockfile-compatible directory locking.
/// Shared by auth (auth.json) and settings (settings.json).
pub const LockedFile = struct {
    path: []const u8,
    lock_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !LockedFile {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{owned_path});
        return .{ .path = owned_path, .lock_path = lock_path, .allocator = allocator };
    }

    pub fn deinit(self: *LockedFile) void {
        self.allocator.free(self.lock_path);
        self.allocator.free(self.path);
    }

    /// Read file content. Returns null if file doesn't exist.
    pub fn readContent(self: *const LockedFile, allocator: std.mem.Allocator) ?[]const u8 {
        return std.fs.cwd().readFileAlloc(allocator, self.path, max_file_size) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                log.warn("failed to read {s}: {}", .{ self.path, err });
                return null;
            },
        };
    }

    /// Write content to file. Creates parent dirs (0o700) and file (0o600).
    pub fn writeContent(self: *const LockedFile, content: []const u8) !void {
        if (std.fs.path.dirname(self.path)) |parent| {
            try std.fs.cwd().makePath(parent);
            var dir = try std.fs.cwd().openDir(parent, .{});
            defer dir.close();
            posix.fchmod(dir.fd, 0o700) catch {};
        }
        const file = try std.fs.cwd().createFile(self.path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(content);
    }

    /// Acquire the lockdir. Returns true on success, false after max retries.
    pub fn acquireLock(self: *const LockedFile) bool {
        var attempt: u32 = 0;
        while (attempt < max_retries) : (attempt += 1) {
            std.fs.cwd().makeDir(self.lock_path) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    if (self.isLockStale()) {
                        self.breakLock();
                        continue;
                    }
                    std.Thread.sleep(retry_delay_ns);
                    continue;
                },
                else => {
                    log.warn("lock mkdir failed: {}", .{err});
                    return false;
                },
            };
            return true;
        }
        log.warn("failed to acquire lock after {d} attempts: {s}", .{ max_retries, self.lock_path });
        return false;
    }

    /// Release the lockdir.
    pub fn releaseLock(self: *const LockedFile) void {
        std.fs.cwd().deleteDir(self.lock_path) catch {};
    }

    fn isLockStale(self: *const LockedFile) bool {
        var dir = std.fs.cwd().openDir(self.lock_path, .{}) catch return false;
        defer dir.close();
        const stat = dir.stat() catch return false;
        const now = std.time.nanoTimestamp();
        const age_ns = now - stat.mtime;
        return age_ns > stale_threshold_ns;
    }

    fn breakLock(self: *const LockedFile) void {
        std.fs.cwd().deleteDir(self.lock_path) catch {};
    }
};

/// In-memory file substitute for testing. No locking needed.
pub const MemoryFile = struct {
    content: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryFile {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryFile) void {
        if (self.content) |c| self.allocator.free(c);
    }

    pub fn readContent(self: *const MemoryFile, allocator: std.mem.Allocator) ?[]const u8 {
        const c = self.content orelse return null;
        return allocator.dupe(u8, c) catch null;
    }

    pub fn writeContent(self: *MemoryFile, content: []const u8) !void {
        const duped = try self.allocator.dupe(u8, content);
        if (self.content) |old| self.allocator.free(old);
        self.content = duped;
    }

    pub fn acquireLock(_: *const MemoryFile) bool {
        return true;
    }

    pub fn releaseLock(_: *const MemoryFile) void {}
};

// ── Path resolution ─────────────────────────────────────────────────
//
// All zi persistent data lives under a single root:
//   ~/.zi/agent/          (default, or ZI_CODING_AGENT_DIR override)
//
// Directory layout:
//   ~/.zi/agent/auth.json
//   ~/.zi/agent/settings.json
//   ~/.zi/agent/models.json
//   ~/.zi/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl
//
// Project-local:
//   <cwd>/.zi/settings.json

/// Get the agent directory. Honors ZI_CODING_AGENT_DIR env var.
/// Default: ~/.zi/agent
pub fn getAgentDir(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |dir| return allocator.dupe(u8, dir);

    if (posix.getenv("ZI_CODING_AGENT_DIR")) |dir| {
        return expandTilde(allocator, dir);
    }

    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".zi", "agent" });
}

/// Get the project-local config directory: <cwd>/.zi
pub fn getProjectDir(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ cwd, ".zi" });
}

/// Get the sessions root directory: <agent_dir>/sessions
pub fn getSessionsDir(allocator: std.mem.Allocator, agent_dir_override: ?[]const u8) ![]const u8 {
    const agent_dir = try getAgentDir(allocator, agent_dir_override);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "sessions" });
}

/// Get the diagnostics root directory: <agent_dir>/diagnostics
pub fn getDiagnosticsDir(allocator: std.mem.Allocator, agent_dir_override: ?[]const u8) ![]const u8 {
    const agent_dir = try getAgentDir(allocator, agent_dir_override);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "diagnostics" });
}

/// Get the memory diagnostics directory: <agent_dir>/diagnostics/memory
pub fn getMemoryDiagnosticsDir(allocator: std.mem.Allocator, agent_dir_override: ?[]const u8) ![]const u8 {
    const diagnostics_dir = try getDiagnosticsDir(allocator, agent_dir_override);
    defer allocator.free(diagnostics_dir);
    return std.fs.path.join(allocator, &.{ diagnostics_dir, "memory" });
}

/// Get the logs diagnostics directory: <agent_dir>/diagnostics/logs
pub fn getLogDiagnosticsDir(allocator: std.mem.Allocator, agent_dir_override: ?[]const u8) ![]const u8 {
    const diagnostics_dir = try getDiagnosticsDir(allocator, agent_dir_override);
    defer allocator.free(diagnostics_dir);
    return std.fs.path.join(allocator, &.{ diagnostics_dir, "logs" });
}

/// Get the session directory for a specific cwd: <agent_dir>/sessions/<encoded-cwd>
pub fn getSessionDirForCwd(allocator: std.mem.Allocator, cwd: []const u8, agent_dir_override: ?[]const u8) ![]const u8 {
    const sessions_dir = try getSessionsDir(allocator, agent_dir_override);
    defer allocator.free(sessions_dir);
    const safe_cwd = try encodeCwd(allocator, cwd);
    defer allocator.free(safe_cwd);
    return std.fs.path.join(allocator, &.{ sessions_dir, safe_cwd });
}

/// Encode cwd into a safe directory name.
/// /Users/foo/bar → --Users-foo-bar--
/// Matches pi-mono's getDefaultSessionDir encoding.
pub fn encodeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    var start: usize = 0;
    if (cwd.len > 0 and (cwd[0] == '/' or cwd[0] == '\\')) start = 1;
    const stripped = cwd[start..];

    var result = try allocator.alloc(u8, stripped.len + 4);
    result[0] = '-';
    result[1] = '-';
    for (stripped, 0..) |c, i| {
        result[i + 2] = if (c == '/' or c == '\\' or c == ':') '-' else c;
    }
    result[stripped.len + 2] = '-';
    result[stripped.len + 3] = '-';
    return result;
}

/// Expand ~ prefix in a path.
fn expandTilde(allocator: std.mem.Allocator, dir: []const u8) ![]const u8 {
    if (std.mem.eql(u8, dir, "~")) {
        const home = posix.getenv("HOME") orelse return error.NoHomeDir;
        return allocator.dupe(u8, home);
    }
    if (dir.len > 1 and dir[0] == '~' and dir[1] == '/') {
        const home = posix.getenv("HOME") orelse return error.NoHomeDir;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, dir[1..] });
    }
    return allocator.dupe(u8, dir);
}

// ── Tests ───────────────────────────────────────────────────────────

test "memory file round-trips content" {
    const allocator = std.testing.allocator;
    var mf = MemoryFile.init(allocator);
    defer mf.deinit();

    try std.testing.expect(mf.readContent(allocator) == null);

    try mf.writeContent("hello world");
    const content = mf.readContent(allocator) orelse return error.TestUnexpectedResult;
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);
}

test "locked file acquire and release" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "test.json" });
    defer allocator.free(file_path);

    var lf = try LockedFile.init(allocator, file_path);
    defer lf.deinit();

    try std.testing.expect(lf.acquireLock());
    tmp.dir.access("test.json.lock", .{}) catch |err| {
        return if (err == error.FileNotFound) error.TestUnexpectedResult else err;
    };
    lf.releaseLock();
    tmp.dir.access("test.json.lock", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.TestUnexpectedResult;
}

test "encodeCwd encodes paths matching pi-mono format" {
    const allocator = std.testing.allocator;

    const r1 = try encodeCwd(allocator, "/Users/foo/bar");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("--Users-foo-bar--", r1);

    const r2 = try encodeCwd(allocator, "/tmp");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("--tmp--", r2);
}

test "getProjectDir joins cwd with .zi" {
    const allocator = std.testing.allocator;
    const dir = try getProjectDir(allocator, "/home/user/project");
    defer allocator.free(dir);
    try std.testing.expectEqualStrings("/home/user/project/.zi", dir);
}

test "getMemoryDiagnosticsDir nests under agent diagnostics" {
    const allocator = std.testing.allocator;
    const dir = try getMemoryDiagnosticsDir(allocator, "/tmp/zi-agent");
    defer allocator.free(dir);
    try std.testing.expectEqualStrings("/tmp/zi-agent/diagnostics/memory", dir);
}

test "getLogDiagnosticsDir nests under agent diagnostics" {
    const allocator = std.testing.allocator;
    const dir = try getLogDiagnosticsDir(allocator, "/tmp/zi-agent");
    defer allocator.free(dir);
    try std.testing.expectEqualStrings("/tmp/zi-agent/diagnostics/logs", dir);
}
