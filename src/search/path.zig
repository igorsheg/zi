const std = @import("std");
const testing = std.testing;

/// Path-aware fuzzy ranking adapted from natecraddock/zf (MIT).
///
/// The algorithm prioritizes basename matches, supports strict path matching
/// when query tokens contain separators, and can return highlight indices for
/// matched characters.
const sep = std.fs.path.sep;

pub const Match = struct {
    matches: bool,
    score: f64,
};

pub const Options = struct {
    case_sensitive: bool = false,
};

pub const Candidate = struct {
    path: []const u8,
    is_directory: bool = false,
};

pub fn rank(query: []const u8, candidate_path: []const u8) Match {
    return rankWithOptions(query, candidate_path, .{});
}

pub fn rankWithOptions(query: []const u8, candidate_path: []const u8, opts: Options) Match {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        return .{ .matches = true, .score = 0 };
    }
    if (candidate_path.len == 0) {
        return .{ .matches = false, .score = 0 };
    }

    var tokens: [64][]const u8 = undefined;
    const token_count = splitTokens(trimmed, &tokens);
    if (token_count == 0) {
        return .{ .matches = true, .score = 0 };
    }

    const filename = std.fs.path.basename(candidate_path);
    var total_score: f64 = 0;
    for (tokens[0..token_count]) |token| {
        const strict_path = hasSeparator(token);
        const token_rank = rankNeedleInternal(candidate_path, filename, token, opts.case_sensitive, strict_path) orelse {
            return .{ .matches = false, .score = 0 };
        };
        total_score += token_rank;
    }

    return .{ .matches = true, .score = total_score };
}

pub fn filter(query: []const u8, paths: []const []const u8, out_indices: []usize) usize {
    return filterWithOptions(query, paths, out_indices, .{});
}

pub fn filterCandidates(query: []const u8, candidates: []const Candidate, out_indices: []usize) usize {
    return filterCandidatesWithOptions(query, candidates, out_indices, .{});
}

pub fn filterWithOptions(query: []const u8, paths: []const []const u8, out_indices: []usize, opts: Options) usize {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        const n = @min(paths.len, out_indices.len);
        for (0..n) |i| out_indices[i] = i;
        return n;
    }

    var scores_buf: [8192]f64 = undefined;
    var count: usize = 0;

    for (paths, 0..) |candidate_path, idx| {
        if (count >= out_indices.len or count >= scores_buf.len) break;

        const match = rankWithOptions(trimmed, candidate_path, opts);
        if (!match.matches) continue;

        out_indices[count] = idx;
        scores_buf[count] = match.score;
        count += 1;
    }

    sortByScore(out_indices[0..count], scores_buf[0..count], paths);
    return count;
}

pub fn filterCandidatesWithOptions(query: []const u8, candidates: []const Candidate, out_indices: []usize, opts: Options) usize {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        const n = @min(candidates.len, out_indices.len);
        for (0..n) |i| out_indices[i] = i;
        return n;
    }

    var scores_buf: [8192]f64 = undefined;
    var count: usize = 0;

    for (candidates, 0..) |candidate, idx| {
        if (count >= out_indices.len or count >= scores_buf.len) break;

        const match = rankWithOptions(trimmed, candidate.path, opts);
        if (!match.matches) continue;

        out_indices[count] = idx;
        scores_buf[count] = adjustedCandidateScore(trimmed, candidate, match.score, opts);
        count += 1;
    }

    sortCandidatesByScore(out_indices[0..count], scores_buf[0..count], candidates);
    return count;
}

pub fn highlight(query: []const u8, candidate_path: []const u8, out_matches: []usize) []const usize {
    return highlightWithOptions(query, candidate_path, out_matches, .{});
}

