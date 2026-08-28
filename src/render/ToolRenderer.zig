//! Bounded normal-buffer renderer for untrusted tool output.
//!
//! The renderer keeps at most one pending display row, one 4096-byte input
//! line, and hax's 1500-byte circular tail. Tool output may be arbitrarily large.

const std = @import("std");
const text = @import("../text/root.zig");
const SafeText = @import("SafeText.zig");
const Theme = @import("Theme.zig");
const ToolContract = @import("../tool/root.zig").Tool;

const ToolRenderer = @This();

pub const Mode = enum {
    head,
    head_tail,
    unified_diff,
};

pub const Error = error{ OutOfMemory, WriteFailed };

const head_lines: usize = 8;
const head_bytes: usize = 3000;
const head_tail_lines: usize = 4;
const head_tail_bytes: usize = 1500;
const tail_lines: usize = 4;
const tail_ring_bytes: usize = 1500;
const line_bytes: usize = 4096;
const gutter_columns: usize = 2;

const RowClass = enum {
    plain,
    add,
    remove,
};

const Row = struct {
    bytes: []u8,
    class: RowClass,

    fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
theme: Theme,
width: usize,
mode: Mode,
safe_text: SafeText.SafeText = .{ .unsafe_policy = .substitute },
line: std.ArrayList(u8) = .empty,
line_has_content: bool = false,
pending: ?Row = null,
tail_ring: [tail_ring_bytes]u8 = undefined,
tail_write_pos: usize = 0,
tail_full: bool = false,
line_tail_bytes: usize = 0,
suppressed_tail_bytes: usize = 0,
head_complete: bool = false,
latest_suppressed: [line_bytes]u8 = undefined,
latest_suppressed_len: usize = 0,
rows_added: usize = 0,
head_lines_emitted: usize = 0,
head_bytes_emitted: usize = 0,
suppressed_lines: usize = 0,
diff_hunk_started: bool = false,
display_was_called: bool = false,
finalized: bool = false,
write_error: ?std.Io.Writer.Error = null,
allocation_failed: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    theme: Theme,
    width: usize,
    mode: Mode,
) ToolRenderer {
    return .{
        .allocator = allocator,
        .writer = writer,
        .theme = theme,
        .width = width,
        .mode = mode,
    };
}

pub fn deinit(self: *ToolRenderer) void {
    self.line.deinit(self.allocator);
    if (self.pending) |*row| row.deinit(self.allocator);
    self.* = undefined;
}

pub fn sink(self: *ToolRenderer) ToolContract.DisplaySink {
    return .from(self);
}

/// Changes preview policy before any visible or retained output is accepted.
pub fn setMode(self: *ToolRenderer, mode: Mode) void {
    std.debug.assert(self.rows_added == 0);
    std.debug.assert(self.line.items.len == 0);
    std.debug.assert(self.tail_write_pos == 0);
    std.debug.assert(!self.tail_full);
    self.mode = mode;
}

pub fn emit(self: *ToolRenderer, bytes: []const u8) error{OutOfMemory}!void {
    if (self.finalized) return;
    self.display_was_called = true;
    self.safe_text.feed(.{ .context = self, .emit_fn = safeOutput }, bytes);
    if (self.allocation_failed) return error.OutOfMemory;
}

pub fn feed(self: *ToolRenderer, bytes: []const u8) error{OutOfMemory}!void {
    if (self.finalized) return;
    self.safe_text.feed(.{ .context = self, .emit_fn = safeOutput }, bytes);
    if (self.allocation_failed) return error.OutOfMemory;
}

pub fn finalize(self: *ToolRenderer) Error!void {
    if (self.finalized) return self.check();
    self.finalized = true;
    self.safe_text.finish(.{ .context = self, .emit_fn = safeOutput });
    if (self.line.items.len != 0 or self.line_has_content) self.finishLine();
    if (self.mode == .head and self.suppressed_lines != 0) {
        var marker_buffer: [96]u8 = undefined;
        const marker = std.fmt.bufPrint(
            &marker_buffer,
            "... ({d} more line{s})",
            .{ self.suppressed_lines, if (self.suppressed_lines == 1) "" else "s" },
        ) catch unreachable;
        self.addRow(marker, .plain);
    } else if (self.mode == .head_tail) {
        self.emitTailPreview();
    }
    self.flushPending(true);
    self.flushWriter();
    return self.check();
}

pub fn check(self: *const ToolRenderer) Error!void {
    if (self.allocation_failed) return error.OutOfMemory;
    if (self.write_error) |err| return err;
}

pub fn rowCount(self: *const ToolRenderer) usize {
    return self.rows_added;
}

