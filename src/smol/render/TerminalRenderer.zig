// Single-painter frame publisher. The target surface always describes the
// complete visible frame (transcript viewport plus footer bands), so commit
// diffs the whole surface against its shadow, exactly like the earlier
// pure-footer diff path extended to every row.
const std = @import("std");
const terminal_render = @import("../../terminal_render/root.zig");
const Ansi = terminal_render.Ansi;
const Diff = terminal_render.Diff;
const Surface = terminal_render.Surface;

const TerminalRenderer = @This();

pub const CommitResult = struct {
    bytes_written: usize,
    changed_rows: u16,
};

allocator: std.mem.Allocator,
previous: ?Surface = null,
publication_indeterminate: bool = false,

pub fn init(allocator: std.mem.Allocator) TerminalRenderer {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *TerminalRenderer) void {
    if (self.previous) |*previous| previous.deinit();
    self.* = undefined;
}

/// Composes the complete wire transaction before writing. The target becomes
/// authoritative only after the output flush succeeds.
pub fn commit(
    self: *TerminalRenderer,
    output: *std.Io.Writer,
    target: *const Surface,
) !CommitResult {
    if (self.publication_indeterminate) return error.IndeterminatePublication;
    // Frame surfaces may use a request arena. The authoritative shadow must
    // instead live in the renderer allocator across commits.
    var next = try target.clone(self.allocator);
    errdefer next.deinit();

    var wire: std.Io.Writer.Allocating = .init(self.allocator);
    defer wire.deinit();
    const changed_rows = try self.compose(&wire.writer, target);
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

    if (self.previous) |*previous| previous.deinit();
    self.previous = next;
    return .{
        .bytes_written = bytes.len,
        .changed_rows = changed_rows,
    };
}

pub fn isPublicationIndeterminate(self: *const TerminalRenderer) bool {
    return self.publication_indeterminate;
}

pub fn finish(self: *TerminalRenderer, output: *std.Io.Writer) !void {
    if (self.publication_indeterminate) return;
    const previous = if (self.previous) |*value| value else return;
    var wire: std.Io.Writer.Allocating = .init(self.allocator);
    defer wire.deinit();
    // Clear the owned viewport and leave the hardware cursor on a fresh line.
    try wire.writer.writeAll("\x1b[?25l\x1b[H\x1b[0m\x1b[2J");
    try wire.writer.print("\x1b[{d};1H\r\n\x1b[0m\x1b[?25h", .{previous.rows});
    output.writeAll(wire.written()) catch |failure| {
        self.publication_indeterminate = true;
        return failure;
    };
    output.flush() catch |failure| {
        self.publication_indeterminate = true;
        return failure;
    };
    previous.deinit();
    self.previous = null;
}

fn compose(
    self: *TerminalRenderer,
    writer: *std.Io.Writer,
    target: *const Surface,
) !u16 {
    var changed_rows: u16 = 0;
    var current_row: u16 = undefined;
    var wire_started = false;

    const first_frame = self.previous == null;
    var diff = Diff.Iterator.init(if (self.previous) |*previous| previous else null, target);
    if (!first_frame) current_row = self.previous.?.cursor.row;

    while (diff.next()) |span| {
        if (!wire_started) {
            try writer.writeAll("\x1b[?25l\x1b[0m");
            if (first_frame or diff.full_repaint) {
                // Nothing above this program's viewport is trusted; home and
                // clear so the first paint never inherits stale screen state.
                try writer.writeAll("\x1b[H\x1b[2J");
                current_row = 1;
            }
            wire_started = true;
        }
        try moveToRow(writer, &current_row, span.row);
        try writer.writeAll("\r\x1b[2K");
        try writeRow(writer, target, span.row);
        changed_rows += 1;
    }

    const cursor_moved = first_frame or self.previous == null or
        !std.meta.eql(self.previous.?.cursor, target.cursor);
    if (!wire_started and !cursor_moved) return 0;
    if (!wire_started) try writer.writeAll("\x1b[?25l\x1b[0m");
    try moveToRow(writer, &current_row, target.cursor.row);
    try writeCursor(writer, target.cursor, current_row);
    try writeCursorVisibility(writer, target.cursor.visible);
    return changed_rows;
}

