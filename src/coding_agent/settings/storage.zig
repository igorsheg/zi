const std = @import("std");
const types = @import("types.zig");

pub const SettingsStorage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        with_lock: *const fn (
            ptr: *anyopaque,
            scope: types.SettingsScope,
            callback_ctx: *anyopaque,
            callback: *const fn (ctx: *anyopaque, current: ?[]const u8) ?[]const u8,
        ) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn withLock(
        self: SettingsStorage,
        scope: types.SettingsScope,
        callback_ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, current: ?[]const u8) ?[]const u8,
    ) void {
        self.vtable.with_lock(self.ptr, scope, callback_ctx, callback);
    }

    pub fn deinit(self: SettingsStorage) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const InMemorySettingsStorage = struct {
    global: ?[]const u8 = null,
    project: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    const vtable_instance: SettingsStorage.VTable = .{
        .with_lock = withLockImpl,
        .deinit = deinitImpl,
    };

    pub fn init(allocator: std.mem.Allocator) InMemorySettingsStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InMemorySettingsStorage) void {
        if (self.global) |g| self.allocator.free(g);
        if (self.project) |p| self.allocator.free(p);
    }

    pub fn asStorage(self: *InMemorySettingsStorage) SettingsStorage {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_instance,
        };
    }

    fn withLockImpl(ptr: *anyopaque, scope: types.SettingsScope, callback_ctx: *anyopaque, callback: *const fn (ctx: *anyopaque, current: ?[]const u8) ?[]const u8) void {
        const self: *InMemorySettingsStorage = @ptrCast(@alignCast(ptr));
        const current = switch (scope) {
            .global => self.global,
            .project => self.project,
        };
        const next = callback(callback_ctx, current);
        if (next) |new_content| {
            const duped = self.allocator.dupe(u8, new_content) catch return;
            switch (scope) {
                .global => {
                    if (self.global) |old| self.allocator.free(old);
                    self.global = duped;
                },
                .project => {
                    if (self.project) |old| self.allocator.free(old);
                    self.project = duped;
                },
            }
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *InMemorySettingsStorage = @ptrCast(@alignCast(ptr));
        const alloc = self.allocator;
        self.deinit();
        alloc.destroy(self);
    }
};
