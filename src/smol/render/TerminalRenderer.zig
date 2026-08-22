// Normal-buffer publication behavior adapted from vercel-labs/fx
// src/ui/render_engine/frame_builder.zig and terminal_diff.zig at commit
// 5ed3be1. Licensed under Apache-2.0 and adapted for Zi.
const std = @import("std");
const terminal_render = @import("../../terminal_render/root.zig");
const FramePlan = @import("FramePlan.zig");
const Ansi = terminal_render.Ansi;
const Diff = terminal_render.Diff;
const Surface = terminal_render.Surface;

const TerminalRenderer = @This();

pub const CommitResult = struct {
    bytes_written: usize,
    changed_rows: u16,
    physical_scroll_rows: u32,
};

allocator: std.mem.Allocator,
launch_row: ?u16 = null,
initial_geometry: ?FramePlan.Geometry = null,
committed_layout: ?FramePlan.CommittedLayout = null,
shadow: ?Surface = null,
publication_indeterminate: bool = false,
finished: bool = false,

pub fn init(allocator: std.mem.Allocator) TerminalRenderer {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *TerminalRenderer) void {
    if (self.shadow) |*shadow| shadow.deinit();
    self.* = undefined;
}

/// Admits the exact initial geometry and launch cursor row. No frame may be
/// planned or committed before this succeeds.
pub fn begin(
    self: *TerminalRenderer,
    geometry: FramePlan.Geometry,
    launch_row: u16,
) !void {
    if (self.launch_row != null) return error.AlreadyAdmitted;
    _ = try FramePlan.solve(.{
        .geometry = geometry,
        .launch_row = launch_row,
        .transcript_rows = 0,
        .footer_rows = 0,
    });
    self.launch_row = launch_row;
    self.initial_geometry = geometry;
}

/// Solves a candidate layout without changing committed renderer state.
pub fn plan(
    self: *const TerminalRenderer,
    geometry: FramePlan.Geometry,
    transcript_rows: u32,
    footer_rows: u16,
) !FramePlan.FramePlan {
    if (self.finished) return error.RendererFinished;
    const launch_row = self.launch_row orelse return error.NotAdmitted;
    if (self.committed_layout == null and !std.meta.eql(self.initial_geometry.?, geometry)) {
        return error.GeometryChangedBeforeFirstCommit;
    }
    return FramePlan.solve(.{
        .geometry = geometry,
        .launch_row = @min(launch_row, geometry.rows),
        .transcript_rows = transcript_rows,
        .footer_rows = footer_rows,
        .prior = self.committed_layout,
    });
}

/// Buffers one synchronized wire transaction. The target shadow and layout
/// become authoritative only after both write and flush succeed.
pub fn commit(
    self: *TerminalRenderer,
    output: *std.Io.Writer,
    target: *const Surface,
    frame_plan: FramePlan.FramePlan,
) !CommitResult {
    if (self.publication_indeterminate) return error.IndeterminatePublication;
    if (self.finished) return error.RendererFinished;
    const expected = try self.plan(
        frame_plan.geometry,
        frame_plan.transcript_rows,
        frame_plan.footer_rows,
    );
    if (!std.meta.eql(expected, frame_plan)) return error.StaleFramePlan;
    if (target.rows != frame_plan.geometry.rows or target.columns != frame_plan.geometry.columns) {
        return error.SurfaceGeometryMismatch;
    }
    if (!frame_plan.footer_band.contains(target.cursor.row)) return error.CursorOutsideFooter;

    // Frame surfaces may use a request arena. Both candidate and authoritative
    // copies use the renderer allocator and survive until publication settles.
    var candidate = if (self.shadow) |*shadow|
        if (shadow.rows == target.rows and shadow.columns == target.columns)
            try shadow.clone(self.allocator)
        else
            try shadow.blankResizedClone(self.allocator, target.rows, target.columns)
    else
        try Surface.init(self.allocator, target.rows, target.columns);
    defer candidate.deinit();
    candidate.scrollUp(frame_plan.physical_scroll_rows);

    var next = try target.clone(self.allocator);
    errdefer next.deinit();

    var wire: std.Io.Writer.Allocating = .init(self.allocator);
    defer wire.deinit();
    const geometry_changed = if (self.shadow) |*shadow|
        shadow.rows != target.rows or shadow.columns != target.columns
    else
        false;
    const bounds = ownedUnion(self.committed_layout, frame_plan);
    const force_owned_repaint = self.shadow == null or geometry_changed or
        frame_plan.released_preserved_rows != 0;
    const changed_rows = try compose(
        &wire.writer,
        if (force_owned_repaint) null else &candidate,
        target,
        frame_plan,
        bounds,
    );

    const bytes = wire.written();
    if (bytes.len != 0) {
        output.writeAll(bytes) catch |failure| {
            self.publication_indeterminate = true;
            return failure;
        };
        output.flush() catch |failure| {
            self.publication_indeterminate = true;
            return failure;
        };
    }

    if (self.shadow) |*shadow| shadow.deinit();
    self.shadow = next;
    self.committed_layout = frame_plan.committed();
    return .{
        .bytes_written = bytes.len,
        .changed_rows = changed_rows,
        .physical_scroll_rows = frame_plan.physical_scroll_rows,
    };
}

