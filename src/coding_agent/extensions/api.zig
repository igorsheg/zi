//! `zi.*` Lua API surface — host functions exposed to extensions.
//!
//! Each function in this file is a C function (`callconv(.c)`)
//! registered into the Lua state's globals as a field of a single
//! `zi` table. Extensions call them like ordinary Lua functions:
//!
//! ```lua
//! return function(zi)
//!   zi.register_tool({ name = "...", ... })
//! end
//! ```
//!
//! The `ExtensionRunner` pointer travels into each C function via a
//! light-userdata upvalue captured at install time
//! (`installZiTable`). C functions read it back through
//! `lua_upvalueindex(1)`. This sidesteps Lua globals entirely — two
//! `ExtensionRunner`s sharing one binary would still each have their
//! own `zi` table bound to their own runner.
//!
//! Ownership rules (see `docs/extensions.md`):
//!
//!   1. Every string we read from Lua is duped via the runner's
//!      allocator BEFORE the Lua stack unwinds. Lua's GC must not
//!      see a slice that zig still holds.
//!
//!   2. Tool parameter schemas are deep-cloned through
//!      `lua_runtime.luaValueToJson` into runner-allocator memory.
//!      The original Lua table can be garbage-collected the moment
//!      this function returns.
//!
//!   3. The `execute` Lua function is captured via `luaL_ref` so the
//!      Lua GC can't reap the closure between registration and the
//!      first invocation. The ref is stored in `ToolDefinition.impl.lua`
//!      as a raw `c_int` and released when the runner closes its
//!      Lua state at deinit (closing the state collects every ref).
//!
//! Error model: failures inside a C function call `luaL_error`,
//! which longjmps back to the Lua caller. Lua-side this surfaces as
//! a normal `error()` and can be caught with `pcall`. We use it for
//! validation failures (missing required field, wrong type, etc.).
//! For "tool already registered" we DO NOT error — first-wins is a
//! silent drop with a diagnostic log entry, matching the spec.

const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const system_api = @import("system_api.zig");
const job_api = @import("job_api.zig");
const json_api = @import("json_api.zig");
const spawn_api = @import("spawn_api.zig");
const provider_api = @import("provider_api.zig");
const command_api = @import("command_api.zig");
const keybinding_api = @import("keybinding_api.zig");
const event_api = @import("event_api.zig");
const tool_api = @import("tool_api.zig");
const tool_registry = @import("registries/tool_registry.zig");
const event_registry = @import("registries/event_registry.zig");
const command_registry = @import("registries/command_registry.zig");
const tool_def = @import("../tools/definition.zig");
const agent_protocol = @import("../../agent/types.zig");
const spawn_mod = @import("../../spawn/spawn.zig");
const spawn_types = @import("../../spawn/types.zig");
const session_core = @import("../../session/root.zig");
const ai = @import("../../ai/root.zig");
const oauth_mod = @import("../auth/oauth.zig");
const keys_mod = @import("../../tui/terminal/keys.zig");

const c = lua_runtime.c;
const log = std.log.scoped(.zi_api);

/// Install the `zi` table as a Lua global, populated with every host
/// C function. Each cfunction captures `runner` as its single
/// upvalue.
///
/// Idempotent within one Lua state — calling twice replaces the
/// global with a fresh table. Used by D3's runtime construction and
/// by tests that build a state inline.
pub fn installZiTable(state: *lua_runtime.LuaState, runner: *runner_mod.ExtensionRunner) void {
    const L = state.L;
    c.lua_createtable(L, 0, 11);

    state.pushCClosureWithUserdata(tool_api.ziRegisterTool, runner);
    c.lua_setfield(L, -2, "register_tool");

    state.pushCClosureWithUserdata(command_api.ziRegisterCommand, runner);
    c.lua_setfield(L, -2, "register_command");

    state.pushCClosureWithUserdata(keybinding_api.ziRegisterKeybinding, runner);
    c.lua_setfield(L, -2, "register_keybinding");

    state.pushCClosureWithUserdata(provider_api.ziRegisterProvider, runner);
    c.lua_setfield(L, -2, "register_provider");

    state.pushCClosureWithUserdata(provider_api.ziUnregisterProvider, runner);
    c.lua_setfield(L, -2, "unregister_provider");

    state.pushCClosureWithUserdata(ziRegisterBuiltinTools, runner);
    c.lua_setfield(L, -2, "__register_builtin_tools");

    state.pushCClosureWithUserdata(event_api.ziOn, runner);
    c.lua_setfield(L, -2, "on");

    state.pushCClosureWithUserdata(spawn_api.ziSpawn, runner);
    c.lua_setfield(L, -2, "spawn");

    state.pushCClosureWithUserdata(system_api.ziSystem, runner);
    c.lua_setfield(L, -2, "system");

    job_api.install(state, runner);
    c.lua_setfield(L, -2, "job");

    json_api.install(state, runner);
    c.lua_setfield(L, -2, "json");

    c.lua_setglobal(L, "zi");
}

