const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const resource_types = @import("../resources/types.zig");
const json_util = @import("../../ai/json_util.zig");
const agent_protocol = @import("../../agent3/types.zig");
const session_core = @import("../../session/root.zig");
const extension_ui = @import("ui.zig");
const request_mod = @import("../request.zig");
const ai_provider = @import("../../ai/provider.zig");

const c = lua_runtime.c;

/// Push the shared extension context table used by tool execution and
/// event handlers. Tool-specific callers can add extra fields (e.g.
/// `update`) after this returns.
pub fn pushExtensionContext(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) !void {
    c.lua_createtable(L, 0, 12);

    _ = c.lua_pushlstring(L, runner.cwd.ptr, runner.cwd.len);
    c.lua_setfield(L, -2, "cwd");

    const has_ui = switch (runner.runtime) {
        .bound => |bound| bound.ui != null or bound.show_panel != null or bound.publish_prompt != null or bound.publish_surface != null or bound.publish_editor_action != null,
        .stub => false,
    };
    c.lua_pushboolean(L, if (has_ui) 1 else 0);
    c.lua_setfield(L, -2, "has_ui");

    pushUiApi(L, runner, provenance);
    c.lua_setfield(L, -2, "ui");

    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "signal");

    pushStateApi(L, runner, provenance);
    c.lua_setfield(L, -2, "state");

    pushSessionApi(L, runner);
    c.lua_setfield(L, -2, "session");

    pushAiApi(L, runner);
    c.lua_setfield(L, -2, "ai");

    pushContextBinding(L, runner, provenance);
    c.lua_setfield(L, -2, "binding");

    if (runner.enable_test_async) {
        pushMethod(L, runner, &ctxTestAsync);
        c.lua_setfield(L, -2, "__test_async");
    }

    switch (runner.runtime) {
        .bound => |bound| {
            pushModelsApi(L, runner);
            c.lua_setfield(L, -2, "models");

            pushMethod(L, runner, &ctxIsIdle);
            c.lua_setfield(L, -2, "is_idle");

            pushMethod(L, runner, &ctxAbort);
            c.lua_setfield(L, -2, "abort");

            pushMethod(L, runner, &ctxHasPendingMessages);
            c.lua_setfield(L, -2, "has_pending_messages");

            if (bound.shutdown != null) {
                pushMethod(L, runner, &ctxShutdown);
            } else {
                c.lua_pushnil(L);
            }
            c.lua_setfield(L, -2, "shutdown");

            pushMethod(L, runner, &ctxGetContextUsage);
            c.lua_setfield(L, -2, "get_context_usage");

            pushMethod(L, runner, &ctxGetSystemPrompt);
            c.lua_setfield(L, -2, "get_system_prompt");
        },
        .stub => {
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "models");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "is_idle");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "abort");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "has_pending_messages");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "shutdown");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "get_context_usage");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "get_system_prompt");
        },
    }
}

fn pushUiApi(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) void {
    const prov = provenance orelse {
        c.lua_pushnil(L);
        return;
    };

    const has_methods = switch (runner.runtime) {
        .bound => |bound| bound.show_panel != null or bound.publish_prompt != null or bound.publish_surface != null or bound.publish_editor_action != null,
        .stub => false,
    };
    if (!has_methods) {
        c.lua_pushnil(L);
        return;
    }

    c.lua_createtable(L, 0, 16);
    if (runner.runtime.bound.show_panel != null) {
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiShowPanel);
        c.lua_setfield(L, -2, "show_panel");
    }
    if (runner.runtime.bound.publish_prompt != null) {
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiPrompt);
        c.lua_setfield(L, -2, "prompt");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiConfirm);
        c.lua_setfield(L, -2, "confirm");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSelect);
        c.lua_setfield(L, -2, "select");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiInput);
        c.lua_setfield(L, -2, "input");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiEditor);
        c.lua_setfield(L, -2, "editor");
    }
    if (runner.runtime.bound.publish_editor_action != null) {
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetEditorText);
        c.lua_setfield(L, -2, "set_editor_text");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiPasteToEditor);
        c.lua_setfield(L, -2, "paste_to_editor");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiClearEditorText);
        c.lua_setfield(L, -2, "clear_editor_text");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiGetEditorText);
        c.lua_setfield(L, -2, "get_editor_text");
    }
    if (runner.runtime.bound.publish_surface != null) {
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiNotify);
        c.lua_setfield(L, -2, "notify");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetStatus);
        c.lua_setfield(L, -2, "set_status");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetTitle);
        c.lua_setfield(L, -2, "set_title");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetWidget);
        c.lua_setfield(L, -2, "set_widget");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetHeader);
        c.lua_setfield(L, -2, "set_header");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetFooter);
        c.lua_setfield(L, -2, "set_footer");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetWorking);
        c.lua_setfield(L, -2, "set_working");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiSetHiddenThinkingLabel);
        c.lua_setfield(L, -2, "set_hidden_thinking_label");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxUiShowOverlay);
        c.lua_setfield(L, -2, "show_overlay");
    }
}

fn pushUiMethod(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    state_owner_id: []const u8,
    func: *const fn (?*c.lua_State) callconv(.c) c_int,
) void {
    c.lua_pushlightuserdata(L, runner);
    _ = c.lua_pushlstring(L, state_owner_id.ptr, state_owner_id.len);
    c.lua_pushcclosure(L, func, 2);
}

fn ctxUiSetEditorText(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishEditorActionFromArgs(L, .set_text) catch {};
    return 0;
}

fn ctxUiPasteToEditor(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishEditorActionFromArgs(L, .paste_text) catch {};
    return 0;
}

fn ctxUiClearEditorText(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishEditorActionFromArgs(L, .clear_text) catch {};
    return 0;
}

