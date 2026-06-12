const std = @import("std");

pub const context_lines = 3;
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

    for (edits, 0..) |edit, index| {
        std.debug.assert(edit.base_offset <= base.len);
        std.debug.assert(edit.base_offset + edit.old_text.len <= base.len);
        std.debug.assert(std.mem.eql(u8, base[edit.base_offset..][0..edit.old_text.len], edit.old_text));

        if (index > 0) try appendBounded(&writer, "\n");
        var header: [80]u8 = undefined;
        const line = lineNumberAt(base, edit.base_offset);
        try appendBounded(&writer, std.fmt.bufPrint(&header, "@@ line {d} @@\n", .{line}) catch "@@\n");

        const before = contextBefore(base, edit.base_offset, context_lines);
        try appendLines(&writer, ' ', before, hunk_lines_max);
        try appendLines(&writer, '-', edit.old_text, hunk_lines_max);
        try appendLines(&writer, '+', edit.new_text, hunk_lines_max);
        const after_start = edit.base_offset + edit.old_text.len;
        const after = contextAfter(base, after_start, context_lines);
        try appendLines(&writer, ' ', after, hunk_lines_max);
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

fn appendLines(
    writer: *std.Io.Writer.Allocating,
    prefix: u8,
    text: []const u8,
    max_lines: usize,
) error{OutOfMemory}!void {
    if (text.len == 0) return;
    var start: usize = 0;
    var count: usize = 0;
    while (start < text.len) {
        if (count == max_lines) {
            try appendBounded(writer, "... (hunk truncated)\n");
            return;
        }
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        var line_buf: [2]u8 = .{ prefix, ' ' };
        try appendBounded(writer, &line_buf);
        try appendBounded(writer, text[start..end]);
        try appendBounded(writer, "\n");
        count += 1;
        start = if (end < text.len) end + 1 else text.len;
    }
}

fn lineNumberAt(text: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (text[0..offset]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn contextBefore(text: []const u8, offset: usize, lines: usize) []const u8 {
    var start = lineStart(text, offset);
    var remaining = lines;
    while (remaining > 0 and start > 0) : (remaining -= 1) {
        start = lineStart(text, start - 1);
    }
    return text[start..lineStart(text, offset)];
}

fn contextAfter(text: []const u8, offset: usize, lines: usize) []const u8 {
    var end = lineEndNext(text, offset);
    var remaining = lines;
    while (remaining > 0 and end < text.len) : (remaining -= 1) {
        end = lineEndNext(text, end);
    }
    return text[offset..end];
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

test "render anchored edit with context" {
    const out = try render(std.testing.allocator, "a\nb\nc\nd\n", &.{.{
        .base_offset = 2,
        .old_text = "b",
        .new_text = "B",
    }});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "- b") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ B") != null);
}

test "render edit at file end without trailing newline" {
    const out = try render(std.testing.allocator, "a\nb", &.{.{
        .base_offset = 2,
        .old_text = "b",
        .new_text = "bee",
    }});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ bee") != null);
}
