const std = @import("std");
const vaxis = @import("vaxis");

pub const Screen = struct {
    pub const width_max = 160;
    pub const height_max = 80;
    pub const cell_count_max = width_max * height_max;
    pub const raw_tail_size_max = 4096;

    pub const Cursor = struct {
        col: u16,
        row: u16,
    };

    width: u16,
    height: u16,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cursor_visible: bool = true,
    cells: [cell_count_max]u21 = [_]u21{' '} ** cell_count_max,
    cell_widths: [cell_count_max]u2 = [_]u2{1} ** cell_count_max,
    raw_tail: [raw_tail_size_max]u8 = undefined,
    raw_tail_len: usize = 0,

    pub fn init(width: u16, height: u16) Screen {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width <= width_max);
        std.debug.assert(height <= height_max);
        return .{ .width = width, .height = height };
    }

    pub fn resize(self: *Screen, width: u16, height: u16) void {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width <= width_max);
        std.debug.assert(height <= height_max);
        self.width = width;
        self.height = height;
        self.clear();
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        self.appendRawTail(bytes);
        var parser: Parser = .{ .screen = self, .bytes = bytes };
        parser.parse();
    }

    pub fn textAt(self: *const Screen, col: u16, row_index: u16) u21 {
        std.debug.assert(col < self.width);
        std.debug.assert(row_index < self.height);
        return self.cells[self.index(col, row_index)];
    }

    pub fn cursor(self: *const Screen) Cursor {
        return .{
            .col = self.cursor_col,
            .row = self.cursor_row,
        };
    }

    pub fn cursorEquals(self: *const Screen, col: u16, row_index: u16) bool {
        std.debug.assert(col < self.width);
        std.debug.assert(row_index < self.height);
        return self.cursor_col == col and self.cursor_row == row_index;
    }

    pub fn cursorIsVisible(self: *const Screen) bool {
        return self.cursor_visible;
    }

    pub fn rowCell(self: *const Screen, col: u16, row_index: u16) u21 {
        std.debug.assert(col < self.width);
        std.debug.assert(row_index < self.height);
        return self.cells[self.index(col, row_index)];
    }

    pub fn rowContains(self: *const Screen, row_index: u16, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var row_buffer: [width_max * 4]u8 = undefined;
        const bytes = self.copyRowText(row_index, &row_buffer) catch return false;
        return std.mem.indexOf(u8, bytes, needle) != null;
    }

    pub fn rowEqualsTrimmedRight(self: *const Screen, row_index: u16, expected: []const u8) bool {
        var row_buffer: [width_max * 4]u8 = undefined;
        const bytes = self.copyRowText(row_index, &row_buffer) catch return false;
        var end = bytes.len;
        while (end > 0 and bytes[end - 1] == ' ') end -= 1;
        return std.mem.eql(u8, bytes[0..end], expected);
    }

    pub fn contains(self: *const Screen, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var row_index: u16 = 0;
        while (row_index < self.height) : (row_index += 1) {
            if (self.rowContains(row_index, needle)) return true;
        }
        return false;
    }

    pub fn rowRangeContains(self: *const Screen, row_start: u16, row_count: u16, needle: []const u8) bool {
        std.debug.assert(row_start <= self.height);
        std.debug.assert(row_count <= self.height - row_start);
        if (needle.len == 0) return true;

        var offset: u16 = 0;
        while (offset < row_count) : (offset += 1) {
            if (self.rowContains(row_start + offset, needle)) return true;
        }
        return false;
    }

    pub fn rowRangeContainsOrdered(
        self: *const Screen,
        row_start: u16,
        row_count: u16,
        needles: []const []const u8,
    ) bool {
        std.debug.assert(row_start <= self.height);
        std.debug.assert(row_count <= self.height - row_start);

        var needle_index: usize = 0;
        var offset: u16 = 0;
        while (needle_index < needles.len and offset < row_count) {
            const needle = needles[needle_index];
            if (needle.len == 0 or self.rowContains(row_start + offset, needle)) {
                needle_index += 1;
            }
            offset += 1;
        }
        return needle_index == needles.len;
    }

    pub fn countRowsContaining(self: *const Screen, needle: []const u8) usize {
        std.debug.assert(needle.len > 0);
        var count: usize = 0;
        var row_index: u16 = 0;
        while (row_index < self.height) : (row_index += 1) {
            if (self.rowContains(row_index, needle)) count += 1;
        }
        return count;
    }

    pub fn copyText(self: *const Screen, out: []u8) ![]const u8 {
        return self.copyRowRangeText(0, self.height, out);
    }

    pub fn rawTail(self: *const Screen) []const u8 {
        return self.raw_tail[0..self.raw_tail_len];
    }

    pub fn copyRowRangeText(self: *const Screen, row_start: u16, row_count: u16, out: []u8) ![]const u8 {
        std.debug.assert(row_start <= self.height);
        std.debug.assert(row_count <= self.height - row_start);
        const range_size_required = @as(usize, self.width) * 4 * row_count + if (row_count == 0) 0 else row_count - 1;
        if (out.len < range_size_required) return error.BufferTooSmall;

        var written: usize = 0;
        var offset: u16 = 0;
        while (offset < row_count) : (offset += 1) {
            written += try self.encodeRow(row_start + offset, out[written..]);
            if (offset + 1 < row_count) {
                out[written] = '\n';
                written += 1;
            }
        }
        return out[0..written];
    }

    pub fn copyRowText(self: *const Screen, row_index: u16, out: []u8) ![]const u8 {
        std.debug.assert(row_index < self.height);
        const size_required = @as(usize, self.width) * 4;
        if (out.len < size_required) return error.BufferTooSmall;
        return out[0..try self.encodeRow(row_index, out)];
    }

    fn clear(self: *Screen) void {
        const count: usize = @as(usize, self.width) * self.height;
        @memset(self.cells[0..count], ' ');
        @memset(self.cell_widths[0..count], 1);
        self.cursor_col = 0;
        self.cursor_row = 0;
    }

    fn appendRawTail(self: *Screen, bytes: []const u8) void {
        if (bytes.len >= self.raw_tail.len) {
            const start = bytes.len - self.raw_tail.len;
            @memcpy(&self.raw_tail, bytes[start..]);
            self.raw_tail_len = self.raw_tail.len;
            return;
        }
        if (self.raw_tail_len + bytes.len > self.raw_tail.len) {
            const drop_count = self.raw_tail_len + bytes.len - self.raw_tail.len;
            const keep_count = self.raw_tail_len - drop_count;
            @memmove(self.raw_tail[0..keep_count], self.raw_tail[drop_count..self.raw_tail_len]);
            self.raw_tail_len = keep_count;
        }
        @memcpy(self.raw_tail[self.raw_tail_len..][0..bytes.len], bytes);
        self.raw_tail_len += bytes.len;
    }

    fn clearLineFromCursor(self: *Screen) void {
        const start = self.index(self.cursor_col, self.cursor_row);
        const end = self.index(0, self.cursor_row) + self.width;
        self.clearCells(start, end);
    }

    fn put(self: *Screen, codepoint: u21) void {
        const width = self.codepointWidth(codepoint);
        const cell_index = self.index(self.cursor_col, self.cursor_row);
        self.cells[cell_index] = codepoint;
        self.cell_widths[cell_index] = width;

        if (width > 0) self.clearFollowingZeroWidthCells(cell_index);

        const next_col = @min(@as(u16, self.width - 1), self.cursor_col + width);
        self.cursor_col = next_col;
    }

    fn moveCursor(self: *Screen, row_one_based: u16, col_one_based: u16) void {
        self.cursor_row = @min(self.height - 1, row_one_based -| 1);
        self.cursor_col = @min(self.width - 1, col_one_based -| 1);
    }

    fn lineFeed(self: *Screen) void {
        if (self.cursor_row + 1 < self.height) self.cursor_row += 1;
    }

    fn index(self: *const Screen, col: u16, row_index: u16) usize {
        return @as(usize, row_index) * self.width + col;
    }

    fn encodeRow(self: *const Screen, row_index: u16, out: []u8) !usize {
        std.debug.assert(row_index < self.height);
        var written: usize = 0;
        var col: u16 = 0;
        while (col < self.width) : (col += 1) {
            const codepoint = self.cells[self.index(col, row_index)];
            const len = try std.unicode.utf8Encode(codepoint, out[written..]);
            written += len;
        }
        return written;
    }

    fn clearCells(self: *Screen, start: usize, end: usize) void {
        @memset(self.cells[start..end], ' ');
        @memset(self.cell_widths[start..end], 1);
    }

    fn clearFollowingZeroWidthCells(self: *Screen, cell_index: usize) void {
        const row_end = self.index(0, self.cursor_row) + self.width;
        var index_next = cell_index + 1;
        while (index_next < row_end and self.cell_widths[index_next] == 0) : (index_next += 1) {
            self.cells[index_next] = ' ';
            self.cell_widths[index_next] = 1;
        }
    }

    fn codepointWidth(_: *const Screen, codepoint: u21) u2 {
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &encoded) catch return 1;
        const width = vaxis.gwidth.gwidth(encoded[0..len], .unicode);
        return @intCast(@min(width, 2));
    }
};

