const std = @import("std");
const lua_runtime = @import("lua_runtime.zig");
const runner_mod = @import("runner.zig");
const lua_agent_serializers = @import("lua_agent_serializers.zig");
const resource_types = @import("../resources/types.zig");
const json_util = @import("../../ai/json_util.zig");
const agent_protocol = @import("../../agent/types.zig");
const session_core = @import("../../session/root.zig");
const extension_ui = @import("ui.zig");
const request_mod = @import("../request.zig");
const ai_provider = @import("../../ai/provider.zig");
const abort_signal_mod = @import("../../zio/root.zig");

const c = lua_runtime.c;
const limits = @import("limits.zig");

const ui_id_bytes: usize = limits.ui_id_bytes;
const ui_text_bytes: usize = limits.ui_text_bytes;
const truncated_marker = "\n... [extension UI text truncated] ...";

pub fn pushExtensionContext(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) !void {
    c.lua_createtable(L, 0, 14);

    _ = c.lua_pushlstring(L, runner.cwd.ptr, runner.cwd.len);
    c.lua_setfield(L, -2, "cwd");

    const has_ui = switch (runner.runtime) {
        .bound => |bound| bound.publish_render != null or bound.publish_frame != null,
        .stub => false,
    };
    c.lua_pushboolean(L, if (has_ui) 1 else 0);
    c.lua_setfield(L, -2, "has_ui");

    pushUiApi(L, runner, provenance);
    c.lua_setfield(L, -2, "ui");

    pushEditorApi(L, runner, provenance);
    c.lua_setfield(L, -2, "editor");

    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "signal");

    pushSessionApi(L, runner, provenance);
    c.lua_setfield(L, -2, "session");

    pushAiApi(L, runner);
    c.lua_setfield(L, -2, "ai");

    pushContextBinding(L, runner, provenance);
    c.lua_setfield(L, -2, "binding");

    pushExtensionInfo(L, runner, provenance);
    c.lua_setfield(L, -2, "extension");

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

            pushMethod(L, runner, &ctxSendUserMessage);
            c.lua_setfield(L, -2, "send_user_message");

            pushMethod(L, runner, &ctxHasPendingMessages);
            c.lua_setfield(L, -2, "has_pending_messages");

            if (bound.shutdown != null) {
                pushMethod(L, runner, &ctxShutdown);
            } else {
                c.lua_pushnil(L);
            }
            c.lua_setfield(L, -2, "shutdown");

            pushMethod(L, runner, &ctxContextUsage);
            c.lua_setfield(L, -2, "context_usage");

            pushMethod(L, runner, &ctxSystemPrompt);
            c.lua_setfield(L, -2, "system_prompt");
        },
        .stub => {
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "models");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "is_idle");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "abort");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "send_user_message");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "has_pending_messages");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "shutdown");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "context_usage");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "system_prompt");
        },
    }
}

fn pushExtensionInfo(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) void {
    const prov = provenance orelse {
        c.lua_pushnil(L);
        return;
    };
    const info = runner.findLoadedExtensionInfoByStateOwner(prov.state_owner_id) orelse {
        c.lua_pushnil(L);
        return;
    };

    c.lua_createtable(L, 0, 4);
    pushContextStringField(L, "id", info.id);
    pushContextStringField(L, "source", info.source);
    pushContextStringField(L, "entry", info.entry_path);
    pushContextStringField(L, "root", info.root_path);
}

fn pushContextStringField(L: *c.lua_State, field: [:0]const u8, value: []const u8) void {
    _ = c.lua_pushlstring(L, value.ptr, value.len);
    c.lua_setfield(L, -2, field.ptr);
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
        .bound => |bound| bound.publish_render != null or bound.publish_frame != null,
        .stub => false,
    };
    if (!has_methods) {
        c.lua_pushnil(L);
        return;
    }

    c.lua_createtable(L, 0, 5);
    pushUiMethod(L, runner, prov.state_owner_id, &ctxUiRender);
    c.lua_setfield(L, -2, "render");
    pushUiMethod(L, runner, prov.state_owner_id, &ctxUiFrame);
    c.lua_setfield(L, -2, "frame");
    pushUiMethod(L, runner, prov.state_owner_id, &ctxUiNotify);
    c.lua_setfield(L, -2, "notify");
    pushUiMethod(L, runner, prov.state_owner_id, &ctxUiNotifyClear);
    c.lua_setfield(L, -2, "notify_clear");
    pushUiMethod(L, runner, prov.state_owner_id, &ctxUiProgress);
    c.lua_setfield(L, -2, "progress");
}

fn pushEditorApi(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) void {
    const prov = provenance orelse {
        c.lua_pushnil(L);
        return;
    };

    const has_editor = switch (runner.runtime) {
        .bound => |bound| bound.publish_editor_action != null,
        .stub => false,
    };
    if (!has_editor) {
        c.lua_pushnil(L);
        return;
    }

    c.lua_createtable(L, 0, 3);
    pushUiMethod(L, runner, prov.state_owner_id, &ctxEditorSetText);
    c.lua_setfield(L, -2, "set_text");
    pushUiMethod(L, runner, prov.state_owner_id, &ctxEditorInsertText);
    c.lua_setfield(L, -2, "insert_text");
    pushUiMethod(L, runner, prov.state_owner_id, &ctxEditorClear);
    c.lua_setfield(L, -2, "clear");
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

fn stateRunnerFromUpvalue(L: *c.lua_State) *runner_mod.ExtensionRunner {
    const ud = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(ud.?));
}

fn stateOwnerFromUpvalue(L: *c.lua_State) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, c.lua_upvalueindex(2), &len) orelse return &.{};
    return ptr[0..len];
}

fn ctxEditorSetText(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishEditorActionFromArgs(L, .set_text) catch {};
    return 0;
}

fn ctxEditorInsertText(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishEditorActionFromArgs(L, .paste_text) catch {};
    return 0;
}

fn ctxEditorClear(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishEditorActionFromArgs(L, .clear_text) catch {};
    return 0;
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

fn ctxUiRender(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishRenderFromArgs(L) catch {};
    return 0;
}

fn ctxUiFrame(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishFrameFromArgs(L) catch {};
    return 0;
}

fn ctxUiNotify(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    publishNotifyFromArgs(L) catch {};
    return 0;
}

fn ctxUiNotifyClear(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    if (c.lua_type(L, 1) == c.LUA_TSTRING) {
        c.lua_createtable(L, 0, 2);
        c.lua_pushvalue(L, 1);
        c.lua_setfield(L, -2, "id");
        c.lua_pushboolean(L, 1);
        c.lua_setfield(L, -2, "clear");
        _ = c.lua_pushliteral(L, "");
        c.lua_replace(L, 1);
        c.lua_replace(L, 2);
    } else if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        c.lua_pushboolean(L, 1);
        c.lua_setfield(L, 1, "clear");
        _ = c.lua_pushliteral(L, "");
        c.lua_insert(L, 1);
    }
    publishNotifyFromArgs(L) catch {};
    return 0;
}

fn ctxUiProgress(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;

    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 1, "message");
        if (c.lua_type(L, -1) != c.LUA_TSTRING) {
            c.lua_pop(L, 1);
            _ = c.lua_pushliteral(L, "working");
        }
        c.lua_pushvalue(L, 1);
        c.lua_pushboolean(L, 1);
        c.lua_setfield(L, -2, "progress");
        c.lua_remove(L, 1);
        publishNotifyFromArgs(L) catch {};
    }
    c.lua_createtable(L, 0, 3);
    pushUiMethod(L, stateRunnerFromUpvalue(L), stateOwnerFromUpvalue(L), &ctxUiNotify);
    c.lua_setfield(L, -2, "update");
    pushUiMethod(L, stateRunnerFromUpvalue(L), stateOwnerFromUpvalue(L), &ctxUiNotify);
    c.lua_setfield(L, -2, "finish");
    pushUiMethod(L, stateRunnerFromUpvalue(L), stateOwnerFromUpvalue(L), &ctxUiNotifyClear);
    c.lua_setfield(L, -2, "clear");
    return 1;
}

