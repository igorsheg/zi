const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const session_runtime = @import("session/root.zig");
const session_core = @import("../session/root.zig");
const ResourceLoader = @import("resources/loader.zig").ResourceLoader;
const resource_types = @import("resources/types.zig");
const tool_def = @import("tools/definition.zig");
const builtin_tools_mod = @import("tools/builtins.zig");
const builtin_util = @import("tools/util.zig");
const system_prompt_mod = @import("system_prompt.zig");
const skills = @import("skills/root.zig");
const auth_storage_mod = @import("auth/storage.zig");
const resolve_config_value = @import("auth/resolve_config_value.zig");
const settings_manager_mod = @import("settings/manager.zig");
const storage = @import("../storage.zig");
const extension_api = @import("extensions/api_v3.zig");
const extension_runner_mod = @import("extensions/runner.zig");
const lua_runtime = @import("extensions/lua_runtime.zig");
const builtin_lua = @import("extensions/builtin_lua.zig");
const lua_tool_mod = @import("extensions/lua_tool.zig");
const event_bridge = @import("extensions/event_bridge.zig");
const c = lua_runtime.c;

pub const SessionStore = session_runtime.store.SessionStore;
pub const ExtensionRunner = extension_runner_mod.ExtensionRunner;
pub const ExtensionRunnerRef = extension_runner_mod.ExtensionRunnerRef;

pub const StreamClosure = struct {
    registry: *ai.provider.Registry,
    auth_storage: ?*auth_storage_mod.AuthStorage,
    extension_runner_ref: *ExtensionRunnerRef,
    api_key: []const u8,
    max_tokens: ?u64,
    io: std.Io,

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
        const provider_str = ai.json_util.providerToString(model.provider);
        const prov = self.registry.getForModel(api_str, provider_str) orelse return;
        var arena = std.heap.ArenaAllocator.init(stream_alloc);
        defer arena.deinit();

        var opts = options;
        opts.base.io = self.io;
        if (opts.base.api_key == null or opts.base.api_key.?.len == 0) {
            opts.base.api_key = self.resolveApiKey(arena.allocator(), model);
        }
        opts.base.headers = self.mergeClaimHeaders(model, arena.allocator(), opts.base.headers) catch opts.base.headers;
        if (self.max_tokens) |mt| opts.base.max_tokens = mt;
        prov.streamSimple(stream_alloc, model, stream_context, opts, callback, callback_ctx);
    }

    pub fn resolveApiKey(self: *const StreamClosure, allocator: std.mem.Allocator, model: ai.protocol.Model) []const u8 {
        const provider_str = ai.json_util.providerToString(model.provider);
        const claim = self.registry.activeClaimRegistrationByName(provider_str);
        if (self.auth_storage) |auth_storage| {
            if (auth_storage.getApiKey(provider_str)) |key| {
                if (key.len > 0) {
                    if (claim) |active_claim| {
                        if (active_claim.oauth_get_api_key_ref != null) {
                            if (auth_storage.get(provider_str)) |credential| switch (credential) {
                                .oauth => |oauth_credential| {
                                    if (self.extension_runner_ref.current) |runner| {
                                        if (runner.dispatchOAuthGetApiKey(provider_str, oauth_credential, allocator) catch null) |derived_key| {
                                            if (derived_key.len > 0) return derived_key;
                                        }
                                    }
                                },
                                else => {},
                            };
                        }
                    }
                    return key;
                }
            }
        }
        const active_claim = claim orelse return self.api_key;
        const config = active_claim.api_key orelse return self.api_key;
        const resolved = resolve_config_value.resolveConfigValue(config) orelse return self.api_key;
        return if (resolved.len > 0) resolved else self.api_key;
    }

    pub fn mergeClaimHeaders(
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
    resource_loader: ResourceLoader,
    stream_closure: *StreamClosure,
    system_prompt: []const u8,
    tools: []const agent_mod.protocol.AgentTool,
    owned_provider_bundle: ?*ai.provider_defaults.Bundle = null,
    builtin_ctx: ?*builtin_util.BuiltinCtx = null,
    extension_runner: ?*ExtensionRunner = null,
    extension_runner_ref: *ExtensionRunnerRef,
    extension_lua_state: ?*lua_runtime.LuaState = null,
};