fn ziRegisterBuiltinTools(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    const source = runner.currentLoadSource() orelse return luaError(L, "builtin bridge: missing load context");
    if (!std.mem.eql(u8, source.kind, "builtin")) {
        return luaError(L, "builtin bridge: builtin load context required");
    }

    for (runner.builtin_tool_definitions) |definition| {
        var cloned = tool_def.cloneOwned(runner.allocator, definition) catch {
            return luaError(L, "builtin bridge: failed to clone builtin tool");
        };
        errdefer tool_def.freeOwned(runner.allocator, &cloned);
        cloned.source = currentRegistrationSource(runner);

        const accepted = runner.tool_registry.register(cloned) catch {
            tool_def.freeOwned(runner.allocator, &cloned);
            return luaError(L, "builtin bridge: registry insert failed");
        };
        if (!accepted) {
            tool_def.freeOwned(runner.allocator, &cloned);
        }
    }

    c.lua_pushboolean(L, 1);
    return 1;
}

fn pushLiteralField(L: *c.lua_State, field: [:0]const u8, value: [:0]const u8) void {
    _ = c.lua_pushstring(L, value.ptr);
    c.lua_setfield(L, -2, field.ptr);
}

fn pushStringField(L: *c.lua_State, field: [:0]const u8, value: []const u8) void {
    _ = c.lua_pushlstring(L, value.ptr, value.len);
    c.lua_setfield(L, -2, field.ptr);
}

pub const TrampolineCtx = spawn_api.TrampolineCtx;
pub const eventTrampoline = spawn_api.eventTrampoline;
pub const pushToolResultAsSpawnResult = spawn_api.pushToolResultAsSpawnResult;
const pushSpawnResult = spawn_api.pushSpawnResult;
const parseEventKind = event_api.parseEventKind;

fn lstring(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return ptr[0..len];
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ud.?));
}

fn currentRegistrationSource(runner: *const runner_mod.ExtensionRunner) tool_registry.RegistrationSource {
    const source = runner.currentLoadSource() orelse return .{ .kind = "lua", .id = "lua" };
    return .{ .kind = source.kind, .id = source.path, .provenance = source.provenance };
}

fn currentEventProvenance(runner: *const runner_mod.ExtensionRunner) ?@import("../resources/types.zig").ExtensionProvenance {
    const source = runner.currentLoadSource() orelse return null;
    return source.provenance;
}

fn currentEventSourceId(runner: *const runner_mod.ExtensionRunner) []const u8 {
    const source = runner.currentLoadSource() orelse return "lua";
    return source.path;
}

/// Push an error message onto the Lua stack and longjmp out of the
/// C function. Returns `c_int` so callers can `return luaError(...)`.
/// `lua_error` does not return — the cast is to satisfy the type
/// checker for the unreachable code path.
fn luaError(L: *c.lua_State, msg: [:0]const u8) c_int {
    _ = c.lua_pushstring(L, msg.ptr);
    _ = c.lua_error(L);
    return 0;
}

fn luaErrorFmt(L: *c.lua_State, comptime fmt: []const u8, args: anytype) c_int {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "lua error";
    _ = c.lua_pushstring(L, msg.ptr);
    _ = c.lua_error(L);
    return 0;
}

const testing = std.testing;

const ApiTestHost = struct {
    state: lua_runtime.LuaState,
    runner: runner_mod.ExtensionRunner,

    fn init(allocator: std.mem.Allocator, generation: runner_mod.Generation) !ApiTestHost {
        return .{
            .state = try lua_runtime.LuaState.init(allocator),
            .runner = runner_mod.ExtensionRunner.init(allocator, generation),
        };
    }

    fn deinit(self: *ApiTestHost) void {
        self.runner.deinit();
        self.state.deinit();
    }

    fn installZi(self: *ApiTestHost) void {
        installZiTable(&self.state, &self.runner);
    }
};

fn expectLuaRuntimeError(state: *lua_runtime.LuaState, source: []const u8, chunk_name: [:0]const u8) !void {
    try testing.expectError(error.LuaRuntime, state.doString(source, chunk_name));
}

fn testBindGetModel(_: *anyopaque) agent_protocol.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = .anthropic_messages,
        .provider = .anthropic,
        .base_url = "https://baseline.example",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 1024,
    };
}

fn testBindIsIdle(_: *anyopaque) bool {
    return true;
}

fn testBindAbort(_: *anyopaque) void {}

fn testBindHasPendingMessages(_: *anyopaque) bool {
    return false;
}

fn testBindGetContextUsage(_: *anyopaque) ?session_core.context_usage.ContextUsage {
    return null;
}

fn testBindGetSystemPrompt(_: *anyopaque) []const u8 {
    return "system";
}

