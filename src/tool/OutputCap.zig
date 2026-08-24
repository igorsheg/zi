const std = @import("std");
const text = @import("../text/root.zig");

pub const default_output_bytes: usize = 50 * 1024;
pub const maximum_lines: usize = 2000;
pub const maximum_line_bytes: usize = 500;
pub const maximum_capture_bytes: usize = 16 * 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    ResultTooLarge,
};

/// Caps every newline-delimited physical line by raw bytes. Existing newline
/// structure is preserved and no final newline is invented.
pub fn capLineLengths(
    allocator: std.mem.Allocator,
    input: []const u8,
    line_bytes: usize,
    result_bytes: usize,
) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var offset: usize = 0;
    while (offset < input.len) {
        const line_start = offset;
        while (offset < input.len and input[offset] != '\n') offset += 1;
        const line = input[line_start..offset];
        if (line.len > line_bytes) {
            try appendBounded(allocator, &output, line[0..line_bytes], result_bytes);
            var marker_buffer: [64]u8 = undefined;
            const marker = std.fmt.bufPrint(
                &marker_buffer,
                "...[{d} bytes elided]",
                .{line.len - line_bytes},
            ) catch return error.ResultTooLarge;
            try appendBounded(allocator, &output, marker, result_bytes);
        } else {
            try appendBounded(allocator, &output, line, result_bytes);
        }
        if (offset < input.len) {
            try appendBounded(allocator, &output, "\n", result_bytes);
            offset += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

/// Applies the byte cap before UTF-8 sanitation, so a split codepoint becomes
/// one replacement for each retained malformed byte exactly as hax does.
pub fn capAndSanitize(
    allocator: std.mem.Allocator,
    input: []const u8,
    line_bytes: usize,
    result_bytes: usize,
) Error![]u8 {
    const capped = try capLineLengths(allocator, input, line_bytes, result_bytes);
    defer allocator.free(capped);
    return text.Utf8.sanitize(allocator, capped, result_bytes);
}

fn appendBounded(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
    maximum: usize,
) Error!void {
    if (bytes.len > maximum -| output.items.len) return error.ResultTooLarge;
    try output.appendSlice(allocator, bytes);
}

test "short and empty lines pass through with an owned result" {
    const allocator = std.testing.allocator;
    const output = try capLineLengths(allocator, "hello\nworld\n", 100, 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("hello\nworld\n", output);

    const empty = try capLineLengths(allocator, "", 100, 1024);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "long lines use exact marker and preserve neighbors" {
    const allocator = std.testing.allocator;
    const output = try capLineLengths(
        allocator,
        "before\nxxxxxxxxxx\nafter\n",
        6,
        1024,
    );
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "before\nxxxxxx...[4 bytes elided]\nafter\n",
        output,
    );
}

test "unterminated long line remains unterminated" {
    const allocator = std.testing.allocator;
    const output = try capLineLengths(allocator, "zzzzzzzz", 3, 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("zzz...[5 bytes elided]", output);
}

test "zero line width preserves newline structure" {
    const allocator = std.testing.allocator;
    const output = try capLineLengths(allocator, "a\n\nb", 0, 1024);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "...[1 bytes elided]\n\n...[1 bytes elided]",
        output,
    );
}

test "marker growth obeys final result bound" {
    try std.testing.expectError(
        error.ResultTooLarge,
        capLineLengths(std.testing.allocator, "12345", 4, 4),
    );
}

test "byte cap may split UTF-8 before sanitizer repairs it" {
    const allocator = std.testing.allocator;
    const input = "abc\xc3\xa9";
    const output = try capAndSanitize(allocator, input, 4, 128);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "abc\xef\xbf\xbd...[1 bytes elided]",
        output,
    );
}

fn exerciseCapAllocations(allocator: std.mem.Allocator) !void {
    const output = try capAndSanitize(
        allocator,
        "before\nxxxxxxxxxx\ninvalid \xff\n",
        4,
        1024,
    );
    allocator.free(output);
}

test "cap and sanitize free every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCapAllocations,
        .{},
    );
}