fn ctxUiGetEditorText(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishEditorActionFromArgs(L, .get_text) catch {};
    c.lua_pushnil(L);
    return 1;
}

fn publishEditorActionFromArgs(L: *c.lua_State, kind: extension_ui.EditorActionKind) !void {
    const runner = stateRunnerFromUpvalue(L);
    const bound = switch (runner.runtime) {
        .bound => |bound| bound,
        .stub => return,
    };
    const callback = bound.publish_editor_action orelse return;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const action = extension_ui.EditorAction{
        .state_owner_id = try aa.dupe(u8, stateOwnerFromUpvalue(L)),
        .generation = runner.generation,
        .kind = kind,
        .text = try readOptionalArgString(aa, L, 1),
    };
    try callback(bound.session, action);
}

fn ctxUiNotify(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishNotificationFromArgs(L) catch {};
    return 0;
}

fn ctxUiSetStatus(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .status) catch {};
    return 0;
}

fn ctxUiSetTitle(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .title) catch {};
    return 0;
}

fn ctxUiSetWidget(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .widget) catch {};
    return 0;
}

fn ctxUiSetHeader(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .header) catch {};
    return 0;
}

fn ctxUiSetFooter(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .footer) catch {};
    return 0;
}

fn ctxUiSetWorking(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .working) catch {};
    return 0;
}

fn ctxUiSetHiddenThinkingLabel(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .thinking_label) catch {};
    return 0;
}

fn ctxUiShowOverlay(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishSurfaceFromArgs(L, .overlay) catch {};
    return 0;
}

fn publishSurfaceFromArgs(L: *c.lua_State, kind: extension_ui.SurfaceKind) !void {
    const runner = stateRunnerFromUpvalue(L);
    const bound = switch (runner.runtime) {
        .bound => |bound| bound,
        .stub => return,
    };
    const callback = bound.publish_surface orelse return;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const update = try parseSurface(arena.allocator(), L, kind, stateOwnerFromUpvalue(L), runner.generation);
    try callback(bound.session, update);
}

fn publishNotificationFromArgs(L: *c.lua_State) !void {
    const runner = stateRunnerFromUpvalue(L);
    const bound = switch (runner.runtime) {
        .bound => |bound| bound,
        .stub => return,
    };
    const callback = bound.publish_surface orelse return;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const kind = try readNotificationKind(aa, L, 2);
    const update = extension_ui.SurfaceUpdate{
        .state_owner_id = try aa.dupe(u8, stateOwnerFromUpvalue(L)),
        .generation = runner.generation,
        .kind = .notification,
        .id = kind,
        .text = try readOptionalArgString(aa, L, 1),
        .lifetime = .until_input,
    };
    try callback(bound.session, update);
}

fn parseSurface(
    arena: std.mem.Allocator,
    L: *c.lua_State,
    kind: extension_ui.SurfaceKind,
    state_owner_id: []const u8,
    generation: runner_mod.Generation,
) !extension_ui.SurfaceUpdate {
    const id = switch (kind) {
        .status, .widget, .overlay => try readStringArg(arena, L, 1, "default"),
        else => try arena.dupe(u8, @tagName(kind)),
    };
    const value_idx: c_int = switch (kind) {
        .status, .widget, .overlay => 2,
        else => 1,
    };
    return .{
        .state_owner_id = try arena.dupe(u8, state_owner_id),
        .generation = generation,
        .kind = kind,
        .id = id,
        .text = try readOptionalArgString(arena, L, value_idx),
        .lines = try readSurfaceLines(arena, L, value_idx),
        .placement = try readSurfacePlacement(arena, L, value_idx + 1),
        .lifetime = try readSurfaceLifetime(L, value_idx + 1),
    };
}

fn readStringArg(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, default: []const u8) ![]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return try arena.dupe(u8, default);
    return try dupeLuaString(arena, L, idx);
}

fn readNotificationKind(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return try arena.dupe(u8, "info");
    const value = try dupeLuaString(arena, L, idx);
    if (std.mem.eql(u8, value, "info")) return value;
    if (std.mem.eql(u8, value, "warning")) return value;
    if (std.mem.eql(u8, value, "error")) return value;
    return try arena.dupe(u8, "info");
}

