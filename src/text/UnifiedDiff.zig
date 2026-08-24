const std = @import("std");
const Utf8 = @import("Utf8.zig");

const context_lines: usize = 3;
const window_slack_lines: usize = 64;
const region_steps_min: isize = 64;
const region_steps_max: isize = 1024;
const maximum_input_bytes: usize = 16 * 1024 * 1024;
const maximum_detailed_lines: usize = 262_144;
// hax permits 2^28 comparisons. Zi narrows this retained-work budget; exhaustion
// takes the same hax coarse-region fallback and still emits a valid bounded diff.
const work_limit: usize = 32 * 1024 * 1024;

pub const Error = error{
    OutOfMemory,
    ResultTooLarge,
};

const Side = struct {
    data: []const u8,
    offsets: []u32,
    hashes: []u32,
    count: usize,

    fn init(allocator: std.mem.Allocator, data: []const u8) Error!Side {
        const count = logicalLineCount(data);
        if (data.len > std.math.maxInt(u32)) return error.ResultTooLarge;
        const metadata_count = std.math.add(usize, count, 1) catch return error.ResultTooLarge;
        const offsets = try allocator.alloc(u32, metadata_count);
        errdefer allocator.free(offsets);
        const hashes = try allocator.alloc(u32, metadata_count);
        errdefer allocator.free(hashes);

        offsets[0] = 0;
        var at: usize = 1;
        if (data.len > 1) {
            for (data[0 .. data.len - 1], 0..) |byte, index| {
                if (byte == '\n') {
                    offsets[at] = @intCast(index + 1);
                    at += 1;
                }
            }
        }
        offsets[count] = @intCast(data.len);
        for (0..count) |line_index| {
            var hash: u32 = 2166136261;
            for (data[offsets[line_index]..offsets[line_index + 1]]) |byte| {
                hash ^= byte;
                hash *%= 16777619;
            }
            hashes[line_index] = hash;
        }
        return .{ .data = data, .offsets = offsets, .hashes = hashes, .count = count };
    }

    fn deinit(self: *Side, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.hashes);
        self.* = undefined;
    }

    fn line(self: *const Side, index: usize) []const u8 {
        return self.data[self.offsets[index]..self.offsets[index + 1]];
    }

    fn linesEqual(x: *const Side, i: usize, y: *const Side, j: usize) bool {
        return x.hashes[i] == y.hashes[j] and std.mem.eql(u8, x.line(i), y.line(j));
    }

    fn lineBlank(self: *const Side, index: usize) bool {
        for (self.line(index)) |byte| switch (byte) {
            ' ', '\t', '\r', '\n' => {},
            else => return false,
        };
        return true;
    }
};

fn logicalLineCount(data: []const u8) usize {
    var count: usize = 0;
    for (data) |byte| if (byte == '\n') {
        count += 1;
    };
    if (data.len > 0 and data[data.len - 1] != '\n') count += 1;
    return count;
}

fn detailedLimitsAllow(a_lines: usize, b_lines: usize) bool {
    return a_lines <= maximum_detailed_lines and b_lines <= maximum_detailed_lines and
        a_lines <= std.math.maxInt(isize) and b_lines <= std.math.maxInt(isize);
}

const Window = struct { lo: usize, a_hi: usize, b_hi: usize, base: usize };

