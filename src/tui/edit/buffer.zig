const std = @import("std");
const grapheme_mod = @import("../grapheme.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const LogicalCursor = types.LogicalCursor;

pub const EditBuffer = struct {
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor_byte: u32 = 0,
    cursor_line: u32 = 0,
    cursor_col: u32 = 0,
    version_tag: u64 = 1,
    width_method: grapheme_mod.WidthMethod,

    pub fn init(allocator: Allocator, width_method: grapheme_mod.WidthMethod) EditBuffer {
        return .{ .allocator = allocator, .width_method = width_method };
    }

    pub fn deinit(self: *EditBuffer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn text(self: *const EditBuffer) []const u8 {
        return self.buf.items;
    }

    pub fn version(self: *const EditBuffer) u64 {
        return self.version_tag;
    }

    pub fn cursor(self: *const EditBuffer) LogicalCursor {
        return .{
            .byte = self.cursor_byte,
            .line = self.cursor_line,
            .col = self.cursor_col,
        };
    }

    pub fn cursorByte(self: *const EditBuffer) u32 {
        return self.cursor_byte;
    }

    pub fn setText(self: *EditBuffer, new_text: []const u8) void {
        self.setTextAndCursor(new_text, @intCast(new_text.len));
    }

    pub fn setTextAndCursor(self: *EditBuffer, new_text: []const u8, cursor_byte: u32) void {
        self.buf.items.len = 0;
        self.buf.appendSlice(self.allocator, new_text) catch {
            self.cursor_byte = 0;
            self.cursor_line = 0;
            self.cursor_col = 0;
            self.bumpVersion();
            return;
        };
        self.cursor_byte = @min(cursor_byte, @as(u32, @intCast(self.buf.items.len)));
        self.recomputeCursorMetrics();
        self.bumpVersion();
    }

    pub fn clear(self: *EditBuffer) void {
        self.setTextAndCursor("", 0);
    }

    pub fn insertAtCursor(self: *EditBuffer, new_text: []const u8) void {
        self.buf.insertSlice(self.allocator, self.cursor_byte, new_text) catch return;
        self.cursor_byte += @intCast(new_text.len);
        self.recomputeCursorMetrics();
        self.bumpVersion();
    }

    pub fn insertNewline(self: *EditBuffer) void {
        self.insertAtCursor("\n");
    }

    pub fn replaceRange(self: *EditBuffer, start_byte: u32, end_byte: u32, replacement_text: []const u8, cursor_in_replacement: u32) void {
        const clamped_start = @min(start_byte, @as(u32, @intCast(self.buf.items.len)));
        const clamped_end = @max(clamped_start, @min(end_byte, @as(u32, @intCast(self.buf.items.len))));

        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(self.allocator);

        next.appendSlice(self.allocator, self.buf.items[0..clamped_start]) catch return;
        next.appendSlice(self.allocator, replacement_text) catch return;
        next.appendSlice(self.allocator, self.buf.items[clamped_end..]) catch return;

        self.buf.deinit(self.allocator);
        self.buf = next;
        self.cursor_byte = clamped_start + @min(cursor_in_replacement, @as(u32, @intCast(replacement_text.len)));
        self.recomputeCursorMetrics();
        self.bumpVersion();
    }

    pub fn backspace(self: *EditBuffer) void {
        if (self.cursor_byte == 0) return;
        const prev: u32 = @intCast(grapheme_mod.prevGraphemeBoundary(self.buf.items, self.cursor_byte, self.width_method));
        const items = self.buf.items;
        std.mem.copyForwards(u8, items[prev..], items[self.cursor_byte..]);
        self.buf.items.len -= self.cursor_byte - prev;
        self.cursor_byte = prev;
        self.recomputeCursorMetrics();
        self.bumpVersion();
    }

    pub fn deleteForward(self: *EditBuffer) void {
        if (self.cursor_byte >= self.buf.items.len) return;
        const next: u32 = @intCast(grapheme_mod.nextGraphemeBoundary(self.buf.items, self.cursor_byte, self.width_method));
        const items = self.buf.items;
        std.mem.copyForwards(u8, items[self.cursor_byte..], items[next..]);
        self.buf.items.len -= next - self.cursor_byte;
        self.recomputeCursorMetrics();
        self.bumpVersion();
    }

    pub fn moveLeft(self: *EditBuffer) void {
        if (self.cursor_byte == 0) return;
        self.cursor_byte = @intCast(grapheme_mod.prevGraphemeBoundary(self.buf.items, self.cursor_byte, self.width_method));
        self.recomputeCursorMetrics();
    }

    pub fn moveRight(self: *EditBuffer) void {
        if (self.cursor_byte >= self.buf.items.len) return;
        self.cursor_byte = @intCast(grapheme_mod.nextGraphemeBoundary(self.buf.items, self.cursor_byte, self.width_method));
        self.recomputeCursorMetrics();
    }

    pub fn moveLogicalLineStart(self: *EditBuffer) void {
        self.cursor_byte = self.currentLineStart();
        self.recomputeCursorMetrics();
    }

    pub fn moveLogicalLineEnd(self: *EditBuffer) void {
        self.cursor_byte = self.currentLineEnd();
        self.recomputeCursorMetrics();
    }

    pub fn setCursorByte(self: *EditBuffer, byte: u32) void {
        self.cursor_byte = @min(byte, @as(u32, @intCast(self.buf.items.len)));
        self.recomputeCursorMetrics();
    }

    pub fn currentLineStart(self: *const EditBuffer) u32 {
        if (self.cursor_byte == 0) return 0;
        var i = self.cursor_byte - 1;
        while (i > 0 and self.buf.items[i] != '\n') : (i -= 1) {}
        if (self.buf.items[i] == '\n') return i + 1;
        return 0;
    }

    pub fn currentLineEnd(self: *const EditBuffer) u32 {
        var i = self.cursor_byte;
        while (i < self.buf.items.len and self.buf.items[i] != '\n') : (i += 1) {}
        return @intCast(i);
    }

    pub fn cursorLine(self: *const EditBuffer) u32 {
        return self.cursor_line;
    }

    pub fn lineCount(self: *const EditBuffer) u32 {
        if (self.buf.items.len == 0) return 1;
        var count: u32 = 1;
        for (self.buf.items) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    pub fn lineStartByIndex(self: *const EditBuffer, n: u32) u32 {
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

    pub fn lineEndByStart(self: *const EditBuffer, start: u32) u32 {
        var i = start;
        while (i < self.buf.items.len and self.buf.items[i] != '\n') : (i += 1) {}
        return i;
    }

    pub fn displayColAtByte(self: *const EditBuffer, byte: u32) u32 {
        const clamped = @min(byte, @as(u32, @intCast(self.buf.items.len)));
        var line_start: u32 = 0;
        if (clamped > 0) {
            var i: u32 = clamped - 1;
            while (i > 0 and self.buf.items[i] != '\n') : (i -= 1) {}
            if (i < clamped and self.buf.items[i] == '\n') {
                line_start = i + 1;
            }
        }
        return @intCast(grapheme_mod.strWidth(self.buf.items[line_start..clamped], self.width_method));
    }

    pub fn byteAtDisplayCol(self: *const EditBuffer, line_start: u32, line_end: u32, target_col: u32) u32 {
        var col: u32 = 0;
        var i: u32 = line_start;
        while (i < line_end) {
            const next_boundary: u32 = @intCast(@min(
                grapheme_mod.nextGraphemeBoundary(self.buf.items, i, self.width_method),
                @as(usize, line_end),
            ));
            const width: u32 = @intCast(grapheme_mod.strWidth(self.buf.items[i..next_boundary], self.width_method));
            if (col + width > target_col and width > 0) break;
            col += width;
            i = next_boundary;
        }
        return i;
    }

    fn recomputeCursorMetrics(self: *EditBuffer) void {
        self.cursor_byte = @min(self.cursor_byte, @as(u32, @intCast(self.buf.items.len)));

        var line: u32 = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < self.cursor_byte) : (i += 1) {
            if (self.buf.items[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }

        self.cursor_line = line;
        self.cursor_col = @intCast(grapheme_mod.strWidth(self.buf.items[line_start..self.cursor_byte], self.width_method));
    }

    fn bumpVersion(self: *EditBuffer) void {
        self.version_tag +%= 1;
    }
};