fn readSurfaceLines(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const []const extension_ui.TextSpan {
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return &.{};
    return try readPanelLinesAtStack(arena, L, idx);
}

fn readSurfacePlacement(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !?[]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return null;
    return try readOptionalStringField(arena, L, idx, "placement");
}

fn readSurfaceLifetime(L: *c.lua_State, idx: c_int) !extension_ui.SurfaceLifetime {
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return .session;
    _ = c.lua_getfield(L, idx, "lifetime");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return .session;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return .session;
    const value = ptr[0..len];
    if (std.mem.eql(u8, value, "until_input")) return .until_input;
    if (std.mem.eql(u8, value, "session")) return .session;
    return .session;
}

fn ctxUiPrompt(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const kind = readPromptKindArg(L, 1) orelse {
        pushPromptEnvelope(L, .{ .value = null });
        return 1;
    };
    var result = requestPromptFromArgs(L, kind) catch request_mod.ExtensionPromptResponse.defaultFor(kind);
    defer result.deinit();
    pushPromptEnvelope(L, result);
    return 1;
}

fn ctxUiConfirm(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    var result = requestPromptFromArgs(L, .confirm) catch request_mod.ExtensionPromptResponse.Result{ .confirm = false };
    defer result.deinit();
    c.lua_pushboolean(L, if (result == .confirm and result.confirm) 1 else 0);
    return 1;
}

fn ctxUiSelect(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    var result = requestPromptFromArgs(L, .select) catch request_mod.ExtensionPromptResponse.Result{ .value = null };
    defer result.deinit();
    pushPromptValueResult(L, result);
    return 1;
}

fn ctxUiInput(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    var result = requestPromptFromArgs(L, .input) catch request_mod.ExtensionPromptResponse.Result{ .value = null };
    defer result.deinit();
    pushPromptValueResult(L, result);
    return 1;
}

fn ctxUiEditor(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    var result = requestPromptFromArgs(L, .editor) catch request_mod.ExtensionPromptResponse.Result{ .value = null };
    defer result.deinit();
    pushPromptValueResult(L, result);
    return 1;
}

fn pushPromptValueResult(L: *c.lua_State, result: request_mod.ExtensionPromptResponse.Result) void {
    if (result == .value) {
        if (result.value) |value| {
            _ = c.lua_pushlstring(L, value.text.ptr, value.text.len);
            return;
        }
    }
    c.lua_pushnil(L);
}

fn pushPromptEnvelope(L: *c.lua_State, result: request_mod.ExtensionPromptResponse.Result) void {
    c.lua_createtable(L, 0, 2);
    switch (result) {
        .confirm => |confirmed| {
            _ = c.lua_pushlstring(L, "submitted", "submitted".len);
            c.lua_setfield(L, -2, "status");
            c.lua_pushboolean(L, if (confirmed) 1 else 0);
            c.lua_setfield(L, -2, "value");
        },
        .value => |maybe_value| if (maybe_value) |value| {
            _ = c.lua_pushlstring(L, "submitted", "submitted".len);
            c.lua_setfield(L, -2, "status");
            _ = c.lua_pushlstring(L, value.text.ptr, value.text.len);
            c.lua_setfield(L, -2, "value");
        } else {
            _ = c.lua_pushlstring(L, "cancelled", "cancelled".len);
            c.lua_setfield(L, -2, "status");
        },
        .timeout => {
            _ = c.lua_pushlstring(L, "timeout", "timeout".len);
            c.lua_setfield(L, -2, "status");
        },
    }
}

fn requestPromptFromArgs(L: *c.lua_State, kind: extension_ui.PromptKind) !request_mod.ExtensionPromptResponse.Result {
    const runner = stateRunnerFromUpvalue(L);
    if (c.lua_type(L, 1) != c.LUA_TSTRING and c.lua_type(L, 1) != c.LUA_TTABLE) return request_mod.ExtensionPromptResponse.defaultFor(kind);

    const bound = switch (runner.runtime) {
        .bound => |bound| bound,
        .stub => return request_mod.ExtensionPromptResponse.defaultFor(kind),
    };

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const prompt = try parsePrompt(arena.allocator(), L, kind, stateOwnerFromUpvalue(L), runner.generation);

    if (bound.resolve_prompt) |resolve| {
        var response = request_mod.ExtensionPromptResponse{};
        resolve(bound.session, prompt, &response);
        return response.wait();
    }

    if (bound.publish_prompt) |publish| try publish(bound.session, prompt);
    return request_mod.ExtensionPromptResponse.defaultFor(kind);
}

fn parsePrompt(
    arena: std.mem.Allocator,
    L: *c.lua_State,
    kind: extension_ui.PromptKind,
    state_owner_id: []const u8,
    generation: runner_mod.Generation,
) !extension_ui.PromptRequest {
    const is_table = c.lua_type(L, 1) == c.LUA_TTABLE;
    const prompt_idx = if (is_table) c.lua_absindex(L, 1) else 1;
    const title = if (is_table) try readStringField(arena, L, prompt_idx, "title", "") else try dupeLuaString(arena, L, 1);
    const id = try std.fmt.allocPrint(arena, "{s}:{d}:{s}", .{ state_owner_id, generation, promptKindString(kind) });
    return switch (kind) {
        .confirm => .{
            .state_owner_id = try arena.dupe(u8, state_owner_id),
            .generation = generation,
            .id = id,
            .kind = kind,
            .title = title,
            .message = if (is_table) try readOptionalStringField(arena, L, prompt_idx, "message") else try readOptionalArgString(arena, L, 2),
            .timeout_ms = try readPromptTimeoutMs(L, if (is_table) prompt_idx else 3),
        },
        .select => .{
            .state_owner_id = try arena.dupe(u8, state_owner_id),
            .generation = generation,
            .id = id,
            .kind = kind,
            .title = title,
            .options = if (is_table) try readSelectOptionsField(arena, L, prompt_idx) else try readSelectOptions(arena, L, 2),
            .timeout_ms = try readPromptTimeoutMs(L, if (is_table) prompt_idx else 3),
        },
        .input => .{
            .state_owner_id = try arena.dupe(u8, state_owner_id),
            .generation = generation,
            .id = id,
            .kind = kind,
            .title = title,
            .placeholder = if (is_table) try readOptionalStringField(arena, L, prompt_idx, "placeholder") else try readOptionalArgString(arena, L, 2),
            .prefill = if (is_table) try readOptionalStringField(arena, L, prompt_idx, "default") else null,
            .timeout_ms = try readPromptTimeoutMs(L, if (is_table) prompt_idx else 3),
        },
        .editor => .{
            .state_owner_id = try arena.dupe(u8, state_owner_id),
            .generation = generation,
            .id = id,
            .kind = kind,
            .title = title,
            .prefill = if (is_table) try readOptionalStringField(arena, L, prompt_idx, "prefill") else try readOptionalArgString(arena, L, 2),
            .timeout_ms = try readPromptTimeoutMs(L, if (is_table) prompt_idx else 3),
        },
    };
}

fn readOptionalArgString(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !?[]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return null;
    return try dupeLuaString(arena, L, idx);
}

fn readPromptTimeoutMs(L: *c.lua_State, idx: c_int) !?u64 {
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return null;
    const abs_idx = c.lua_absindex(L, idx);
    _ = c.lua_getfield(L, abs_idx, "timeout_ms");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return null;
    var isnum: c_int = 0;
    const value = c.lua_tointegerx(L, -1, &isnum);
    if (isnum == 0 or value <= 0) return null;
    return @intCast(value);
}

fn readPromptKindArg(L: *c.lua_State, idx: c_int) ?extension_ui.PromptKind {
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return null;
    const abs_idx = c.lua_absindex(L, idx);
    _ = c.lua_getfield(L, abs_idx, "kind");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return null;
    const value = ptr[0..len];
    if (std.mem.eql(u8, value, "confirm")) return .confirm;
    if (std.mem.eql(u8, value, "select")) return .select;
    if (std.mem.eql(u8, value, "input")) return .input;
    if (std.mem.eql(u8, value, "editor")) return .editor;
    return null;
}

fn readSelectOptionsField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const extension_ui.SelectOption {
    _ = c.lua_getfield(L, idx, "options");
    defer c.lua_pop(L, 1);
    return try readSelectOptions(arena, L, -1);
}

fn readSelectOptions(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const extension_ui.SelectOption {
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return &.{};
    const abs_idx = c.lua_absindex(L, idx);
    const n = c.lua_rawlen(L, abs_idx);
    const options = try arena.alloc(extension_ui.SelectOption, @intCast(n));
    var i: c.lua_Integer = 1;
    while (i <= @as(c.lua_Integer, @intCast(n))) : (i += 1) {
        _ = c.lua_rawgeti(L, abs_idx, i);
        defer c.lua_pop(L, 1);
        options[@intCast(i - 1)] = try readSelectOption(arena, L, -1);
    }
    return options;
}

fn readSelectOption(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !extension_ui.SelectOption {
    if (c.lua_type(L, idx) == c.LUA_TSTRING) {
        const value = try dupeLuaString(arena, L, idx);
        return .{ .id = value, .label = value };
    }
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return .{ .id = "", .label = "" };
    const abs_idx = c.lua_absindex(L, idx);
    const id = if (try readOptionalStringField(arena, L, abs_idx, "value")) |value| value else try readStringField(arena, L, abs_idx, "id", "");
    const label = try readStringField(arena, L, abs_idx, "label", id);
    return .{ .id = id, .label = label };
}

fn promptKindString(kind: extension_ui.PromptKind) []const u8 {
    return switch (kind) {
        .confirm => "confirm",
        .select => "select",
        .input => "input",
        .editor => "editor",
    };
}

fn ctxUiShowPanel(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return 0;

    switch (runner.runtime) {
        .bound => |bound| {
            const callback = bound.show_panel orelse return 0;
            var arena = std.heap.ArenaAllocator.init(runner.allocator);
            defer arena.deinit();
            const panel = parsePanel(arena.allocator(), L, 1, stateOwnerFromUpvalue(L), runner.generation) catch return 0;
            callback(bound.session, panel) catch return 0;
        },
        .stub => {},
    }
    return 0;
}

fn parsePanel(
    arena: std.mem.Allocator,
    L: *c.lua_State,
    idx: c_int,
    state_owner_id: []const u8,
    generation: runner_mod.Generation,
) !extension_ui.Panel {
    const abs_idx = c.lua_absindex(L, idx);
    return .{
        .state_owner_id = try arena.dupe(u8, state_owner_id),
        .generation = generation,
        .id = try readStringField(arena, L, abs_idx, "id", "panel"),
        .title = try readStringField(arena, L, abs_idx, "title", ""),
        .lines = try readPanelLines(arena, L, abs_idx),
        .transient = readBoolField(L, abs_idx, "transient"),
    };
}

fn readPanelLines(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const []const extension_ui.TextSpan {
    _ = c.lua_getfield(L, idx, "lines");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return &.{};
    return try readPanelLinesAtStack(arena, L, -1);
}

fn readPanelLinesAtStack(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const []const extension_ui.TextSpan {
    const abs_idx = c.lua_absindex(L, idx);
    const n = c.lua_rawlen(L, abs_idx);
    if (n == 0) return &.{};

    var lines: std.ArrayListUnmanaged([]const extension_ui.TextSpan) = .empty;
    try lines.ensureTotalCapacity(arena, @intCast(n));

    var i: c.lua_Integer = 1;
    while (i <= @as(c.lua_Integer, @intCast(n))) : (i += 1) {
        _ = c.lua_rawgeti(L, abs_idx, i);
        const line = try readPanelLine(arena, L, -1);
        c.lua_pop(L, 1);
        try lines.append(arena, line);
    }
    return lines.items;
}

fn readPanelLine(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const extension_ui.TextSpan {
    if (c.lua_type(L, idx) == c.LUA_TSTRING) {
        const spans = try arena.alloc(extension_ui.TextSpan, 1);
        spans[0] = .{ .text = try dupeLuaString(arena, L, idx) };
        return spans;
    }
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return &.{};

    const abs_idx = c.lua_absindex(L, idx);
    const n = c.lua_rawlen(L, abs_idx);
    var spans: std.ArrayListUnmanaged(extension_ui.TextSpan) = .empty;
    try spans.ensureTotalCapacity(arena, @intCast(n));

    var i: c.lua_Integer = 1;
    while (i <= @as(c.lua_Integer, @intCast(n))) : (i += 1) {
        _ = c.lua_rawgeti(L, abs_idx, i);
        const span = readPanelSpan(arena, L, -1) catch {
            c.lua_pop(L, 1);
            continue;
        };
        c.lua_pop(L, 1);
        try spans.append(arena, span);
    }
    return spans.items;
}

fn readPanelSpan(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !extension_ui.TextSpan {
    if (c.lua_type(L, idx) == c.LUA_TSTRING) return .{ .text = try dupeLuaString(arena, L, idx) };
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return error.BadSpan;

    const abs_idx = c.lua_absindex(L, idx);
    return .{
        .text = try readStringField(arena, L, abs_idx, "text", ""),
        .fg = try readOptionalStringField(arena, L, abs_idx, "fg"),
        .dim = readBoolField(L, abs_idx, "dim"),
    };
}

fn readStringField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, field: [:0]const u8, default: []const u8) ![]const u8 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return try arena.dupe(u8, default);
    return try dupeLuaString(arena, L, -1);
}

fn readOptionalStringField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, field: [:0]const u8) !?[]const u8 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    return try dupeLuaString(arena, L, -1);
}

fn readBoolField(L: *c.lua_State, idx: c_int, field: [:0]const u8) bool {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return c.lua_toboolean(L, -1) != 0;
}

fn dupeLuaString(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return try arena.dupe(u8, ptr[0..len]);
}

fn pushStateApi(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) void {
    const prov = provenance orelse {
        c.lua_pushnil(L);
        return;
    };

    c.lua_createtable(L, 0, 3);
    pushStateMethod(L, runner, prov.state_owner_id, &ctxStateGet);
    c.lua_setfield(L, -2, "get");
    pushStateMethod(L, runner, prov.state_owner_id, &ctxStateSet);
    c.lua_setfield(L, -2, "set");
    pushStateMethod(L, runner, prov.state_owner_id, &ctxStateDelete);
    c.lua_setfield(L, -2, "delete");
}

fn pushStateMethod(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    state_owner_id: []const u8,
    func: *const fn (?*c.lua_State) callconv(.c) c_int,
) void {
    c.lua_pushlightuserdata(L, runner);
    _ = c.lua_pushlstring(L, state_owner_id.ptr, state_owner_id.len);
    c.lua_pushcclosure(L, func, 2);
}

fn stateRunnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ud.?));
}