fn publishNotifyFromArgs(L: *c.lua_State) !void {
    const runner = stateRunnerFromUpvalue(L);
    const bound = switch (runner.runtime) {
        .bound => |bound| bound,
        .stub => return,
    };
    const callback = bound.publish_render orelse return;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const message = if (c.lua_type(L, 1) == c.LUA_TSTRING) luaString(L, 1) orelse "" else "";
    const opts_idx: c_int = if (c.lua_type(L, 2) == c.LUA_TTABLE) c.lua_absindex(L, 2) else 0;
    const fallback_id = if (message.len > 0) message else "notification";
    const id = if (opts_idx != 0) try readStringFieldLimit(aa, L, opts_idx, "id", fallback_id, ui_id_bytes) else try aa.dupe(u8, fallback_id[0..@min(fallback_id.len, ui_id_bytes)]);
    const level = if (opts_idx != 0) try readNotifyLevelField(L, opts_idx, "level") else extension_ui.NotifyLevel.info;
    const group = if (opts_idx != 0) try readOptionalStringFieldLimit(aa, L, opts_idx, "group", ui_id_bytes) else null;
    const title = if (opts_idx != 0) try readOptionalStringFieldLimit(aa, L, opts_idx, "title", ui_text_bytes) else null;
    const annote = if (opts_idx != 0) try readOptionalStringFieldLimit(aa, L, opts_idx, "annote", ui_text_bytes) else null;
    const clear = if (opts_idx != 0) readBoolField(L, opts_idx, "clear", false) else false;
    const done = if (opts_idx != 0) readBoolField(L, opts_idx, "done", false) else false;
    const progress = if (opts_idx != 0) readBoolField(L, opts_idx, "progress", false) else false;
    const ttl_ms = if (opts_idx != 0) readOptionalU32Field(L, opts_idx, "ttl_ms") orelse readOptionalSecondsAsMsField(L, opts_idx, "ttl") else null;
    const lifetime = notifyLifetime(ttl_ms, progress, done);
    const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()));

    const notify = extension_ui.NotifySpec{ .state_owner_id = try aa.dupe(u8, stateOwnerFromUpvalue(L)), .generation = runner.generation, .id = id, .message = try aa.dupe(u8, message), .group = group, .title = title, .annote = annote, .level = level, .progress = progress, .done = done, .clear = clear, .created_ns = now_ns, .updated_ns = now_ns, .lifetime = lifetime };
    const spec = extension_ui.RenderSpec{ .state_owner_id = notify.state_owner_id, .generation = notify.generation, .id = notify.id, .slot = .notification, .order = 0, .remove = notify.clear, .root = null, .notification = notify };
    try callback(bound.session, spec);
}

fn notifyLifetime(ttl_ms: ?u32, progress: bool, done: bool) @import("../../tui/notifications.zig").Lifetime {
    const Lifetime = @import("../../tui/notifications.zig").Lifetime;
    if (ttl_ms) |ms| {
        if (ms != 0) return .{ .ttl_ms = ms };
    }
    if (done) return Lifetime.doneDefault();
    if (progress) return Lifetime.progressDefault();
    return Lifetime.default();
}

fn publishRenderFromArgs(L: *c.lua_State) !void {
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return;
    const runner = stateRunnerFromUpvalue(L);
    const bound = switch (runner.runtime) {
        .bound => |bound| bound,
        .stub => return,
    };
    const callback = bound.publish_render orelse return;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const spec_idx = c.lua_absindex(L, 1);
    if (hasField(L, spec_idx, "title")) return error.InvalidUiRenderTitle;
    const slot = try readSlotField(L, spec_idx);
    const spec = extension_ui.RenderSpec{
        .state_owner_id = try aa.dupe(u8, stateOwnerFromUpvalue(L)),
        .generation = runner.generation,
        .id = try readStringFieldLimit(aa, L, spec_idx, "id", "root", ui_id_bytes),
        .slot = slot.kind,
        .slot_options = slot.options,
        .order = readIntField(L, spec_idx, "order", 0),
        .focus = readBoolField(L, spec_idx, "focus", false),
        .remove = readBoolField(L, spec_idx, "remove", false),
        .root = try readOptionalNodeField(aa, L, spec_idx, "root"),
        .keys = try readKeysField(aa, L, spec_idx),
    };
    try callback(bound.session, spec);
}

fn publishFrameFromArgs(L: *c.lua_State) !void {
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return;
    const runner = stateRunnerFromUpvalue(L);
    const bound = switch (runner.runtime) {
        .bound => |bound| bound,
        .stub => return,
    };
    const callback = bound.publish_frame orelse return;

    var arena = std.heap.ArenaAllocator.init(runner.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const spec_idx = c.lua_absindex(L, 1);
    const view = try readStringFieldLimit(aa, L, spec_idx, "view", "root", ui_id_bytes);
    const spec = extension_ui.FrameSpec{
        .state_owner_id = try aa.dupe(u8, stateOwnerFromUpvalue(L)),
        .generation = runner.generation,
        .view = view,
        .node = try readStringFieldLimit(aa, L, spec_idx, "node", view, ui_id_bytes),
        .width = readU32Field(L, spec_idx, "width", 0),
        .height = readU32Field(L, spec_idx, "height", 0),
        .format = try readFrameFormatField(L, spec_idx),
        .data = try readStringFieldLimit(aa, L, spec_idx, "data", "", std.math.maxInt(usize)),
    };
    try spec.validate();
    try callback(bound.session, spec);
}

const ParsedSlot = struct { kind: extension_ui.UiSlot = .overlay, options: extension_ui.UiSlotOptions = .{} };

fn readSlotField(L: *c.lua_State, idx: c_int) !ParsedSlot {
    _ = c.lua_getfield(L, idx, "slot");
    defer c.lua_pop(L, 1);
    return switch (c.lua_type(L, -1)) {
        c.LUA_TSTRING => .{ .kind = try parseSlotKind(luaString(L, -1) orelse return .{}) },
        c.LUA_TTABLE => blk: {
            const tidx = c.lua_absindex(L, -1);
            const kind = try parseSlotKindField(L, tidx);
            var options: extension_ui.UiSlotOptions = .{};
            options.width = readConstraintField(L, tidx, "width");
            options.height = readConstraintField(L, tidx, "height");
            options.min_width = readConstraintField(L, tidx, "min_width");
            options.max_width = readConstraintField(L, tidx, "max_width");
            options.min_height = readConstraintField(L, tidx, "min_height");
            options.max_height = readConstraintField(L, tidx, "max_height");
            options.anchor = try readAnchorField(L, tidx, "anchor");
            options.backdrop = try readBackdropField(L, tidx, "backdrop");
            options.lifetime = try readLifetimeField(L, tidx, "lifetime");
            options.preset = try readOverlayPresetField(L, tidx, "preset");
            break :blk .{ .kind = kind, .options = options };
        },
        else => .{},
    };
}

fn parseSlotKindField(L: *c.lua_State, idx: c_int) !extension_ui.UiSlot {
    _ = c.lua_getfield(L, idx, "kind");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return .overlay;
    return try parseSlotKind(luaString(L, -1) orelse return .overlay);
}

fn parseSlotKind(value: []const u8) !extension_ui.UiSlot {
    if (std.mem.eql(u8, value, "overlay")) return .overlay;
    if (std.mem.eql(u8, value, "status")) return .status;
    if (std.mem.eql(u8, value, "notification")) return .notification;
    if (std.mem.eql(u8, value, "editor.border.top")) return .editor_border_top;
    if (std.mem.eql(u8, value, "editor.border.bottom")) return .editor_border_bottom;
    return error.InvalidUiSlot;
}

fn readNotifyLevelField(L: *c.lua_State, idx: c_int, field: [:0]const u8) !extension_ui.NotifyLevel {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return .info;
    const value = luaString(L, -1) orelse return .info;
    if (std.mem.eql(u8, value, "debug")) return .debug;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "warn") or std.mem.eql(u8, value, "warning")) return .warn;
    if (std.mem.eql(u8, value, "error") or std.mem.eql(u8, value, "danger")) return .error_;
    if (std.mem.eql(u8, value, "success")) return .success;
    return error.InvalidNotifyLevel;
}

fn readAnchorField(L: *c.lua_State, idx: c_int, field: [:0]const u8) !?extension_ui.UiAnchor {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    const value = luaString(L, -1) orelse return null;
    if (std.mem.eql(u8, value, "center")) return .center;
    if (std.mem.eql(u8, value, "top_left")) return .top_left;
    if (std.mem.eql(u8, value, "top_right")) return .top_right;
    if (std.mem.eql(u8, value, "bottom_left")) return .bottom_left;
    if (std.mem.eql(u8, value, "bottom_right")) return .bottom_right;
    if (std.mem.eql(u8, value, "top_center")) return .top_center;
    if (std.mem.eql(u8, value, "bottom_center")) return .bottom_center;
    return error.InvalidUiAnchor;
}

fn readBackdropField(L: *c.lua_State, idx: c_int, field: [:0]const u8) !?extension_ui.UiBackdrop {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    const value = luaString(L, -1) orelse return null;
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "dim")) return .dim;
    if (std.mem.eql(u8, value, "fill")) return .fill;
    return error.InvalidUiBackdrop;
}

fn readOverlayPresetField(L: *c.lua_State, idx: c_int, field: [:0]const u8) !?extension_ui.UiOverlayPreset {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    const value = luaString(L, -1) orelse return null;
    return extension_ui.UiOverlayPreset.parse(value) orelse error.InvalidUiOverlayPreset;
}

fn readLifetimeField(L: *c.lua_State, idx: c_int, field: [:0]const u8) !?extension_ui.UiLifetime {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    const value = luaString(L, -1) orelse return null;
    if (std.mem.eql(u8, value, "until_input")) return .until_input;
    if (std.mem.eql(u8, value, "manual")) return .manual;
    return error.InvalidUiLifetime;
}

fn luaString(L: *c.lua_State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return null;
    return ptr[0..len];
}

