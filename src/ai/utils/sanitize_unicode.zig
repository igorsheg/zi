const std = @import("std");
const mem = @import("../../runtime/root.zig");

pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var sanitized = mem.ByteBuilder.initBounded(allocator, text.len);
    errdefer sanitized.deinit();

    var index: usize = 0;
    while (index < text.len) {
        if (isUtf8SurrogateAt(text, index)) {
            index += 3;
            continue;
        }

        try sanitized.appendByte(text[index]);
        index += 1;
    }

    return sanitized.toOwnedSlice();
}

fn isUtf8SurrogateAt(text: []const u8, index: usize) bool {
    if (index + 3 > text.len) return false;
    if (text[index] != 0xED) return false;

    const second = text[index + 1];
    const third = text[index + 2];
    return second >= 0xA0 and second <= 0xBF and third >= 0x80 and third <= 0xBF;
}

test "sanitize surrogates preserves valid utf8 emoji" {
    const input = "Hello 🙈 World";

    const sanitized = try sanitizeSurrogates(std.testing.allocator, input);
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(input, sanitized);
}

test "sanitize surrogates removes encoded high surrogate code unit" {
    const input = "Text \xED\xA0\xBD here";

    const sanitized = try sanitizeSurrogates(std.testing.allocator, input);
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings("Text  here", sanitized);
}

test "sanitize surrogates removes encoded low surrogate code unit" {
    const input = "Text \xED\xB8\x88 here";

    const sanitized = try sanitizeSurrogates(std.testing.allocator, input);
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings("Text  here", sanitized);
}

test "sanitize surrogates preserves incomplete byte sequence" {
    const input = "Text \xED\xA0 here";

    const sanitized = try sanitizeSurrogates(std.testing.allocator, input);
    defer std.testing.allocator.free(sanitized);

    try std.testing.expectEqualStrings(input, sanitized);
}
