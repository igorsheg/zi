const std = @import("std");
const build_options = @import("build_options");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const auth_mod = @import("auth.zig");
const ExtensionHost = @import("ExtensionHost.zig");
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
    dir: std.Io.Dir,
    openai_provider: *ai.OpenAiResponsesProvider,
    openai_codex_provider: *ai.OpenAiCodexResponsesProvider,
    faux_provider: ?*ai.FauxProvider,
    faux_gate_active: bool,
    extension_host: ?*ExtensionHost = null,
    extension_startup_error_name: ?[]const u8 = null,

    pub const Options = struct {
        cwd: []const u8,
        agent_dir: []const u8,
        dir: std.Io.Dir = .cwd(),
        environ: ?*const std.process.Environ.Map = null,
        task_runtime: *runtime.Runtime,
        extension_load_plan: ?*const ExtensionHost.ExtensionLoadPlan = null,
        node_executable: ?[]const u8 = null,
    };

    pub const ExtensionAvailability = enum {
        disabled,
        active,
        failed,
    };

    pub const ExtensionDiagnostic = union(enum) {
        startup: []const u8,
        host: ExtensionHost.Diagnostic,
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

        var extension_startup_error_name: ?[]const u8 = null;
        const extension_host = if (options.extension_load_plan) |plan| host: {
            if (!plan.enabled()) break :host null;
            const host_ptr = allocator.create(ExtensionHost) catch |err| {
                extension_startup_error_name = @errorName(err);
                break :host null;
            };
            host_ptr.* = ExtensionHost.init(allocator, .{
                .task_runtime = options.task_runtime,
                .cwd = cwd,
                .agent_dir = agent_dir,
                .dir = options.dir,
                .environ = options.environ,
                .node_executable = options.node_executable,
            }, plan) catch |err| {
                allocator.destroy(host_ptr);
                extension_startup_error_name = @errorName(err);
                break :host null;
            };
            bootstrapExtensionHost(host_ptr) catch |err| {
                extension_startup_error_name = @errorName(err);
                host_ptr.requestShutdown(monotonicNowNs(io));
                drainExtensionHost(host_ptr, io);
                host_ptr.deinit();
                allocator.destroy(host_ptr);
                break :host null;
            };
            break :host host_ptr;
        } else null;
        errdefer if (extension_host) |host| {
            host.requestShutdown(monotonicNowNs(io));
            drainExtensionHost(host, io);
            host.deinit();
            allocator.destroy(host);
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
            .dir = options.dir,
            .openai_provider = openai_provider,
            .openai_codex_provider = openai_codex_provider,
            .faux_provider = faux_provider,
            .faux_gate_active = faux_gate_active,
            .extension_host = extension_host,
            .extension_startup_error_name = extension_startup_error_name,
        };
    }

    pub fn extensionHost(self: *RuntimeServices) ?*ExtensionHost {
        return self.extension_host;
    }

    pub fn startExtensionReplacement(
        self: *RuntimeServices,
        load_plan: *ExtensionHost.ExtensionLoadPlan,
        now_ns: u64,
    ) !ExtensionHost.ReplacementHandle {
        const host = self.extension_host orelse return error.HostUnavailable;
        return host.startReplacementOwned(load_plan, now_ns);
    }

    pub fn pollExtensionReplacement(
        self: *const RuntimeServices,
        handle: *const ExtensionHost.ReplacementHandle,
    ) ExtensionHost.ReplacementPoll {
        const host = self.extension_host orelse return .{ .failure = .{
            .failure = .{ .startup = "HostUnavailable" },
            .stderr_tail = &.{},
            .term = null,
        } };
        return host.pollReplacement(handle);
    }

    pub fn deinitExtensionReplacement(
        self: *RuntimeServices,
        handle: *ExtensionHost.ReplacementHandle,
    ) void {
        const host = self.extension_host orelse {
            handle.released = true;
            return;
        };
        host.deinitReplacement(handle);
    }

    pub fn extensionPromptCommands(self: *const RuntimeServices) []const ExtensionHost.PromptCommand {
        const host = self.extension_host orelse return &.{};
        return host.promptCommands();
    }

    pub fn findExtensionPromptCommand(
        self: *const RuntimeServices,
        name: []const u8,
    ) ?*const ExtensionHost.PromptCommand {
        const host = self.extension_host orelse return null;
        return host.findPromptCommand(name);
    }

    pub fn startExtensionPromptCommand(
        self: *RuntimeServices,
        name: []const u8,
        args: []const u8,
        deadline_ns: u64,
    ) !ExtensionHost.PromptCommandHandle {
        const host = self.extension_host orelse return error.HostUnavailable;
        return host.startPromptCommand(name, args, deadline_ns);
    }

    pub fn pollExtensionPromptCommand(
        self: *RuntimeServices,
        handle: *const ExtensionHost.PromptCommandHandle,
    ) ExtensionHost.PromptCommandPoll {
        const host = self.extension_host orelse return .{ .failure = .generation_failed };
        return host.pollPromptCommand(handle);
    }

    pub fn cancelExtensionPromptCommand(
        self: *RuntimeServices,
        handle: *const ExtensionHost.PromptCommandHandle,
    ) void {
        if (self.extension_host) |host| host.cancel(handle);
    }

    pub fn takeExtensionPromptCommand(
        self: *RuntimeServices,
        handle: *const ExtensionHost.PromptCommandHandle,
    ) ![]u8 {
        const host = self.extension_host orelse return error.HostUnavailable;
        return host.takePromptCommand(handle);
    }

    pub fn freeExtensionPrompt(self: *RuntimeServices, prompt: []u8) void {
        self.allocator.free(prompt);
    }

    pub fn deinitExtensionPromptCommand(
        self: *RuntimeServices,
        handle: *ExtensionHost.PromptCommandHandle,
    ) void {
        const host = self.extension_host orelse {
            handle.released = true;
            return;
        };
        host.deinitPromptCommand(handle);
    }

    pub fn extensionAvailability(self: *const RuntimeServices) ExtensionAvailability {
        if (self.extension_host) |host| {
            return if (host.available()) .active else .failed;
        }
        return if (self.extension_startup_error_name == null) .disabled else .failed;
    }

    pub fn extensionDiagnostic(self: *const RuntimeServices) ?ExtensionDiagnostic {
        if (self.extension_startup_error_name) |name| return .{ .startup = name };
        if (self.extension_host) |host| {
            if (host.diagnostic()) |diagnostic| return .{ .host = diagnostic };
        }
        return null;
    }

    pub fn setExtensionWake(self: *RuntimeServices, wake: *runtime.WakeEvent) void {
        if (self.extension_host) |host| host.setWake(wake);
    }

    pub fn clearExtensionWake(self: *RuntimeServices) void {
        if (self.extension_host) |host| host.clearWake();
    }

    pub fn pollExtensionHost(self: *RuntimeServices, now_ns: u64) void {
        if (self.extension_host) |host| host.poll(now_ns);
    }

    pub fn extensionHostDeadline(self: *const RuntimeServices) ?u64 {
        const host = self.extension_host orelse return null;
        return host.nextDeadline();
    }

    pub fn requestExtensionShutdown(self: *RuntimeServices, now_ns: u64) void {
        if (self.extension_host) |host| host.requestShutdown(now_ns);
    }

    pub fn extensionShutdownComplete(self: *const RuntimeServices) bool {
        const host = self.extension_host orelse return true;
        return host.shutdownComplete();
    }

    pub fn deinit(self: *RuntimeServices) void {
        if (self.extension_host) |host| {
            // Frontends drain normal shutdown. This fallback owns early errors
            // before a frontend loop exists, such as failed session bootstrap.
            if (!host.shutdownComplete()) {
                host.requestShutdown(monotonicNowNs(self.io));
                drainExtensionHost(host, self.io);
            }
            host.deinit();
            self.allocator.destroy(host);
        }
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

fn bootstrapExtensionHost(host: *ExtensionHost) !void {
    var wake: runtime.WakeEvent = .init;
    host.setWake(&wake);
    defer host.clearWake();
    var now = monotonicNowNs(host.io);
    try host.start(now);
    while (!host.available() and host.diagnostic() == null) {
        host.poll(now);
        if (host.available() or host.diagnostic() != null) break;
        waitForExtensionProgress(host.io, &wake, now, host.nextDeadline());
        now = monotonicNowNs(host.io);
    }
    if (host.diagnostic() != null) drainExtensionHost(host, host.io);
}

fn drainExtensionHost(host: *ExtensionHost, io: std.Io) void {
    var wake: runtime.WakeEvent = .init;
    host.setWake(&wake);
    defer host.clearWake();
    while (!host.shutdownComplete()) {
        const now = monotonicNowNs(io);
        host.poll(now);
        if (host.shutdownComplete()) break;
        waitForExtensionProgress(io, &wake, now, host.nextDeadline());
    }
}

fn waitForExtensionProgress(
    io: std.Io,
    wake: *runtime.WakeEvent,
    now_ns: u64,
    deadline_ns: ?u64,
) void {
    const wait_ns = if (deadline_ns) |deadline|
        @min(deadline -| now_ns, 100 * std.time.ns_per_ms)
    else
        100 * std.time.ns_per_ms;
    wake.waitTimeout(io, .{ .duration = .{
        .raw = .fromNanoseconds(@intCast(wait_ns)),
        .clock = .awake,
    } }) catch |err| {
        const ignored_wait_error = @errorName(err);
        _ = ignored_wait_error;
    };
    wake.reset();
}

fn monotonicNowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

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
    const message = if (fauxErrorMessage(environ)) |error_message|
        ai.faux.assistantMessage(&.{}, .{
            .stop_reason = .error_,
            .error_message = error_message,
            .operational_failure = .{
                .category = .provider_unavailable,
                .message = error_message,
                .retryable = .no,
            },
        })
    else
        ai.faux.assistantMessage(&content, .{});
    try provider.setResponses(&.{message});
    try provider.register(registry);
    return provider;
}