fn stateOwnerFromUpvalue(L: *c.lua_State) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, c.lua_upvalueindex(2), &len) orelse return &.{};
    return ptr[0..len];
}

fn readKeyArg(L: *c.lua_State) ?[]const u8 {
    if (c.lua_type(L, 1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, 1, &len) orelse return null;
    return ptr[0..len];
}

fn ctxStateGet(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const key = readKeyArg(L) orelse {
        c.lua_pushnil(L);
        return 1;
    };

    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_state_get orelse {
                c.lua_pushnil(L);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, stateOwnerFromUpvalue(L), key) orelse {
                c.lua_pushnil(L);
                return 1;
            };
            defer json_util.freeJsonValue(runner.allocator, value);
            lua_runtime.pushJsonValue(L, value) catch c.lua_pushnil(L);
            return 1;
        },
        .stub => {
            c.lua_pushnil(L);
            return 1;
        },
    }
}

fn ctxStateSet(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const key = readKeyArg(L) orelse return 0;
    if (c.lua_type(L, 2) == c.LUA_TNIL) return 0;

    switch (runner.runtime) {
        .bound => |bound| {
            const setter = bound.session_state_set orelse return 0;
            const value = lua_runtime.luaValueToJson(L, 2, runner.allocator) catch return 0;
            defer json_util.freeJsonValue(runner.allocator, value);
            setter(bound.session, stateOwnerFromUpvalue(L), key, value) catch return 0;
        },
        .stub => {},
    }
    return 0;
}

