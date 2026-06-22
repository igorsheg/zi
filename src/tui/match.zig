//! Deterministic allocation-free candidate matching for picker-style UI.
//! This is a text primitive, not an autocomplete service: owners provide
//! candidates, keep bounds, and decide what selection means.
const std = @import("std");

pub const Score = struct {
    /// Lower is better.
    value: u32,
    first_match: u16,
    last_match: u16,
};

const exact_base: u32 = 0;
const prefix_base: u32 = 100;
const boundary_prefix_base: u32 = 240;
const fuzzy_base: i64 = 1000;

pub fn score(candidate: []const u8, query: []const u8) ?Score {
    if (query.len == 0) return .{ .value = 0, .first_match = 0, .last_match = 0 };
    if (candidate.len == 0) return null;

    if (asciiEql(candidate, query)) {
        const last = @min(candidate.len - 1, std.math.maxInt(u16));
        return .{ .value = exact_base, .first_match = 0, .last_match = @intCast(last) };
    }
    if (startsWith(candidate, query)) {
        return .{
            .value = prefix_base + lengthPenalty(candidate.len),
            .first_match = 0,
            .last_match = lastQueryByte(query),
        };
    }
    if (boundaryPrefix(candidate, query)) |start| {
        return .{
            .value = boundary_prefix_base + positionPenalty(start) + lengthPenalty(candidate.len),
            .first_match = clampIndex(start),
            .last_match = clampIndex(start + query.len - 1),
        };
    }
    return fuzzyScore(candidate, query);
}

pub fn lessThan(a: Score, b: Score) bool {
    if (a.value != b.value) return a.value < b.value;
    if (a.first_match != b.first_match) return a.first_match < b.first_match;
    return a.last_match < b.last_match;
}

fn fuzzyScore(candidate: []const u8, query: []const u8) ?Score {
    var query_index: usize = 0;
    var first_match: ?usize = null;
    var last_match: ?usize = null;
    var gap_sum: usize = 0;
    var contiguous: usize = 0;
    var boundary_hits: usize = 0;

    for (candidate, 0..) |byte, index| {
        if (query_index >= query.len) break;
        if (asciiLower(byte) != asciiLower(query[query_index])) continue;

        if (first_match == null) first_match = index;
        if (isBoundaryAt(candidate, index)) boundary_hits += 1;
        if (last_match) |last| {
            const gap = index - last - 1;
            gap_sum += gap;
            if (gap == 0) contiguous += 1;
        }
        last_match = index;
        query_index += 1;
    }
    if (query_index != query.len) return null;

    const first = first_match.?;
    const last = last_match.?;
    const span = last - first + 1;
    var value: i64 = fuzzy_base;
    value += @as(i64, @intCast(first)) * 8;
    value += @as(i64, @intCast(gap_sum)) * 12;
    value += @as(i64, @intCast(span)) * 2;
    value += @as(i64, @intCast(candidate.len));
    value -= @as(i64, @intCast(boundary_hits)) * 32;
    value -= @as(i64, @intCast(contiguous)) * 24;
    if (value < 0) value = 0;

    return .{
        .value = @intCast(@min(value, std.math.maxInt(u32))),
        .first_match = clampIndex(first),
        .last_match = clampIndex(last),
    };
}

fn boundaryPrefix(candidate: []const u8, query: []const u8) ?usize {
    var index: usize = 1;
    while (index < candidate.len) : (index += 1) {
        if (!isBoundaryAt(candidate, index)) continue;
        if (startsWith(candidate[index..], query)) return index;
    }
    return null;
}

fn isBoundaryAt(bytes: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = bytes[index - 1];
    if (previous == '/' or previous == '-' or previous == '_' or previous == '.' or
        previous == ':' or previous == ' ' or previous == '@') return true;
    const current = bytes[index];
    return std.ascii.isLower(previous) and std.ascii.isUpper(current);
}

fn startsWith(candidate: []const u8, query: []const u8) bool {
    if (query.len > candidate.len) return false;
    return asciiEql(candidate[0..query.len], query);
}

fn asciiEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (asciiLower(left) != asciiLower(right)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return std.ascii.toLower(byte);
}

fn lastQueryByte(query: []const u8) u16 {
    return clampIndex(query.len - 1);
}

fn positionPenalty(index: usize) u32 {
    return @intCast(@min(index * 2, std.math.maxInt(u32)));
}

fn lengthPenalty(len: usize) u32 {
    return @intCast(@min(len / 2, std.math.maxInt(u32)));
}

fn clampIndex(index: usize) u16 {
    return @intCast(@min(index, std.math.maxInt(u16)));
}

test "score ranks exact prefix boundary and fuzzy matches" {
    const exact = score("model", "model").?;
    const prefix = score("model", "mod").?;
    const boundary = score("openai/gpt-5.1", "gpt").?;
    const fuzzy = score("openai/gpt-5.1", "g51").?;

    try std.testing.expect(lessThan(exact, prefix));
    try std.testing.expect(lessThan(prefix, boundary));
    try std.testing.expect(lessThan(boundary, fuzzy));
}

test "score rejects non-subsequence queries" {
    try std.testing.expect(score("model", "xyz") == null);
}

test "score prefers contiguous and earlier fuzzy matches" {
    const contiguous = score("model", "mod").?;
    const scattered = score("m_o_d", "mod").?;
    const early = score("model", "mdl").?;
    const late = score("xxmodel", "mdl").?;

    try std.testing.expect(lessThan(contiguous, scattered));
    try std.testing.expect(lessThan(early, late));
}

test "score supports model and file shaped queries" {
    try std.testing.expect(score("openai/gpt-5.1", "g51") != null);
    try std.testing.expect(score("src/tui/App.zig", "app") != null);
    try std.testing.expect(lessThan(
        score("src/tui/App.zig", "app").?,
        score("src/trap-plan.zig", "app").?,
    ));
}

test "score is ascii case insensitive" {
    try std.testing.expect(score("src/tui/App.zig", "APP") != null);
    try std.testing.expectEqual(@as(u32, 0), score("HELP", "help").?.value);
}
