const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent3/root.zig");
const session_runtime = @import("session/root.zig");
const resources = @import("resources/root.zig");
const tool_def = @import("tools/definition.zig");
const builtin_tools_mod = @import("tools/builtins.zig");
const builtin_util = @import("tools/util.zig");
const system_prompt_mod = @import("system_prompt.zig");
const skills = @import("skills/root.zig");
const auth_storage_mod = @import("auth/storage.zig");
const resolve_config_value = @import("auth/resolve_config_value.zig");
const settings_manager_mod = @import("settings/manager.zig");
const storage = @import("../storage.zig");
const extension_api = @import("extensions/api.zig");
const extension_runner_mod = @import("extensions/runner.zig");
const lua_runtime = @import("extensions/lua_runtime.zig");
const lua_tool_mod = @import("extensions/lua_tool.zig");
const c = lua_runtime.c;

pub const SessionStore = session_runtime.store.SessionStore;
pub const ExtensionRunner = extension_runner_mod.ExtensionRunner;

pub const StreamClosure = struct {
    registry: *ai.provider.Registry,
    auth_storage: ?*auth_storage_mod.AuthStorage,
    api_key: []const u8,
    max_tokens: ?u64,

    pub fn streamFn(
        ctx: ?*anyopaque,
        stream_alloc: std.mem.Allocator,
        model: ai.protocol.Model,
        stream_context: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        callback: ai.provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        const self: *const StreamClosure = @ptrCast(@alignCast(ctx.?));
        const api_str = ai.provider.apiToString(model.api);
        const prov = self.registry.get(api_str) orelse return;
        var arena = std.heap.ArenaAllocator.init(stream_alloc);
        defer arena.deinit();

        var opts = options;
        if (opts.base.api_key == null or opts.base.api_key.?.len == 0) {
            opts.base.api_key = self.resolveApiKey(model);
        }
        opts.base.headers = self.mergeClaimHeaders(model, arena.allocator(), opts.base.headers) catch opts.base.headers;
        if (self.max_tokens) |mt| opts.base.max_tokens = mt;
        prov.streamSimple(stream_alloc, model, stream_context, opts, callback, callback_ctx);
    }

    pub fn resolveApiKey(self: *const StreamClosure, model: ai.protocol.Model) []const u8 {
        const provider_str = ai.json_util.providerToString(model.provider);
        if (self.auth_storage) |auth_storage| {
            if (auth_storage.getApiKey(provider_str)) |key| {
                if (key.len > 0) return key;
            }
        }
        const claim = self.registry.activeClaimRegistrationByName(provider_str) orelse return self.api_key;
        const config = claim.api_key orelse return self.api_key;
        const resolved = resolve_config_value.resolveConfigValue(config) orelse return self.api_key;
        return if (resolved.len > 0) resolved else self.api_key;
    }

    fn mergeClaimHeaders(
        self: *const StreamClosure,
        model: ai.protocol.Model,
        allocator: std.mem.Allocator,
        request_headers: ?[]const ai.protocol.Header,
    ) !?[]const ai.protocol.Header {
        const provider_str = ai.json_util.providerToString(model.provider);
        const claim = self.registry.activeClaimRegistrationByName(provider_str) orelse return request_headers;
        if (claim.headers.len == 0) return request_headers;

        var merged: std.ArrayListUnmanaged(ai.protocol.Header) = .empty;

        for (claim.headers) |header| {
            const resolved_value = resolve_config_value.resolveConfigValue(header.value) orelse continue;
            try merged.append(allocator, .{
                .key = try allocator.dupe(u8, header.key),
                .value = try allocator.dupe(u8, resolved_value),
            });
        }
        if (request_headers) |headers| {
            for (headers) |header| {
                try merged.append(allocator, .{
                    .key = try allocator.dupe(u8, header.key),
                    .value = try allocator.dupe(u8, header.value),
                });
            }
        }

        if (merged.items.len == 0) return null;
        return merged.items;
    }
};

pub const PreparedDeps = struct {
    session_store: SessionStore,
    resource_loader: resources.ResourceLoader,
    stream_closure: *StreamClosure,
    system_prompt: []const u8,
    tools: []const agent_mod.protocol.AgentTool,
    owned_provider_bundle: ?*ai.provider_defaults.Bundle = null,
    builtin_ctx: ?*builtin_util.BuiltinCtx = null,
    extension_runner: ?*ExtensionRunner = null,
    extension_lua_state: ?*lua_runtime.LuaState = null,
};

