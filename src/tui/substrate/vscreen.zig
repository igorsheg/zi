const std = @import("std");

pub const Screen = struct {
    pub const width_max = 160;
    pub const height_max = 80;
    pub const cell_count_max = width_max * height_max;

    width: u16,
    height: u16,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cells: [cell_count_max]u8 = [_]u8{' '} ** cell_count_max,

    pub fn init(width: u16, height: u16) Screen {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        std.debug.assert(width <= width_max);
        std.debug.assert(height <= height_max);
        return .{ .width = width, .height = height };
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        var parser: Parser = .{ .screen = self, .bytes = bytes };
        parser.parse();
    }

    pub fn textAt(self: *const Screen, col: u16, row: u16) u8 {
        std.debug.assert(col < self.width);
        std.debug.assert(row < self.height);
        return self.cells[self.index(col, row)];
    }

    pub fn contains(self: *const Screen, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var row: u16 = 0;
        while (row < self.height) : (row += 1) {
            const start = self.index(0, row);
            const line = self.cells[start .. start + self.width];
            if (std.mem.indexOf(u8, line, needle) != null) return true;
        }
        return false;
    }

    fn clear(self: *Screen) void {
        const count: usize = @as(usize, self.width) * self.height;
        @memset(self.cells[0..count], ' ');
        self.cursor_col = 0;
        self.cursor_row = 0;
    }

    fn clearLineFromCursor(self: *Screen) void {
        const start = self.index(self.cursor_col, self.cursor_row);
        const end = self.index(0, self.cursor_row) + self.width;
        @memset(self.cells[start..end], ' ');
    }

    fn put(self: *Screen, byte: u8) void {
        self.cells[self.index(self.cursor_col, self.cursor_row)] = byte;
        if (self.cursor_col + 1 < self.width) {
            self.cursor_col += 1;
        }
    }

    fn moveCursor(self: *Screen, row_one_based: u16, col_one_based: u16) void {
        self.cursor_row = @min(self.height - 1, row_one_based -| 1);
        self.cursor_col = @min(self.width - 1, col_one_based -| 1);
    }

    fn lineFeed(self: *Screen) void {
        if (self.cursor_row + 1 < self.height) self.cursor_row += 1;
    }

    fn index(self: *const Screen, col: u16, row: u16) usize {
        return @as(usize, row) * self.width + col;
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
                else => {},
            }
        }
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
                '?' => {},
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
                'm', 'h', 'l' => return,
                else => return,
            }
        }
    }
};

test "virtual screen applies cursor movement clear and printable text" {
    var screen = Screen.init(10, 3);

    screen.feed("hello\x1b[2;3Hzi\x1b[1;1H!\x1b[2K");

    try std.testing.expectEqual(@as(u8, '!'), screen.textAt(0, 0));
    try std.testing.expect(screen.contains("zi"));
    try std.testing.expect(!screen.contains("hello"));
}
