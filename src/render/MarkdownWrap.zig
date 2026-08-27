const std = @import("std");
const DisplayWidth = @import("../text/DisplayWidth.zig");
const MarkdownOutput = @import("MarkdownOutput.zig");
const Theme = @import("Theme.zig");

const MarkdownWrap = @This();
const Error = MarkdownOutput.Error;

/// The row shadow and its one-byte-per-row-byte kind map share this bound.
/// A retained content byte therefore consumes two bytes from the budget.
const maximum_retained_bytes: usize = 64 * 1024 * 1024;
const minimum_continuation_content: usize = 8;

const ansi_bold = "\x1b[1m";
const ansi_bold_off = "\x1b[22m";
const ansi_italic = "\x1b[3m";
const ansi_italic_off = "\x1b[23m";
const ansi_erase_line = "\x1b[K";
const spaces = "                                ";

allocator: std.mem.Allocator,
wrap_width: usize,
cell_stream: CellStream = .{},
row: std.ArrayList(u8) = .empty,
row_meta: std.ArrayList(u8) = .empty,
col: usize = 0,
last_break_byte: ?usize = null,
last_break_col: usize = 0,
indent_cells: usize = 0,
indent_locked: bool = false,
row_has_content: bool = false,
pending_wrap: bool = false,
snap_in_bold: bool = false,
snap_in_italic: bool = false,
snap_in_inline_code: bool = false,
snap_in_link: bool = false,

pub const Context = struct {
    sink: MarkdownOutput.Sink,
    theme: *const Theme,
    styled: bool,
    in_bold: bool,
    in_italic: bool,
    in_inline_code: bool,
    in_link: bool,
};

/// Initializes a reusable eager wrapper. The row shadow is allocated lazily.
pub fn init(allocator: std.mem.Allocator, wrap_width: usize) MarkdownWrap {
    return .{
        .allocator = allocator,
        .wrap_width = wrap_width,
    };
}

pub fn deinit(self: *MarkdownWrap) void {
    self.row.deinit(self.allocator);
    self.row_meta.deinit(self.allocator);
}

/// Resets a stream while retaining the row buffers' capacity.
pub fn reset(self: *MarkdownWrap, wrap_width: usize) void {
    self.wrap_width = wrap_width;
    self.cell_stream.reset();
    self.rowReset();
    self.pending_wrap = false;
    self.snap_in_bold = false;
    self.snap_in_italic = false;
    self.snap_in_inline_code = false;
    self.snap_in_link = false;
}

pub fn width(self: *const MarkdownWrap) usize {
    return self.wrap_width;
}

/// Discards the current row shadow after direct output. A deferred edge wrap is
/// intentionally left pending, matching the boundary between the two callers.
pub fn rowReset(self: *MarkdownWrap) void {
    self.row.clearRetainingCapacity();
    self.row_meta.clearRetainingCapacity();
    self.col = 0;
    self.last_break_byte = null;
    self.last_break_col = 0;
    self.indent_cells = 0;
    self.indent_locked = false;
    self.row_has_content = false;
}

/// Emits text either directly (verbatim or disabled wrapping), or through the
/// incremental cell stream. Input is borrowed for the duration of the call.
pub fn emitText(
    self: *MarkdownWrap,
    context: Context,
    input: []const u8,
    verbatim: bool,
) MarkdownOutput.Error!void {
    const bypass = self.wrap_width == 0 or verbatim;
    const tab_replacement = if (bypass) "    " else " ";
    var start: usize = 0;
    for (input, 0..) |byte, index| {
        if (byte != '\t') continue;
        if (index > start) try self.emitTextChunk(context, input[start..index], verbatim);
        try self.emitTextChunk(context, tab_replacement, verbatim);
        start = index + 1;
    }
    if (start < input.len) try self.emitTextChunk(context, input[start..], verbatim);
}

/// Emits a zero-width raw run. Wrapped non-verbatim runs are retained so a
/// retroactive replay can reproduce raw/content boundaries.
pub fn emitRaw(
    self: *MarkdownWrap,
    context: Context,
    input: []const u8,
    verbatim: bool,
) MarkdownOutput.Error!void {
    if (self.wrap_width == 0) {
        try context.sink.emit(input, .raw);
        return;
    }

    if (verbatim) {
        try self.drainCellStream(context);
        try context.sink.emit(input, .raw);
        return;
    }

    try self.drainCellStream(context);
    try self.appendRetained(context, input, .raw);
}

