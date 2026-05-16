const std = @import("std");
const breaks_mod = @import("../wrap/breaks.zig");
const grapheme_mod = @import("../grapheme.zig");
const buffer_mod = @import("buffer.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const EditBuffer = buffer_mod.EditBuffer;
const LayoutConfig = types.LayoutConfig;
const VirtualLine = types.VirtualLine;
const VirtualLineKind = types.VirtualLineKind;

pub const TextAreaLayoutCache = struct {
    arena: std.heap.ArenaAllocator,
    virtual_lines: []const VirtualLine = &.{},
    buffer_version: u64 = 0,
    config: ?LayoutConfig = null,
    generation: u64 = 0,

    pub fn init(allocator: Allocator) TextAreaLayoutCache {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *TextAreaLayoutCache) void {
        self.arena.deinit();
    }

    pub fn invalidateAll(self: *TextAreaLayoutCache) void {
        self.buffer_version = 0;
        self.config = null;
        self.virtual_lines = &.{};
    }

    pub fn ensure(self: *TextAreaLayoutCache, buffer: *const EditBuffer, config: LayoutConfig) void {
        if (self.config) |current| {
            if (current.eql(config) and self.buffer_version == buffer.version()) return;
        }

        _ = self.arena.reset(.retain_capacity);
        const allocator = self.arena.allocator();
        self.virtual_lines = buildVirtualLines(buffer, config, allocator) catch &.{};
        self.buffer_version = buffer.version();
        self.config = config;
        self.generation +%= 1;
    }

    pub fn lines(self: *const TextAreaLayoutCache) []const VirtualLine {
        return self.virtual_lines;
    }
};

fn buildVirtualLines(buffer: *const EditBuffer, config: LayoutConfig, allocator: Allocator) ![]const VirtualLine {
    var lines: std.ArrayList(VirtualLine) = .empty;
    errdefer lines.deinit(allocator);

    const items = buffer.text();
    const first_text_width = if (config.width_cols > config.first_line_text_col)
        config.width_cols - config.first_line_text_col
    else
        1;
    const continuation_text_width = if (config.width_cols > config.continuation_text_col)
        config.width_cols - config.continuation_text_col
    else
        1;

    var logical_line: u32 = 0;
    var line_start: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfScalarPos(u8, items, line_start, '\n') orelse items.len;
        const line_text = items[line_start..line_end];

        try appendWrappedSlices(
            &lines,
            line_text,
            @intCast(line_start),
            logical_line,
            if (logical_line == 0) .prompt_first else .wrapped_continuation,
            if (logical_line == 0) config.first_line_text_col else config.continuation_text_col,
            if (logical_line == 0) first_text_width else continuation_text_width,
            continuation_text_width,
            config.continuation_text_col,
            allocator,
            buffer.width_method,
        );

        logical_line += 1;
        if (line_end >= items.len) break;
        line_start = line_end + 1;
    }

    if (lines.items.len == 0) {
        try lines.append(allocator, .{
            .byte_start = 0,
            .byte_end = 0,
            .logical_line = 0,
            .logical_col_start = 0,
            .width_cols = 0,
            .text_col = config.first_line_text_col,
            .kind = .prompt_first,
        });
    }

    return try lines.toOwnedSlice(allocator);
}

fn appendWrappedSlices(
    out: *std.ArrayList(VirtualLine),
    line_text: []const u8,
    base_start: u32,
    logical_line: u32,
    first_kind: VirtualLineKind,
    first_text_col: u32,
    first_width: u32,
    continuation_width: u32,
    continuation_text_col: u32,
    allocator: Allocator,
    width_method: grapheme_mod.WidthMethod,
) !void {
    var start: usize = 0;
    var current_kind = first_kind;
    var current_text_col = first_text_col;
    var current_width = @max(@as(u32, 1), first_width);
    var logical_col_start: u32 = 0;
    var continuation = false;

    while (breaks_mod.nextSegment(line_text, start, current_width, continuation, .{}, width_method)) |segment| {
        try out.append(allocator, .{
            .byte_start = base_start + @as(u32, @intCast(segment.start)),
            .byte_end = base_start + @as(u32, @intCast(segment.end)),
            .logical_line = logical_line,
            .logical_col_start = logical_col_start,
            .width_cols = segment.width_cols,
            .text_col = current_text_col,
            .kind = current_kind,
        });

        if (segment.next_start >= line_text.len) break;

        logical_col_start += @intCast(grapheme_mod.strWidth(line_text[start..segment.next_start], width_method));
        start = segment.next_start;
        current_kind = .wrapped_continuation;
        current_text_col = continuation_text_col;
        current_width = @max(@as(u32, 1), continuation_width);
        continuation = true;
    }
}
