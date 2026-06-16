const std = @import("std");

pub const context_lines = 4;
pub const diff_bytes_max = 8 * 1024;
pub const hunk_lines_max = 200;

pub const AppliedEdit = struct {
    base_offset: usize,
    old_text: []const u8,
    new_text: []const u8,
};

pub fn render(
    allocator: std.mem.Allocator,
    base: []const u8,
    edits: []const AppliedEdit,
) error{OutOfMemory}![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    const line_width = lineNumberWidth(base, edits);
    var line_delta: isize = 0;
    for (edits, 0..) |edit, index| {
        std.debug.assert(edit.base_offset <= base.len);
        std.debug.assert(edit.base_offset + edit.old_text.len <= base.len);
        std.debug.assert(std.mem.eql(u8, base[edit.base_offset..][0..edit.old_text.len], edit.old_text));

        if (index == 0) {
            const before_start = contextBeforeStart(base, edit.base_offset, context_lines);
            const before_end = lineStart(base, edit.base_offset);
            try appendContext(&writer, base, before_start, before_end, line_width);
        }

        const old_line = lineNumberAt(base, edit.base_offset);
        const new_line = shiftedLine(old_line, line_delta);
        _ = try appendNumberedLines(&writer, '-', edit.old_text, old_line, line_width, hunk_lines_max);
        _ = try appendNumberedLines(&writer, '+', edit.new_text, new_line, line_width, hunk_lines_max);
        line_delta += lineDelta(lineCount(edit.old_text), lineCount(edit.new_text));

        const after_start = contextAfterStart(base, edit.base_offset + edit.old_text.len);
        if (index + 1 < edits.len) {
            const next = edits[index + 1];
            const before_end = lineStart(base, next.base_offset);
            if (before_end > after_start) {
                const after_end = contextAfterEnd(base, after_start, context_lines);
                const before_start = contextBeforeStart(base, next.base_offset, context_lines);
                if (before_start <= after_end) {
                    try appendContext(&writer, base, after_start, before_end, line_width);
                } else {
                    try appendContext(&writer, base, after_start, after_end, line_width);
                    try appendEllipsis(&writer, line_width);
                    try appendContext(&writer, base, before_start, before_end, line_width);
                }
            }
        } else {
            const after_end = contextAfterEnd(base, after_start, context_lines);
            try appendContext(&writer, base, after_start, after_end, line_width);
        }
    }

    return writer.toOwnedSlice();
}

fn appendBounded(writer: *std.Io.Writer.Allocating, text: []const u8) error{OutOfMemory}!void {
    if (writer.written().len + text.len > diff_bytes_max) {
        if (!std.mem.endsWith(u8, writer.written(), "... (diff truncated)\n") and
            writer.written().len + "... (diff truncated)\n".len <= diff_bytes_max)
        {
            writer.writer.writeAll("... (diff truncated)\n") catch return error.OutOfMemory;
        }
        return;
    }
    writer.writer.writeAll(text) catch return error.OutOfMemory;
}

fn appendContext(
    writer: *std.Io.Writer.Allocating,
    base: []const u8,
    start: usize,
    end: usize,
    line_width: usize,
) error{OutOfMemory}!void {
    if (end <= start) return;
    _ = try appendNumberedLines(writer, ' ', base[start..end], lineNumberAt(base, start), line_width, hunk_lines_max);
}

fn appendEllipsis(writer: *std.Io.Writer.Allocating, line_width: usize) error{OutOfMemory}!void {
    try appendBounded(writer, " ");
    var pad = line_width;
    while (pad > 0) : (pad -= 1) try appendBounded(writer, " ");
    try appendBounded(writer, " ...\n");
}

fn appendNumberedLines(
    writer: *std.Io.Writer.Allocating,
    prefix: u8,
    text: []const u8,
    start_line: usize,
    line_width: usize,
    max_lines: usize,
) error{OutOfMemory}!usize {
    if (text.len == 0) return 0;
    var start: usize = 0;
    var line = start_line;
    var count: usize = 0;
    while (start < text.len) {
        if (count == max_lines) {
            try appendBounded(writer, "... (hunk truncated)\n");
            return count;
        }
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try appendLinePrefix(writer, prefix, line, line_width);
        try appendBounded(writer, text[start..end]);
        try appendBounded(writer, "\n");
        count += 1;
        line += 1;
        start = if (end < text.len) end + 1 else text.len;
    }
    return count;
}