/// Resolves an edge space before direct block output. The edge space itself is
/// omitted; a hard newline absorbs this pending state instead.
pub fn commitPending(self: *MarkdownWrap, context: Context) MarkdownOutput.Error!void {
    if (!self.pending_wrap) return;

    self.pending_wrap = false;
    const continuation_indent = self.indent_cells;
    const had_indent_lock = self.indent_locked;
    const suspend_link = context.styled and context.in_link;
    if (suspend_link) try context.sink.emit(context.theme.link.close, .raw);
    try context.sink.emit("\n", .content);
    try emitIndent(context, continuation_indent);
    if (suspend_link) try context.sink.emit(context.theme.link.open, .raw);

    self.rowReset();
    // A soft wrap is still in the same logical list item. Keep its detected
    // hanging indent until a hard newline resets it.
    self.indent_cells = continuation_indent;
    self.indent_locked = had_indent_lock;
    self.col = continuation_indent;
    self.snap_in_bold = false;
    self.snap_in_italic = false;
    self.snap_in_inline_code = false;
    self.snap_in_link = false;
}

/// Drains a split UTF-8 tail and discards the row shadow without writing a
/// terminator. The caller owns the physical line ending.
pub fn finish(self: *MarkdownWrap, context: Context) MarkdownOutput.Error!void {
    if (self.wrap_width == 0) return;
    try self.drainCellStream(context);
    self.pending_wrap = false;
    self.rowReset();
}

fn emitTextChunk(self: *MarkdownWrap, context: Context, input: []const u8, verbatim: bool) Error!void {
    if (self.wrap_width == 0 or verbatim) {
        // A caller can change from wrapped to verbatim output while a split
        // leader is held. Preserve source byte order without making the
        // verbatim run part of the wrapped row.
        if (verbatim and self.wrap_width != 0) try self.cell_stream.drainDirect(context);
        try context.sink.emit(input, .content);
        return;
    }

    for (input) |byte| {
        if (byte == '\n') {
            try self.drainCellStream(context);
            try self.hardNewline(context);
        } else {
            try self.cell_stream.feedByte(self, context, byte);
        }
    }
}

fn appendRetained(self: *MarkdownWrap, context: Context, input: []const u8, kind: MarkdownOutput.Kind) Error!void {
    if (kind == .raw and self.pending_wrap) {
        try context.sink.emit(input, kind);
        return;
    }

    try self.prepareAppend(input.len, self.pending_wrap);
    try self.commitPending(context);
    try context.sink.emit(input, kind);
    self.appendPrepared(input, kind);
}

fn prepareAppend(self: *MarkdownWrap, byte_count: usize, replacing_row: bool) Error!void {
    std.debug.assert(self.row.items.len == self.row_meta.items.len);
    const retained = if (replacing_row) 0 else blk: {
        if (self.row.items.len > maximum_retained_bytes -| self.row_meta.items.len) {
            return error.OutputTooLarge;
        }
        break :blk self.row.items.len + self.row_meta.items.len;
    };
    if (retained > maximum_retained_bytes or
        byte_count > (maximum_retained_bytes - retained) / 2)
    {
        return error.OutputTooLarge;
    }

    // Reserve both arrays before either length changes or the sink sees the
    // bytes. If the second reservation fails, both logical lengths are intact.
    try self.row.ensureUnusedCapacity(self.allocator, byte_count);
    try self.row_meta.ensureUnusedCapacity(self.allocator, byte_count);
}

fn appendPrepared(self: *MarkdownWrap, input: []const u8, kind: MarkdownOutput.Kind) void {
    self.row.appendSliceAssumeCapacity(input);
    const tag: u8 = if (kind == .raw) 1 else 0;
    for (input) |_| self.row_meta.appendAssumeCapacity(tag);
}

fn hardNewline(self: *MarkdownWrap, context: Context) Error!void {
    self.pending_wrap = false;
    try context.sink.emit("\n", .content);
    self.rowReset();
}

fn drainCellStream(self: *MarkdownWrap, context: Context) Error!void {
    try self.cell_stream.flush(self, context);
}

