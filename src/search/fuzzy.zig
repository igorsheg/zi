const std = @import("std");
const query_mod = @import("query.zig");

pub const Query = query_mod.Query;
pub const Token = query_mod.Token;
pub const Options = query_mod.Options;

pub const FuzzyMatch = struct {
    matches: bool,
    score: i32,
};

pub const Match = FuzzyMatch;

const score_match: i32 = 16;
const score_gap_start: i32 = -3;
const score_gap_extension: i32 = -1;
const bonus_boundary: i32 = score_match / 2;
const bonus_nonword: i32 = score_match / 2;
const bonus_camel_123: i32 = bonus_boundary - 1;
const bonus_consecutive: i32 = -(score_gap_start + score_gap_extension);
const bonus_first_char_multiplier: i32 = 2;

const CharClass = enum(u8) { white, nonword, delimiter, lower, upper, letter, number };

pub const Field = struct {
    name: []const u8,
    text: []const u8,
    weight: i32 = 0,
};

pub fn parse(query: []const u8, opts: Options) Query {
    return query_mod.parse(query, opts);
}

/// Fuzzy match a query against text. Higher score is better.
pub fn fuzzyMatch(query: []const u8, text: []const u8) FuzzyMatch {
    return match(query, text);
}

pub fn match(query: []const u8, text: []const u8) FuzzyMatch {
    return matchWithOptions(query, text, .{});
}

pub fn matchWithOptions(pattern: []const u8, text: []const u8, opts: Options) FuzzyMatch {
    const q = parse(pattern, opts);
    return matchParsed(&q, text);
}

pub fn matchParsed(q: *const Query, text: []const u8) FuzzyMatch {
    if (q.empty) return .{ .matches = true, .score = 0 };
    return matchFieldsParsed(q, &.{.{ .name = "text", .text = text }});
}

pub fn matchFields(pattern: []const u8, fields: []const Field) FuzzyMatch {
    const q = parse(pattern, .{});
    return matchFieldsParsed(&q, fields);
}

pub fn matchFieldsParsed(q: *const Query, fields: []const Field) FuzzyMatch {
    if (q.empty) return .{ .matches = true, .score = 0 };
    var total: i32 = 0;
    for (q.slice()) |clause| {
        var best: ?i32 = null;
        for (clause.slice()) |tok| {
            const tok_match = matchTokenAcrossFields(tok, fields);
            if (tok.inverse) {
                if (tok_match.matches) return .{ .matches = false, .score = 0 };
                best = @max(best orelse 0, 1);
            } else if (tok_match.matches) {
                best = @max(best orelse tok_match.score, tok_match.score);
            }
        }
        if (best) |score| total += score else return .{ .matches = false, .score = 0 };
    }
    return .{ .matches = true, .score = total };
}

fn matchTokenAcrossFields(tok: Token, fields: []const Field) FuzzyMatch {
    var best: ?i32 = null;
    for (fields) |field| {
        if (tok.field) |want| if (!std.mem.eql(u8, want, field.name)) continue;
        const m = matchToken(tok, field.text);
        if (m.matches) best = @max(best orelse m.score, m.score + field.weight);
    }
    if (best) |score| return .{ .matches = true, .score = score };
    return .{ .matches = false, .score = 0 };
}

pub fn matchToken(tok: Token, text: []const u8) FuzzyMatch {
    return switch (tok.mode) {
        .fuzzy => fuzzyToken(tok.text, text, tok.ignore_case, null),
        .exact => exactToken(tok.text, text, tok.ignore_case, .any),
        .word => exactToken(tok.text, text, tok.ignore_case, .word),
        .prefix => exactToken(tok.text, text, tok.ignore_case, .prefix),
        .suffix => exactToken(tok.text, text, tok.ignore_case, .suffix),
    };
}

const ExactMode = enum { any, word, prefix, suffix };

fn exactToken(needle: []const u8, haystack: []const u8, ignore_case: bool, mode: ExactMode) FuzzyMatch {
    if (needle.len == 0) return .{ .matches = true, .score = 0 };
    if (needle.len > haystack.len) return .{ .matches = false, .score = 0 };
    var start: usize = 0;
    while (indexOfSlice(haystack, needle, start, ignore_case)) |from| {
        const to = from + needle.len;
        const ok = switch (mode) {
            .any => true,
            .prefix => from == 0,
            .suffix => to == haystack.len,
            .word => isLeftBoundary(haystack, from) and isRightBoundary(haystack, to),
        };
        if (ok) return .{ .matches = true, .score = scoreExact(haystack, from, to) };
        start = from + 1;
    }
    return .{ .matches = false, .score = 0 };
}

