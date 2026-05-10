const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const context_mod = @import("context.zig");
const webview = @import("../webview/root.zig");
const resource_types = @import("../resources/types.zig");
const json_api = @import("json_api.zig");

const c = lua_runtime.c;

const ApiError = error{
    OutOfMemory,
    MissingSpec,
    MissingId,
    InvalidId,
    InvalidTitle,
    InvalidHtml,
    HtmlTooLarge,
    InvalidAssetRoot,
    InvalidEntry,
    InvalidWidth,
    InvalidHeight,
    InvalidFloating,
    InvalidBridge,
    InvalidCommands,
    InvalidCommandName,
    InvalidCommandSpec,
    InvalidHandler,
    InvalidPermissions,
    InvalidPermission,
};

pub fn pushContextApi(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) void {
    _ = provenance;
    c.lua_createtable(L, 0, 5);
    pushMethod(L, runner, &ctxWebviewOpen);
    c.lua_setfield(L, -2, "open");
    pushMethod(L, runner, &ctxWebviewClose);
    c.lua_setfield(L, -2, "close");
    pushMethod(L, runner, &ctxWebviewDispatch);
    c.lua_setfield(L, -2, "__dispatch");
    pushMethod(L, runner, &ctxWebviewPump);
    c.lua_setfield(L, -2, "__pump");
    c.lua_pushboolean(L, 1);
    c.lua_setfield(L, -2, "available");
}

fn ctxWebviewOpen(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    runner.assertOnLuaThread();
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return luaError(L, "ctx.webview.open: expected spec table");

    var options = buildOptions(L, runner) catch |err| {
        return luaErrorFmt(L, "ctx.webview.open: {s}", .{errorMessage(err)});
    };
    var transferred = false;
    defer freeBuiltOptions(runner.allocator, &options, if (transferred) null else L);

    runner.webview_manager.register(options, L) catch |err| {
        return luaErrorFmt(L, "ctx.webview.open: {s}", .{openHostErrorMessage(err)});
    };
    transferred = true;

    runner.webview_manager.openHost(options.id) catch |err| {
        _ = runner.webview_manager.close(options.id, L);
        return luaErrorFmt(L, "ctx.webview.open: {s}", .{openHostErrorMessage(err)});
    };

    c.lua_createtable(L, 0, 1);
    _ = c.lua_pushlstring(L, options.id.ptr, options.id.len);
    c.lua_setfield(L, -2, "id");
    return 1;
}

fn openHostErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedPlatform => "native WebView is unavailable on this platform",
        error.WindowNotFound => "window was not registered",
        error.HostSpawnFailed => "failed to spawn zi-webview-host",
        error.InitialDocumentSendFailed => "failed to send initial document to zi-webview-host",
        error.AssetEntryNotFound => "asset entry file was not found",
        error.InvalidAssetRoot => "asset_root must be non-empty when provided",
        error.InvalidEntry => "entry must be a non-empty relative path without '..' components",
        error.HtmlTooLarge => "html exceeds maximum size",
        error.ResponseTooLarge => "bridge response exceeds maximum size",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

fn ctxWebviewClose(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    runner.assertOnLuaThread();
    const id = readArgString(L, 1) orelse return luaError(L, "ctx.webview.close: expected window id");
    const closed = runner.webview_manager.close(id, runner.lua_state.?.L);
    c.lua_pushboolean(L, if (closed) 1 else 0);
    return 1;
}

fn ctxWebviewDispatch(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    runner.assertOnLuaThread();
    const window_id = readArgString(L, 1) orelse return luaError(L, "ctx.webview.__dispatch: expected window id");
    const command = readArgString(L, 2) orelse return luaError(L, "ctx.webview.__dispatch: expected command");
    const payload_json = readArgString(L, 3) orelse "null";
    const response = dispatchBridge(runner, window_id, command, payload_json, runner.allocator) catch |err| {
        return luaErrorFmt(L, "ctx.webview.__dispatch: {s}", .{@errorName(err)});
    };
    defer runner.allocator.free(response);
    _ = c.lua_pushlstring(L, response.ptr, response.len);
    return 1;
}

fn ctxWebviewPump(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    runner.assertOnLuaThread();
    const count = pumpEvents(runner);
    c.lua_pushinteger(L, @intCast(count));
    return 1;
}

