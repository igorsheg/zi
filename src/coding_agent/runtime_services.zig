const std = @import("std");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const auth_mod = @import("auth.zig");
const paths_mod = @import("paths.zig");
const settings_mod = @import("settings.zig");

pub const RuntimeServices = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    task_runtime_owner: RuntimeOwner,
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: settings_mod.SettingsManager,
    auth_manager: *auth_mod.AuthManager,
    provider_registry: ai.ProviderRegistry,
    environ: ?*const std.process.Environ.Map,
    openai_provider: *ai.OpenAiResponsesProvider,
    openai_codex_provider: *ai.OpenAiCodexResponsesProvider,

    pub const Options = struct {
        cwd: []const u8,
        agent_dir: []const u8,
        dir: std.Io.Dir = .cwd(),
        environ: ?*const std.process.Environ.Map = null,
        task_runtime: ?*runtime.Runtime = null,
    };

    const RuntimeOwner = enum {
        owned,
        borrowed,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !RuntimeServices {
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        const agent_dir = try allocator.dupe(u8, options.agent_dir);
        errdefer allocator.free(agent_dir);
        const task_runtime = options.task_runtime orelse try runtime.Runtime.init(allocator, .{});
        errdefer if (options.task_runtime == null) task_runtime.deinit();
        const io = task_runtime.io();

        const resource_paths: paths_mod.PersistencePaths = .{ .global_dir = agent_dir, .cwd = cwd };
        var settings_manager = try settings_mod.SettingsManager.init(allocator, io, .{
            .paths = resource_paths,
            .dir = options.dir,
        });
        errdefer settings_manager.deinit();

        const auth_manager = try allocator.create(auth_mod.AuthManager);
        errdefer allocator.destroy(auth_manager);
        auth_manager.* = try auth_mod.AuthManager.init(allocator, io, .{
            .environ = options.environ,
            .paths = resource_paths,
            .dir = options.dir,
        });
        errdefer auth_manager.deinit();

        const openai_provider = try allocator.create(ai.OpenAiResponsesProvider);
        errdefer allocator.destroy(openai_provider);
        openai_provider.* = ai.OpenAiResponsesProvider.init(.{ .environ = options.environ });

        const openai_codex_provider = try allocator.create(ai.OpenAiCodexResponsesProvider);
        errdefer allocator.destroy(openai_codex_provider);
        openai_codex_provider.* = ai.OpenAiCodexResponsesProvider.init(.{});

        var provider_registry = ai.ProviderRegistry.init(allocator);
        errdefer provider_registry.deinit();
        try openai_provider.register(&provider_registry);
        try openai_codex_provider.register(&provider_registry);

        return .{
            .allocator = allocator,
            .io = io,
            .task_runtime = task_runtime,
            .task_runtime_owner = if (options.task_runtime == null) .owned else .borrowed,
            .cwd = cwd,
            .agent_dir = agent_dir,
            .settings_manager = settings_manager,
            .auth_manager = auth_manager,
            .provider_registry = provider_registry,
            .environ = options.environ,
            .openai_provider = openai_provider,
            .openai_codex_provider = openai_codex_provider,
        };
    }

    pub fn deinit(self: *RuntimeServices) void {
        self.provider_registry.deinit();
        switch (self.task_runtime_owner) {
            .owned => self.task_runtime.deinit(),
            .borrowed => {},
        }
        self.allocator.destroy(self.openai_codex_provider);
        self.allocator.destroy(self.openai_provider);
        self.auth_manager.deinit();
        self.allocator.destroy(self.auth_manager);
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

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
    });
    defer services.deinit();

    try std.testing.expectEqualStrings("repo", services.cwd);
    try std.testing.expectEqualStrings("agent", services.agent_dir);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_responses) != null);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_codex_responses) != null);
}

test "runtime services can borrow process task runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    try std.testing.expect(services.task_runtime == task_runtime);
    try std.testing.expectEqual(RuntimeServices.RuntimeOwner.borrowed, services.task_runtime_owner);
}