fn safeOutput(context: *anyopaque, bytes: []const u8) void {
    const self: *ToolRenderer = @ptrCast(@alignCast(context));
    if (self.allocation_failed) return;
    const visible = if (bytes.len > 1) text.DisplayWidth.next(bytes, 0).?.bytes else bytes;
    self.consumeSafe(visible) catch {
        self.allocation_failed = true;
    };
}

fn consumeSafe(self: *ToolRenderer, bytes: []const u8) error{OutOfMemory}!void {
    for (bytes) |byte| switch (byte) {
        '\n' => {
            self.pushTailByte('\n');
            self.finishLine();
        },
        '\t' => {
            if (self.line.items.len <= line_bytes - 4) try self.line.appendSlice(self.allocator, "    ");
            for ("    ") |space| self.pushTailByte(space);
        },
        else => {
            if (self.line.items.len < line_bytes) try self.line.append(self.allocator, byte);
            self.pushTailByte(byte);
            if (byte != ' ') self.line_has_content = true;
        },
    };
}

fn pushTailByte(self: *ToolRenderer, byte: u8) void {
    if (self.mode != .head_tail) return;
    self.tail_ring[self.tail_write_pos] = byte;
    self.tail_write_pos += 1;
    if (self.tail_write_pos == self.tail_ring.len) {
        self.tail_write_pos = 0;
        self.tail_full = true;
    }
    self.line_tail_bytes +|= 1;
    if (self.head_complete) self.suppressed_tail_bytes +|= 1;
}

fn emitTailPreview(self: *ToolRenderer) void {
    const ring_len = if (self.tail_full) self.tail_ring.len else self.tail_write_pos;
    const oldest = if (self.tail_full) self.tail_write_pos else 0;
    var linearized: [tail_ring_bytes]u8 = undefined;
    for (0..ring_len) |index| {
        linearized[index] = self.tail_ring[(oldest + index) % self.tail_ring.len];
    }

    const suppressed_len = @min(self.suppressed_tail_bytes, ring_len);
    const suppressed = linearized[ring_len - suppressed_len .. ring_len];
    var view_start = suppressed.len;
    if (view_start != 0 and suppressed[view_start - 1] == '\n') view_start -= 1;
    var current_line_end = view_start;
    var visible_lines: usize = 0;
    while (view_start != 0) {
        view_start -= 1;
        if (suppressed[view_start] != '\n') continue;
        const candidate = view_start + 1;
        if (current_line_end > candidate and
            !lineIsBlank(suppressed[candidate..current_line_end]))
        {
            visible_lines += 1;
            if (visible_lines == tail_lines) {
                view_start = candidate;
                break;
            }
        }
        current_line_end = view_start;
    }
    while (view_start < suppressed.len and suppressed[view_start] & 0xc0 == 0x80) {
        view_start += 1;
    }

    const Span = struct { start: usize, end: usize };
    var spans: [tail_lines]Span = undefined;
    var span_count: usize = 0;
    var line_start = view_start;
    var index = view_start;
    while (index <= suppressed.len) : (index += 1) {
        if (index < suppressed.len and suppressed[index] != '\n') continue;
        if (index > line_start and !lineIsBlank(suppressed[line_start..index]) and span_count < spans.len) {
            spans[span_count] = .{ .start = line_start, .end = index };
            span_count += 1;
        }
        line_start = index + 1;
    }

    const elided = self.suppressed_lines -| span_count;
    if (elided != 0) {
        var marker_buffer: [96]u8 = undefined;
        const marker = std.fmt.bufPrint(
            &marker_buffer,
            "... ({d} more line{s}) ...",
            .{ elided, if (elided == 1) "" else "s" },
        ) catch unreachable;
        self.addRow(marker, .plain);
    }
    for (spans[0..span_count], 0..) |span, row| {
        const bytes = if (row + 1 == span_count and self.latest_suppressed_len != 0)
            self.latest_suppressed[0..self.latest_suppressed_len]
        else
            suppressed[span.start..span.end];
        self.addRow(bytes, .plain);
    }
}

fn lineIsBlank(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != ' ') return false;
    return true;
}

fn finishLine(self: *ToolRenderer) void {
    const line_value = self.line.items;
    if (self.mode == .unified_diff) {
        self.finishDiffLine(line_value);
    } else if (self.line_has_content) {
        self.finishPreviewLine(line_value);
    }
    self.line.clearRetainingCapacity();
    self.line_has_content = false;
    self.line_tail_bytes = 0;
}