pub fn pumpEvents(runner: *runner_mod.ExtensionRunner) usize {
    var count: usize = 0;
    while (runner.webview_manager.popEvent()) |event_in| {
        var event = event_in;
        defer event.deinit(runner.allocator);
        count += 1;
        switch (event) {
            .bridge => |bridge| {
                const response = dispatchBridge(runner, bridge.window_id, bridge.command, bridge.payload_json, runner.allocator) catch |err| {
                    sendBridgeErrorOrClose(runner, bridge.window_id, bridge.id, @errorName(err));
                    continue;
                };
                defer runner.allocator.free(response);
                sendBridgeResponseOrClose(runner, bridge.window_id, bridge.id, true, response);
            },
            .closed => |closed| {
                _ = runner.webview_manager.close(closed.window_id, luaState(runner));
            },
            .err => |err| {
                std.log.warn("webview host error window={s}: {s}", .{ err.window_id, err.message });
                _ = runner.webview_manager.close(err.window_id, luaState(runner));
            },
            .ready => {},
        }
    }
    return count;
}

fn sendBridgeErrorOrClose(runner: *runner_mod.ExtensionRunner, window_id: []const u8, bridge_id: []const u8, message: []const u8) void {
    runner.webview_manager.sendBridgeError(window_id, bridge_id, message) catch |send_err| {
        std.log.warn("webview bridge error response failed window={s} id={s}: {s}", .{ window_id, bridge_id, @errorName(send_err) });
        _ = runner.webview_manager.close(window_id, luaState(runner));
    };
}

fn sendBridgeResponseOrClose(runner: *runner_mod.ExtensionRunner, window_id: []const u8, bridge_id: []const u8, ok: bool, result_json: []const u8) void {
    runner.webview_manager.sendBridgeResponse(window_id, bridge_id, ok, result_json) catch |send_err| {
        std.log.warn("webview bridge response failed window={s} id={s}: {s}", .{ window_id, bridge_id, @errorName(send_err) });
        _ = runner.webview_manager.close(window_id, luaState(runner));
    };
}

fn luaState(runner: *runner_mod.ExtensionRunner) ?*c.lua_State {
    return if (runner.lua_state) |state| state.L else null;
}

pub const DispatchError = error{
    MissingLuaState,
    WindowNotFound,
    CommandNotFound,
    PayloadTooLarge,
    ResponseTooLarge,
    InvalidPayloadJson,
    HandlerError,
    UnexpectedYield,
    OutOfMemory,
    UnsupportedLuaType,
    InvalidUtf8,
    LimitExceeded,
    LuaRuntime,
    LuaSyntax,
    LuaMemory,
    LuaError,
    InvalidCoroutineState,
};

pub fn dispatchBridge(
    runner: *runner_mod.ExtensionRunner,
    window_id: []const u8,
    command_name: []const u8,
    payload_json: []const u8,
    allocator: std.mem.Allocator,
) DispatchError![]u8 {
    if (payload_json.len > webview.max_request_bytes) return error.PayloadTooLarge;
    const state = runner.lua_state orelse return error.MissingLuaState;
    const window = runner.webview_manager.find(window_id) orelse return error.WindowNotFound;
    const command = window.findCommand(command_name) orelse return error.CommandNotFound;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{ .allocate = .alloc_always }) catch return error.InvalidPayloadJson;
    defer parsed.deinit();

    var co = try lua_runtime.Coroutine.init(state);
    defer co.deinit();
    _ = c.lua_rawgeti(co.L, c.LUA_REGISTRYINDEX, command.handler_ref);
    if (c.lua_type(co.L, -1) != c.LUA_TFUNCTION) return error.HandlerError;
    try lua_runtime.pushJsonValue(co.L, parsed.value);
    try context_mod.pushExtensionContext(co.L, runner, window.provenance);

    if (window.provenance) |provenance| {
        runner.beginExecutionContext(runner.sourceForProvenance(provenance));
        defer runner.endExecutionContext();
        runner.setModuleContext(state, provenance);
    }

    const result = try co.resumeWith(2);
    switch (result.status) {
        .yielded => return error.UnexpectedYield,
        .ok, .finished => {},
    }

    var value: std.json.Value = .null;
    if (result.nresults > 0) {
        if (result.nresults > 1) c.lua_pop(co.L, result.nresults - 1);
        var budget = lua_runtime.JsonConvertBudget{ .limits = lua_runtime.default_json_convert_limits };
        value = try lua_runtime.luaValueToJsonLimited(co.L, -1, allocator, &budget);
        c.lua_pop(co.L, 1);
    }
    defer lua_runtime.freeJsonValue(allocator, value);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    const written = out.written();
    if (written.len > webview.max_response_bytes) return error.ResponseTooLarge;
    return out.toOwnedSlice();
}

