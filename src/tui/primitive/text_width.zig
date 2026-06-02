const std = @import("std");

pub const WidthError = error{InvalidUtf8};

pub fn width(bytes: []const u8) WidthError!usize {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var total: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return error.InvalidUtf8;
        if (bytes[i] < 0x20 or bytes[i] == 0x7f) {}
        else total += 1;
        i += len;
    }
    return total;
}

test "ascii exact and utf8 conservative" {
    try std.testing.expectEqual(@as(usize, 3), try width("abc"));
    try std.testing.expectEqual(@as(usize, 1), try width("🙂"));
    try std.testing.expectError(error.InvalidUtf8, width("\xff"));
}