fn wrapBreak(self: *MarkdownWrap, context: Context) Error!void {
    if (!self.indent_locked) {
        self.indent_cells = self.computeIndent();
        self.indent_locked = true;
    }

    const break_byte = self.last_break_byte orelse return;
    const old_col = self.col;
    const break_col = self.last_break_col;
    const erase_cells = old_col -| break_col + 1;
    if (erase_cells != 0) {
        var escape: [64]u8 = undefined;
        const cursor_back = std.fmt.bufPrint(&escape, "\x1b[{d}D", .{erase_cells}) catch unreachable;
        try context.sink.emit(cursor_back, .raw);
        try context.sink.emit(ansi_erase_line, .raw);
    }
    try context.sink.emit("\n", .content);

    try self.restoreSnapshot(context);
    const suspend_link = context.styled and self.snap_in_link;
    if (suspend_link) try context.sink.emit(context.theme.link.close, .raw);
    try emitIndent(context, self.indent_cells);
    if (suspend_link) try context.sink.emit(context.theme.link.open, .raw);

    const shift = @min(break_byte + 1, self.row.items.len);
    if (shift < self.row.items.len) try self.flushRange(context, shift, self.row.items.len);

    const new_len = self.row.items.len - shift;
    if (new_len != 0) {
        @memmove(self.row.items[0..new_len], self.row.items[shift..][0..new_len]);
        @memmove(self.row_meta.items[0..new_len], self.row_meta.items[shift..][0..new_len]);
    }
    self.row.items.len = new_len;
    self.row_meta.items.len = new_len;
    self.col = self.indent_cells + (old_col - break_col);
    self.last_break_byte = null;
    self.last_break_col = 0;
}

fn restoreSnapshot(self: *MarkdownWrap, context: Context) Error!void {
    if (!context.styled) return;

    if (context.in_bold != self.snap_in_bold) {
        try context.sink.emit(if (self.snap_in_bold) ansi_bold else ansi_bold_off, .raw);
    }
    if (context.in_italic != self.snap_in_italic) {
        try context.sink.emit(if (self.snap_in_italic) ansi_italic else ansi_italic_off, .raw);
    }
    if (context.in_inline_code != self.snap_in_inline_code) {
        try context.sink.emit(
            if (self.snap_in_inline_code) context.theme.code_inline.open else context.theme.code_inline.close,
            .raw,
        );
    }
    if (context.in_link != self.snap_in_link) {
        try context.sink.emit(
            if (self.snap_in_link) context.theme.link.open else context.theme.link.close,
            .raw,
        );
    }
}

fn flushRange(self: *const MarkdownWrap, context: Context, start: usize, end: usize) Error!void {
    var offset = start;
    while (offset < end) {
        const kind = self.row_meta.items[offset];
        var next = offset + 1;
        while (next < end and self.row_meta.items[next] == kind) next += 1;
        try context.sink.emit(
            self.row.items[offset..next],
            if (kind == 1) .raw else .content,
        );
        offset = next;
    }
}

fn computeIndent(self: *const MarkdownWrap) usize {
    var offset: usize = 0;
    while (offset < self.row.items.len and self.row_meta.items[offset] == 1) offset += 1;

    var leading_spaces: usize = 0;
    while (offset < self.row.items.len and leading_spaces < 8 and
        self.row_meta.items[offset] == 0 and self.row.items[offset] == ' ')
    {
        offset += 1;
        leading_spaces += 1;
    }

    while (offset < self.row.items.len and self.row_meta.items[offset] == 1) offset += 1;
    if (offset >= self.row.items.len) return 0;

    if (offset + 3 < self.row.items.len and self.row_meta.items[offset] == 0 and
        self.row.items[offset] == 0xe2 and self.row.items[offset + 1] == 0x80 and
        self.row.items[offset + 2] == 0xa2 and self.row_meta.items[offset + 3] == 0 and
        self.row.items[offset + 3] == ' ')
    {
        return leading_spaces + 2;
    }

    const marker = self.row.items[offset];
    if ((marker == '*' or marker == '-' or marker == '+') and
        offset + 1 < self.row.items.len and self.row_meta.items[offset + 1] == 0 and
        self.row.items[offset + 1] == ' ')
    {
        return leading_spaces + 2;
    }

    if (marker >= '0' and marker <= '9') {
        var end = offset + 1;
        while (end < self.row.items.len and self.row_meta.items[end] == 0 and
            self.row.items[end] >= '0' and self.row.items[end] <= '9')
        {
            end += 1;
        }
        if (end > offset and end + 1 < self.row.items.len and self.row_meta.items[end] == 0 and
            (self.row.items[end] == '.' or self.row.items[end] == ')') and
            self.row_meta.items[end + 1] == 0 and self.row.items[end + 1] == ' ')
        {
            return leading_spaces + (end - offset) + 2;
        }
    }

    return leading_spaces;
}