fn buildOptions(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) ApiError!webview.Options {
    const allocator = runner.allocator;
    const id = try requireString(L, 1, "id", allocator, error.MissingId, error.InvalidId);
    errdefer allocator.free(id);
    if (id.len == 0 or id.len > webview.max_window_id_bytes) return error.InvalidId;
    const title = try optionalString(L, 1, "title", allocator, error.InvalidTitle) orelse try allocator.dupe(u8, id);
    errdefer allocator.free(title);
    const html = try optionalString(L, 1, "html", allocator, error.InvalidHtml);
    errdefer if (html) |v| allocator.free(v);
    if (html) |v| if (v.len > webview.max_html_bytes) return error.HtmlTooLarge;
    const asset_root = try optionalString(L, 1, "asset_root", allocator, error.InvalidAssetRoot);
    errdefer if (asset_root) |v| allocator.free(v);
    const entry = try optionalString(L, 1, "entry", allocator, error.InvalidEntry) orelse try allocator.dupe(u8, "index.html");
    errdefer allocator.free(entry);
    if (asset_root) |root| {
        webview.validateAssetSpec(root, entry) catch |err| switch (err) {
            error.InvalidAssetRoot => return error.InvalidAssetRoot,
            error.InvalidEntry => return error.InvalidEntry,
        };
    }
    const width = try optionalU32(L, 1, "width", 800, error.InvalidWidth);
    const height = try optionalU32(L, 1, "height", 600, error.InvalidHeight);
    const floating = try optionalBool(L, 1, "floating", false, error.InvalidFloating);
    const commands = try parseCommands(L, 1, allocator);
    errdefer freeCommands(allocator, commands, null);

    return .{
        .id = id,
        .title = title,
        .width = width,
        .height = height,
        .floating = floating,
        .asset_root = asset_root,
        .entry = entry,
        .html = html,
        .commands = commands,
        .provenance = currentProvenance(runner),
    };
}

fn parseCommands(L: *c.lua_State, spec_idx_in: c_int, allocator: std.mem.Allocator) ApiError![]webview.Command {
    const spec_idx = absIndex(L, spec_idx_in);
    _ = c.lua_getfield(L, spec_idx, "bridge");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return &.{};
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return error.InvalidBridge;
    const bridge_idx = absIndex(L, -1);
    _ = c.lua_getfield(L, bridge_idx, "commands");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return &.{};
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return error.InvalidCommands;
    const commands_idx = absIndex(L, -1);

    var commands: std.ArrayList(webview.Command) = .empty;
    errdefer freeCommands(allocator, commands.items, null);
    c.lua_pushnil(L);
    while (c.lua_next(L, commands_idx) != 0) {
        const command = parseCommandEntry(L, -2, -1, allocator) catch |err| {
            c.lua_pop(L, 2);
            return err;
        };
        commands.append(allocator, command) catch |err| {
            var owned = command;
            freeCommand(allocator, &owned, null);
            c.lua_pop(L, 2);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        c.lua_pop(L, 1);
    }
    return commands.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn parseCommandEntry(L: *c.lua_State, key_idx_in: c_int, value_idx_in: c_int, allocator: std.mem.Allocator) ApiError!webview.Command {
    const key_idx = absIndex(L, key_idx_in);
    const value_idx = absIndex(L, value_idx_in);
    if (c.lua_type(L, key_idx) != c.LUA_TSTRING) return error.InvalidCommandName;
    var name_len: usize = 0;
    const name_ptr = c.lua_tolstring(L, key_idx, &name_len) orelse return error.InvalidCommandName;
    if (name_len == 0 or name_len > webview.max_command_name_bytes) return error.InvalidCommandName;
    const name = try allocator.dupe(u8, name_ptr[0..name_len]);
    errdefer allocator.free(name);

    var permissions: []const []const u8 = &.{};
    errdefer freeStringArray(allocator, permissions);
    var handler_ref: c_int = c.LUA_NOREF;
    errdefer if (handler_ref != c.LUA_NOREF) c.luaL_unref(L, c.LUA_REGISTRYINDEX, handler_ref);

    if (c.lua_type(L, value_idx) == c.LUA_TFUNCTION) {
        c.lua_pushvalue(L, value_idx);
        handler_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    } else if (c.lua_type(L, value_idx) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, value_idx, "permissions");
        permissions = try parsePermissions(L, -1, allocator);
        c.lua_pop(L, 1);
        _ = c.lua_getfield(L, value_idx, "handler");
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_pop(L, 1);
            return error.InvalidHandler;
        }
        handler_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    } else {
        return error.InvalidCommandSpec;
    }

    const out = webview.Command{ .name = name, .permissions = permissions, .handler_ref = handler_ref };
    handler_ref = c.LUA_NOREF;
    permissions = &.{};
    return out;
}

