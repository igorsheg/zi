/// Shared file storage primitives — lockdir protocol, file I/O with permissions,
/// and agent directory resolution. Used by auth and settings.
///
/// Lock protocol is proper-lockfile compatible (mkdir-based, 30s stale detection)
/// so zi and pi-mono can safely share ~/.pi/agent/ files.
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

/// Get the agent directory. Honors PI_CODING_AGENT_DIR env var.
/// Default: ~/.pi/agent
/// pi-mono: config.ts:187-196
pub fn getAgentDir(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |dir| return allocator.dupe(u8, dir);

    if (posix.getenv("PI_CODING_AGENT_DIR")) |dir| {
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

    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".pi", "agent" });
}

// ── tests ───────────────────────────────────────────────────────────

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