fn ctxStateDelete(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const key = readKeyArg(L) orelse return 0;

    switch (runner.runtime) {
        .bound => |bound| {
            const deleter = bound.session_state_delete orelse return 0;
            deleter(bound.session, stateOwnerFromUpvalue(L), key) catch return 0;
        },
        .stub => {},
    }
    return 0;
}

fn pushAiApi(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) void {
    c.lua_createtable(L, 0, 1);
    pushMethod(L, runner, &ctxAiComplete);
    c.lua_setfield(L, -2, "complete");
}

fn pushModelsApi(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) void {
    c.lua_createtable(L, 0, 3);
    pushMethod(L, runner, &ctxModelsList);
    c.lua_setfield(L, -2, "list");
    pushMethod(L, runner, &ctxModelsCurrent);
    c.lua_setfield(L, -2, "current");
    pushMethod(L, runner, &ctxModelsGet);
    c.lua_setfield(L, -2, "get");
}

fn pushSessionApi(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) void {
    const has_session = switch (runner.runtime) {
        .bound => |bound| bound.session_info_get != null or bound.session_name_get != null or bound.session_name_set != null or bound.session_tool_results_get != null or bound.session_messages_get != null or bound.session_note_append != null or bound.session_notes_get != null,
        .stub => false,
    };
    if (!has_session) {
        c.lua_pushnil(L);
        return;
    }

    c.lua_createtable(L, 0, 7);
    pushMethod(L, runner, &ctxSessionInfo);
    c.lua_setfield(L, -2, "info");
    pushMethod(L, runner, &ctxSessionName);
    c.lua_setfield(L, -2, "name");
    pushMethod(L, runner, &ctxSessionRename);
    c.lua_setfield(L, -2, "rename");
    pushMethod(L, runner, &ctxSessionToolResults);
    c.lua_setfield(L, -2, "tool_results");
    pushMethod(L, runner, &ctxSessionMessages);
    c.lua_setfield(L, -2, "messages");
    pushMethod(L, runner, &ctxSessionAppendNote);
    c.lua_setfield(L, -2, "append_note");
    pushMethod(L, runner, &ctxSessionNotes);
    c.lua_setfield(L, -2, "notes");
}

fn ctxModelsCurrent(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            pushModel(L, bound.get_model(bound.session));
            return 1;
        },
        .stub => {
            c.lua_pushnil(L);
            return 1;
        },
    }
}

fn ctxModelsGet(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const model_ref = readModelRefArg(L) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.models_get_one orelse {
                c.lua_pushnil(L);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, model_ref) orelse {
                c.lua_pushnil(L);
                return 1;
            };
            defer json_util.freeJsonValue(runner.allocator, value);
            lua_runtime.pushJsonValue(L, value) catch c.lua_pushnil(L);
            return 1;
        },
        .stub => {
            c.lua_pushnil(L);
            return 1;
        },
    }
}