fn testBindGetBindingInfo(_: *anyopaque) runner_mod.ExtensionBindingInfo {
    return .{
        .workspace_id = "/workspace",
        .session_id = "session-123",
        .session_file = "/workspace/.zi/sessions/session-123.jsonl",
    };
}

fn testToolProjectionChanged(session_ptr: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(session_ptr));
    count.* += 1;
}

fn testProviderProvenance() @import("../resources/types.zig").ExtensionProvenance {
    return .{
        .runtime_root_id = "root-123",
        .extension_id = "ext-123",
        .state_owner_id = "state-123",
        .root_kind = .runtime_root,
    };
}

fn testProviderLoadSource() runner_mod.ExtensionLoadSource {
    return .{
        .kind = "project",
        .id = "ext-123",
        .path = "/workspace/extensions/ext.lua",
        .provenance = testProviderProvenance(),
    };
}

test "zi.register_provider queues models metadata before bind and keeps live routing behavior" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 7);
    defer runner.deinit();

    installZiTable(&state, &runner);

    runner.beginLoadContext(testProviderLoadSource());

    try state.doString(
        \\assert(zi.register_provider("queued", {
        \\  api = "anthropic-messages",
        \\  base_url = "https://queued.example",
        \\  api_key = "QUEUED_PROXY_API_KEY",
        \\  headers = { ["x-provider"] = "queued-provider" },
        \\  models = {
        \\    {
        \\      id = "claude-sonnet-4-20250514",
        \\      name = "Claude 4 Sonnet (queued)",
        \\      reasoning = true,
        \\      input = { "text", "image" },
        \\      cost = { input = 3, output = 15, cache_read = 0.3, cache_write = 3.75 },
        \\      context_window = 200000,
        \\      max_tokens = 16384,
        \\      headers = { ["x-model"] = "queued" },
        \\      compat = { supports_store = true }
        \\    }
        \\  }
        \\}) == true)
    , "provider_prebind");

    try testing.expectEqual(@as(usize, 1), runner.provider_queue.count());
    switch (runner.provider_queue.pending.items[0]) {
        .register => |claim| {
            try testing.expectEqualStrings("QUEUED_PROXY_API_KEY", claim.api_key.?);
            try testing.expectEqual(@as(usize, 1), claim.headers.len);
            try testing.expectEqualStrings("x-provider", claim.headers[0].key);
            try testing.expectEqualStrings("queued-provider", claim.headers[0].value);
            try testing.expectEqual(@as(usize, 1), claim.models.len);
            try testing.expectEqualStrings("claude-sonnet-4-20250514", claim.models[0].id);
            try testing.expectEqualStrings("Claude 4 Sonnet (queued)", claim.models[0].name);
            try testing.expectEqual(@as(usize, 2), claim.models[0].input.len);
            try testing.expectEqual(@as(usize, 1), claim.models[0].headers.len);
            try testing.expectEqualStrings("x-model", claim.models[0].headers[0].key);
            try testing.expectEqualStrings("queued", claim.models[0].headers[0].value);
            try testing.expect(claim.models[0].compat != null);
            try testing.expectEqual(true, claim.models[0].compat.?.object.get("supports_store").?.bool);
        },
        else => return error.ExpectedQueuedProviderRegistration,
    }
    runner.endLoadContext();

    var baseline = ai.faux.FauxProvider.init(testing.allocator);
    defer baseline.deinit();
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try provider_registry.register("anthropic-messages", baseline.provider(), null);

    try runner.bindRuntime(.{
        .session = undefined,
        .ui = null,
        .command_actions = null,
        .get_model = &testBindGetModel,
        .is_idle = &testBindIsIdle,
        .abort = &testBindAbort,
        .has_pending_messages = &testBindHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testBindGetContextUsage,
        .get_system_prompt = &testBindGetSystemPrompt,
        .get_binding_info = &testBindGetBindingInfo,
    }, &provider_registry);

    try testing.expectEqualStrings("queued", provider_registry.get("anthropic-messages").?.getName());
    try testing.expectEqual(@as(usize, 1), provider_registry.activeClaimCount());
    const queued_claim = provider_registry.activeClaimRegistrationAt(0);
    try testing.expectEqualStrings("queued", queued_claim.name);
    try testing.expectEqualStrings("QUEUED_PROXY_API_KEY", queued_claim.api_key.?);
    try testing.expectEqual(@as(usize, 1), queued_claim.headers.len);
    try testing.expectEqualStrings("x-provider", queued_claim.headers[0].key);
    try testing.expectEqualStrings("queued-provider", queued_claim.headers[0].value);
    try testing.expectEqual(@as(usize, 1), queued_claim.models.len);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", queued_claim.models[0].id);

    runner.beginExecutionContext(runner.sourceForProvenance(testProviderProvenance()));
    defer runner.endExecutionContext();

    try state.doString(
        \\assert(zi.register_provider("live", {
        \\  api = "anthropic-messages",
        \\  base_url = "https://live.example",
        \\  models = {
        \\    {
        \\      id = "claude-opus-4-6",
        \\      name = "Claude 4.6 Opus (live)",
        \\      api = "openai-responses",
        \\      reasoning = false,
        \\      input = { "text" },
        \\      cost = { input = 15, output = 75, cache_read = 1.5, cache_write = 18.75 },
        \\      context_window = 200000,
        \\      max_tokens = 32000
        \\    }
        \\  }
        \\}) == true)
    , "provider_live_register");

    try testing.expectEqualStrings("live", provider_registry.get("anthropic-messages").?.getName());
    try testing.expectEqual(@as(usize, 2), provider_registry.activeClaimCount());
    const live_claim = provider_registry.activeClaimRegistrationAt(1);
    try testing.expectEqualStrings("live", live_claim.name);
    try testing.expectEqual(@as(usize, 1), live_claim.models.len);
    try testing.expectEqualStrings("openai-responses", live_claim.models[0].api.?);

    try state.doString(
        \\assert(zi.unregister_provider("live") == true)
    , "provider_live_unregister");

    try testing.expectEqualStrings("queued", provider_registry.get("anthropic-messages").?.getName());
    try testing.expectEqual(@as(usize, 1), provider_registry.activeClaimCount());
}

