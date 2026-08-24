// Adapted from vercel-labs/fx src/ui/footer/surface_frame.zig.
// Owns footer measurement and typed surface painting for one frame.
const std = @import("std");
const ai = @import("../../ai/root.zig");
const interactive = @import("../../coding_agent/root.zig").interactive;
const terminal_render = @import("../../terminal_render/root.zig");
const FooterLayout = @import("../render_engine/FooterLayout.zig");
const SlashMenu = @import("../input/SlashMenu.zig");
const SafeText = @import("../SafeText.zig");
const presentation = @import("presentation.zig");

const prompt = "❯ ";

pub const ComposerView = struct {
    text: []const u8,
    cursor_byte: usize,
    masked: bool = false,
};

pub const SlashMenuProjection = SlashMenu.Projection;

pub const View = struct {
    composer: ComposerView,
    phase: interactive.Phase,
    queued_count: usize,
    active_tool: ?[]const u8,
    active_model: ?ai.ModelIdentity = null,
    thinking_level: ?ai.ThinkingLevel = null,
    cwd: []const u8 = "",
    slash_menu: ?SlashMenuProjection = null,
};

const MenuRow = struct {
    text: []const u8,
    selected: bool = false,
};

pub const SurfaceFooterFrame = struct {
    layout: FooterLayout,
    composer_text: []const u8,
    status_text: []const u8,
    menu_rows: []const MenuRow,

    pub fn rowCount(self: SurfaceFooterFrame) u16 {
        return self.layout.surface_rows;
    }

    pub fn paint(
        self: SurfaceFooterFrame,
        surface: *terminal_render.Surface,
        row_offset: u16,
    ) !void {
        if (self.layout.menu) |menu| {
            for (self.menu_rows, 0..) |row, index| {
                if (index >= menu.row_count) break;
                _ = try surface.writeText(
                    menu.first_row + row_offset + @as(u16, @intCast(index)),
                    1,
                    row.text,
                    if (row.selected)
                        .{ .attributes = .{ .inverse = true } }
                    else
                        .{ .attributes = .{ .dim = true } },
                );
            }
        }
        if (self.layout.status) |status| {
            _ = try surface.writeText(
                status.first_row + row_offset,
                1,
                self.status_text,
                .{ .attributes = .{ .dim = true } },
            );
        }
        for (self.layout.visibleLines(), 0..) |line, visible_index| {
            const row = self.layout.composer.first_row + row_offset +
                @as(u16, @intCast(visible_index));
            if (self.layout.sourceLineIndex(visible_index) == 0 and line.start_column > 1) {
                _ = try surface.writeText(row, 1, prompt, .{
                    .attributes = .{ .bold = true },
                });
            }
            _ = try surface.writeText(
                row,
                line.start_column,
                self.composer_text[line.start_byte..line.end_byte],
                .{},
            );
        }
        try surface.setCursor(.{
            .row = self.layout.cursor.row + row_offset,
            .column = self.layout.cursor.column,
        });
    }
};

pub fn prepare(
    arena: std.mem.Allocator,
    terminal_rows: u16,
    columns: u16,
    view: View,
) !SurfaceFooterFrame {
    const masked_text = if (view.composer.masked)
        try arena.alloc(u8, view.composer.text.len)
    else
        null;
    if (masked_text) |text| @memset(text, '*');
    const composer_text = masked_text orelse view.composer.text;
    const desired_menu_rows: u16 = if (view.slash_menu) |menu|
        1 + @as(u16, @intCast(@min(menu.count, 6)))
    else
        0;
    const layout = try FooterLayout.initWithMenu(
        arena,
        terminal_rows,
        columns,
        composer_text,
        view.composer.cursor_byte,
        @intCast(terminal_render.Text.displayWidth(prompt)),
        desired_menu_rows,
    );
    const menu_rows = try prepareMenuRows(arena, view.slash_menu, layout.menu);
    return .{
        .layout = layout,
        .composer_text = composer_text,
        .status_text = try prepareStatusText(arena, columns, view),
        .menu_rows = menu_rows,
    };
}