pub fn isPublicationIndeterminate(self: *const TerminalRenderer) bool {
    return self.publication_indeterminate;
}

/// Clears only rows below the committed transcript that Zi still owns. The
/// transcript remains in the normal buffer and the first cleared footer row
/// becomes the shell's fresh input line.
pub fn finish(self: *TerminalRenderer, output: *std.Io.Writer) !void {
    if (self.publication_indeterminate or self.finished) return;
    const layout = self.committed_layout orelse return;
    const shadow = if (self.shadow) |*value| value else return error.MissingShadow;
    const clear_top = if (!layout.transcript_band.isEmpty())
        layout.transcript_band.bottom + 1
    else
        layout.owned_top;
    const clear_bottom = layout.owned_bottom;
    if (clear_top > clear_bottom) return error.MissingFreshLine;

    var wire: std.Io.Writer.Allocating = .init(self.allocator);
    defer wire.deinit();
    try wire.writer.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    var encoder = Ansi.Encoder.init(&wire.writer);
    encoder.invalidate();
    var row = clear_top;
    while (row <= clear_bottom) : (row += 1) {
        encoder.forgetCursor();
        try encoder.moveTo(.{ .row = row, .column = 1 });
        try encoder.eraseLine(.entire);
    }
    encoder.forgetCursor();
    try encoder.moveTo(.{ .row = clear_top, .column = 1 });
    try encoder.setStyle(.{});
    try wire.writer.writeAll("\x1b[?2026l\x1b[?25h");

    output.writeAll(wire.written()) catch |failure| {
        self.publication_indeterminate = true;
        return failure;
    };
    output.flush() catch |failure| {
        self.publication_indeterminate = true;
        return failure;
    };

    shadow.deinit();
    self.shadow = null;
    self.committed_layout = null;
    self.finished = true;
}

fn ownedUnion(
    prior: ?FramePlan.CommittedLayout,
    current: FramePlan.FramePlan,
) Diff.RowBounds {
    var top = current.owned_top;
    var bottom = current.owned_bottom;
    if (prior) |layout| {
        if (layout.owned_top <= current.geometry.rows) top = @min(top, layout.owned_top);
        bottom = @max(bottom, @min(layout.owned_bottom, current.geometry.rows));
    }
    if (bottom < top) return .empty();
    return .{ .top = top, .bottom = bottom };
}

fn compose(
    writer: *std.Io.Writer,
    previous: ?*const Surface,
    target: *const Surface,
    frame_plan: FramePlan.FramePlan,
    bounds: Diff.RowBounds,
) !u16 {
    var diff = try Diff.Iterator.initBounded(previous, target, bounds);
    const first_span = diff.next();
    const cursor_changed = previous == null or
        !std.meta.eql(previous.?.cursor, target.cursor);
    if (first_span == null and frame_plan.physical_scroll_rows == 0 and !cursor_changed) return 0;

    try writer.writeAll("\x1b[?2026h\x1b[?25l\x1b[0m");
    var encoder = Ansi.Encoder.init(writer);
    encoder.invalidate();

    if (frame_plan.physical_scroll_rows != 0) {
        try encoder.moveTo(.{ .row = target.rows, .column = 1 });
        var remaining = frame_plan.physical_scroll_rows;
        while (remaining != 0) : (remaining -= 1) try writer.writeAll("\r\n");
        encoder.invalidate();
    }

    var changed_rows: u16 = 0;
    if (first_span) |span| {
        try paintChangedRow(&encoder, target, span.row);
        changed_rows += 1;
    }
    while (diff.next()) |span| {
        try paintChangedRow(&encoder, target, span.row);
        changed_rows += 1;
    }

    encoder.forgetCursor();
    try encoder.moveTo(.{ .row = target.cursor.row, .column = target.cursor.column });
    try encoder.setStyle(.{});
    try writer.writeAll("\x1b[?2026l");
    try writer.writeAll(if (target.cursor.visible) "\x1b[?25h" else "\x1b[?25l");
    return changed_rows;
}