pub fn highlightWithOptions(query: []const u8, candidate_path: []const u8, out_matches: []usize, opts: Options) []const usize {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0 or candidate_path.len == 0 or out_matches.len == 0) {
        return &.{};
    }

    var tokens: [64][]const u8 = undefined;
    const token_count = splitTokens(trimmed, &tokens);
    if (token_count == 0) return &.{};

    const filename = std.fs.path.basename(candidate_path);
    var match_index: usize = 0;

    for (tokens[0..token_count]) |token| {
        if (match_index >= out_matches.len) break;
        const strict_path = hasSeparator(token);
        const matched = highlightNeedleInternal(
            candidate_path,
            filename,
            token,
            opts.case_sensitive,
            strict_path,
            out_matches[match_index..],
        );
        if (matched.len == 0) return &.{};
        match_index += matched.len;
    }

    if (token_count == 1) {
        return out_matches[0..match_index];
    }

    sortUsizes(out_matches[0..match_index]);
    return deduplicateMatches(out_matches[0..match_index]);
}

fn splitTokens(query: []const u8, tokens: *[64][]const u8) usize {
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (iter.next()) |token| {
        if (count >= tokens.len) break;
        tokens[count] = token;
        count += 1;
    }
    return count;
}

fn hasSeparator(str: []const u8) bool {
    for (str) |byte| {
        if (byte == sep) return true;
    }
    return false;
}

fn indexOf(haystack: []const u8, start_index: usize, needle: u8) ?usize {
    return std.mem.indexOfScalarPos(u8, haystack, start_index, needle);
}

fn indexOfInsensitive(haystack: []const u8, start_index: usize, needle: u8) ?usize {
    const lowered = std.ascii.toLower(needle);
    for (haystack[start_index..], start_index..) |byte, i| {
        if (std.ascii.toLower(byte) == lowered) return i;
    }
    return null;
}

const IndexIterator = struct {
    str: []const u8,
    char: u8,
    index: usize = 0,
    case_sensitive: bool,

    fn init(str: []const u8, char: u8, case_sensitive: bool) @This() {
        return .{ .str = str, .char = char, .case_sensitive = case_sensitive };
    }

    fn next(self: *@This()) ?usize {
        const found = if (self.case_sensitive)
            indexOf(self.str, self.index, self.char)
        else
            indexOfInsensitive(self.str, self.index, self.char);

        if (found) |i| self.index = i + 1;
        return found;
    }
};

const PathIterator = struct {
    str: []const u8,
    index: usize = 0,

    fn init(str: []const u8) @This() {
        return .{ .str = str };
    }

    fn next(self: *@This()) ?[]const u8 {
        if (self.index >= self.str.len) return null;

        const start = self.index;
        if (self.str[self.index] == sep) {
            self.index += 1;
            return self.str[start..self.index];
        }

        while (self.index < self.str.len) : (self.index += 1) {
            if (self.str[self.index] == sep) {
                return self.str[start..self.index];
            }
        }

        return self.str[start..];
    }
};

fn segmentLen(str: []const u8, index: usize) usize {
    if (str[index] == sep) return 1;

    var start = index;
    var end = index;
    while (start > 0) : (start -= 1) {
        if (str[start - 1] == sep) break;
    }
    while (end < str.len and str[end] != sep) : (end += 1) {}
    return end - start;
}