fn prepareStatusText(
    arena: std.mem.Allocator,
    columns: u16,
    view: View,
) ![]const u8 {
    var hint: std.Io.Writer.Allocating = .init(arena);
    defer hint.deinit();
    try presentation.writeHint(
        &hint.writer,
        view.phase,
        view.active_tool,
        view.queued_count,
    );

    const model = if (view.active_model) |identity| model: {
        const raw = try std.fmt.allocPrint(arena, "{s}/{s}", .{ identity.provider, identity.model });
        break :model try sanitizeStatusText(arena, raw);
    } else null;
    const thinking = if (view.thinking_level) |level|
        try std.fmt.allocPrint(arena, "thinking {s}", .{@tagName(level)})
    else
        null;
    const cwd = if (view.cwd.len == 0) "" else try sanitizeStatusText(arena, view.cwd);
    var status: std.ArrayList(u8) = .empty;
    var used_cells: usize = 0;
    const max_cells: usize = columns;

    if (actionHasPriority(view.phase)) {
        if (!try appendStatusSegment(arena, &status, &used_cells, max_cells, hint.written())) {
            return status.toOwnedSlice(arena);
        }
        if (model) |value| if (!try appendStatusSegment(
            arena,
            &status,
            &used_cells,
            max_cells,
            value,
        )) return status.toOwnedSlice(arena);
        if (thinking) |value| if (!try appendStatusSegment(
            arena,
            &status,
            &used_cells,
            max_cells,
            value,
        )) return status.toOwnedSlice(arena);
        if (cwd.len != 0) _ = try appendCwdStatusSegment(
            arena,
            &status,
            &used_cells,
            max_cells,
            cwd,
        );
    } else {
        if (model) |value| if (!try appendStatusSegment(
            arena,
            &status,
            &used_cells,
            max_cells,
            value,
        )) return status.toOwnedSlice(arena);
        if (thinking) |value| _ = try appendStatusSegment(
            arena,
            &status,
            &used_cells,
            max_cells,
            value,
        );
        if (cwd.len != 0 and !try appendCwdStatusSegment(
            arena,
            &status,
            &used_cells,
            max_cells,
            cwd,
        )) return status.toOwnedSlice(arena);
        _ = try appendStatusSegment(arena, &status, &used_cells, max_cells, hint.written());
    }
    return status.toOwnedSlice(arena);
}

fn sanitizeStatusText(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var sanitized: std.Io.Writer.Allocating = .init(arena);
    defer sanitized.deinit();
    try SafeText.write(&sanitized.writer, text, false);
    return sanitized.toOwnedSlice();
}

fn appendCwdStatusSegment(
    arena: std.mem.Allocator,
    status: *std.ArrayList(u8),
    used_cells: *usize,
    max_cells: usize,
    cwd: []const u8,
) !bool {
    const separator_width = if (status.items.len == 0) 0 else terminal_render.Text.displayWidth(" · ");
    const available = max_cells -| used_cells.* -| separator_width;
    if (terminal_render.Text.displayWidth(cwd) <= available) {
        return appendStatusSegment(arena, status, used_cells, max_cells, cwd);
    }
    const basename = std.fs.path.basename(cwd);
    const abbreviated = try std.fmt.allocPrint(arena, "…/{s}", .{basename});
    return appendStatusSegment(arena, status, used_cells, max_cells, abbreviated);
}

fn actionHasPriority(phase: interactive.Phase) bool {
    return switch (phase) {
        .turn => |turn| turn != .idle,
        .model_less, .authenticating, .transitioning, .unavailable => true,
    };
}

/// Appends one segment without exceeding terminal display cells. The leading
/// segment may clip; later segments are omitted unless they fit completely.
fn appendStatusSegment(
    arena: std.mem.Allocator,
    status: *std.ArrayList(u8),
    used_cells: *usize,
    max_cells: usize,
    text: []const u8,
) !bool {
    if (text.len == 0 or max_cells == 0) return true;
    const separator = " · ";
    const saved_len = status.items.len;
    const saved_cells = used_cells.*;
    if (status.items.len != 0) {
        const separator_width = terminal_render.Text.displayWidth(separator);
        const required_width = separator_width + terminal_render.Text.displayWidth(text);
        if (required_width > max_cells -| used_cells.*) return false;
        try status.appendSlice(arena, separator);
        used_cells.* += separator_width;
    }

    const segment_start = status.items.len;
    var iterator = terminal_render.Text.Iterator.init(text);
    var complete = true;
    while (iterator.next()) |grapheme| {
        if (grapheme.kind == .line_break or grapheme.width > max_cells -| used_cells.*) {
            complete = false;
            break;
        }
        if (grapheme.width == 0) continue;
        try status.appendSlice(arena, grapheme.bytes);
        used_cells.* += grapheme.width;
    }
    if (status.items.len == segment_start) {
        status.items.len = saved_len;
        used_cells.* = saved_cells;
    }
    return complete;
}

