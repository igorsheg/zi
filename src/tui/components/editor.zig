const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const keys_mod = @import("../keys.zig");
const grapheme_mod = @import("../grapheme.zig");
const box_chrome = @import("../box_chrome.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Key = keys_mod.Key;

pub const Editor = struct {
    buf: std.ArrayList(u8),
    cursor_byte: u32 = 0,
    cursor_col: u32 = 0,
    scroll_x: u32 = 0,
    scroll_y: u32 = 0,
    max_visible_lines: u32 = 10,
    prompt: []const u8 = "> ",
    on_submit: ?*const fn (text: []const u8, ctx: ?*anyopaque) void = null,
    on_submit_ctx: ?*anyopaque = null,
    prompt_fg: Color = Color.rgb(100, 100, 100),
    text_fg: Color = Color.default,
    border_color: Color = Color.rgb(0x50, 0x50, 0x50),
    status_left: []const u8 = "",
    status_right: []const u8 = "",
    allocator: std.mem.Allocator,
    focused: bool = true,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{
            .buf = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.allocator);
    }

    pub fn getText(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn clear(self: *Editor) void {
        self.buf.items.len = 0;
        self.cursor_byte = 0;
        self.cursor_col = 0;
        self.scroll_x = 0;
        self.scroll_y = 0;
    }

    pub fn setText(self: *Editor, text: []const u8) void {
        self.buf.items.len = 0;
        self.buf.appendSlice(self.allocator, text) catch return;
        self.cursor_byte = @intCast(text.len);
        // cursor_col is display col within the last line
        const last_line_start = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |pos| pos + 1 else 0;
        self.cursor_col = @intCast(grapheme_mod.strWidth(text[last_line_start..]));
        self.scroll_x = 0;
        self.ensureCursorVisible();
    }

    pub fn insertText(self: *Editor, text: []const u8) void {
        self.buf.insertSlice(self.allocator, self.cursor_byte, text) catch return;
        // advance cursor through inserted text, tracking col on last line
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\n') {
                self.cursor_col = 0;
                i += 1;
            } else {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const end = @min(i + cp_len, text.len);
                const cp = std.unicode.utf8Decode(text[i..end]) catch '_';
                self.cursor_col += @as(u32, grapheme_mod.charWidth(cp));
                i = end;
            }
        }
        self.cursor_byte += @intCast(text.len);
        self.ensureCursorVisible();
    }

    // --- Input handling ---

    pub fn handleInput(self: *Editor, key: Key) bool {
        if (!self.focused) return false;

        switch (key.code) {
            .enter => {
                if (key.shift) {
                    self.insertNewline();
                    return true;
                }
                // backslash-enter: delete backslash, insert newline
                if (self.cursor_byte > 0 and self.buf.items[self.cursor_byte - 1] == '\\') {
                    // remove the backslash
                    const prev = self.cursor_byte - 1;
                    const items = self.buf.items;
                    std.mem.copyForwards(u8, items[prev..], items[self.cursor_byte..]);
                    self.buf.items.len -= 1;
                    self.cursor_byte = prev;
                    self.cursor_col -= 1; // backslash is 1 col wide
                    self.insertNewline();
                    return true;
                }
                if (self.on_submit) |cb| {
                    cb(self.buf.items, self.on_submit_ctx);
                }
                return true;
            },
            .char => {
                if (key.ctrl) return false;
                if (key.char) |cp| {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return false;
                    self.buf.insertSlice(self.allocator, self.cursor_byte, utf8_buf[0..len]) catch return false;
                    self.cursor_byte += @intCast(len);
                    self.cursor_col += @as(u32, grapheme_mod.charWidth(cp));
                    self.ensureCursorVisible();
                    return true;
                }
                return false;
            },
            .backspace => {
                if (self.cursor_byte == 0) return true;
                // newline: merge lines
                if (self.buf.items[self.cursor_byte - 1] == '\n') {
                    const prev = self.cursor_byte - 1;
                    // cursor_col becomes display width of the previous line (now end of merged line)
                    const prev_line_start = self.lineStartByIndex(self.cursorLine() -| 1);
                    self.cursor_col = self.displayColAtByte(prev);
                    _ = prev_line_start;
                    const items = self.buf.items;
                    std.mem.copyForwards(u8, items[prev..], items[self.cursor_byte..]);
                    self.buf.items.len -= 1;
                    self.cursor_byte = prev;
                    self.ensureCursorVisible();
                    return true;
                }
                const prev = self.prevCodepointBoundary();
                const removed_bytes = self.cursor_byte - prev;
                const removed_text = self.buf.items[prev..self.cursor_byte];
                const removed_width: u32 = @intCast(grapheme_mod.strWidth(removed_text));
                const items = self.buf.items;
                std.mem.copyForwards(u8, items[prev..], items[self.cursor_byte..]);
                self.buf.items.len -= removed_bytes;
                self.cursor_byte = prev;
                self.cursor_col -= removed_width;
                return true;
            },
            .delete => {
                if (self.cursor_byte >= self.buf.items.len) return true;
                // newline at cursor: merge with next line
                if (self.buf.items[self.cursor_byte] == '\n') {
                    const items = self.buf.items;
                    const next = self.cursor_byte + 1;
                    std.mem.copyForwards(u8, items[self.cursor_byte..], items[next..]);
                    self.buf.items.len -= 1;
                    return true;
                }
                const next = self.nextCodepointBoundary();
                const remove_count = next - self.cursor_byte;
                const items = self.buf.items;
                std.mem.copyForwards(u8, items[self.cursor_byte..], items[next..]);
                self.buf.items.len -= remove_count;
                return true;
            },
            .left => {
                if (self.cursor_byte == 0) return true;
                if (self.buf.items[self.cursor_byte - 1] == '\n') {
                    // move to end of previous line
                    self.cursor_byte -= 1;
                    self.cursor_col = self.displayColAtByte(self.cursor_byte);
                    self.ensureCursorVisible();
                    return true;
                }
                const prev = self.prevCodepointBoundary();
                const moved_text = self.buf.items[prev..self.cursor_byte];
                const moved_width: u32 = @intCast(grapheme_mod.strWidth(moved_text));
                self.cursor_byte = prev;
                self.cursor_col -= moved_width;
                return true;
            },
            .right => {
                if (self.cursor_byte >= self.buf.items.len) return true;
                if (self.buf.items[self.cursor_byte] == '\n') {
                    // move to start of next line
                    self.cursor_byte += 1;
                    self.cursor_col = 0;
                    self.ensureCursorVisible();
                    return true;
                }
                const next = self.nextCodepointBoundary();
                const moved_text = self.buf.items[self.cursor_byte..next];
                const moved_width: u32 = @intCast(grapheme_mod.strWidth(moved_text));
                self.cursor_byte = next;
                self.cursor_col += moved_width;
                return true;
            },
            .up => {
                const cur_line = self.cursorLine();
                if (cur_line == 0) return true;
                const target_col = self.cursor_col;
                const prev_line_start = self.lineStartByIndex(cur_line - 1);
                const prev_line_end = self.currentLineStart() - 1; // the \n before current line
                self.cursor_byte = self.byteAtDisplayCol(prev_line_start, prev_line_end, target_col);
                self.cursor_col = self.displayColAtByte(self.cursor_byte);
                self.ensureCursorVisible();
                return true;
            },
            .down => {
                const cur_line = self.cursorLine();
                if (cur_line + 1 >= self.lineCount()) return true;
                const target_col = self.cursor_col;
                const next_line_start = self.lineStartByIndex(cur_line + 1);
                const next_line_end = self.lineEndByStart(next_line_start);
                self.cursor_byte = self.byteAtDisplayCol(next_line_start, next_line_end, target_col);
                self.cursor_col = self.displayColAtByte(self.cursor_byte);
                self.ensureCursorVisible();
                return true;
            },
            .home => {
                self.cursor_byte = self.currentLineStart();
                self.cursor_col = 0;
                return true;
            },
            .end => {
                self.cursor_byte = self.currentLineEnd();
                self.cursor_col = self.displayColAtByte(self.cursor_byte);
                return true;
            },
            else => return false,
        }
    }

    // --- Rendering ---

    pub fn render(self: *Editor, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h < 3) return;

        // Top border with rounded corners and inline status
        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            _ = box_chrome.drawClosedTop(region, 0,
                if (self.status_left.len > 0) self.status_left else null,
                if (self.status_right.len > 0) self.status_right else null,
                style);
        }
        // Bottom border with rounded corners
        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            _ = box_chrome.drawClosedBottom(region, h - 1, style);
        }

        // Content between borders
        const content = region.sub(0, 1, w, h - 2);
        const prompt_width: u32 = @intCast(grapheme_mod.strWidth(self.prompt));
        const continuation = "  ";
        const items = self.buf.items;

        // Draw left border │ on all content rows
        {
            const chrome_style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            var row: u32 = 0;
            while (row < content.height) : (row += 1) {
                _ = box_chrome.drawClosedContentPrefix(content, row, chrome_style);
            }
        }

        var line_idx: u32 = 0;
        var line_start: u32 = 0;
        var visible_row: u32 = 0;

        while (visible_row < content.height) {
            var line_end: u32 = line_start;
            while (line_end < items.len and items[line_end] != '\n') : (line_end += 1) {}

            if (line_idx >= self.scroll_y) {
                const line_text = items[line_start..line_end];
                if (line_idx == 0) {
                    _ = content.writeStr(1, visible_row, self.prompt, self.prompt_fg, Color.default, .{});
                } else {
                    _ = content.writeStr(1, visible_row, continuation, self.prompt_fg, Color.default, .{});
                }

                if (line_text.len > 0) {
                    _ = content.writeStr(prompt_width + 1, visible_row, line_text, self.text_fg, Color.default, .{});
                }
                visible_row += 1;
            }

            line_idx += 1;
            if (line_end >= items.len) break;
            line_start = line_end + 1;
        }
    }

    pub fn measure(self: *Editor, width: u32) Measurement {
        _ = width;
        const lc = self.lineCount();
        return .{
            .min_height = 3,
            .preferred_height = @min(lc, self.max_visible_lines) + 2,
        };
    }

    pub fn cursorState(self: *Editor) ?CursorState {
        if (!self.focused) return null;
        const prompt_width: u32 = @intCast(grapheme_mod.strWidth(self.prompt));
        const cur_line = self.cursorLine();
        if (cur_line < self.scroll_y) return null;
        const visual_y = cur_line - self.scroll_y;
        return .{
            .x = prompt_width + self.cursor_col + 1,
            .y = visual_y + 1,
            .style = .bar,
        };
    }

    pub fn setFocused(self: *Editor, focused: bool) void {
        self.focused = focused;
    }

    pub fn component(self: *Editor) Component {
        return Component.init(Editor, self);
    }

    // --- Internal helpers ---

    fn insertNewline(self: *Editor) void {
        self.buf.insertSlice(self.allocator, self.cursor_byte, "\n") catch return;
        self.cursor_byte += 1;
        self.cursor_col = 0;
        self.ensureCursorVisible();
    }

    fn currentLineStart(self: *const Editor) u32 {
        if (self.cursor_byte == 0) return 0;
        var i = self.cursor_byte - 1;
        while (i > 0 and self.buf.items[i] != '\n') : (i -= 1) {}
        if (self.buf.items[i] == '\n') return i + 1;
        return 0;
    }

    fn currentLineEnd(self: *const Editor) u32 {
        var i = self.cursor_byte;
        while (i < self.buf.items.len and self.buf.items[i] != '\n') : (i += 1) {}
        return @intCast(i);
    }

    fn cursorLine(self: *const Editor) u32 {
        var count: u32 = 0;
        for (self.buf.items[0..self.cursor_byte]) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    fn lineCount(self: *const Editor) u32 {
        if (self.buf.items.len == 0) return 1;
        var count: u32 = 1;
        for (self.buf.items) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    fn lineStartByIndex(self: *const Editor, n: u32) u32 {
        if (n == 0) return 0;
        var count: u32 = 0;
        for (self.buf.items, 0..) |b, i| {
            if (b == '\n') {
                count += 1;
                if (count == n) return @intCast(i + 1);
            }
        }
        return @intCast(self.buf.items.len);
    }

    fn lineEndByStart(self: *const Editor, start: u32) u32 {
        var i = start;
        while (i < self.buf.items.len and self.buf.items[i] != '\n') : (i += 1) {}
        return i;
    }

    fn displayColAtByte(self: *const Editor, byte: u32) u32 {
        // find start of the line containing `byte`
        var line_start: u32 = 0;
        if (byte > 0) {
            var i: u32 = byte - 1;
            while (i > 0 and self.buf.items[i] != '\n') : (i -= 1) {}
            if (i < byte and self.buf.items[i] == '\n') {
                line_start = i + 1;
            }
        }
        return @intCast(grapheme_mod.strWidth(self.buf.items[line_start..byte]));
    }

    fn byteAtDisplayCol(self: *const Editor, line_start: u32, line_end: u32, target_col: u32) u32 {
        var col: u32 = 0;
        var i: u32 = line_start;
        while (i < line_end) {
            const cp_len: u32 = @intCast(std.unicode.utf8ByteSequenceLength(self.buf.items[i]) catch 1);
            const end = @min(i + cp_len, line_end);
            const cp = std.unicode.utf8Decode(self.buf.items[i..end]) catch '_';
            const w: u32 = @as(u32, grapheme_mod.charWidth(cp));
            if (col + w > target_col) break;
            col += w;
            i = end;
        }
        return i;
    }

    fn ensureCursorVisible(self: *Editor) void {
        const cur_line = self.cursorLine();
        if (cur_line < self.scroll_y) {
            self.scroll_y = cur_line;
        } else if (cur_line >= self.scroll_y + self.max_visible_lines) {
            self.scroll_y = cur_line - self.max_visible_lines + 1;
        }
    }

    fn prevCodepointBoundary(self: *const Editor) u32 {
        if (self.cursor_byte == 0) return 0;
        var i = self.cursor_byte - 1;
        while (i > 0 and (self.buf.items[i] & 0xC0) == 0x80) : (i -= 1) {}
        return i;
    }

    fn nextCodepointBoundary(self: *const Editor) u32 {
        if (self.cursor_byte >= self.buf.items.len) return @intCast(self.buf.items.len);
        var i = self.cursor_byte + 1;
        while (i < self.buf.items.len and (self.buf.items[i] & 0xC0) == 0x80) : (i += 1) {}
        return @intCast(i);
    }
};


// --- Tests ---

test "Editor insert, cursor tracking, and submit" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'h' });
    _ = editor.handleInput(.{ .code = .char, .char = 'i' });
    try std.testing.expectEqualStrings("hi", editor.getText());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    // Cursor state includes prompt offset
    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 5), cs.x); // "> " (2) + cursor_col (2)
}