test "zi.register_provider retains oauth callback refs and still rejects deferred oauth semantics" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 7);
    defer runner.deinit();

    installZiTable(&state, &runner);

    runner.beginLoadContext(testProviderLoadSource());
    defer runner.endLoadContext();

    try state.doString(
        \\assert(zi.register_provider("oauth-claim", {
        \\  api = "anthropic-messages",
        \\  base_url = "https://proxy.example",
        \\  oauth = { name = "Corp Claude", login = function(callbacks)
        \\    callbacks.onProgress("opening browser")
        \\    callbacks.onAuth({ url = "https://example.com/oauth" })
        \\    return { access = "access-token", refresh = "refresh-token", expires = 1234 }
        \\  end, refresh_token = function(credentials)
        \\    return { access = credentials.access .. "-next", refresh = credentials.refresh .. "-next", expires = credentials.expires + 1 }
        \\  end, getApiKey = function(credentials)
        \\    return credentials.access
        \\  end },
        \\  models = {
        \\    {
        \\      id = "claude-sonnet-4-20250514",
        \\      name = "Corp Claude Sonnet",
        \\      reasoning = true,
        \\      input = { "text", "image" },
        \\      cost = { input = 0, output = 0, cache_read = 0, cache_write = 0 },
        \\      context_window = 200000,
        \\      max_tokens = 16384,
        \\    }
        \\  },
        \\}) == true)
    , "provider_oauth_minimal_metadata");

    try state.doString(
        \\assert(zi.register_provider("oauth-claim-unnamed", {
        \\  api = "anthropic-messages",
        \\  base_url = "https://proxy-2.example",
        \\  oauth = {},
        \\  models = {
        \\    {
        \\      id = "claude-opus-4-6",
        \\      name = "Unnamed OAuth Claim",
        \\      reasoning = true,
        \\      input = { "text", "image" },
        \\      cost = { input = 0, output = 0, cache_read = 0, cache_write = 0 },
        \\      context_window = 200000,
        \\      max_tokens = 32000,
        \\    }
        \\  },
        \\}) == true)
    , "provider_oauth_minimal_metadata_unnamed");

    try testing.expectEqual(@as(usize, 2), runner.provider_queue.count());
    switch (runner.provider_queue.pending.items[0]) {
        .register => |claim| {
            try testing.expect(claim.oauth_enabled);
            try testing.expectEqualStrings("Corp Claude", claim.oauth_name.?);
            try testing.expect(claim.oauth_login_ref != null);
            try testing.expect(claim.oauth_refresh_token_ref != null);
            try testing.expect(claim.oauth_get_api_key_ref != null);
        },
        else => return error.ExpectedQueuedProviderRegistration,
    }
    switch (runner.provider_queue.pending.items[1]) {
        .register => |claim| {
            try testing.expect(claim.oauth_enabled);
            try testing.expect(claim.oauth_name == null);
        },
        else => return error.ExpectedQueuedProviderRegistration,
    }
    const invalid_oauth_specs = .{
        .{
            "provider_oauth_modify_models_reject",
            \\return zi.register_provider("broken", {
            \\  api = "anthropic-messages",
            \\  base_url = "https://proxy.example",
            \\  oauth = { modifyModels = function() end },
            \\})
        },
        .{
            "provider_oauth_requires_models_reject",
            \\return zi.register_provider("broken", {
            \\  api = "anthropic-messages",
            \\  base_url = "https://proxy.example",
            \\  oauth = {},
            \\})
        },
        .{
            "provider_oauth_template_reject",
            \\return zi.register_provider("broken", {
            \\  api = "openai-responses",
            \\  base_url = "https://proxy.example",
            \\  oauth = {},
            \\  models = {
            \\    {
            \\      id = "gpt-4.1",
            \\      name = "Broken",
            \\      reasoning = false,
            \\      input = { "text" },
            \\      cost = { input = 0, output = 0, cache_read = 0, cache_write = 0 },
            \\      context_window = 128000,
            \\      max_tokens = 4096,
            \\    }
            \\  },
            \\})
        },
    };

    inline for (invalid_oauth_specs) |spec| {
        try expectLuaRuntimeError(&state, spec[1], spec[0]);
    }
    try testing.expectEqual(@as(usize, 2), runner.provider_queue.count());

    const invalid_oauth_shape_specs = .{
        .{
            "provider_oauth_refresh_token_non_function_reject",
            \\return zi.register_provider("broken", {
            \\  api = "anthropic-messages",
            \\  base_url = "https://proxy.example",
            \\  oauth = { refresh_token = "nope" },
            \\})
        },
        .{
            "provider_oauth_refresh_token_camel_non_function_reject",
            \\return zi.register_provider("broken", {
            \\  api = "anthropic-messages",
            \\  base_url = "https://proxy.example",
            \\  oauth = { refreshToken = "nope" },
            \\})
        },
        .{
            "provider_oauth_get_api_key_non_function_reject",
            \\return zi.register_provider("broken", {
            \\  api = "anthropic-messages",
            \\  base_url = "https://proxy.example",
            \\  oauth = { getApiKey = "nope" },
            \\})
        },
    };

    inline for (invalid_oauth_shape_specs) |spec| {
        try expectLuaRuntimeError(&state, spec[1], spec[0]);
    }
}