fn fuzzyToken(needle: []const u8, haystack: []const u8, ignore_case: bool, out_positions: ?[]usize) FuzzyMatch {
    if (needle.len == 0) return .{ .matches = true, .score = 0 };
    if (needle.len > haystack.len) return .{ .matches = false, .score = 0 };

    var best_score: ?i32 = null;
    var best_pos_buf: [256]usize = undefined;
    var tmp_pos_buf: [256]usize = undefined;
    var start: usize = 0;
    while (indexOfChar(haystack, needle[0], start, ignore_case)) |from| {
        if (scanAndScore(needle, haystack, from, ignore_case, &tmp_pos_buf)) |score| {
            if (best_score == null or score > best_score.?) {
                best_score = score;
                const n = @min(needle.len, best_pos_buf.len);
                @memcpy(best_pos_buf[0..n], tmp_pos_buf[0..n]);
            }
        }
        start = from + 1;
    }

    if (best_score) |score| {
        if (out_positions) |out| {
            const n = @min(@min(needle.len, out.len), best_pos_buf.len);
            @memcpy(out[0..n], best_pos_buf[0..n]);
        }
        return .{ .matches = true, .score = score };
    }
    return .{ .matches = false, .score = 0 };
}

pub fn positions(pattern: []const u8, text: []const u8, out_positions: []usize) []const usize {
    const q = parse(pattern, .{});
    if (q.len != 1 or q.clauses[0].len != 1) return &.{};
    const tok = q.clauses[0].alts[0];
    if (tok.inverse) return &.{};
    if (tok.mode == .fuzzy) {
        const m = fuzzyToken(tok.text, text, tok.ignore_case, out_positions);
        return if (m.matches) out_positions[0..@min(tok.text.len, out_positions.len)] else &.{};
    }
    const m = matchToken(tok, text);
    if (!m.matches) return &.{};
    // Minimal fallback: exact positions are omitted until a renderer needs them.
    return &.{};
}

fn scanAndScore(needle: []const u8, haystack: []const u8, first: usize, ignore_case: bool, positions_buf: []usize) ?i32 {
    var score: i32 = 0;
    var prev: ?usize = null;
    var prev_class: CharClass = if (first == 0) .delimiter else classify(haystack[first - 1]);
    var consecutive: u32 = 0;
    var first_bonus: i32 = 0;
    var last = first;

    for (needle, 0..) |c, i| {
        const pos = if (i == 0) first else indexOfChar(haystack, c, last + 1, ignore_case) orelse return null;
        if (i < positions_buf.len) positions_buf[i] = pos;
        const class = classify(haystack[pos]);
        var bonus = bonusFor(prev_class, class);
        const gap: usize = if (prev) |p| pos - p - 1 else 0;
        if (gap > 0) {
            prev_class = classify(haystack[pos - 1]);
            bonus = bonusFor(prev_class, class);
            score += score_gap_start + @as(i32, @intCast(gap - 1)) * score_gap_extension;
            consecutive = 0;
            first_bonus = 0;
        } else {
            if (consecutive == 0) {
                first_bonus = bonus;
            } else {
                if (bonus >= bonus_boundary and bonus > first_bonus) first_bonus = bonus;
                bonus = @max(@max(bonus, first_bonus), bonus_consecutive);
            }
            consecutive += 1;
        }
        if (prev == null) bonus *= bonus_first_char_multiplier;
        score += score_match + bonus;
        prev_class = class;
        prev = pos;
        last = pos;
    }
    return score;
}

fn scoreExact(haystack: []const u8, from: usize, to: usize) i32 {
    var score: i32 = @as(i32, @intCast(to - from)) * score_match;
    if (isLeftBoundary(haystack, from)) score += bonus_boundary * bonus_first_char_multiplier;
    if (from == 0) score += 8;
    if (to == haystack.len) score += 4;
    return score;
}

fn classify(c: u8) CharClass {
    if (std.ascii.isWhitespace(c)) return .white;
    if (c == '/' or c == '\\' or c == ',' or c == ':' or c == ';' or c == '|' or c == '.' or c == '_' or c == '-') return .delimiter;
    if (std.ascii.isDigit(c)) return .number;
    if (std.ascii.isLower(c)) return .lower;
    if (std.ascii.isUpper(c)) return .upper;
    if (std.ascii.isAlphabetic(c)) return .letter;
    return .nonword;
}

fn bonusFor(prev: CharClass, cur: CharClass) i32 {
    return switch (prev) {
        .white => bonus_boundary,
        .delimiter => bonus_boundary,
        .nonword => bonus_nonword,
        .lower => if (cur == .upper or cur == .number) bonus_camel_123 else 0,
        .upper => if (cur == .number) bonus_camel_123 else 0,
        .letter => if (cur == .number) bonus_camel_123 else 0,
        .number => if (cur == .upper or cur == .lower or cur == .letter) bonus_camel_123 else 0,
    };
}