pub const PrepareOptions = struct {
    api_key: []const u8 = "",
    cwd: []const u8,
    resource_loader: ?resources.ResourceLoader = null,
    system_prompt: ?[]const u8 = null,
    context_files: []const resources.types.AgentsFile = &.{},
    extension_paths: []const []const u8 = &.{},
    max_tokens: ?u64 = 4096,
    tools: ?[]const tool_def.ToolDefinition = null,
    registry: ?*ai.provider.Registry = null,
    auth_storage: ?*auth_storage_mod.AuthStorage = null,
    settings_manager: ?*settings_manager_mod.SettingsManager = null,
    session_store: ?SessionStore = null,
    no_session: bool = false,
    append_system_prompt: ?[]const u8 = null,
    tool_allowlist: ?[]const []const u8 = null,
    extension_generation: extension_runner_mod.Generation = 0,
};

pub fn prepareSessionDeps(
    allocator: std.mem.Allocator,
    options: PrepareOptions,
) !PreparedDeps {
    var session_store = options.session_store orelse if (options.no_session)
        SessionStore.createEphemeral(allocator)
    else
        try SessionStore.createForCwd(allocator, options.cwd);
    errdefer session_store.deinit();

    const resource_loader = options.resource_loader orelse try resources.ResourceLoader.init(allocator, .{
        .cwd = options.cwd,
        .settings_manager = options.settings_manager,
        .system_prompt = options.system_prompt,
        .append_system_prompt = options.append_system_prompt,
        .injected_agents_files = options.context_files,
        .explicit_extension_paths = options.extension_paths,
    });
    errdefer {
        var loader = resource_loader;
        loader.deinit();
    }

    const image_auto_resize = if (options.settings_manager) |settings|
        settings.getImageAutoResize()
    else
        true;

    var builtin_ctx: ?*builtin_util.BuiltinCtx = null;
    const builtin_definitions = options.tools orelse blk: {
        var bundle = builtin_tools_mod.build(allocator, options.cwd, .{
            .image_auto_resize = image_auto_resize,
        }) catch break :blk @as([]const tool_def.ToolDefinition, &.{});
        bundle.ctx.session_id = session_store.sessionId();
        builtin_ctx = bundle.ctx;
        break :blk @as([]const tool_def.ToolDefinition, bundle.definitions);
    };

    var owned_provider_bundle: ?*ai.provider_defaults.Bundle = null;
    const registry: *ai.provider.Registry = options.registry orelse blk: {
        const bundle = try ai.provider_defaults.Bundle.init(allocator);
        owned_provider_bundle = bundle;
        break :blk bundle.registry;
    };
    errdefer if (owned_provider_bundle) |bundle| bundle.deinit();

    const stream_closure = try allocator.create(StreamClosure);
    errdefer allocator.destroy(stream_closure);
    stream_closure.* = .{
        .registry = registry,
        .auth_storage = options.auth_storage,
        .api_key = options.api_key,
        .max_tokens = options.max_tokens,
    };

    var extension_runtime = try buildExtensionRuntime(
        allocator,
        options.cwd,
        resource_loader,
        builtin_definitions,
        options.tools != null,
        options.extension_generation,
    );
    errdefer extension_runtime.deinit(allocator);

    const definitions = if (extension_runtime.runner) |runner|
        runner.tool_registry.items()
    else
        builtin_definitions;

    const filtered = try filterToolDefinitions(allocator, definitions, options.tool_allowlist);
    defer filtered.deinit(allocator);

    const tools = try buildAgentTools(allocator, filtered.items, extension_runtime.runner);
    errdefer allocator.free(tools);

    const system_prompt = try buildSystemPrompt(
        allocator,
        options.cwd,
        resource_loader,
        filtered.items,
    );
    errdefer allocator.free(system_prompt);

    return .{
        .session_store = session_store,
        .resource_loader = resource_loader,
        .stream_closure = stream_closure,
        .system_prompt = system_prompt,
        .tools = tools,
        .owned_provider_bundle = owned_provider_bundle,
        .builtin_ctx = builtin_ctx,
        .extension_runner = extension_runtime.takeRunner(),
        .extension_lua_state = extension_runtime.takeLuaState(),
    };
}

