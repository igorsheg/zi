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
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: settings_mod.SettingsManager,
    auth_manager: *auth_mod.AuthManager,
    provider_registry: ai.ProviderRegistry,
    environ: ?*const std.process.Environ.Map,
    openai_provider: *ai.OpenAiResponsesProvider,
    openai_codex_provider: *ai.OpenAiCodexResponsesProvider,
    faux_provider: ?*ai.FauxProvider,
    faux_gate_active: bool,

    pub const Options = struct {
        cwd: []const u8,
        agent_dir: []const u8,
        dir: std.Io.Dir = .cwd(),
        environ: ?*const std.process.Environ.Map = null,
        task_runtime: *runtime.Runtime,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !RuntimeServices {
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        const agent_dir = try allocator.dupe(u8, options.agent_dir);
        errdefer allocator.free(agent_dir);
        const io = options.task_runtime.io();

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

        const faux_gate_active = ai.retainFauxProviderGateFromEnviron(options.environ);
        errdefer if (faux_gate_active) ai.releaseFauxProviderGate();

        var provider_registry = ai.ProviderRegistry.init(allocator);
        errdefer provider_registry.deinit();
        try openai_provider.register(&provider_registry);
        try openai_codex_provider.register(&provider_registry);

        const faux_provider = if (faux_gate_active)
            try initFauxProvider(allocator, io, options.dir, options.environ, &provider_registry)
        else
            null;
        errdefer if (faux_provider) |provider| {
            provider.deinit();
            allocator.destroy(provider);
        };

        return .{
            .allocator = allocator,
            .io = io,
            .task_runtime = options.task_runtime,
            .cwd = cwd,
            .agent_dir = agent_dir,
            .settings_manager = settings_manager,
            .auth_manager = auth_manager,
            .provider_registry = provider_registry,
            .environ = options.environ,
            .openai_provider = openai_provider,
            .openai_codex_provider = openai_codex_provider,
            .faux_provider = faux_provider,
            .faux_gate_active = faux_gate_active,
        };
    }

    pub fn deinit(self: *RuntimeServices) void {
        self.provider_registry.deinit();
        if (self.faux_provider) |provider| {
            provider.deinit();
            self.allocator.destroy(provider);
        }
        self.allocator.destroy(self.openai_codex_provider);
        self.allocator.destroy(self.openai_provider);
        if (self.faux_gate_active) ai.releaseFauxProviderGate();
        self.auth_manager.deinit();
        self.allocator.destroy(self.auth_manager);
        self.settings_manager.deinit();
        self.allocator.free(self.agent_dir);
        self.allocator.free(self.cwd);
        self.* = undefined;
    }
};

const default_faux_script = "faux provider streamed through the real TUI\n";
// faux's buffered stream has 256 events; one text block spends 4 on lifecycle events.
const max_faux_script_bytes = 252 * 64;

fn initFauxProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    registry: *ai.ProviderRegistry,
) !*ai.FauxProvider {
    const provider = try allocator.create(ai.FauxProvider);
    errdefer allocator.destroy(provider);
    provider.* = try ai.FauxProvider.init(allocator, .{
        .min_token_size = 16,
        .max_token_size = 16,
        .delay_per_delta_ms = fauxDelayMs(environ),
    });
    errdefer provider.deinit();

    const script = try loadFauxScript(allocator, io, dir, environ);
    defer allocator.free(script);
    const content = [_]ai.AssistantContent{ai.faux.text(script)};
    const message = ai.faux.assistantMessage(&content, .{});
    try provider.setResponses(&.{message});
    try provider.register(registry);
    return provider;
}

fn fauxDelayMs(environ: ?*const std.process.Environ.Map) u32 {
    const env = environ orelse return 0;
    const text = env.get("ZI_FAUX_DELAY_MS") orelse return 0;
    return std.fmt.parseInt(u32, text, 10) catch 0;
}

fn loadFauxScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    const env = environ orelse return allocator.dupe(u8, default_faux_script);
    const path = env.get("ZI_FAUX_SCRIPT") orelse return allocator.dupe(u8, default_faux_script);
    if (path.len == 0) return allocator.dupe(u8, default_faux_script);
    const script = if (std.fs.path.isAbsolute(path))
        try readAbsoluteFileLimited(allocator, io, path)
    else
        try dir.readFileAlloc(io, path, allocator, .limited(max_faux_script_bytes));
    errdefer allocator.free(script);
    if (!std.unicode.utf8ValidateSlice(script)) return error.InvalidUtf8;
    return script;
}

fn readAbsoluteFileLimited(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const file_len = try file.length(io);
    if (file_len > max_faux_script_bytes) return error.StreamTooLong;
    const raw = try allocator.alloc(u8, @intCast(file_len));
    errdefer allocator.free(raw);
    const read_len = try file.readPositionalAll(io, raw, 0);
    if (read_len != raw.len) return error.EndOfStream;
    return raw;
}

test "runtime services owns stable cwd, agent dir, settings manager" {
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

    try std.testing.expectEqualStrings("repo", services.cwd);
    try std.testing.expectEqualStrings("agent", services.agent_dir);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_responses) != null);
    try std.testing.expect(services.provider_registry.get(ai.KnownApi.openai_codex_responses) != null);
}

test "runtime services registers faux provider only when env gate is on" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    try std.testing.expect(services.provider_registry.get(ai.KnownApi.faux) != null);
    try std.testing.expect(ai.getModel(ai.KnownProvider.faux, "faux-default") != null);
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
}
