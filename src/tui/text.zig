//! Text measurement and wrapping policy over vaxis' unicode/gwidth engines,
//! plus the UTF-8 sanitation helpers the transcript and composer use to make
//! streamed operational input safe by construction.
//!
//! Invariant the rest of the TUI relies on: text stored in product state is
//! always valid UTF-8. Invalid sequences are replaced with U+FFFD on ingest;
//! a multibyte codepoint split across two streamed deltas is carried as a
//! pending tail (`splitIncompleteTail`) and joined with the next delta.
const std = @import("std");
const vaxis = @import("vaxis");

pub const replacement = "\u{fffd}";

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

/// One display row of wrapped text. Newlines break, over-wide graphemes are
/// force-consumed so progress is guaranteed even at width 1.
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

pub const SplitTail = struct {
    complete: []const u8,
    tail: []const u8,
};

/// Split off a trailing incomplete (but so far valid) multibyte sequence so
/// a streamed delta boundary never corrupts a codepoint. `tail` is at most
/// 3 bytes; anything that cannot become valid stays in `complete` for the
/// sanitizer to replace.
pub fn splitIncompleteTail(bytes: []const u8) SplitTail {
    if (bytes.len == 0) return .{ .complete = bytes, .tail = bytes[0..0] };
    const scan_max = @min(bytes.len, 3);
    var back: usize = 1;
    while (back <= scan_max) : (back += 1) {
        const index = bytes.len - back;
        const byte = bytes[index];
        if (byte & 0xc0 == 0x80) continue; // continuation byte, keep scanning
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch return .{
            .complete = bytes,
            .tail = bytes[0..0],
        };
        if (index + sequence_len <= bytes.len) break; // final sequence is complete
        return .{ .complete = bytes[0..index], .tail = bytes[index..] };
    }
    return .{ .complete = bytes, .tail = bytes[0..0] };
}

/// Append `bytes` with every invalid UTF-8 sequence replaced by U+FFFD.
/// Valid input is copied verbatim.
pub fn appendSanitized(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    bytes: []const u8,
) error{OutOfMemory}!void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try list.appendSlice(gpa, bytes);
        return;
    }
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte < 0x80) {
            try list.append(gpa, byte);
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try list.appendSlice(gpa, replacement);
            index += 1;
            continue;
        };
        if (index + sequence_len > bytes.len or
            !std.unicode.utf8ValidateSlice(bytes[index .. index + sequence_len]))
        {
            try list.appendSlice(gpa, replacement);
            index += 1;
            continue;
        }
        try list.appendSlice(gpa, bytes[index .. index + sequence_len]);
        index += sequence_len;
    }
}

/// Sanitize into a caller buffer (no allocation): invalid sequences become
/// U+FFFD, output truncates at the buffer end on a codepoint boundary.
pub fn sanitizeInto(buffer: []u8, bytes: []const u8) []const u8 {
    var out: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        var piece: []const u8 = undefined;
        if (byte < 0x80) {
            piece = bytes[index .. index + 1];
            index += 1;
        } else if (std.unicode.utf8ByteSequenceLength(byte)) |sequence_len| {
            if (index + sequence_len <= bytes.len and
                std.unicode.utf8ValidateSlice(bytes[index .. index + sequence_len]))
            {
                piece = bytes[index .. index + sequence_len];
                index += sequence_len;
            } else {
                piece = replacement;
                index += 1;
            }
        } else |_| {
            piece = replacement;
            index += 1;
        }
        if (out + piece.len > buffer.len) break;
        @memcpy(buffer[out..][0..piece.len], piece);
        out += piece.len;
    }
    return buffer[0..out];
}

/// Longest valid-UTF-8 prefix of `bytes` no longer than `max_bytes`.
pub fn utf8Prefix(bytes: []const u8, max_bytes: usize) []const u8 {
    if (bytes.len <= max_bytes) return bytes;
    var end = max_bytes;
    while (end > 0 and (bytes[end] & 0xc0) == 0x80) : (end -= 1) {}
    return bytes[0..end];
}

fn previousScalarStart(bytes: []const u8, cursor: usize) usize {
    var index = cursor - 1;
    while (index > 0 and (bytes[index] & 0xc0) == 0x80) : (index -= 1) {}
    return index;
}

fn nextScalarEnd(bytes: []const u8, cursor: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor]) catch 1;
    return @min(cursor + len, bytes.len);
}

fn clampWidth(width: usize) u2 {
    if (width == 0) return 0;
    if (width > 2) return 2;
    return @intCast(width);
}

test "nextVisualLineBreak forces progress on over-wide graphemes" {
    const wide = "🙂"; // width 2
    const line = nextVisualLineBreak(wide, 0, 1);
    try std.testing.expect(line.next > 0);
    try std.testing.expectEqual(wide.len, line.next);
}

test "nextVisualLineBreak splits on newline and wraps at width" {
    const bytes = "ab\ncdef";
    const first = nextVisualLineBreak(bytes, 0, 80);
    try std.testing.expectEqualStrings("ab", bytes[first.start..first.end]);
    const second = nextVisualLineBreak(bytes, first.next, 2);
    try std.testing.expectEqualStrings("cd", bytes[second.start..second.end]);
}

test "splitIncompleteTail carries a split codepoint" {
    const heart = "❤"; // 3 bytes
    var bytes: [4]u8 = undefined;
    bytes[0] = 'a';
    @memcpy(bytes[1..4], heart);
    const split = splitIncompleteTail(bytes[0..3]); // 'a' + 2 of 3 heart bytes
    try std.testing.expectEqualStrings("a", split.complete);
    try std.testing.expectEqual(@as(usize, 2), split.tail.len);

    const whole = splitIncompleteTail(bytes[0..4]);
    try std.testing.expectEqual(@as(usize, 0), whole.tail.len);
}

test "appendSanitized replaces invalid bytes and keeps valid text" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendSanitized(std.testing.allocator, &list, "ok\xffgo");
    try std.testing.expectEqualStrings("ok\u{fffd}go", list.items);
}

test "sanitizeInto truncates at buffer end on codepoint boundary" {
    var buffer: [4]u8 = undefined;
    const out = sanitizeInto(&buffer, "ab❤x");
    try std.testing.expectEqualStrings("ab", out); // heart needs 3 bytes, only 2 left
}