fn paintChangedRow(encoder: *Ansi.Encoder, surface: *const Surface, row: u16) !void {
    encoder.forgetCursor();
    try encoder.moveTo(.{ .row = row, .column = 1 });
    try encoder.eraseLine(.entire);
    try writeRow(encoder, surface, row);
}

fn writeRow(encoder: *Ansi.Encoder, surface: *const Surface, row: u16) !void {
    const cells = surface.rowCells(row) orelse return error.InvalidSurface;
    const last_column = surface.lastOccupiedColumn(row);
    for (cells[0..last_column]) |cell| {
        if (cell.isContinuation()) continue;
        try encoder.setStyle(cell.style);
        if (surface.graphemeBytes(cell)) |bytes| {
            try encoder.writer.writeAll(bytes);
        } else {
            try encoder.writer.writeByte(' ');
        }
        encoder.forgetCursor();
    }
    try encoder.setStyle(.{});
}

fn makeTarget(
    allocator: std.mem.Allocator,
    frame_plan: FramePlan.FramePlan,
    transcript: []const u8,
    footer: []const u8,
) !Surface {
    var target = try Surface.init(
        allocator,
        frame_plan.geometry.rows,
        frame_plan.geometry.columns,
    );
    errdefer target.deinit();
    if (!frame_plan.transcript_band.isEmpty()) {
        _ = try target.writeText(frame_plan.transcript_band.top, 1, transcript, .{});
    }
    if (!frame_plan.footer_band.isEmpty()) {
        _ = try target.writeText(frame_plan.footer_band.top, 1, footer, .{});
        try target.setCursor(.{
            .row = frame_plan.footer_band.bottom,
            .column = 1,
        });
    }
    return target;
}

fn expectRowsNotAddressed(bytes: []const u8, first: u16, last: u16) !void {
    var row = first;
    while (row <= last) : (row += 1) {
        var sequence: [32]u8 = undefined;
        const cup = try std.fmt.bufPrint(&sequence, "\x1b[{d};1H", .{row});
        try std.testing.expect(std.mem.find(u8, bytes, cup) == null);
    }
}

test "renderer rejects planning and commits before admission" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    try std.testing.expectError(
        error.NotAdmitted,
        renderer.plan(.{ .rows = 8, .columns = 20 }, 1, 2),
    );
}

test "first frame is compact and never addresses prelaunch rows" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 10, .columns = 20 }, 6);
    const frame_plan = try renderer.plan(.{ .rows = 10, .columns = 20 }, 1, 2);
    var target = try makeTarget(std.testing.allocator, frame_plan, "answer", "Ready");
    defer target.deinit();

    const result = try renderer.commit(&output.writer, &target, frame_plan);
    try std.testing.expectEqual(@as(u16, 3), result.changed_rows);
    try std.testing.expectEqual(@as(u16, 6), renderer.committed_layout.?.owned_top);
    try std.testing.expectEqual(@as(u16, 8), renderer.committed_layout.?.owned_bottom);
    const bytes = output.written();
    try expectRowsNotAddressed(bytes, 1, 5);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[H") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[3J") == null);
}

test "transcript growth physically scrolls and replaces the full shadow" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 5, .columns = 20 }, 3);

    const first_plan = try renderer.plan(.{ .rows = 5, .columns = 20 }, 1, 2);
    var first = try makeTarget(std.testing.allocator, first_plan, "old", "Ready");
    defer first.deinit();
    _ = try renderer.commit(&output.writer, &first, first_plan);
    const before = output.written().len;

    const grown_plan = try renderer.plan(.{ .rows = 5, .columns = 20 }, 3, 2);
    var grown = try makeTarget(std.testing.allocator, grown_plan, "new", "Ready");
    defer grown.deinit();
    const result = try renderer.commit(&output.writer, &grown, grown_plan);
    const delta = output.written()[before..];

    try std.testing.expectEqual(@as(u32, 2), result.physical_scroll_rows);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, delta, "\r\n"));
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[5;1H") != null);
    try std.testing.expectEqual(@as(u16, 1), renderer.committed_layout.?.owned_top);
    try std.testing.expectEqualStrings(
        "n",
        renderer.shadow.?.graphemeBytes(renderer.shadow.?.rowCells(1).?[0]).?,
    );
    try std.testing.expectEqual(@as(u16, 3), renderer.shadow.?.lastOccupiedColumn(1));
}

