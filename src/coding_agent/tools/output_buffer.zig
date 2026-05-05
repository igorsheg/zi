const std = @import("std");
const testing = std.testing;

pub fn HeadTailResult(comptime T: type) type {
    return struct {
        head: []const T,
        tail: []const T,
        truncated_count: usize,
    };
}

/// Split a slice into head + tail windows, truncating the middle when
/// `items.len > max_items`. Like pi's helper, the budget is split evenly
/// between head and tail using floor(max_items / 2).
pub fn splitHeadTail(comptime T: type, items: []const T, max_items: usize) HeadTailResult(T) {
    if (items.len <= max_items) {
        return .{
            .head = items,
            .tail = items[0..0],
            .truncated_count = 0,
        };
    }

    const half = max_items / 2;
    return .{
        .head = items[0..half],
        .tail = items[items.len - half ..],
        .truncated_count = items.len - (half * 2),
    };
}

fn appendJoined(out: *std.Io.Writer, lines: []const []const u8) !void {
    for (lines, 0..) |line, i| {
        if (i > 0) try out.writeAll("\n");
        try out.writeAll(line);
    }
}

/// Append a head+tail truncation of `lines` to `out`. If the slice fits,
/// all lines are written verbatim joined by `\n`. Otherwise the first and
/// last halves are kept with a marker between them.
pub fn appendHeadTail(
    out: *std.Io.Writer,
    lines: []const []const u8,
    max_items: usize,
    comptime marker_fmt: []const u8,
) !void {
    const window = splitHeadTail([]const u8, lines, max_items);
    if (window.truncated_count == 0) {
        try appendJoined(out, window.head);
        return;
    }

    try appendJoined(out, window.head);
    try out.writeAll("\n\n");
    try out.print(marker_fmt, .{window.truncated_count});
    try out.writeAll("\n\n");
    try appendJoined(out, window.tail);
}

pub const FormatResult = struct {
    text: []u8,
    truncated_lines: usize,
};

/// Streaming fixed-memory line buffer with first-N head lines and last-M tail lines.
/// Intended for tool output capture so we never retain unbounded stdout/stderr.
pub const LineOutputBuffer = struct {
    const default_max_line_bytes: usize = 16 * 1024;
    const line_truncated_marker = "... [line truncated]";

    allocator: std.mem.Allocator,
    max_head: usize,
    max_tail: usize,
    max_line_bytes: usize = default_max_line_bytes,
    head: std.ArrayList([]u8) = .empty,
    tail: std.ArrayList([]u8) = .empty,
    pending: std.ArrayList(u8) = .empty,
    pending_truncated: bool = false,
    total_lines: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_head: usize, max_tail: usize) LineOutputBuffer {
        return .{
            .allocator = allocator,
            .max_head = max_head,
            .max_tail = max_tail,
        };
    }

    pub fn deinit(self: *LineOutputBuffer) void {
        for (self.head.items) |line| self.allocator.free(line);
        self.head.deinit(self.allocator);

        for (self.tail.items) |line| self.allocator.free(line);
        self.tail.deinit(self.allocator);

        self.pending.deinit(self.allocator);
    }

    /// Add raw output bytes. Newlines terminate committed lines; a trailing
    /// partial line is retained in `pending` until another chunk arrives or
    /// `finishAlloc()` is called.
    pub fn addChunk(self: *LineOutputBuffer, chunk: []const u8) !void {
        var start: usize = 0;
        for (chunk, 0..) |byte, i| {
            if (byte != '\n') continue;

            if (self.pending.items.len > 0 or self.pending_truncated) {
                try self.appendPendingBounded(chunk[start..i]);
                try self.commitPendingLine();
            } else {
                try self.pushLine(chunk[start..i]);
            }
            start = i + 1;
        }

        if (start < chunk.len) {
            try self.appendPendingBounded(chunk[start..]);
        }
    }

    /// Format only committed lines. Useful for streaming updates: partial
    /// trailing lines stay buffered so future chunks can continue them.
    pub fn snapshotAlloc(self: *const LineOutputBuffer, allocator: std.mem.Allocator, comptime marker_fmt: []const u8) !FormatResult {
        return formatStateAlloc(
            allocator,
            self.head.items,
            self.tail.items,
            self.total_lines,
            self.max_head,
            self.max_tail,
            marker_fmt,
        );
    }

    /// Finalize any trailing partial line and return the formatted head+tail text.
    pub fn finishAlloc(self: *LineOutputBuffer, allocator: std.mem.Allocator, comptime marker_fmt: []const u8) !FormatResult {
        if (self.pending.items.len > 0) {
            try self.commitPendingLine();
        }
        return self.snapshotAlloc(allocator, marker_fmt);
    }

    fn appendPendingBounded(self: *LineOutputBuffer, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const remaining = self.max_line_bytes -| self.pending.items.len;
        if (remaining == 0) {
            self.pending_truncated = true;
            return;
        }
        const kept = @min(remaining, bytes.len);
        try self.pending.appendSlice(self.allocator, bytes[0..kept]);
        if (kept < bytes.len) self.pending_truncated = true;
    }

    fn commitPendingLine(self: *LineOutputBuffer) !void {
        try self.pushLineMaybeTruncated(self.pending.items, self.pending_truncated);
        self.pending.clearRetainingCapacity();
        self.pending_truncated = false;
    }

    fn pushLine(self: *LineOutputBuffer, line: []const u8) !void {
        try self.pushLineMaybeTruncated(line, line.len > self.max_line_bytes);
    }

    fn pushLineMaybeTruncated(self: *LineOutputBuffer, line: []const u8, truncated: bool) !void {
        self.total_lines += 1;
        const owned = try self.dupeLine(line, truncated);
        errdefer self.allocator.free(owned);

        if (self.head.items.len < self.max_head) {
            try self.head.append(self.allocator, try self.allocator.dupe(u8, owned));
        }

        if (self.max_tail == 0) {
            self.allocator.free(owned);
            return;
        }

        try self.tail.append(self.allocator, owned);
        if (self.tail.items.len > self.max_tail) {
            const evicted = self.tail.orderedRemove(0);
            self.allocator.free(evicted);
        }
    }

    fn dupeLine(self: *LineOutputBuffer, line: []const u8, truncated: bool) ![]u8 {
        const kept = line[0..@min(line.len, self.max_line_bytes)];
        if (!truncated) return self.allocator.dupe(u8, kept);
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ kept, line_truncated_marker });
    }
};

