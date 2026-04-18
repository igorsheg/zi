//! Renderers for the zig built-in tools (read, write, edit, grep,
//! find, ls). Complex result rendering is retained: we parse/build a
//! tool surface on result mutation, then measure/paint slices from the
//! cached surface without reallocating during render.

const std = @import("std");
const tool_display_mod = @import("../tool_display.zig");
const boxed_surface = @import("../boxed_surface.zig");
const excerpt_mod = @import("../excerpt.zig");
const buffer_mod = @import("../buffer.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const json_util = @import("../../ai/json_util.zig");
const agent_protocol = @import("../../agent2/root.zig").protocol;

const ToolRenderer = tool_display_mod.ToolRenderer;
const ToolStateContext = tool_display_mod.ToolStateContext;
const ToolMeasureContext = tool_display_mod.ToolMeasureContext;
const ToolRenderContext = tool_display_mod.ToolRenderContext;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Allocator = std.mem.Allocator;
const OwnedSurface = boxed_surface.OwnedSurface;

const ParseMode = enum {
    plain,
    numbered,
};

const TextParser = struct {
    mode: ParseMode,
    collapsed_excerpts: []const excerpt_mod.Excerpt,
};

const BuiltinParser = union(enum) {
    text: TextParser,
    edit: void,
};

const BuiltinRenderState = struct {
    allocator: Allocator,
    parser: BuiltinParser,
    surface: OwnedSurface,

    fn createText(allocator: Allocator, mode: ParseMode, collapsed_excerpts: []const excerpt_mod.Excerpt) ?*anyopaque {
        const state = allocator.create(BuiltinRenderState) catch return null;
        state.* = .{
            .allocator = allocator,
            .parser = .{ .text = .{ .mode = mode, .collapsed_excerpts = collapsed_excerpts } },
            .surface = OwnedSurface.init(allocator),
        };
        return @ptrCast(state);
    }

    fn createEdit(allocator: Allocator) ?*anyopaque {
        const state = allocator.create(BuiltinRenderState) catch return null;
        state.* = .{
            .allocator = allocator,
            .parser = .edit,
            .surface = OwnedSurface.init(allocator),
        };
        return @ptrCast(state);
    }

    fn deinitOpaque(raw_state: *anyopaque, allocator: Allocator) void {
        const state: *BuiltinRenderState = @ptrCast(@alignCast(raw_state));
        state.surface.deinit();
        allocator.destroy(state);
    }

    fn update(self: *BuiltinRenderState, ctx: *const ToolStateContext) void {
        self.surface.clear();
        switch (self.parser) {
            .text => |parser| rebuildTextSurface(&self.surface, ctx.result, parser.mode, parser.collapsed_excerpts) catch {},
            .edit => rebuildEditSurface(&self.surface, ctx) catch {},
        }
    }
};

fn stateFrom(raw_state: ?*anyopaque) ?*BuiltinRenderState {
    const state = raw_state orelse return null;
    return @ptrCast(@alignCast(state));
}

fn builtinResultChanged(ctx: *const ToolStateContext) void {
    const state = stateFrom(ctx.state) orelse return;
    state.update(ctx);
}

fn makePalette(ctx: *const ToolRenderContext) boxed_surface.Palette {
    const base: @import("../box_chrome.zig").Style = .{
        .chrome = ctx.theme.fg(.dim),
        .fg = if (ctx.is_error) ctx.theme.fg(.@"error") else ctx.theme.fg(.tool_output),
        .dim = ctx.theme.fg(.dim),
    };
    return .{
        .base = base,
        .added = .{ .chrome = base.chrome, .fg = ctx.theme.fg(.tool_diff_added), .dim = base.dim },
        .removed = .{ .chrome = base.chrome, .fg = ctx.theme.fg(.tool_diff_removed), .dim = base.dim },
        .context = .{ .chrome = base.chrome, .fg = ctx.theme.fg(.tool_diff_context), .dim = base.dim },
    };
}

fn retainedMeasure(ctx: *const ToolMeasureContext) u32 {
    const state = stateFrom(ctx.state) orelse return 0;
    return state.surface.measure(ctx.expanded);
}

fn retainedRenderSlice(ctx: *const ToolRenderContext, first_row: u32) void {
    const state = stateFrom(ctx.state) orelse return;
    state.surface.renderSlice(ctx.region, makePalette(ctx), ctx.expanded, first_row);
}

fn collectText(surface: *OwnedSurface, result: ?agent_protocol.AgentToolResult) ![]u8 {
    const resolved = result orelse return surface.raw_buf.items[0..0];
    var total: usize = 0;
    var text_blocks: usize = 0;
    for (resolved.content) |block| switch (block) {
        .text => |text| {
            total += text.text.len;
            text_blocks += 1;
        },
        .image => {},
    };
    if (text_blocks == 0) return surface.raw_buf.items[0..0];
    total += text_blocks - 1;

    try surface.raw_buf.resize(surface.allocator, total);
    var pos: usize = 0;
    for (resolved.content) |block| switch (block) {
        .text => |text| {
            if (pos > 0) {
                surface.raw_buf.items[pos] = '\n';
                pos += 1;
            }
            @memcpy(surface.raw_buf.items[pos..][0..text.text.len], text.text);
            pos += text.text.len;
        },
        .image => {},
    };
    return surface.raw_buf.items[0..pos];
}

fn rebuildTextSurface(
    surface: *OwnedSurface,
    result: ?agent_protocol.AgentToolResult,
    mode: ParseMode,
    collapsed_excerpts: []const excerpt_mod.Excerpt,
) !void {
    const raw_full = try collectText(surface, result);
    if (raw_full.len == 0) return;

    var raw_end = raw_full.len;
    while (raw_end > 0 and (raw_full[raw_end - 1] == '\n' or raw_full[raw_end - 1] == '\r')) {
        raw_end -= 1;
    }
    if (raw_end == 0) return;

    if (std.mem.lastIndexOfScalar(u8, raw_full[0..raw_end], '\n')) |nl| {
        const last_line = raw_full[nl + 1 .. raw_end];
        if (last_line.len >= 2 and last_line[0] == '(' and last_line[last_line.len - 1] == ')') {
            surface.notice = last_line[1 .. last_line.len - 1];
            raw_end = nl;
            while (raw_end > 0 and raw_full[raw_end - 1] == '\n') raw_end -= 1;
        }
    }
    if (raw_end == 0) {
        surface.notice = null;
        return;
    }

    var line_count: usize = 1;
    for (raw_full[0..raw_end]) |c| {
        if (c == '\n') line_count += 1;
    }
    try surface.rows.resize(surface.allocator, line_count);

    var idx: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    var max_gutter: usize = 0;
    while (i <= raw_end) : (i += 1) {
        if (i == raw_end or raw_full[i] == '\n') {
            const line_text = raw_full[start..i];
            var row = boxed_surface.Row{ .text = line_text };
            switch (mode) {
                .plain => {},
                .numbered => {
                    var j: usize = 0;
                    while (j < line_text.len and line_text[j] == ' ') : (j += 1) {}
                    const num_start = j;
                    while (j < line_text.len and line_text[j] >= '0' and line_text[j] <= '9') : (j += 1) {}
                    if (j > num_start and j + 1 < line_text.len and line_text[j] == ':' and line_text[j + 1] == ' ') {
                        row.gutter = line_text[num_start..j];
                        row.text = line_text[j + 2 ..];
                        if (row.gutter.?.len > max_gutter) max_gutter = row.gutter.?.len;
                    }
                },
            }
            surface.rows.items[idx] = row;
            idx += 1;
            start = i + 1;
        }
    }
    surface.gutter_width = @intCast(max_gutter);
    try surface.setCollapsedExcerpts(collapsed_excerpts);
}

fn rebuildLiteralSurface(surface: *OwnedSurface, text: []const u8, collapsed_excerpts: []const excerpt_mod.Excerpt) !void {
    try surface.raw_buf.resize(surface.allocator, text.len);
    @memcpy(surface.raw_buf.items[0..text.len], text);
    try surface.rows.resize(surface.allocator, 1);
    surface.rows.items[0] = .{ .text = surface.raw_buf.items[0..text.len], .highlight = false };
    try surface.setCollapsedExcerpts(collapsed_excerpts);
}

fn rebuildEditSurface(surface: *OwnedSurface, ctx: *const ToolStateContext) !void {
    if (ctx.result == null) {
        try rebuildLiteralSurface(surface, "malformed edit result: missing tool result", &TAIL_5);
        return;
    }

    // Diagnostic mode: bypass structured diff decoding/render prep and
    // render the unified diff text directly so we can isolate whether the
    // structuredDiff payload/path is causing the TUI stall.
    try rebuildTextSurface(surface, ctx.result, .plain, &DIFF_COLLAPSED);
}

fn renderTitle(
    ctx: *const ToolRenderContext,
    label: []const u8,
    detail: ?[]const u8,
) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;
    var col: u32 = 0;
    col += region.writeStr(col, 0, label, ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });
    col += region.writeStr(col, 0, " ", Color.default, Color.default, .{});
    if (detail) |resolved| _ = region.writeStr(col, 0, resolved, ctx.theme.fg(.dim), Color.default, .{});
}

