const std = @import("std");
const text = @import("../text/root.zig");

const DisplayWidth = text.DisplayWidth;

/// Layout is deliberately bounded so untrusted terminal reports cannot cause large
/// coordinates or arithmetic overflow. A zero column count disables soft wrapping.
pub const max_terminal_columns: usize = 4096;
pub const tab_width: usize = 4;
const pending_capacity = 256;
const tab_spaces = "    ";

pub const Position = struct {
    row: usize,
    column: usize,
};

pub const Layout = struct {
    cursor: Position,
    end: Position,
    total_rows: usize,
};

pub const Glyph = struct {
    /// Borrowed from the input or static storage. Valid only during the call.
    bytes: []const u8,
    width: usize,
    position: Position,
};

pub const Event = union(enum) {
    glyph: Glyph,
    /// Position at which the new row starts.
    row_break: Position,
};

/// A tiny erased synchronous event sink. Implementations must not retain glyph bytes.
pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: Event) void,

    pub fn emit(self: Sink, event: Event) void {
        self.emit_fn(self.context, event);
    }
};

pub const Options = struct {
    prompt_width: usize = 0,
    continuation_column: usize = 0,
    columns: usize = 0,
};

const DecodedGlyph = struct {
    bytes: []const u8,
    width: usize,
    offset: usize,
    consumed: usize,
    is_space: bool,
};

fn decodeGlyph(input: []const u8, offset: usize) DecodedGlyph {
    if (input[offset] == '\t') return .{
        .bytes = tab_spaces,
        .width = tab_width,
        .offset = offset,
        .consumed = 1,
        .is_space = false,
    };

    const glyph = DisplayWidth.next(input, offset) orelse unreachable;
    return .{
        .bytes = glyph.bytes,
        .width = glyph.width,
        .offset = offset,
        .consumed = glyph.consumed,
        .is_space = glyph.is_ascii_space,
    };
}

/// Return the first-line prompt width. Only complete CSI SGR sequences of at
/// most 64 bytes are ignored. Other escape bytes render as substitution cells.
pub fn promptWidth(prompt: []const u8) usize {
    var width: usize = 0;
    var offset: usize = 0;
    while (offset < prompt.len and prompt[offset] != '\n') {
        if (prompt[offset] == 0x1b) {
            if (sgrLength(prompt[offset..])) |length| {
                offset += length;
                continue;
            }
        }
        const glyph = decodeGlyph(prompt, offset);
        width = @min(max_terminal_columns, width +| glyph.width);
        offset += glyph.consumed;
    }
    return width;
}

fn sgrLength(input: []const u8) ?usize {
    if (input.len < 3 or input[0] != 0x1b or input[1] != '[') return null;
    const limit = @min(input.len, 64);
    var index: usize = 2;
    while (index < limit) : (index += 1) {
        const byte = input[index];
        if (byte >= 0x40 and byte <= 0x7e)
            return if (byte == 'm') index + 1 else null;
        if (byte < 0x20 or byte > 0x3f) return null;
    }
    return null;
}

const State = struct {
    continuation_column: usize,
    columns: usize,
    cursor: usize,
    sink: ?Sink,
    row: usize = 0,
    column: usize,
    cursor_position: ?Position = null,
    pending: [pending_capacity]DecodedGlyph = undefined,
    pending_len: usize = 0,
    pending_width: usize = 0,
    pending_after_space: bool = false,

    fn emitGlyph(self: *State, glyph: DecodedGlyph) void {
        if (self.cursor_position == null and self.cursor >= glyph.offset and
            self.cursor < glyph.offset + glyph.consumed)
        {
            self.cursor_position = .{ .row = self.row, .column = self.column };
        }
        if (self.sink) |sink| sink.emit(.{ .glyph = .{
            .bytes = glyph.bytes,
            .width = glyph.width,
            .position = .{ .row = self.row, .column = self.column },
        } });
        self.column +|= glyph.width;
    }

    fn emitRowBreak(self: *State) void {
        self.row += 1;
        self.column = self.continuation_column;
        if (self.sink) |sink| sink.emit(.{ .row_break = .{
            .row = self.row,
            .column = self.column,
        } });
    }

    fn flushPending(self: *State) void {
        for (self.pending[0..self.pending_len]) |glyph| self.emitGlyph(glyph);
        self.pending_len = 0;
        self.pending_width = 0;
        self.pending_after_space = false;
    }

    fn replayPending(self: *State) void {
        self.emitRowBreak();
        for (self.pending[0..self.pending_len]) |glyph| self.emitGlyph(glyph);
        self.pending_len = 0;
        self.pending_width = 0;
        self.pending_after_space = false;
    }
};