fn findWindow(a: []const u8, b: []const u8) Window {
    const common = @min(a.len, b.len);
    var prefix: usize = 0;
    while (prefix < common and a[prefix] == b[prefix]) prefix += 1;

    var lo = prefix;
    while (lo > 0 and a[lo - 1] != '\n') lo -= 1;
    for (0..window_slack_lines) |_| {
        if (lo == 0) break;
        lo -= 1;
        while (lo > 0 and a[lo - 1] != '\n') lo -= 1;
    }
    var base: usize = 0;
    for (a[0..lo]) |byte| if (byte == '\n') {
        base += 1;
    };

    var suffix: usize = 0;
    const suffix_max = common - lo;
    while (suffix < suffix_max and a[a.len - 1 - suffix] == b[b.len - 1 - suffix]) suffix += 1;
    const suffix_start = a.len - suffix;
    const newline_relative = if (suffix == 0) null else std.mem.findScalar(u8, a[suffix_start..], '\n');
    if (newline_relative == null) return .{ .lo = lo, .a_hi = a.len, .b_hi = b.len, .base = base };

    var hi = suffix_start + newline_relative.? + 1;
    for (0..window_slack_lines) |_| {
        if (hi >= a.len) break;
        const end = std.mem.findScalar(u8, a[hi..], '\n');
        hi = if (end) |relative| hi + relative + 1 else a.len;
    }
    return .{ .lo = lo, .a_hi = hi, .b_hi = b.len - (a.len - hi), .base = base };
}

const Split = struct { a: usize, b: usize };

const DiffContext = struct {
    a: *const Side,
    b: *const Side,
    a_changed: []u8,
    b_changed: []u8,
    forward: []isize,
    backward: []isize,
    diagonal_offset: isize,
    work: usize,

    fn equal(self: *DiffContext, ai: usize, bi: usize) bool {
        if (self.work == 0) return false;
        self.work -= 1;
        return Side.linesEqual(self.a, ai, self.b, bi);
    }

    fn equalReverse(self: *DiffContext, a_hi: usize, b_hi: usize, x: isize, y: isize) bool {
        return self.equal(a_hi - 1 - @as(usize, @intCast(x)), b_hi - 1 - @as(usize, @intCast(y)));
    }

    fn diagonal(slice: []isize, offset: isize, k: isize) *isize {
        return &slice[@intCast(offset + k)];
    }
};

fn splitOut(
    a_lo: usize,
    b_lo: usize,
    n: isize,
    m: isize,
    input_x: isize,
    input_y: isize,
) Split {
    const x = std.math.clamp(input_x, 0, n);
    const y = std.math.clamp(input_y, 0, m);
    return .{ .a = a_lo + @as(usize, @intCast(x)), .b = b_lo + @as(usize, @intCast(y)) };
}

fn myersSplit(
    context: *DiffContext,
    a_lo: usize,
    a_hi: usize,
    b_lo: usize,
    b_hi: usize,
) Split {
    const n: isize = @intCast(a_hi - a_lo);
    const m: isize = @intCast(b_hi - b_lo);
    const delta = n - m;
    const odd = delta & 1 != 0;
    const offset = context.diagonal_offset;

    var budget = region_steps_min;
    while (budget < region_steps_max and budget * budget < n + m) budget *= 2;
    if (budget > @divTrunc(n + m, 2) + 1) budget = @divTrunc(n + m, 2) + 1;

    var best: isize = -1;
    var best_x: isize = 0;
    var best_y: isize = 0;
    DiffContext.diagonal(context.forward, offset, 1).* = 0;
    DiffContext.diagonal(context.backward, offset, 1).* = 0;

    var d: isize = 0;
    while (d <= budget and context.work > 0) : (d += 1) {
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            var x = if (k == -d or (k != d and
                DiffContext.diagonal(context.forward, offset, k - 1).* <
                    DiffContext.diagonal(context.forward, offset, k + 1).*))
                DiffContext.diagonal(context.forward, offset, k + 1).*
            else
                DiffContext.diagonal(context.forward, offset, k - 1).* + 1;
            var y = x - k;
            while (x < n and y < m and
                context.equal(a_lo + @as(usize, @intCast(x)), b_lo + @as(usize, @intCast(y))))
            {
                x += 1;
                y += 1;
            }
            DiffContext.diagonal(context.forward, offset, k).* = x;
            if (x <= n and y <= m and x + y > best) {
                best = x + y;
                best_x = x;
                best_y = y;
            }
            const reverse_k = delta - k;
            if (odd and reverse_k >= -(d - 1) and reverse_k <= d - 1 and
                x >= n - DiffContext.diagonal(context.backward, offset, reverse_k).*)
            {
                return splitOut(a_lo, b_lo, n, m, x, y);
            }
        }
        k = -d;
        while (k <= d) : (k += 2) {
            var x = if (k == -d or (k != d and
                DiffContext.diagonal(context.backward, offset, k - 1).* <
                    DiffContext.diagonal(context.backward, offset, k + 1).*))
                DiffContext.diagonal(context.backward, offset, k + 1).*
            else
                DiffContext.diagonal(context.backward, offset, k - 1).* + 1;
            var y = x - k;
            while (x < n and y < m and context.equalReverse(a_hi, b_hi, x, y)) {
                x += 1;
                y += 1;
            }
            DiffContext.diagonal(context.backward, offset, k).* = x;
            const forward_k = delta - k;
            if (!odd and forward_k >= -d and forward_k <= d and
                DiffContext.diagonal(context.forward, offset, forward_k).* >= n - x)
            {
                return splitOut(a_lo, b_lo, n, m, n - x, m - y);
            }
        }
    }
    return splitOut(a_lo, b_lo, n, m, best_x, best_y);
}