pub const ExtensionRuntimeBundle = struct {
    system_prompt: []const u8,
    tools: []const agent_mod.protocol.AgentTool,
    builtin_ctx: ?*builtin_util.BuiltinCtx = null,
    extension_runner: ?*ExtensionRunner = null,
    extension_lua_state: ?*lua_runtime.LuaState = null,

    pub fn deinit(self: *ExtensionRuntimeBundle, allocator: std.mem.Allocator) void {
        if (self.extension_runner) |runner| {
            runner.deinit();
            allocator.destroy(runner);
            self.extension_runner = null;
        }
        if (self.extension_lua_state) |state| {
            state.deinit();
            allocator.destroy(state);
            self.extension_lua_state = null;
        }
        if (self.system_prompt.len > 0) {
            allocator.free(self.system_prompt);
            self.system_prompt = "";
        }
        if (self.tools.len > 0) {
            allocator.free(self.tools);
            self.tools = &.{};
        }
        if (self.builtin_ctx) |ctx| {
            ctx.deinit(allocator);
            allocator.destroy(ctx);
            self.builtin_ctx = null;
        }
    }
};

pub const ReloadExtensionOptions = struct {
    model: ai.protocol.Model,
    resource_loader: ResourceLoader,
    io: std.Io = std.Options.debug_io,
    settings_manager: ?*settings_manager_mod.SettingsManager = null,
    tools: ?[]const tool_def.ToolDefinition = null,
    tool_allowlist: ?[]const []const u8 = null,
    session_id: []const u8 = "",
    extension_generation: extension_runner_mod.Generation,
};

const BuiltinDefinitions = struct {
    definitions: []const tool_def.ToolDefinition,
    ctx: ?*builtin_util.BuiltinCtx = null,
    owns_definitions: bool = false,

    fn takeCtx(self: *BuiltinDefinitions) ?*builtin_util.BuiltinCtx {
        const ctx = self.ctx;
        self.ctx = null;
        return ctx;
    }

    fn deinitDefinitionsOnly(self: *BuiltinDefinitions, allocator: std.mem.Allocator) void {
        if (self.owns_definitions and self.definitions.len > 0) {
            allocator.free(@constCast(self.definitions));
            self.definitions = &.{};
            self.owns_definitions = false;
        }
    }

    fn deinit(self: *BuiltinDefinitions, allocator: std.mem.Allocator) void {
        self.deinitDefinitionsOnly(allocator);
        if (self.ctx) |ctx| {
            ctx.deinit(allocator);
            allocator.destroy(ctx);
            self.ctx = null;
        }
    }
};

const BuiltinOptions = struct {
    cwd: []const u8,
    io: std.Io,
    settings_manager: ?*settings_manager_mod.SettingsManager = null,
    tools: ?[]const tool_def.ToolDefinition = null,
    session_id: []const u8 = "",
};

fn buildBuiltinDefinitions(allocator: std.mem.Allocator, options: BuiltinOptions) !BuiltinDefinitions {
    if (options.tools) |tools| return .{ .definitions = tools };

    const image_auto_resize = if (options.settings_manager) |settings|
        settings.getImageAutoResize()
    else
        true;
    var bundle = try builtin_tools_mod.build(allocator, options.cwd, .{
        .io = options.io,
        .image_auto_resize = image_auto_resize,
    });
    bundle.ctx.session_id = options.session_id;
    return .{
        .definitions = bundle.definitions,
        .ctx = bundle.ctx,
        .owns_definitions = true,
    };
}