fn finishPreviewLine(self: *ToolRenderer, bytes: []const u8) void {
    const limit_lines = if (self.mode == .head_tail) head_tail_lines else head_lines;
    const limit_bytes = if (self.mode == .head_tail) head_tail_bytes else head_bytes;
    if (self.head_lines_emitted < limit_lines and self.head_bytes_emitted < limit_bytes) {
        self.addRow(bytes, .plain);
        self.head_lines_emitted += 1;
        self.head_bytes_emitted +|= bytes.len + 1;
        if (self.head_lines_emitted >= limit_lines or self.head_bytes_emitted >= limit_bytes) {
            self.head_complete = true;
        }
        return;
    }

    self.suppressed_lines +|= 1;
    if (self.mode != .head_tail) return;
    const amount = @min(bytes.len, self.latest_suppressed.len);
    @memcpy(self.latest_suppressed[0..amount], bytes[0..amount]);
    self.latest_suppressed_len = amount;
}

fn finishDiffLine(self: *ToolRenderer, bytes: []const u8) void {
    if (!self.diff_hunk_started and
        (std.mem.startsWith(u8, bytes, "--- ") or std.mem.startsWith(u8, bytes, "+++ ")))
    {
        return;
    }
    const class: RowClass = if (self.diff_hunk_started and std.mem.startsWith(u8, bytes, "+"))
        .add
    else if (self.diff_hunk_started and std.mem.startsWith(u8, bytes, "-"))
        .remove
    else
        .plain;
    self.addRow(bytes, class);
    if (std.mem.startsWith(u8, bytes, "@@")) self.diff_hunk_started = true;
}

fn addRow(self: *ToolRenderer, bytes: []const u8, class: RowClass) void {
    const clipped = self.clipRow(bytes) catch {
        self.allocation_failed = true;
        return;
    };
    self.addOwnedRow(.{ .bytes = clipped, .class = class });
}

fn addOwnedRow(self: *ToolRenderer, row: Row) void {
    if (self.allocation_failed) {
        var discarded = row;
        discarded.deinit(self.allocator);
        return;
    }
    self.flushPending(false);
    if (self.write_error != null) {
        var discarded = row;
        discarded.deinit(self.allocator);
        return;
    }
    self.pending = row;
    self.rows_added +|= 1;
}

fn flushPending(self: *ToolRenderer, final: bool) void {
    var row = self.pending orelse return;
    self.pending = null;
    defer row.deinit(self.allocator);
    const glyph = if (final)
        if (self.rows_added == 1) "›" else "└"
    else if (self.rows_added == 1)
        "┌"
    else
        "│";
    self.write(self.theme.chrome_dim.open);
    self.write(glyph);
    self.write(" \x1b[0m");
    switch (row.class) {
        .plain => self.write("\x1b[2m"),
        .add => self.write(self.theme.add.open),
        .remove => self.write(self.theme.remove.open),
    }
    self.write(row.bytes);
    self.write("\x1b[0m\n");
}

fn clipRow(self: *ToolRenderer, bytes: []const u8) error{OutOfMemory}![]u8 {
    const budget = if (self.width <= gutter_columns + 5)
        1
    else
        @min(self.width - gutter_columns - 1, line_bytes);
    if (text.DisplayWidth.visibleWidth(bytes, budget + 1) <= budget) {
        return self.allocator.dupe(u8, bytes);
    }

    const dots = @min(budget, 3);
    const prefix_budget = budget - dots;
    var end: usize = 0;
    var cells: usize = 0;
    var glyphs = text.DisplayWidth.iterator(bytes);
    while (glyphs.next()) |glyph| {
        if (glyph.width > prefix_budget -| cells) break;
        end = glyphs.offset;
        cells += glyph.width;
    }
    const output = try self.allocator.alloc(u8, end + dots);
    @memcpy(output[0..end], bytes[0..end]);
    @memset(output[end..], '.');
    return output;
}

fn write(self: *ToolRenderer, bytes: []const u8) void {
    if (self.write_error != null or bytes.len == 0) return;
    self.writer.writeAll(bytes) catch |err| {
        self.write_error = err;
    };
}

fn flushWriter(self: *ToolRenderer) void {
    if (self.write_error != null) return;
    self.writer.flush() catch |err| {
        self.write_error = err;
    };
}

fn testTheme() !Theme {
    return Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
}

fn renderOne(mode: Mode, bytes: []const u8, width: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer output.deinit();
    var renderer = init(std.testing.allocator, &output.writer, try testTheme(), width, mode);
    defer renderer.deinit();
    try renderer.feed(bytes);
    try renderer.finalize();
    return output.toOwnedSlice();
}