fn writeRow(writer: *std.Io.Writer, surface: *const Surface, row: u16) !void {
    const cells = surface.rowCells(row) orelse return error.InvalidSurface;
    const last_column = surface.lastOccupiedColumn(row);
    var encoder = Ansi.Encoder.init(writer);
    for (cells[0..last_column]) |cell| {
        if (cell.isContinuation()) continue;
        try encoder.setStyle(cell.style);
        if (surface.graphemeBytes(cell)) |bytes| {
            try writer.writeAll(bytes);
        } else {
            try writer.writeByte(' ');
        }
        encoder.forgetCursor();
    }
    try encoder.setStyle(.{});
}

fn moveToRow(writer: *std.Io.Writer, current_row: *u16, target_row: u16) !void {
    if (target_row < current_row.*) {
        try writer.print("\x1b[{d}A", .{current_row.* - target_row});
    } else if (target_row > current_row.*) {
        try writer.print("\x1b[{d}B", .{target_row - current_row.*});
    }
    current_row.* = target_row;
}

fn writeCursor(writer: *std.Io.Writer, cursor: Surface.Cursor, current_row: u16) !void {
    var row = current_row;
    try moveToRow(writer, &row, cursor.row);
    try writer.writeByte('\r');
    if (cursor.column > 1) try writer.print("\x1b[{d}C", .{cursor.column - 1});
}

fn writeCursorVisibility(writer: *std.Io.Writer, visible: bool) !void {
    try writer.writeAll("\x1b[0m");
    var encoder = Ansi.Encoder.init(writer);
    try encoder.setCursorVisible(visible);
}

test "renderer diffs changed rows against its shadow" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var first = try Surface.init(std.testing.allocator, 3, 20);
    defer first.deinit();
    _ = try first.writeText(1, 1, "hello", .{ .attributes = .{ .bold = true } });
    _ = try first.writeText(2, 1, "Ready", .{ .attributes = .{ .dim = true } });
    _ = try first.writeText(3, 1, "\u{279d} one", .{});
    try first.setCursor(.{ .row = 3, .column = 6 });
    _ = try renderer.commit(&output.writer, &first);

    var second = try Surface.init(std.testing.allocator, 3, 20);
    defer second.deinit();
    _ = try second.writeText(1, 1, "hello world", .{ .attributes = .{ .bold = true } });
    _ = try second.writeText(2, 1, "Ready", .{ .attributes = .{ .dim = true } });
    _ = try second.writeText(3, 1, "\u{279d} one", .{});
    try second.setCursor(.{ .row = 3, .column = 6 });
    const result = try renderer.commit(&output.writer, &second);
    try std.testing.expectEqual(@as(u16, 1), result.changed_rows);
    const delta = output.written()[output.written().len - result.bytes_written ..];
    try std.testing.expect(std.mem.find(u8, delta, "world") != null);
    try std.testing.expect(std.mem.find(u8, delta, "Ready") == null);
}

test "the first commit homes and clears before painting" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var target = try Surface.init(std.testing.allocator, 2, 20);
    defer target.deinit();
    _ = try target.writeText(1, 1, "Ready", .{ .attributes = .{ .dim = true } });
    _ = try target.writeText(2, 1, "\u{279d}", .{});
    try target.setCursor(.{ .row = 2, .column = 2 });
    _ = try renderer.commit(&output.writer, &target);

    const bytes = output.written();
    const hide = std.mem.find(u8, bytes, "\x1b[?25l").?;
    const home = std.mem.find(u8, bytes, "\x1b[H").?;
    const clear = std.mem.find(u8, bytes, "\x1b[2J").?;
    const ready = std.mem.find(u8, bytes, "Ready").?;
    try std.testing.expect(hide < home and home < clear and clear < ready);
}