test "Editor backspace, delete, and navigation" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .char, .char = 'c' });
    // Backspace
    _ = editor.handleInput(.{ .code = .backspace });
    try std.testing.expectEqualStrings("ab", editor.getText());
    // Navigation
    _ = editor.handleInput(.{ .code = .home });
    try std.testing.expectEqual(@as(u32, 0), editor.cursor_col);
    _ = editor.handleInput(.{ .code = .end });
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);
    // Clear
    editor.clear();
    try std.testing.expectEqualStrings("", editor.getText());
}

test "Editor renders prompt and text to buffer" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'x' });
    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 20, 3);
    defer buf.deinit();
    editor.render(buf.region());
    try std.testing.expectEqual(@as(u21, 0x256D), buf.get(0, 0).grapheme.codepoint); // top border
    try std.testing.expectEqual(@as(u21, '>'), buf.get(1, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'x'), buf.get(3, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 0x2570), buf.get(0, 2).grapheme.codepoint); // bottom border
}


test "editor render after backspace clears deleted char from buffer" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 20, 3);
    defer buf.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .char, .char = 'c' });

    // Frame 1: render "> abc"
    editor.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'c'), buf.get(5, 1).grapheme.codepoint);

    // Backspace removes 'c'
    _ = editor.handleInput(.{ .code = .backspace });

    // Frame 2: clear buffer (simulates renderer.begin()), re-render
    buf.clear();
    editor.render(buf.region());

    // Position 4 must be blank, not ghost 'c'
    try std.testing.expectEqual(@as(u21, 'b'), buf.get(4, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), buf.get(5, 1).grapheme.codepoint);

    // Cursor should be at prompt_width(2) + cursor_col(2) = 4, y=1 for border
    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 5), cs.x);
    try std.testing.expectEqual(@as(u32, 1), cs.y);
}

