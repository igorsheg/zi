const std = @import("std");

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

const testing = std.testing;

test "utf8LossyAlloc preserves valid utf-8 and replaces invalid bytes" {
    const allocator = testing.allocator;

    const valid = try utf8LossyAlloc(allocator, "hello é");
    defer allocator.free(valid);
    try testing.expectEqualStrings("hello é", valid);

    const invalid = try utf8LossyAlloc(allocator, "bad\xaa\xfftail");
    defer allocator.free(invalid);
    try testing.expectEqualStrings("bad��tail", invalid);
}

test "utf8LossyAlloc replaces truncated trailing sequence" {
    const allocator = testing.allocator;
    const invalid = try utf8LossyAlloc(allocator, "x\xE2");
    defer allocator.free(invalid);
    try testing.expectEqualStrings("x�", invalid);
}