pub const PrepareOptions = struct {
    model: ai.protocol.Model,
    api_key: []const u8 = "",
    cwd: []const u8,
    io: std.Io = std.Options.debug_io,
    resource_loader: ?ResourceLoader = null,
    system_prompt: ?[]const u8 = null,
    context_files: []const resource_types.AgentsFile = &.{},
    extension_paths: []const []const u8 = &.{},
    agent_dir_override: ?[]const u8 = null,
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
        try SessionStore.createForCwd(allocator, options.cwd, options.agent_dir_override);
    errdefer session_store.deinit();

    const resource_loader = options.resource_loader orelse try ResourceLoader.init(allocator, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
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

    var builtins = try buildBuiltinDefinitions(allocator, .{
        .cwd = options.cwd,
        .io = options.io,
        .settings_manager = options.settings_manager,
        .tools = options.tools,
        .session_id = session_store.sessionId(),
    });
    errdefer builtins.deinit(allocator);
    defer builtins.deinitDefinitionsOnly(allocator);

    var owned_provider_bundle: ?*ai.provider_defaults.Bundle = null;
    const registry: *ai.provider.Registry = options.registry orelse blk: {
        const bundle = try ai.provider_defaults.Bundle.init(allocator);
        owned_provider_bundle = bundle;
        break :blk bundle.registry;
    };
    errdefer if (owned_provider_bundle) |bundle| bundle.deinit();

    const extension_runner_ref = try allocator.create(ExtensionRunnerRef);
    errdefer allocator.destroy(extension_runner_ref);
    extension_runner_ref.* = .{};

    const stream_closure = try allocator.create(StreamClosure);
    errdefer allocator.destroy(stream_closure);
    stream_closure.* = .{
        .registry = registry,
        .auth_storage = options.auth_storage,
        .extension_runner_ref = extension_runner_ref,
        .api_key = options.api_key,
        .max_tokens = options.max_tokens,
        .io = options.io,
    };

    var extension_runtime = try buildExtensionRuntime(
        allocator,
        resource_loader,
        options.io,
        builtins.definitions,
        options.tools != null,
        options.extension_generation,
    );
    errdefer extension_runtime.deinit(allocator);

    _ = extension_runner_ref.swap(extension_runtime.runner);
    errdefer _ = extension_runner_ref.swap(null);

    const definitions = if (extension_runtime.runner) |runner|
        runner.tool_registry.items()
    else
        builtins.definitions;

    const filtered = try filterToolDefinitions(allocator, definitions, .{
        .allowlist = options.tool_allowlist,
        .model_policy = ToolSelectionPolicy.forModel(options.model),
    });
    defer filtered.deinit(allocator);

    const tools = try buildAgentTools(allocator, filtered.items, extension_runtime.runner);
    errdefer allocator.free(tools);

    const base_system_prompt = try buildSystemPrompt(
        allocator,
        resource_loader,
        filtered.items,
    );
    errdefer allocator.free(base_system_prompt);

    const system_prompt = try customizeSystemPrompt(allocator, resource_loader, filtered.items, extension_runtime.runner, base_system_prompt);
    errdefer allocator.free(system_prompt);
    allocator.free(base_system_prompt);

    return .{
        .session_store = session_store,
        .resource_loader = resource_loader,
        .stream_closure = stream_closure,
        .system_prompt = system_prompt,
        .tools = tools,
        .owned_provider_bundle = owned_provider_bundle,
        .builtin_ctx = builtins.takeCtx(),
        .extension_runner = extension_runtime.takeRunner(),
        .extension_runner_ref = extension_runner_ref,
        .extension_lua_state = extension_runtime.takeLuaState(),
    };
}

pub fn prepareExtensionRuntimeBundle(
    allocator: std.mem.Allocator,
    options: ReloadExtensionOptions,
) !ExtensionRuntimeBundle {
    var builtins = try buildBuiltinDefinitions(allocator, .{
        .cwd = options.resource_loader.cwd,
        .io = options.io,
        .settings_manager = options.settings_manager,
        .tools = options.tools,
        .session_id = options.session_id,
    });
    errdefer builtins.deinit(allocator);
    defer builtins.deinitDefinitionsOnly(allocator);

    var extension_runtime = try buildExtensionRuntime(
        allocator,
        options.resource_loader,
        options.io,
        builtins.definitions,
        options.tools != null,
        options.extension_generation,
    );
    errdefer extension_runtime.deinit(allocator);

    const definitions = if (extension_runtime.runner) |runner|
        runner.tool_registry.items()
    else
        builtins.definitions;

    const filtered = try filterToolDefinitions(allocator, definitions, .{
        .allowlist = options.tool_allowlist,
        .model_policy = ToolSelectionPolicy.forModel(options.model),
    });
    defer filtered.deinit(allocator);

    const tools = try buildAgentTools(allocator, filtered.items, extension_runtime.runner);
    errdefer allocator.free(tools);

    const base_system_prompt = try buildSystemPrompt(
        allocator,
        options.resource_loader,
        filtered.items,
    );
    errdefer allocator.free(base_system_prompt);

    const system_prompt = try customizeSystemPrompt(allocator, options.resource_loader, filtered.items, extension_runtime.runner, base_system_prompt);
    errdefer allocator.free(system_prompt);
    allocator.free(base_system_prompt);

    return .{
        .system_prompt = system_prompt,
        .tools = tools,
        .builtin_ctx = builtins.takeCtx(),
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

const ToolDefinitionFilter = struct {
    allowlist: ?[]const []const u8 = null,
    model_policy: ToolSelectionPolicy = .{},
};

const ToolSelectionPolicy = struct {
    prefer_patch: bool = false,

    fn forModel(model: ai.protocol.Model) ToolSelectionPolicy {
        return .{ .prefer_patch = modelPrefersPatch(model) };
    }
};

const EditSurface = enum { edit, patch };

fn modelPrefersPatch(model: ai.protocol.Model) bool {
    return switch (model.api) {
        .openai_responses,
        .openai_codex_responses,
        .azure_openai_responses,
        => true,
        else => switch (model.provider) {
            .openai,
            .openai_codex,
            => true,
            else => modelIdPrefersPatch(model.id),
        },
    };
}

fn modelIdPrefersPatch(id: []const u8) bool {
    return startsWithIgnoreCase(id, "gpt-5") or containsIgnoreCase(id, "codex");
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn filterToolDefinitions(
    allocator: std.mem.Allocator,
    definitions: []const tool_def.ToolDefinition,
    filter: ToolDefinitionFilter,
) !FilteredDefinitions {
    const edit_surface = selectEditSurface(definitions, filter);
    const filtered = try allocator.alloc(tool_def.ToolDefinition, definitions.len);
    var count: usize = 0;
    for (definitions) |definition| {
        if (filter.allowlist) |allow| {
            if (!definitionAllowed(definition, allow)) continue;
        }
        if (std.mem.eql(u8, definition.name, "edit") and edit_surface != .edit) continue;
        if (std.mem.eql(u8, definition.name, "patch") and edit_surface != .patch) continue;
        filtered[count] = definition;
        count += 1;
    }

    if (count == definitions.len) {
        allocator.free(filtered);
        return .{ .items = definitions };
    }
    return .{ .items = filtered[0..count], .owned_slice = true };
}

fn selectEditSurface(definitions: []const tool_def.ToolDefinition, filter: ToolDefinitionFilter) EditSurface {
    var has_allowed_edit = false;
    var has_allowed_patch = false;
    for (definitions) |definition| {
        if (!std.mem.eql(u8, definition.name, "edit") and !std.mem.eql(u8, definition.name, "patch")) continue;
        if (filter.allowlist) |allow| {
            if (!definitionAllowed(definition, allow)) continue;
        }
        if (std.mem.eql(u8, definition.name, "edit")) has_allowed_edit = true;
        if (std.mem.eql(u8, definition.name, "patch")) has_allowed_patch = true;
    }
    if (filter.model_policy.prefer_patch and has_allowed_patch) return .patch;
    return if (has_allowed_edit) .edit else .patch;
}

fn definitionAllowed(definition: tool_def.ToolDefinition, allow: []const []const u8) bool {
    for (allow) |wanted| {
        const trimmed = std.mem.trim(u8, wanted, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(trimmed, definition.name) or std.ascii.eqlIgnoreCase(trimmed, definition.label)) return true;
    }
    return false;
}

pub fn buildAgentTools(
    allocator: std.mem.Allocator,
    definitions: []const tool_def.ToolDefinition,
    extension_runner: ?*ExtensionRunner,
) ![]const agent_mod.protocol.AgentTool {
    const tools = try allocator.alloc(agent_mod.protocol.AgentTool, definitions.len);
    var count: usize = 0;
    for (definitions) |*definition| {
        const tool = switch (definition.impl) {
            .builtin => tool_def.toAgentTool(definition),
            .lua => if (extension_runner) |runner|
                lua_tool_mod.buildAgentTool(allocator, runner, definition.*) catch |err| {
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

fn customizeSystemPrompt(
    allocator: std.mem.Allocator,
    resource_loader: ResourceLoader,
    definitions: []const tool_def.ToolDefinition,
    runner: ?*ExtensionRunner,
    base_system_prompt: []const u8,
) ![]const u8 {
    const extension_runner = runner orelse return try allocator.dupe(u8, base_system_prompt);
    const tool_names = try toolNameSlice(allocator, definitions);
    defer allocator.free(tool_names);
    const prompt_inputs = resource_loader.getPromptInputs();
    var result = try event_bridge.dispatchBeforeAgentStart(extension_runner, base_system_prompt, .{
        .cwd = resource_loader.cwd,
        .selected_tools = tool_names,
        .skills = resource_loader.getSkills().skills,
        .append_system_prompt = prompt_inputs.append_system_prompt,
    }, allocator);
    const prompt = result.system_prompt;
    result.system_prompt = "";
    result.deinit(allocator);
    return prompt;
}

pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    resource_loader: ResourceLoader,
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
            .cwd = resource_loader.cwd,
            .context_files = prompt_inputs.agents_files,
            .tool_names = tool_names,
            .tool_snippets = tool_snippets,
            .guidelines = prompt_guidelines,
            .skills_section = skills_section,
            .append_system_prompt = prompt_inputs.append_system_prompt,
        }) catch allocator.dupe(u8, custom);
    }

    return system_prompt_mod.buildSystemPrompt(allocator, .{
        .cwd = resource_loader.cwd,
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
    resource_loader: ResourceLoader,
    io: std.Io,
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
    runner_ptr.io = io;
    runner_ptr.cwd = resource_loader.cwd;
    runner_ptr.builtin_tool_definitions = if (has_custom_tools) &.{} else builtin_definitions;
    runner_ptr.attachLuaState(state_ptr);
    extension_api.install(state_ptr, runner_ptr);
    try builtin_lua.install(state_ptr);

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
            shared_buf.print(allocator, "{s}/?.lua;{s}/?/init.lua", .{ d, d }) catch {};
        }
        runner_ptr.shared_lua_paths = allocator.dupe(u8, shared_buf.items) catch null;
    }

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

test "system prompt is built from ResourceLoader-owned inputs" {
    const allocator = testing.allocator;

    var cwd_tmp = testing.tmpDir(.{});
    defer cwd_tmp.cleanup();
    const cwd = try cwd_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);

    var agent_tmp = testing.tmpDir(.{});
    defer agent_tmp.cleanup();
    const agent_dir = try agent_tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(agent_dir);

    const context_files = [_]resource_types.AgentsFile{.{
        .path = "AGENTS.md",
        .content = "project guidance from loader",
    }};
    var resource_loader = try ResourceLoader.init(allocator, .{
        .cwd = cwd,
        .agent_dir_override = agent_dir,
        .system_prompt = "custom prompt from loader",
        .append_system_prompt = "append prompt from loader",
        .injected_agents_files = &context_files,
    });
    defer resource_loader.deinit();

    const prompt = try buildSystemPrompt(allocator, resource_loader, &.{});
    defer allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "custom prompt from loader") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "append prompt from loader") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "project guidance from loader") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, cwd) != null);
}

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