/// Emit borrowed glyph and row-break events in visual order and return layout.
/// Cursor is a byte offset and is clamped to input.len.
pub fn render(input: []const u8, cursor: usize, options: Options, sink: ?Sink) Layout {
    const prompt_column = @min(options.prompt_width, max_terminal_columns);
    const continuation_column = @min(options.continuation_column, max_terminal_columns);
    const columns = @min(options.columns, max_terminal_columns);
    var state: State = .{
        .continuation_column = continuation_column,
        .columns = columns,
        .cursor = @min(cursor, input.len),
        .sink = sink,
        .column = prompt_column,
    };

    var offset: usize = 0;
    while (offset < input.len) {
        if (input[offset] == '\n') {
            state.flushPending();
            if (state.cursor_position == null and state.cursor == offset)
                state.cursor_position = .{ .row = state.row, .column = state.column };
            state.emitRowBreak();
            offset += 1;
            continue;
        }

        const glyph = decodeGlyph(input, offset);
        if (glyph.width == 0) {
            if (state.pending_len < pending_capacity) {
                state.pending[state.pending_len] = glyph;
                state.pending_len += 1;
            } else {
                state.flushPending();
                state.emitGlyph(glyph);
            }
            offset += glyph.consumed;
            continue;
        }

        if (glyph.is_space) {
            const overflows = columns > 0 and
                state.column +| state.pending_width +| glyph.width >= columns;
            state.flushPending();
            if (overflows and state.column > continuation_column) {
                if (state.cursor_position == null and state.cursor == glyph.offset)
                    state.cursor_position = .{ .row = state.row, .column = state.column };
                state.emitRowBreak();
            } else {
                state.emitGlyph(glyph);
                state.pending_after_space = true;
            }
            offset += glyph.consumed;
            continue;
        }

        const prospective = state.column +| state.pending_width +| glyph.width;
        if (columns > 0 and prospective >= columns) {
            if (state.pending_len > 0 and state.pending_after_space and
                state.column > continuation_column)
            {
                state.replayPending();
            } else {
                state.flushPending();
                if (state.column > continuation_column) state.emitRowBreak();
            }
        }

        if (state.pending_len < pending_capacity) {
            state.pending[state.pending_len] = glyph;
            state.pending_len += 1;
            state.pending_width +|= glyph.width;
        } else {
            state.flushPending();
            if (columns > 0 and state.column +| glyph.width >= columns and
                state.column > continuation_column)
                state.emitRowBreak();
            state.emitGlyph(glyph);
        }
        offset += glyph.consumed;
    }

    if (state.pending_len > 0 and columns > 0 and
        state.column +| state.pending_width >= columns and state.pending_after_space and
        state.column > continuation_column)
    {
        state.replayPending();
    } else {
        state.flushPending();
    }

    const cursor_position = state.cursor_position orelse
        Position{ .row = state.row, .column = state.column };
    return .{
        .cursor = cursor_position,
        .end = .{ .row = state.row, .column = state.column },
        .total_rows = state.row + 1,
    };
}

pub fn compute(input: []const u8, cursor: usize, prompt_width: usize, columns: usize) Layout {
    return render(input, cursor, .{
        .prompt_width = prompt_width,
        .continuation_column = prompt_width,
        .columns = columns,
    }, null);
}

const Recording = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, event: Event) void {
        const self: *Recording = @ptrCast(@alignCast(context));
        switch (event) {
            .row_break => self.append("/"),
            .glyph => |glyph| self.append(glyph.bytes),
        }
    }

    fn append(self: *Recording, bytes: []const u8) void {
        const count = @min(bytes.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..count], bytes[0..count]);
        self.len += count;
    }

    fn sink(self: *Recording) Sink {
        return .{ .context = self, .emit_fn = emit };
    }
};

fn expectPosition(expected_row: usize, expected_column: usize, actual: Position) !void {
    try std.testing.expectEqual(expected_row, actual.row);
    try std.testing.expectEqual(expected_column, actual.column);
}