const FilteredDefinitions = struct {
    items: []const tool_def.ToolDefinition,
    owned_slice: bool = false,

    fn deinit(self: FilteredDefinitions, allocator: std.mem.Allocator) void {
        if (self.owned_slice) allocator.free(self.items);
    }
};

fn filterToolDefinitions(
    allocator: std.mem.Allocator,
    definitions: []const tool_def.ToolDefinition,
    allowlist: ?[]const []const u8,
) !FilteredDefinitions {
    const allow = allowlist orelse return .{ .items = definitions };

    const filtered = try allocator.alloc(tool_def.ToolDefinition, definitions.len);
    var count: usize = 0;
    for (definitions) |definition| {
        for (allow) |wanted| {
            const trimmed = std.mem.trim(u8, wanted, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(trimmed, definition.name) or std.ascii.eqlIgnoreCase(trimmed, definition.label)) {
                filtered[count] = definition;
                count += 1;
                break;
            }
        }
    }

    return .{ .items = filtered[0..count], .owned_slice = true };
}

fn buildAgentTools(
    allocator: std.mem.Allocator,
    definitions: []const tool_def.ToolDefinition,
    extension_runner: ?*ExtensionRunner,
) ![]const agent_mod.protocol.AgentTool {
    const tools = try allocator.alloc(agent_mod.protocol.AgentTool, definitions.len);
    var count: usize = 0;
    for (definitions) |definition| {
        const tool = switch (definition.impl) {
            .builtin => tool_def.toAgentTool(definition),
            .lua => if (extension_runner) |runner|
                lua_tool_mod.buildAgentTool(allocator, runner, definition) catch |err| {
                    std.log.scoped(.extensions).warn(
                        "failed to build agent tool for {s}: {s}",
                        .{ definition.name, @errorName(err) },
                    );
                    continue;
                }
            else
                continue,
        };
        tools[count] = tool;
        count += 1;
    }
    return tools[0..count];
}

fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    resource_loader: resources.ResourceLoader,
    definitions: []const tool_def.ToolDefinition,
) ![]const u8 {
    const prompt_inputs = resource_loader.getPromptInputs();
    const tool_names = try toolNameSlice(allocator, definitions);
    defer allocator.free(tool_names);

    const tool_snippets = try collectToolSnippets(allocator, definitions);
    defer allocator.free(tool_snippets);

    const prompt_guidelines = try collectGuidelines(allocator, definitions);
    defer allocator.free(prompt_guidelines);

    const skills_section: ?[]const u8 = if (hasToolNamed(definitions, "read"))
        skills.format.formatSkillsForPrompt(allocator, resource_loader.getSkills().skills) catch null
    else
        null;
    defer if (skills_section) |section| allocator.free(section);

    if (prompt_inputs.system_prompt) |custom| {
        return system_prompt_mod.buildSystemPrompt(allocator, .{
            .custom_prompt = custom,
            .cwd = cwd,
            .context_files = prompt_inputs.agents_files,
            .tool_names = tool_names,
            .tool_snippets = tool_snippets,
            .guidelines = prompt_guidelines,
            .skills_section = skills_section,
            .append_system_prompt = prompt_inputs.append_system_prompt,
        }) catch allocator.dupe(u8, custom);
    }

    return system_prompt_mod.buildSystemPrompt(allocator, .{
        .cwd = cwd,
        .tool_names = tool_names,
        .tool_snippets = tool_snippets,
        .guidelines = prompt_guidelines,
        .skills_section = skills_section,
        .context_files = prompt_inputs.agents_files,
        .append_system_prompt = prompt_inputs.append_system_prompt,
    }) catch allocator.dupe(u8, "You are a helpful coding assistant.");
}

const ExtensionRuntime = struct {
    runner: ?*ExtensionRunner = null,
    lua_state: ?*lua_runtime.LuaState = null,

    fn takeRunner(self: *ExtensionRuntime) ?*ExtensionRunner {
        const runner = self.runner;
        self.runner = null;
        return runner;
    }

    fn takeLuaState(self: *ExtensionRuntime) ?*lua_runtime.LuaState {
        const state = self.lua_state;
        self.lua_state = null;
        return state;
    }

    fn deinit(self: ExtensionRuntime, allocator: std.mem.Allocator) void {
        if (self.runner) |runner| {
            runner.deinit();
            allocator.destroy(runner);
        }
        if (self.lua_state) |state| {
            state.deinit();
            allocator.destroy(state);
        }
    }
};

