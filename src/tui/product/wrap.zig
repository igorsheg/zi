const std = @import("std");
const vaxis = @import("vaxis");

pub const replacement: u21 = 0xfffd;

pub const Grapheme = struct {
    start: usize,
    end: usize,
    width: u2,
};

pub const VisualLineBreak = struct {
    start: usize,
    end: usize,
    next: usize,
    width: u16,
};

pub fn nextGrapheme(bytes: []const u8) Grapheme {
    if (bytes.len == 0) return .{ .start = 0, .end = 0, .width = 0 };
    if (!std.unicode.utf8ValidateSlice(bytes)) return .{ .start = 0, .end = 1, .width = 1 };
    var iterator = vaxis.unicode.graphemeIterator(bytes);
    const grapheme = iterator.next() orelse return .{ .start = 0, .end = 0, .width = 0 };
    const end = grapheme.start + grapheme.len;
    return .{ .start = grapheme.start, .end = end, .width = clampWidth(displayWidth(bytes[grapheme.start..end])) };
}

pub fn previousGraphemeStart(bytes: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= bytes.len);
    if (cursor == 0) return 0;
    if (!std.unicode.utf8ValidateSlice(bytes[0..cursor])) return previousScalarStart(bytes, cursor);
    var iterator = vaxis.unicode.graphemeIterator(bytes[0..cursor]);
    var previous: usize = 0;
    while (iterator.next()) |grapheme| {
        const end = grapheme.start + grapheme.len;
        if (end >= cursor) return grapheme.start;
        previous = grapheme.start;
    }
    return previous;
}

pub fn nextGraphemeEnd(bytes: []const u8, cursor: usize) usize {
    std.debug.assert(cursor <= bytes.len);
    if (cursor >= bytes.len) return bytes.len;
    if (!std.unicode.utf8ValidateSlice(bytes[cursor..])) return nextScalarEnd(bytes, cursor);
    const grapheme = nextGrapheme(bytes[cursor..]);
    if (grapheme.end == 0) return bytes.len;
    return @min(cursor + grapheme.end, bytes.len);
}

pub fn displayWidth(bytes: []const u8) usize {
    if (!std.unicode.utf8ValidateSlice(bytes)) return bytes.len;
    return vaxis.gwidth.gwidth(bytes, .unicode);
}

pub fn nextVisualLineBreak(bytes: []const u8, start: usize, max_width: u16) VisualLineBreak {
    std.debug.assert(start <= bytes.len);
    if (start == bytes.len or max_width == 0) return .{ .start = start, .end = start, .next = start, .width = 0 };
    if (bytes[start] == '\n') return .{ .start = start, .end = start, .next = start + 1, .width = 0 };

    var index = start;
    var width: u16 = 0;
    while (index < bytes.len) {
        if (bytes[index] == '\n') return .{ .start = start, .end = index, .next = index + 1, .width = width };
        if (bytes[index] == '\r' and index + 1 < bytes.len and bytes[index + 1] == '\n') {
            return .{ .start = start, .end = index, .next = index + 2, .width = width };
        }
        const grapheme = nextGrapheme(bytes[index..]);
        if (grapheme.end == 0) break;
        const next_width = width + grapheme.width;
        if (next_width > max_width) {
            if (index == start) {
                return .{ .start = start, .end = index + grapheme.end, .next = index + grapheme.end, .width = 0 };
            }
            break;
        }
        index += grapheme.end;
        width = next_width;
    }
    return .{ .start = start, .end = index, .next = index, .width = width };
}

fn previousScalarStart(bytes: []const u8, cursor: usize) usize {
    var index = cursor - 1;
    while (index > 0 and (bytes[index] & 0xc0) == 0x80) : (index -= 1) {}
    return index;
}

fn nextScalarEnd(bytes: []const u8, cursor: usize) usize {
    const first = bytes[cursor];
    const len: usize = if (first < 0x80)
        1
    else if ((first & 0xe0) == 0xc0)
        2
    else if ((first & 0xf0) == 0xe0)
        3
    else if ((first & 0xf8) == 0xf0)
        4
    else
        1;
    return @min(cursor + len, bytes.len);
}

fn clampWidth(width: usize) u2 {
    if (width == 0) return 0;
    if (width > 2) return 2;
    return @intCast(width);
}