fn diffRegion(
    context: *DiffContext,
    input_a_lo: usize,
    input_a_hi: usize,
    input_b_lo: usize,
    input_b_hi: usize,
) void {
    var a_lo = input_a_lo;
    var a_hi = input_a_hi;
    var b_lo = input_b_lo;
    var b_hi = input_b_hi;
    while (true) {
        while (a_lo < a_hi and b_lo < b_hi and context.equal(a_lo, b_lo)) {
            a_lo += 1;
            b_lo += 1;
        }
        while (a_hi > a_lo and b_hi > b_lo and context.equal(a_hi - 1, b_hi - 1)) {
            a_hi -= 1;
            b_hi -= 1;
        }
        if (a_lo == a_hi) {
            @memset(context.b_changed[b_lo..b_hi], 1);
            return;
        }
        if (b_lo == b_hi) {
            @memset(context.a_changed[a_lo..a_hi], 1);
            return;
        }

        var split: Split = .{ .a = a_lo, .b = b_lo };
        var degenerate = true;
        if (context.work > 0) {
            split = myersSplit(context, a_lo, a_hi, b_lo, b_hi);
            degenerate = (split.a == a_lo and split.b == b_lo) or
                (split.a == a_hi and split.b == b_hi);
        }
        if (degenerate) {
            @memset(context.a_changed[a_lo..a_hi], 1);
            @memset(context.b_changed[b_lo..b_hi], 1);
            return;
        }
        if ((split.a - a_lo) +| (split.b - b_lo) <=
            (a_hi - split.a) +| (b_hi - split.b))
        {
            diffRegion(context, a_lo, split.a, b_lo, split.b);
            a_lo = split.a;
            b_lo = split.b;
        } else {
            diffRegion(context, split.a, a_hi, split.b, b_hi);
            a_hi = split.a;
            b_hi = split.b;
        }
    }
}

fn runScore(side: *const Side, start: usize, end: usize) u2 {
    var score: u2 = 0;
    if (start == 0 or side.lineBlank(start - 1)) score += 2;
    if (end == side.count or side.lineBlank(end - 1)) score += 1;
    return score;
}

fn slideRuns(side: *const Side, changed: []u8) void {
    var scan: usize = 0;
    while (scan < side.count) {
        if (changed[scan] == 0) {
            scan += 1;
            continue;
        }
        const start = scan;
        var end = start;
        while (end < side.count and changed[end] != 0) end += 1;
        const run = end - start;
        var lo = start;
        while (lo > 0 and changed[lo - 1] == 0 and
            Side.linesEqual(side, lo - 1, side, lo + run - 1)) lo -= 1;
        var hi = start;
        while (hi + run < side.count and changed[hi + run] == 0 and
            Side.linesEqual(side, hi, side, hi + run)) hi += 1;

        var best = lo;
        var best_score: i8 = -1;
        var position = lo;
        while (position <= hi) : (position += 1) {
            const score: i8 = @intCast(runScore(side, position, position + run));
            if (score >= best_score) {
                best_score = score;
                best = position;
            }
        }
        if (best != start) {
            @memset(changed[start..end], 0);
            @memset(changed[best .. best + run], 1);
        }
        scan = @max(best, start) + run;
    }
}