fn buildExtensionRuntime(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    resource_loader: resources.ResourceLoader,
    builtin_definitions: []const tool_def.ToolDefinition,
    has_custom_tools: bool,
    generation: extension_runner_mod.Generation,
) !ExtensionRuntime {
    var runtime: ExtensionRuntime = .{};

    const state_ptr = allocator.create(lua_runtime.LuaState) catch return runtime;
    errdefer allocator.destroy(state_ptr);
    state_ptr.* = lua_runtime.LuaState.init(allocator) catch return runtime;
    errdefer state_ptr.deinit();

    const runner_ptr = allocator.create(ExtensionRunner) catch return runtime;
    errdefer allocator.destroy(runner_ptr);
    runner_ptr.* = ExtensionRunner.init(allocator, generation);
    runner_ptr.cwd = cwd;
    runner_ptr.builtin_tool_definitions = if (has_custom_tools) &.{} else builtin_definitions;
    runner_ptr.attachLuaState(state_ptr);
    extension_api.installZiTable(state_ptr, runner_ptr);

    // Capture the default Lua package.path before any extension
    // overrides, so we can append it after private + shared roots.
    _ = c.lua_getglobal(state_ptr.L, "package");
    defer c.lua_pop(state_ptr.L, 1);
    if (c.lua_type(state_ptr.L, -1) == c.LUA_TTABLE) {
        _ = c.lua_getfield(state_ptr.L, -1, "path");
        defer c.lua_pop(state_ptr.L, 1);
        if (c.lua_type(state_ptr.L, -1) == c.LUA_TSTRING) {
            var len: usize = 0;
            const ptr = c.lua_tolstring(state_ptr.L, -1, &len);
            runner_ptr.base_package_path = allocator.dupe(u8, ptr[0..len]) catch null;
        }
    }

    // Build shared `lua/` search paths from the canonical ordered root list.
    const roots = resource_loader.getExtensionRoots();
    var lua_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (lua_dirs.items) |d| allocator.free(d);
        lua_dirs.deinit(allocator);
    }
    for (roots) |root| {
        if (root.kind != .runtime_root) continue;
        const lua_dir = std.fs.path.join(allocator, &.{ root.path, "lua" }) catch continue;
        lua_dirs.append(allocator, lua_dir) catch {
            allocator.free(lua_dir);
            continue;
        };
    }
    if (lua_dirs.items.len > 0) {
        var shared_buf: std.ArrayList(u8) = .empty;
        defer shared_buf.deinit(allocator);
        for (lua_dirs.items) |d| {
            if (shared_buf.items.len > 0) shared_buf.append(allocator, ';') catch {};
            shared_buf.writer(allocator).print("{s}/?.lua;{s}/?/init.lua", .{ d, d }) catch {};
        }
        runner_ptr.shared_lua_paths = allocator.dupe(u8, shared_buf.items) catch null;
    }

    // Set the initial package.path = shared + default (no private root yet).
    runner_ptr.setModuleContext(state_ptr, null);

    runner_ptr.bindLuaOwnerThread(std.Thread.getCurrentId());
    const stats = resource_loader.loadExtensionsInto(
        state_ptr,
        runner_ptr,
        if (has_custom_tools) &.{} else builtin_definitions,
    );
    std.log.scoped(.extensions).info(
        "extensions: {d} loaded, {d} failed of {d} discovered",
        .{ stats.loaded, stats.failed, stats.attempted },
    );

    // If custom tools override builtins, register them directly.
    if (has_custom_tools) {
        for (builtin_definitions) |def| {
            var cloned = tool_def.cloneOwned(runner_ptr.allocator, def) catch |err| {
                std.log.scoped(.extensions).warn(
                    "failed to clone custom tool '{s}' for registry: {s}",
                    .{ def.name, @errorName(err) },
                );
                continue;
            };
            const accepted = runner_ptr.tool_registry.register(cloned) catch |err| {
                std.log.scoped(.extensions).warn(
                    "failed to register custom tool '{s}': {s}",
                    .{ def.name, @errorName(err) },
                );
                tool_def.freeOwned(runner_ptr.allocator, &cloned);
                continue;
            };
            if (!accepted) {
                tool_def.freeOwned(runner_ptr.allocator, &cloned);
            }
        }
    }

    runtime.lua_state = state_ptr;
    runtime.runner = runner_ptr;
    return runtime;
}

