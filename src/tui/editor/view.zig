const std = @import("std");
const buffer_mod = @import("buffer.zig");
const layout_mod = @import("layout.zig");
const navigation_mod = @import("navigation.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const PromptBuffer = buffer_mod.PromptBuffer;
const PromptLayoutCache = layout_mod.PromptLayoutCache;
const LayoutConfig = types.LayoutConfig;
const LogicalCursor = types.LogicalCursor;
const Viewport = types.Viewport;
const VirtualLine = types.VirtualLine;
const VisualCursor = types.VisualCursor;

const ResolvedCursor = struct {
    absolute_row: u32,
    cursor: VisualCursor,
};

const CursorCache = struct {
    buffer_version: u64,
    layout_generation: u64,
    cursor_byte: u32,
    resolved: ResolvedCursor,
};

pub const PromptView = struct {
    buffer: *PromptBuffer,
    layout: PromptLayoutCache,
    viewport: Viewport = .{},
    layout_config: LayoutConfig = .{
        .width_cols = 1,
        .first_line_text_col = 1,
        .continuation_text_col = 1,
    },
    scroll_margin: f32 = 0.15,
    desired_visual_col: ?u32 = null,
    cursor_cache: ?CursorCache = null,

    pub fn init(allocator: Allocator, buffer: *PromptBuffer) PromptView {
        return .{
            .buffer = buffer,
            .layout = PromptLayoutCache.init(allocator),
        };
    }

    pub fn deinit(self: *PromptView) void {
        self.layout.deinit();
    }

    pub fn setLayoutConfig(self: *PromptView, config: LayoutConfig) void {
        if (!self.layout_config.eql(config)) {
            self.layout_config = config;
            self.cursor_cache = null;
        }
        self.viewport.width_cols = config.width_cols;
    }

    pub fn setViewportHeight(self: *PromptView, height_rows: u32) void {
        self.viewport.height_rows = @max(@as(u32, 1), height_rows);
        self.clampViewport();
    }

    pub fn resetViewport(self: *PromptView) void {
        self.viewport.scroll_x = 0;
        self.viewport.scroll_y = 0;
        self.cursor_cache = null;
    }

    pub fn setScrollMargin(self: *PromptView, margin: f32) void {
        self.scroll_margin = @max(0.0, @min(0.5, margin));
    }

    pub fn ensureLayout(self: *PromptView) void {
        self.layout.ensure(self.buffer, self.layout_config);
        self.clampViewport();
    }

    pub fn invalidateAll(self: *PromptView) void {
        self.layout.invalidateAll();
        self.cursor_cache = null;
    }

    pub fn visibleLines(self: *PromptView) []const VirtualLine {
        self.ensureLayout();
        const all = self.layout.lines();
        const start = @min(self.viewport.scroll_y, @as(u32, @intCast(all.len)));
        const end = @min(start + self.viewport.height_rows, @as(u32, @intCast(all.len)));
        return all[start..end];
    }

    pub fn totalVisualLineCount(self: *PromptView) u32 {
        self.ensureLayout();
        return @intCast(self.layout.lines().len);
    }

    pub fn viewportState(self: *const PromptView) Viewport {
        return self.viewport;
    }

    pub fn viewportHeight(self: *const PromptView) u32 {
        return self.viewport.height_rows;
    }

    pub fn clearDesiredVisualColumn(self: *PromptView) void {
        self.desired_visual_col = null;
    }

    pub fn visualCursor(self: *PromptView) ?VisualCursor {
        self.ensureLayout();
        self.ensureCursorVisible();
        const resolved = self.resolveCursor() orelse return null;
        if (resolved.absolute_row < self.viewport.scroll_y) return null;
        return .{
            .visual_row = resolved.absolute_row - self.viewport.scroll_y,
            .visual_col = resolved.cursor.visual_col,
            .logical_line = resolved.cursor.logical_line,
            .logical_col = resolved.cursor.logical_col,
            .byte = resolved.cursor.byte,
        };
    }

    pub fn logicalToVisual(self: *PromptView, logical: LogicalCursor) ?VisualCursor {
        self.ensureLayout();
        const resolved = self.logicalToResolved(logical) orelse return null;
        if (resolved.absolute_row < self.viewport.scroll_y) return null;
        return .{
            .visual_row = resolved.absolute_row - self.viewport.scroll_y,
            .visual_col = resolved.cursor.visual_col,
            .logical_line = resolved.cursor.logical_line,
            .logical_col = resolved.cursor.logical_col,
            .byte = resolved.cursor.byte,
        };
    }

    pub fn visualToLogical(self: *PromptView, row: u32, col: u32) ?LogicalCursor {
        self.ensureLayout();
        const absolute_row = self.viewport.scroll_y + row;
        const lines = self.layout.lines();
        if (absolute_row >= lines.len) return null;
        const line = lines[absolute_row];
        const target_col = col -| line.text_col;
        const target_byte = self.buffer.byteAtDisplayCol(line.byte_start, line.byte_end, target_col);
        return .{
            .byte = target_byte,
            .line = line.logical_line,
            .col = self.buffer.displayColAtByte(target_byte),
        };
    }

    pub fn moveUpVisual(self: *PromptView) void {
        self.moveVisual(-1);
    }

    pub fn moveDownVisual(self: *PromptView) void {
        self.moveVisual(1);
    }

    pub fn ensureCursorVisible(self: *PromptView) void {
        self.ensureLayout();
        const resolved = self.resolveCursor() orelse return;
        const cursor_row = resolved.absolute_row;
        const total_lines = @as(u32, @intCast(self.layout.lines().len));
        const height = self.viewport.height_rows;
        if (height == 0) return;

        const margin = self.verticalMarginRows();
        const max_offset = if (total_lines > height) total_lines - height else 0;
        var new_scroll = self.viewport.scroll_y;

        if (cursor_row < self.viewport.scroll_y + margin) {
            new_scroll = if (cursor_row >= margin) cursor_row - margin else 0;
        } else if (cursor_row >= self.viewport.scroll_y + height - margin) {
            const desired = cursor_row + margin - height + 1;
            new_scroll = @min(desired, max_offset);
        }

        if (new_scroll != self.viewport.scroll_y) {
            self.viewport.scroll_y = new_scroll;
            self.cursor_cache = null;
        }
    }

    pub fn isCursorOnFirstVisualLine(self: *PromptView) bool {
        self.ensureLayout();
        const resolved = self.resolveCursor() orelse return true;
        return resolved.absolute_row == 0;
    }

    pub fn isCursorOnLastVisualLine(self: *PromptView) bool {
        self.ensureLayout();
        const resolved = self.resolveCursor() orelse return true;
        return resolved.absolute_row + 1 >= self.layout.lines().len;
    }

    fn moveVisual(self: *PromptView, direction: i32) void {
        self.ensureLayout();
        const resolved = self.resolveCursor() orelse return;
        const next = navigation_mod.moveVisual(
            self.buffer,
            self.layout.lines(),
            resolved.absolute_row,
            resolved.cursor,
            &self.desired_visual_col,
            direction,
        ) orelse return;
        self.buffer.setCursorByte(next.byte);
        self.cursor_cache = null;
        self.ensureCursorVisible();
    }

    fn resolveCursor(self: *PromptView) ?ResolvedCursor {
        const buffer_version = self.buffer.version();
        const cursor_byte = self.buffer.cursorByte();
        if (self.cursor_cache) |cache| {
            if (cache.buffer_version == buffer_version and
                cache.layout_generation == self.layout.generation and
                cache.cursor_byte == cursor_byte)
            {
                return cache.resolved;
            }
        }

        const resolved = self.logicalToResolved(self.buffer.cursor()) orelse return null;
        self.cursor_cache = .{
            .buffer_version = buffer_version,
            .layout_generation = self.layout.generation,
            .cursor_byte = cursor_byte,
            .resolved = resolved,
        };
        return resolved;
    }

    fn logicalToResolved(self: *PromptView, logical: LogicalCursor) ?ResolvedCursor {
        const lines = self.layout.lines();
        if (lines.len == 0) {
            return .{
                .absolute_row = 0,
                .cursor = .{
                    .visual_row = 0,
                    .visual_col = self.layout_config.first_line_text_col,
                    .logical_line = logical.line,
                    .logical_col = logical.col,
                    .byte = logical.byte,
                },
            };
        }

        for (lines, 0..) |line, idx| {
            const next_start = if (idx + 1 < lines.len) lines[idx + 1].byte_start else line.byte_end;
            if (logical.byte >= line.byte_start and logical.byte <= line.byte_end) {
                const col_in_line = self.buffer.displayColAtByte(logical.byte) - line.logical_col_start;
                return .{
                    .absolute_row = @intCast(idx),
                    .cursor = .{
                        .visual_row = 0,
                        .visual_col = line.text_col + col_in_line,
                        .logical_line = logical.line,
                        .logical_col = logical.col,
                        .byte = logical.byte,
                    },
                };
            }
            if (logical.byte > line.byte_end and logical.byte < next_start) {
                return .{
                    .absolute_row = @intCast(idx),
                    .cursor = .{
                        .visual_row = 0,
                        .visual_col = line.text_col + line.width_cols,
                        .logical_line = logical.line,
                        .logical_col = logical.col,
                        .byte = logical.byte,
                    },
                };
            }
        }

        const last = lines[lines.len - 1];
        return .{
            .absolute_row = @intCast(lines.len - 1),
            .cursor = .{
                .visual_row = 0,
                .visual_col = last.text_col + last.width_cols,
                .logical_line = logical.line,
                .logical_col = logical.col,
                .byte = logical.byte,
            },
        };
    }

    fn verticalMarginRows(self: *const PromptView) u32 {
        const height = self.viewport.height_rows;
        if (height <= 1) return 0;
        const raw = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * self.scroll_margin)));
        return @min(raw, (height - 1) / 2);
    }

    fn clampViewport(self: *PromptView) void {
        const total_lines: u32 = @intCast(self.layout.lines().len);
        const height = self.viewport.height_rows;
        const max_offset = if (total_lines > height) total_lines - height else 0;
        if (self.viewport.scroll_y > max_offset) {
            self.viewport.scroll_y = max_offset;
            self.cursor_cache = null;
        }
    }
};