const Change = struct { a_start: usize, a_lines: usize, b_start: usize, b_lines: usize };

fn collectChanges(
    allocator: std.mem.Allocator,
    n: usize,
    m: usize,
    a_changed: []const u8,
    b_changed: []const u8,
) Error![]Change {
    var changes: std.ArrayList(Change) = .empty;
    errdefer changes.deinit(allocator);
    var i: usize = 0;
    var j: usize = 0;
    while (i < n or j < m) {
        if ((i < n and a_changed[i] != 0) or (j < m and b_changed[j] != 0)) {
            const a_start = i;
            const b_start = j;
            while (i < n and a_changed[i] != 0) i += 1;
            while (j < m and b_changed[j] != 0) j += 1;
            try changes.append(allocator, .{
                .a_start = a_start,
                .a_lines = i - a_start,
                .b_start = b_start,
                .b_lines = j - b_start,
            });
        } else {
            i += 1;
            j += 1;
        }
    }
    return changes.toOwnedSlice(allocator);
}

fn appendBounded(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
    maximum: usize,
) Error!void {
    if (bytes.len > maximum -| output.items.len) return error.ResultTooLarge;
    try output.appendSlice(allocator, bytes);
}

fn appendLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    marker: u8,
    side: *const Side,
    index: usize,
    maximum: usize,
) Error!void {
    try appendBounded(allocator, output, &.{marker}, maximum);
    const line = side.line(index);
    try appendBounded(allocator, output, line, maximum);
    if (line[line.len - 1] != '\n')
        try appendBounded(allocator, output, "\n\\ No newline at end of file\n", maximum);
}

fn appendRange(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    start: usize,
    count: usize,
    maximum: usize,
) Error!void {
    var text: [48]u8 = undefined;
    const range = if (count == 1)
        std.fmt.bufPrint(&text, "{d}", .{start + 1}) catch return error.ResultTooLarge
    else
        std.fmt.bufPrint(&text, "{d},{d}", .{ if (count != 0) start + 1 else start, count }) catch
            return error.ResultTooLarge;
    try appendBounded(allocator, output, range, maximum);
}

fn appendHunks(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    a: *const Side,
    b: *const Side,
    changes: []const Change,
    base: usize,
    maximum: usize,
) Error!void {
    var group: usize = 0;
    while (group < changes.len) {
        var last = group;
        while (last + 1 < changes.len and
            changes[last + 1].a_start -| (changes[last].a_start +| changes[last].a_lines) <=
                2 * context_lines) last += 1;
        const a_end = changes[last].a_start +| changes[last].a_lines;
        const b_end = changes[last].b_start +| changes[last].b_lines;
        const a_lo = changes[group].a_start -| context_lines;
        const a_hi = @min(a_end +| context_lines, a.count);
        const b_lo = changes[group].b_start - (changes[group].a_start - a_lo);
        const b_hi = b_end + (a_hi - a_end);

        try appendBounded(allocator, output, "@@ -", maximum);
        try appendRange(allocator, output, base +| a_lo, a_hi - a_lo, maximum);
        try appendBounded(allocator, output, " +", maximum);
        try appendRange(allocator, output, base +| b_lo, b_hi - b_lo, maximum);
        try appendBounded(allocator, output, " @@\n", maximum);

        var i = a_lo;
        for (changes[group .. last + 1]) |change| {
            while (i < change.a_start) : (i += 1)
                try appendLine(allocator, output, ' ', a, i, maximum);
            while (i < change.a_start +| change.a_lines) : (i += 1)
                try appendLine(allocator, output, '-', a, i, maximum);
            for (change.b_start..change.b_start +| change.b_lines) |j|
                try appendLine(allocator, output, '+', b, j, maximum);
        }
        while (i < a_hi) : (i += 1) try appendLine(allocator, output, ' ', a, i, maximum);
        group = last + 1;
    }
}