fn toolNameSlice(
    allocator: std.mem.Allocator,
    definitions: []const tool_def.ToolDefinition,
) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, definitions.len);
    for (definitions, 0..) |definition, index| names[index] = definition.name;
    return names;
}

fn collectToolSnippets(
    allocator: std.mem.Allocator,
    definitions: []const tool_def.ToolDefinition,
) ![]const system_prompt_mod.ToolSnippet {
    var count: usize = 0;
    for (definitions) |definition| {
        if (definition.prompt_snippet != null) count += 1;
    }

    const snippets = try allocator.alloc(system_prompt_mod.ToolSnippet, count);
    var index: usize = 0;
    for (definitions) |definition| {
        const snippet = definition.prompt_snippet orelse continue;
        snippets[index] = .{ .name = definition.name, .snippet = snippet };
        index += 1;
    }
    return snippets;
}

fn hasToolNamed(definitions: []const tool_def.ToolDefinition, wanted: []const u8) bool {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, wanted)) return true;
    }
    return false;
}

fn collectGuidelines(
    allocator: std.mem.Allocator,
    definitions: []const tool_def.ToolDefinition,
) ![]const []const u8 {
    var total: usize = 0;
    for (definitions) |definition| total += definition.prompt_guidelines.len;

    const guidelines = try allocator.alloc([]const u8, total);
    var index: usize = 0;
    for (definitions) |definition| {
        for (definition.prompt_guidelines) |guideline| {
            var duplicate = false;
            for (guidelines[0..index]) |existing| {
                if (std.mem.eql(u8, existing, guideline)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            guidelines[index] = guideline;
            index += 1;
        }
    }

    return guidelines[0..index];
}

const testing = std.testing;

const StreamCaptureProvider = struct {
    allocator: std.mem.Allocator,
    last_base_url: ?[]const u8 = null,
    last_api_key: ?[]const u8 = null,
    last_headers: []const ai.protocol.Header = &.{},

    const vtable: ai.provider.Provider.VTable = .{
        .stream = streamImpl,
        .stream_simple = streamSimpleImpl,
        .get_name = getNameImpl,
        .deinit = deinitImpl,
    };

    fn create(allocator: std.mem.Allocator) !*StreamCaptureProvider {
        const self = try allocator.create(StreamCaptureProvider);
        self.* = .{ .allocator = allocator };
        return self;
    }

    fn provider(self: *StreamCaptureProvider) ai.provider.Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn getSelf(ptr: *anyopaque) *StreamCaptureProvider {
        return @ptrCast(@alignCast(ptr));
    }

    fn clearCaptured(self: *StreamCaptureProvider) void {
        if (self.last_base_url) |value| self.allocator.free(value);
        if (self.last_api_key) |value| self.allocator.free(value);
        for (self.last_headers) |header| {
            self.allocator.free(header.key);
            self.allocator.free(header.value);
        }
        if (self.last_headers.len > 0) self.allocator.free(self.last_headers);
        self.last_base_url = null;
        self.last_api_key = null;
        self.last_headers = &.{};
    }

    fn capture(self: *StreamCaptureProvider, model: ai.protocol.Model, options: ai.protocol.SimpleStreamOptions) void {
        self.clearCaptured();
        self.last_base_url = self.allocator.dupe(u8, model.base_url) catch null;
        if (options.base.api_key) |api_key| {
            self.last_api_key = self.allocator.dupe(u8, api_key) catch null;
        }
        if (options.base.headers) |headers| {
            const owned = self.allocator.alloc(ai.protocol.Header, headers.len) catch return;
            var built: usize = 0;
            for (headers, 0..) |header, i| {
                const key = self.allocator.dupe(u8, header.key) catch {
                    for (owned[0..built]) |captured| {
                        self.allocator.free(captured.key);
                        self.allocator.free(captured.value);
                    }
                    self.allocator.free(owned);
                    return;
                };
                const value = self.allocator.dupe(u8, header.value) catch {
                    self.allocator.free(key);
                    for (owned[0..built]) |captured| {
                        self.allocator.free(captured.key);
                        self.allocator.free(captured.value);
                    }
                    self.allocator.free(owned);
                    return;
                };
                owned[i] = .{ .key = key, .value = value };
                built += 1;
            }
            self.last_headers = owned;
        }
    }

    fn streamImpl(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        model: ai.protocol.Model,
        _: ai.protocol.Context,
        options: ai.protocol.StreamOptions,
        _: ai.provider.EventCallback,
        _: ?*anyopaque,
    ) void {
        const simple: ai.protocol.SimpleStreamOptions = .{ .base = options };
        getSelf(ptr).capture(model, simple);
    }

    fn streamSimpleImpl(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        model: ai.protocol.Model,
        _: ai.protocol.Context,
        options: ai.protocol.SimpleStreamOptions,
        _: ai.provider.EventCallback,
        _: ?*anyopaque,
    ) void {
        getSelf(ptr).capture(model, options);
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "stream-capture";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self = getSelf(ptr);
        self.clearCaptured();
        self.allocator.destroy(self);
    }
};

fn noopProviderEvent(_: ai.protocol.AssistantMessageEvent, _: ?*anyopaque) void {}

test "stream closure resolves claim api_key and layers provider headers before request headers" {
    resolve_config_value.clearCache();
    defer resolve_config_value.clearCache();

    var registry = ai.provider.Registry.init(testing.allocator);
    defer registry.deinit();

    const capture = try StreamCaptureProvider.create(testing.allocator);
    try registry.register("anthropic-messages", capture.provider(), null);
    defer registry.get("anthropic-messages").?.deinit();

    const claim_headers = try testing.allocator.alloc(ai.protocol.Header, 2);
    claim_headers[0] = .{
        .key = try testing.allocator.dupe(u8, "x-provider"),
        .value = try testing.allocator.dupe(u8, "!printf provider-default"),
    };
    claim_headers[1] = .{
        .key = try testing.allocator.dupe(u8, "x-claim"),
        .value = try testing.allocator.dupe(u8, "claim-header"),
    };

    try testing.expect(try registry.registerClaim(.{
        .name = try testing.allocator.dupe(u8, "proxy-auth"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy-auth.example"),
        .api_key = try testing.allocator.dupe(u8, "!printf claim-key"),
        .headers = claim_headers,
        .owner_id = try testing.allocator.dupe(u8, "ext-a"),
        .generation = 1,
    }));

    var closure: StreamClosure = .{
        .registry = &registry,
        .auth_storage = null,
        .api_key = "session-fallback",
        .max_tokens = null,
    };

    const request_headers = [_]ai.protocol.Header{
        .{ .key = "x-provider", .value = "request-override" },
        .{ .key = "x-request", .value = "request-local" },
    };
    const model: ai.protocol.Model = .{
        .id = "proxy-model",
        .name = "Proxy Model",
        .api = .anthropic_messages,
        .provider = .{ .custom = "proxy-auth" },
        .base_url = "https://visible-model.example",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 4096,
        .max_tokens = 2048,
    };

    StreamClosure.streamFn(
        @ptrCast(&closure),
        testing.allocator,
        model,
        .{ .messages = &.{} },
        .{ .base = .{ .headers = &request_headers } },
        &noopProviderEvent,
        null,
    );

    try testing.expectEqualStrings("https://proxy-auth.example", capture.last_base_url.?);
    try testing.expectEqualStrings("claim-key", capture.last_api_key.?);
    try testing.expectEqual(@as(usize, 4), capture.last_headers.len);
    try testing.expectEqualStrings("x-provider", capture.last_headers[0].key);
    try testing.expectEqualStrings("provider-default", capture.last_headers[0].value);
    try testing.expectEqualStrings("x-claim", capture.last_headers[1].key);
    try testing.expectEqualStrings("claim-header", capture.last_headers[1].value);
    try testing.expectEqualStrings("x-provider", capture.last_headers[2].key);
    try testing.expectEqualStrings("request-override", capture.last_headers[2].value);
    try testing.expectEqualStrings("x-request", capture.last_headers[3].key);
    try testing.expectEqualStrings("request-local", capture.last_headers[3].value);
}