fn fauxDelayMs(environ: ?*const std.process.Environ.Map) u32 {
    const env = environ orelse return 0;
    const text = env.get("ZI_FAUX_DELAY_MS") orelse return 0;
    return std.fmt.parseInt(u32, text, 10) catch 0;
}

fn fauxErrorMessage(environ: ?*const std.process.Environ.Map) ?[]const u8 {
    const env = environ orelse return null;
    const message = env.get("ZI_FAUX_ERROR_MESSAGE") orelse return null;
    if (message.len == 0 or message.len > ai.OperationalFailure.message_bytes_max) return null;
    if (!std.unicode.utf8ValidateSlice(message)) return null;
    return message;
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
    try std.testing.expectEqual(RuntimeServices.ExtensionAvailability.disabled, services.extensionAvailability());
    try std.testing.expect(services.extensionHost() == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(
        std.testing.io,
        "agent/cache/extension-host",
        .{},
    ));
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

test "runtime services owns an explicitly enabled extension host through drain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const root_path = root_buffer[0..root_len];
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "extension.ts",
        .data =
        \\export default function activate(zi) {
        \\  zi.commands.registerPrompt({
        \\    name: "fixture-review",
        \\    description: "Review a fixture",
        \\    run: ({ args }) => ({ prompt: `Review ${args}` }),
        \\  });
        \\}
        ,
    });
    const extension_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "extension.ts" });
    defer std.testing.allocator.free(extension_path);
    const agent_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "agent" });
    defer std.testing.allocator.free(agent_dir);

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var plan = try ExtensionHost.ExtensionLoadPlan.init(std.testing.allocator, &.{.{
        .canonical_path = extension_path,
        .provenance = .explicit,
    }});
    defer plan.deinit();
    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = root_path,
        .agent_dir = agent_dir,
        .task_runtime = task_runtime,
        .extension_load_plan = &plan,
        .node_executable = build_options.node_executable,
    });
    defer services.deinit();

    try std.testing.expectEqual(RuntimeServices.ExtensionAvailability.active, services.extensionAvailability());
    var wake: runtime.WakeEvent = .init;
    services.setExtensionWake(&wake);
    var now = monotonicNowNs(services.io);
    var ping = try services.extensionHost().?.startPing(now + std.time.ns_per_s);
    while (services.extensionHost().?.pollPing(&ping) == .pending) {
        services.pollExtensionHost(now);
        waitForExtensionProgress(services.io, &wake, now, services.extensionHostDeadline());
        now = monotonicNowNs(services.io);
    }
    try std.testing.expect(services.extensionHost().?.pollPing(&ping) == .success);
    services.extensionHost().?.deinitPing(&ping);
    services.requestExtensionShutdown(now);
    while (!services.extensionShutdownComplete()) {
        services.pollExtensionHost(now);
        waitForExtensionProgress(services.io, &wake, now, services.extensionHostDeadline());
        now = monotonicNowNs(services.io);
    }
    services.clearExtensionWake();
}

