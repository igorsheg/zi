// Adapts fx's frame-builder ownership: semantic transcript and footer frames
// are prepared independently, then composed into one typed publication target.
const std = @import("std");
const terminal_render = @import("../../terminal_render/root.zig");
const FooterSurface = @import("../footer/surface_frame.zig");
const Store = @import("../transcript/Store.zig");
const transcript_painter = @import("../transcript/painter.zig");
const FramePlan = @import("frame_plan.zig");
const TerminalRenderer = @import("TerminalRenderer.zig");

const min_transcript_rows: u16 = 3;

pub const ComposerView = FooterSurface.ComposerView;

pub const BuiltFrame = struct {
    surface: terminal_render.Surface,
    document: ?terminal_render.Surface,
    plan: FramePlan.FramePlan,
    open_entry_materialized: bool,

    pub fn deinit(self: *BuiltFrame) void {
        if (self.document) |*document| document.deinit();
        self.surface.deinit();
        self.* = undefined;
    }
};

pub fn build(
    arena: std.mem.Allocator,
    store: *const Store.Store,
    open_entry: ?u32,
    geometry: FramePlan.Geometry,
    footer_view: FooterSurface.View,
    terminal_renderer: *const TerminalRenderer,
) !BuiltFrame {
    const footer_budget = @min(
        @max(geometry.rows -| min_transcript_rows, @as(u16, 2)),
        geometry.rows,
    );
    const footer = try FooterSurface.prepare(
        arena,
        footer_budget,
        geometry.columns,
        footer_view,
    );
    const transcript = try transcript_painter.prepare(arena, store, geometry.columns);
    const transcript_rows = std.math.cast(u32, transcript.rows.len) orelse
        return error.TranscriptRowCountOverflow;
    const plan = try terminal_renderer.plan(
        geometry,
        transcript_rows,
        footer.rowCount(),
    );
    const materialized_rows = std.math.cast(
        usize,
        plan.materialized_transcript_rows,
    ) orelse return error.TranscriptRowCountOverflow;
    if (materialized_rows > transcript.rows.len or
        transcript.rows.len - materialized_rows != @as(usize, plan.visible_transcript_rows))
    {
        return error.InvalidFramePlan;
    }
    const document_rows: usize = plan.document_rows;
    if (document_rows > materialized_rows) return error.InvalidFramePlan;

    var document: ?terminal_render.Surface = null;
    var open_entry_materialized = false;
    errdefer if (document) |*value| value.deinit();
    if (plan.document_rows != 0) {
        document = try terminal_render.Surface.init(
            arena,
            plan.document_rows,
            geometry.columns,
        );
        const first_document = materialized_rows - document_rows;
        for (transcript.rows[first_document..materialized_rows], 1..) |row, document_row| {
            try transcript_painter.paint(&document.?, @intCast(document_row), row);
            if (open_entry) |open_id| {
                open_entry_materialized = open_entry_materialized or
                    transcript_painter.belongsToEntry(row, open_id) or row.provenance != .entry;
            }
        }
    }

    var surface = try terminal_render.Surface.init(arena, geometry.rows, geometry.columns);
    errdefer surface.deinit();
    for (transcript.rows[materialized_rows..], 0..) |row, index| {
        const target_row = plan.transcript_band.top + @as(u16, @intCast(index));
        try transcript_painter.paint(&surface, target_row, row);
    }
    try footer.paint(&surface, plan.footer_band.top - 1);

    return .{
        .surface = surface,
        .document = document,
        .plan = plan,
        .open_entry_materialized = open_entry_materialized,
    };
}
