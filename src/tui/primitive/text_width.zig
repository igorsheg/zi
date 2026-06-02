const std = @import("std");

pub const replacement: u21 = 0xfffd;
pub const DecodedScalar = struct { scalar: u21, len: usize };

pub fn nextScalar(bytes: []const u8) DecodedScalar {
    if (bytes.len == 0) return .{ .scalar = replacement, .len = 0 };
    const first = bytes[0];
    if (first < 0x80) {
        return .{ .scalar = if (first < 0x20 or first == 0x7f) replacement else first, .len = 1 };
    }
    const len = utf8SequenceLen(first);
    if (len > bytes.len) return .{ .scalar = replacement, .len = 1 };
    const slice = bytes[0..len];
    if (!std.unicode.utf8ValidateSlice(slice)) return .{ .scalar = replacement, .len = 1 };
    return .{ .scalar = std.unicode.utf8Decode(slice) catch replacement, .len = len };
}

fn utf8SequenceLen(first: u8) usize {
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
}

pub fn scalarWidth(scalar: u21) u2 {
    if (scalar == 0 or scalar < 0x20 or scalar == 0x7f) return 1;
    if (isWideScalar(scalar)) return 2;
    return 1;
}

fn isWideScalar(scalar: u21) bool {
    // Bounded terminal-width policy for common fullwidth, CJK, and emoji scalar ranges.
    // This is scalar-based, not grapheme-based; product text can later swap this file
    // for uucode without leaking that dependency into renderer or product types.
    return (scalar >= 0x1100 and scalar <= 0x115f) or
        (scalar >= 0x231a and scalar <= 0x231b) or
        (scalar >= 0x2329 and scalar <= 0x232a) or
        (scalar >= 0x23e9 and scalar <= 0x23ec) or
        (scalar >= 0x23f0 and scalar <= 0x23f0) or
        (scalar >= 0x23f3 and scalar <= 0x23f3) or
        (scalar >= 0x25fd and scalar <= 0x25fe) or
        (scalar >= 0x2614 and scalar <= 0x2615) or
        (scalar >= 0x2648 and scalar <= 0x2653) or
        (scalar >= 0x267f and scalar <= 0x267f) or
        (scalar >= 0x2693 and scalar <= 0x2693) or
        (scalar >= 0x26a1 and scalar <= 0x26a1) or
        (scalar >= 0x26aa and scalar <= 0x26ab) or
        (scalar >= 0x26bd and scalar <= 0x26be) or
        (scalar >= 0x26c4 and scalar <= 0x26c5) or
        (scalar >= 0x26ce and scalar <= 0x26ce) or
        (scalar >= 0x26d4 and scalar <= 0x26d4) or
        (scalar >= 0x26ea and scalar <= 0x26ea) or
        (scalar >= 0x26f2 and scalar <= 0x26f3) or
        (scalar >= 0x26f5 and scalar <= 0x26f5) or
        (scalar >= 0x26fa and scalar <= 0x26fa) or
        (scalar >= 0x26fd and scalar <= 0x26fd) or
        (scalar >= 0x2705 and scalar <= 0x2705) or
        (scalar >= 0x270a and scalar <= 0x270b) or
        (scalar >= 0x2728 and scalar <= 0x2728) or
        (scalar >= 0x274c and scalar <= 0x274c) or
        (scalar >= 0x2e80 and scalar <= 0xa4cf) or
        (scalar >= 0xac00 and scalar <= 0xd7a3) or
        (scalar >= 0xf900 and scalar <= 0xfaff) or
        (scalar >= 0xff01 and scalar <= 0xff60) or
        (scalar >= 0xffe0 and scalar <= 0xffe6) or
        (scalar >= 0x1f300 and scalar <= 0x1f64f) or
        (scalar >= 0x1f900 and scalar <= 0x1f9ff);
}

test "text width conservative utf8" {
    try std.testing.expectEqual(@as(u21, 'a'), nextScalar("a").scalar);
    try std.testing.expectEqual(@as(u2, 2), scalarWidth(nextScalar("中").scalar));
    try std.testing.expectEqual(replacement, nextScalar("\xff").scalar);
}