test "runtime services retains a typed extension startup diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const root_path = root_buffer[0..root_len];
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "extension.ts",
        .data =
        \\export default function activate(zi) {
        \\  zi.commands.registerPrompt({
        \\    name: "fixture-review",
        \\    description: "Review a fixture",
        \\    run: ({ args }) => ({ prompt: `Review ${args}` }),
        \\  });
        \\}
        ,
    });
    const extension_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "extension.ts" });
    defer std.testing.allocator.free(extension_path);
    const agent_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "agent" });
    defer std.testing.allocator.free(agent_dir);

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var plan = try ExtensionHost.ExtensionLoadPlan.init(std.testing.allocator, &.{.{
        .canonical_path = extension_path,
        .provenance = .explicit,
    }});
    defer plan.deinit();
    var services = try RuntimeServices.init(std.testing.allocator, .{
        .cwd = root_path,
        .agent_dir = agent_dir,
        .task_runtime = task_runtime,
        .extension_load_plan = &plan,
        .node_executable = "/definitely/not/node",
    });
    defer services.deinit();

    try std.testing.expectEqual(RuntimeServices.ExtensionAvailability.failed, services.extensionAvailability());
    const diagnostic = services.extensionDiagnostic() orelse return error.MissingExtensionDiagnostic;
    try std.testing.expect(diagnostic == .startup);
    try std.testing.expectEqualStrings("FileNotFound", diagnostic.startup);
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
