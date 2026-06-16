//! Deterministic text-reveal animation for short status strings.
//!
//! This is deliberately not the stateful widget shape from the sketch: Zi's
//! status store already owns the text and the animation start time. Render can
//! derive each frame from (text, start_ms, now_ms) with no allocation, I/O, or
//! hidden randomness.
const std = @import("std");
const text_mod = @import("text.zig");

pub const Config = struct {
    duration_ms: u64 = 600,
    frame_ms: u64 = 33,
    random_chars: []const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
    empty_char: []const u8 = "-",
    seed: u64 = 0x9e37_79b9_7f4a_7c15,
};

pub const Span = struct {
    start: usize,
    len: usize,

    pub fn bytes(self: Span, source: []const u8) []const u8 {
        return source[self.start .. self.start + self.len];
    }
};

pub fn isRunning(now_ms: i64, start_ms: i64, config: Config) bool {
    if (config.duration_ms == 0) return false;
    const elapsed = elapsedMs(now_ms, start_ms);
    return elapsed <= config.duration_ms + config.frame_ms;
}

pub fn countSpans(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (nextSpan(text, index)) |span| {
        count += 1;
        index = span.start + span.len;
    }
    return count;
}

pub fn nextSpan(text: []const u8, start: usize) ?Span {
    if (start >= text.len) return null;
    const grapheme = text_mod.nextGrapheme(text[start..]);
    if (grapheme.end == 0) return null;
    return .{ .start = start, .len = grapheme.end };
}

pub fn renderedSpan(
    config: Config,
    text: []const u8,
    span: Span,
    span_index: usize,
    span_count: usize,
    now_ms: i64,
    start_ms: i64,
) []const u8 {
    if (span_count == 0 or config.duration_ms == 0) return span.bytes(text);

    const elapsed = elapsedMs(now_ms, start_ms);
    if (elapsed >= config.duration_ms) return span.bytes(text);

    const reveal = revealAt(config.seed, span_index, span_count);
    const percent = progress(elapsed, config.duration_ms);
    if (percent >= reveal) return span.bytes(text);
    if (percent < reveal / 3) return config.empty_char;

    const random_count = countSpans(config.random_chars);
    if (random_count == 0) return config.empty_char;
    const frame = elapsed / @max(config.frame_ms, 1);
    const random_index = boundedHash(config.seed ^ frame, span_index, random_count);
    return spanAt(config.random_chars, random_index) orelse config.empty_char;
}

fn spanAt(text: []const u8, target: usize) ?[]const u8 {
    var index: usize = 0;
    var current: usize = 0;
    while (nextSpan(text, index)) |span| {
        if (current == target) return span.bytes(text);
        current += 1;
        index = span.start + span.len;
    }
    return null;
}

fn revealAt(seed: u64, index: usize, count: usize) u32 {
    if (count == 0) return 0;
    const max = std.math.maxInt(u16);
    const rate: u32 = @intCast((@as(u128, index) * max) / count);
    const remaining = max - rate;
    const jitter = boundedHash(seed, index, remaining + 1);
    return rate + @as(u32, @intCast(jitter));
}

fn progress(elapsed: u64, duration: u64) u32 {
    if (duration == 0 or elapsed >= duration) return std.math.maxInt(u16);
    return @intCast((@as(u128, elapsed) * std.math.maxInt(u16)) / duration);
}

fn elapsedMs(now_ms: i64, start_ms: i64) u64 {
    if (now_ms <= start_ms) return 0;
    return @intCast(now_ms - start_ms);
}

fn boundedHash(seed: u64, value: usize, bound: usize) usize {
    std.debug.assert(bound > 0);
    return @intCast(mix(seed +% @as(u64, @intCast(value))) % bound);
}

fn mix(value: u64) u64 {
    var x = value +% 0x9e37_79b9_7f4a_7c15;
    x = (x ^ (x >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    x = (x ^ (x >> 27)) *% 0x94d0_49bb_1331_11eb;
    return x ^ (x >> 31);
}

test "shuffle text rate limits frames and resolves to original" {
    const config: Config = .{ .seed = 1 };
    const text = "TEXT";
    const first = nextSpan(text, 0).?;
    try std.testing.expectEqualStrings("-", renderedSpan(config, text, first, 0, countSpans(text), 1000, 1000));
    try std.testing.expect(isRunning(1000, 1000, config));
    try std.testing.expectEqualStrings("T", renderedSpan(config, text, first, 0, countSpans(text), 1600, 1000));
    try std.testing.expect(!isRunning(1634, 1000, config));
}

test "shuffle text keeps utf8 random characters intact" {
    const config: Config = .{ .seed = 2, .duration_ms = 1000, .random_chars = "░▒▓█" };
    const text = "abcd";
    const span = nextSpan(text, 2).?;
    const rendered = renderedSpan(config, text, span, 2, countSpans(text), 400, 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(rendered));
}
