const std = @import("std");

pub const LogicalCursor = struct {
    byte: u32,
    line: u32,
    col: u32,
};

pub const VisualCursor = struct {
    visual_row: u32,
    visual_col: u32,
    logical_line: u32,
    logical_col: u32,
    byte: u32,
};

pub const VirtualLineKind = enum {
    prompt_first,
    wrapped_continuation,
};

pub const VirtualLine = struct {
    byte_start: u32,
    byte_end: u32,
    logical_line: u32,
    logical_col_start: u32,
    width_cols: u32,
    text_col: u32,
    kind: VirtualLineKind,
};

pub const LayoutConfig = struct {
    width_cols: u32,
    first_line_text_col: u32,
    continuation_text_col: u32,

    pub fn eql(a: LayoutConfig, b: LayoutConfig) bool {
        return a.width_cols == b.width_cols and
            a.first_line_text_col == b.first_line_text_col and
            a.continuation_text_col == b.continuation_text_col;
    }
};

pub const Viewport = struct {
    scroll_x: u32 = 0,
    scroll_y: u32 = 0,
    width_cols: u32 = 1,
    height_rows: u32 = 1,
};