fn isLeftBoundary(s: []const u8, pos: usize) bool {
    return pos == 0 or bonusFor(classify(s[pos - 1]), classify(s[pos])) > 0;
}

fn isRightBoundary(s: []const u8, pos: usize) bool {
    return pos >= s.len or !isWord(s[pos]);
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn eqChar(a: u8, b: u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

fn indexOfChar(haystack: []const u8, needle: u8, start: usize, ignore_case: bool) ?usize {
    if (start >= haystack.len) return null;
    for (haystack[start..], start..) |c, i| if (eqChar(c, needle, ignore_case)) return i;
    return null;
}

fn indexOfSlice(haystack: []const u8, needle: []const u8, start: usize, ignore_case: bool) ?usize {
    if (needle.len == 0) return start;
    if (needle.len > haystack.len or start > haystack.len - needle.len) return null;
    var i = start;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| if (!eqChar(haystack[i + j], c, ignore_case)) { ok = false; break; };
        if (ok) return i;
    }
    return null;
}

pub fn fuzzyFilter(query: []const u8, texts: []const []const u8, out_indices: []usize) usize {
    return filter(query, texts, out_indices);
}

pub fn filter(query: []const u8, texts: []const []const u8, out_indices: []usize) usize {
    const q = parse(query, .{});
    if (q.empty) {
        const n = @min(texts.len, out_indices.len);
        for (0..n) |i| out_indices[i] = i;
        return n;
    }
    var scores: [8192]i32 = undefined;
    var count: usize = 0;
    for (texts, 0..) |text, idx| {
        if (count >= out_indices.len or count >= scores.len) break;
        const m = matchParsed(&q, text);
        if (!m.matches) continue;
        out_indices[count] = idx;
        scores[count] = m.score;
        count += 1;
    }
    sortByScore(out_indices[0..count], scores[0..count], texts);
    return count;
}

pub fn filterFields(query: []const u8, rows: []const []const Field, out_indices: []usize) usize {
    const q = parse(query, .{});
    if (q.empty) {
        const n = @min(rows.len, out_indices.len);
        for (0..n) |i| out_indices[i] = i;
        return n;
    }
    var scores: [8192]i32 = undefined;
    var count: usize = 0;
    for (rows, 0..) |fields, idx| {
        if (count >= out_indices.len or count >= scores.len) break;
        const m = matchFieldsParsed(&q, fields);
        if (!m.matches) continue;
        out_indices[count] = idx;
        scores[count] = m.score;
        count += 1;
    }
    sortIndicesByScore(out_indices[0..count], scores[0..count]);
    return count;
}

fn sortByScore(indices: []usize, scores: []i32, texts: []const []const u8) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const idx = indices[i];
        const score = scores[i];
        var j = i;
        while (j > 0 and (score > scores[j - 1] or (score == scores[j - 1] and std.mem.lessThan(u8, texts[idx], texts[indices[j - 1]])))) : (j -= 1) {
            indices[j] = indices[j - 1];
            scores[j] = scores[j - 1];
        }
        indices[j] = idx;
        scores[j] = score;
    }
}

fn sortIndicesByScore(indices: []usize, scores: []i32) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const idx = indices[i];
        const score = scores[i];
        var j = i;
        while (j > 0 and score > scores[j - 1]) : (j -= 1) {
            indices[j] = indices[j - 1];
            scores[j] = scores[j - 1];
        }
        indices[j] = idx;
        scores[j] = score;
    }
}

test "fuzzyMatch accepts case-insensitive ordered subsequences and rejects misses" {
    try std.testing.expect(fuzzyMatch("abc", "ABC").matches);
    try std.testing.expect(fuzzyMatch("ac", "abc").matches);
    try std.testing.expect(!fuzzyMatch("z", "abc").matches);
}

test "fuzzy ranks boundaries, camelcase and consecutive chunks" {
    try std.testing.expect(match("fb", "foo-bar").score > match("fb", "fxxbxx").score);
    try std.testing.expect(match("fb", "FooBar").score > match("fb", "f very long b").score);
    try std.testing.expect(match("abc", "abcdef").score > match("abc", "axbxcx").score);
}

test "filter supports AND OR inverse exact prefix suffix" {
    const items = [_][]const u8{ "foo_test", "bar_prod", "baz_prod", "prelude", "the end" };
    var out: [items.len]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), filter("^foo | ^bar", &items, &out));
    try std.testing.expectEqual(@as(usize, 2), filter("prod !foo", &items, &out));
    try std.testing.expectEqual(@as(usize, 1), filter("^pre", &items, &out));
    try std.testing.expectEqual(@as(usize, 1), filter("end$", &items, &out));
    try std.testing.expectEqual(@as(usize, 1), filter("'foo", &items, &out));
}
