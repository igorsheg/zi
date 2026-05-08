const std = @import("std");
const cell_mod = @import("../cell.zig");
const component_mod = @import("view.zig");
const surface_mod = @import("surface.zig");
const keys_mod = @import("../terminal/keys.zig");
const grapheme_mod = @import("../grapheme.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const edit_core = @import("../edit/root.zig");

const Color = cell_mod.Color;
const CursorState = component_mod.CursorState;
const Measurement = component_mod.Measurement;
const Component = component_mod.Component;
const Region = surface_mod.Region;
const Key = keys_mod.Key;
const Theme = theme_mod.Theme;
const EditBuffer = edit_core.EditBuffer;

/// OpenTUI-style single-line input renderable over zi's shared editable text core.
///
/// TextInput is the single-line policy/rendering layer. The actual UTF-8 text
/// storage, cursor movement, grapheme-aware deletion, and line metrics live in
/// the same buffer used by the multiline composer editor.
pub const TextInput = struct {
    allocator: std.mem.Allocator,
    theme: *const Theme,
    buffer: EditBuffer,
    placeholder: ?[]const u8 = null,
    focused: bool = false,
    max_bytes: usize = 4096,
    scroll_byte: u32 = 0,
    last_committed: std.ArrayListUnmanaged(u8) = .empty,
    prompt: []const u8 = "› ",

    pub const Event = enum {
        none,
        consumed,
        input,
        submit,
    };

    pub fn init(allocator: std.mem.Allocator, theme: *const Theme) TextInput {
        return .{
            .allocator = allocator,
            .theme = theme,
            .buffer = EditBuffer.init(allocator, .wcwidth),
        };
    }

    pub fn deinit(self: *TextInput) void {
        self.buffer.deinit();
        self.last_committed.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setValue(self: *TextInput, new_value: []const u8) !void {
        var sanitized: std.ArrayListUnmanaged(u8) = .empty;
        defer sanitized.deinit(self.allocator);
        try appendSingleLineBounded(self.allocator, &sanitized, new_value, self.max_bytes);
        self.buffer.setText(sanitized.items);
        self.scroll_byte = 0;
    }

    pub fn text(self: *const TextInput) []const u8 {
        return self.buffer.text();
    }

    pub fn cursorByte(self: *const TextInput) u32 {
        return self.buffer.cursorByte();
    }

    pub fn focus(self: *TextInput) !void {
        self.focused = true;
        try self.commitBaseline();
    }

    pub fn blur(self: *TextInput) !bool {
        self.focused = false;
        if (!std.mem.eql(u8, self.text(), self.last_committed.items)) {
            try self.commitBaseline();
            return true;
        }
        return false;
    }

    pub fn setFocused(self: *TextInput, focused: bool) void {
        if (focused) {
            self.focused = true;
            self.commitBaseline() catch {};
        } else {
            _ = self.blur() catch {};
        }
    }

    pub fn handleInput(self: *TextInput, key: Key) bool {
        return self.handleKey(key) != .none;
    }

    pub fn handleKey(self: *TextInput, key: Key) Event {
        switch (key.code) {
            .char => {
                if (key.ctrl) {
                    if (key.char) |cp| switch (cp) {
                        'a' => return self.moveHome(),
                        'e' => return self.moveEnd(),
                        'u' => return self.deleteToStart(),
                        'k' => return self.deleteToEnd(),
                        'w' => return self.deleteWordBackward(),
                        else => return .none,
                    };
                    return .none;
                }
                if (key.alt) return .none;
                const cp = key.char orelse return .none;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return .none;
                return self.insertText(buf[0..len]);
            },
            .backspace => return self.deleteBackward(),
            .delete => return self.deleteForward(),
            .left => return self.moveLeft(),
            .right => return self.moveRight(),
            .home => return self.moveHome(),
            .end => return self.moveEnd(),
            .enter => return self.submit(),
            else => return .none,
        }
    }

    pub fn handlePaste(self: *TextInput, pasted: []const u8) Event {
        return self.insertText(pasted);
    }

    pub fn submit(self: *TextInput) Event {
        const changed = !std.mem.eql(u8, self.text(), self.last_committed.items);
        if (changed) self.commitBaseline() catch {};
        return .submit;
    }

    pub fn render(self: *TextInput, region: Region) void {
        if (region.width == 0 or region.height == 0) return;
        self.buffer.width_method = region.buf.width_method;
        _ = region.writeStr(0, 0, self.prompt, self.theme.fg(.accent), Color.default, .{});
        const prompt_w: u32 = @intCast(grapheme_mod.strWidth(self.prompt, self.buffer.width_method));
        const available_w = region.width -| prompt_w;
        self.ensureCursorVisible(available_w);
        if (self.text().len > 0) {
            _ = region.writeStr(prompt_w, 0, self.text()[self.scroll_byte..], self.theme.fg(.text), Color.default, .{});
        } else if (self.placeholder) |p| {
            _ = region.writeStr(prompt_w, 0, p, self.theme.fg(.muted), Color.default, .{ .dim = true });
        }
    }

    pub fn measure(_: *TextInput, _: u32) Measurement {
        return .{ .min_height = 1, .preferred_height = 1 };
    }

    pub fn cursorState(self: *TextInput) ?CursorState {
        if (!self.focused) return null;
        const prompt_w: u32 = @intCast(grapheme_mod.strWidth(self.prompt, self.buffer.width_method));
        const cursor = self.buffer.cursorByte();
        const scroll = @min(self.scroll_byte, cursor);
        const text_w: u32 = @intCast(grapheme_mod.strWidth(self.text()[scroll..cursor], self.buffer.width_method));
        return .{ .x = prompt_w + text_w, .y = 0, .style = .bar };
    }

    pub fn component(self: *TextInput) Component {
        return Component.init(TextInput, self);
    }

    fn ensureCursorVisible(self: *TextInput, available_w: u32) void {
        const cursor = self.buffer.cursorByte();
        if (available_w == 0) {
            self.scroll_byte = cursor;
            return;
        }
        if (self.scroll_byte > cursor) self.scroll_byte = cursor;
        if (grapheme_mod.strWidth(self.text()[self.scroll_byte..cursor], self.buffer.width_method) <= available_w) return;

        var start: u32 = self.scroll_byte;
        while (start < cursor and grapheme_mod.strWidth(self.text()[start..cursor], self.buffer.width_method) > available_w) {
            start = @intCast(grapheme_mod.nextGraphemeBoundary(self.text(), start, self.buffer.width_method));
        }
        self.scroll_byte = start;
    }

    fn insertText(self: *TextInput, inserted: []const u8) Event {
        var sanitized: std.ArrayListUnmanaged(u8) = .empty;
        defer sanitized.deinit(self.allocator);
        appendSingleLineBounded(self.allocator, &sanitized, inserted, self.max_bytes -| self.text().len) catch return .none;
        if (sanitized.items.len == 0) return .none;
        self.buffer.insertAtCursor(sanitized.items);
        return .input;
    }

    fn deleteBackward(self: *TextInput) Event {
        const before = self.buffer.version();
        self.buffer.backspace();
        return if (self.buffer.version() != before) .input else .none;
    }

    fn deleteForward(self: *TextInput) Event {
        const before = self.buffer.version();
        self.buffer.deleteForward();
        return if (self.buffer.version() != before) .input else .none;
    }

    fn deleteToStart(self: *TextInput) Event {
        const cursor = self.buffer.cursorByte();
        if (cursor == 0) return .none;
        self.buffer.replaceRange(0, cursor, "", 0);
        return .input;
    }

    fn deleteToEnd(self: *TextInput) Event {
        const cursor = self.buffer.cursorByte();
        if (cursor >= self.text().len) return .none;
        self.buffer.replaceRange(cursor, @intCast(self.text().len), "", 0);
        return .input;
    }

    fn deleteWordBackward(self: *TextInput) Event {
        const cursor = self.buffer.cursorByte();
        if (cursor == 0) return .none;
        const bytes = self.text();
        var pos: u32 = cursor;
        while (pos > 0) {
            const p: u32 = @intCast(grapheme_mod.prevGraphemeBoundary(bytes, pos, self.buffer.width_method));
            if (!isAsciiSpace(bytes[p..pos])) break;
            pos = p;
        }
        while (pos > 0) {
            const p: u32 = @intCast(grapheme_mod.prevGraphemeBoundary(bytes, pos, self.buffer.width_method));
            if (isAsciiSpace(bytes[p..pos])) break;
            pos = p;
        }
        self.buffer.replaceRange(pos, cursor, "", 0);
        return .input;
    }

    fn moveLeft(self: *TextInput) Event {
        const before = self.buffer.cursorByte();
        self.buffer.moveLeft();
        return if (self.buffer.cursorByte() != before) .consumed else .none;
    }

    fn moveRight(self: *TextInput) Event {
        const before = self.buffer.cursorByte();
        self.buffer.moveRight();
        return if (self.buffer.cursorByte() != before) .consumed else .none;
    }

    fn moveHome(self: *TextInput) Event {
        const before = self.buffer.cursorByte();
        self.buffer.moveLogicalLineStart();
        return if (self.buffer.cursorByte() != before) .consumed else .none;
    }

    fn moveEnd(self: *TextInput) Event {
        const before = self.buffer.cursorByte();
        self.buffer.moveLogicalLineEnd();
        return if (self.buffer.cursorByte() != before) .consumed else .none;
    }

    fn commitBaseline(self: *TextInput) !void {
        self.last_committed.clearRetainingCapacity();
        try self.last_committed.appendSlice(self.allocator, self.text());
    }
};

fn appendSingleLineBounded(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8, max_bytes: usize) !void {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n' or cp == '\r') continue;
        if (out.items.len >= max_bytes) break;
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        if (out.items.len + len > max_bytes) break;
        try out.appendSlice(allocator, buf[0..len]);
    }
}

fn isAsciiSpace(bytes: []const u8) bool {
    return bytes.len == 1 and std.ascii.isWhitespace(bytes[0]);
}

const testing = std.testing;
const Buffer = surface_mod.Buffer;

test "TextInput edits submit and renders using shared edit buffer" {
    const theme = themes_builtin.dark();
    var input = TextInput.init(testing.allocator, theme);
    defer input.deinit();
    input.placeholder = "Ask…";
    try input.focus();

    try testing.expectEqual(TextInput.Event.input, input.handleKey(.{ .code = .char, .char = 'h' }));
    try testing.expectEqual(TextInput.Event.input, input.handleKey(.{ .code = .char, .char = 'i' }));
    try testing.expectEqualStrings("hi", input.text());
    try testing.expectEqual(TextInput.Event.consumed, input.handleKey(.{ .code = .left }));
    try testing.expectEqual(TextInput.Event.input, input.handleKey(.{ .code = .char, .char = '!' }));
    try testing.expectEqualStrings("h!i", input.text());
    try testing.expectEqual(TextInput.Event.submit, input.handleKey(.{ .code = .enter }));

    var buf = try Buffer.init(testing.allocator, 8, 1, .wcwidth);
    defer buf.deinit();
    input.render(buf.region());
    try testing.expectEqual(@as(u21, '›'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'h'), buf.get(2, 0).grapheme.codepoint);
}

test "TextInput scrolls horizontally to keep cursor visible" {
    const theme = themes_builtin.dark();
    var input = TextInput.init(testing.allocator, theme);
    defer input.deinit();
    try input.focus();
    try input.setValue("abcdef");

    var buf = try Buffer.init(testing.allocator, 5, 1, .wcwidth);
    defer buf.deinit();
    input.render(buf.region());

    try testing.expect(input.scroll_byte > 0);
    try testing.expectEqual(@as(u32, 5), input.cursorState().?.x);
}