fn parsePermissions(L: *c.lua_State, idx_in: c_int, allocator: std.mem.Allocator) ApiError![]const []const u8 {
    const idx = absIndex(L, idx_in);
    if (c.lua_type(L, idx) == c.LUA_TNIL) return &.{};
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return error.InvalidPermissions;
    const len = c.lua_rawlen(L, idx);
    const out = try allocator.alloc([]const u8, len);
    var count: usize = 0;
    errdefer {
        for (out[0..count]) |item| allocator.free(item);
        allocator.free(out);
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        _ = c.lua_rawgeti(L, idx, @intCast(i + 1));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidPermission;
        var item_len: usize = 0;
        const item_ptr = c.lua_tolstring(L, -1, &item_len) orelse return error.InvalidPermission;
        out[i] = try allocator.dupe(u8, item_ptr[0..item_len]);
        count += 1;
    }
    return out;
}

fn freeBuiltOptions(allocator: std.mem.Allocator, options: *webview.Options, L: ?*c.lua_State) void {
    allocator.free(options.id);
    allocator.free(options.title);
    allocator.free(options.entry);
    if (options.asset_root) |v| allocator.free(v);
    if (options.html) |v| allocator.free(v);
    freeCommands(allocator, options.commands, L);
    options.* = undefined;
}

fn freeCommands(allocator: std.mem.Allocator, commands: []const webview.Command, L: ?*c.lua_State) void {
    for (commands) |command_in| {
        var command = command_in;
        freeCommand(allocator, &command, L);
    }
    if (commands.len > 0) allocator.free(commands);
}

fn freeCommand(allocator: std.mem.Allocator, command: *webview.Command, L: ?*c.lua_State) void {
    allocator.free(command.name);
    freeStringArray(allocator, command.permissions);
    if (L) |state| c.luaL_unref(state, c.LUA_REGISTRYINDEX, command.handler_ref);
}

fn freeStringArray(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn currentProvenance(runner: *const runner_mod.ExtensionRunner) ?resource_types.ExtensionProvenance {
    const source = runner.currentLoadSource() orelse return null;
    return source.provenance;
}

fn requireString(L: *c.lua_State, table_idx: c_int, field: [:0]const u8, allocator: std.mem.Allocator, missing_err: ApiError, invalid_err: ApiError) ApiError![]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return missing_err;
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return invalid_err;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return invalid_err;
    return allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
}

fn optionalString(L: *c.lua_State, table_idx: c_int, field: [:0]const u8, allocator: std.mem.Allocator, invalid_err: ApiError) ApiError!?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return null;
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return invalid_err;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return invalid_err;
    return allocator.dupe(u8, ptr[0..len]) catch error.OutOfMemory;
}

fn optionalU32(L: *c.lua_State, table_idx: c_int, field: [:0]const u8, default: u32, invalid_err: ApiError) ApiError!u32 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return default;
    if (c.lua_type(L, -1) != c.LUA_TNUMBER or c.lua_isinteger(L, -1) == 0) return invalid_err;
    const value = c.lua_tointegerx(L, -1, null);
    if (value <= 0 or value > std.math.maxInt(u32)) return invalid_err;
    return @intCast(value);
}