/// Returns an owned, bounded unified diff with three context lines. The result
/// is valid UTF-8; malformed bytes and NULs become U+FFFD.
/// Returns an owned hax-compatible unified diff. Each input is limited to
/// 16 MiB; a changed window over 262,144 logical lines is rejected. The final
/// raw and sanitized output must fit `maximum_result_bytes`.
pub fn make(
    allocator: std.mem.Allocator,
    old_bytes: []const u8,
    new_bytes: []const u8,
    old_label: []const u8,
    new_label: []const u8,
    maximum_result_bytes: usize,
) Error![]u8 {
    if (old_bytes.len > maximum_input_bytes or new_bytes.len > maximum_input_bytes)
        return error.ResultTooLarge;
    if (std.mem.eql(u8, old_bytes, new_bytes)) return allocator.dupe(u8, "");
    const window = findWindow(old_bytes, new_bytes);
    const a_window = old_bytes[window.lo..window.a_hi];
    const b_window = new_bytes[window.lo..window.b_hi];
    const a_line_count = logicalLineCount(a_window);
    const b_line_count = logicalLineCount(b_window);
    if (!detailedLimitsAllow(a_line_count, b_line_count))
        return error.ResultTooLarge;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try appendBounded(allocator, &output, "--- ", maximum_result_bytes);
    try appendBounded(allocator, &output, old_label, maximum_result_bytes);
    try appendBounded(allocator, &output, "\n+++ ", maximum_result_bytes);
    try appendBounded(allocator, &output, new_label, maximum_result_bytes);
    try appendBounded(allocator, &output, "\n", maximum_result_bytes);

    var a = try Side.init(allocator, a_window);
    defer a.deinit(allocator);
    var b = try Side.init(allocator, b_window);
    defer b.deinit(allocator);
    const a_changed = try allocator.alloc(u8, a.count + 1);
    defer allocator.free(a_changed);
    @memset(a_changed, 0);
    const b_changed = try allocator.alloc(u8, b.count + 1);
    defer allocator.free(b_changed);
    @memset(b_changed, 0);
    const diagonal_count: usize = 2 * @as(usize, @intCast(region_steps_max)) + 3;
    const vectors = try allocator.alloc(isize, 2 * diagonal_count);
    defer allocator.free(vectors);
    var context: DiffContext = .{
        .a = &a,
        .b = &b,
        .a_changed = a_changed,
        .b_changed = b_changed,
        .forward = vectors[0..diagonal_count],
        .backward = vectors[diagonal_count..],
        .diagonal_offset = region_steps_max + 1,
        .work = work_limit,
    };
    diffRegion(&context, 0, a.count, 0, b.count);
    slideRuns(&a, a_changed);
    slideRuns(&b, b_changed);
    const changes = try collectChanges(allocator, a.count, b.count, a_changed, b_changed);
    defer allocator.free(changes);
    try appendHunks(
        allocator,
        &output,
        &a,
        &b,
        changes,
        window.base,
        maximum_result_bytes,
    );
    return Utf8.sanitize(allocator, output.items, maximum_result_bytes);
}

