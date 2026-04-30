const std = @import("std");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../root.zig");
const auth = @import("../auth/root.zig");
const settings_mod = @import("../settings/root.zig");
const common = @import("common.zig");

pub const InitDiagnostic = enum {
    auth_storage_init_failed,
    settings_init_failed,
    model_registry_init_failed,
};

pub const InitResult = union(enum) {
    ok: Runtime,
    err: InitDiagnostic,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    auth_storage: *auth.storage.AuthStorage,
    settings_manager: *settings_mod.manager.SettingsManager,
    model_registry: *coding_agent.ModelRegistry,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!InitResult {
        const cwd = try resolveCwd(allocator, io);
        errdefer allocator.free(cwd);

        const auth_storage = try allocator.create(auth.storage.AuthStorage);
        errdefer allocator.destroy(auth_storage);
        auth_storage.* = auth.storage.AuthStorage.create(allocator, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .err = .auth_storage_init_failed },
        };
        errdefer auth_storage.deinit();

        const settings_manager = try allocator.create(settings_mod.manager.SettingsManager);
        errdefer allocator.destroy(settings_manager);
        settings_manager.* = settings_mod.manager.SettingsManager.create(allocator, cwd, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .err = .settings_init_failed },
        };
        errdefer settings_manager.deinit();

        const custom_models = try common.convertCustomModels(allocator, settings_manager.getModels());
        defer if (custom_models.len > 0) allocator.free(custom_models);

        const model_registry = try allocator.create(coding_agent.ModelRegistry);
        errdefer allocator.destroy(model_registry);
        model_registry.* = coding_agent.ModelRegistry.init(allocator, auth_storage, custom_models) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer model_registry.deinit();

        return .{ .ok = .{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .auth_storage = auth_storage,
            .settings_manager = settings_manager,
            .model_registry = model_registry,
        } };
    }

    pub fn deinit(self: *Runtime) void {
        self.model_registry.deinit();
        self.allocator.destroy(self.model_registry);
        self.settings_manager.deinit();
        self.allocator.destroy(self.settings_manager);
        self.auth_storage.deinit();
        self.allocator.destroy(self.auth_storage);
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

fn resolveCwd(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try allocator.dupe(u8, "/unknown"),
    };
}