fn shortPath(buf: []u8, path: []const u8) []const u8 {
    const home = std.posix.getenv("HOME") orelse return path;
    if (std.mem.startsWith(u8, path, home)) {
        if (path.len - home.len + 1 > buf.len) return path;
        buf[0] = '~';
        @memcpy(buf[1 .. 1 + (path.len - home.len)], path[home.len..]);
        return buf[0 .. 1 + (path.len - home.len)];
    }
    return path;
}

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (args) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
}

fn argTimeoutSeconds(args: std.json.Value) ?u64 {
    return switch (args) {
        .object => |o| switch (o.get("timeout") orelse return null) {
            .integer => |i| if (i > 0) @intCast(i) else null,
            .float => |f| if (f > 0) @intFromFloat(@floor(f)) else null,
            else => null,
        },
        else => null,
    };
}

const READ_COLLAPSED = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 3 },
    .{ .focus = .tail, .context = 5 },
};
const TAIL_5 = [_]excerpt_mod.Excerpt{.{ .focus = .tail, .context = 5 }};
const HEAD_TAIL_SHORT = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 3 },
    .{ .focus = .tail, .context = 5 },
};
const DIFF_COLLAPSED = [_]excerpt_mod.Excerpt{
    .{ .focus = .head, .context = 12 },
    .{ .focus = .tail, .context = 13 },
};

