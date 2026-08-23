// Adapted from vercel-labs/fx src/ui/footer/surface_frame.zig.
// Owns footer measurement and typed surface painting for one frame.
const std = @import("std");
const interactive = @import("../../coding_agent/root.zig").interactive;
const terminal_render = @import("../../terminal_render/root.zig");
const FooterLayout = @import("../render_engine/FooterLayout.zig");
const presentation = @import("presentation.zig");

const prompt = "❯ ";

pub const ComposerView = struct {
    text: []const u8,
    cursor_byte: usize,
    masked: bool = false,
};

pub const View = struct {
    composer: ComposerView,
    phase: interactive.Phase,
    queued_count: usize,
    active_tool: ?[]const u8,
};

pub const SurfaceFooterFrame = struct {
    layout: FooterLayout,
    composer_text: []const u8,
    hint_text: []const u8,

    pub fn rowCount(self: SurfaceFooterFrame) u16 {
        return self.layout.surface_rows;
    }

    pub fn paint(
        self: SurfaceFooterFrame,
        surface: *terminal_render.Surface,
        row_offset: u16,
    ) !void {
        if (self.layout.top_divider) |divider| try paintDivider(
            surface,
            divider.first_row + row_offset,
        );
        if (self.layout.bottom_divider) |divider| try paintDivider(
            surface,
            divider.first_row + row_offset,
        );
        if (self.layout.hint) |hint| {
            _ = try surface.writeText(
                hint.first_row + row_offset,
                1,
                self.hint_text,
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
    const layout = try FooterLayout.init(
        arena,
        terminal_rows,
        columns,
        composer_text,
        view.composer.cursor_byte,
        @intCast(terminal_render.Text.displayWidth(prompt)),
    );

    var hint: std.Io.Writer.Allocating = .init(arena);
    errdefer hint.deinit();
    try presentation.writeHint(
        &hint.writer,
        view.phase,
        view.active_tool,
        view.queued_count,
    );
    return .{
        .layout = layout,
        .composer_text = composer_text,
        .hint_text = try hint.toOwnedSlice(),
    };
}

fn paintDivider(surface: *terminal_render.Surface, row: u16) !void {
    var column: u16 = 1;
    while (column <= surface.columns) : (column += 1) {
        _ = try surface.writeText(row, column, "─", .{
            .foreground = .{ .indexed = 240 },
        });
    }
}

test "surface footer frame owns fx chrome and actionable hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const frame = try prepare(arena.allocator(), 8, 30, .{
        .composer = .{ .text = "draft", .cursor_byte = 5 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
        .active_tool = null,
    });
    try std.testing.expect(frame.layout.top_divider != null);
    try std.testing.expect(frame.layout.bottom_divider != null);
    try std.testing.expectEqualStrings("enter send · ctrl+d exit", frame.hint_text);
}