fn expectDiff(old: []const u8, new: []const u8, expected: []const u8) !void {
    const output = try make(std.testing.allocator, old, new, "a/f", "b/f", 64 * 1024);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "identical inputs produce an owned empty diff" {
    try expectDiff("hello\n", "hello\n", "");
    try expectDiff("", "", "");
}

test "simple changes and range conventions match hax" {
    try expectDiff("hello\nworld\n", "hello\nthere\n", "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n hello\n-world\n+there\n");
    try expectDiff("a\n", "b\n", "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n");
    const created = try make(std.testing.allocator, "", "alpha\nbeta\n", "/dev/null", "b/new.txt", 1024);
    defer std.testing.allocator.free(created);
    try std.testing.expectEqualStrings(
        "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+alpha\n+beta\n",
        created,
    );
    const deleted = try make(std.testing.allocator, "only line\n", "", "a/old", "/dev/null", 1024);
    defer std.testing.allocator.free(deleted);
    try std.testing.expectEqualStrings(
        "--- a/old\n+++ /dev/null\n@@ -1 +0,0 @@\n-only line\n",
        deleted,
    );
}

test "missing trailing newline markers match hax" {
    try expectDiff("a\nb", "a\nb\n", "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n");
    try expectDiff("a\nb\n", "a\nb", "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+b\n\\ No newline at end of file\n");
    try expectDiff("a\nz", "b\nz", "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-a\n+b\n z\n\\ No newline at end of file\n");
}

test "context grouping and clipping match hax" {
    try expectDiff("1\n2\n3\n4\n5\n", "one\n2\n3\n4\n5\n", "--- a/f\n+++ b/f\n@@ -1,4 +1,4 @@\n-1\n+one\n 2\n 3\n 4\n");
    try expectDiff(
        "1\n2\n3\n4\n5\n",
        "1\nB\n3\nD\n5\n",
        "--- a/f\n+++ b/f\n@@ -1,5 +1,5 @@\n 1\n-2\n+B\n 3\n-4\n+D\n 5\n",
    );
    const base = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";
    const merged = try make(
        std.testing.allocator,
        base,
        "one\n2\n3\n4\n5\n6\n7\neight\n9\n10\n11\n12\n",
        "a/f",
        "b/f",
        4096,
    );
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, merged, "@@ -"));
    const split = try make(
        std.testing.allocator,
        base,
        "one\n2\n3\n4\n5\n6\n7\n8\nnine\n10\n11\n12\n",
        "a/f",
        "b/f",
        4096,
    );
    defer std.testing.allocator.free(split);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, split, "@@ -"));
    try std.testing.expect(std.mem.indexOf(u8, split, "@@ -1,4 +1,4 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, split, "@@ -6,7 +6,7 @@") != null);
}

test "changed runs slide to readable blank-line boundaries" {
    try expectDiff(
        "void a()\n{\n}\n\nvoid c()\n{\n}\n",
        "void a()\n{\n}\n\nvoid b()\n{\n}\n\nvoid c()\n{\n}\n",
        "--- a/f\n+++ b/f\n@@ -2,6 +2,10 @@\n {\n }\n \n+void b()\n+{\n+}\n+\n void c()\n {\n }\n",
    );
    try expectDiff(
        "void a()\n{\n}\n\nvoid b()\n{\n}\n\nvoid c()\n{\n}\n",
        "void a()\n{\n}\n\nvoid c()\n{\n}\n",
        "--- a/f\n+++ b/f\n@@ -2,10 +2,6 @@\n {\n }\n \n-void b()\n-{\n-}\n-\n void c()\n {\n }\n",
    );
    try expectDiff("a\nb\n", "a\nb\nb\n", "--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n a\n b\n+b\n");
}

test "output sanitizes NUL and invalid UTF-8" {
    const old = [_]u8{ 'a', 0, 0xff, 'b', '\n' };
    const output = try make(std.testing.allocator, &old, "abc\n", "a/f", "b/f", 1024);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\xef\xbf\xbd\xef\xbf\xbd") != null);
    try std.testing.expect(std.mem.findScalar(u8, output, 0) == null);
}

test "long common prefix keeps whole-file line numbers" {
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(std.testing.allocator);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(std.testing.allocator);
    for (0..300) |i| {
        var buffer: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "x{d}\n", .{i});
        try old.appendSlice(std.testing.allocator, line);
        try new.appendSlice(std.testing.allocator, line);
    }
    try old.appendSlice(std.testing.allocator, "old\n");
    try new.appendSlice(std.testing.allocator, "new\n");
    for (0..300) |i| {
        var buffer: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "y{d}\n", .{i});
        try old.appendSlice(std.testing.allocator, line);
        try new.appendSlice(std.testing.allocator, line);
    }
    const output = try make(std.testing.allocator, old.items, new.items, "a/f", "b/f", 4096);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "@@ -298,7 +298,7 @@\n x297\n x298\n x299\n-old\n+new\n y0\n y1\n y2\n",
    ) != null);
}