fn initReadState(allocator: Allocator) ?*anyopaque {
    return BuiltinRenderState.createText(allocator, .numbered, &READ_COLLAPSED);
}

fn initPlainTailState(allocator: Allocator) ?*anyopaque {
    return BuiltinRenderState.createText(allocator, .plain, &TAIL_5);
}

fn initHeadTailShortState(allocator: Allocator) ?*anyopaque {
    return BuiltinRenderState.createText(allocator, .plain, &HEAD_TAIL_SHORT);
}

fn initEditState(allocator: Allocator) ?*anyopaque {
    return BuiltinRenderState.createEdit(allocator);
}

fn skillNameFromReadPath(path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, path, "/SKILL.md")) return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    const name = std.fs.path.basename(dir);
    if (name.len == 0) return null;
    return name;
}

fn readCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    const short = shortPath(&buf, path);
    var detail_buf: [1100]u8 = undefined;
    if (skillNameFromReadPath(path)) |skill_name| {
        const detail = if (rangeFromArgs(ctx.args)) |r|
            std.fmt.bufPrint(&detail_buf, "{s}:{d}-{d}", .{ skill_name, r[0], r[1] }) catch skill_name
        else
            skill_name;
        renderTitle(ctx, "Skill", detail);
        return;
    }
    const detail = if (rangeFromArgs(ctx.args)) |r|
        std.fmt.bufPrint(&detail_buf, "{s}:{d}-{d}", .{ short, r[0], r[1] }) catch short
    else
        short;
    renderTitle(ctx, "Read", detail);
}

