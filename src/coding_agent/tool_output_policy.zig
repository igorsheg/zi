const std = @import("std");

pub const default_max_lines: usize = 2000;
pub const default_max_bytes: usize = 50 * 1024;
pub const grep_max_line_bytes: usize = 500;

pub const TruncationLimit = enum { lines, bytes };

pub const TruncationOptions = struct {
    max_lines: usize = default_max_lines,
    max_bytes: usize = default_max_bytes,
};

pub const TruncationResult = struct {
    content: []const u8,
    truncated: bool,
    truncated_by: ?TruncationLimit,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    first_line_exceeds_limit: bool = false,
    partial_boundary_line: bool = false,
    max_lines: usize,
    max_bytes: usize,
};

pub fn truncateHead(content: []const u8, options: TruncationOptions) TruncationResult {
    const totals = countLinesAndBytes(content);
    if (totals.lines <= options.max_lines and totals.bytes <= options.max_bytes) {
        return fullResult(content, options, totals);
    }

    const first_end = lineEnd(content, 0);
    if (first_end > options.max_bytes) {
        return .{
            .content = content[0..0],
            .truncated = true,
            .truncated_by = .bytes,
            .total_lines = totals.lines,
            .total_bytes = totals.bytes,
            .output_lines = 0,
            .output_bytes = 0,
            .first_line_exceeds_limit = true,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
        };
    }

    var index: usize = 0;
    var lines: usize = 0;
    var bytes: usize = 0;
    var truncated_by: TruncationLimit = .lines;
    while (index < content.len and lines < options.max_lines) {
        const end = lineEnd(content, index);
        const next = nextLineStart(content, end);
        const line_bytes = next - index;
        if (bytes + line_bytes > options.max_bytes) {
            truncated_by = .bytes;
            break;
        }
        bytes += line_bytes;
        index = next;
        lines += 1;
    }
    if (lines >= options.max_lines and bytes <= options.max_bytes) truncated_by = .lines;

    return .{
        .content = content[0..index],
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = totals.lines,
        .total_bytes = totals.bytes,
        .output_lines = lines,
        .output_bytes = index,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

pub fn truncateTail(content: []const u8, options: TruncationOptions) TruncationResult {
    const totals = countLinesAndBytes(content);
    if (totals.lines <= options.max_lines and totals.bytes <= options.max_bytes) {
        return fullResult(content, options, totals);
    }

    var start = content.len;
    var lines: usize = 0;
    var bytes: usize = 0;
    var truncated_by: TruncationLimit = .lines;
    var partial = false;
    while (start > 0 and lines < options.max_lines) {
        const line_start = previousLineStart(content, start);
        const line_bytes = start - line_start;
        if (bytes + line_bytes > options.max_bytes) {
            truncated_by = .bytes;
            if (lines == 0) {
                const suffix_start = utf8SafeSuffixStart(content[line_start..start], options.max_bytes) + line_start;
                start = suffix_start;
                bytes = content.len - start;
                lines = 1;
                partial = true;
            }
            break;
        }
        bytes += line_bytes;
        start = line_start;
        lines += 1;
    }
    if (lines >= options.max_lines and bytes <= options.max_bytes and !partial) truncated_by = .lines;

    return .{
        .content = content[start..],
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = totals.lines,
        .total_bytes = totals.bytes,
        .output_lines = lines,
        .output_bytes = content.len - start,
        .partial_boundary_line = partial,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

const Totals = struct { lines: usize, bytes: usize };

fn fullResult(content: []const u8, options: TruncationOptions, totals: Totals) TruncationResult {
    return .{
        .content = content,
        .truncated = false,
        .truncated_by = null,
        .total_lines = totals.lines,
        .total_bytes = totals.bytes,
        .output_lines = totals.lines,
        .output_bytes = totals.bytes,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

fn countLinesAndBytes(content: []const u8) Totals {
    if (content.len == 0) return .{ .lines = 0, .bytes = 0 };
    var lines: usize = 1;
    for (content) |byte| {
        if (byte == '\n') lines += 1;
    }
    if (content[content.len - 1] == '\n') lines -= 1;
    return .{ .lines = lines, .bytes = content.len };
}

fn lineEnd(content: []const u8, start: usize) usize {
    var index = start;
    while (index < content.len and content[index] != '\n') : (index += 1) {}
    return index;
}

fn nextLineStart(content: []const u8, end: usize) usize {
    return if (end < content.len and content[end] == '\n') end + 1 else end;
}

fn previousLineStart(content: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var index = end - 1;
    if (content[index] == '\n' and index > 0) index -= 1;
    while (index > 0 and content[index - 1] != '\n') : (index -= 1) {}
    return index;
}

fn utf8SafeSuffixStart(content: []const u8, max_bytes: usize) usize {
    if (content.len <= max_bytes) return 0;
    var start = content.len - max_bytes;
    while (start < content.len and (content[start] & 0xc0) == 0x80) : (start += 1) {}
    return start;
}

test "tool output policy head keeps complete leading lines" {
    const result = truncateHead("one\ntwo\nthree", .{ .max_lines = 2, .max_bytes = 100 });
    try std.testing.expect(result.truncated);
    try std.testing.expectEqual(TruncationLimit.lines, result.truncated_by.?);
    try std.testing.expectEqualStrings("one\ntwo\n", result.content);
    try std.testing.expectEqual(@as(usize, 2), result.output_lines);
}

test "tool output policy head refuses partial first line" {
    const result = truncateHead("abcdef\nnext", .{ .max_lines = 10, .max_bytes = 3 });
    try std.testing.expect(result.first_line_exceeds_limit);
    try std.testing.expectEqualStrings("", result.content);
}

test "tool output policy tail keeps trailing lines" {
    const result = truncateTail("one\ntwo\nthree", .{ .max_lines = 2, .max_bytes = 100 });
    try std.testing.expect(result.truncated);
    try std.testing.expectEqual(TruncationLimit.lines, result.truncated_by.?);
    try std.testing.expectEqualStrings("two\nthree", result.content);
}

test "tool output policy tail keeps utf8-safe suffix for huge final line" {
    const result = truncateTail("ab中cd", .{ .max_lines = 10, .max_bytes = 4 });
    try std.testing.expect(result.partial_boundary_line);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.content));
    try std.testing.expectEqualStrings("cd", result.content);
}