fn currentBudget(self: *const MarkdownWrap) usize {
    if (self.indent_cells == 0 or self.indent_cells < self.wrap_width) return self.wrap_width;
    return self.indent_cells + minimum_continuation_content;
}

fn overflows(column: usize, cells: usize, budget: usize) bool {
    return column > budget or cells > budget -| column;
}

fn consumeCodepoint(
    self: *MarkdownWrap,
    context: Context,
    output: []const u8,
    cells: usize,
) Error!void {
    // CR is the other half of CRLF. Suppress only a standalone CR; malformed
    // runs remain byte-exact and count each byte as a cell.
    if (output.len == 1 and output[0] == '\r') return;
    if (output.len == 1 and output[0] == ' ' and self.pending_wrap) return;

    const is_space = output.len == 1 and output[0] == ' ';
    if (cells != 0) {
        const budget = self.currentBudget();
        if (is_space and self.row_has_content and overflows(self.col, cells, budget)) {
            self.pending_wrap = true;
            return;
        }
        try self.prepareAppend(output.len, self.pending_wrap);
        try self.commitPending(context);
        if (!is_space and overflows(self.col, cells, self.currentBudget()) and self.last_break_byte != null) {
            try self.wrapBreak(context);
        }
    } else {
        try self.prepareAppend(output.len, self.pending_wrap);
        try self.commitPending(context);
    }

    try context.sink.emit(output, .content);
    self.appendPrepared(output, .content);

    if (cells == 0) return;
    self.col += cells;
    if (is_space) {
        if (!self.row_has_content) return;

        if (self.last_break_byte == null and !self.indent_locked) {
            self.indent_cells = self.computeIndent();
            self.indent_locked = true;
        }
        const new_break = self.row.items.len - 1;
        const shift = new_break;
        if (shift != 0) {
            const new_len = self.row.items.len - shift;
            @memmove(self.row.items[0..new_len], self.row.items[shift..][0..new_len]);
            @memmove(self.row_meta.items[0..new_len], self.row_meta.items[shift..][0..new_len]);
            self.row.items.len = new_len;
            self.row_meta.items.len = new_len;
        }
        self.last_break_byte = new_break - shift;
        self.last_break_col = self.col;
        self.snap_in_bold = context.in_bold;
        self.snap_in_italic = context.in_italic;
        self.snap_in_inline_code = context.in_inline_code;
        self.snap_in_link = context.in_link;
    } else {
        self.row_has_content = true;
    }
}

fn emitIndent(context: Context, count: usize) Error!void {
    var remaining = count;
    while (remaining != 0) {
        const chunk = @min(remaining, spaces.len);
        try context.sink.emit(spaces[0..chunk], .content);
        remaining -= chunk;
    }
}