const testing = std.testing;

test "PromptView reuses cached virtual lines across repeated cursor queries" {
    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("hello world");

    var view = PromptView.init(testing.allocator, &buffer);
    defer view.deinit();
    view.setLayoutConfig(.{ .width_cols = 10, .first_line_text_col = 3, .continuation_text_col = 3 });
    view.setViewportHeight(4);

    _ = view.totalVisualLineCount();
    const generation = view.layout.generation;
    _ = view.visualCursor();
    _ = view.visualCursor();

    try testing.expectEqual(generation, view.layout.generation);
}

test "PromptView wrapped visual up down preserves desired visual column" {
    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("abcd efgh ijkl");

    var view = PromptView.init(testing.allocator, &buffer);
    defer view.deinit();
    view.setLayoutConfig(.{ .width_cols = 9, .first_line_text_col = 3, .continuation_text_col = 3 });
    view.setViewportHeight(3);
    view.ensureLayout();

    buffer.setCursorByte(5);
    view.clearDesiredVisualColumn();
    view.moveDownVisual();
    const down = buffer.cursor();
    try testing.expectEqual(@as(u32, 10), down.byte);
    try testing.expectEqual(@as(u32, 10), down.col);

    view.moveUpVisual();
    const up = buffer.cursor();
    try testing.expectEqual(@as(u32, 5), up.byte);
    try testing.expectEqual(@as(u32, 5), up.col);
}