fn rankNeedleInternal(
    haystack: []const u8,
    filename_or_null: ?[]const u8,
    needle: []const u8,
    case_sensitive: bool,
    strict_path: bool,
) ?f64 {
    if (haystack.len == 0 or needle.len == 0) return null;

    var best_rank: ?f64 = null;

    if (strict_path) {
        var iter = PathIterator.init(needle);
        var start: usize = 0;
        while (iter.next()) |segment| {
            var it = IndexIterator.init(haystack, segment[0], case_sensitive);
            it.index = start;
            while (it.next()) |start_index| {
                if (scanToEnd(haystack, segment[1..], start_index, 0, null, case_sensitive, strict_path)) |scan| {
                    const path_segment_len = segmentLen(haystack, start_index);
                    const coverage = 1.0 - (@as(f64, @floatFromInt(segment.len)) / @as(f64, @floatFromInt(path_segment_len)));
                    const segment_rank = coverage * scan.rank;

                    if (best_rank == null) {
                        best_rank = segment_rank;
                    } else {
                        best_rank = best_rank.? + segment_rank;
                    }

                    start = scan.index;
                    break;
                }
            } else return null;
        }
        return best_rank;
    }

    if (filename_or_null) |filename| {
        var it = IndexIterator.init(filename, needle[0], case_sensitive);
        while (it.next()) |start_index| {
            if (scanToEnd(filename, needle[1..], start_index, 0, null, case_sensitive, false)) |scan| {
                if (best_rank == null or scan.rank < best_rank.?) best_rank = scan.rank;
            } else {
                break;
            }
        }

        if (best_rank != null) {
            best_rank.? /= 2.0;
            if (needle.len == filename.len) {
                best_rank.? /= 2.0;
            } else {
                const coverage = 1.0 - (@as(f64, @floatFromInt(needle.len)) / @as(f64, @floatFromInt(filename.len)));
                best_rank.? *= coverage;
            }
            return best_rank;
        }
    }

    var it = IndexIterator.init(haystack, needle[0], case_sensitive);
    while (it.next()) |start_index| {
        if (scanToEnd(haystack, needle[1..], start_index, 0, null, case_sensitive, false)) |scan| {
            if (best_rank == null or scan.rank < best_rank.?) best_rank = scan.rank;
        } else {
            break;
        }
    }

    return best_rank;
}

fn FixedArrayList(comptime T: type) type {
    return struct {
        buffer: []T,
        len: usize = 0,

        fn init(buffer: []T) @This() {
            return .{ .buffer = buffer };
        }

        fn append(self: *@This(), value: T) void {
            if (self.len >= self.buffer.len) return;
            self.buffer[self.len] = value;
            self.len += 1;
        }

        fn clear(self: *@This()) void {
            self.len = 0;
        }

        fn slice(self: @This()) []const T {
            return self.buffer[0..self.len];
        }
    };
}

fn highlightNeedleInternal(
    haystack: []const u8,
    filename_or_null: ?[]const u8,
    needle: []const u8,
    case_sensitive: bool,
    strict_path: bool,
    matches: []usize,
) []const usize {
    if (haystack.len == 0 or needle.len == 0 or matches.len == 0) return &.{};

    var best_rank: ?f64 = null;
    var buf: [1024]usize = undefined;
    var matched = FixedArrayList(usize).init(&buf);
    var best_matched = FixedArrayList(usize).init(matches);

    if (strict_path) {
        var iter = PathIterator.init(needle);
        var start: usize = 0;
        while (iter.next()) |segment| {
            var it = IndexIterator.init(haystack, segment[0], case_sensitive);
            it.index = start;
            while (it.next()) |start_index| {
                matched.append(start_index);

                if (scanToEnd(haystack, segment[1..], start_index, 0, &matched, case_sensitive, strict_path)) |scan| {
                    const path_segment_len = segmentLen(haystack, start_index);
                    const coverage = 1.0 - (@as(f64, @floatFromInt(segment.len)) / @as(f64, @floatFromInt(path_segment_len)));
                    const segment_rank = coverage * scan.rank;

                    if (best_rank == null) {
                        best_rank = segment_rank;
                    } else {
                        best_rank = best_rank.? + segment_rank;
                    }

                    start = scan.index;
                    for (matched.slice()) |index| best_matched.append(index);
                    break;
                } else {
                    matched.clear();
                }
            } else return &.{};

            matched.clear();
        }
        return best_matched.slice();
    }

    if (filename_or_null) |filename| {
        const trailing_sep: usize = if (haystack[haystack.len - 1] == sep) 1 else 0;
        const offset = haystack.len - filename.len - trailing_sep;

        var it = IndexIterator.init(filename, needle[0], case_sensitive);
        while (it.next()) |start_index| {
            matched.append(start_index + offset);

            if (scanToEnd(filename, needle[1..], start_index, offset, &matched, case_sensitive, false)) |scan| {
                if (best_rank == null or scan.rank < best_rank.?) {
                    best_rank = scan.rank;
                    best_matched.clear();
                    for (matched.slice()) |index| best_matched.append(index);
                }
            } else {
                break;
            }
            matched.clear();
        }
        if (best_rank != null) return best_matched.slice();
    }

    matched.clear();

    var it = IndexIterator.init(haystack, needle[0], case_sensitive);
    while (it.next()) |start_index| {
        matched.append(start_index);

        if (scanToEnd(haystack, needle[1..], start_index, 0, &matched, case_sensitive, false)) |scan| {
            if (best_rank == null or scan.rank < best_rank.?) {
                best_rank = scan.rank;
                best_matched.clear();
                for (matched.slice()) |index| best_matched.append(index);
            }
        } else {
            break;
        }
        matched.clear();
    }

    return best_matched.slice();
}

