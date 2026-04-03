const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const keys_mod = @import("../keys.zig");
const grapheme_mod = @import("../grapheme.zig");

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
    prompt: []const u8 = "> ",
    on_submit: ?*const fn (text: []const u8, ctx: ?*anyopaque) void = null,
    on_submit_ctx: ?*anyopaque = null,
    prompt_fg: Color = Color.rgb(100, 100, 100),
    text_fg: Color = Color.default,
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
    }

    pub fn setText(self: *Editor, text: []const u8) void {
        self.buf.items.len = 0;
        self.buf.appendSlice(self.allocator, text) catch return;
        self.cursor_byte = @intCast(text.len);
        self.cursor_col = @intCast(grapheme_mod.strWidth(text));
        self.scroll_x = 0;
    }

    // --- Input handling ---

    pub fn handleInput(self: *Editor, key: Key) bool {
        if (!self.focused) return false;

        switch (key.code) {
            .enter => {
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
                    return true;
                }
                return false;
            },
            .backspace => {
                if (self.cursor_byte == 0) return true;
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
            .left => {
                if (self.cursor_byte == 0) return true;
                const prev = self.prevCodepointBoundary();
                const moved_text = self.buf.items[prev..self.cursor_byte];
                const moved_width: u32 = @intCast(grapheme_mod.strWidth(moved_text));
                self.cursor_byte = prev;
                self.cursor_col -= moved_width;
                return true;
            },
            .right => {
                if (self.cursor_byte >= self.buf.items.len) return true;
                const next = self.nextCodepointBoundary();
                const moved_text = self.buf.items[self.cursor_byte..next];
                const moved_width: u32 = @intCast(grapheme_mod.strWidth(moved_text));
                self.cursor_byte = next;
                self.cursor_col += moved_width;
                return true;
            },
            .home => {
                self.cursor_byte = 0;
                self.cursor_col = 0;
                return true;
            },
            .end => {
                self.cursor_byte = @intCast(self.buf.items.len);
                self.cursor_col = @intCast(grapheme_mod.strWidth(self.buf.items));
                return true;
            },
            .delete => {
                if (self.cursor_byte >= self.buf.items.len) return true;
                const next = self.nextCodepointBoundary();
                const remove_count = next - self.cursor_byte;
                const items = self.buf.items;
                std.mem.copyForwards(u8, items[self.cursor_byte..], items[next..]);
                self.buf.items.len -= remove_count;
                return true;
            },
            else => return false,
        }
    }

    // --- Rendering ---

    pub fn render(self: *Editor, region: Region) void {
        const prompt_width: u32 = @intCast(grapheme_mod.strWidth(self.prompt));
        _ = region.writeStr(0, 0, self.prompt, self.prompt_fg, Color.default, .{});

        if (self.buf.items.len > 0) {
            _ = region.writeStr(prompt_width, 0, self.buf.items, self.text_fg, Color.default, .{});
        }
    }

    pub fn measure(self: *Editor, width: u32) Measurement {
        _ = self;
        _ = width;
        return .{ .min_height = 1, .preferred_height = 1 };
    }

    pub fn cursorState(self: *Editor) ?CursorState {
        if (!self.focused) return null;
        const prompt_width: u32 = @intCast(grapheme_mod.strWidth(self.prompt));
        return .{
            .x = prompt_width + self.cursor_col,
            .y = 0,
            .style = .bar,
        };
    }

    pub fn component(self: *Editor) Component {
        return Component.init(Editor, self);
    }

    // --- Internal helpers ---

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

test "Editor type and submit" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    try std.testing.expect(editor.handleInput(.{ .code = .char, .char = 'h' }));
    try std.testing.expect(editor.handleInput(.{ .code = .char, .char = 'i' }));
    try std.testing.expectEqualStrings("hi", editor.getText());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);
}

test "Editor backspace" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .backspace });
    try std.testing.expectEqualStrings("a", editor.getText());
    try std.testing.expectEqual(@as(u32, 1), editor.cursor_col);
}

test "Editor cursor movement" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .char, .char = 'c' });

    _ = editor.handleInput(.{ .code = .left });
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    _ = editor.handleInput(.{ .code = .home });
    try std.testing.expectEqual(@as(u32, 0), editor.cursor_col);

    _ = editor.handleInput(.{ .code = .end });
    try std.testing.expectEqual(@as(u32, 3), editor.cursor_col);
}

test "Editor clear" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'x' });
    editor.clear();
    try std.testing.expectEqualStrings("", editor.getText());
    try std.testing.expectEqual(@as(u32, 0), editor.cursor_col);
}

test "Editor renders to buffer" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'h' });
    _ = editor.handleInput(.{ .code = .char, .char = 'i' });

    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 20, 1);
    defer buf.deinit();
    editor.render(buf.region());

    try std.testing.expectEqual(@as(u21, '>'), buf.get(0, 0).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), buf.get(1, 0).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), buf.get(2, 0).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), buf.get(3, 0).grapheme.codepoint);
}

test "Editor cursor state includes prompt offset" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 3), cs.x);
    try std.testing.expectEqual(@as(u32, 0), cs.y);
}
