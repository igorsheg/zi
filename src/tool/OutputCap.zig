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
    return sanitizeClipped(allocator, capped, result_bytes);
}

fn sanitizeClipped(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum: usize,
) Error![]u8 {
    return text.Utf8.sanitize(allocator, input, maximum) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => clipped: {
            if (maximum <= 3) break :clipped allocator.dupe(u8, "..."[0..maximum]);
            const budget = maximum - 3;
            var low: usize = 0;
            var high: usize = input.len;
            while (low < high) {
                const middle = low + (high - low + 1) / 2;
                const candidate = text.Utf8.sanitize(
                    allocator,
                    input[0..middle],
                    budget,
                ) catch |candidate_error| switch (candidate_error) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ResultTooLarge => {
                        high = middle - 1;
                        continue;
                    },
                };
                allocator.free(candidate);
                low = middle;
            }
            const prefix = try text.Utf8.sanitize(allocator, input[0..low], budget);
            defer allocator.free(prefix);
            const output = try allocator.alloc(u8, prefix.len + 3);
            @memcpy(output[0..prefix.len], prefix);
            @memcpy(output[prefix.len..], "...");
            break :clipped output;
        },
    };
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

test "sanitation expansion clips within the model byte budget" {
    const allocator = std.testing.allocator;
    const input: [10]u8 = @splat(0xff);
    const output = try capAndSanitize(allocator, &input, maximum_line_bytes, 10);
    defer allocator.free(output);
    try std.testing.expect(output.len <= 10);
    try std.testing.expectEqualStrings("...", output[output.len - 3 ..]);
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
