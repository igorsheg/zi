const std = @import("std");
const tool_display_mod = @import("../tool_display.zig");
const box_chrome = @import("../box_chrome.zig");
const excerpt_mod = @import("../excerpt.zig");
const buffer_mod = @import("../buffer.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");

const ToolRenderer = tool_display_mod.ToolRenderer;
const ToolRenderContext = tool_display_mod.ToolRenderContext;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;

const COLLAPSED_EXCERPTS = [_]excerpt_mod.Excerpt{
    .{ .focus = .tail, .context = 5 },
};

pub const renderer = ToolRenderer{
    .render_call = renderCall,
    .render_result = renderResult,
    .measure_result = measureResultFn,
};

fn renderCall(ctx: *const ToolRenderContext) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;

    const command = extractCommand(ctx.args);
    const theme = ctx.theme;

    var col: u32 = 0;
    col += region.writeStr(col, 0, "$ ", theme.fg(.tool_title), Color.default, .{ .bold = true });

    if (command) |cmd| {
        _ = region.writeStr(col, 0, cmd, theme.fg(.tool_title), Color.default, .{ .bold = true });
    } else {
        _ = region.writeStr(col, 0, "...", theme.fg(.tool_output), Color.default, .{});
    }
}

fn renderResult(ctx: *const ToolRenderContext) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;

    var split = getLines(ctx) orelse return;
    defer split.deinit();
    const total: u32 = @intCast(split.lines.len);
    if (total == 0) return;

    const style = makeStyle(ctx);
    const excerpts: []const excerpt_mod.Excerpt = if (ctx.expanded) &.{} else &COLLAPSED_EXCERPTS;
    var window = excerpt_mod.windowExcerpts(ctx.allocator, total, excerpts) catch return;
    defer window.deinit();

    var row: u32 = 0;
    row += box_chrome.drawTop(region, row, null, style);

    for (window.items) |item| {
        switch (item) {
            .span => |span| {
                var i = span.start;
                while (i < span.end and row < region.height) : (i += 1) {
                    row += box_chrome.drawContentLine(region, row, null, 0, split.lines[i], style, true);
                }
            },
            .gap => |count| {
                row += box_chrome.drawElision(region, row, count, 0, style);
            },
        }
    }

    _ = box_chrome.drawBottom(region, row, style);
}

fn measureResultFn(ctx: *const ToolRenderContext) u32 {
    var split = getLines(ctx) orelse return 0;
    defer split.deinit();
    const total: u32 = @intCast(split.lines.len);
    if (total == 0) return 0;

    const excerpts: []const excerpt_mod.Excerpt = if (ctx.expanded) &.{} else &COLLAPSED_EXCERPTS;
    var window = excerpt_mod.windowExcerpts(ctx.allocator, total, excerpts) catch return 1;
    defer window.deinit();

    var visible: u32 = 0;
    var gaps: u32 = 0;
    for (window.items) |item| {
        switch (item) {
            .span => |span| visible += span.end - span.start,
            .gap => |_| gaps += 1,
        }
    }
    return box_chrome.measureHeight(visible, gaps);
}

fn makeStyle(ctx: *const ToolRenderContext) box_chrome.Style {
    return .{
        .chrome = ctx.theme.fg(.dim),
        .fg = if (ctx.is_error) ctx.theme.fg(.@"error") else ctx.theme.fg(.tool_output),
        .dim = ctx.theme.fg(.dim),
    };
}

// ── Line splitting ───────────────────────────────────────────────

const SplitLines = struct {
    text: []u8,
    lines: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SplitLines) void {
        self.allocator.free(self.lines);
        self.allocator.free(self.text);
    }
};

fn getLines(ctx: *const ToolRenderContext) ?SplitLines {
    const result = ctx.result orelse return null;
    var total_len: usize = 0;
    for (result.content) |block| {
        switch (block) {
            .text => |t| total_len += t.text.len + 1,
            .image => {},
        }
    }
    if (total_len == 0) return null;

    const buf = ctx.allocator.alloc(u8, total_len) catch return null;
    var pos: usize = 0;
    for (result.content) |block| {
        switch (block) {
            .text => |t| {
                if (pos > 0) {
                    buf[pos] = '\n';
                    pos += 1;
                }
                @memcpy(buf[pos..][0..t.text.len], t.text);
                pos += t.text.len;
            },
            .image => {},
        }
    }
    const text = buf[0..pos];

    // Trim trailing whitespace
    const trimmed_len = std.mem.trimRight(u8, text, " \t\n\r").len;
    if (trimmed_len == 0) {
        ctx.allocator.free(buf);
        return null;
    }
    const trimmed = text[0..trimmed_len];

    // Count lines
    var line_count: usize = 1;
    for (trimmed) |c| {
        if (c == '\n') line_count += 1;
    }

    const lines = ctx.allocator.alloc([]const u8, line_count) catch {
        ctx.allocator.free(buf);
        return null;
    };

    var line_idx: usize = 0;
    var start: usize = 0;
    for (trimmed, 0..) |c, i| {
        if (c == '\n') {
            lines[line_idx] = trimmed[start..i];
            line_idx += 1;
            start = i + 1;
        }
    }
    lines[line_idx] = trimmed[start..];

    return .{
        .text = buf,
        .lines = lines,
        .allocator = ctx.allocator,
    };
}