test "zi.register_provider rejects deferred provider fields instead of silently dropping them" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 7);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\for _, spec in ipairs({
        \\  { field = "auth_header", value = "true" },
        \\  { field = "stream_simple", value = "function() end" },
        \\  { field = "streamSimple", value = "function() end" },
        \\}) do
        \\  local ok, err = pcall(function()
        \\    local chunk = string.format([[
        \\      return zi.register_provider("deferred", {
        \\        api = "anthropic-messages",
        \\        base_url = "https://proxy.example",
        \\        %s = %s,
        \\      })
        \\    ]], spec.field, spec.value)
        \\    assert(load(chunk))()
        \\  end)
        \\  assert(not ok, "expected error for " .. spec.field)
        \\  assert(string.find(err, spec.field) ~= nil, tostring(err))
        \\end
    , "provider_reject_deferred_fields");

    try testing.expectEqual(@as(usize, 0), runner.provider_queue.count());
}

test "zi.register_provider infers built-in override api and restores the baseline" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 7);
    defer runner.deinit();

    installZiTable(&state, &runner);

    runner.beginLoadContext(testProviderLoadSource());
    try state.doString(
        \\assert(zi.register_provider("anthropic", {
        \\  base_url = "https://queued.example",
        \\}) == true)
    , "builtin_provider_override_prebind");
    runner.endLoadContext();

    try testing.expectEqual(@as(usize, 1), runner.provider_queue.count());
    switch (runner.provider_queue.pending.items[0]) {
        .register => |claim| {
            try testing.expectEqualStrings("anthropic", claim.name);
            try testing.expectEqualStrings("anthropic-messages", claim.api);
            try testing.expectEqualStrings("https://queued.example", claim.base_url);
            try testing.expectEqual(@as(usize, 0), claim.models.len);
        },
        else => return error.ExpectedQueuedProviderRegistration,
    }

    var baseline = ai.faux.FauxProvider.init(testing.allocator);
    defer baseline.deinit();
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try provider_registry.register("anthropic-messages", baseline.provider(), null);

    try runner.bindRuntime(.{
        .session = undefined,
        .ui = null,
        .command_actions = null,
        .get_model = &testBindGetModel,
        .is_idle = &testBindIsIdle,
        .abort = &testBindAbort,
        .has_pending_messages = &testBindHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testBindGetContextUsage,
        .get_system_prompt = &testBindGetSystemPrompt,
        .get_binding_info = &testBindGetBindingInfo,
    }, &provider_registry);

    const queued_claim = provider_registry.activeClaimRegistrationByName("anthropic") orelse return error.ExpectedQueuedProviderRegistration;
    try testing.expectEqualStrings("anthropic-messages", queued_claim.api);
    try testing.expectEqualStrings("https://queued.example", queued_claim.base_url);
    try testing.expectEqual(@as(usize, 0), queued_claim.models.len);
    try testing.expectEqualStrings("anthropic", provider_registry.get("anthropic-messages").?.getName());

    runner.beginExecutionContext(runner.sourceForProvenance(testProviderProvenance()));
    defer runner.endExecutionContext();

    try state.doString(
        \\assert(zi.register_provider("anthropic", {
        \\  api = "anthropic-messages",
        \\  base_url = "https://live.example",
        \\  headers = { ["x-provider"] = "anthropic" },
        \\}) == true)
    , "builtin_provider_override_live");

    const active_claim = provider_registry.activeClaimRegistrationByName("anthropic") orelse return error.ExpectedQueuedProviderRegistration;
    try testing.expectEqualStrings("anthropic-messages", active_claim.api);
    try testing.expectEqualStrings("https://queued.example", active_claim.base_url);
    try testing.expectEqual(@as(usize, 0), active_claim.headers.len);

    try state.doString(
        \\assert(zi.unregister_provider("anthropic") == true)
    , "builtin_provider_override_unregister");

    const restored_claim = provider_registry.activeClaimRegistrationByName("anthropic") orelse return error.ExpectedQueuedProviderRegistration;
    try testing.expectEqualStrings("https://live.example", restored_claim.base_url);
    try testing.expectEqual(@as(usize, 1), restored_claim.headers.len);
    try testing.expectEqualStrings("x-provider", restored_claim.headers[0].key);
    try testing.expectEqualStrings("anthropic", restored_claim.headers[0].value);
    try testing.expectEqualStrings("anthropic", provider_registry.get("anthropic-messages").?.getName());
}