fn optionalBool(L: *c.lua_State, table_idx: c_int, field: [:0]const u8, default: bool, invalid_err: ApiError) ApiError!bool {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return default;
    if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return invalid_err;
    return c.lua_toboolean(L, -1) != 0;
}

fn readArgString(L: *c.lua_State, idx: c_int) ?[]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return null;
    return ptr[0..len];
}

fn absIndex(L: *c.lua_State, idx: c_int) c_int {
    return if (idx < 0) c.lua_gettop(L) + idx + 1 else idx;
}

fn pushMethod(L: *c.lua_State, runner: *runner_mod.ExtensionRunner, func: *const fn (?*c.lua_State) callconv(.c) c_int) void {
    c.lua_pushlightuserdata(L, runner);
    c.lua_pushcclosure(L, func, 1);
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const raw = c.lua_touserdata(L, c.lua_upvalueindex(1)) orelse unreachable;
    return @ptrCast(@alignCast(raw));
}

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

fn errorMessage(err: ApiError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.MissingSpec => "missing spec table",
        error.MissingId => "missing required field 'id'",
        error.InvalidId => "field 'id' must be a non-empty string",
        error.InvalidTitle => "field 'title' must be a string",
        error.InvalidHtml => "field 'html' must be a string",
        error.HtmlTooLarge => "field 'html' exceeds maximum size",
        error.InvalidAssetRoot => "field 'asset_root' must be a non-empty string",
        error.InvalidEntry => "field 'entry' must be a non-empty relative path without '..' components",
        error.InvalidWidth => "field 'width' must be a positive integer",
        error.InvalidHeight => "field 'height' must be a positive integer",
        error.InvalidFloating => "field 'floating' must be a boolean",
        error.InvalidBridge => "field 'bridge' must be a table",
        error.InvalidCommands => "field 'bridge.commands' must be a table",
        error.InvalidCommandName => "bridge command names must be non-empty strings",
        error.InvalidCommandSpec => "bridge command must be a function or table",
        error.InvalidHandler => "bridge command handler must be a function",
        error.InvalidPermissions => "bridge command permissions must be an array of strings",
        error.InvalidPermission => "bridge command permissions must be strings",
    };
}

const testing = std.testing;

fn testProvenance() resource_types.ExtensionProvenance {
    return .{
        .runtime_root_id = "root",
        .root_kind = .runtime_root,
        .extension_id = "ext",
        .state_owner_id = "owner",
    };
}

test "webview context API stores callbacks and dispatches JSON" {
    var state = try lua_runtime.LuaState.init(testing.allocator);
    defer state.deinit();
    var runner = runner_mod.ExtensionRunner.init(testing.allocator, 1);
    defer runner.deinit();
    runner.attachLuaState(&state);
    json_api.install(&state, &runner);
    c.lua_setglobal(state.L, "zi_json");
    const provenance = testProvenance();
    try runner.recordLoadedExtensionInfo(provenance, "ext", "user", "/tmp/ext/init.lua");
    context_mod.pushExtensionContext(state.L, &runner, provenance) catch return error.ContextFailed;
    c.lua_setglobal(state.L, "ctx");
    try state.doString(
        \\local win = ctx.webview.open({
        \\  id = "diff-review",
        \\  title = "Diff Review",
        \\  asset_root = ctx.extension.root .. "/ui/dist",
        \\  entry = "index.html",
        \\  bridge = { commands = {
        \\    load_diff = { permissions = { "git.read" }, handler = function(payload, ctx)
        \\      _G.last_webview_scope = payload.scope
        \\      return { scope = payload.scope, cwd = ctx.cwd }
        \\    end },
        \\  } },
        \\})
        \\assert(win.id == "diff-review")
        \\local result = ctx.webview.__dispatch("diff-review", "load_diff", '{"scope":"branch"}')
        \\local decoded = zi_json.decode(result)
        \\assert(decoded.scope == "branch")
    , "webview_open_dispatch");

    try runner.webview_manager.enqueueBridgeEventForTest("diff-review", "1", "load_diff", "{\"scope\":\"pump\"}");
    try state.doString(
        \\assert(ctx.webview.__pump() == 1)
        \\assert(_G.last_webview_scope == "pump")
    , "webview_pump_dispatch");
}