test "PromptView ensureCursorVisible keeps cursor inside scroll margins" {
    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("one two three four five six seven");

    var view = PromptView.init(testing.allocator, &buffer);
    defer view.deinit();
    view.setLayoutConfig(.{ .width_cols = 9, .first_line_text_col = 3, .continuation_text_col = 3 });
    view.setViewportHeight(2);
    view.ensureCursorVisible();

    try testing.expect(view.viewport.scroll_y > 0);
    const cursor = view.visualCursor().?;
    try testing.expect(cursor.visual_row < view.viewport.height_rows);
}

test "PromptView resize reflows once and keeps cursor visible" {
    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("alpha beta gamma delta epsilon");

    var view = PromptView.init(testing.allocator, &buffer);
    defer view.deinit();
    view.setLayoutConfig(.{ .width_cols = 16, .first_line_text_col = 3, .continuation_text_col = 3 });
    view.setViewportHeight(3);
    _ = view.totalVisualLineCount();
    const before = view.layout.generation;

    view.setLayoutConfig(.{ .width_cols = 10, .first_line_text_col = 3, .continuation_text_col = 3 });
    _ = view.totalVisualLineCount();
    const after_resize = view.layout.generation;
    _ = view.visualCursor();

    try testing.expectEqual(before + 1, after_resize);
    try testing.expectEqual(after_resize, view.layout.generation);
    const cursor = view.visualCursor().?;
    try testing.expect(cursor.visual_row < view.viewport.height_rows);
}
