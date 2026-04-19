//! Composition-root factory for AgentSession.
//!
//! This is the canonical bootstrap path used by print/json/interactive
//! modes. `main.zig` resolves mode-specific concerns (auth, settings,
//! model choice), then hands session construction to this module.
//!
//! `createAgentSession(...)` owns the shared bootstrap wiring that
//! should not be duplicated at top-level callsites:
//! - resolve the on-disk session directory
//! - create/open the SessionStore when needed
//! - construct the ResourceLoader as the single owner of loaded
//!   extensions, prompt inputs, skills, and future resource kinds
//! - assemble the provider/tool/extension environment the session runs in
//! - inject prepared deps into AgentSession
//!
//! Keeping this wiring here gives the application one composition root
//! instead of scattered ad hoc setup in `main.zig` and `coding_agent.zig`.

const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent3/root.zig");
const storage = @import("../storage.zig");
const coding_agent = @import("root.zig");
const model_registry_mod = @import("model_registry.zig");
const resources = @import("resources/root.zig");
const tool_def = @import("tools/definition.zig");
const builtin_tools_mod = @import("tools/builtins.zig");
const builtin_util = @import("tools/util.zig");
const system_prompt_mod = @import("system_prompt.zig");
const skills = @import("skills/root.zig");
const auth_storage_mod = @import("auth/storage.zig");
const settings_manager_mod = @import("settings/manager.zig");
const extension_api = @import("extensions/api.zig");
const extension_runner_mod = @import("extensions/runner.zig");
const lua_runtime = @import("extensions/lua_runtime.zig");
const lua_tool_mod = @import("extensions/lua_tool.zig");

pub const AgentSession = coding_agent.AgentSession;
pub const SessionStore = coding_agent.SessionStore;
pub const PreparedSessionDeps = AgentSession.PreparedDeps;
const ExtensionRunner = extension_runner_mod.ExtensionRunner;

pub const CreateOptions = struct {
    model: ai.protocol.Model,
    /// Static API key fallback. Used only when no `auth_storage` is
    /// attached or its lookup returns empty.
    api_key: []const u8 = "",
    cwd: []const u8,
    /// ResourceLoader bootstrap input: custom system-prompt source.
    system_prompt: ?[]const u8 = null,
    /// ResourceLoader bootstrap input: injected AGENTS/CLAUDE-style files.
    context_files: []const resources.types.AgentsFile = &.{},
    max_tokens: ?u64 = 4096,
    tools: ?[]const tool_def.ToolDefinition = null,
    registry: ?*ai.provider.Registry = null,
    event_handler: ?AgentSession.EventHandler = null,
    auth_storage: ?*auth_storage_mod.AuthStorage = null,
    settings_manager: ?*settings_manager_mod.SettingsManager = null,
    model_registry: ?*model_registry_mod.ModelRegistry = null,
    initial_messages: []const agent_mod.protocol.AgentMessage = &.{},
    thinking_level: ?agent_mod.protocol.ThinkingLevel = null,
    session_store: ?SessionStore = null,
    no_session: bool = false,
    /// ResourceLoader bootstrap input: append-system-prompt source.
    append_system_prompt: ?[]const u8 = null,
    tool_allowlist: ?[]const []const u8 = null,
};

/// Resolve the on-disk directory for a session's files before the
/// SessionStore is created. Caller owns the returned slice.
pub fn resolveSessionDir(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    return storage.getSessionDirForCwd(allocator, cwd, null);
}

/// Build a fully-initialized `AgentSession` from resolved external
/// dependencies (model, api key, registry, etc.). The caller still
/// owns auth/settings/model resolution because those have mode-specific
/// error handling (print mode exits, interactive mode surfaces a prompt).
pub fn createAgentSession(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) !AgentSession {
    const prepared = try prepareSessionDeps(allocator, options);
    return AgentSession.init(allocator, .{
        .model = options.model,
        .prepared = prepared,
        .event_handler = options.event_handler,
        .auth_storage = options.auth_storage,
        .settings_manager = options.settings_manager,
        .model_registry = options.model_registry,
        .initial_messages = options.initial_messages,
        .thinking_level = options.thinking_level,
    });
}

