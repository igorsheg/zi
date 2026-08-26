const std = @import("std");

/// Layout is deliberately bounded so untrusted terminal reports cannot cause large
/// coordinates or arithmetic overflow. A zero column count disables soft wrapping.
pub const max_terminal_columns: usize = 4096;
pub const tab_width: usize = 4;
const pending_capacity = 256;
const substitute = "?";
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

const Interval = struct { first: u21, last: u21 };

// Derived from the conventional wcwidth combining table. These cover combining
// characters used by modern terminals without depending on a process locale.
const combining = [_]Interval{
    .{ .first = 0x0300, .last = 0x036f },   .{ .first = 0x0483, .last = 0x0489 },
    .{ .first = 0x0591, .last = 0x05bd },   .{ .first = 0x05bf, .last = 0x05bf },
    .{ .first = 0x05c1, .last = 0x05c2 },   .{ .first = 0x05c4, .last = 0x05c5 },
    .{ .first = 0x0610, .last = 0x061a },   .{ .first = 0x064b, .last = 0x065f },
    .{ .first = 0x0670, .last = 0x0670 },   .{ .first = 0x06d6, .last = 0x06ed },
    .{ .first = 0x0711, .last = 0x0711 },   .{ .first = 0x0730, .last = 0x074a },
    .{ .first = 0x07a6, .last = 0x07b0 },   .{ .first = 0x07eb, .last = 0x07f3 },
    .{ .first = 0x0816, .last = 0x082d },   .{ .first = 0x0859, .last = 0x085b },
    .{ .first = 0x08d3, .last = 0x0902 },   .{ .first = 0x093a, .last = 0x093c },
    .{ .first = 0x0941, .last = 0x0948 },   .{ .first = 0x094d, .last = 0x094d },
    .{ .first = 0x0951, .last = 0x0957 },   .{ .first = 0x0962, .last = 0x0963 },
    .{ .first = 0x0981, .last = 0x0981 },   .{ .first = 0x09bc, .last = 0x09bc },
    .{ .first = 0x09c1, .last = 0x09c4 },   .{ .first = 0x09cd, .last = 0x09cd },
    .{ .first = 0x0a01, .last = 0x0a02 },   .{ .first = 0x0a3c, .last = 0x0a3c },
    .{ .first = 0x0a41, .last = 0x0a51 },   .{ .first = 0x0a70, .last = 0x0a71 },
    .{ .first = 0x0abc, .last = 0x0abc },   .{ .first = 0x0ac1, .last = 0x0ac8 },
    .{ .first = 0x0acd, .last = 0x0acd },   .{ .first = 0x0b01, .last = 0x0b01 },
    .{ .first = 0x0b3c, .last = 0x0b3c },   .{ .first = 0x0b3f, .last = 0x0b3f },
    .{ .first = 0x0b41, .last = 0x0b4d },   .{ .first = 0x0c00, .last = 0x0c00 },
    .{ .first = 0x0c3e, .last = 0x0c40 },   .{ .first = 0x0c46, .last = 0x0c56 },
    .{ .first = 0x0d41, .last = 0x0d4d },   .{ .first = 0x0dca, .last = 0x0dca },
    .{ .first = 0x0dd2, .last = 0x0dd6 },   .{ .first = 0x0e31, .last = 0x0e31 },
    .{ .first = 0x0e34, .last = 0x0e3a },   .{ .first = 0x0e47, .last = 0x0e4e },
    .{ .first = 0x0eb1, .last = 0x0eb1 },   .{ .first = 0x0eb4, .last = 0x0ecd },
    .{ .first = 0x0f18, .last = 0x0f19 },   .{ .first = 0x0f35, .last = 0x0f39 },
    .{ .first = 0x0f71, .last = 0x0f84 },   .{ .first = 0x0f86, .last = 0x0f87 },
    .{ .first = 0x0f8d, .last = 0x0fbc },   .{ .first = 0x102d, .last = 0x1030 },
    .{ .first = 0x1032, .last = 0x1037 },   .{ .first = 0x1039, .last = 0x103a },
    .{ .first = 0x1058, .last = 0x1059 },   .{ .first = 0x135d, .last = 0x135f },
    .{ .first = 0x1712, .last = 0x1714 },   .{ .first = 0x1732, .last = 0x1734 },
    .{ .first = 0x1752, .last = 0x1753 },   .{ .first = 0x1772, .last = 0x1773 },
    .{ .first = 0x17b4, .last = 0x17d3 },   .{ .first = 0x180b, .last = 0x180d },
    .{ .first = 0x1885, .last = 0x1886 },   .{ .first = 0x18a9, .last = 0x18a9 },
    .{ .first = 0x1ab0, .last = 0x1aff },   .{ .first = 0x1dc0, .last = 0x1dff },
    .{ .first = 0x20d0, .last = 0x20ff },   .{ .first = 0x2cef, .last = 0x2cf1 },
    .{ .first = 0x2de0, .last = 0x2dff },   .{ .first = 0x302a, .last = 0x302f },
    .{ .first = 0x3099, .last = 0x309a },   .{ .first = 0xa66f, .last = 0xa672 },
    .{ .first = 0xa674, .last = 0xa67d },   .{ .first = 0xa69e, .last = 0xa69f },
    .{ .first = 0xa6f0, .last = 0xa6f1 },   .{ .first = 0xa802, .last = 0xa802 },
    .{ .first = 0xa806, .last = 0xa806 },   .{ .first = 0xa80b, .last = 0xa80b },
    .{ .first = 0xa825, .last = 0xa826 },   .{ .first = 0xa8c4, .last = 0xa8c5 },
    .{ .first = 0xa8e0, .last = 0xa8f1 },   .{ .first = 0xfe00, .last = 0xfe0f },
    .{ .first = 0xfe20, .last = 0xfe2f },   .{ .first = 0x101fd, .last = 0x101fd },
    .{ .first = 0x1d167, .last = 0x1d182 }, .{ .first = 0x1d185, .last = 0x1d18b },
    .{ .first = 0x1d1aa, .last = 0x1d1ad }, .{ .first = 0x1e000, .last = 0x1e02a },
    .{ .first = 0x1e8d0, .last = 0x1e8d6 }, .{ .first = 0x1e944, .last = 0x1e94a },
    .{ .first = 0xe0100, .last = 0xe01ef },
};