test "Editor handles newline insertion and cross-line backspace" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    // Type "ab", shift+enter for newline, type "cd"
    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .enter, .shift = true });
    _ = editor.handleInput(.{ .code = .char, .char = 'c' });
    _ = editor.handleInput(.{ .code = .char, .char = 'd' });

    try std.testing.expectEqualStrings("ab\ncd", editor.getText());
    try std.testing.expectEqual(@as(u32, 1), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    // Backslash-enter also inserts newline
    editor.clear();
    _ = editor.handleInput(.{ .code = .char, .char = 'x' });
    _ = editor.handleInput(.{ .code = .char, .char = '\\' });
    _ = editor.handleInput(.{ .code = .enter });
    _ = editor.handleInput(.{ .code = .char, .char = 'y' });
    try std.testing.expectEqualStrings("x\ny", editor.getText());

    // Backspace at line start merges lines
    // cursor is after 'y' on line 1 — move home first
    _ = editor.handleInput(.{ .code = .home });
    try std.testing.expectEqual(@as(u32, 0), editor.cursor_col);
    _ = editor.handleInput(.{ .code = .backspace });
    try std.testing.expectEqualStrings("xy", editor.getText());
    try std.testing.expectEqual(@as(u32, 1), editor.cursor_col); // after 'x'
}

test "Editor up/down navigation moves between lines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    // Build "abc\nde\nfghij" via insertText
    editor.insertText("abc\nde\nfghij");
    try std.testing.expectEqualStrings("abc\nde\nfghij", editor.getText());
    try std.testing.expectEqual(@as(u32, 2), editor.cursorLine()); // on line 2
    try std.testing.expectEqual(@as(u32, 5), editor.cursor_col); // after "fghij"

    // Up to line 1 — col clamps to 2 (line "de" is 2 wide)
    _ = editor.handleInput(.{ .code = .up });
    try std.testing.expectEqual(@as(u32, 1), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    // Up to line 0 — col stays 2 (line "abc" has room)
    _ = editor.handleInput(.{ .code = .up });
    try std.testing.expectEqual(@as(u32, 0), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    // Down back to line 1
    _ = editor.handleInput(.{ .code = .down });
    try std.testing.expectEqual(@as(u32, 1), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    // Down to line 2 — col stays 2
    _ = editor.handleInput(.{ .code = .down });
    try std.testing.expectEqual(@as(u32, 2), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);
}
