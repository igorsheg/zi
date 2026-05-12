const std = @import("std");

pub const ascii_whitespace = &std.ascii.whitespace;

pub fn dupeTrimmed(
    allocator: std.mem.Allocator,
    text: []const u8,
    cutset: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, text, cutset);
    return allocator.dupe(u8, trimmed);
}

pub fn trimAsciiWhitespace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, ascii_whitespace);
}

pub fn dupeTrimmedAsciiWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return dupeTrimmed(allocator, text, ascii_whitespace);
}

pub fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn containsAnyCI(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsCI(haystack, needle)) return true;
    }
    return false;
}

pub fn utf8LossyAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return allocator.dupe(u8, bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        if (i + len > bytes.len) {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            break;
        }
        _ = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        try out.appendSlice(allocator, bytes[i .. i + len]);
        i += len;
    }

    return out.toOwnedSlice(allocator);
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

test "containsCI matches substrings case-insensitively" {
    try std.testing.expect(containsCI("HTTP 429 Too Many Requests", "many requests"));
    try std.testing.expect(containsAnyCI("context window exceeded", &.{ "rate limit", "context window" }));
    try std.testing.expect(!containsCI("hello", "world"));
}