test "sparse edits in a large file stay local" {
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(std.testing.allocator);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(std.testing.allocator);
    for (0..40_000) |i| {
        var old_buffer: [16]u8 = undefined;
        var new_buffer: [16]u8 = undefined;
        try old.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&old_buffer, "l{d}\n", .{i}));
        if (i % 2000 == 500) {
            try new.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&new_buffer, "e{d}\n", .{i}));
        } else {
            try new.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&new_buffer, "l{d}\n", .{i}));
        }
    }
    const output = try make(std.testing.allocator, old.items, new.items, "a/f", "b/f", 4096);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, output, "@@ -"));
    try std.testing.expect(std.mem.indexOf(u8, output, "@@ -498,7 +498,7 @@\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-l500\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+e500\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-l38500\n") != null);
}

test "final no-newline change survives a long common prefix" {
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(std.testing.allocator);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(std.testing.allocator);
    for (0..200) |i| {
        var buffer: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "p{d}\n", .{i});
        try old.appendSlice(std.testing.allocator, line);
        try new.appendSlice(std.testing.allocator, line);
    }
    try old.appendSlice(std.testing.allocator, "aaa");
    try new.appendSlice(std.testing.allocator, "bbb");
    const output = try make(std.testing.allocator, old.items, new.items, "a/f", "b/f", 4096);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "@@ -198,4 +198,4 @@\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        " p199\n-aaa\n\\ No newline at end of file\n+bbb\n\\ No newline at end of file\n",
    ) != null);
}

test "large rewrite coarsens to one replacement" {
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(std.testing.allocator);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(std.testing.allocator);
    for (0..1500) |i| {
        var old_buffer: [16]u8 = undefined;
        var new_buffer: [16]u8 = undefined;
        try old.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&old_buffer, "old{d}\n", .{i}));
        try new.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&new_buffer, "new{d}\n", .{i}));
    }
    const output = try make(std.testing.allocator, old.items, new.items, "a/f", "b/f", 64 * 1024);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "@@ -1,1500 +1,1500 @@\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "@@ -"));
}

test "maximum result bound applies to raw and sanitized output" {
    try std.testing.expectError(error.ResultTooLarge, make(std.testing.allocator, "a\n", "b\n", "a/f", "b/f", 8));
    const old = [_]u8{0xff};
    try std.testing.expectError(error.ResultTooLarge, make(std.testing.allocator, &old, "x", "a", "b", 50));
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    const output = try make(allocator, "a\nb\nc\n", "a\nx\nc\n", "a/f", "b/f", 1024);
    allocator.free(output);
}

test "all allocation failures release partial state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

test "detailed diff limits are target-width safe and deterministic" {
    try std.testing.expect(detailedLimitsAllow(4096, 4096));
    try std.testing.expect(!detailedLimitsAllow(maximum_detailed_lines + 1, 1));
    if (@sizeOf(isize) == 4) {
        try std.testing.expect(!detailedLimitsAllow(@as(usize, std.math.maxInt(isize)) + 1, 1));
    }
}

test "public API rejects oversized input before diff allocation" {
    const oversized = try std.testing.allocator.alloc(u8, maximum_input_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.ResultTooLarge,
        make(std.testing.allocator, oversized, "", "a/f", "b/f", 1024),
    );
}