fn readFrameFormatField(L: *c.lua_State, idx: c_int) !extension_ui.FrameFormat {
    _ = c.lua_getfield(L, idx, "format");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return .rgba8888;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, -1, &len) orelse return .rgba8888;
    const value = ptr[0..len];
    if (std.mem.eql(u8, value, "rgba8888")) return .rgba8888;
    if (std.mem.eql(u8, value, "halfblock_rgb")) return .halfblock_rgb;
    return error.InvalidFrameFormat;
}

fn readOptionalNodeField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, field: [:0]const u8) !?extension_ui.UiNode {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return null;
    return try readNode(arena, L, c.lua_absindex(L, -1));
}

fn readNode(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !extension_ui.UiNode {
    const typ = try readStringFieldLimit(arena, L, idx, "type", "view", 32);
    const style = try readStyleField(arena, L, idx);
    const id = try readOptionalStringFieldLimit(arena, L, idx, "id", ui_id_bytes);
    if (std.mem.eql(u8, typ, "text")) {
        const spans = try readTextSpansField(arena, L, idx);
        const text = if (spans) |items| try concatSpansText(arena, items) else try readStringFieldLimit(arena, L, idx, "text", "", ui_text_bytes);
        return .{ .text = .{ .id = id, .text = text, .spans = spans, .style = style, .wrap = try readTextWrapField(L, idx), .overflow = try readTextOverflowField(L, idx), .format = try readTextFormatField(L, idx), .@"align" = try readTextAlignField(L, idx), .max_lines = readOptionalU32Field(L, idx, "max_lines"), .scroll_y = readU32Field(L, idx, "scroll_y", 0), .scroll_x = readU32Field(L, idx, "scroll_x", 0), .link = try readOptionalStringFieldLimit(arena, L, idx, "link", ui_text_bytes), .selectable = readBoolField(L, idx, "selectable", false) } };
    }
    if (std.mem.eql(u8, typ, "chip")) return .{ .chip = .{ .id = id, .label = try readStringFieldLimit(arena, L, idx, "label", "", ui_text_bytes), .style = style } };
    if (std.mem.eql(u8, typ, "progress")) return .{ .progress = .{ .id = id, .value = readOptionalFloatField(L, idx, "value"), .label = try readOptionalStringFieldLimit(arena, L, idx, "label", ui_text_bytes), .style = style } };
    if (std.mem.eql(u8, typ, "separator")) return .{ .separator = .{ .id = id, .style = style } };
    if (std.mem.eql(u8, typ, "surface")) return .{ .surface = .{ .id = try readStringFieldLimit(arena, L, idx, "id", "surface", ui_id_bytes), .style = style } };
    if (std.mem.eql(u8, typ, "input")) return .{ .input = .{
        .id = try readStringFieldLimit(arena, L, idx, "id", "input", ui_id_bytes),
        .value = try readStringFieldLimit(arena, L, idx, "value", "", ui_text_bytes),
        .placeholder = try readOptionalStringFieldLimit(arena, L, idx, "placeholder", ui_text_bytes),
        .style = style,
        .on_input = try readOptionalStringFieldLimit(arena, L, idx, "on_input", ui_id_bytes),
        .on_change = try readOptionalStringFieldLimit(arena, L, idx, "on_change", ui_id_bytes),
        .on_submit = try readOptionalStringFieldLimit(arena, L, idx, "on_submit", ui_id_bytes),
    } };
    var children: []extension_ui.UiNode = &.{};
    _ = c.lua_getfield(L, idx, "children");
    if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        const len = c.lua_rawlen(L, -1);
        children = try arena.alloc(extension_ui.UiNode, len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            _ = c.lua_rawgeti(L, -1, @intCast(i + 1));
            defer c.lua_pop(L, 1);
            children[i] = if (c.lua_type(L, -1) == c.LUA_TTABLE) try readNode(arena, L, c.lua_absindex(L, -1)) else .{ .text = .{ .text = "" } };
        }
    }
    c.lua_pop(L, 1);
    if (!std.mem.eql(u8, typ, "view")) return error.InvalidUiNodeType;
    return .{ .view = .{ .id = id, .style = style, .children = children } };
}

fn readTextSpansField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !?[]extension_ui.TextSpan {
    _ = c.lua_getfield(L, idx, "spans");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return null;
    const spans_idx = c.lua_absindex(L, -1);
    const len = c.lua_rawlen(L, spans_idx);
    const spans = try arena.alloc(extension_ui.TextSpan, len);
    for (0..len) |i| {
        _ = c.lua_rawgeti(L, spans_idx, @intCast(i + 1));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            const span_idx = c.lua_absindex(L, -1);
            spans[i] = .{
                .text = try readStringFieldLimit(arena, L, span_idx, "text", "", ui_text_bytes),
                .style = try readOptionalStyleField(arena, L, span_idx, "style"),
                .link = try readOptionalStringFieldLimit(arena, L, span_idx, "link", ui_text_bytes),
            };
        } else {
            spans[i] = .{ .text = try arena.dupe(u8, "") };
        }
    }
    return spans;
}

fn concatSpansText(arena: std.mem.Allocator, spans: []const extension_ui.TextSpan) ![]const u8 {
    var total: usize = 0;
    for (spans) |span| total += span.text.len;

    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(arena);
    for (spans) |span| {
        try joined.appendSlice(arena, span.text);
        if (joined.items.len > ui_text_bytes) break;
    }
    return truncateBytesWithMarker(arena, joined.items, ui_text_bytes, truncated_marker);
}

fn readTextWrapField(L: *c.lua_State, idx: c_int) !extension_ui.TextWrap {
    return readEnumField(extension_ui.TextWrap, L, idx, "wrap", .word, error.InvalidTextWrap);
}

fn readTextAlignField(L: *c.lua_State, idx: c_int) !extension_ui.TextAlign {
    return readEnumField(extension_ui.TextAlign, L, idx, "align", .left, error.InvalidTextAlign);
}

fn readTextOverflowField(L: *c.lua_State, idx: c_int) !extension_ui.TextOverflow {
    return readEnumField(extension_ui.TextOverflow, L, idx, "overflow", .clip, error.InvalidTextOverflow);
}

fn readTextFormatField(L: *c.lua_State, idx: c_int) !extension_ui.TextFormat {
    return readEnumField(extension_ui.TextFormat, L, idx, "format", .plain, error.InvalidTextFormat);
}

fn readStyleField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !extension_ui.Style {
    return (try readOptionalStyleField(arena, L, idx, "style")) orelse .{};
}

fn readOptionalStyleField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, field: [:0]const u8) !?extension_ui.Style {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return null;
    return try readStyleTable(arena, L, c.lua_absindex(L, -1));
}

fn readStyleTable(arena: std.mem.Allocator, L: *c.lua_State, sidx: c_int) !extension_ui.Style {
    var style: extension_ui.Style = .{};
    if (hasField(L, sidx, "border")) return error.InvalidUiStyleBorder;
    style.flex_grow = readFloatField(L, sidx, "flex_grow", style.flex_grow);
    style.gap = readFloatField(L, sidx, "gap", style.gap);
    style.chrome = try readChromeField(arena, L, sidx);
    style.padding = .{ .top = readFloatField(L, sidx, "padding", 0), .right = readFloatField(L, sidx, "padding", 0), .bottom = readFloatField(L, sidx, "padding", 0), .left = readFloatField(L, sidx, "padding", 0) };
    style.width = readConstraintField(L, sidx, "width");
    style.height = readConstraintField(L, sidx, "height");
    if (try readOptionalStringFieldLimit(std.heap.c_allocator, L, sidx, "flex_direction", 16)) |dir| {
        defer std.heap.c_allocator.free(dir);
        if (std.mem.eql(u8, dir, "row")) style.flex_direction = .row;
    }
    if (try readOptionalStringFieldLimit(std.heap.c_allocator, L, sidx, "tone", 16)) |tone| {
        defer std.heap.c_allocator.free(tone);
        if (std.mem.eql(u8, tone, "muted")) style.tone = .muted else if (std.mem.eql(u8, tone, "info")) style.tone = .info else if (std.mem.eql(u8, tone, "success")) style.tone = .success else if (std.mem.eql(u8, tone, "warning")) style.tone = .warning else if (std.mem.eql(u8, tone, "danger")) style.tone = .danger else if (std.mem.eql(u8, tone, "accent")) style.tone = .accent;
    }
    style.fg = try readColorField(L, sidx, "fg");
    style.bg = try readColorField(L, sidx, "bg");
    style.bold = readBoolField(L, sidx, "bold", style.bold);
    style.dim = readBoolField(L, sidx, "dim", style.dim);
    style.italic = readBoolField(L, sidx, "italic", style.italic);
    style.underline = readBoolField(L, sidx, "underline", style.underline);
    style.strikethrough = readBoolField(L, sidx, "strikethrough", style.strikethrough);
    return style;
}

