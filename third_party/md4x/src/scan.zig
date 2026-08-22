// MD4X — vectorized byte scanning.
//
// Every hot loop in the parser and the renderers has the same shape: walk
// forward over a buffer until a byte from a small, comptime-known set turns up.
// `indexOfAnyPos` is that loop, written once, widened to the target's native
// vector width when there is one.
//
// The width comes from `std.simd.suggestVectorLength(u8)`, which returns null
// on targets with no usable vector unit — notably `wasm32` without the
// `simd128` feature, which is exactly how this project builds its WASM. That
// null case matters: a hand-written `@Vector(16, u8)` there does NOT degrade to
// the scalar loop, it gets *scalarized* by LLVM into 16 unconditional compares
// with no early exit, which is strictly worse than just reading a byte at a
// time. So the vector body must be gated on the optional actually being
// non-null, never written unconditionally. Measured: enabling `simd128` on the
// WASM target buys nothing (the bottleneck there is the linear-memory allocator
// and the JS boundary copy, not scanning) and costs up to 6% on
// `renderToHtml`, so the WASM target deliberately stays scalar.
//
// A single-byte needle should use `std.mem.indexOfScalarPos` instead — std has
// its own vectorized implementation for that case. This helper exists for the
// multi-byte sets std can only scan scalar-wise (`std.mem.indexOfAnyPos` walks
// the needle set per input byte).

const std = @import("std");

/// True when `ch` is one of `bytes`, or below `lt` when `lt` is given.
pub inline fn matches(comptime bytes: []const u8, comptime lt: ?u8, ch: u8) bool {
    return lookupTable(bytes, lt)[ch];
}

/// The predicate as a 256-entry table, built at comptime.
///
/// The scalar path must be a **single indexed load**, not a chain of compares.
/// It is not just a leftover tail: on a target with no vector unit (the WASM
/// build) it is the entire scan. Spelling the four HTML-escape bytes as four
/// sequential compares there measured ~10% slower on `renderToHtml` than the
/// `ESCAPE_MAP` lookup it replaced — the cost grows with the size of the byte
/// set, which is exactly backwards. One load is O(1) in the set size.
fn lookupTable(comptime bytes: []const u8, comptime lt: ?u8) *const [256]bool {
    return &struct {
        const table: [256]bool = blk: {
            var t = [_]bool{false} ** 256;
            for (bytes) |b| t[b] = true;
            if (lt) |threshold| {
                for (0..threshold) |i| t[i] = true;
            }
            break :blk t;
        };
    }.table;
}

/// Index of the first byte in `data[start..len]` satisfying `matches`, or `len`
/// if there is none. Reads only within `[start, len)` — `data` needs no NUL
/// terminator and is never over-read, which is what lets this replace the
/// `strcspn()` call the parser used to make on a non-NUL-terminated buffer.
pub inline fn indexOfAnyPos(
    comptime bytes: []const u8,
    comptime lt: ?u8,
    data: [*]const u8,
    start: usize,
    len: usize,
) usize {
    var off = start;

    if (std.simd.suggestVectorLength(u8)) |V| {
        const Vec = @Vector(V, u8);
        while (off + V <= len) : (off += V) {
            const chunk: Vec = @as(*const [V]u8, @ptrCast(data + off)).*;
            var hit: @Vector(V, bool) = @splat(false);
            inline for (bytes) |b| {
                hit = hit | (chunk == @as(Vec, @splat(b)));
            }
            if (lt) |threshold| {
                hit = hit | (chunk < @as(Vec, @splat(threshold)));
            }
            if (@reduce(.Or, hit)) return off + std.simd.firstTrue(hit).?;
        }
    }

    // Tail — and the whole scan on targets with no vector unit, which is why
    // this is a table lookup rather than a compare chain (see lookupTable) and
    // why it is unrolled. The loop this replaced in `md_analyze_line` was
    // hand-unrolled by 4; dropping that cost the WASM build several percent on
    // `renderToHtml` / `renderToText` under JavaScriptCore, which does not
    // recover it on its own.
    const table = lookupTable(bytes, lt);
    while (off + 4 <= len and !table[data[off]] and !table[data[off + 1]] and
        !table[data[off + 2]] and !table[data[off + 3]]) off += 4;
    while (off < len and !table[data[off]]) off += 1;
    return off;
}

test "indexOfAnyPos matches the scalar predicate at every length and position" {
    // Cover every alignment of the needle relative to the vector stride, plus
    // buffers shorter than one stride (tail-only) and needle-free buffers.
    var buf: [200]u8 = undefined;
    for (&buf) |*b| b.* = 'a';

    for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 199 }) |len| {
        // No match anywhere -> len.
        try std.testing.expectEqual(len, indexOfAnyPos("\r\n", null, &buf, 0, len));

        var pos: usize = 0;
        while (pos < len) : (pos += 1) {
            buf[pos] = '\n';
            try std.testing.expectEqual(pos, indexOfAnyPos("\r\n", null, &buf, 0, len));
            // Starting past the needle must skip it.
            try std.testing.expectEqual(len, indexOfAnyPos("\r\n", null, &buf, pos + 1, len));
            buf[pos] = 'a';
        }
    }
}

test "indexOfAnyPos honours the `lt` threshold" {
    var buf: [64]u8 = undefined;
    for (&buf) |*b| b.* = 'x';
    buf[40] = 0x07; // control char, below the threshold but in no byte set

    try std.testing.expectEqual(@as(usize, 40), indexOfAnyPos("\"\\", 0x20, &buf, 0, buf.len));
    try std.testing.expectEqual(@as(usize, buf.len), indexOfAnyPos("\"\\", null, &buf, 0, buf.len));

    buf[10] = '\\';
    try std.testing.expectEqual(@as(usize, 10), indexOfAnyPos("\"\\", 0x20, &buf, 0, buf.len));
}
