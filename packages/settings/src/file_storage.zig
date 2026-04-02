const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");
const storage_mod = @import("storage.zig");

const log = std.log.scoped(.settings_file_storage);

const max_retries: u32 = 10;
const retry_delay_ns: u64 = 20 * std.time.ns_per_ms;
const stale_threshold_ns: i128 = 30 * std.time.ns_per_s;
const max_file_size: usize = 1 * 1024 * 1024;

pub const FileSettingsStorage = struct {
    allocator: std.mem.Allocator,
    global_path: []const u8,
    project_path: []const u8,

    const vtable_instance: storage_mod.SettingsStorage.VTable = .{
        .with_lock = withLockImpl,
        .deinit = deinitImpl,
    };

    /// pi-mono: settings-manager.ts:146-149
    pub fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        agent_dir_override: ?[]const u8,
    ) !FileSettingsStorage {
        const agent_dir = try getAgentDir(allocator, agent_dir_override);
        defer allocator.free(agent_dir);

        const global_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
        errdefer allocator.free(global_path);

        const project_path = try std.fs.path.join(allocator, &.{ cwd, ".pi", "settings.json" });

        return .{
            .allocator = allocator,
            .global_path = global_path,
            .project_path = project_path,
        };
    }

    pub fn deinit(self: *FileSettingsStorage) void {
        self.allocator.free(self.project_path);
        self.allocator.free(self.global_path);
    }

    pub fn asStorage(self: *FileSettingsStorage) storage_mod.SettingsStorage {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_instance,
        };
    }

    fn pathForScope(self: *const FileSettingsStorage, scope: types.SettingsScope) []const u8 {
        return switch (scope) {
            .global => self.global_path,
            .project => self.project_path,
        };
    }

    fn lockPathForScope(self: *const FileSettingsStorage, allocator: std.mem.Allocator, scope: types.SettingsScope) ![]const u8 {
        const path = self.pathForScope(scope);
        return std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    }

    /// pi-mono: settings-manager.ts:178-206
    /// Lock on read if file exists, lock on write if callback returns content.
    /// Lazy directory creation — only when actually writing.
    fn withLockImpl(
        ptr: *anyopaque,
        scope: types.SettingsScope,
        callback_ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, current: ?[]const u8) ?[]const u8,
    ) void {
        const self: *FileSettingsStorage = @ptrCast(@alignCast(ptr));
        const path = self.pathForScope(scope);

        const lock_path = self.lockPathForScope(self.allocator, scope) catch return;
        defer self.allocator.free(lock_path);

        const file_exists = std.fs.cwd().access(path, .{}) != error.FileNotFound;

        var locked = false;
        if (file_exists) {
            if (!acquireLock(lock_path)) return;
            locked = true;
        }
        defer if (locked) releaseLock(lock_path);

        const current = if (file_exists)
            std.fs.cwd().readFileAlloc(self.allocator, path, max_file_size) catch null
        else
            null;
        defer if (current) |c| self.allocator.free(c);

        const next = callback(callback_ctx, current);

        if (next) |new_content| {
            if (!locked) {
                if (!acquireLock(lock_path)) return;
                locked = true;
            }

            if (std.fs.path.dirname(path)) |parent| {
                std.fs.cwd().makePath(parent) catch return;
            }

            const file = std.fs.cwd().createFile(path, .{}) catch return;
            defer file.close();
            file.writeAll(new_content) catch return;
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *FileSettingsStorage = @ptrCast(@alignCast(ptr));
        const alloc = self.allocator;
        self.deinit();
        alloc.destroy(self);
    }
};

/// Get the agent directory. Honors PI_CODING_AGENT_DIR env var.
/// pi-mono: config.ts:187-196
pub fn getAgentDir(allocator: std.mem.Allocator, override: ?[]const u8) ![]const u8 {
    if (override) |dir| return allocator.dupe(u8, dir);

    if (std.posix.getenv("PI_CODING_AGENT_DIR")) |dir| {
        if (std.mem.eql(u8, dir, "~")) {
            const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
            return allocator.dupe(u8, home);
        }
        if (dir.len > 1 and dir[0] == '~' and dir[1] == '/') {
            const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, dir[1..] });
        }
        return allocator.dupe(u8, dir);
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".pi", "agent" });
}

// ── lockdir protocol (same pattern as auth, independent impl) ──────────

fn acquireLock(lock_path: []const u8) bool {
    var attempt: u32 = 0;
    while (attempt < max_retries) : (attempt += 1) {
        std.fs.cwd().makeDir(lock_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (isLockStale(lock_path)) {
                    breakLock(lock_path);
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

fn releaseLock(lock_path: []const u8) void {
    std.fs.cwd().deleteDir(lock_path) catch {};
}

fn isLockStale(lock_path: []const u8) bool {
    var dir = std.fs.cwd().openDir(lock_path, .{}) catch return false;
    defer dir.close();
    const stat = dir.stat() catch return false;
    const now = std.time.nanoTimestamp();
    const age_ns = now - stat.mtime;
    return age_ns > stale_threshold_ns;
}

fn breakLock(lock_path: []const u8) void {
    std.fs.cwd().deleteDir(lock_path) catch {};
}