fn formatStateAlloc(
    allocator: std.mem.Allocator,
    head: []const []u8,
    tail: []const []u8,
    total_lines: usize,
    max_head: usize,
    max_tail: usize,
    comptime marker_fmt: []const u8,
) !FormatResult {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const no_truncation_budget = max_head + max_tail;
    if (total_lines <= no_truncation_budget) {
        const overlap = if (head.len + tail.len > total_lines)
            @min(head.len, (head.len + tail.len) - total_lines)
        else
            0;

        var first = true;
        for (head[0 .. head.len - overlap]) |line| {
            if (!first) try aw.writer.writeAll("\n");
            first = false;
            try aw.writer.writeAll(line);
        }
        for (tail) |line| {
            if (!first) try aw.writer.writeAll("\n");
            first = false;
            try aw.writer.writeAll(line);
        }

        return .{ .text = try aw.toOwnedSlice(), .truncated_lines = 0 };
    }

    const truncated_lines = total_lines - head.len - tail.len;
    var first = true;
    for (head) |line| {
        if (!first) try aw.writer.writeAll("\n");
        first = false;
        try aw.writer.writeAll(line);
    }
    if (!first) try aw.writer.writeAll("\n\n");
    try aw.writer.print(marker_fmt, .{truncated_lines});
    if (tail.len > 0) try aw.writer.writeAll("\n\n");
    first = true;
    for (tail) |line| {
        if (!first) try aw.writer.writeAll("\n");
        first = false;
        try aw.writer.writeAll(line);
    }

    return .{ .text = try aw.toOwnedSlice(), .truncated_lines = truncated_lines };
}
const TEST_MARKER = "... [{d} lines truncated] ...";

fn expectBufferFinish(
    chunks: []const []const u8,
    max_head: usize,
    max_tail: usize,
    max_line_bytes: ?usize,
    expected_text: []const u8,
    expected_truncated_lines: usize,
) !void {
    var buffer = LineOutputBuffer.init(testing.allocator, max_head, max_tail);
    defer buffer.deinit();
    if (max_line_bytes) |limit| buffer.max_line_bytes = limit;

    for (chunks) |chunk| try buffer.addChunk(chunk);

    const out = try buffer.finishAlloc(testing.allocator, TEST_MARKER);
    defer testing.allocator.free(out.text);
    try testing.expectEqual(expected_truncated_lines, out.truncated_lines);
    try testing.expectEqualStrings(expected_text, out.text);
}

test "LineOutputBuffer caps complete and pending lines independently" {
    try expectBufferFinish(
        &.{"abcdefghijklmnop\nshort\npartial-very-long"},
        2,
        2,
        8,
        "abcdefgh... [line truncated]\nshort\npartial-... [line truncated]",
        0,
    );
}

test "LineOutputBuffer snapshots only committed lines and finish adds pending tail" {
    var buffer = LineOutputBuffer.init(testing.allocator, 2, 2);
    defer buffer.deinit();

    try buffer.addChunk("a\nb");
    try buffer.addChunk("\nc\nd\n");

    const snapshot = try buffer.snapshotAlloc(testing.allocator, TEST_MARKER);
    defer testing.allocator.free(snapshot.text);
    try testing.expectEqual(@as(usize, 0), snapshot.truncated_lines);
    try testing.expectEqualStrings("a\nb\nc\nd", snapshot.text);

    try buffer.addChunk("e");
    const final = try buffer.finishAlloc(testing.allocator, TEST_MARKER);
    defer testing.allocator.free(final.text);
    try testing.expectEqual(@as(usize, 1), final.truncated_lines);
    try testing.expectEqualStrings("a\nb\n\n... [1 lines truncated] ...\n\nd\ne", final.text);
}

test "LineOutputBuffer emits duplicate text lines once when head and tail overlap" {
    try expectBufferFinish(
        &.{"same\nsame\nsame\n"},
        5,
        5,
        null,
        "same\nsame\nsame",
        0,
    );
}