fn readChromeField(arena: std.mem.Allocator, L: *c.lua_State, sidx: c_int) !extension_ui.Chrome {
    _ = c.lua_getfield(L, sidx, "chrome");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return .none;
    const cidx = c.lua_absindex(L, -1);
    const kind = try readStringFieldLimit(arena, L, cidx, "kind", "frame", 32);
    if (std.mem.eql(u8, kind, "none")) return .none;
    if (!std.mem.eql(u8, kind, "frame")) return error.InvalidUiChrome;
    return .{ .frame = .{
        .title = try readOptionalStringFieldLimit(arena, L, cidx, "title", ui_text_bytes),
        .trailing = try readOptionalStringFieldLimit(arena, L, cidx, "trailing", ui_text_bytes),
        .border = try readBorderStyleField(L, cidx),
        .tone = try readToneField(L, cidx, .muted),
    } };
}

fn readBorderStyleField(L: *c.lua_State, idx: c_int) !extension_ui.BorderStyle {
    _ = c.lua_getfield(L, idx, "border");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return .rounded;
    const value = luaString(L, -1) orelse return .rounded;
    if (std.mem.eql(u8, value, "rounded")) return .rounded;
    if (std.mem.eql(u8, value, "square")) return .square;
    return error.InvalidUiBorderStyle;
}

fn readToneField(L: *c.lua_State, idx: c_int, default: extension_ui.Tone) !extension_ui.Tone {
    _ = c.lua_getfield(L, idx, "tone");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return default;
    const value = luaString(L, -1) orelse return default;
    if (std.mem.eql(u8, value, "neutral")) return .neutral;
    if (std.mem.eql(u8, value, "muted")) return .muted;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "success")) return .success;
    if (std.mem.eql(u8, value, "warning")) return .warning;
    if (std.mem.eql(u8, value, "danger")) return .danger;
    if (std.mem.eql(u8, value, "accent")) return .accent;
    return error.InvalidUiTone;
}

fn readEnumField(comptime T: type, L: *c.lua_State, idx: c_int, field: [:0]const u8, default: T, invalid: anyerror) !T {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return default;
    const value = luaString(L, -1) orelse return default;
    inline for (@typeInfo(T).@"enum".fields) |enum_field| {
        if (std.mem.eql(u8, value, enum_field.name)) return @field(T, enum_field.name);
    }
    return invalid;
}

fn hasField(L: *c.lua_State, idx: c_int, field: [:0]const u8) bool {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return c.lua_type(L, -1) != c.LUA_TNIL;
}

fn readColorField(L: *c.lua_State, idx: c_int, field: [:0]const u8) !?extension_ui.Color {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    const value = luaString(L, -1) orelse return null;
    return try parseStyleColor(value);
}

fn parseStyleColor(value: []const u8) !extension_ui.Color {
    if (value.len == 4 and value[0] == '#') {
        const r = try parseHexNibble(value[1]);
        const g = try parseHexNibble(value[2]);
        const b = try parseHexNibble(value[3]);
        return extension_ui.Color.rgb(r * 17, g * 17, b * 17);
    }
    if (value.len == 7 and value[0] == '#') {
        return extension_ui.Color.rgb(try parseHexByte(value[1..3]), try parseHexByte(value[3..5]), try parseHexByte(value[5..7]));
    }
    if (std.mem.eql(u8, value, "black")) return extension_ui.Color.rgb(0, 0, 0);
    if (std.mem.eql(u8, value, "red")) return extension_ui.Color.rgb(205, 49, 49);
    if (std.mem.eql(u8, value, "green")) return extension_ui.Color.rgb(13, 188, 121);
    if (std.mem.eql(u8, value, "yellow")) return extension_ui.Color.rgb(229, 229, 16);
    if (std.mem.eql(u8, value, "blue")) return extension_ui.Color.rgb(36, 114, 200);
    if (std.mem.eql(u8, value, "magenta")) return extension_ui.Color.rgb(188, 63, 188);
    if (std.mem.eql(u8, value, "cyan")) return extension_ui.Color.rgb(17, 168, 205);
    if (std.mem.eql(u8, value, "white")) return extension_ui.Color.rgb(229, 229, 229);
    return error.InvalidStyleColor;
}

fn parseHexByte(bytes: []const u8) !u8 {
    return (try parseHexNibble(bytes[0])) * 16 + try parseHexNibble(bytes[1]);
}

fn parseHexNibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidStyleColor,
    };
}

fn readConstraintField(L: *c.lua_State, idx: c_int, field: [:0]const u8) ?extension_ui.Constraint {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return switch (c.lua_type(L, -1)) {
        c.LUA_TNUMBER => .{ .fixed = @floatCast(c.lua_tonumberx(L, -1, null)) },
        c.LUA_TSTRING => blk: {
            const v = luaString(L, -1) orelse break :blk null;
            if (std.mem.eql(u8, v, "fill")) break :blk .{ .fill = 1 };
            if (std.mem.eql(u8, v, "auto")) break :blk .{ .auto = {} };
            if (v.len > 1 and v[v.len - 1] == '%') {
                const n = std.fmt.parseFloat(f32, v[0 .. v.len - 1]) catch break :blk null;
                break :blk .{ .percent = n };
            }
            break :blk null;
        },
        else => null,
    };
}

fn readKeysField(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]extension_ui.KeyBinding {
    _ = c.lua_getfield(L, idx, "keys");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return &.{};
    const len = c.lua_rawlen(L, -1);
    const keys = try arena.alloc(extension_ui.KeyBinding, len);
    for (0..len) |i| {
        _ = c.lua_rawgeti(L, -1, @intCast(i + 1));
        defer c.lua_pop(L, 1);
        keys[i] = .{ .key = try readStringFieldLimit(arena, L, c.lua_absindex(L, -1), "key", "", ui_id_bytes), .action = try readStringFieldLimit(arena, L, c.lua_absindex(L, -1), "action", "", ui_id_bytes) };
    }
    return keys;
}

fn readOptionalStringFieldLimit(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, field: [:0]const u8, max_bytes: usize) !?[]const u8 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    return try dupeLuaStringLimit(arena, L, -1, max_bytes);
}

fn readBoolField(L: *c.lua_State, idx: c_int, field: [:0]const u8, default: bool) bool {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) c.lua_toboolean(L, -1) != 0 else default;
}
fn readIntField(L: *c.lua_State, idx: c_int, field: [:0]const u8, default: i64) i64 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return if (c.lua_type(L, -1) == c.LUA_TNUMBER) @intCast(c.lua_tointegerx(L, -1, null)) else default;
}
fn readU32Field(L: *c.lua_State, idx: c_int, field: [:0]const u8, default: u32) u32 {
    const raw = readIntField(L, idx, field, default);
    return if (raw < 0) default else @intCast(raw);
}
fn readOptionalU32Field(L: *c.lua_State, idx: c_int, field: [:0]const u8) ?u32 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return null;
    const raw: i64 = @intCast(c.lua_tointegerx(L, -1, null));
    return if (raw < 0) null else @intCast(raw);
}
fn readOptionalSecondsAsMsField(L: *c.lua_State, idx: c_int, field: [:0]const u8) ?u32 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return null;
    const raw = c.lua_tonumberx(L, -1, null);
    if (!std.math.isFinite(raw) or raw < 0) return null;
    return @intFromFloat(@min(raw * 1000.0, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
}
fn readFloatField(L: *c.lua_State, idx: c_int, field: [:0]const u8, default: f32) f32 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return if (c.lua_type(L, -1) == c.LUA_TNUMBER) @floatCast(c.lua_tonumberx(L, -1, null)) else default;
}
fn readOptionalFloatField(L: *c.lua_State, idx: c_int, field: [:0]const u8) ?f32 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    return if (c.lua_type(L, -1) == c.LUA_TNUMBER) @floatCast(c.lua_tonumberx(L, -1, null)) else null;
}

fn readOptionalArgString(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) !?[]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return null;
    return try dupeLuaStringLimit(arena, L, idx, ui_text_bytes);
}

fn readStringFieldLimit(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, field: [:0]const u8, default: []const u8, max_bytes: usize) ![]const u8 {
    _ = c.lua_getfield(L, idx, field.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return try arena.dupe(u8, default);
    return try dupeLuaStringLimit(arena, L, -1, max_bytes);
}

fn dupeLuaString(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return try arena.dupe(u8, ptr[0..len]);
}

fn dupeLuaStringLimit(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, max_bytes: usize) ![]const u8 {
    return dupeLuaStringWithMarker(arena, L, idx, max_bytes, truncated_marker);
}

fn dupeLuaStringWithMarker(arena: std.mem.Allocator, L: *c.lua_State, idx: c_int, max_bytes: usize, marker: []const u8) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return truncateBytesWithMarker(arena, ptr[0..len], max_bytes, marker);
}

fn truncateBytesWithMarker(arena: std.mem.Allocator, value: []const u8, max_bytes: usize, marker: []const u8) ![]const u8 {
    if (value.len <= max_bytes) return try arena.dupe(u8, value);
    if (max_bytes == 0) return &.{};

    const marker_len = @min(marker.len, max_bytes);
    const prefix_limit = max_bytes - marker_len;
    const prefix_len = utf8SafePrefixLen(value, prefix_limit);
    const out = try arena.alloc(u8, prefix_len + marker_len);
    @memcpy(out[0..prefix_len], value[0..prefix_len]);
    @memcpy(out[prefix_len..], marker[0..marker_len]);
    return out;
}