test "prompt width ignores bounded SGR and handles text safely" {
    try std.testing.expectEqual(3, promptWidth("\x1b[31m> \x1b[0mé"));
    try std.testing.expectEqual(2, promptWidth("ab\nignored"));
    try std.testing.expectEqual(5, promptWidth("\x1b[2Jx"));
    try std.testing.expectEqual(1, promptWidth("\xff"));
}

test "empty and ASCII cursor positions" {
    var layout = compute("", 0, 2, 80);
    try expectPosition(0, 2, layout.cursor);
    try expectPosition(0, 2, layout.end);
    try std.testing.expectEqual(1, layout.total_rows);

    layout = compute("hello", 3, 2, 80);
    try expectPosition(0, 5, layout.cursor);
    try expectPosition(0, 7, layout.end);
}

test "explicit newlines and continuation indentation" {
    var layout = compute("ab\ncd", 2, 2, 80);
    try expectPosition(0, 4, layout.cursor);
    try expectPosition(1, 4, layout.end);
    layout = compute("ab\n", 3, 2, 80);
    try expectPosition(1, 2, layout.cursor);
    try std.testing.expectEqual(2, layout.total_rows);

    layout = render("a\nb", 3, .{
        .prompt_width = 3,
        .continuation_column = 1,
        .columns = 80,
    }, null);
    try expectPosition(1, 2, layout.end);
}

test "wide and combining UTF-8 use terminal cells" {
    const layout = compute("A界e\xcc\x81", 7, 0, 80);
    try expectPosition(0, 4, layout.end);
    try expectPosition(0, 4, layout.cursor);
}

test "malformed and control input is substituted" {
    var recording: Recording = .{};
    var layout = render("a\x07\xffb", 4, .{}, recording.sink());
    try std.testing.expectEqualStrings("a??b", recording.bytes[0..recording.len]);
    try expectPosition(0, 4, layout.end);

    recording = .{};
    layout = render("\xe2\x80\xae", 3, .{}, recording.sink());
    try std.testing.expectEqualStrings("?", recording.bytes[0..recording.len]);
    try expectPosition(0, 1, layout.end);
}

test "tabs always occupy four cells" {
    var recording: Recording = .{};
    const layout = render("a\tb", 3, .{}, recording.sink());
    try std.testing.expectEqualStrings("a    b", recording.bytes[0..recording.len]);
    try expectPosition(0, 6, layout.end);
}

test "word wrapping prefers spaces and falls back inside tokens" {
    var recording: Recording = .{};
    var layout = render("hello world", 11, .{
        .prompt_width = 2,
        .continuation_column = 2,
        .columns = 10,
    }, recording.sink());
    try std.testing.expectEqualStrings("hello /world", recording.bytes[0..recording.len]);
    try expectPosition(1, 7, layout.end);

    recording = .{};
    layout = render("abcdefghijk", 11, .{
        .prompt_width = 2,
        .continuation_column = 2,
        .columns = 10,
    }, recording.sink());
    try std.testing.expectEqualStrings("abcdefg/hijk", recording.bytes[0..recording.len]);
    try expectPosition(1, 6, layout.end);
}

test "boundary spaces drop and cursor resolves after wrap" {
    var recording: Recording = .{};
    var layout = render("abcdefg ij", 10, .{
        .prompt_width = 2,
        .continuation_column = 2,
        .columns = 10,
    }, recording.sink());
    try std.testing.expectEqualStrings("abcdefg/ij", recording.bytes[0..recording.len]);
    try expectPosition(1, 4, layout.end);

    layout = compute("hello world", 6, 2, 10);
    try expectPosition(1, 2, layout.cursor);
}

test "zero and tiny widths are safe" {
    var layout = compute("abc", 3, 0, 0);
    try expectPosition(0, 3, layout.end);
    try std.testing.expectEqual(1, layout.total_rows);

    layout = compute("界a", 4, 0, 1);
    try expectPosition(1, 1, layout.end);
    try std.testing.expectEqual(2, layout.total_rows);

    layout = compute("ab", 2, 9000, 9000);
    try expectPosition(1, 4097, layout.end);
    try std.testing.expectEqual(2, layout.total_rows);
}

test "cursor inside multibyte and malformed sequences resolves deterministically" {
    var layout = compute("éx", 1, 0, 80);
    try expectPosition(0, 0, layout.cursor);
    layout = compute("\xffx", 1, 0, 80);
    try expectPosition(0, 1, layout.cursor);
}