fn rangeFromArgs(args: std.json.Value) ?[2]i64 {
    const obj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const arr = switch (obj.get("read_range") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len != 2) return null;
    const a = switch (arr.items[0]) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return null,
    };
    const b = switch (arr.items[1]) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return null,
    };
    return .{ a, b };
}

pub const read_renderer = ToolRenderer{
    .render_call = readCall,
    .render_result_slice = retainedRenderSlice,
    .measure_result = retainedMeasure,
    .init_state = initReadState,
    .deinit_state = BuiltinRenderState.deinitOpaque,
    .result_changed = builtinResultChanged,
};

fn writeCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    renderTitle(ctx, "Write", shortPath(&buf, path));
}

pub const write_renderer = ToolRenderer{
    .render_call = writeCall,
    .render_result_slice = retainedRenderSlice,
    .measure_result = retainedMeasure,
    .init_state = initPlainTailState,
    .deinit_state = BuiltinRenderState.deinitOpaque,
    .result_changed = builtinResultChanged,
};

fn editCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse "...";
    renderTitle(ctx, "Edit", shortPath(&buf, path));
}

pub const edit_renderer = ToolRenderer{
    .render_call = editCall,
    .render_result_slice = retainedRenderSlice,
    .measure_result = retainedMeasure,
    .init_state = initEditState,
    .deinit_state = BuiltinRenderState.deinitOpaque,
    .result_changed = builtinResultChanged,
};

fn grepCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const pattern = argString(ctx.args, "pattern") orelse "...";
    const path = argString(ctx.args, "path") orelse argString(ctx.args, "glob") orelse ".";
    const short = shortPath(&buf, path);
    var detail_buf: [2048]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "/{s}/ in {s}", .{ pattern, short }) catch pattern;
    renderTitle(ctx, "Grep", detail);
}

pub const grep_renderer = ToolRenderer{
    .render_call = grepCall,
    .render_result_slice = retainedRenderSlice,
    .measure_result = retainedMeasure,
    .init_state = initHeadTailShortState,
    .deinit_state = BuiltinRenderState.deinitOpaque,
    .result_changed = builtinResultChanged,
};

fn findCall(ctx: *const ToolRenderContext) void {
    const pat = argString(ctx.args, "filePattern") orelse "...";
    renderTitle(ctx, "Find", pat);
}

pub const find_renderer = ToolRenderer{
    .render_call = findCall,
    .render_result_slice = retainedRenderSlice,
    .measure_result = retainedMeasure,
    .init_state = initHeadTailShortState,
    .deinit_state = BuiltinRenderState.deinitOpaque,
    .result_changed = builtinResultChanged,
};

fn bashCall(ctx: *const ToolRenderContext) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;

    var col: u32 = 0;
    col += region.writeStr(col, 0, "$ ", ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });

    const cmd = argString(ctx.args, "cmd") orelse argString(ctx.args, "command");
    if (cmd) |command| {
        col += region.writeStr(col, 0, command, ctx.theme.fg(.tool_title), Color.default, .{ .bold = true });
    } else {
        col += region.writeStr(col, 0, "...", ctx.theme.fg(.tool_output), Color.default, .{});
    }

    if (argTimeoutSeconds(ctx.args)) |timeout_secs| {
        var timeout_buf: [32]u8 = undefined;
        const suffix = std.fmt.bufPrint(&timeout_buf, " (timeout {d}s)", .{timeout_secs}) catch "";
        _ = region.writeStr(col, 0, suffix, ctx.theme.fg(.dim), Color.default, .{});
    }
}

pub const bash_renderer = ToolRenderer{
    .render_call = bashCall,
    .render_result_slice = retainedRenderSlice,
    .measure_result = retainedMeasure,
    .init_state = initPlainTailState,
    .deinit_state = BuiltinRenderState.deinitOpaque,
    .result_changed = builtinResultChanged,
};

