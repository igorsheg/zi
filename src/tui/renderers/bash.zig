const std = @import("std");
const tool_display_mod = @import("../tool_display.zig");
const buffer_mod = @import("../buffer.zig");
const cell_mod = @import("../cell.zig");
const word_wrap_mod = @import("../word_wrap.zig");
const theme_mod = @import("../theme.zig");

const ToolRenderer = tool_display_mod.ToolRenderer;
const ToolRenderContext = tool_display_mod.ToolRenderContext;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;

/// Preview line limit when collapsed (pi-mono: BASH_PREVIEW_LINES = 5).
/// Shows the LAST N lines (most recent output), not the first N.
const PREVIEW_LINES: u32 = 5;

pub const renderer = ToolRenderer{
    .render_call = renderCall,
    .render_result = renderResult,
};

/// Render: `$ {command}` in bold, with optional timeout suffix.
fn renderCall(ctx: *const ToolRenderContext) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;

    const command = extractCommand(ctx.args);
    const theme = ctx.theme;

    // "$ " prefix
    var col: u32 = 0;
    col += region.writeStr(col, 0, "$ ", theme.fg(.tool_title), Color.default, .{ .bold = true });

    if (command) |cmd| {
        _ = region.writeStr(col, 0, cmd, theme.fg(.tool_title), Color.default, .{ .bold = true });
    } else {
        _ = region.writeStr(col, 0, "...", theme.fg(.tool_output), Color.default, .{});
    }
}

/// Render result: output lines with "earlier lines" truncation when collapsed.
fn renderResult(ctx: *const ToolRenderContext) void {
    const region = ctx.region;
    if (region.width == 0 or region.height == 0) return;

    const result_text = getResultText(ctx) orelse return;
    defer ctx.allocator.free(result_text);

    const trimmed = std.mem.trim(u8, result_text, " \t\n\r");
    if (trimmed.len == 0) return;

    const theme = ctx.theme;
    const fg = if (ctx.is_error) theme.fg(.@"error") else theme.fg(.tool_output);
    const w: usize = @intCast(region.width);
    const lines = word_wrap_mod.wordWrap(trimmed, w, ctx.allocator) catch return;
    defer ctx.allocator.free(lines);

    const total_lines: u32 = @intCast(lines.len);
    if (total_lines == 0) return;

    if (ctx.expanded) {
        // Show all lines
        var row: u32 = 0;
        for (lines) |line| {
            if (row >= region.height) break;
            _ = region.writeStr(0, row, line.text(trimmed), fg, Color.default, .{});
            row += 1;
        }
    } else {
        // Show last PREVIEW_LINES lines (pi-mono shows tail, not head)
        const preview_count = @min(total_lines, PREVIEW_LINES);
        const skipped = total_lines - preview_count;
        var row: u32 = 0;

        // "... (N earlier lines)" hint
        if (skipped > 0 and row < region.height) {
            var hint_buf: [80]u8 = undefined;
            const hint = std.fmt.bufPrint(&hint_buf, "... ({d} earlier lines, ctrl+o to expand)", .{skipped}) catch "...";
            _ = region.writeStr(0, row, hint, theme.fg(.dim), Color.default, .{});
            row += 1;
        }

        // Tail lines
        const start_idx = total_lines - preview_count;
        var i: u32 = start_idx;
        while (i < total_lines and row < region.height) {
            const line = lines[i];
            _ = region.writeStr(0, row, line.text(trimmed), fg, Color.default, .{});
            row += 1;
            i += 1;
        }
    }
}

/// Extract the "command" field from args json object.
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

/// Extract joined text from result content blocks.
fn getResultText(ctx: *const ToolRenderContext) ?[]u8 {
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
    if (pos < buf.len) {
        return ctx.allocator.realloc(buf, pos) catch buf[0..pos];
    }
    return buf;
}

/// Measure height for bash result rendering.
pub fn measureResult(ctx: *const ToolRenderContext) u32 {
    const result_text = getResultText(ctx) orelse return 0;
    defer ctx.allocator.free(result_text);

    const trimmed = std.mem.trim(u8, result_text, " \t\n\r");
    if (trimmed.len == 0) return 0;

    const w: usize = @intCast(ctx.width);
    const lines = word_wrap_mod.wordWrap(trimmed, w, ctx.allocator) catch return 1;
    defer ctx.allocator.free(lines);

    const total: u32 = @intCast(lines.len);
    if (ctx.expanded) return total;

    const preview = @min(total, PREVIEW_LINES);
    const skipped = total - preview;
    return preview + if (skipped > 0) @as(u32, 1) else @as(u32, 0); // +1 for hint line
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;
const agent_protocol = @import("../../agent/root.zig").protocol;

test "bash renderCall shows $ command" {
    var buf = try Buffer.init(testing.allocator, 40, 1);
    defer buf.deinit();

    // Build args: {"command": "echo hello"}
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

    // Should show "$ echo hello"
    try testing.expectEqual(@as(u21, '$'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, ' '), buf.get(1, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'e'), buf.get(2, 0).grapheme.codepoint);
}

test "bash renderResult shows truncated output with hint" {
    var buf = try Buffer.init(testing.allocator, 40, 10);
    defer buf.deinit();

    // Create 8-line output
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

    // First row should be hint "... (3 earlier lines, ctrl+o to expand)"
    try testing.expectEqual(@as(u21, '.'), buf.get(0, 0).grapheme.codepoint);

    // Second row should be "line4" (first of the last 5 lines)
    try testing.expectEqual(@as(u21, 'l'), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'i'), buf.get(1, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'n'), buf.get(2, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'e'), buf.get(3, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '4'), buf.get(4, 1).grapheme.codepoint);
}

test "bash renderResult expanded shows all lines" {
    var buf = try Buffer.init(testing.allocator, 40, 10);
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

    // First row should be "line1"
    try testing.expectEqual(@as(u21, 'l'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '1'), buf.get(4, 0).grapheme.codepoint);
    // Last row should be "line6"
    try testing.expectEqual(@as(u21, '6'), buf.get(4, 5).grapheme.codepoint);
}
