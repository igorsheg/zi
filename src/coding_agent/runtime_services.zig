const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const auth_mod = @import("auth.zig");
const model_registry_mod = @import("model_registry.zig");
const paths_mod = @import("paths.zig");
const settings_mod = @import("settings.zig");

pub const RuntimeServices = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: settings_mod.SettingsManager,
    auth_manager: *auth_mod.AuthManager,
    model_registry: model_registry_mod.ModelRegistry,
    provider_registry: ai.ProviderRegistry,
    openai_provider: *ai.OpenAiResponsesProvider,
    openai_codex_provider: *ai.OpenAiCodexResponsesProvider,
    diagnostics: [diagnostic_capacity]Diagnostic = undefined,
    diagnostic_count: usize = 0,

    pub const Options = struct {
        cwd: []const u8,
        agent_dir: []const u8,
        dir: std.Io.Dir = .cwd(),
        environ: ?*const std.process.Environ.Map = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !RuntimeServices {
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        const agent_dir = try allocator.dupe(u8, options.agent_dir);
        errdefer allocator.free(agent_dir);

        const resource_paths: paths_mod.PersistencePaths = .{ .global_dir = agent_dir, .cwd = cwd };
        var settings_manager = try settings_mod.SettingsManager.init(allocator, io, .{
            .paths = resource_paths,
            .dir = options.dir,
        });
        errdefer settings_manager.deinit();

        const auth_manager = try allocator.create(auth_mod.AuthManager);
        errdefer allocator.destroy(auth_manager);
        auth_manager.* = auth_mod.AuthManager.init(.{ .environ = options.environ });

        const model_registry = model_registry_mod.ModelRegistry.init(auth_manager);

        const openai_provider = try allocator.create(ai.OpenAiResponsesProvider);
        errdefer allocator.destroy(openai_provider);
        openai_provider.* = ai.OpenAiResponsesProvider.init(.{});

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
            .cwd = cwd,
            .agent_dir = agent_dir,
            .settings_manager = settings_manager,
            .auth_manager = auth_manager,
            .model_registry = model_registry,
            .provider_registry = provider_registry,
            .openai_provider = openai_provider,
            .openai_codex_provider = openai_codex_provider,
        };
    }

    pub const diagnostic_capacity = 8;

    pub const Diagnostic = union(enum) {
        unresolved_model_setting: ModelSetting,
        unresolved_stream: StreamSetting,

        pub const ModelSetting = struct {
            provider: ?[]const u8,
            model: ?[]const u8,
        };

        pub const StreamSetting = struct {
            api: []const u8,
        };
    };

    pub fn paths(self: *const RuntimeServices) paths_mod.PersistencePaths {
        return .{ .global_dir = self.agent_dir, .cwd = self.cwd };
    }

    pub fn getApiKeyHook(self: *const RuntimeServices) agent_mod.GetApiKeyHook {
        return self.auth_manager.hook();
    }

    pub fn clearDiagnostics(self: *RuntimeServices) void {
        self.diagnostic_count = 0;
    }

    pub fn appendDiagnostic(self: *RuntimeServices, diagnostic: Diagnostic) void {
        if (self.diagnostic_count == diagnostic_capacity) return;
        self.diagnostics[self.diagnostic_count] = diagnostic;
        self.diagnostic_count += 1;
    }

    pub fn diagnosticSlice(self: *const RuntimeServices) []const Diagnostic {
        return self.diagnostics[0..self.diagnostic_count];
    }

    pub fn deinit(self: *RuntimeServices) void {
        self.provider_registry.deinit();
        self.allocator.destroy(self.openai_codex_provider);
        self.allocator.destroy(self.openai_provider);
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
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_responses) != null);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_codex_responses) != null);
}