fn utf8SafePrefixLen(value: []const u8, limit: usize) usize {
    var n = @min(value.len, limit);
    while (n > 0 and (value[n] & 0xc0) == 0x80) n -= 1;
    return n;
}

fn pushAiApi(L: *c.lua_State, runner: *runner_mod.ExtensionRunner) void {
    c.lua_createtable(L, 0, 2);
    pushMethod(L, runner, &ctxAiComplete);
    c.lua_setfield(L, -2, "complete");
    pushMethod(L, runner, &ctxAiSessionCreate);
    c.lua_setfield(L, -2, "session");
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

fn pushSessionApi(L: *c.lua_State, runner: *runner_mod.ExtensionRunner, provenance: ?resource_types.ExtensionProvenance) void {
    const has_session = switch (runner.runtime) {
        .bound => |bound| bound.session_info_get != null or bound.session_name_get != null or bound.session_name_set != null or bound.session_tool_results_get != null or bound.session_messages_get != null or bound.session_context_get != null or bound.session_note_append != null or bound.session_notes_get != null or bound.session_artifact_append != null or bound.session_artifacts_get != null or bound.session_label_set != null or bound.session_labels_get != null or bound.session_entry_get != null or bound.session_entries_get != null,
        .stub => false,
    };
    if (!has_session) {
        c.lua_pushnil(L);
        return;
    }

    c.lua_createtable(L, 0, 15);
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
    pushMethod(L, runner, &ctxSessionContext);
    c.lua_setfield(L, -2, "context");
    pushMethod(L, runner, &ctxSessionAppendNote);
    c.lua_setfield(L, -2, "append_note");
    pushMethod(L, runner, &ctxSessionNotes);
    c.lua_setfield(L, -2, "notes");
    if (provenance) |prov| {
        pushUiMethod(L, runner, prov.state_owner_id, &ctxSessionAppendArtifact);
        c.lua_setfield(L, -2, "append_artifact");
        pushUiMethod(L, runner, prov.state_owner_id, &ctxSessionArtifacts);
        c.lua_setfield(L, -2, "artifacts");
    }
    pushMethod(L, runner, &ctxSessionLabel);
    c.lua_setfield(L, -2, "label");
    pushMethod(L, runner, &ctxSessionLabels);
    c.lua_setfield(L, -2, "labels");
    pushMethod(L, runner, &ctxSessionEntry);
    c.lua_setfield(L, -2, "entry");
    pushMethod(L, runner, &ctxSessionEntries);
    c.lua_setfield(L, -2, "entries");
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

fn readKeyArg(L: *c.lua_State) ?[]const u8 {
    if (c.lua_type(L, 1) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, 1, &len) orelse return null;
    return ptr[0..len];
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

fn ctxSessionContext(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    var max_messages: usize = 500;
    var include_tools = true;
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 1, "max_messages");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw > 0) max_messages = @intCast(@min(raw, 500));
        }
        c.lua_pop(L, 1);
        _ = c.lua_getfield(L, 1, "include_tools");
        if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) include_tools = c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);
    }
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_context_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, max_messages, include_tools) orelse {
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
    var source_entry_id: ?[]const u8 = null;
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, 1);
        kind = readBorrowedStringField(L, idx, "kind");
        source_entry_id = readBorrowedStringField(L, idx, "source_entry_id") orelse readBorrowedStringField(L, idx, "sourceEntryId");
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
            const value = getter(bound.session, runner.allocator, kind, source_entry_id, limit) orelse {
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

fn ctxSessionAppendArtifact(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const owner_id = stateOwnerFromUpvalue(L);
    if (owner_id.len == 0 or c.lua_type(L, 1) != c.LUA_TTABLE) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    const idx = c.lua_absindex(L, 1);
    const kind = readBorrowedStringField(L, idx, "kind") orelse "artifact";
    const key = readBorrowedStringField(L, idx, "key");
    const title = readBorrowedStringField(L, idx, "title");

    _ = c.lua_getfield(L, idx, "data");
    if (c.lua_type(L, -1) == c.LUA_TNONE or c.lua_type(L, -1) == c.LUA_TNIL) {
        c.lua_pop(L, 1);
        c.lua_pushboolean(L, 0);
        return 1;
    }
    const allocator = runner.allocator;
    var budget = lua_runtime.JsonConvertBudget{ .limits = lua_runtime.default_json_convert_limits };
    const data = lua_runtime.luaValueToJsonLimited(L, -1, allocator, &budget) catch {
        c.lua_pop(L, 1);
        c.lua_pushboolean(L, 0);
        return 1;
    };
    c.lua_pop(L, 1);
    errdefer json_util.freeJsonValue(allocator, data);

    switch (runner.runtime) {
        .bound => |bound| {
            const append = bound.session_artifact_append orelse {
                json_util.freeJsonValue(allocator, data);
                c.lua_pushboolean(L, 0);
                return 1;
            };
            append(bound.session, owner_id, kind, key, title, data) catch {
                json_util.freeJsonValue(allocator, data);
                c.lua_pushboolean(L, 0);
                return 1;
            };
            json_util.freeJsonValue(allocator, data);
            c.lua_pushboolean(L, 1);
            return 1;
        },
        .stub => {
            json_util.freeJsonValue(allocator, data);
            c.lua_pushboolean(L, 0);
            return 1;
        },
    }
}

fn ctxSessionArtifacts(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const owner_id = stateOwnerFromUpvalue(L);
    var limit: usize = 50;
    var kind: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, 1);
        kind = readBorrowedStringField(L, idx, "kind");
        key = readBorrowedStringField(L, idx, "key");
        _ = c.lua_getfield(L, idx, "limit");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw > 0) limit = @intCast(@min(raw, 500));
        }
        c.lua_pop(L, 1);
    }
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_artifacts_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, owner_id, kind, key, limit) orelse {
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

fn ctxSessionLabel(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    if (c.lua_type(L, 1) != c.LUA_TSTRING) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    var target_len: usize = 0;
    const target_ptr = c.lua_tolstring(L, 1, &target_len) orelse {
        c.lua_pushboolean(L, 0);
        return 1;
    };
    const target_entry_id = target_ptr[0..target_len];
    const label: ?[]const u8 = switch (c.lua_type(L, 2)) {
        c.LUA_TSTRING => blk: {
            var label_len: usize = 0;
            const label_ptr = c.lua_tolstring(L, 2, &label_len) orelse break :blk null;
            break :blk if (label_len == 0) null else label_ptr[0..label_len];
        },
        c.LUA_TNIL, c.LUA_TNONE => null,
        else => {
            c.lua_pushboolean(L, 0);
            return 1;
        },
    };
    switch (runner.runtime) {
        .bound => |bound| {
            const setter = bound.session_label_set orelse {
                c.lua_pushboolean(L, 0);
                return 1;
            };
            setter(bound.session, target_entry_id, label) catch {
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

fn ctxSessionLabels(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    var limit: usize = 50;
    var target_entry_id: ?[]const u8 = null;
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, 1);
        target_entry_id = readBorrowedStringField(L, idx, "target_entry_id") orelse readBorrowedStringField(L, idx, "targetEntryId");
        _ = c.lua_getfield(L, idx, "limit");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw > 0) limit = @intCast(@min(raw, 500));
        }
        c.lua_pop(L, 1);
    }
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_labels_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, target_entry_id, limit) orelse {
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

fn ctxSessionEntry(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    if (c.lua_type(L, 1) != c.LUA_TSTRING) {
        c.lua_pushnil(L);
        return 1;
    }
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, 1, &len) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    const entry_id = ptr[0..len];
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_entry_get orelse {
                c.lua_pushnil(L);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, entry_id) orelse {
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

fn ctxSessionEntries(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    var limit: usize = 50;
    var label: ?[]const u8 = null;
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, 1);
        label = readBorrowedStringField(L, idx, "label");
        _ = c.lua_getfield(L, idx, "limit");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw > 0) limit = @intCast(@min(raw, 500));
        }
        c.lua_pop(L, 1);
    }
    switch (runner.runtime) {
        .bound => |bound| {
            const getter = bound.session_entries_get orelse {
                c.lua_createtable(L, 0, 0);
                return 1;
            };
            const value = getter(bound.session, runner.allocator, label, limit) orelse {
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

fn ctxAiSessionCreate(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    var session = runner_mod.SideAiSession{ .id = 0 };
    var session_owned = false;
    defer if (!session_owned) session.deinit(runner.allocator);
    if (c.lua_type(L, 1) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, 1);
        if (readBorrowedStringField(L, idx, "model")) |model| session.model = runner.allocator.dupe(u8, model) catch {
            c.lua_pushnil(L);
            return 1;
        };
        if (readBorrowedStringField(L, idx, "system_prompt")) |prompt| session.system_prompt = runner.allocator.dupe(u8, prompt) catch {
            c.lua_pushnil(L);
            return 1;
        };
        session.reasoning = readAiCompleteReasoning(L, idx) catch null;
        _ = c.lua_getfield(L, idx, "max_tokens");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw > 0) session.max_tokens = @intCast(raw);
        }
        c.lua_pop(L, 1);
        readAiSessionTools(runner.allocator, L, idx, &session) catch {
            c.lua_pushnil(L);
            return 1;
        };
        validateAiSessionTools(runner, &session) catch {
            c.lua_pushnil(L);
            return 1;
        };
        readAiSessionSeedMessages(runner.allocator, L, idx, &session) catch {
            c.lua_pushnil(L);
            return 1;
        };
        session.callbacks_ref = readOptionalCallbacksRef(L, idx);
        session.callbacks_L = if (session.callbacks_ref != c.LUA_NOREF) L else null;
    } else if (c.lua_type(L, 1) != c.LUA_TNONE and c.lua_type(L, 1) != c.LUA_TNIL) {
        c.lua_pushnil(L);
        return 1;
    }
    const id = runner.createSideAiSession(session) catch {
        c.lua_pushnil(L);
        return 1;
    };
    session_owned = true;
    pushAiSessionHandle(L, runner, id);
    return 1;
}