test "stream closure derives request api key from oauth.getApiKey when the active claim provides one" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = ExtensionRunner.init(testing.allocator, 12);
    defer runner.deinit();
    runner.attachLuaState(&state);
    runner.bindLuaOwnerThread(std.Thread.getCurrentId());

    try state.doString(
        \\function oauth_get_api_key(credentials)
        \\  return credentials.access .. "-derived"
        \\end
    , "session_bootstrap_oauth_get_api_key");
    _ = c.lua_getglobal(state.L, "oauth_get_api_key");
    const handler_ref = c.luaL_ref(state.L, c.LUA_REGISTRYINDEX);

    var registry = ai.provider.Registry.init(testing.allocator);
    defer registry.deinit();

    const capture = try StreamCaptureProvider.create(testing.allocator);
    defer capture.provider().deinit();
    try registry.register("anthropic-messages", capture.provider(), null);

    try testing.expect(try registry.registerClaim(.{
        .name = try testing.allocator.dupe(u8, "proxy-oauth-key"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy-auth.example"),
        .oauth_enabled = true,
        .oauth_get_api_key_ref = handler_ref,
        .owner_id = try testing.allocator.dupe(u8, "ext-a"),
        .generation = runner.generation,
    }));

    const Hooks = struct {
        fn getModel(_: *anyopaque) agent_mod.protocol.Model {
            return .{
                .id = "test-model",
                .name = "Test Model",
                .api = .{ .custom = "test-api" },
                .provider = .{ .custom = "test-provider" },
                .base_url = "",
                .reasoning = false,
                .input = &.{.text},
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
                .context_window = 1024,
                .max_tokens = 1024,
            };
        }

        fn isIdle(_: *anyopaque) bool {
            return true;
        }

        fn abort(_: *anyopaque) void {}

        fn hasPendingMessages(_: *anyopaque) bool {
            return false;
        }

        fn getContextUsage(_: *anyopaque) ?session_core.context_usage.ContextUsage {
            return .{ .tokens = 64, .context_window = 1024, .percent = 6.25 };
        }

        fn getSystemPrompt(_: *anyopaque) []const u8 {
            return "system";
        }

        fn getBindingInfo(_: *anyopaque) extension_runner_mod.ExtensionBindingInfo {
            return .{
                .workspace_id = "/workspace",
                .session_id = "session-123",
                .session_file = "/workspace/.zi/sessions/session-123.jsonl",
            };
        }
    };

    try runner.bindRuntime(.{
        .session = undefined,
        .ui = null,
        .command_actions = null,
        .get_model = &Hooks.getModel,
        .is_idle = &Hooks.isIdle,
        .abort = &Hooks.abort,
        .has_pending_messages = &Hooks.hasPendingMessages,
        .shutdown = null,
        .context_usage = &Hooks.getContextUsage,
        .system_prompt = &Hooks.getSystemPrompt,
        .get_binding_info = &Hooks.getBindingInfo,
    }, &registry);

    var auth = try auth_storage_mod.AuthStorage.inMemory(testing.allocator, null);
    defer auth.deinit();
    auth.set("proxy-oauth-key", .{ .oauth = .{
        .refresh = "refresh-token",
        .access = "access-token",
        .expires = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() + 60_000,
        .extras = .{},
    } });

    var runner_ref: ExtensionRunnerRef = .{ .current = &runner };
    var closure: StreamClosure = .{
        .registry = &registry,
        .auth_storage = &auth,
        .extension_runner_ref = &runner_ref,
        .api_key = "session-fallback",
        .max_tokens = null,
        .io = std.Options.debug_io,
    };

    const model: ai.protocol.Model = .{
        .id = "proxy-model",
        .name = "Proxy Model",
        .api = .anthropic_messages,
        .provider = .{ .custom = "proxy-oauth-key" },
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
        .{ .base = .{} },
        &noopProviderEvent,
        null,
    );

    try testing.expectEqualStrings("access-token-derived", capture.last_api_key.?);

    runner_ref.current = null;
    capture.clearCaptured();
    StreamClosure.streamFn(
        @ptrCast(&closure),
        testing.allocator,
        model,
        .{ .messages = &.{} },
        .{ .base = .{} },
        &noopProviderEvent,
        null,
    );

    try testing.expectEqualStrings("access-token", capture.last_api_key.?);
}