fn extractCommand(args: std.json.Value) ?[]const u8 {
    switch (args) {
        .object => |obj| {
            if (obj.get("command")) |cmd| {
                switch (cmd) {
                    .string => |s| return s,
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
    }
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;
const agent_protocol = @import("../../agent/root.zig").protocol;

test "bash renderCall shows $ command" {
    var buf = try Buffer.init(testing.allocator, 40, 1);
    defer buf.deinit();

    var obj = std.json.ObjectMap.init(testing.allocator);
    defer obj.deinit();
    try obj.put("command", .{ .string = "echo hello" });

    const ctx = ToolRenderContext{
        .tool_name = "Bash",
        .tool_call_id = "test-1",
        .args = .{ .object = obj },
        .result = null,
        .is_partial = true,
        .is_error = false,
        .expanded = false,
        .execution_started = false,
        .args_complete = true,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = 40,
    };
    renderCall(&ctx);

    try testing.expectEqual(@as(u21, '$'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(1, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'e'), buf.get(2, 0).grapheme.codepoint);
}

test "bash renderResult shows box chrome with tail excerpt" {
    var buf = try Buffer.init(testing.allocator, 40, 15);
    defer buf.deinit();

    const output = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8";
    var content = [_]agent_protocol.AgentToolResult.ContentBlock{
        .{ .text = .{ .text = output } },
    };

    const ctx = ToolRenderContext{
        .tool_name = "Bash",
        .tool_call_id = "test-2",
        .args = .null,
        .result = .{ .content = &content },
        .is_partial = false,
        .is_error = false,
        .expanded = false,
        .execution_started = true,
        .args_complete = true,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = 40,
    };
    renderResult(&ctx);

    // Row 0: top chrome ╭─
    try testing.expectEqual(@as(u21, '╭'), buf.get(0, 0).grapheme.codepoint);
    // Row 1: elision (gap of 3 lines)
    try testing.expectEqual(@as(u21, '·'), buf.get(0, 1).grapheme.codepoint);
    // Row 2: │ line4 (first of last 5)
    try testing.expectEqual(@as(u21, '│'), buf.get(0, 2).grapheme.codepoint);
    // Last visible content row has line8, then bottom chrome
    try testing.expectEqual(@as(u21, '╰'), buf.get(0, 7).grapheme.codepoint);
}

test "bash renderResult expanded shows all lines in box" {
    var buf = try Buffer.init(testing.allocator, 40, 12);
    defer buf.deinit();

    const output = "line1\nline2\nline3\nline4\nline5\nline6";
    var content = [_]agent_protocol.AgentToolResult.ContentBlock{
        .{ .text = .{ .text = output } },
    };

    const ctx = ToolRenderContext{
        .tool_name = "Bash",
        .tool_call_id = "test-3",
        .args = .null,
        .result = .{ .content = &content },
        .is_partial = false,
        .is_error = false,
        .expanded = true,
        .execution_started = true,
        .args_complete = true,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = buf.region(),
        .width = 40,
    };
    renderResult(&ctx);

    // Row 0: top chrome
    try testing.expectEqual(@as(u21, '╭'), buf.get(0, 0).grapheme.codepoint);
    // Row 1: │ line1
    try testing.expectEqual(@as(u21, '│'), buf.get(0, 1).grapheme.codepoint);
    // Row 7: bottom chrome (top + 6 lines + bottom)
    try testing.expectEqual(@as(u21, '╰'), buf.get(0, 7).grapheme.codepoint);
}

test "bash measureResult returns box chrome height" {
    const output = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8";
    var content = [_]agent_protocol.AgentToolResult.ContentBlock{
        .{ .text = .{ .text = output } },
    };

    const ctx = ToolRenderContext{
        .tool_name = "Bash",
        .tool_call_id = "test-4",
        .args = .null,
        .result = .{ .content = &content },
        .is_partial = false,
        .is_error = false,
        .expanded = false,
        .execution_started = true,
        .args_complete = true,
        .theme = &theme_mod.Theme.dark,
        .allocator = testing.allocator,
        .state = null,
        .region = undefined,
        .width = 40,
    };
    // 8 lines collapsed: gap(3) + span(5) → measureHeight(5, 1) = 1+5+1+1 = 8
    const h = measureResultFn(&ctx);
    try testing.expectEqual(@as(u32, 8), h);
}