fn ctxModelsList(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.models_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator) orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            defer json_util.freeJsonValue(runner.allocator, value);
            lua_runtime.pushJsonValue(L, value) catch c.lua_createtable(L, 0, 0);
            return 1;
        },
        .stub => {
            c.lua_createtable(L, 0, 0);
            return 1;
        },
    }
}

fn ctxSessionInfo(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_info_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator) orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            defer json_util.freeJsonValue(runner.allocator, value);
            lua_runtime.pushJsonValue(L, value) catch c.lua_createtable(L, 0, 0);
            return 1;
        },
        .stub => {
            c.lua_createtable(L, 0, 0);
            return 1;
        },
    }
}

fn ctxSessionName(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_name_get orelse {
                c.lua_pushnil(L);
                return 1;
            };
            const name = getter(bound.session, runner.allocator) orelse {
                c.lua_pushnil(L);
                return 1;
            };
            defer runner.allocator.free(name);
            _ = c.lua_pushlstring(L, name.ptr, name.len);
            return 1;
        },
        .stub => {
            c.lua_pushnil(L);
            return 1;
        },
    }
}

fn ctxSessionRename(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    if (c.lua_type(L, 1) != c.LUA_TSTRING) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    const name = readKeyArg(L) orelse "";
    switch (runner.runtime) {
        .bound => |bound| {
            const setter = bound.session_name_set orelse {
                c.lua_pushboolean(L, 0);
                return 1;
            };
            setter(bound.session, if (name.len == 0) null else name) catch {
                c.lua_pushboolean(L, 0);
                return 1;
            };
            c.lua_pushboolean(L, 1);
            return 1;
        },
        .stub => {
            c.lua_pushboolean(L, 0);
            return 1;
        },
    }
}

fn ctxSessionToolResults(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const tool_name = readKeyArg(L) orelse {
        c.lua_createtable(L, 0, 0);
        return 1;
    };
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_tool_results_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, tool_name) orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            defer json_util.freeJsonValue(runner.allocator, value);
            lua_runtime.pushJsonValue(L, value) catch c.lua_createtable(L, 0, 0);
            return 1;
        },
        .stub => {
            c.lua_createtable(L, 0, 0);
            return 1;
        },
    }
}

fn ctxSessionMessages(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    var limit: usize = 50;
    var include_tools = true;
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 1, "limit");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw > 0) limit = @intCast(@min(raw, 500));
        }
        c.lua_pop(L, 1);
        _ = c.lua_getfield(L, 1, "include_tools");
        if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) include_tools = c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);
    }
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_messages_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, limit, include_tools) orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            defer json_util.freeJsonValue(runner.allocator, value);
            lua_runtime.pushJsonValue(L, value) catch c.lua_createtable(L, 0, 0);
            return 1;
        },
        .stub => {
            c.lua_createtable(L, 0, 0);
            return 1;
        },
    }
}

fn ctxSessionAppendNote(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    if (c.lua_type(L, 1) != c.LUA_TTABLE) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    const idx = c.lua_absindex(L, 1);
    const kind = readBorrowedStringField(L, idx, "kind") orelse "note";
    const body = readBorrowedStringField(L, idx, "body") orelse {
        c.lua_pushboolean(L, 0);
        return 1;
    };
    const title = readBorrowedStringField(L, idx, "title");
    const source_entry_id = readBorrowedStringField(L, idx, "source_entry_id") orelse readBorrowedStringField(L, idx, "sourceEntryId");
    switch (runner.runtime) {
        .bound => |bound| {
            const append = bound.session_note_append orelse {
                c.lua_pushboolean(L, 0);
                return 1;
            };
            append(bound.session, kind, title, body, source_entry_id) catch {
                c.lua_pushboolean(L, 0);
                return 1;
            };
            c.lua_pushboolean(L, 1);
            return 1;
        },
        .stub => {
            c.lua_pushboolean(L, 0);
            return 1;
        },
    }
}

fn ctxSessionNotes(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    var limit: usize = 50;
    var kind: ?[]const u8 = null;
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, 1);
        kind = readBorrowedStringField(L, idx, "kind");
        _ = c.lua_getfield(L, idx, "limit");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw > 0) limit = @intCast(@min(raw, 500));
        }
        c.lua_pop(L, 1);
    }
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_notes_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, kind, limit) orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            defer json_util.freeJsonValue(runner.allocator, value);
            lua_runtime.pushJsonValue(L, value) catch c.lua_createtable(L, 0, 0);
            return 1;
        },
        .stub => {
            c.lua_createtable(L, 0, 0);
            return 1;
        },
    }
}

fn readBorrowedStringField(L: *c.lua_State, table_idx: c_int, field: [:0]const u8) ?[]const u8 {
    _ = c.lua_getfield(L, table_idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return null;
    return ptr[0..len];
}

fn ctxAiComplete(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const request = parseAiCompleteRequest(runner.allocator, L) catch {
        pushAiCompleteError(L, "ctx.ai.complete: invalid request");
        return 1;
    };
    const id = runner.beginAiCompleteAsync(request);
    return c.lua_yieldk(L, 0, @intCast(id), ctxAiCompleteContinue);
}

fn ctxAiCompleteContinue(L_opt: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id: runner_mod.AsyncOpId = @intCast(ctx);
    var result = runner.takeCompletedAsync(id) orelse {
        pushAiCompleteError(L, "ctx.ai.complete: missing async result");
        return 1;
    };
    defer result.deinit(runner.allocator);
    switch (result) {
        .ai_complete => |value| pushAiCompleteResult(L, value),
        else => pushAiCompleteError(L, "ctx.ai.complete: unexpected async result"),
    }
    return 1;
}

fn readModelRefArg(L: *c.lua_State) ?[]const u8 {
    if (c.lua_type(L, 1) == c.LUA_TSTRING) {
        var len: usize = 0;
        const ptr = c.lua_tolstring(L, 1, &len) orelse return null;
        return ptr[0..len];
    }
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, 1);
        return readBorrowedStringField(L, idx, "id");
    }
    return null;
}

