const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.auth_file_backend);

const stale_threshold_ns: i128 = 30 * std.time.ns_per_s;
const max_retries: u32 = 10;
const retry_delay_ns: u64 = 20 * std.time.ns_per_ms;
const max_file_size: usize = 1 * 1024 * 1024; // 1 MiB

/// Auth storage backend — tagged union dispatching to file or in-memory.
pub const Backend = union(enum) {
    file: FileState,
    memory: MemoryState,

    pub fn readContent(self: *const Backend, allocator: std.mem.Allocator) ?[]const u8 {
        return switch (self.*) {
            .file => |*s| s.readContent(allocator),
            .memory => |*s| s.readContent(allocator),
        };
    }

    pub fn writeContent(self: *Backend, content: []const u8) !void {
        return switch (self.*) {
            .file => |*s| s.writeContent(content),
            .memory => |*s| s.writeContent(content),
        };
    }

    pub fn acquireLock(self: *const Backend) bool {
        return switch (self.*) {
            .file => |*s| s.acquireLock(),
            .memory => true,
        };
    }

    pub fn releaseLock(self: *const Backend) void {
        switch (self.*) {
            .file => |*s| s.releaseLock(),
            .memory => {},
        }
    }
};

pub const FileState = struct {
    auth_path: []const u8,
    lock_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, auth_path_override: ?[]const u8) !FileState {
        const auth_path = if (auth_path_override) |p|
            try allocator.dupe(u8, p)
        else
            try defaultAuthPath(allocator);
        errdefer allocator.free(auth_path);

        const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{auth_path});

        return .{
            .auth_path = auth_path,
            .lock_path = lock_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileState) void {
        self.allocator.free(self.lock_path);
        self.allocator.free(self.auth_path);
    }

    pub fn readContent(self: *const FileState, allocator: std.mem.Allocator) ?[]const u8 {
        return std.fs.cwd().readFileAlloc(allocator, self.auth_path, max_file_size) catch |err| {
            switch (err) {
                error.FileNotFound => return null,
                else => {
                    log.warn("failed to read {s}: {}", .{ self.auth_path, err });
                    return null;
                },
            }
        };
    }

    pub fn writeContent(self: *const FileState, content: []const u8) !void {
        // ensure parent directory exists with 0o700
        if (std.fs.path.dirname(self.auth_path)) |parent| {
            try std.fs.cwd().makePath(parent);
            // tighten permissions on the immediate parent
            var dir = try std.fs.cwd().openDir(parent, .{});
            defer dir.close();
            chmodDir(dir, 0o700);
        }

        // write file with 0o600
        const file = try std.fs.cwd().createFile(self.auth_path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(content);
    }

    pub fn acquireLock(self: *const FileState) bool {
        var attempt: u32 = 0;
        while (attempt < max_retries) : (attempt += 1) {
            // atomic mkdir — succeeds only if we created it
            std.fs.cwd().makeDir(self.lock_path) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    if (self.isLockStale()) {
                        self.breakLock();
                        // retry immediately after breaking
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
        log.warn("failed to acquire lock after {d} attempts", .{max_retries});
        return false;
    }

    pub fn releaseLock(self: *const FileState) void {
        std.fs.cwd().deleteDir(self.lock_path) catch {};
    }

    fn isLockStale(self: *const FileState) bool {
        var lock_dir = std.fs.cwd().openDir(self.lock_path, .{}) catch return false;
        defer lock_dir.close();
        const stat = lock_dir.stat() catch return false;
        const now = std.time.nanoTimestamp();
        const age_ns = now - stat.mtime;
        return age_ns > stale_threshold_ns;
    }

    fn breakLock(self: *const FileState) void {
        std.fs.cwd().deleteDir(self.lock_path) catch {};
    }
};

pub const MemoryState = struct {
    content: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryState) void {
        if (self.content) |c| self.allocator.free(c);
    }

    pub fn readContent(self: *const MemoryState, allocator: std.mem.Allocator) ?[]const u8 {
        const c = self.content orelse return null;
        return allocator.dupe(u8, c) catch return null;
    }

    pub fn writeContent(self: *MemoryState, content: []const u8) !void {
        const duped = try self.allocator.dupe(u8, content);
        if (self.content) |old| self.allocator.free(old);
        self.content = duped;
    }
};

pub fn defaultAuthPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.pi/agent/auth.json", .{home});
}

fn chmodDir(dir: std.fs.Dir, mode: std.posix.mode_t) void {
    const fd: posix.fd_t = dir.fd;
    posix.fchmod(fd, mode) catch {};
}

// ── tests ────────────────────────────────────────────────────────────────

test "memory backend round-trips content" {
    const allocator = std.testing.allocator;
    var backend: Backend = .{ .memory = MemoryState.init(allocator) };
    defer backend.memory.deinit();

    try std.testing.expect(backend.readContent(allocator) == null);

    try backend.writeContent("{\"anthropic\":{\"type\":\"api_key\",\"key\":\"sk-test\"}}");

    const content = backend.readContent(allocator) orelse return error.TestUnexpectedResult;
    defer allocator.free(content);
    try std.testing.expectEqualStrings(
        "{\"anthropic\":{\"type\":\"api_key\",\"key\":\"sk-test\"}}",
        content,
    );
}

test "file backend lock acquire and release" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const auth_path = try std.fs.path.join(allocator, &.{ tmp_path, "auth.json" });
    defer allocator.free(auth_path);

    var fs: FileState = try FileState.init(allocator, auth_path);
    defer fs.deinit();

    // acquire succeeds
    try std.testing.expect(fs.acquireLock());
    // lock dir exists
    tmp.dir.access("auth.json.lock", .{}) catch |err| {
        return if (err == error.FileNotFound) error.TestUnexpectedResult else err;
    };
    // release removes it
    fs.releaseLock();
    tmp.dir.access("auth.json.lock", .{}) catch |err| switch (err) {
        error.FileNotFound => return, // expected
        else => return err,
    };
    return error.TestUnexpectedResult; // should have been FileNotFound
}