const CellStream = struct {
    pending: [4]u8 = undefined,
    pending_len: u3 = 0,
    expected_len: u3 = 0,

    fn reset(self: *CellStream) void {
        self.pending_len = 0;
        self.expected_len = 0;
    }

    fn feedByte(self: *CellStream, owner: *MarkdownWrap, context: Context, byte: u8) Error!void {
        if (self.pending_len == 0) {
            self.pending[0] = byte;
            self.pending_len = 1;
            self.expected_len = sequenceLength(byte);
            if (self.expected_len == 1) try self.finishUnit(owner, context, false);
            return;
        }

        if (!isContinuation(byte)) {
            self.pending[self.pending_len] = byte;
            self.pending_len += 1;
            try self.finishUnit(owner, context, true);
            return;
        }

        self.pending[self.pending_len] = byte;
        self.pending_len += 1;
        if (self.pending_len < self.expected_len) return;
        const malformed = !validSequence(self.pending[0..self.expected_len]);
        try self.finishUnit(owner, context, malformed);
    }

    fn flush(self: *CellStream, owner: *MarkdownWrap, context: Context) Error!void {
        if (self.pending_len == 0) return;
        try self.finishUnit(owner, context, true);
    }

    fn drainDirect(self: *CellStream, context: Context) Error!void {
        if (self.pending_len == 0) return;
        try context.sink.emit(self.pending[0..self.pending_len], .content);
        self.reset();
    }

    fn finishUnit(
        self: *CellStream,
        owner: *MarkdownWrap,
        context: Context,
        malformed: bool,
    ) Error!void {
        const length: usize = self.pending_len;
        const cells: usize = if (malformed)
            length
        else
            DisplayWidth.next(self.pending[0..length], 0).?.width;
        try owner.consumeCodepoint(context, self.pending[0..length], cells);
        self.reset();
    }

    fn sequenceLength(byte: u8) u3 {
        if (byte >= 0xc2 and byte <= 0xdf) return 2;
        if (byte >= 0xe0 and byte <= 0xef) return 3;
        if (byte >= 0xf0 and byte <= 0xf4) return 4;
        return 1;
    }

    fn isContinuation(byte: u8) bool {
        return byte & 0xc0 == 0x80;
    }

    fn validSequence(sequence: []const u8) bool {
        if (sequence.len == 1) return sequence[0] < 0x80;
        for (sequence[1..]) |byte| if (!isContinuation(byte)) return false;
        return switch (sequence.len) {
            2 => true,
            3 => !((sequence[0] == 0xe0 and sequence[1] < 0xa0) or
                (sequence[0] == 0xed and sequence[1] > 0x9f)),
            4 => !((sequence[0] == 0xf0 and sequence[1] < 0x90) or
                (sequence[0] == 0xf4 and sequence[1] > 0x8f)),
            else => false,
        };
    }
};

comptime {
    _ = MarkdownOutput;
    _ = Theme;
}

const TestCapture = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    raw: std.ArrayList(u8) = .empty,
    wire: std.ArrayList(u8) = .empty,
    calls: usize = 0,

    fn init(allocator: std.mem.Allocator) TestCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestCapture) void {
        self.text.deinit(self.allocator);
        self.raw.deinit(self.allocator);
        self.wire.deinit(self.allocator);
    }

    fn reset(self: *TestCapture) void {
        self.text.clearRetainingCapacity();
        self.raw.clearRetainingCapacity();
        self.wire.clearRetainingCapacity();
        self.calls = 0;
    }

    pub fn emit(self: *TestCapture, bytes: []const u8, kind: MarkdownOutput.Kind) Error!void {
        switch (kind) {
            .content => try self.text.appendSlice(self.allocator, bytes),
            .raw => try self.raw.appendSlice(self.allocator, bytes),
        }
        try self.wire.appendSlice(self.allocator, bytes);
        self.calls += 1;
    }
};

fn testContext(capture: *TestCapture, theme: *const Theme) Context {
    return .{
        .sink = MarkdownOutput.Sink.from(capture),
        .theme = theme,
        .styled = true,
        .in_bold = false,
        .in_italic = false,
        .in_inline_code = false,
        .in_link = false,
    };
}

test "text emits eagerly" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 100);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "alpha ", false);
    try std.testing.expectEqualStrings("alpha ", capture.wire.items);
    try std.testing.expectEqual(@as(usize, 6), capture.calls);
    try wrapper.emitText(context, "beta", false);
    try std.testing.expectEqualStrings("alpha beta", capture.wire.items);
    try std.testing.expectEqual(@as(usize, 10), capture.calls);
    try wrapper.finish(context);
    try std.testing.expectEqual(@as(usize, 10), capture.calls);
}

test "retroactive break preserves wire and byte kinds" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 10);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "abc def ghi", false);
    try wrapper.finish(context);

    try std.testing.expectEqualStrings("abc def gh\x1b[3D\x1b[K\nghi", capture.wire.items);
    try std.testing.expectEqualStrings("abc def gh\nghi", capture.text.items);
    try std.testing.expectEqualStrings("\x1b[3D\x1b[K", capture.raw.items);
}

test "tabs follow wrapped and verbatim policies" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 4);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "ab\tcd", false);
    try wrapper.finish(context);
    try std.testing.expectEqualStrings("ab c\x1b[2D\x1b[K\ncd", capture.wire.items);

    capture.reset();
    wrapper.reset(4);
    try wrapper.emitText(context, "ab\tcd", true);
    try std.testing.expectEqualStrings("ab    cd", capture.wire.items);

    capture.reset();
    wrapper.reset(0);
    try wrapper.emitText(context, "ab\tcd", false);
    try std.testing.expectEqualStrings("ab    cd", capture.wire.items);
}