fn appendLinePrefix(
    writer: *std.Io.Writer.Allocating,
    prefix: u8,
    line: usize,
    line_width: usize,
) error{OutOfMemory}!void {
    const prefix_buf: [1]u8 = .{prefix};
    try appendBounded(writer, &prefix_buf);
    var digits_buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{line}) catch "?";
    var pad = line_width -| digits.len;
    while (pad > 0) : (pad -= 1) try appendBounded(writer, " ");
    try appendBounded(writer, digits);
    try appendBounded(writer, " ");
}

fn lineNumberAt(text: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (text[0..offset]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn contextBeforeStart(text: []const u8, offset: usize, lines: usize) usize {
    var start = lineStart(text, offset);
    var remaining = lines;
    while (remaining > 0 and start > 0) : (remaining -= 1) {
        start = lineStart(text, start - 1);
    }
    return start;
}

fn contextAfterStart(text: []const u8, offset: usize) usize {
    if (offset < text.len and text[offset] == '\n') return offset + 1;
    return offset;
}

fn contextAfterEnd(text: []const u8, offset: usize, lines: usize) usize {
    var end = lineEndNext(text, offset);
    var remaining = lines;
    while (remaining > 0 and end < text.len) : (remaining -= 1) {
        end = lineEndNext(text, end);
    }
    return end;
}

fn lineStart(text: []const u8, offset: usize) usize {
    var pos = @min(offset, text.len);
    while (pos > 0 and text[pos - 1] != '\n') pos -= 1;
    return pos;
}

fn lineEndNext(text: []const u8, offset: usize) usize {
    const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse return text.len;
    return end + 1;
}

fn lineNumberWidth(base: []const u8, edits: []const AppliedEdit) usize {
    const old_lines = @max(lineCount(base), 1);
    var new_lines = old_lines;
    for (edits) |edit| {
        const old_count = lineCount(edit.old_text);
        const new_count = lineCount(edit.new_text);
        if (new_count >= old_count) {
            new_lines += new_count - old_count;
        } else {
            new_lines -|= old_count - new_count;
        }
    }
    return decimalDigits(@max(old_lines, new_lines));
}

fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        count += 1;
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        start = if (end < text.len) end + 1 else text.len;
    }
    return count;
}

fn decimalDigits(value: usize) usize {
    var digits: usize = 1;
    var remaining = value;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return digits;
}

fn shiftedLine(line: usize, delta: isize) usize {
    if (delta < 0) return line -| @as(usize, @intCast(-delta));
    return line + @as(usize, @intCast(delta));
}

fn lineDelta(old_count: usize, new_count: usize) isize {
    if (new_count >= old_count) return @intCast(new_count - old_count);
    return -@as(isize, @intCast(old_count - new_count));
}

test "render anchored edit with numbered context" {
    const out = try render(std.testing.allocator, "a\nb\nc\nd\n", &.{.{
        .base_offset = 2,
        .old_text = "b",
        .new_text = "B",
    }});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "-2 b") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+2 B") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@@") == null);
}

test "render edit pads line numbers like pi-mono" {
    const out = try render(std.testing.allocator, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", &.{.{
        .base_offset = 0,
        .old_text = "1",
        .new_text = "one",
    }});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "- 1 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ 1 one") != null);
}

test "render edit merges nearby hunk context" {
    const base = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";
    const second = std.mem.indexOf(u8, base, "8").?;
    const out = try render(std.testing.allocator, base, &.{
        .{ .base_offset = 0, .old_text = "1", .new_text = "one" },
        .{ .base_offset = second, .old_text = "8", .new_text = "eight" },
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, " 5 5"));
    try std.testing.expect(std.mem.indexOf(u8, out, "- 8 8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ 8 eight") != null);
}

test "render edit at file end without trailing newline" {
    const out = try render(std.testing.allocator, "a\nb", &.{.{
        .base_offset = 2,
        .old_text = "b",
        .new_text = "bee",
    }});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+2 bee") != null);
}