test "stream closure resolves claim api_key and layers provider headers before request headers" {
    resolve_config_value.clearCache();
    defer resolve_config_value.clearCache();

    var registry = ai.provider.Registry.init(testing.allocator);
    defer registry.deinit();

    const capture = try StreamCaptureProvider.create(testing.allocator);
    defer capture.provider().deinit();
    try registry.register("anthropic-messages", capture.provider(), null);

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

    var runner_ref: ExtensionRunnerRef = .{};
    var closure: StreamClosure = .{
        .registry = &registry,
        .auth_storage = null,
        .extension_runner_ref = &runner_ref,
        .api_key = "session-fallback",
        .max_tokens = null,
        .io = std.Options.debug_io,
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

fn dummyToolExecute(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: agent_mod.protocol.Token,
    _: ?agent_mod.protocol.AgentToolUpdateCallback,
    _: ?*anyopaque,
) agent_mod.protocol.AgentToolExecution {
    _ = allocator;
    return .{ .ready = .{ .content = &.{}, .is_error = false } };
}

fn testToolDefinition(name: []const u8) tool_def.ToolDefinition {
    return .{
        .name = name,
        .label = name,
        .description = name,
        .parameters = .null,
        .impl = .{ .builtin = .{ .execute = dummyToolExecute } },
        .source = .{ .kind = "builtin", .id = name },
    };
}

fn testModel(api_value: ai.protocol.Api, provider_value: ai.protocol.Provider, id: []const u8) ai.protocol.Model {
    return .{
        .id = id,
        .name = id,
        .api = api_value,
        .provider = provider_value,
        .base_url = "",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 1024,
    };
}

fn hasTool(definitions: []const tool_def.ToolDefinition, name: []const u8) bool {
    for (definitions) |definition| if (std.mem.eql(u8, definition.name, name)) return true;
    return false;
}

test "tool policy exposes patch instead of edit for OpenAI responses" {
    const defs = [_]tool_def.ToolDefinition{ testToolDefinition("read"), testToolDefinition("edit"), testToolDefinition("patch") };
    const filtered = try filterToolDefinitions(testing.allocator, &defs, .{ .model_policy = ToolSelectionPolicy.forModel(testModel(.openai_responses, .openai, "gpt-5")) });
    defer filtered.deinit(testing.allocator);
    try testing.expect(hasTool(filtered.items, "read"));
    try testing.expect(!hasTool(filtered.items, "edit"));
    try testing.expect(hasTool(filtered.items, "patch"));
}

test "tool policy exposes edit instead of patch for non OpenAI models" {
    const defs = [_]tool_def.ToolDefinition{ testToolDefinition("read"), testToolDefinition("edit"), testToolDefinition("patch") };
    const filtered = try filterToolDefinitions(testing.allocator, &defs, .{ .model_policy = ToolSelectionPolicy.forModel(testModel(.anthropic_messages, .anthropic, "claude")) });
    defer filtered.deinit(testing.allocator);
    try testing.expect(hasTool(filtered.items, "read"));
    try testing.expect(hasTool(filtered.items, "edit"));
    try testing.expect(!hasTool(filtered.items, "patch"));
}

test "tool policy falls back to edit when OpenAI patch is unavailable" {
    const defs = [_]tool_def.ToolDefinition{ testToolDefinition("read"), testToolDefinition("edit") };
    const filtered = try filterToolDefinitions(testing.allocator, &defs, .{ .model_policy = ToolSelectionPolicy.forModel(testModel(.openai_responses, .openai, "gpt-5")) });
    defer filtered.deinit(testing.allocator);
    try testing.expect(hasTool(filtered.items, "read"));
    try testing.expect(hasTool(filtered.items, "edit"));
    try testing.expect(!hasTool(filtered.items, "patch"));
}

test "tool policy composes allowlist before model surface selection" {
    const defs = [_]tool_def.ToolDefinition{ testToolDefinition("read"), testToolDefinition("edit"), testToolDefinition("patch") };
    const allow = [_][]const u8{ "read", "edit", "patch" };
    const filtered = try filterToolDefinitions(testing.allocator, &defs, .{
        .allowlist = &allow,
        .model_policy = ToolSelectionPolicy.forModel(testModel(.openai_responses, .openai, "gpt-5")),
    });
    defer filtered.deinit(testing.allocator);
    try testing.expect(hasTool(filtered.items, "read"));
    try testing.expect(!hasTool(filtered.items, "edit"));
    try testing.expect(hasTool(filtered.items, "patch"));
}
