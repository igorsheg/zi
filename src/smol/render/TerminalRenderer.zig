const std = @import("std");
const terminal_render = @import("../../terminal_render/root.zig");
const Ansi = terminal_render.Ansi;
const Diff = terminal_render.Diff;
const Surface = terminal_render.Surface;

const TerminalRenderer = @This();

pub const CommitResult = struct {
    bytes_written: usize,
    changed_rows: u16,
    document_appended: bool,
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
    document_append: []const u8,
) !CommitResult {
    if (self.publication_indeterminate) return error.IndeterminatePublication;
    if (document_append.len != 0 and !std.mem.endsWith(u8, document_append, "\n")) {
        return error.IncompleteDocumentAppend;
    }
    var next = try target.clone();
    var next_live = true;
    errdefer if (next_live) next.deinit();

    var wire: std.Io.Writer.Allocating = .init(self.allocator);
    defer wire.deinit();
    const changed_rows = try self.compose(&wire.writer, target, document_append);
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
    next_live = false;
    return .{
        .bytes_written = bytes.len,
        .changed_rows = changed_rows,
        .document_appended = document_append.len != 0,
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
    try wire.writer.writeAll("\x1b[?25l");
    var current_row = previous.cursor.row;
    try moveToRow(&wire.writer, &current_row, 1);
    for (1..@as(usize, previous.rows) + 1) |row_index| {
        try wire.writer.writeAll("\r\x1b[2K");
        if (row_index < previous.rows) try wire.writer.writeAll("\x1b[1B");
    }
    if (previous.rows > 1) try wire.writer.print("\x1b[{d}A", .{previous.rows - 1});
    try wire.writer.writeAll("\r\n\x1b[0m\x1b[?25h");
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
    document_append: []const u8,
) !u16 {
    if (self.previous == null) {
        try writer.writeAll("\x1b[?25l\x1b[0m");
        if (document_append.len != 0) try writer.writeAll(document_append);
        try writer.writeByte('\r');
        try paintFull(writer, target);
        try writeCursor(writer, target.cursor, target.rows);
        try writeCursorVisibility(writer, target.cursor.visible);
        return target.rows;
    }

    const previous = &self.previous.?;
    if (document_append.len != 0 or
        previous.rows != target.rows or previous.columns != target.columns)
    {
        try writer.writeAll("\x1b[?25l\x1b[0m");
        try clearPrevious(writer, previous);
        if (document_append.len != 0) try writer.writeAll(document_append);
        try writer.writeByte('\r');
        try paintFull(writer, target);
        try writeCursor(writer, target.cursor, target.rows);
        try writeCursorVisibility(writer, target.cursor.visible);
        return target.rows;
    }

    var changed_rows: u16 = 0;
    var current_row = previous.cursor.row;
    var wire_started = false;
    var diff = Diff.Iterator.init(previous, target);
    while (diff.next()) |span| {
        if (!wire_started) {
            try writer.writeAll("\x1b[?25l\x1b[0m");
            wire_started = true;
        }
        try moveToRow(writer, &current_row, span.row);
        try writer.writeAll("\r\x1b[2K");
        try writeRow(writer, target, span.row);
        changed_rows += 1;
    }
    if (!wire_started and std.meta.eql(previous.cursor, target.cursor)) return 0;
    if (!wire_started) try writer.writeAll("\x1b[?25l\x1b[0m");
    try moveToRow(writer, &current_row, target.cursor.row);
    try writeCursor(writer, target.cursor, current_row);
    try writeCursorVisibility(writer, target.cursor.visible);
    return changed_rows;
}

fn clearPrevious(writer: *std.Io.Writer, previous: *const Surface) !void {
    var current_row = previous.cursor.row;
    try moveToRow(writer, &current_row, 1);
    var row: u16 = 1;
    while (row <= previous.rows) : (row += 1) {
        try writer.writeAll("\r\x1b[2K");
        if (row < previous.rows) {
            try writer.writeAll("\x1b[1B");
            current_row += 1;
        }
    }
    try moveToRow(writer, &current_row, 1);
    try writer.writeByte('\r');
}

fn paintFull(writer: *std.Io.Writer, target: *const Surface) !void {
    var row: u16 = 1;
    while (row <= target.rows) : (row += 1) {
        try writer.writeAll("\x1b[2K");
        try writeRow(writer, target, row);
        if (row < target.rows) try writer.writeAll("\r\n");
    }
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

test "renderer diffs changed footer rows against its shadow" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var first = try Surface.init(std.testing.allocator, 2, 20);
    defer first.deinit();
    _ = try first.writeText(1, 1, "Ready", .{ .attributes = .{ .dim = true } });
    _ = try first.writeText(2, 1, "❯ one", .{});
    try first.setCursor(.{ .row = 2, .column = 6 });
    _ = try renderer.commit(&output.writer, &first, "hello\n");
    const first_len = output.written().len;

    var second = try Surface.init(std.testing.allocator, 2, 20);
    defer second.deinit();
    _ = try second.writeText(1, 1, "Ready", .{ .attributes = .{ .dim = true } });
    _ = try second.writeText(2, 1, "❯ two", .{});
    try second.setCursor(.{ .row = 2, .column = 6 });
    const result = try renderer.commit(&output.writer, &second, "");
    try std.testing.expectEqual(@as(u16, 1), result.changed_rows);
    try std.testing.expect(std.mem.find(u8, output.written()[first_len..], "Ready") == null);
    try std.testing.expect(std.mem.find(u8, output.written()[first_len..], "two") != null);
}

test "renderer establishes default style before styled grapheme output" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();
    var target = try Surface.init(std.testing.allocator, 1, 8);
    defer target.deinit();
    _ = try target.writeText(1, 1, "界", .{ .attributes = .{ .bold = true } });
    _ = try renderer.commit(&output.writer, &target, "");

    const bytes = output.written();
    const reset = std.mem.find(u8, bytes, "\x1b[0m").?;
    const bold = std.mem.find(u8, bytes, "\x1b[1m").?;
    const grapheme = std.mem.find(u8, bytes, "界").?;
    try std.testing.expect(reset < bold);
    try std.testing.expect(bold < grapheme);
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
    try std.testing.expectError(error.WriteFailed, renderer.commit(&output, &target, ""));
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
    _ = try renderer.commit(&initial.writer, &target, "");

    try std.testing.expectError(error.WriteFailed, renderer.finish(&failing));
    try std.testing.expect(renderer.isPublicationIndeterminate());
    try renderer.finish(&failing);
}

test "partial publication poisons the renderer and prevents document retry" {
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
        renderer.commit(&output.writer, &target, "document\n"),
    );
    try std.testing.expect(output.accepted != 0);
    try std.testing.expect(renderer.isPublicationIndeterminate());
    try std.testing.expectError(
        error.IndeterminatePublication,
        renderer.commit(&output.writer, &target, "document\n"),
    );
}