fn validateAiSessionTools(runner: *runner_mod.ExtensionRunner, session: *const runner_mod.SideAiSession) !void {
    if (session.tool_allowlist.len == 0) return;
    switch (runner.runtime) {
        .bound => |bound| {
            const exists = bound.tool_exists orelse return;
            for (session.tool_allowlist) |name| if (!exists(bound.session, name)) return error.UnknownTool;
        },
        .stub => return,
    }
}

fn readAiSessionTools(allocator: std.mem.Allocator, L: *c.lua_State, idx: c_int, session: *runner_mod.SideAiSession) !void {
    _ = c.lua_getfield(L, idx, "tools");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TNIL) return;
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return error.InvalidTools;
    const n: usize = @intCast(c.lua_rawlen(L, -1));
    const items = try allocator.alloc([]const u8, n);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| allocator.free(item);
        allocator.free(items);
    }
    for (0..n) |i| {
        _ = c.lua_rawgeti(L, -1, @intCast(i + 1));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidTools;
        items[i] = try dupeLuaString(allocator, L, -1);
        built += 1;
    }
    session.tool_allowlist = items;
}

fn readAiSessionSeedMessages(allocator: std.mem.Allocator, L: *c.lua_State, idx: c_int, session: *runner_mod.SideAiSession) !void {
    _ = c.lua_getfield(L, idx, "context");
    if (c.lua_type(L, -1) == c.LUA_TSTRING) {
        try session.append(allocator, .context, readBorrowedLuaString(L, -1));
    } else if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        const cidx = c.lua_absindex(L, -1);
        if (readBorrowedStringField(L, cidx, "system_prompt")) |system_prompt| try session.append(allocator, .context, system_prompt);
        _ = c.lua_getfield(L, cidx, "messages");
        if (c.lua_type(L, -1) == c.LUA_TTABLE) try appendAiSessionSeedMessageArray(allocator, L, c.lua_absindex(L, -1), session);
        c.lua_pop(L, 1);
    }
    c.lua_pop(L, 1);
    _ = c.lua_getfield(L, idx, "messages");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TTABLE) try appendAiSessionSeedMessageArray(allocator, L, c.lua_absindex(L, -1), session);
}

fn appendAiSessionSeedMessageArray(allocator: std.mem.Allocator, L: *c.lua_State, idx: c_int, session: *runner_mod.SideAiSession) !void {
    const n: usize = @intCast(c.lua_rawlen(L, idx));
    for (0..n) |i| {
        _ = c.lua_rawgeti(L, idx, @intCast(i + 1));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            try session.append(allocator, .user, readBorrowedLuaString(L, -1));
        } else if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            try appendAiSessionSeedMessage(allocator, L, c.lua_absindex(L, -1), session);
        }
    }
}

fn appendAiSessionSeedMessage(allocator: std.mem.Allocator, L: *c.lua_State, idx: c_int, session: *runner_mod.SideAiSession) !void {
    const role_s = readBorrowedStringField(L, idx, "role") orelse "user";
    const role: runner_mod.SideAiSession.Role = if (std.mem.eql(u8, role_s, "assistant")) .assistant else if (std.mem.eql(u8, role_s, "context") or std.mem.eql(u8, role_s, "system")) .context else .user;
    if (readBorrowedStringField(L, idx, "text") orelse readBorrowedStringField(L, idx, "content")) |text| {
        try session.append(allocator, role, text);
        return;
    }
    _ = c.lua_getfield(L, idx, "content");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TTABLE) {
        var text = std.ArrayList(u8).empty;
        defer text.deinit(allocator);
        const n: usize = @intCast(c.lua_rawlen(L, -1));
        for (0..n) |i| {
            _ = c.lua_rawgeti(L, -1, @intCast(i + 1));
            defer c.lua_pop(L, 1);
            if (c.lua_type(L, -1) != c.LUA_TTABLE) continue;
            const bidx = c.lua_absindex(L, -1);
            const typ = readBorrowedStringField(L, bidx, "type") orelse "text";
            if (!std.mem.eql(u8, typ, "text")) continue;
            const block_text = readBorrowedStringField(L, bidx, "text") orelse continue;
            if (text.items.len > 0) try text.append(allocator, '\n');
            try text.appendSlice(allocator, block_text);
        }
        if (text.items.len > 0) try session.append(allocator, role, text.items);
    }
}

fn readBorrowedLuaString(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return &.{};
    return ptr[0..len];
}

fn pushAiSessionHandle(L: *c.lua_State, runner: *runner_mod.ExtensionRunner, id: u64) void {
    c.lua_createtable(L, 0, 9);
    c.lua_pushinteger(L, @intCast(id));
    c.lua_setfield(L, -2, "id");
    pushAiSessionMethod(L, runner, id, &ctxAiSessionPrompt);
    c.lua_setfield(L, -2, "prompt");
    pushAiSessionMethod(L, runner, id, &ctxAiSessionAbort);
    c.lua_setfield(L, -2, "abort");
    pushAiSessionMethod(L, runner, id, &ctxAiSessionDispose);
    c.lua_setfield(L, -2, "dispose");
    pushAiSessionMethod(L, runner, id, &ctxAiSessionInfo);
    c.lua_setfield(L, -2, "info");
    pushAiSessionMethod(L, runner, id, &ctxAiSessionMessages);
    c.lua_setfield(L, -2, "messages");
    pushAiSessionMethod(L, runner, id, &ctxAiSessionIsBusy);
    c.lua_setfield(L, -2, "is_busy");
    pushAiSessionMethod(L, runner, id, &ctxAiSessionClear);
    c.lua_setfield(L, -2, "clear");
}

fn pushAiSessionMethod(L: *c.lua_State, runner: *runner_mod.ExtensionRunner, id: u64, func: *const fn (?*c.lua_State) callconv(.c) c_int) void {
    c.lua_pushlightuserdata(L, runner);
    c.lua_pushinteger(L, @intCast(id));
    c.lua_pushcclosure(L, func, 2);
}

fn aiSessionIdFromUpvalue(L: *c.lua_State) u64 {
    return @intCast(c.lua_tointegerx(L, c.lua_upvalueindex(2), null));
}

fn ctxAiSessionPrompt(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const session_id = aiSessionIdFromUpvalue(L);
    const prompt_arg = aiSessionPromptArgIndex(L);
    const prompt = parseAiSessionPromptText(runner.allocator, L, prompt_arg) catch {
        pushAiCompleteError(L, "ctx.ai.session.prompt: invalid prompt");
        return 1;
    };
    errdefer runner.allocator.free(prompt);
    const session = runner.getSideAiSession(session_id) orelse {
        runner.allocator.free(prompt);
        pushAiCompleteError(L, "ctx.ai.session.prompt: disposed session");
        return 1;
    };
    if (session.disposed) {
        runner.allocator.free(prompt);
        pushAiCompleteError(L, "ctx.ai.session.prompt: disposed session");
        return 1;
    }
    if (session.isBusy()) {
        runner.allocator.free(prompt);
        pushAiCompleteError(L, "ctx.ai.session.prompt: side session is busy");
        return 1;
    }
    var request = runner_mod.AiSessionPromptRequest{ .session_id = session_id, .prompt = prompt, .signal = runner.requireToolExecution("zi.ai.session.prompt").signal };
    request.callbacks_ref = readOptionalCallbacksRef(L, prompt_arg);
    request.source_L = if (request.callbacks_ref != c.LUA_NOREF) L else null;
    const id = runner.beginAiSessionPromptAsync(request);
    return c.lua_yieldk(L, 0, @intCast(id), ctxAiSessionPromptContinue);
}

fn aiSessionPromptArgIndex(L: *c.lua_State) c_int {
    if (c.lua_type(L, 1) == c.LUA_TTABLE and readBorrowedStringField(L, c.lua_absindex(L, 1), "prompt") == null and c.lua_type(L, 2) != c.LUA_TNONE) return 2;
    return 1;
}

