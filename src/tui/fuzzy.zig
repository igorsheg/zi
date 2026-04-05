const std = @import("std");

pub const FuzzyMatch = struct {
    matches: bool,
    score: f64,
};

/// Fuzzy match a query against text. All query chars must appear in order (subsequence).
/// Lower score = better match.
pub fn fuzzyMatch(query: []const u8, text: []const u8) FuzzyMatch {
    var query_lower_buf: [1024]u8 = undefined;
    var text_lower_buf: [4096]u8 = undefined;

    if (query.len > query_lower_buf.len or text.len > text_lower_buf.len) {
        return .{ .matches = false, .score = 0 };
    }

    const query_lower = toLowerSlice(query, &query_lower_buf);
    const text_lower = toLowerSlice(text, &text_lower_buf);

    const primary = matchQuery(query_lower, text_lower);
    if (primary.matches) return primary;

    var swapped_buf: [1024]u8 = undefined;
    if (buildSwappedQuery(query_lower, &swapped_buf)) |swapped| {
        const swapped_match = matchQuery(swapped, text_lower);
        if (swapped_match.matches) {
            return .{ .matches = true, .score = swapped_match.score + 5 };
        }
    }

    return primary;
}

/// Filter and sort items by fuzzy match quality. Returns number of matched indices written to out_indices.
/// Supports space-separated tokens: ALL tokens must match.
pub fn fuzzyFilter(
    query: []const u8,
    texts: []const []const u8,
    out_indices: []usize,
) usize {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        const n = @min(texts.len, out_indices.len);
        for (0..n) |i| out_indices[i] = i;
        return n;
    }

    var tokens: [64][]const u8 = undefined;
    var token_count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (iter.next()) |tok| {
        if (token_count >= tokens.len) break;
        tokens[token_count] = tok;
        token_count += 1;
    }

    if (token_count == 0) {
        const n = @min(texts.len, out_indices.len);
        for (0..n) |i| out_indices[i] = i;
        return n;
    }

    var scores_buf: [8192]f64 = undefined;
    var count: usize = 0;

    for (texts, 0..) |text, idx| {
        if (count >= out_indices.len or count >= scores_buf.len) break;

        var total_score: f64 = 0;
        var all_match = true;

        for (tokens[0..token_count]) |token| {
            const m = fuzzyMatch(token, text);
            if (m.matches) {
                total_score += m.score;
            } else {
                all_match = false;
                break;
            }
        }

        if (all_match) {
            out_indices[count] = idx;
            scores_buf[count] = total_score;
            count += 1;
        }
    }

    sortByScore(out_indices[0..count], scores_buf[0..count]);
    return count;
}

// --- internals ---

fn matchQuery(query_lower: []const u8, text_lower: []const u8) FuzzyMatch {
    if (query_lower.len == 0) return .{ .matches = true, .score = 0 };
    if (query_lower.len > text_lower.len) return .{ .matches = false, .score = 0 };

    var query_index: usize = 0;
    var score: f64 = 0;
    var last_match_index: ?usize = null;
    var consecutive_matches: f64 = 0;

    for (text_lower, 0..) |ch, i| {
        if (query_index >= query_lower.len) break;

        if (ch == query_lower[query_index]) {
            const is_word_boundary = (i == 0) or isWordBoundaryChar(text_lower[i - 1]);

            if (last_match_index) |lmi| {
                if (lmi == i - 1) {
                    consecutive_matches += 1;
                    score -= consecutive_matches * 5;
                } else {
                    consecutive_matches = 0;
                    score += @as(f64, @floatFromInt(i - lmi - 1)) * 2;
                }
            } else {
                consecutive_matches = 0;
            }

            if (is_word_boundary) {
                score -= 10;
            }

            score += @as(f64, @floatFromInt(i)) * 0.1;

            last_match_index = i;
            query_index += 1;
        }
    }

    if (query_index < query_lower.len) {
        return .{ .matches = false, .score = 0 };
    }

    return .{ .matches = true, .score = score };
}