fn parseAiCompleteRequest(allocator: std.mem.Allocator, L: *c.lua_State) !runner_mod.AiCompleteRequest {
    if (c.lua_type(L, 1) == c.LUA_TSTRING) {
        const prompt = try dupeLuaString(allocator, L, 1);
        return .{ .prompt = prompt };
    }
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return error.InvalidRequest;
    const idx = c.lua_absindex(L, 1);
    _ = c.lua_getfield(L, idx, "prompt");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidRequest;
    const prompt = try dupeLuaString(allocator, L, -1);
    errdefer allocator.free(prompt);

    var system_prompt: ?[]const u8 = null;
    _ = c.lua_getfield(L, idx, "system_prompt");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) system_prompt = try dupeLuaString(allocator, L, -1);
    c.lua_pop(L, 1);
    errdefer if (system_prompt) |value| allocator.free(value);

    var model: ?[]const u8 = null;
    _ = c.lua_getfield(L, idx, "model");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        model = try dupeLuaString(allocator, L, -1);
    } else if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        const model_idx = c.lua_absindex(L, -1);
        if (readBorrowedStringField(L, model_idx, "id")) |id| {
            if (readBorrowedStringField(L, model_idx, "provider")) |provider| {
                model = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, id });
            } else {
                model = try allocator.dupe(u8, id);
            }
        }
    }
    c.lua_pop(L, 1);
    errdefer if (model) |value| allocator.free(value);

    const reasoning = try readAiCompleteReasoning(L, idx);

    var max_tokens: ?u64 = null;
    _ = c.lua_getfield(L, idx, "max_tokens");
    if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
        const raw = c.lua_tointegerx(L, -1, null);
        if (raw > 0) max_tokens = @intCast(raw);
    }
    c.lua_pop(L, 1);

    return .{ .prompt = prompt, .system_prompt = system_prompt, .max_tokens = max_tokens, .model = model, .reasoning = reasoning };
}

fn readAiCompleteReasoning(L: *c.lua_State, table_idx: c_int) !?agent_protocol.ThinkingLevel {
    _ = c.lua_getfield(L, table_idx, "reasoning");
    defer c.lua_pop(L, 1);
    switch (c.lua_type(L, -1)) {
        c.LUA_TNONE, c.LUA_TNIL => return null,
        c.LUA_TBOOLEAN => return if (c.lua_toboolean(L, -1) != 0) .high else .off,
        c.LUA_TSTRING => {
            var len: usize = 0;
            const ptr = c.lua_tolstring(L, -1, &len) orelse return error.InvalidReasoning;
            const value = ptr[0..len];
            if (std.mem.eql(u8, value, "off")) return .off;
            if (std.mem.eql(u8, value, "minimal")) return .minimal;
            if (std.mem.eql(u8, value, "low")) return .low;
            if (std.mem.eql(u8, value, "medium")) return .medium;
            if (std.mem.eql(u8, value, "high")) return .high;
            if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
            return error.InvalidReasoning;
        },
        else => return error.InvalidReasoning,
    }
}

fn pushAiCompleteResult(L: *c.lua_State, result: runner_mod.AiCompleteResult) void {
    c.lua_createtable(L, 0, 2);
    switch (result) {
        .completed => |completed| {
            _ = c.lua_pushlstring(L, "completed", "completed".len);
            c.lua_setfield(L, -2, "status");
            _ = c.lua_pushlstring(L, completed.text.ptr, completed.text.len);
            c.lua_setfield(L, -2, "text");
        },
        .err => |msg| {
            _ = c.lua_pushlstring(L, "error", "error".len);
            c.lua_setfield(L, -2, "status");
            _ = c.lua_pushlstring(L, msg.ptr, msg.len);
            c.lua_setfield(L, -2, "error");
        },
        .cancelled => {
            _ = c.lua_pushlstring(L, "cancelled", "cancelled".len);
            c.lua_setfield(L, -2, "status");
        },
    }
}

fn pushAiCompleteError(L: *c.lua_State, msg: []const u8) void {
    c.lua_createtable(L, 0, 2);
    _ = c.lua_pushlstring(L, "error", "error".len);
    c.lua_setfield(L, -2, "status");
    _ = c.lua_pushlstring(L, msg.ptr, msg.len);
    c.lua_setfield(L, -2, "error");
}

fn ctxTestAsync(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id = runner.beginTestAsync();
    return c.lua_yieldk(L, 0, @intCast(id), ctxTestAsyncContinue);
}

fn ctxTestAsyncContinue(L_opt: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id: runner_mod.AsyncOpId = @intCast(ctx);
    var result = runner.takeCompletedAsync(id) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    defer result.deinit(runner.allocator);
    switch (result) {
        .@"test" => |value| {
            _ = c.lua_pushlstring(L, value.ptr, value.len);
        },
        else => c.lua_pushnil(L),
    }
    return 1;
}

fn pushContextBinding(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) void {
    const prov = provenance orelse {
        c.lua_pushnil(L);
        return;
    };

    switch (runner.runtime) {
        .bound => |bound| {
            const binding = bound.get_binding_info(bound.session);
            pushBinding(L, prov, runner.generation, binding.workspace_id, binding.session_id, binding.session_file);
        },
        .stub => c.lua_pushnil(L),
    }
}