test "zi.register_provider rejects unsupported built-in override extras" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 7);
    defer runner.deinit();

    installZiTable(&state, &runner);

    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.register_provider("openai", {
        \\    api = "anthropic-messages",
        \\    base_url = "https://proxy.example",
        \\  })
        \\end)
        \\assert(not ok)
        \\assert(string.find(err, "field 'api'") ~= nil, tostring(err))
    , "builtin_provider_override_reject_api_mismatch");

    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.register_provider("openai", {
        \\    base_url = "https://proxy.example",
        \\    models = {
        \\      {
        \\        id = "gpt-5",
        \\        name = "GPT-5",
        \\        reasoning = true,
        \\        input = { "text" },
        \\        cost = { input = 0, output = 0, cache_read = 0, cache_write = 0 },
        \\        context_window = 200000,
        \\        max_tokens = 16384,
        \\      }
        \\    },
        \\  })
        \\end)
        \\assert(not ok)
        \\assert(string.find(err, "field 'models'") ~= nil, tostring(err))
    , "builtin_provider_override_reject_models");

    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.register_provider("anthropic", {
        \\    base_url = "https://proxy.example",
        \\    oauth = {},
        \\  })
        \\end)
        \\assert(not ok)
        \\assert(string.find(err, "field 'oauth'") ~= nil, tostring(err))
    , "builtin_provider_override_reject_oauth");

    try testing.expectEqual(@as(usize, 0), runner.provider_queue.count());
}

test "zi.register_tool registers a Lua-defined tool end-to-end" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;
    const runner = &host.runner;

    try state.doString(
        \\zi.register_tool({
        \\  name = "finder",
        \\  label = "Finder",
        \\  description = "search the codebase",
        \\  prompt_snippet = "use finder for multi-step search",
        \\  prompt_guidelines = { "prefer over chained grep", "parallelize independent queries" },
        \\  parameters = {
        \\    type = "object",
        \\    properties = {
        \\      query = { type = "string", description = "the search query" },
        \\    },
        \\    required = { "query" },
        \\  },
        \\  execute = function(params, ctx) return { content = {} } end,
        \\})
    , "test_register");

    try testing.expectEqual(@as(usize, 1), runner.tool_registry.count());

    const tool = runner.tool_registry.get("finder").?;
    try testing.expectEqualStrings("finder", tool.name);
    try testing.expectEqualStrings("Finder", tool.label);
    try testing.expectEqualStrings("search the codebase", tool.description);
    try testing.expectEqualStrings("use finder for multi-step search", tool.prompt_snippet.?);
    try testing.expectEqual(@as(usize, 2), tool.prompt_guidelines.len);
    try testing.expectEqualStrings("prefer over chained grep", tool.prompt_guidelines[0]);

    _ = c.lua_gc(state.L, c.LUA_GCCOLLECT, @as(c_int, 0));

    try testing.expect(tool.parameters == .object);
    const props = tool.parameters.object.get("properties").?.object;
    const query_schema = props.get("query").?.object;
    try testing.expectEqualStrings("string", query_schema.get("type").?.string);
    try testing.expectEqualStrings("the search query", query_schema.get("description").?.string);

    const required = tool.parameters.object.get("required").?.array;
    try testing.expectEqual(@as(usize, 1), required.items.len);
    try testing.expectEqualStrings("query", required.items[0].string);

    try testing.expect(tool.impl == .lua);
    try testing.expect(tool.impl.lua != c.LUA_REFNIL);
}

