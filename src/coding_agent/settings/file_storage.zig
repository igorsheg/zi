const std = @import("std");
const shared = @import("../../storage.zig");
const types = @import("types.zig");
const storage_mod = @import("storage.zig");

const log = std.log.scoped(.settings_file_storage);

pub const FileSettingsStorage = struct {
    allocator: std.mem.Allocator,
    global: shared.LockedFile,
    project: shared.LockedFile,

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
        const agent_dir = try shared.getAgentDir(allocator, agent_dir_override);
        defer allocator.free(agent_dir);

        const global_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
        defer allocator.free(global_path);
        const project_dir = try shared.getProjectDir(allocator, cwd);
        defer allocator.free(project_dir);
        const project_path = try std.fs.path.join(allocator, &.{ project_dir, "settings.json" });
        defer allocator.free(project_path);

        var global = try shared.LockedFile.init(allocator, global_path);
        errdefer global.deinit();
        const project = try shared.LockedFile.init(allocator, project_path);

        return .{
            .allocator = allocator,
            .global = global,
            .project = project,
        };
    }

    pub fn deinit(self: *FileSettingsStorage) void {
        self.project.deinit();
        self.global.deinit();
    }

    pub fn asStorage(self: *FileSettingsStorage) storage_mod.SettingsStorage {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_instance,
        };
    }

    fn fileForScope(self: *FileSettingsStorage, scope: types.SettingsScope) *shared.LockedFile {
        return switch (scope) {
            .global => &self.global,
            .project => &self.project,
        };
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
        const file = self.fileForScope(scope);

        // Check if file exists before locking (pi-mono: settings-manager.ts:185-188)
        const file_exists = std.fs.cwd().access(file.path, .{}) != error.FileNotFound;

        var locked = false;
        if (file_exists) {
            if (!file.acquireLock()) return;
            locked = true;
        }
        defer if (locked) file.releaseLock();

        const current = if (file_exists) file.readContent(self.allocator) else null;
        defer if (current) |c| self.allocator.free(c);

        const next = callback(callback_ctx, current);

        if (next) |new_content| {
            if (!locked) {
                if (!file.acquireLock()) return;
                locked = true;
            }
            file.writeContent(new_content) catch return;
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *FileSettingsStorage = @ptrCast(@alignCast(ptr));
        const alloc = self.allocator;
        self.deinit();
        alloc.destroy(self);
    }
};