test "partial UTF-8 drains before newline and raw" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 80);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "A\xc3", false);
    try wrapper.emitText(context, "\nX", false);
    try std.testing.expectEqualStrings("A\xc3\nX", capture.wire.items);

    capture.reset();
    wrapper.reset(80);
    try wrapper.emitText(context, "A\xc3", false);
    try wrapper.emitRaw(context, ansi_bold, false);
    try std.testing.expectEqualStrings("A\xc3" ++ ansi_bold, capture.wire.items);
    try std.testing.expectEqualStrings("A\xc3", capture.text.items);
    try std.testing.expectEqualStrings(ansi_bold, capture.raw.items);
}

test "split multibyte input counts cells consistently" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 8);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "h\xc3", false);
    try wrapper.emitText(context, "\xa9llo w\xc3\xb6rld", false);
    try wrapper.finish(context);
    try std.testing.expectEqualStrings(
        "h\xc3\xa9llo w\xc3\xb6\x1b[3D\x1b[K\nw\xc3\xb6rld",
        capture.wire.items,
    );
}

test "edge spaces defer a wrap" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 7);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "foo bar  ", false);
    try std.testing.expectEqualStrings("foo bar", capture.wire.items);
    try wrapper.commitPending(context);
    try std.testing.expectEqualStrings("foo bar\n", capture.wire.items);
}

test "hard newline absorbs an edge wrap" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 5);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "aaaaa  \r\nbar", false);
    try wrapper.finish(context);
    try std.testing.expectEqualStrings("aaaaa\nbar", capture.wire.items);
    try std.testing.expectEqualStrings("", capture.raw.items);
}

test "raw output does not commit a pending wrap" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 7);
    defer wrapper.deinit();
    var context = testContext(&capture, &theme);

    try wrapper.emitText(context, "foo bar ", false);
    try wrapper.emitRaw(context, ansi_bold, false);
    context.in_bold = true;
    try wrapper.emitText(context, "baz", false);
    try wrapper.emitRaw(context, ansi_bold_off, false);
    context.in_bold = false;
    try wrapper.finish(context);

    try std.testing.expectEqualStrings("foo bar" ++ ansi_bold ++ "\nbaz" ++ ansi_bold_off, capture.wire.items);
}

test "list markers set a hanging indent" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 15);
    defer wrapper.deinit();
    const context = testContext(&capture, &theme);

    try wrapper.emitText(context, "* alpha beta gamma", false);
    try wrapper.finish(context);
    try std.testing.expectEqualStrings("* alpha beta ga\x1b[3D\x1b[K\n  gamma", capture.wire.items);
}

test "retroactive replay restores the style snapshot" {
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(std.testing.allocator, 8);
    defer wrapper.deinit();
    var context = testContext(&capture, &theme);

    try wrapper.emitRaw(context, ansi_bold, false);
    context.in_bold = true;
    try wrapper.emitText(context, "foo bar", false);
    try wrapper.emitRaw(context, ansi_bold_off, false);
    context.in_bold = false;
    try wrapper.emitText(context, "baz", false);
    try wrapper.finish(context);

    try std.testing.expectEqualStrings(
        ansi_bold ++ "foo bar" ++ ansi_bold_off ++ "b\x1b[5D\x1b[K\n" ++ ansi_bold ++ "bar" ++
            ansi_bold_off ++ "baz",
        capture.wire.items,
    );
}

test "allocation failures leave both row arrays deinitializable" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseWrapAllocations,
        .{},
    );
}

fn exerciseWrapAllocations(allocator: std.mem.Allocator) !void {
    const Discard = struct {
        pub fn emit(_: *@This(), _: []const u8, _: MarkdownOutput.Kind) Error!void {}
    };
    var discard: Discard = .{};
    const theme = try Theme.resolve(.{ .configured_theme = "ansi", .configured_tint = "teal" });
    var wrapper = MarkdownWrap.init(allocator, 100);
    defer wrapper.deinit();
    const context: Context = .{
        .sink = MarkdownOutput.Sink.from(&discard),
        .theme = &theme,
        .styled = true,
        .in_bold = false,
        .in_italic = false,
        .in_inline_code = false,
        .in_link = false,
    };
    try wrapper.emitText(context, "allocation", false);
}

comptime {
    _ = maximum_retained_bytes;
}