test "resize forces repaint only across the old and new owned union" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 8, .columns = 10 }, 5);

    const first_plan = try renderer.plan(.{ .rows = 8, .columns = 10 }, 1, 2);
    var first = try makeTarget(std.testing.allocator, first_plan, "old", "Ready");
    defer first.deinit();
    _ = try renderer.commit(&output.writer, &first, first_plan);
    const before = output.written().len;

    const resized_plan = try renderer.plan(.{ .rows = 6, .columns = 12 }, 1, 2);
    var resized = try makeTarget(std.testing.allocator, resized_plan, "new", "Ready");
    defer resized.deinit();
    const result = try renderer.commit(&output.writer, &resized, resized_plan);
    const delta = output.written()[before..];

    try std.testing.expectEqual(@as(u16, 3), result.changed_rows);
    try expectRowsNotAddressed(delta, 1, 3);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[4;1H") != null);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[2J") == null);
    try std.testing.expectEqual(@as(u16, 6), renderer.shadow.?.rows);
    try std.testing.expectEqual(@as(u16, 12), renderer.shadow.?.columns);
}

test "frame shrink clears only stale rows that were previously owned" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 10, .columns = 20 }, 4);

    const first_plan = try renderer.plan(.{ .rows = 10, .columns = 20 }, 1, 4);
    var first = try makeTarget(std.testing.allocator, first_plan, "answer", "Ready");
    defer first.deinit();
    var row = first_plan.footer_band.top + 1;
    while (row <= first_plan.footer_band.bottom) : (row += 1) {
        _ = try first.writeText(row, 1, "stale", .{});
    }
    _ = try renderer.commit(&output.writer, &first, first_plan);
    const before = output.written().len;

    const shrunk_plan = try renderer.plan(.{ .rows = 10, .columns = 20 }, 1, 2);
    var shrunk = try makeTarget(std.testing.allocator, shrunk_plan, "answer", "Ready");
    defer shrunk.deinit();
    _ = try renderer.commit(&output.writer, &shrunk, shrunk_plan);
    const delta = output.written()[before..];

    try std.testing.expect(std.mem.find(u8, delta, "\x1b[7;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[8;1H\x1b[2K") != null);
    try expectRowsNotAddressed(delta, 9, 10);
}

test "finish clears only footer rows and leaves transcript visible" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 10, .columns = 20 }, 4);
    const frame_plan = try renderer.plan(.{ .rows = 10, .columns = 20 }, 2, 2);
    var target = try makeTarget(std.testing.allocator, frame_plan, "answer", "Ready");
    defer target.deinit();
    _ = try renderer.commit(&output.writer, &target, frame_plan);
    const before = output.written().len;

    try renderer.finish(&output.writer);
    const delta = output.written()[before..];
    try std.testing.expect(std.mem.find(u8, delta, "answer") == null);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[6;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[7;1H\x1b[2K") != null);
    try expectRowsNotAddressed(delta, 1, 5);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[3J") == null);
    try std.testing.expect(renderer.shadow == null);
    try std.testing.expect(renderer.committed_layout == null);
}

test "renderer shadow outlives a frame arena" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 4, .columns = 12 }, 1);

    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const frame_plan = try renderer.plan(.{ .rows = 4, .columns = 12 }, 1, 2);
        var first = try makeTarget(arena.allocator(), frame_plan, "first", "Ready");
        defer first.deinit();
        _ = try renderer.commit(&output.writer, &first, frame_plan);
    }

    const second_plan = try renderer.plan(.{ .rows = 4, .columns = 12 }, 1, 2);
    var second = try makeTarget(std.testing.allocator, second_plan, "second", "Ready");
    defer second.deinit();
    const result = try renderer.commit(&output.writer, &second, second_plan);
    try std.testing.expectEqual(@as(u16, 1), result.changed_rows);
    try std.testing.expect(std.mem.find(u8, output.written(), "second") != null);
}

test "unchanged frame writes no transaction" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 4, .columns = 12 }, 1);
    const frame_plan = try renderer.plan(.{ .rows = 4, .columns = 12 }, 1, 2);
    var target = try makeTarget(std.testing.allocator, frame_plan, "same", "Ready");
    defer target.deinit();
    _ = try renderer.commit(&output.writer, &target, frame_plan);
    const before = output.written().len;

    const next_plan = try renderer.plan(.{ .rows = 4, .columns = 12 }, 1, 2);
    const result = try renderer.commit(&output.writer, &target, next_plan);
    try std.testing.expectEqual(@as(usize, 0), result.bytes_written);
    try std.testing.expectEqual(before, output.written().len);
}

