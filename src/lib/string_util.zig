const std = @import("std");

/// Trim `cutset` from both ends of `text` and return an owned copy.
///
/// The returned slice is always allocated from `allocator`, even when the
/// trimmed view is a subslice of a larger owned buffer.
pub fn dupeTrimmed(
    allocator: std.mem.Allocator,
    text: []const u8,
    cutset: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, text, cutset);
    return allocator.dupe(u8, trimmed);
}

test "dupeTrimmed returns an owned copy of the trimmed subslice" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, "  hello  ");
    defer allocator.free(source);

    const trimmed = try dupeTrimmed(allocator, source, " ");
    defer allocator.free(trimmed);

    try std.testing.expectEqualStrings("hello", trimmed);
    try std.testing.expect(trimmed.ptr != source.ptr);
}