fn prepareMenuRows(
    arena: std.mem.Allocator,
    projection: ?SlashMenuProjection,
    band: ?FooterLayout.Band,
) ![]const MenuRow {
    const menu = projection orelse return &.{};
    const visible_rows = (band orelse return &.{}).row_count;
    var rows: std.ArrayList(MenuRow) = .empty;
    try rows.ensureTotalCapacity(arena, visible_rows);
    rows.appendAssumeCapacity(.{
        .text = try std.fmt.allocPrint(arena, "Commands {d} · Type to filter", .{menu.count}),
    });
    if (visible_rows == 1 or menu.count == 0) return rows.toOwnedSlice(arena);

    const option_rows: usize = visible_rows - 1;
    const selected = menu.selected_index % menu.count;
    const max_start = menu.count -| option_rows;
    const window_start = @min(@max(menu.window_start, selected + 1 -| option_rows), max_start);
    const window_end = @min(window_start + option_rows, menu.count);
    for (window_start..window_end) |index| {
        const spec = interactive.slashCommandCompletionAt(menu.prefix, index) orelse continue;
        rows.appendAssumeCapacity(.{
            .text = try std.fmt.allocPrint(
                arena,
                "{s} {s}  {s}",
                .{ if (index == selected) "›" else " ", spec.usage, spec.description },
            ),
            .selected = index == selected,
        });
    }
    return rows.toOwnedSlice(arena);
}

test "surface footer frame paints a bounded slash menu above the composer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try prepare(arena.allocator(), 8, 24, .{
        .composer = .{ .text = "/", .cursor_byte = 1 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
        .active_tool = null,
        .slash_menu = .{
            .prefix = "/",
            .selected_index = 1,
            .window_start = 0,
            .count = 2,
        },
    });
    try std.testing.expectEqual(@as(u16, 3), frame.layout.menu.?.row_count);
    try std.testing.expectEqual(@as(usize, 3), frame.menu_rows.len);
    try std.testing.expect(frame.menu_rows[2].selected);

    var surface = try terminal_render.Surface.init(arena.allocator(), 8, 24);
    defer surface.deinit();
    try frame.paint(&surface, 0);
    try std.testing.expect(surface.lastOccupiedColumn(3) <= 24);
    try std.testing.expect(surface.rowCells(3).?[0].style.attributes.inverse);
}

test "surface footer frame keeps composer visible when menu rows are squeezed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try prepare(arena.allocator(), 4, 12, .{
        .composer = .{ .text = "/", .cursor_byte = 1 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
        .active_tool = null,
        .slash_menu = .{
            .prefix = "/",
            .selected_index = 0,
            .window_start = 0,
            .count = 2,
        },
    });
    try std.testing.expectEqual(@as(u16, 2), frame.layout.menu.?.row_count);
    try std.testing.expectEqual(@as(u16, 1), frame.layout.composer.row_count);
    try std.testing.expectEqual(@as(u16, 4), frame.layout.status.?.first_row);
}

test "surface footer frame paints model cwd and idle hint without rails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try prepare(arena.allocator(), 8, 80, .{
        .composer = .{ .text = "draft", .cursor_byte = 5 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
        .active_tool = null,
        .active_model = .{ .provider = "openai", .model = "gpt-test" },
        .thinking_level = .high,
        .cwd = "/work/zi",
    });
    try std.testing.expectEqual(@as(u16, 1), frame.layout.composer.first_row);
    try std.testing.expectEqual(@as(u16, 2), frame.layout.status.?.first_row);
    try std.testing.expectEqualStrings(
        "openai/gpt-test · thinking high · /work/zi · enter send · ctrl+d exit",
        frame.status_text,
    );
}

test "surface footer frame sanitizes status facts before measuring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try prepare(arena.allocator(), 4, 80, .{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
        .active_tool = null,
        .active_model = .{ .provider = "open\x1bai", .model = "gpt\nmodel\xff" },
        .cwd = "/work/a\nb\t/e\u{301}",
    });
    try std.testing.expectEqualStrings(
        "open�ai/gpt�model� · /work/a�b\t/e\u{301} · enter send · ctrl+d exit",
        frame.status_text,
    );
    try std.testing.expect(terminal_render.Text.displayWidth(frame.status_text) <= 80);
}

test "surface footer frame prioritizes active work and clips by display width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try prepare(arena.allocator(), 4, 18, .{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .{ .running = @enumFromInt(1) } },
        .queued_count = 0,
        .active_tool = "Reading 파일.zig",
        .active_model = .{ .provider = "openai", .model = "gpt-test" },
        .cwd = "/work/긴-프로젝트",
    });
    try std.testing.expect(std.mem.startsWith(u8, frame.status_text, "Reading"));
    try std.testing.expect(terminal_render.Text.displayWidth(frame.status_text) <= 18);

    var surface = try terminal_render.Surface.init(arena.allocator(), 4, 18);
    defer surface.deinit();
    try frame.paint(&surface, 0);
    try std.testing.expect(surface.lastOccupiedColumn(frame.layout.status.?.first_row) <= 18);

    const idle = try prepare(arena.allocator(), 4, 30, .{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
        .active_tool = null,
        .active_model = .{ .provider = "openai", .model = "gpt-test" },
        .thinking_level = .high,
        .cwd = "/work/long-parent/zi",
    });
    try std.testing.expectEqualStrings("openai/gpt-test · …/zi", idle.status_text);
    try std.testing.expect(terminal_render.Text.displayWidth(idle.status_text) <= 30);
}