fn lsCall(ctx: *const ToolRenderContext) void {
    var buf: [1024]u8 = undefined;
    const path = argString(ctx.args, "path") orelse ".";
    renderTitle(ctx, "Ls", shortPath(&buf, path));
}

pub const ls_renderer = ToolRenderer{
    .render_call = lsCall,
    .render_result_slice = retainedRenderSlice,
    .measure_result = retainedMeasure,
    .init_state = initHeadTailShortState,
    .deinit_state = BuiltinRenderState.deinitOpaque,
    .result_changed = builtinResultChanged,
};

const testing = std.testing;

fn rowAscii(buf: *const buffer_mod.Buffer, y: u32, out: []u8) []const u8 {
    var len: usize = 0;
    var x: u32 = 0;
    while (x < buf.width and len < out.len) : (x += 1) {
        const cp = buf.get(x, y).grapheme.codepoint;
        out[len] = if (cp <= 0x7f) @intCast(cp) else '?';
        len += 1;
    }
    return std.mem.trimRight(u8, out[0..len], " ");
}

fn makeBashArgsForTest(allocator: Allocator, key: []const u8, command: []const u8, timeout: ?std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_command = try allocator.dupe(u8, command);
    errdefer allocator.free(owned_command);
    try obj.put(owned_key, .{ .string = owned_command });

    if (timeout) |value| {
        const timeout_key = try allocator.dupe(u8, "timeout");
        errdefer allocator.free(timeout_key);
        try obj.put(timeout_key, value);
    }

    return .{ .object = obj };
}

fn prepareRendererStateForTest(
    allocator: Allocator,
    renderer: ToolRenderer,
    result: agent_protocol.AgentToolResult,
    is_error: bool,
) !?*anyopaque {
    const state = if (renderer.init_state) |init_fn| init_fn(allocator) else null;
    errdefer if (state) |resolved| {
        if (renderer.deinit_state) |deinit_fn| deinit_fn(resolved, allocator);
    };

    if (renderer.result_changed) |changed_fn| {
        var ctx = ToolStateContext{
            .tool_name = "edit",
            .tool_call_id = "call-test",
            .args = .null,
            .result = result,
            .is_partial = false,
            .is_error = is_error,
            .expanded = true,
            .execution_started = true,
            .args_complete = true,
            .allocator = allocator,
            .state = state,
        };
        changed_fn(&ctx);
    }

    return state;
}

test "skillNameFromReadPath extracts skill name from canonical skill file path" {
    try testing.expectEqualStrings("caveman", skillNameFromReadPath("/Users/igors/.zi/agent/skills/caveman/SKILL.md").?);
}

test "skillNameFromReadPath ignores ordinary read paths" {
    try testing.expect(skillNameFromReadPath("/tmp/notes.md") == null);
}

test "bashCall renders cmd args with timeout suffix" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 64, 1);
    defer buf.deinit();

    const args = try makeBashArgsForTest(testing.allocator, "cmd", "echo hi", .{ .integer = 5 });
    defer json_util.freeJsonValue(testing.allocator, args);

    const ctx = ToolRenderContext{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .args = args,
        .result = null,
        .is_partial = true,
        .is_error = false,
        .expanded = false,
        .execution_started = false,
        .args_complete = false,
        .theme = themes_builtin.dark(),
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = buf.width,
    };

    bashCall(&ctx);

    var line: [64]u8 = undefined;
    try testing.expectEqualStrings("$ echo hi (timeout 5s)", rowAscii(&buf, 0, &line));
}

test "bashCall falls back to legacy command arg for old sessions" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 32, 1);
    defer buf.deinit();

    const args = try makeBashArgsForTest(testing.allocator, "command", "ls -la", null);
    defer json_util.freeJsonValue(testing.allocator, args);

    const ctx = ToolRenderContext{
        .tool_name = "bash",
        .tool_call_id = "call-1",
        .args = args,
        .result = null,
        .is_partial = true,
        .is_error = false,
        .expanded = false,
        .execution_started = false,
        .args_complete = false,
        .theme = themes_builtin.dark(),
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = buf.width,
    };

    bashCall(&ctx);

    var line: [32]u8 = undefined;
    try testing.expectEqualStrings("$ ls -la", rowAscii(&buf, 0, &line));
}