const Parser = struct {
    screen: *Screen,
    bytes: []const u8,
    index: usize = 0,

    fn parse(self: *Parser) void {
        while (self.index < self.bytes.len) {
            const byte = self.bytes[self.index];
            self.index += 1;
            switch (byte) {
                0x1b => self.parseEscape(),
                '\r' => self.screen.cursor_col = 0,
                '\n' => self.screen.lineFeed(),
                0x08 => {
                    if (self.screen.cursor_col > 0) self.screen.cursor_col -= 1;
                },
                0x20...0x7e => self.screen.put(byte),
                0xc2...0xf4 => self.parseUtf8(byte),
                else => {},
            }
        }
    }

    fn parseUtf8(self: *Parser, first_byte: u8) void {
        const len = std.unicode.utf8ByteSequenceLength(first_byte) catch return;
        if (len == 1) {
            self.screen.put(first_byte);
            return;
        }
        if (self.index + len - 1 > self.bytes.len) return;
        const start = self.index - 1;
        const end = start + len;
        var view = std.unicode.Utf8View.init(self.bytes[start..end]) catch return;
        var iter = view.iterator();
        const codepoint = iter.nextCodepoint() orelse return;
        self.index = end;
        self.screen.put(codepoint);
    }

    fn parseEscape(self: *Parser) void {
        if (self.index >= self.bytes.len) return;
        const byte = self.bytes[self.index];
        self.index += 1;
        switch (byte) {
            '[' => self.parseCsi(),
            'c' => self.screen.clear(),
            else => {},
        }
    }

    fn parseCsi(self: *Parser) void {
        var params: [4]u16 = .{ 0, 0, 0, 0 };
        var param_count: usize = 1;
        var private_mode = false;
        while (self.index < self.bytes.len) {
            const byte = self.bytes[self.index];
            self.index += 1;
            switch (byte) {
                '0'...'9' => {
                    const param_index = @min(param_count - 1, params.len - 1);
                    params[param_index] = params[param_index] * 10 + (byte - '0');
                },
                ';' => {
                    if (param_count < params.len) param_count += 1;
                },
                '?' => private_mode = true,
                'H', 'f' => {
                    const row = if (params[0] == 0) 1 else params[0];
                    const col = if (params[1] == 0) 1 else params[1];
                    self.screen.moveCursor(row, col);
                    return;
                },
                'J' => {
                    if (params[0] == 0 or params[0] == 2) self.screen.clear();
                    return;
                },
                'K' => {
                    self.screen.clearLineFromCursor();
                    return;
                },
                'h' => {
                    if (private_mode and params[0] == 25) self.screen.cursor_visible = true;
                    return;
                },
                'l' => {
                    if (private_mode and params[0] == 25) self.screen.cursor_visible = false;
                    return;
                },
                'm' => return,
                else => return,
            }
        }
    }
};