test "zi.register_tool after bind refreshes visible tool projection for accepted claims only" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();

    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 0);
    defer runner.deinit();

    var baseline = ai.faux.FauxProvider.init(testing.allocator);
    defer baseline.deinit();
    var provider_registry = ai.provider.Registry.init(testing.allocator);
    defer provider_registry.deinit();
    try provider_registry.register("anthropic-messages", baseline.provider(), null);

    var projection_changes: usize = 0;
    try runner.bindRuntime(.{
        .session = @ptrCast(&projection_changes),
        .ui = null,
        .command_actions = null,
        .get_model = &testBindGetModel,
        .is_idle = &testBindIsIdle,
        .abort = &testBindAbort,
        .has_pending_messages = &testBindHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &testBindGetContextUsage,
        .get_system_prompt = &testBindGetSystemPrompt,
        .get_binding_info = &testBindGetBindingInfo,
        .tool_projection_changed = &testToolProjectionChanged,
    }, &provider_registry);

    installZiTable(&state, &runner);

    try state.doString(
        \\local first = zi.register_tool({
        \\  name = "runtime_echo",
        \\  description = "runtime registration",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\})
        \\local duplicate = zi.register_tool({
        \\  name = "runtime_echo",
        \\  description = "duplicate registration",
        \\  parameters = { type = "object" },
        \\  execute = function() end,
        \\})
        \\assert(first == true, "runtime registration should be accepted")
        \\assert(duplicate == false, "duplicate runtime registration should fail open")
    , "test_runtime_register_tool");

    try testing.expectEqual(@as(usize, 1), runner.tool_registry.count());
    try testing.expectEqual(@as(usize, 1), projection_changes);
    try testing.expectEqualStrings("runtime registration", runner.tool_registry.get("runtime_echo").?.description);
}

test "zi.on subscribes a Lua handler to the right event chain" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;
    const runner = &host.runner;

    try state.doString(
        \\zi.on("message_end", function(event, ctx) end)
        \\zi.on("tool_call", function(event, ctx) end)
        \\zi.on("tool_call", function(event, ctx) end)
    , "test_subscribe");

    try testing.expectEqual(@as(usize, 3), runner.event_registry.count());

    const tc = runner.event_registry.handlers(.tool_call);
    try testing.expectEqual(@as(usize, 2), tc.len);
    try testing.expect(tc[0].lua_ref != tc[1].lua_ref);

    const me = runner.event_registry.handlers(.message_end);
    try testing.expectEqual(@as(usize, 1), me.len);
    try testing.expect(me[0].lua_ref != c.LUA_REFNIL);
}

test "zi.on rejects invalid subscriptions with Lua-catchable errors" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;
    const runner = &host.runner;

    try state.doString(
        \\local cases = {
        \\  { name = "not_a_real_event", handler = function() end, want = "not_a_real_event" },
        \\  { name = "message_end", handler = "not a function", want = "function" },
        \\}
        \\for _, case in ipairs(cases) do
        \\  local ok, err = pcall(function() zi.on(case.name, case.handler) end)
        \\  assert(not ok, "expected error")
        \\  assert(string.find(err, case.want) ~= nil, tostring(err))
        \\end
    , "test_invalid_event_subscriptions");

    try testing.expectEqual(@as(usize, 0), runner.event_registry.count());
}

test "zi.spawn validates required task and callback shapes" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;

    try state.doString(
        \\local cases = {
        \\  { spec = {}, want = "task" },
        \\  { spec = { task = "x", on = { message_end = "not a fn" } }, want = "function" },
        \\}
        \\for _, case in ipairs(cases) do
        \\  local ok, err = pcall(function() zi.spawn(case.spec) end)
        \\  assert(not ok)
        \\  assert(string.find(err, case.want) ~= nil, tostring(err))
        \\end
    , "spawn_validation");
}

test "zi.spawn end-to-end: dispatches per-event callbacks via argv_override" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;

    const Helper = struct {
        fn run(L_opt: ?*c.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            if (c.lua_type(L, 1) != c.LUA_TFUNCTION) return luaError(L, "expected fn");

            c.lua_createtable(L, 0, 1);
            c.lua_pushvalue(L, 1);
            c.lua_setfield(L, -2, "message_end");
            const cb_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);

            const script =
                \\printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"helo"}]}}'
                \\printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"helo"}]}}'
            ;
            const override = [_][]const u8{ "sh", "-c", script };

            var ctx_struct = TrampolineCtx{ .L = L, .callbacks_ref = cb_ref };
            const cfg = spawn_types.SpawnConfig{
                .allocator = std.testing.allocator,
                .cwd = ".",
                .task = "unused",
                .argv_override = &override,
                .on_event = &eventTrampoline,
                .on_event_ctx = @ptrCast(&ctx_struct),
            };

            var result = spawn_mod.ziSpawn(cfg);
            defer result.deinit(std.testing.allocator);
            c.luaL_unref(L, c.LUA_REGISTRYINDEX, cb_ref);

            pushSpawnResult(L, result);
            return 1;
        }
    };

    c.lua_pushcfunction(state.L, &Helper.run);
    c.lua_setglobal(state.L, "_test_spawn");

    try state.doString(
        \\local count = 0
        \\local saw_text = nil
        \\local r = _test_spawn(function(event)
        \\  count = count + 1
        \\  if event.message and event.message.content then
        \\    saw_text = event.message.content[1].text
        \\  end
        \\end)
        \\assert(count == 2, "expected 2 callbacks, got " .. tostring(count))
        \\assert(saw_text == "helo", "expected helo, got " .. tostring(saw_text))
        \\assert(r.exit_code == 0)
        \\assert(r.cancelled == false)
        \\assert(r.final_text == "helo")
        \\assert(type(r.usage) == "table")
        \\assert(r.usage.turns == 2)
    , "spawn_e2e");
}

