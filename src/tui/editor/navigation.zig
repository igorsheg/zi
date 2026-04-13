const buffer_mod = @import("buffer.zig");
const types = @import("types.zig");

const PromptBuffer = buffer_mod.PromptBuffer;
const LogicalCursor = types.LogicalCursor;
const VirtualLine = types.VirtualLine;
const VisualCursor = types.VisualCursor;

pub fn moveVisual(
    buffer: *const PromptBuffer,
    virtual_lines: []const VirtualLine,
    current_row: u32,
    current_cursor: VisualCursor,
    desired_visual_col: *?u32,
    direction: i32,
) ?LogicalCursor {
    if (virtual_lines.len == 0) return null;

    const current_row_i: i32 = @intCast(current_row);
    const target_row_i = current_row_i + direction;
    if (target_row_i < 0 or target_row_i >= virtual_lines.len) return null;

    const current_line = virtual_lines[current_row];
    const target_row: u32 = @intCast(target_row_i);
    const target_line = virtual_lines[target_row];

    const column_within_line = desired_visual_col.* orelse (current_cursor.visual_col - current_line.text_col);
    desired_visual_col.* = column_within_line;

    const target_byte = buffer.byteAtDisplayCol(target_line.byte_start, target_line.byte_end, column_within_line);
    return .{
        .byte = target_byte,
        .line = target_line.logical_line,
        .col = buffer.displayColAtByte(target_byte),
    };
}