test "edit renderer renders unified diff text without structured diff details" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 80, 12);
    defer buf.deinit();

    const content = try testing.allocator.alloc(agent_protocol.AgentToolResult.ContentBlock, 1);
    defer {
        testing.allocator.free(content[0].text.text);
        testing.allocator.free(content);
    }
    content[0] = .{ .text = .{ .text = try testing.allocator.dupe(
        u8,
        "--- a.txt\n+++ a.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n",
    ) } };

    const result = agent_protocol.AgentToolResult{
        .content = content,
        .details = .null,
        .is_error = false,
    };

    const state = try prepareRendererStateForTest(testing.allocator, edit_renderer, result, false);
    defer if (state) |resolved| {
        if (edit_renderer.deinit_state) |deinit_fn| deinit_fn(resolved, testing.allocator);
    };

    var ctx = ToolRenderContext{
        .tool_name = "edit",
        .tool_call_id = "call-1",
        .args = .null,
        .result = result,
        .is_partial = false,
        .is_error = false,
        .expanded = true,
        .execution_started = true,
        .args_complete = true,
        .theme = themes_builtin.dark(),
        .allocator = testing.allocator,
        .state = state,
        .region = buf.region(),
        .width = buf.width,
    };

    edit_renderer.render_result_slice.?(&ctx, 0);

    var row0: [80]u8 = undefined;
    var row2: [80]u8 = undefined;
    var row3: [80]u8 = undefined;
    var row4: [80]u8 = undefined;
    var row5: [80]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 0, &row0), "--- a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 2, &row2), "@@ -1,3 +1,3 @@") != null);
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 3, &row3), "one") != null);
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 4, &row4), "-two") != null);
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 5, &row5), "+TWO") != null);
}

test "edit renderer shows malformed result message when tool result is missing" {
    var buf = try buffer_mod.Buffer.init(testing.allocator, 80, 8);
    defer buf.deinit();

    const state = if (edit_renderer.init_state) |init_fn| init_fn(testing.allocator) else null;
    defer if (state) |resolved| {
        if (edit_renderer.deinit_state) |deinit_fn| deinit_fn(resolved, testing.allocator);
    };

    if (edit_renderer.result_changed) |changed_fn| {
        var state_ctx = ToolStateContext{
            .tool_name = "edit",
            .tool_call_id = "call-2",
            .args = .null,
            .result = null,
            .is_partial = false,
            .is_error = false,
            .expanded = true,
            .execution_started = true,
            .args_complete = true,
            .allocator = testing.allocator,
            .state = state,
        };
        changed_fn(&state_ctx);
    }

    const measure_ctx = ToolMeasureContext{
        .tool_name = "edit",
        .tool_call_id = "call-2",
        .args = .null,
        .result = null,
        .is_partial = false,
        .is_error = false,
        .expanded = true,
        .execution_started = true,
        .args_complete = true,
        .allocator = testing.allocator,
        .state = state,
        .width = buf.width,
    };
    try testing.expect(edit_renderer.measure_result.?(&measure_ctx) > 0);

    var render_ctx = ToolRenderContext{
        .tool_name = "edit",
        .tool_call_id = "call-2",
        .args = .null,
        .result = null,
        .is_partial = false,
        .is_error = false,
        .expanded = true,
        .execution_started = true,
        .args_complete = true,
        .theme = themes_builtin.dark(),
        .allocator = testing.allocator,
        .state = state,
        .region = buf.region(),
        .width = buf.width,
    };
    edit_renderer.render_result_slice.?(&render_ctx, 0);

    var row: [80]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, rowAscii(&buf, 0, &row), "malformed edit result") != null);
}