pub fn pushBinding(
    L: *c.lua_State,
    provenance: resource_types.ExtensionProvenance,
    generation: runner_mod.Generation,
    workspace_id: []const u8,
    session_id: []const u8,
    session_file: ?[]const u8,
) void {
    c.lua_createtable(L, 0, 7);

    _ = c.lua_pushlstring(L, provenance.runtime_root_id.ptr, provenance.runtime_root_id.len);
    c.lua_setfield(L, -2, "runtime_root_id");

    _ = c.lua_pushlstring(L, provenance.state_owner_id.ptr, provenance.state_owner_id.len);
    c.lua_setfield(L, -2, "state_owner_id");

    c.lua_pushinteger(L, @intCast(generation));
    c.lua_setfield(L, -2, "generation_id");

    pushNamespaceId(L, provenance.state_owner_id, generation);
    c.lua_setfield(L, -2, "namespace_id");

    _ = c.lua_pushlstring(L, workspace_id.ptr, workspace_id.len);
    c.lua_setfield(L, -2, "workspace_id");

    _ = c.lua_pushlstring(L, session_id.ptr, session_id.len);
    c.lua_setfield(L, -2, "session_id");

    if (session_file) |path| {
        if (path.len > 0) {
            _ = c.lua_pushlstring(L, path.ptr, path.len);
            c.lua_setfield(L, -2, "session_file");
        }
    }
}

fn pushNamespaceId(
    L: *c.lua_State,
    state_owner_id: []const u8,
    generation: runner_mod.Generation,
) void {
    var generation_buf: [32]u8 = undefined;
    const generation_str = std.fmt.bufPrint(&generation_buf, "{d}", .{generation}) catch unreachable;

    _ = c.lua_pushlstring(L, state_owner_id.ptr, state_owner_id.len);
    _ = c.lua_pushlstring(L, "::".ptr, 2);
    _ = c.lua_pushlstring(L, generation_str.ptr, generation_str.len);
    c.lua_concat(L, 3);
}

fn pushMethod(L: *c.lua_State, runner: *runner_mod.ExtensionRunner, func: *const fn (?*c.lua_State) callconv(.c) c_int) void {
    c.lua_pushlightuserdata(L, runner);
    c.lua_pushcclosure(L, func, 1);
}

pub fn pushModel(L: *c.lua_State, model: agent_protocol.Model) void {
    c.lua_createtable(L, 0, 8);
    _ = c.lua_pushlstring(L, model.id.ptr, model.id.len);
    c.lua_setfield(L, -2, "id");
    _ = c.lua_pushlstring(L, model.name.ptr, model.name.len);
    c.lua_setfield(L, -2, "name");
    const provider = json_util.providerToString(model.provider);
    _ = c.lua_pushlstring(L, provider.ptr, provider.len);
    c.lua_setfield(L, -2, "provider");
    const api = ai_provider.apiToString(model.api);
    _ = c.lua_pushlstring(L, api.ptr, api.len);
    c.lua_setfield(L, -2, "api");
    c.lua_pushinteger(L, @intCast(model.context_window));
    c.lua_setfield(L, -2, "context_window");
    c.lua_pushinteger(L, @intCast(model.max_tokens));
    c.lua_setfield(L, -2, "max_tokens");
    c.lua_pushboolean(L, if (model.reasoning) 1 else 0);
    c.lua_setfield(L, -2, "reasoning");
}

fn pushContextUsage(L: *c.lua_State, usage: session_core.context_usage.ContextUsage) void {
    c.lua_createtable(L, 0, 3);
    if (usage.tokens) |tokens| {
        c.lua_pushinteger(L, @intCast(tokens));
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "tokens");
    c.lua_pushinteger(L, @intCast(usage.context_window));
    c.lua_setfield(L, -2, "context_window");
    if (usage.percent) |percent| {
        c.lua_pushnumber(L, percent);
    } else {
        c.lua_pushnil(L);
    }
    c.lua_setfield(L, -2, "percent");
}

fn runnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ud.?));
}

fn ctxIsIdle(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| c.lua_pushboolean(L, if (bound.is_idle(bound.session)) 1 else 0),
        .stub => c.lua_pushboolean(L, 1),
    }
    return 1;
}

fn ctxAbort(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| bound.abort(bound.session),
        .stub => {},
    }
    return 0;
}

fn ctxHasPendingMessages(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| c.lua_pushboolean(L, if (bound.has_pending_messages(bound.session)) 1 else 0),
        .stub => c.lua_pushboolean(L, 0),
    }
    return 1;
}

fn ctxShutdown(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| if (bound.shutdown) |func| func(bound.session),
        .stub => {},
    }
    return 0;
}

fn ctxGetContextUsage(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            if (bound.get_context_usage(bound.session)) |usage| {
                pushContextUsage(L, usage);
            } else {
                c.lua_pushnil(L);
            }
        },
        .stub => c.lua_pushnil(L),
    }
    return 1;
}

fn ctxGetSystemPrompt(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            const prompt = bound.get_system_prompt(bound.session);
            _ = c.lua_pushlstring(L, prompt.ptr, prompt.len);
        },
        .stub => _ = c.lua_pushlstring(L, "".ptr, 0),
    }
    return 1;
}

/// Push the extension context table for command handlers.
///
/// Command handlers receive the same base context as tool/event
/// handlers plus command-only fields. In this slice those fields
/// are absent/nil because session-control actions are not yet safe
/// inside command bodies (they may destroy the live runner while
/// the coroutine is still executing).
pub fn pushCommandContext(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) !void {
    try pushExtensionContext(L, runner, provenance);

    // Command-only session-control fields: all nil in this slice.
    // They are explicitly present (rather than absent) so extension
    // code that probes `ctx.new_session` sees nil and gets a clean
    // "attempt to call a nil value" error instead of a missing-key
    // diagnostic.
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "wait_for_idle");
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "new_session");
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "fork");
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "navigate_tree");
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "switch_session");
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "reload");
}