fn isWordBoundaryChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '-', '_', '.', '/', ':' => true,
        else => false,
    };
}

fn toLowerSlice(src: []const u8, buf: []u8) []const u8 {
    const len = @min(src.len, buf.len);
    for (0..len) |i| {
        buf[i] = std.ascii.toLower(src[i]);
    }
    return buf[0..len];
}

/// If query matches `[a-z]+[0-9]+` or `[0-9]+[a-z]+`, write the swapped form into buf.
/// Returns the swapped slice, or null if pattern doesn't match.
fn buildSwappedQuery(query: []const u8, buf: []u8) ?[]const u8 {
    if (query.len == 0 or query.len > buf.len) return null;

    var split: usize = 0;

    if (std.ascii.isAlphabetic(query[0])) {
        while (split < query.len and std.ascii.isAlphabetic(query[split])) : (split += 1) {}
        if (split == 0 or split == query.len) return null;
        for (query[split..]) |c| {
            if (!std.ascii.isDigit(c)) return null;
        }
    } else if (std.ascii.isDigit(query[0])) {
        while (split < query.len and std.ascii.isDigit(query[split])) : (split += 1) {}
        if (split == 0 or split == query.len) return null;
        for (query[split..]) |c| {
            if (!std.ascii.isAlphabetic(c)) return null;
        }
    } else {
        return null;
    }

    const second_part = query[split..];
    const first_part = query[0..split];
    @memcpy(buf[0..second_part.len], second_part);
    @memcpy(buf[second_part.len..][0..first_part.len], first_part);
    return buf[0..query.len];
}

fn sortByScore(indices: []usize, scores: []f64) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const idx = indices[i];
        const sc = scores[i];
        var j: usize = i;
        while (j > 0 and scores[j - 1] > sc) : (j -= 1) {
            indices[j] = indices[j - 1];
            scores[j] = scores[j - 1];
        }
        indices[j] = idx;
        scores[j] = sc;
    }
}

// ── Tests ──

test "fuzzyMatch exact match" {
    const m = fuzzyMatch("abc", "abc");
    try std.testing.expect(m.matches);
    try std.testing.expect(m.score < 0);
}

test "fuzzyMatch subsequence" {
    const m = fuzzyMatch("ac", "abc");
    try std.testing.expect(m.matches);
}

test "fuzzyMatch no match" {
    const m = fuzzyMatch("z", "abc");
    try std.testing.expect(!m.matches);
}

test "fuzzyMatch case insensitive" {
    const m = fuzzyMatch("ABC", "abc");
    try std.testing.expect(m.matches);
}

test "fuzzyMatch word boundary bonus" {
    const boundary = fuzzyMatch("fb", "foo-bar");
    const no_boundary = fuzzyMatch("fb", "fxxbxx");
    try std.testing.expect(boundary.matches);
    try std.testing.expect(no_boundary.matches);
    try std.testing.expect(boundary.score < no_boundary.score);
}

test "fuzzyMatch consecutive bonus" {
    const consecutive = fuzzyMatch("abc", "abcdef");
    const scattered = fuzzyMatch("abc", "axbxcx");
    try std.testing.expect(consecutive.matches);
    try std.testing.expect(scattered.matches);
    try std.testing.expect(consecutive.score < scattered.score);
}

test "fuzzyFilter multi-token" {
    const texts = [_][]const u8{ "foobar", "foo", "bar" };
    var out: [3]usize = undefined;
    const n = fuzzyFilter("foo bar", &texts, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 0), out[0]);
}

test "fuzzyFilter sorts by score" {
    const texts = [_][]const u8{ "xxabcxx", "abc", "xaxbxc" };
    var out: [3]usize = undefined;
    const n = fuzzyFilter("abc", &texts, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 1), out[0]);
}

test "fuzzyFilter empty query returns all" {
    const texts = [_][]const u8{ "a", "b", "c" };
    var out: [3]usize = undefined;
    const n = fuzzyFilter("", &texts, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
}