fn prepareSessionDeps(
    allocator: std.mem.Allocator,
    options: CreateOptions,
) !PreparedSessionDeps {
    var session_store = options.session_store orelse if (options.no_session)
        SessionStore.createEphemeral(allocator)
    else
        try SessionStore.createForCwd(allocator, options.cwd);
    errdefer session_store.deinit();

    const resource_loader = try resources.ResourceLoader.init(allocator, .{
        .cwd = options.cwd,
        .settings_manager = options.settings_manager,
        .system_prompt = options.system_prompt,
        .append_system_prompt = options.append_system_prompt,
        .injected_agents_files = options.context_files,
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

    const stream_closure = try allocator.create(AgentSession.StreamClosure);
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

    return .{
        .items = filtered[0..count],
        .owned_slice = true,
    };
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
) !ExtensionRuntime {
    var runtime: ExtensionRuntime = .{};

    const state_ptr = allocator.create(lua_runtime.LuaState) catch return runtime;
    errdefer allocator.destroy(state_ptr);
    state_ptr.* = lua_runtime.LuaState.init(allocator) catch return runtime;
    errdefer state_ptr.deinit();

    const runner_ptr = allocator.create(ExtensionRunner) catch return runtime;
    errdefer allocator.destroy(runner_ptr);
    runner_ptr.* = ExtensionRunner.init(allocator, 0);
    runner_ptr.cwd = cwd;
    runner_ptr.attachLuaState(state_ptr);
    extension_api.installZiTable(state_ptr, runner_ptr);

    const agent_dir = storage.getAgentDir(allocator, null) catch null;
    defer if (agent_dir) |dir| allocator.free(dir);
    const project_dir = storage.getProjectDir(allocator, cwd) catch null;
    defer if (project_dir) |dir| allocator.free(dir);
    const agent_ext = if (agent_dir) |dir| std.fs.path.join(allocator, &.{ dir, "extensions" }) catch null else null;
    defer if (agent_ext) |dir| allocator.free(dir);
    const project_ext = if (project_dir) |dir| std.fs.path.join(allocator, &.{ dir, "extensions" }) catch null else null;
    defer if (project_ext) |dir| allocator.free(dir);

    var dirs_buf: [2][]const u8 = .{ "", "" };
    var dirs_count: usize = 0;
    if (project_ext) |dir| {
        dirs_buf[dirs_count] = dir;
        dirs_count += 1;
    }
    if (agent_ext) |dir| {
        dirs_buf[dirs_count] = dir;
        dirs_count += 1;
    }
    state_ptr.setPackagePath(dirs_buf[0..dirs_count]) catch {};

    runner_ptr.bindLuaOwnerThread(std.Thread.getCurrentId());
    const loaded_extensions = resource_loader.getExtensions();
    if (loaded_extensions.extensions.len > 0) {
        const stats = resource_loader.loadExtensionsInto(state_ptr, runner_ptr);
        std.log.scoped(.extensions).info(
            "extensions: {d} loaded, {d} failed of {d} discovered",
            .{ stats.loaded, stats.failed, stats.attempted },
        );
    }

    registerBaseToolDefinitions(runner_ptr, builtin_definitions);
    runtime.lua_state = state_ptr;
    runtime.runner = runner_ptr;
    return runtime;
}

fn registerBaseToolDefinitions(
    runner: *ExtensionRunner,
    definitions: []const tool_def.ToolDefinition,
) void {
    for (definitions) |definition| {
        registerBaseToolDefinition(runner, definition);
    }
}

fn registerBaseToolDefinition(runner: *ExtensionRunner, definition: tool_def.ToolDefinition) void {
    var cloned = tool_def.cloneOwned(runner.allocator, definition) catch |err| {
        std.log.scoped(.extensions).warn(
            "failed to clone base tool '{s}' for registry: {s}",
            .{ definition.name, @errorName(err) },
        );
        return;
    };

    const accepted = runner.tool_registry.register(cloned) catch |err| {
        std.log.scoped(.extensions).warn(
            "failed to register base tool '{s}': {s}",
            .{ definition.name, @errorName(err) },
        );
        tool_def.freeOwned(runner.allocator, &cloned);
        return;
    };
    if (!accepted) {
        const winner = runner.tool_registry.get(definition.name) orelse unreachable;
        std.log.scoped(.extensions).info(
            "base tool '{s}' from {s} ignored; already registered by {s}:{s}",
            .{ definition.name, definition.source.kind, winner.source.kind, winner.source.id },
        );
        tool_def.freeOwned(runner.allocator, &cloned);
    }
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