fn inIntervals(codepoint: u21, intervals: []const Interval) bool {
    for (intervals) |interval| {
        if (codepoint < interval.first) return false;
        if (codepoint <= interval.last) return true;
    }
    return false;
}

fn isWide(codepoint: u21) bool {
    return codepoint >= 0x1100 and (codepoint <= 0x115f or codepoint == 0x2329 or codepoint == 0x232a or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf and codepoint != 0x303f) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd));
}

fn requiresSubstitution(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f) or
        codepoint == 0x00ad or codepoint == 0x034f or codepoint == 0x061c or
        codepoint == 0x115f or codepoint == 0x1160 or codepoint == 0x180e or
        (codepoint >= 0x200b and codepoint <= 0x200f) or
        (codepoint >= 0x2028 and codepoint <= 0x202e) or
        (codepoint >= 0x2060 and codepoint <= 0x206f) or codepoint == 0x3164 or
        codepoint == 0xfeff or codepoint == 0xffa0 or
        (codepoint >= 0xfff9 and codepoint <= 0xfffb) or
        (codepoint >= 0xe0000 and codepoint <= 0xe007f);
}

fn codepointWidth(codepoint: u21) ?usize {
    if (requiresSubstitution(codepoint)) return null;
    if (inIntervals(codepoint, &combining)) return 0;
    return if (isWide(codepoint)) 2 else 1;
}

fn decodeGlyph(input: []const u8, offset: usize) DecodedGlyph {
    const byte = input[offset];
    if (byte == '\t') return .{
        .bytes = tab_spaces,
        .width = tab_width,
        .offset = offset,
        .consumed = 1,
        .is_space = false,
    };
    if (byte < 0x20 or byte == 0x7f) return .{
        .bytes = substitute,
        .width = 1,
        .offset = offset,
        .consumed = 1,
        .is_space = false,
    };

    const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch return substitutedGlyph(offset);
    if (sequence_len > input.len - offset) return substitutedGlyph(offset);
    const bytes = input[offset..][0..sequence_len];
    if (!std.unicode.utf8ValidateSlice(bytes)) return substitutedGlyph(offset);
    const codepoint: u21 = switch (sequence_len) {
        1 => byte,
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return substitutedGlyph(offset),
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return substitutedGlyph(offset),
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return substitutedGlyph(offset),
        else => unreachable,
    };
    const width = codepointWidth(codepoint) orelse return .{
        .bytes = substitute,
        .width = 1,
        .offset = offset,
        .consumed = sequence_len,
        .is_space = false,
    };
    return .{
        .bytes = bytes,
        .width = width,
        .offset = offset,
        .consumed = sequence_len,
        .is_space = sequence_len == 1 and byte == ' ',
    };
}

fn substitutedGlyph(offset: usize) DecodedGlyph {
    return .{
        .bytes = substitute,
        .width = 1,
        .offset = offset,
        .consumed = 1,
        .is_space = false,
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