test "failed write leaves shadow and layout unchanged and poisons publication" {
    const Failing = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };
    var initial: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer initial.deinit();
    var failing: std.Io.Writer = .{ .vtable = &Failing.vtable, .buffer = &.{} };
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 5, .columns = 12 }, 2);

    const first_plan = try renderer.plan(.{ .rows = 5, .columns = 12 }, 1, 2);
    var first = try makeTarget(std.testing.allocator, first_plan, "old", "Ready");
    defer first.deinit();
    _ = try renderer.commit(&initial.writer, &first, first_plan);
    const committed_before = renderer.committed_layout.?;

    const second_plan = try renderer.plan(.{ .rows = 5, .columns = 12 }, 2, 2);
    var second = try makeTarget(std.testing.allocator, second_plan, "new", "Ready");
    defer second.deinit();
    try std.testing.expectError(error.WriteFailed, renderer.commit(&failing, &second, second_plan));
    try std.testing.expectEqual(committed_before, renderer.committed_layout.?);
    try std.testing.expectEqualStrings(
        "o",
        renderer.shadow.?.graphemeBytes(renderer.shadow.?.rowCells(2).?[0]).?,
    );
    try std.testing.expectEqual(@as(u16, 3), renderer.shadow.?.lastOccupiedColumn(2));
    try std.testing.expect(renderer.isPublicationIndeterminate());
    try std.testing.expectError(
        error.IndeterminatePublication,
        renderer.commit(&failing, &second, second_plan),
    );
}

test "partial publication poisons the renderer without installing a shadow" {
    const PrefixThenFail = struct {
        const Self = @This();

        writer: std.Io.Writer = .{ .vtable = &vtable, .buffer = &.{} },
        accepted: usize = 0,

        fn drain(
            writer: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize {
            const self: *Self = @fieldParentPtr("writer", writer);
            if (self.accepted != 0) return error.WriteFailed;
            var available: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| available += bytes.len;
            available += data[data.len - 1].len * splat;
            self.accepted = @min(available, 8);
            return self.accepted;
        }

        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };

    var output: PrefixThenFail = .{};
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 4, .columns = 10 }, 1);
    const frame_plan = try renderer.plan(.{ .rows = 4, .columns = 10 }, 1, 2);
    var target = try makeTarget(std.testing.allocator, frame_plan, "text", "Ready");
    defer target.deinit();

    try std.testing.expectError(
        error.WriteFailed,
        renderer.commit(&output.writer, &target, frame_plan),
    );
    try std.testing.expect(output.accepted != 0);
    try std.testing.expect(renderer.shadow == null);
    try std.testing.expect(renderer.committed_layout == null);
    try std.testing.expect(renderer.isPublicationIndeterminate());
    try std.testing.expectError(
        error.IndeterminatePublication,
        renderer.commit(&output.writer, &target, frame_plan),
    );
}

test "flush failure leaves the committed transaction unchanged" {
    const FlushFail = struct {
        fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| consumed += bytes.len;
            consumed += data[data.len - 1].len * splat;
            return consumed;
        }
        fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
        const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };
    };
    var writer: std.Io.Writer = .{ .vtable = &FlushFail.vtable, .buffer = &.{} };
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 4, .columns = 10 }, 1);
    const frame_plan = try renderer.plan(.{ .rows = 4, .columns = 10 }, 1, 2);
    var target = try makeTarget(std.testing.allocator, frame_plan, "text", "Ready");
    defer target.deinit();

    try std.testing.expectError(error.WriteFailed, renderer.commit(&writer, &target, frame_plan));
    try std.testing.expect(renderer.shadow == null);
    try std.testing.expect(renderer.committed_layout == null);
    try std.testing.expect(renderer.isPublicationIndeterminate());
}

test "failed finish poisons the renderer without clearing committed state" {
    const Failing = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };
    var initial: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer initial.deinit();
    var failing: std.Io.Writer = .{ .vtable = &Failing.vtable, .buffer = &.{} };
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    try renderer.begin(.{ .rows = 4, .columns = 10 }, 1);
    const frame_plan = try renderer.plan(.{ .rows = 4, .columns = 10 }, 1, 2);
    var target = try makeTarget(std.testing.allocator, frame_plan, "text", "Ready");
    defer target.deinit();
    _ = try renderer.commit(&initial.writer, &target, frame_plan);

    try std.testing.expectError(error.WriteFailed, renderer.finish(&failing));
    try std.testing.expect(renderer.isPublicationIndeterminate());
    try std.testing.expect(renderer.shadow != null);
    try std.testing.expect(renderer.committed_layout != null);
    try renderer.finish(&failing);
}