test "an unchanged frame writes nothing but cursor upkeep" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var target = try Surface.init(std.testing.allocator, 2, 10);
    defer target.deinit();
    _ = try target.writeText(1, 1, "Ready", .{});
    try target.setCursor(.{ .row = 2, .column = 1 });
    _ = try renderer.commit(&output.writer, &target);
    const base = output.written().len;

    _ = try renderer.commit(&output.writer, &target);
    try std.testing.expectEqual(base + 0, output.written().len);
}

test "renderer fully repaints after frame dimensions change" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    var first = try Surface.init(std.testing.allocator, 2, 8);
    defer first.deinit();
    _ = try first.writeText(1, 1, "old", .{});
    _ = try renderer.commit(&output.writer, &first);
    const before = output.written().len;

    var resized = try Surface.init(std.testing.allocator, 3, 12);
    defer resized.deinit();
    _ = try resized.writeText(1, 1, "new", .{});
    const result = try renderer.commit(&output.writer, &resized);
    const delta = output.written()[before..];
    try std.testing.expectEqual(resized.rows, result.changed_rows);
    try std.testing.expect(std.mem.find(u8, delta, "\x1b[H\x1b[2J") != null);
}

test "renderer shadow outlives a frame arena" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var first = try Surface.init(arena.allocator(), 2, 12);
        defer first.deinit();
        _ = try first.writeText(1, 1, "first", .{});
        _ = try renderer.commit(&output.writer, &first);
    }

    var second = try Surface.init(std.testing.allocator, 2, 12);
    defer second.deinit();
    _ = try second.writeText(1, 1, "second", .{});
    const result = try renderer.commit(&output.writer, &second);
    try std.testing.expectEqual(@as(u16, 1), result.changed_rows);
    try std.testing.expect(std.mem.find(u8, output.written(), "second") != null);
}

test "renderer establishes default style before styled grapheme output" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var target = try Surface.init(std.testing.allocator, 1, 8);
    defer target.deinit();
    _ = try target.writeText(1, 1, "\u{754c}", .{ .attributes = .{ .bold = true } });
    _ = try renderer.commit(&output.writer, &target);

    const bytes = output.written();
    const reset = std.mem.find(u8, bytes, "\x1b[0m").?;
    const bold = std.mem.find(u8, bytes, "\x1b[1m").?;
    const grapheme = std.mem.find(u8, bytes, "\u{754c}").?;
    try std.testing.expect(reset < bold and bold < grapheme);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b[0m\x1b[?25h"));
}

test "failed publication leaves the authoritative shadow unchanged" {
    const Failing = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };
    var output: std.Io.Writer = .{ .vtable = &Failing.vtable, .buffer = &.{} };
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var target = try Surface.init(std.testing.allocator, 2, 10);
    defer target.deinit();
    _ = try target.writeText(1, 1, "Ready", .{});
    try std.testing.expectError(error.WriteFailed, renderer.commit(&output, &target));
    try std.testing.expect(renderer.previous == null);
    try std.testing.expect(renderer.isPublicationIndeterminate());
}

test "failed finish poisons the renderer and suppresses retry" {
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
    var target = try Surface.init(std.testing.allocator, 1, 10);
    defer target.deinit();
    _ = try target.writeText(1, 1, "Ready", .{});
    _ = try renderer.commit(&initial.writer, &target);

    try std.testing.expectError(error.WriteFailed, renderer.finish(&failing));
    try std.testing.expect(renderer.isPublicationIndeterminate());
    try renderer.finish(&failing);
}

test "partial publication poisons the renderer and prevents retry" {
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
            const accepted = @min(available, 8);
            self.accepted = accepted;
            return accepted;
        }

        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };

    var output: PrefixThenFail = .{};
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var target = try Surface.init(std.testing.allocator, 1, 10);
    defer target.deinit();
    _ = try target.writeText(1, 1, "Ready", .{});

    try std.testing.expectError(
        error.WriteFailed,
        renderer.commit(&output.writer, &target),
    );
    try std.testing.expect(output.accepted != 0);
    try std.testing.expect(renderer.isPublicationIndeterminate());
    try std.testing.expectError(
        error.IndeterminatePublication,
        renderer.commit(&output.writer, &target),
    );
}