fn isStartOfWord(byte: u8) bool {
    return switch (byte) {
        sep, '_', '-', '.', ' ' => true,
        else => false,
    };
}

const ScanResult = struct {
    rank: f64,
    index: usize,
};

fn scanToEnd(
    haystack: []const u8,
    needle: []const u8,
    start_index: usize,
    offset: usize,
    matched_indices: ?*FixedArrayList(usize),
    case_sensitive: bool,
    strict_path: bool,
) ?ScanResult {
    var rank_score: f64 = 1;
    var last_index = start_index;
    var last_sequential = false;

    if (start_index > 0 and !isStartOfWord(haystack[start_index - 1])) {
        rank_score += 2.0;
    }

    for (needle) |char| {
        const found = if (case_sensitive)
            indexOf(haystack, last_index + 1, char)
        else
            indexOfInsensitive(haystack, last_index + 1, char);

        if (found) |idx| {
            if (strict_path and hasSeparator(haystack[last_index .. idx + 1])) return null;

            if (matched_indices) |matched| matched.append(idx + offset);

            if (idx == last_index + 1) {
                if (!last_sequential) {
                    last_sequential = true;
                    rank_score += 1.0;
                }
            } else {
                if (!isStartOfWord(haystack[idx - 1])) {
                    rank_score += 2.0;
                }
                last_sequential = false;
                rank_score += @as(f64, @floatFromInt(idx - last_index));
            }

            last_index = idx;
        } else {
            return null;
        }
    }

    return .{ .rank = rank_score, .index = last_index + 1 };
}

fn adjustedCandidateScore(query: []const u8, candidate: Candidate, base_score: f64, opts: Options) f64 {
    var score = base_score;
    const basename = std.fs.path.basename(candidate.path);
    const query_basename = std.fs.path.basename(query);

    if (equals(query_basename, basename, opts.case_sensitive)) {
        score -= 100.0;
    } else if (startsWith(basename, query_basename, opts.case_sensitive)) {
        score -= 40.0;
    } else if (contains(basename, query_basename, opts.case_sensitive)) {
        score -= 15.0;
    }

    score += @as(f64, @floatFromInt(separatorCount(candidate.path))) * 0.75;

    if (candidate.is_directory) score -= 3.0;

    return score;
}

fn separatorCount(path_value: []const u8) usize {
    var count: usize = 0;
    for (path_value) |byte| {
        if (byte == sep) count += 1;
    }
    return count;
}

fn equals(a: []const u8, b: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) return std.mem.eql(u8, a, b);
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsWith(haystack: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (needle.len > haystack.len) return false;
    return equals(haystack[0..needle.len], needle, case_sensitive);
}