test "zi.register_tool surfaces validation errors as Lua errors" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;
    const runner = &host.runner;

    try state.doString(
        \\local ok, err = pcall(function()
        \\  zi.register_tool({
        \\    name = "broken",
        \\    description = "no execute",
        \\    parameters = { type = "object" },
        \\  })
        \\end)
        \\assert(not ok, "expected error")
        \\assert(string.find(err, "execute") ~= nil, "error should mention 'execute', got: " .. tostring(err))
    , "test_missing_execute");

    try testing.expectEqual(@as(usize, 0), runner.tool_registry.count());
}

test "zi.on accepts every reserved v2 event" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;
    const runner = &host.runner;

    const events = [_][]const u8{
        "session_directory",
        "resources_discover",
        "agent_start",
        "agent_end",
        "before_agent_start",
        "input",
        "context",
        "before_provider_request",
        "turn_start",
        "turn_end",
        "message_start",
        "message_update",
        "message_end",
        "message",
        "tool_execution_start",
        "tool_execution_update",
        "tool_execution_end",
        "tool_call",
        "tool_result",
        "user_bash",
        "session_start",
        "session_shutdown",
        "session_before_switch",
        "session_before_fork",
        "session_before_compact",
        "session_compact",
        "session_before_tree",
        "session_tree",
        "model_select",
    };

    inline for (events) |event_name| {
        try testing.expect(parseEventKind(event_name) != null);
    }
    try testing.expectEqual(@as(usize, 29), events.len);

    try state.doString(
        \\local events = {
        \\  "session_directory", "resources_discover",
        \\  "agent_start", "agent_end", "before_agent_start", "input", "context", "before_provider_request",
        \\  "turn_start", "turn_end", "message_start", "message_update", "message_end", "message",
        \\  "tool_execution_start", "tool_execution_update", "tool_execution_end", "tool_call", "tool_result", "user_bash",
        \\  "session_start", "session_shutdown", "session_before_switch", "session_before_fork",
        \\  "session_before_compact", "session_compact", "session_before_tree", "session_tree",
        \\  "model_select",
        \\}
        \\for _, name in ipairs(events) do
        \\  zi.on(name, function() end)
        \\end
    , "test_all_reserved_events");

    try testing.expectEqual(@as(usize, 29), runner.event_registry.count());
}

test "zi.register_command registers commands and disambiguates duplicate visible names" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;
    const runner = &host.runner;

    try state.doString(
        \\assert(zi.register_command({ name = "greet", description = "say hello", handler = function() end }) == true)
        \\zi.register_command({ name = "dup", description = "first", handler = function() end })
        \\zi.register_command({ name = "dup", description = "second", handler = function() end })
    , "test_register_commands");

    try testing.expectEqual(@as(usize, 3), runner.command_registry.count());
    const cmd = runner.command_registry.getByVisibleName("greet").?;
    try testing.expectEqualStrings("greet", cmd.name);
    try testing.expectEqualStrings("say hello", cmd.description);
    try testing.expect(runner.command_registry.getByVisibleName("dup") == null);
    try testing.expect(runner.command_registry.getByVisibleName("dup:1") != null);
    try testing.expect(runner.command_registry.getByVisibleName("dup:2") != null);
}

test "zi.register_keybinding registers normalized key specs" {
    var host = try ApiTestHost.init(testing.allocator, 0);
    defer host.deinit();
    host.installZi();

    const state = &host.state;
    const runner = &host.runner;

    try state.doString(
        \\assert(zi.register_keybinding({ id = "starter.pick", key = "ctrl+f", description = "Pick starter", handler = function(ctx) end }) == true)
    , "test_register_keybindings");

    try testing.expectEqual(@as(usize, 1), runner.keybinding_registry.count());
    const kb = runner.keybinding_registry.items()[0];
    try testing.expectEqualStrings("starter.pick", kb.id);
    try testing.expectEqualStrings("Pick starter", kb.description);
    try testing.expectEqual(@as(usize, 1), kb.keys.len);
    try testing.expect(keys_mod.Key.eql(kb.keys[0], .{ .code = .char, .char = 'f', .ctrl = true }));
}
