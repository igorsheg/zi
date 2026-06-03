const std = @import("std");

pub const tool_tail_preview_bytes_max: usize = 2048;
pub const tool_tail_preview_lines_max: usize = 20;

pub const TailAppendResult = struct {
    bytes: []u8,
    dropped_bytes: usize,
    dropped_lines: usize,
};

pub const TailOptions = struct {
    max_bytes: usize = tool_tail_preview_bytes_max,
    max_lines: usize = tool_tail_preview_lines_max,
};

pub fn appendTail(
    allocator: std.mem.Allocator,
    old: []const u8,
    delta: []const u8,
) !TailAppendResult {
    return appendTailWithOptions(allocator, old, delta, .{});
}

pub fn appendTailWithOptions(
    allocator: std.mem.Allocator,
    old: []const u8,
    delta: []const u8,
    options: TailOptions,
) !TailAppendResult {
    const combined_len = old.len + delta.len;
    const combined = try allocator.alloc(u8, combined_len);
    defer allocator.free(combined);
    @memcpy(combined[0..old.len], old);
    @memcpy(combined[old.len..], delta);

    const start = tailStart(combined, options.max_bytes, options.max_lines);
    const bytes = try allocator.dupe(u8, combined[start..]);
    return .{
        .bytes = bytes,
        .dropped_bytes = start,
        .dropped_lines = countLines(combined[0..start]),
    };
}

fn tailStart(bytes: []const u8, max_bytes: usize, max_lines: usize) usize {
    if (bytes.len == 0) return 0;
    var start = if (bytes.len > max_bytes) bytes.len - max_bytes else 0;
    while (start < bytes.len and (bytes[start] & 0xc0) == 0x80) : (start += 1) {}

    if (max_lines == 0) return bytes.len;
    var line_count: usize = 0;
    var index = bytes.len;
    while (index > start) {
        if (bytes[index - 1] == '\n') {
            if (index - 1 != bytes.len - 1) line_count += 1;
            if (line_count >= max_lines) return index;
        }
        index -= 1;
    }
    return start;
}

fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    if (bytes[bytes.len - 1] == '\n') count -= 1;
    return count;
}

test "transcript preview keeps tail by byte cap" {
    const result = try appendTail(std.testing.allocator, "abcdef", "ghij");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualStrings("abcdefghij", result.bytes);
    try std.testing.expectEqual(@as(usize, 0), result.dropped_bytes);
}

test "transcript preview keeps tail by line cap" {
    const result = try appendTailWithOptions(std.testing.allocator, "one\ntwo\n", "three\nfour\nfive", .{
        .max_bytes = 100,
        .max_lines = 2,
    });
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expectEqualStrings("four\nfive", result.bytes);
    try std.testing.expect(result.dropped_lines >= 3);
}

test "transcript preview keeps utf8-safe suffix" {
    const result = try appendTail(std.testing.allocator, "", "ab中cd");
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.bytes));
}