test "virtual screen applies cursor movement clear and printable text" {
    var screen = Screen.init(10, 3);

    screen.feed("hello\x1b[2;3Hab\x1b[1;1H!\x1b[2K");

    try std.testing.expectEqual(@as(u21, '!'), screen.textAt(0, 0));
    try std.testing.expect(screen.rowContains(1, "ab"));
    try std.testing.expect(screen.contains("ab"));
    try std.testing.expect(!screen.contains("hello"));
    try std.testing.expect(screen.cursorEquals(1, 0));
}

test "virtual screen tracks cursor visibility mode" {
    var screen = Screen.init(10, 3);

    screen.feed("\x1b[?25l");
    try std.testing.expect(!screen.cursorIsVisible());

    screen.feed("\x1b[?25h");
    try std.testing.expect(screen.cursorIsVisible());
}

test "virtual screen resize is bounded and clears stale cells" {
    var screen = Screen.init(10, 3);

    screen.feed("hello");
    screen.resize(6, 2);

    try std.testing.expectEqual(@as(u16, 6), screen.width);
    try std.testing.expectEqual(@as(u16, 2), screen.height);
    var row_buffer: [Screen.width_max * 4]u8 = undefined;
    try std.testing.expectEqualStrings("      ", try screen.copyRowText(0, &row_buffer));
    try std.testing.expect(screen.cursorEquals(0, 0));
}

