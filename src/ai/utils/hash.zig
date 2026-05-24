const std = @import("std");

const base36_digits = "0123456789abcdefghijklmnopqrstuvwxyz";

pub fn shortHash(buffer: []u8, value: []const u8) ![]const u8 {
    var h1: u32 = 0xdeadbeef;
    var h2: u32 = 0x41c6ce57;

    var iterator: std.unicode.Utf8Iterator = .{ .bytes = value, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xFFFF) {
            h1 = hashCodeUnit(h1, @intCast(codepoint), 2_654_435_761);
            h2 = hashCodeUnit(h2, @intCast(codepoint), 1_597_334_677);
        } else {
            const offset = codepoint - 0x10000;
            const high: u16 = @intCast(0xD800 + (offset >> 10));
            const low: u16 = @intCast(0xDC00 + (offset & 0x3FF));
            h1 = hashCodeUnit(h1, high, 2_654_435_761);
            h2 = hashCodeUnit(h2, high, 1_597_334_677);
            h1 = hashCodeUnit(h1, low, 2_654_435_761);
            h2 = hashCodeUnit(h2, low, 1_597_334_677);
        }
    }

    h1 = mix(h1, 16, 2_246_822_507) ^ mix(h2, 13, 3_266_489_909);
    h2 = mix(h2, 16, 2_246_822_507) ^ mix(h1, 13, 3_266_489_909);

    var writer = std.Io.Writer.fixed(buffer);
    try writeBase36(&writer, h2);
    try writeBase36(&writer, h1);
    return writer.buffered();
}

fn hashCodeUnit(hash: u32, code_unit: u16, multiplier: u32) u32 {
    return (hash ^ @as(u32, code_unit)) *% multiplier;
}

fn mix(value: u32, shift: u5, multiplier: u32) u32 {
    return (value ^ (value >> shift)) *% multiplier;
}

fn writeBase36(writer: *std.Io.Writer, value: u32) !void {
    if (value == 0) {
        try writer.writeByte('0');
        return;
    }

    var remaining = value;
    var reversed: [7]u8 = undefined;
    var len: usize = 0;
    while (remaining > 0) {
        reversed[len] = base36_digits[remaining % 36];
        remaining /= 36;
        len += 1;
    }

    while (len > 0) {
        len -= 1;
        try writer.writeByte(reversed[len]);
    }
}

test "short hash matches pi mono output" {
    var buffer: [16]u8 = undefined;

    try std.testing.expectEqualStrings("k4n83c7h0j2b", try shortHash(&buffer, ""));
    try std.testing.expectEqualStrings("1h6qa0qrowduu", try shortHash(&buffer, "hello"));
    try std.testing.expectEqualStrings("y0biex7f9bbh", try shortHash(&buffer, "abc"));
    const pangram = try shortHash(&buffer, "The quick brown fox jumps over the lazy dog");
    try std.testing.expectEqualStrings("eig47k1th3xf1", pangram);
    try std.testing.expectEqualStrings("kphsz0153ms3q", try shortHash(&buffer, "🙈"));
}