fn parseAiSessionPromptText(allocator: std.mem.Allocator, L: *c.lua_State, arg_idx: c_int) ![]const u8 {
    if (c.lua_type(L, arg_idx) == c.LUA_TSTRING) return try dupeLuaString(allocator, L, arg_idx);
    if (c.lua_type(L, arg_idx) != c.LUA_TTABLE) return error.InvalidPrompt;
    const idx = c.lua_absindex(L, arg_idx);
    _ = c.lua_getfield(L, idx, "prompt");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return error.InvalidPrompt;
    return try dupeLuaString(allocator, L, -1);
}

fn readOptionalCallbacksRef(L: *c.lua_State, arg_idx: c_int) c_int {
    if (c.lua_type(L, arg_idx) != c.LUA_TTABLE) return c.LUA_NOREF;
    const idx = c.lua_absindex(L, arg_idx);
    _ = c.lua_getfield(L, idx, "on");
    const t = c.lua_type(L, -1);
    if (t == c.LUA_TFUNCTION or t == c.LUA_TTABLE) return c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    c.lua_pop(L, 1);
    return c.LUA_NOREF;
}

fn ctxAiSessionPromptContinue(L_opt: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.c) c_int {
    _ = status;
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id: runner_mod.AsyncOpId = @intCast(ctx);
    var result = runner.takeCompletedAsync(id) orelse {
        pushAiCompleteError(L, "ctx.ai.session.prompt: missing async result");
        return 1;
    };
    defer result.deinit(runner.allocator);
    switch (result) {
        .ai_session_prompt => |value| pushAiCompleteResult(L, value),
        else => pushAiCompleteError(L, "ctx.ai.session.prompt: unexpected async result"),
    }
    return 1;
}

fn ctxAiSessionAbort(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id = aiSessionIdFromUpvalue(L);
    if (runner.getSideAiSession(id)) |session| {
        session.abort_requested = true;
        if (session.core) |core| core.abort();
    }
    c.lua_pushboolean(L, 1);
    return 1;
}

fn ctxAiSessionDispose(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id = aiSessionIdFromUpvalue(L);
    c.lua_pushboolean(L, if (runner.disposeSideAiSession(id)) 1 else 0);
    return 1;
}

fn ctxAiSessionInfo(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id = aiSessionIdFromUpvalue(L);
    const session = runner.getSideAiSession(id) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    c.lua_createtable(L, 0, 5);
    c.lua_pushinteger(L, @intCast(id));
    c.lua_setfield(L, -2, "id");
    c.lua_pushboolean(L, if (session.disposed) 1 else 0);
    c.lua_setfield(L, -2, "disposed");
    c.lua_pushboolean(L, if (session.isBusy()) 1 else 0);
    c.lua_setfield(L, -2, "busy");
    c.lua_pushinteger(L, @intCast(session.messages.items.len));
    c.lua_setfield(L, -2, "message_count");
    c.lua_createtable(L, @intCast(session.tool_allowlist.len), 0);
    for (session.tool_allowlist, 0..) |name, i| {
        _ = c.lua_pushlstring(L, name.ptr, name.len);
        c.lua_rawseti(L, -2, @intCast(i + 1));
    }
    c.lua_setfield(L, -2, "tools");
    return 1;
}

fn ctxAiSessionMessages(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id = aiSessionIdFromUpvalue(L);
    const session = runner.getSideAiSession(id) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    var limit: usize = session.messages.items.len;
    var include_tools = true;
    const opts_arg: c_int = if (c.lua_type(L, 2) == c.LUA_TTABLE) 2 else 1;
    if (c.lua_type(L, opts_arg) == c.LUA_TTABLE) {
        const idx = c.lua_absindex(L, opts_arg);
        _ = c.lua_getfield(L, idx, "limit");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const raw = c.lua_tointegerx(L, -1, null);
            if (raw >= 0) limit = @min(limit, @as(usize, @intCast(raw)));
        }
        c.lua_pop(L, 1);
        _ = c.lua_getfield(L, idx, "include_tools");
        if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) include_tools = c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);
    }
    const start = session.messages.items.len - limit;
    c.lua_createtable(L, @intCast(session.messages.items.len - start), 0);
    var out_index: c_int = 1;
    for (session.messages.items[start..]) |msg| {
        if (!include_tools and msg == .tool_result) continue;
        lua_agent_serializers.pushAgentMessageToLua(L, msg) catch {
            c.lua_createtable(L, 0, 1);
            _ = c.lua_pushlstring(L, @tagName(msg).ptr, @tagName(msg).len);
            c.lua_setfield(L, -2, "role");
        };
        c.lua_rawseti(L, -2, out_index);
        out_index += 1;
    }
    return 1;
}

fn ctxAiSessionIsBusy(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id = aiSessionIdFromUpvalue(L);
    const session = runner.getSideAiSession(id) orelse {
        c.lua_pushboolean(L, 0);
        return 1;
    };
    c.lua_pushboolean(L, if (session.isBusy()) 1 else 0);
    return 1;
}

fn ctxAiSessionClear(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    const id = aiSessionIdFromUpvalue(L);
    const session = runner.getSideAiSession(id) orelse {
        c.lua_pushboolean(L, 0);
        return 1;
    };
    if (session.isBusy()) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    session.clear(runner.allocator) catch {
        c.lua_pushboolean(L, 0);
        return 1;
    };
    c.lua_pushboolean(L, 1);
    return 1;
}

fn ctxAiComplete(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = stateRunnerFromUpvalue(L);
    var request = parseAiCompleteRequest(runner.allocator, L) catch {
        pushAiCompleteError(L, "ctx.ai.complete: invalid request");
        return 1;
    };
    request.signal = runner.requireToolExecution("zi.ai.complete").signal;
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

    var callbacks_ref: c_int = c.LUA_NOREF;
    _ = c.lua_getfield(L, idx, "on");
    const on_type = c.lua_type(L, -1);
    if (on_type == c.LUA_TFUNCTION or on_type == c.LUA_TTABLE) {
        callbacks_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    } else {
        c.lua_pop(L, 1);
        if (on_type != c.LUA_TNIL) return error.InvalidRequest;
    }
    errdefer if (callbacks_ref != c.LUA_NOREF) c.luaL_unref(L, c.LUA_REGISTRYINDEX, callbacks_ref);

    var max_tokens: ?u64 = null;
    _ = c.lua_getfield(L, idx, "max_tokens");
    if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
        const raw = c.lua_tointegerx(L, -1, null);
        if (raw > 0) max_tokens = @intCast(raw);
    }
    c.lua_pop(L, 1);

    return .{ .prompt = prompt, .system_prompt = system_prompt, .max_tokens = max_tokens, .model = model, .reasoning = reasoning, .stream_events = callbacks_ref != c.LUA_NOREF, .callbacks_ref = callbacks_ref, .source_L = L };
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

fn pushLuaTextMessage(L: *c.lua_State, role: []const u8, text: []const u8) void {
    c.lua_createtable(L, 0, 2);
    _ = c.lua_pushlstring(L, role.ptr, role.len);
    c.lua_setfield(L, -2, "role");
    _ = c.lua_pushlstring(L, text.ptr, text.len);
    c.lua_setfield(L, -2, "text");
}