test "empty and blank-only previews emit nothing" {
    const empty = try renderOne(.head, "", 80);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const blank = try renderOne(.head, "\n  \n\t\n", 80);
    defer std.testing.allocator.free(blank);
    try std.testing.expectEqualStrings("", blank);
}

test "single and multiple rows use closed gutters" {
    const single = try renderOne(.head, "only\n", 80);
    defer std.testing.allocator.free(single);
    try std.testing.expect(std.mem.indexOf(u8, single, "› \x1b[0m\x1b[2monly") != null);
    const multiple = try renderOne(.head, "hello\nworld\n", 80);
    defer std.testing.allocator.free(multiple);
    try std.testing.expect(std.mem.indexOf(u8, multiple, "┌ \x1b[0m\x1b[2mhello") != null);
    try std.testing.expect(std.mem.indexOf(u8, multiple, "└ \x1b[0m\x1b[2mworld") != null);
}

test "plain previews elide blanks expand tabs and flush trailing lines" {
    const output = try renderOne(.head, "a\n\n\t\tb\npartial", 80);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "        b") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "partial") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output, '\t') == null);
}

test "head preview caps rows and reports suppression" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    for (0..20) |index| {
        var buffer: [32]u8 = undefined;
        try input.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&buffer, "line{d}\n", .{index}));
    }
    const output = try renderOne(.head, input.items, 80);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "line0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "12 more lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line19") == null);
}

test "head-tail preview retains the newest four rows" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    for (0..20) |index| {
        var buffer: [32]u8 = undefined;
        try input.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&buffer, "row{d:0>2}\n", .{index}));
    }
    const output = try renderOne(.head_tail, input.items, 80);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "row00") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "row19") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "12 more lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "row10") == null);
}

test "head-tail suffix is bounded by hax's byte ring" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "h1\nh2\nh3\nh4\nOLD-A-");
    try input.appendNTimes(std.testing.allocator, 'a', 900);
    try input.appendSlice(std.testing.allocator, "\nOLD-B-");
    try input.appendNTimes(std.testing.allocator, 'b', 900);
    try input.appendSlice(std.testing.allocator, "\nnewest\n");

    const output = try renderOne(.head_tail, input.items, 80);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "OLD-A-") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "OLD-B-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "newest") != null);
}

test "head-tail newest long line replays its display prefix" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendSlice(std.testing.allocator, "h1\nh2\nh3\nh4\nPREFIX-");
    try input.appendNTimes(std.testing.allocator, 'x', 2000);
    try input.appendSlice(std.testing.allocator, "-SUFFIX\n");

    const output = try renderOne(.head_tail, input.items, 80);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "PREFIX-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SUFFIX") == null);
}

test "modest head-tail overflow replays without a marker" {
    const output = try renderOne(.head_tail, "a\nb\nc\nd\ne\n", 80);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "e") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "more line") == null);
}

test "rows truncate by display cells without splitting UTF-8" {
    const output = try renderOne(.head, "123456界789\n", 10);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.unicode.utf8ValidateSlice(output));
    try std.testing.expect(std.mem.indexOf(u8, output, "...") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "789") == null);
}

test "unified diff drops file headers and colors hunk rows" {
    const output = try renderOne(
        .unified_diff,
        "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n context\n",
        80,
    );
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "a/x") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "b/x") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31m-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[32m+new") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " context") != null);
}

test "control sequences malformed UTF-8 and unsafe scalars are sanitized" {
    const output = try renderOne(.head, "ab\x07\x1b[31mc\x1b[m\xff\xe2\x80\xae\xc2\xadd\n", 80);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "abc\xef\xbf\xbd??d") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31mc") == null);
}

test "display sink records even an empty callback" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = init(std.testing.allocator, &output.writer, try testTheme(), 80, .head);
    defer renderer.deinit();
    try renderer.sink().emit("");
    try std.testing.expect(renderer.display_was_called);
    try renderer.finalize();
    try std.testing.expectEqualStrings("", output.written());
}

test "finalize is idempotent and writer failures are sticky" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var renderer = init(std.testing.allocator, &output.writer, try testTheme(), 80, .head);
    defer renderer.deinit();
    try renderer.feed("x\n");
    try renderer.finalize();
    const first_len = output.written().len;
    try renderer.finalize();
    try std.testing.expectEqual(first_len, output.written().len);

    var failed_writer: std.Io.Writer = .failing;
    var failed = init(std.testing.allocator, &failed_writer, try testTheme(), 80, .head);
    defer failed.deinit();
    try failed.feed("x\n");
    try std.testing.expectError(error.WriteFailed, failed.finalize());
}