fn contains(haystack: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (equals(haystack[i..][0..needle.len], needle, case_sensitive)) return true;
    }
    return false;
}

fn sortByScore(indices: []usize, scores: []f64, texts: []const []const u8) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const idx = indices[i];
        const score = scores[i];
        var j: usize = i;
        while (j > 0 and scoreLessThan(score, idx, scores[j - 1], indices[j - 1], texts)) : (j -= 1) {
            indices[j] = indices[j - 1];
            scores[j] = scores[j - 1];
        }
        indices[j] = idx;
        scores[j] = score;
    }
}

fn scoreLessThan(score_a: f64, idx_a: usize, score_b: f64, idx_b: usize, texts: []const []const u8) bool {
    if (score_a < score_b) return true;
    if (score_a > score_b) return false;

    const text_a = if (idx_a < texts.len) texts[idx_a] else "";
    const text_b = if (idx_b < texts.len) texts[idx_b] else "";
    return std.mem.lessThan(u8, text_a, text_b);
}

fn sortCandidatesByScore(indices: []usize, scores: []f64, candidates: []const Candidate) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const idx = indices[i];
        const score = scores[i];
        var j: usize = i;
        while (j > 0 and candidateScoreLessThan(score, idx, scores[j - 1], indices[j - 1], candidates)) : (j -= 1) {
            indices[j] = indices[j - 1];
            scores[j] = scores[j - 1];
        }
        indices[j] = idx;
        scores[j] = score;
    }
}

fn candidateScoreLessThan(score_a: f64, idx_a: usize, score_b: f64, idx_b: usize, candidates: []const Candidate) bool {
    if (score_a < score_b) return true;
    if (score_a > score_b) return false;

    const a = if (idx_a < candidates.len) candidates[idx_a] else Candidate{ .path = "" };
    const b = if (idx_b < candidates.len) candidates[idx_b] else Candidate{ .path = "" };
    if (a.is_directory != b.is_directory) return a.is_directory;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn sortUsizes(values: []usize) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const value = values[i];
        var j: usize = i;
        while (j > 0 and value < values[j - 1]) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = value;
    }
}

fn deduplicateMatches(matches: []usize) []usize {
    if (matches.len < 2) return matches;

    var end: usize = 1;
    for (matches[1..]) |value| {
        if (value != matches[end - 1]) {
            matches[end] = value;
            end += 1;
        }
    }
    return matches[0..end];
}

test "path filter prefers filename matches over path-only matches" {
    const paths = [_][]const u8{
        "source/blender/makesdna/DNA_genfile.h",
        "GNUmakefile",
    };
    var out: [2]usize = undefined;

    const n = filter("make", &paths, &out);

    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), out[0]);
}

test "path rank treats slash-containing query as strict path" {
    try testing.expect(!rank("mod/barbaz", "app/models/foo/bar/baz.rb").matches);
    try testing.expect(rank("mod/baz.rb", "app/models/foo/bar/baz.rb").matches);
}

test "path highlight returns basename match indices" {
    var matches_buf: [16]usize = undefined;
    const matches = highlight("file", "a/path/to/file", &matches_buf);

    try testing.expectEqualSlices(usize, &.{ 10, 11, 12, 13 }, matches);
}

test "path candidate filter boosts exact and prefix basename matches" {
    const candidates = [_]Candidate{
        .{ .path = "deep/path/to/main.zig" },
        .{ .path = "main.zig" },
        .{ .path = "src/domain/index.zig" },
    };
    var out: [3]usize = undefined;

    const n = filterCandidates("main", &candidates, &out);

    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 1), out[0]);
}

test "path candidate filter prefers directory continuation on tie" {
    const candidates = [_]Candidate{
        .{ .path = "src/file", .is_directory = false },
        .{ .path = "src/dir", .is_directory = true },
    };
    var out: [2]usize = undefined;

    const n = filterCandidates("src", &candidates, &out);

    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), out[0]);
}