fn pushAiCompleteResult(L: *c.lua_State, result: runner_mod.AiCompleteResult) void {
    c.lua_createtable(L, 0, 10);
    switch (result) {
        .completed => |completed| {
            _ = c.lua_pushlstring(L, "completed", "completed".len);
            c.lua_setfield(L, -2, "status");
            _ = c.lua_pushlstring(L, completed.text.ptr, completed.text.len);
            c.lua_setfield(L, -2, "text");
            if (completed.message) |message| {
                lua_agent_serializers.pushAgentMessageToLua(L, message) catch pushLuaTextMessage(L, "assistant", completed.text);
            } else {
                pushLuaTextMessage(L, "assistant", completed.text);
            }
            c.lua_setfield(L, -2, "message");
            c.lua_createtable(L, @intCast(completed.messages.len), 0);
            for (completed.messages, 0..) |message, i| {
                lua_agent_serializers.pushAgentMessageToLua(L, message) catch pushLuaTextMessage(L, @tagName(message), "");
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
            c.lua_setfield(L, -2, "messages");
            c.lua_createtable(L, @intCast(completed.tool_results.len), 0);
            for (completed.tool_results, 0..) |tr, i| {
                lua_agent_serializers.pushToolResultMessageToLua(L, tr) catch c.lua_createtable(L, 0, 0);
                c.lua_rawseti(L, -2, @intCast(i + 1));
            }
            c.lua_setfield(L, -2, "tool_results");
            if (completed.message) |message| if (message == .assistant) {
                lua_agent_serializers.pushUsageToLua(L, message.assistant.usage);
                c.lua_setfield(L, -2, "usage");
                _ = c.lua_pushlstring(L, message.assistant.model.ptr, message.assistant.model.len);
                c.lua_setfield(L, -2, "model");
                const stop = json_util.stopReasonToString(message.assistant.stop_reason);
                _ = c.lua_pushlstring(L, stop.ptr, stop.len);
                c.lua_setfield(L, -2, "stopReason");
                _ = c.lua_pushlstring(L, stop.ptr, stop.len);
                c.lua_setfield(L, -2, "stop_reason");
                if (message.assistant.error_message) |err_msg| _ = c.lua_pushlstring(L, err_msg.ptr, err_msg.len) else c.lua_pushnil(L);
                c.lua_setfield(L, -2, "errorMessage");
                if (message.assistant.error_message) |err_msg| _ = c.lua_pushlstring(L, err_msg.ptr, err_msg.len) else c.lua_pushnil(L);
                c.lua_setfield(L, -2, "error_message");
            };
            if (completed.context_usage) |usage| {
                lua_agent_serializers.pushContextUsageToLua(L, usage);
                c.lua_setfield(L, -2, "context_usage");
            }
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

fn ctxSendUserMessage(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    if (c.lua_type(L, 1) != c.LUA_TSTRING) return c.luaL_error(L, "ctx.send_user_message: expected text string");

    var len: usize = 0;
    const ptr = c.lua_tolstring(L, 1, &len) orelse return c.luaL_error(L, "ctx.send_user_message: expected text string");
    const text = ptr[0..len];

    var opts: runner_mod.SendUserMessageOptions = .{};
    if (c.lua_type(L, 2) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, 2, "target");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            var target_len: usize = 0;
            const target_ptr = c.lua_tolstring(L, -1, &target_len) orelse return c.luaL_error(L, "ctx.send_user_message: expected target string");
            const target = target_ptr[0..target_len];
            opts.target = if (std.mem.eql(u8, target, "auto"))
                .auto
            else if (std.mem.eql(u8, target, "prompt"))
                .prompt
            else if (std.mem.eql(u8, target, "steering"))
                .steering
            else if (std.mem.eql(u8, target, "follow_up") or std.mem.eql(u8, target, "follow-up"))
                .follow_up
            else
                return c.luaL_error(L, "ctx.send_user_message: unknown target");
        }
    }

    const actions = switch (runner.runtime) {
        .bound => |bound| bound.command_actions orelse return c.luaL_error(L, "ctx.send_user_message: unavailable in this host"),
        .stub => return c.luaL_error(L, "ctx.send_user_message: unavailable before runtime bind"),
    };

    const result = actions.send_user_message(actions.ctx, text, opts) catch {
        return c.luaL_error(L, "ctx.send_user_message: failed to enqueue message");
    };

    c.lua_createtable(L, 0, 1);
    const status = switch (result) {
        .submitted => "submitted",
        .queued => "queued",
    };
    _ = c.lua_pushlstring(L, status.ptr, status.len);
    c.lua_setfield(L, -2, "status");
    return 1;
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

fn ctxContextUsage(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            if (bound.context_usage(bound.session)) |usage| {
                pushContextUsage(L, usage);
            } else {
                c.lua_pushnil(L);
            }
        },
        .stub => c.lua_pushnil(L),
    }
    return 1;
}

fn ctxSystemPrompt(L_opt: ?*c.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    const runner = runnerFromUpvalue(L);
    switch (runner.runtime) {
        .bound => |bound| {
            const prompt = bound.system_prompt(bound.session);
            _ = c.lua_pushlstring(L, prompt.ptr, prompt.len);
        },
        .stub => _ = c.lua_pushlstring(L, "".ptr, 0),
    }
    return 1;
}

pub fn pushCommandContext(
    L: *c.lua_State,
    runner: *runner_mod.ExtensionRunner,
    provenance: ?resource_types.ExtensionProvenance,
) !void {
    try pushExtensionContext(L, runner, provenance);

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

test "extension ui parses text node options" {
    var lua = try lua_runtime.LuaState.init(std.testing.allocator);
    defer lua.deinit();
    try lua.doString("return { type = 'text', text = 'hello', wrap = 'none', overflow = 'ellipsis', format = 'markdown', max_lines = 2, scroll_y = 1, link = 'https://node.test', selectable = true }", "test_text_options");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try readNode(arena.allocator(), lua.L, -1);

    try std.testing.expect(node == .text);
    try std.testing.expectEqual(extension_ui.TextWrap.none, node.text.wrap);
    try std.testing.expectEqual(extension_ui.TextOverflow.ellipsis, node.text.overflow);
    try std.testing.expectEqual(extension_ui.TextFormat.markdown, node.text.format);
    try std.testing.expectEqual(@as(?u32, 2), node.text.max_lines);
    try std.testing.expectEqual(@as(u32, 1), node.text.scroll_y);
    try std.testing.expectEqualStrings("https://node.test", node.text.link.?);
    try std.testing.expect(node.text.selectable);
}

test "extension ui text node option defaults preserve behavior" {
    var lua = try lua_runtime.LuaState.init(std.testing.allocator);
    defer lua.deinit();
    try lua.doString("return { type = 'text', text = 'hello' }", "test_text_option_defaults");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try readNode(arena.allocator(), lua.L, -1);

    try std.testing.expect(node == .text);
    try std.testing.expectEqual(extension_ui.TextWrap.word, node.text.wrap);
    try std.testing.expectEqual(extension_ui.TextOverflow.clip, node.text.overflow);
    try std.testing.expectEqual(extension_ui.TextFormat.plain, node.text.format);
    try std.testing.expectEqual(@as(?u32, null), node.text.max_lines);
    try std.testing.expectEqual(@as(u32, 0), node.text.scroll_y);
}

test "extension ui parses text node spans" {
    var lua = try lua_runtime.LuaState.init(std.testing.allocator);
    defer lua.deinit();
    try lua.doString("return { type = 'text', text = 'fallback', spans = { { text = 'hello', link = 'https://span.test', style = { tone = 'accent' } }, { text = ' world', style = { tone = 'success' } } } }", "test_text_spans");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try readNode(arena.allocator(), lua.L, -1);

    try std.testing.expect(node == .text);
    try std.testing.expectEqualStrings("hello world", node.text.text);
    try std.testing.expect(node.text.spans != null);
    try std.testing.expectEqual(@as(usize, 2), node.text.spans.?.len);
    try std.testing.expectEqualStrings("hello", node.text.spans.?[0].text);
    try std.testing.expectEqual(extension_ui.Tone.accent, node.text.spans.?[0].style.?.tone);
    try std.testing.expectEqualStrings("https://span.test", node.text.spans.?[0].link.?);
    try std.testing.expectEqual(extension_ui.Tone.success, node.text.spans.?[1].style.?.tone);
}

test "extension ui parses input node" {
    var lua = try lua_runtime.LuaState.init(std.testing.allocator);
    defer lua.deinit();
    try lua.doString("return { type = 'input', id = 'filter', value = 'zi', placeholder = 'Filter…', on_input = 'filter.input', on_change = 'filter.changed', on_submit = 'filter.submit', style = { tone = 'accent' } }", "test_input_node");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try readNode(arena.allocator(), lua.L, -1);

    try std.testing.expect(node == .input);
    try std.testing.expectEqualStrings("filter", node.input.id);
    try std.testing.expectEqualStrings("zi", node.input.value);
    try std.testing.expectEqualStrings("Filter…", node.input.placeholder.?);
    try std.testing.expectEqualStrings("filter.input", node.input.on_input.?);
    try std.testing.expectEqualStrings("filter.changed", node.input.on_change.?);
    try std.testing.expectEqualStrings("filter.submit", node.input.on_submit.?);
    try std.testing.expectEqual(extension_ui.Tone.accent, node.input.style.tone);
}

test "extension ui parses style colors and attributes" {
    var lua = try lua_runtime.LuaState.init(std.testing.allocator);
    defer lua.deinit();
    try lua.doString("return { type = 'text', text = 'fallback', style = { fg = '#0f8', bg = 'blue', bold = true, dim = true, italic = true, underline = true, strikethrough = true }, spans = { { text = 'x', style = { fg = '#112233', bg = 'red', bold = true } } } }", "test_text_styles");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try readNode(arena.allocator(), lua.L, -1);

    try std.testing.expect(node == .text);
    try std.testing.expectEqual(extension_ui.Color.rgb(0, 255, 136), node.text.style.fg.?);
    try std.testing.expectEqual(extension_ui.Color.rgb(36, 114, 200), node.text.style.bg.?);
    try std.testing.expect(node.text.style.bold);
    try std.testing.expect(node.text.style.dim);
    try std.testing.expect(node.text.style.italic);
    try std.testing.expect(node.text.style.underline);
    try std.testing.expect(node.text.style.strikethrough);
    try std.testing.expectEqual(extension_ui.Color.rgb(0x11, 0x22, 0x33), node.text.spans.?[0].style.?.fg.?);
    try std.testing.expectEqual(extension_ui.Color.rgb(205, 49, 49), node.text.spans.?[0].style.?.bg.?);
}

test "extension context truncates span text on utf8 boundary with marker" {
    const text = "abcédef";
    const truncated = try truncateBytesWithMarker(std.testing.allocator, text, 6, "...");
    defer std.testing.allocator.free(truncated);
    try std.testing.expectEqualStrings("abc...", truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
}

test "extension context concatSpansText marks truncated output" {
    const spans = [_]extension_ui.TextSpan{
        .{ .text = "abc" },
        .{ .text = "é" ** ui_text_bytes },
    };
    const text = try concatSpansText(std.testing.allocator, &spans);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.endsWith(u8, text, truncated_marker));
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}
