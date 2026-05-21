const std = @import("std");
const env_mod = @import("env.zig");

pub const Error = error{
    MissingHome,
} || std.mem.Allocator.Error;

pub const Storage = struct {
    allocator: std.mem.Allocator,

    zi_home: []const u8,
    agent_home: []const u8,
    user_settings: []const u8,
    sessions_dir: []const u8,

    project_root: ?[]const u8,
    project_zi: ?[]const u8,
    project_settings: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, environment: env_mod.Env, project_root: ?[]const u8) Error!Storage {
        const home = environment.get("HOME") orelse return error.MissingHome;
        return initFromHome(allocator, home, project_root);
    }

    pub fn initFromHome(allocator: std.mem.Allocator, home: []const u8, project_root: ?[]const u8) Error!Storage {
        std.debug.assert(home.len > 0);
        if (project_root) |root| std.debug.assert(root.len > 0);

        var storage: Storage = .{
            .allocator = allocator,
            .zi_home = try join(allocator, &.{ home, ".zi" }),
            .agent_home = undefined,
            .user_settings = undefined,
            .sessions_dir = undefined,
            .project_root = null,
            .project_zi = null,
            .project_settings = null,
        };
        errdefer storage.deinit();

        storage.agent_home = try join(allocator, &.{ storage.zi_home, "agent" });
        storage.user_settings = try join(allocator, &.{ storage.agent_home, "settings.json" });
        storage.sessions_dir = try join(allocator, &.{ storage.agent_home, "sessions" });

        if (project_root) |root| {
            storage.project_root = try allocator.dupe(u8, root);
            storage.project_zi = try join(allocator, &.{ storage.project_root.?, ".zi" });
            storage.project_settings = try join(allocator, &.{ storage.project_zi.?, "settings.json" });
        }

        return storage;
    }

    pub fn deinit(storage: *Storage) void {
        const allocator = storage.allocator;
        if (storage.project_settings) |path| allocator.free(path);
        if (storage.project_zi) |path| allocator.free(path);
        if (storage.project_root) |path| allocator.free(path);
        allocator.free(storage.sessions_dir);
        allocator.free(storage.user_settings);
        allocator.free(storage.agent_home);
        allocator.free(storage.zi_home);
        storage.* = undefined;
    }
};

fn join(allocator: std.mem.Allocator, parts: []const []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fs.path.join(allocator, parts);
}

test "storage builds user agent paths from home" {
    var storage = try Storage.initFromHome(std.testing.allocator, "/tmp/home", null);
    defer storage.deinit();

    try std.testing.expectEqualStrings("/tmp/home/.zi", storage.zi_home);
    try std.testing.expectEqualStrings("/tmp/home/.zi/agent", storage.agent_home);
    try std.testing.expectEqualStrings("/tmp/home/.zi/agent/settings.json", storage.user_settings);
    try std.testing.expectEqualStrings("/tmp/home/.zi/agent/sessions", storage.sessions_dir);
    try std.testing.expect(storage.project_root == null);
    try std.testing.expect(storage.project_zi == null);
    try std.testing.expect(storage.project_settings == null);
}

test "storage builds project settings path from project root" {
    var storage = try Storage.initFromHome(std.testing.allocator, "/tmp/home", "/work/project");
    defer storage.deinit();

    try std.testing.expectEqualStrings("/work/project", storage.project_root.?);
    try std.testing.expectEqualStrings("/work/project/.zi", storage.project_zi.?);
    try std.testing.expectEqualStrings("/work/project/.zi/settings.json", storage.project_settings.?);
}

test "storage requires home from environment" {
    try std.testing.expectError(error.MissingHome, Storage.init(std.testing.allocator, .empty, null));
}