test "virtual screen decodes utf8 printable codepoints into one cell" {
    var screen = Screen.init(5, 2);

    screen.feed("aé");

    try std.testing.expectEqual(@as(u21, 'a'), screen.rowCell(0, 0));
    try std.testing.expectEqual(@as(u21, 'é'), screen.rowCell(1, 0));
    try std.testing.expect(screen.cursorEquals(2, 0));

    var row_buffer: [Screen.width_max * 4]u8 = undefined;
    try std.testing.expectEqualStrings("aé   ", try screen.copyRowText(0, &row_buffer));
    try std.testing.expect(screen.rowContains(0, "aé"));
}

test "virtual screen clears trailing zero width cells when base cell is overwritten" {
    var screen = Screen.init(5, 2);

    screen.feed("ae\u{0301}");
    try std.testing.expect(screen.cursorEquals(2, 0));
    try std.testing.expect(screen.rowContains(0, "e\u{0301}"));

    screen.feed("\x1b[1;2H ");

    var row_buffer: [Screen.width_max * 4]u8 = undefined;
    try std.testing.expectEqualStrings("a    ", try screen.copyRowText(0, &row_buffer));
    try std.testing.expect(!screen.rowContains(0, "\u{0301}"));
}

test "virtual screen keeps bounded raw byte tail for debugging" {
    var screen = Screen.init(5, 2);

    screen.feed("abc");
    try std.testing.expectEqualStrings("abc", screen.rawTail());

    var bytes: [Screen.raw_tail_size_max + 4]u8 = undefined;
    @memset(&bytes, 'x');
    bytes[bytes.len - 1] = 'z';
    screen.feed(&bytes);

    try std.testing.expectEqual(@as(usize, Screen.raw_tail_size_max), screen.rawTail().len);
    try std.testing.expectEqual(@as(u8, 'z'), screen.rawTail()[screen.rawTail().len - 1]);
}

test "virtual screen searches bounded row ranges" {
    var screen = Screen.init(5, 4);

    screen.feed("top\x1b[2;1Hmid\x1b[4;1Hbot");

    try std.testing.expect(screen.rowRangeContains(1, 2, "mid"));
    try std.testing.expect(!screen.rowRangeContains(1, 2, "top"));
    try std.testing.expect(!screen.rowRangeContains(1, 2, "bot"));
    try std.testing.expect(screen.rowRangeContainsOrdered(0, 4, &.{ "top", "mid", "bot" }));
    try std.testing.expect(!screen.rowRangeContainsOrdered(0, 4, &.{ "mid", "top" }));

    var out: [Screen.width_max * 4 * 2 + 1]u8 = undefined;
    try std.testing.expectEqualStrings(
        "mid  \n     ",
        try screen.copyRowRangeText(1, 2, &out),
    );
}

test "virtual screen exposes bounded row and snapshot assertions" {
    var screen = Screen.init(5, 2);

    screen.feed("abc\x1b[2;1Habc");

    try std.testing.expectEqual(@as(usize, 2), screen.countRowsContaining("abc"));
    var row_buffer: [Screen.width_max * 4]u8 = undefined;
    try std.testing.expectEqualStrings("abc  ", try screen.copyRowText(0, &row_buffer));
    try std.testing.expect(screen.rowEqualsTrimmedRight(0, "abc"));

    var out: [Screen.width_max * 4 * 2 + 1]u8 = undefined;
    try std.testing.expectEqualStrings(
        "abc  \nabc  ",
        try screen.copyText(&out),
    );
}
