const std = @import("std");
const rendered_tool_result_mod = @import("../../agent/rendered_tool_result.zig");
const theme_mod = @import("../theme.zig");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");

const Region = buffer_mod.Region;
const Color = cell_mod.Color;

pub const Span = rendered_tool_result_mod.Span;
pub const Line = rendered_tool_result_mod.Line;
pub const RenderedToolResult = rendered_tool_result_mod.RenderedToolResult;

pub fn measure(state: *const RenderedToolResult, expanded: bool) u32 {
    return @intCast((if (expanded) state.expanded else state.collapsed).len);
}

pub fn renderSlice(
    state: *const RenderedToolResult,
    region: Region,
    theme: *const theme_mod.Theme,
    expanded: bool,
    first_row: u32,
) void {
    const lines = if (expanded) state.expanded else state.collapsed;
    var row: u32 = 0;
    var idx: usize = @intCast(first_row);
    while (idx < lines.len and row < region.height) : ({
        idx += 1;
        row += 1;
    }) {
        renderLine(lines[idx], region, theme, row);
    }
}

fn renderLine(line: Line, region: Region, theme: *const theme_mod.Theme, row: u32) void {
    var col: u32 = 0;
    for (line) |span| {
        if (col >= region.width) break;
        const fg = if (span.fg) |role| theme.fg(role) else Color.default;
        const bg = if (span.bg) |role| theme.bg(role) else Color.default;
        const attrs: cell_mod.Attributes = .{
            .bold = span.bold,
            .dim = span.dim,
            .italic = span.italic,
            .underline = span.underline,
        };
        const written = region.writeStr(col, row, span.text, fg, bg, attrs);
        col +|= written;
    }
}
