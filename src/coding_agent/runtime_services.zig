const std = @import("std");
const ai = @import("../ai/root.zig");
const paths_mod = @import("paths.zig");
const settings_mod = @import("settings.zig");

pub const RuntimeServices = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: settings_mod.SettingsManager,
    provider_registry: ai.ProviderRegistry,

    pub const Options = struct {
        cwd: []const u8,
        agent_dir: []const u8,
        dir: std.Io.Dir = .cwd(),
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !RuntimeServices {
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        const agent_dir = try allocator.dupe(u8, options.agent_dir);
        errdefer allocator.free(agent_dir);

        const resource_paths: paths_mod.PersistencePaths = .{ .global_dir = agent_dir, .cwd = cwd };
        const settings_manager = try settings_mod.SettingsManager.init(allocator, io, .{
            .paths = resource_paths,
            .dir = options.dir,
        });
        errdefer settings_manager.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .agent_dir = agent_dir,
            .settings_manager = settings_manager,
            .provider_registry = ai.ProviderRegistry.init(allocator),
        };
    }

    pub fn paths(self: *const RuntimeServices) paths_mod.PersistencePaths {
        return .{ .global_dir = self.agent_dir, .cwd = self.cwd };
    }

    pub fn deinit(self: *RuntimeServices) void {
        self.provider_registry.deinit();
        self.settings_manager.deinit();
        self.allocator.free(self.agent_dir);
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

test "runtime services owns stable cwd, agent dir, settings manager" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var services = try RuntimeServices.init(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    try std.testing.expectEqualStrings("repo", services.cwd);
    try std.testing.expectEqualStrings("agent", services.agent_dir);
    const service_paths = services.paths();
    try std.testing.expectEqualStrings(services.cwd, service_paths.cwd);
    try std.testing.expectEqualStrings(services.agent_dir, service_paths.global_dir);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_responses) == null);
}
