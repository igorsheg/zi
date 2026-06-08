const std = @import("std");
const primitive = @import("../primitive/root.zig");

const random_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890";
const empty_char = "-";
pub const reveal_ticks: u64 = 36;

pub fn project(out: []u8, text: []const u8, tick: u64, seed: u32) []const u8 {
    if (out.len == 0 or text.len == 0) return "";
    const grapheme_count = countGraphemes(text);
    if (grapheme_count == 0) return "";

    const phase = @min(tick, reveal_ticks);
    const percent = progressPercent(phase);
    var out_len: usize = 0;
    var index: usize = 0;
    var grapheme_index: usize = 0;
    while (index < text.len) : (grapheme_index += 1) {
        const grapheme = primitive.text.nextGrapheme(text[index..]);
        if (grapheme.end == 0) break;
        const slice = text[index .. index + grapheme.end];
        const reveal = revealAt(grapheme_index, grapheme_count, seed);
        const source = if (percent >= reveal)
            slice
        else if (percent < reveal / 3)
            empty_char
        else
            randomChar(seed, tick, grapheme_index);
        if (source.len > out.len - out_len) break;
        @memcpy(out[out_len..][0..source.len], source);
        out_len += source.len;
        index += grapheme.end;
    }
    return out[0..out_len];
}

fn countGraphemes(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (count += 1) {
        const grapheme = primitive.text.nextGrapheme(text[index..]);
        if (grapheme.end == 0) break;
        index += grapheme.end;
    }
    return count;
}

fn progressPercent(tick: u64) u32 {
    const max = std.math.maxInt(u16);
    return @intCast(@min((tick * max) / reveal_ticks, max));
}

fn revealAt(index: usize, count: usize, seed: u32) u32 {
    const max = std.math.maxInt(u16);
    const rate: u32 = @intCast((index * max) / count);
    const remaining = max - rate;
    const jitter = hash(seed, @intCast(index)) % (remaining + 1);
    return rate + @as(u32, @intCast(jitter));
}

fn randomChar(seed: u32, tick: u64, index: usize) []const u8 {
    const value = hash(seed ^ @as(u32, @truncate(tick)), @intCast(index));
    return random_chars[value % random_chars.len ..][0..1];
}

fn hash(seed: u32, value: u32) usize {
    var x = seed ^ value ^ 0x9e37_79b9;
    x ^= x >> 16;
    x *%= 0x7feb_352d;
    x ^= x >> 15;
    x *%= 0x846c_a68b;
    x ^= x >> 16;
    return x;
}

test "shuffle text is deterministic and bounded" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    const one = project(&a, "model", 3, 7);
    const two = project(&b, "model", 3, 7);
    try std.testing.expectEqualStrings(one, two);
    try std.testing.expect(one.len <= a.len);
}

test "shuffle text starts empty and finishes original" {
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("----", project(&out, "TEXT", 0, 1));
    try std.testing.expectEqualStrings("TEXT", project(&out, "TEXT", reveal_ticks, 1));
}

test "shuffle text output remains valid utf8" {
    var out: [32]u8 = undefined;
    const text = project(&out, "a中e\u{0301}", 12, 1);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
}
