//! Line-level diff component.
//!
//! Produces `git diff`-quality unified diffs from two text blobs. Used
//! by the edit tool to describe what a replacement changed, and exposed
//! as a component so other UIs (review, history) can render the same
//! structured data without reparsing text.
//!
//! ## Layers
//!
//! This file is organized top-down from data → algorithm → formatter:
//!
//!   1. Types       — DiffOp, DiffLine, Hunk, FileDiff, Stats
//!   2. Myers       — shortest-edit-script line diff, O(ND) time
//!                    (ported from Bun's node_assert port of node's myers_diff.js;
//!                     which itself derives from Myers' 1986 paper)
//!   3. Hunker      — group edits into hunks with N lines of surrounding context
//!   4. Build       — full pipeline: two texts → FileDiff
//!   5. Unified     — FileDiff → unified-diff text (what LLMs expect to read)
//!
//! ## Why Myers (and not what)
//!
//! Myers O(ND) finds the minimum number of edits to turn A into B. It's
//! the same algorithm `diff(1)`, `git diff`, and Node's `assert` use.
//! Patience and histogram diff are variants that pick *nicer* edit
//! scripts when multiple minimum scripts exist (fewer interleaved
//! hunks). They matter for human review on large refactors; they don't
//! matter for short edits the agent emits, which is the hot path.
//! Patience is a future add, not a launch requirement.
//!
//! ## Why no generics
//!
//! Bun's version is generic over `Line` (u8 / u16 / []const u8). We
//! only ever diff utf-8 lines. Dropping the comptime generic keeps the
//! public surface small — if we ever need byte-level diffing for
//! another tool, generalize then, not now.
//!
//! ## References
//! - Myers (1986): http://www.xmailserver.org/diff2.pdf
//! - Node's impl: https://github.com/nodejs/node/blob/main/lib/internal/assert/myers_diff.js
//! - Bun's zig port: https://github.com/oven-sh/bun/blob/main/src/bun.js/node/assert/myers_diff.zig

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── 1. Types ────────────────────────────────────────────────────────

pub const DiffOp = enum {
    /// line present in both a and b
    equal,
    /// line present only in b (added)
    insert,
    /// line present only in a (removed)
    delete,
};

/// A single line in the diff, annotated with its 1-based line numbers
/// in the old and new file when applicable. `old_lineno` is set for
/// `equal` and `delete`; `new_lineno` is set for `equal` and `insert`.
pub const DiffLine = struct {
    op: DiffOp,
    text: []const u8,
    old_lineno: ?u32 = null,
    new_lineno: ?u32 = null,
};

/// One hunk = one contiguous run of changes plus its surrounding
/// context. Matches the `@@ -old_start,old_count +new_start,new_count @@`
/// header line numbers in unified diff format (all 1-based).
pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    lines: []const DiffLine,
};

pub const Stats = struct {
    added: u32 = 0,
    removed: u32 = 0,
};

pub const FileDiff = struct {
    /// Label for the "a" side (old); typically the file basename.
    a_label: []const u8,
    /// Label for the "b" side (new); typically the same basename.
    b_label: []const u8,
    hunks: []const Hunk,
    stats: Stats,
    allocator: Allocator,

    /// Free everything the builder allocated. Input texts are borrowed
    /// (FileDiff's `lines[*].text` slices point into the caller's
    /// buffers), so the caller must keep the sources alive for the
    /// lifetime of this FileDiff.
    pub fn deinit(self: *FileDiff) void {
        for (self.hunks) |h| self.allocator.free(h.lines);
        self.allocator.free(self.hunks);
    }
};

// ── 2. Myers O(ND) ──────────────────────────────────────────────────
//
// The algorithm builds an "edit graph" where walking down a column is
// an insertion, right is a deletion, and diagonal is an equal match.
// The shortest path from (0,0) to (N,M) is the shortest edit script.
//
// `V[k]` stores the furthest x reachable on diagonal `k = x - y` using
// exactly `d` edits. We iterate `d` upward until we reach the sink,
// snapshotting V at each step so we can backtrack and reconstruct the
// actual operations (not just their count).
//
// Indices: diagonals range [-max, max] where max = n+m. We offset by
// `max` and store in a flat array of length `2*max+1` so all accesses
// are non-negative.

const RawOp = struct {
    kind: DiffOp,
    /// index into `a` for delete/equal, into `b` for insert
    idx: u32,
};

/// Raw Myers — produces a list of RawOp in forward order (start→end).
/// Returned slice is owned by caller.
fn myers(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
) ![]RawOp {
    const n = a.len;
    const m = b.len;
    const max: usize = n + m;

    if (max == 0) return allocator.alloc(RawOp, 0);

    const graph_size = 2 * max + 1;
    // V graph, one copy live, one per diff level for the trace.
    var v = try allocator.alloc(i64, graph_size);
    defer allocator.free(v);
    @memset(v, 0);

    var trace: std.ArrayList([]i64) = .empty;
    defer {
        for (trace.items) |frame| allocator.free(frame);
        trace.deinit(allocator);
    }
    try trace.ensureTotalCapacity(allocator, max + 1);

    // Main loop: grow d until we reach the sink (n, m).
    var reached = false;
    var final_d: usize = 0;
    outer: for (0..max + 1) |d| {
        const frame = try allocator.dupe(i64, v);
        trace.appendAssumeCapacity(frame);

        const di: i64 = @intCast(d);
        var k: i64 = -di;
        while (k <= di) : (k += 2) {
            // Pick the best predecessor: down (k+1) or right (k-1).
            const idx_center: usize = @intCast(k + @as(i64, @intCast(max)));
            var x: i64 = blk: {
                if (k == -di or (k != di and v[idx_center - 1] < v[idx_center + 1])) {
                    break :blk v[idx_center + 1]; // move down from k+1
                } else {
                    break :blk v[idx_center - 1] + 1; // move right from k-1
                }
            };
            var y: i64 = x - k;

            // Slide diagonally as long as lines match.
            while (x < @as(i64, @intCast(n)) and y < @as(i64, @intCast(m)) and
                std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }

            v[idx_center] = x;
            if (x >= @as(i64, @intCast(n)) and y >= @as(i64, @intCast(m))) {
                reached = true;
                final_d = d;
                break :outer;
            }
        }
    }
    if (!reached) {
        // Unreachable in theory; defensive so we never panic on bad input.
        return error.DiffFailed;
    }

    // Backtrack: reconstruct the edit script by walking trace frames
    // from d=final_d down to d=0. At each level we decide whether the
    // previous step came from k-1 (right/delete) or k+1 (down/insert),
    // then slide back along any diagonal matches.
    var ops_rev: std.ArrayList(RawOp) = .empty;
    defer ops_rev.deinit(allocator);
    try ops_rev.ensureTotalCapacity(allocator, max);

    var x: i64 = @intCast(n);
    var y: i64 = @intCast(m);

    var d_walk: usize = final_d + 1;
    while (d_walk > 0) {
        d_walk -= 1;
        const graph = trace.items[d_walk];
        const k: i64 = x - y;
        const di: i64 = @intCast(d_walk);

        const prev_k: i64 = blk: {
            const idx_center: usize = @intCast(k + @as(i64, @intCast(max)));
            if (k == -di or (k != di and graph[idx_center - 1] < graph[idx_center + 1])) {
                break :blk k + 1;
            } else {
                break :blk k - 1;
            }
        };

        const prev_idx: usize = @intCast(prev_k + @as(i64, @intCast(max)));
        const prev_x: i64 = graph[prev_idx];
        const prev_y: i64 = prev_x - prev_k;

        // Walk diagonal equal matches back to (prev_x, prev_y+something).
        while (x > prev_x and y > prev_y) {
            try ops_rev.append(allocator, .{ .kind = .equal, .idx = @intCast(x - 1) });
            x -= 1;
            y -= 1;
        }
        if (d_walk > 0) {
            if (x > prev_x) {
                try ops_rev.append(allocator, .{ .kind = .delete, .idx = @intCast(x - 1) });
                x -= 1;
            } else {
                try ops_rev.append(allocator, .{ .kind = .insert, .idx = @intCast(y - 1) });
                y -= 1;
            }
        }
    }

    // Reverse into forward order.
    const ops = try allocator.alloc(RawOp, ops_rev.items.len);
    for (ops_rev.items, 0..) |op, i| {
        ops[ops_rev.items.len - 1 - i] = op;
    }
    return ops;
}

// ── 3. Diff lines with line numbers ─────────────────────────────────

/// Split a text into lines on `\n`. Preserves the trailing empty line
/// when the input ends with a newline (matches pi-mono / node behavior;
/// consumers often rely on `lines.len` reflecting trailing-newline
/// presence).
fn splitLines(allocator: Allocator, s: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try list.append(allocator, l);
    return list.toOwnedSlice(allocator);
}

/// Compute line-level DiffLines (flat, with line numbers), without
/// grouping into hunks yet. Caller owns the returned slice. The line
/// `text` fields borrow from `a_lines`/`b_lines`.
fn diffLinesRaw(
    allocator: Allocator,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
) ![]DiffLine {
    const ops = try myers(allocator, a_lines, b_lines);
    defer allocator.free(ops);

    const out = try allocator.alloc(DiffLine, ops.len);
    var old_lineno: u32 = 1;
    var new_lineno: u32 = 1;
    for (ops, 0..) |op, i| {
        out[i] = switch (op.kind) {
            .equal => .{
                .op = .equal,
                .text = a_lines[op.idx],
                .old_lineno = old_lineno,
                .new_lineno = new_lineno,
            },
            .delete => .{
                .op = .delete,
                .text = a_lines[op.idx],
                .old_lineno = old_lineno,
            },
            .insert => .{
                .op = .insert,
                .text = b_lines[op.idx],
                .new_lineno = new_lineno,
            },
        };
        switch (op.kind) {
            .equal => {
                old_lineno += 1;
                new_lineno += 1;
            },
            .delete => old_lineno += 1,
            .insert => new_lineno += 1,
        }
    }
    return out;
}

// ── 4. Hunker — group changes with context ──────────────────────────
//
// Walks the flat DiffLine list and coalesces consecutive change lines
// (plus up to `ctx` equal lines on each side) into hunks. Two change
// regions within `2*ctx` lines of each other merge into a single hunk,
// matching git's behavior.

const DEFAULT_CTX: u32 = 3;

fn buildHunks(
    allocator: Allocator,
    flat: []const DiffLine,
    ctx: u32,
) ![]Hunk {
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer {
        for (hunks.items) |h| allocator.free(h.lines);
        hunks.deinit(allocator);
    }

    var i: usize = 0;
    while (i < flat.len) {
        // Find next change.
        while (i < flat.len and flat[i].op == .equal) : (i += 1) {}
        if (i >= flat.len) break;

        // Hunk start: back up by `ctx` equal lines.
        const hunk_start: usize = i -| ctx;

        // Extend hunk: include changes + trailing context, merging
        // into the next change if it's within `2*ctx` equal lines.
        var j = i;
        while (j < flat.len) {
            // Skip past the current run of changes.
            while (j < flat.len and flat[j].op != .equal) : (j += 1) {}
            // Look ahead: is there another change within 2*ctx?
            var k = j;
            while (k < flat.len and k - j < 2 * ctx and flat[k].op == .equal) : (k += 1) {}
            if (k < flat.len and flat[k].op != .equal) {
                // Merge — absorb the equals and continue.
                j = k;
                continue;
            }
            break;
        }
        // Trailing context: up to `ctx` equals after the last change.
        const hunk_end: usize = @min(flat.len, j + ctx);

        // Emit.
        const span = flat[hunk_start..hunk_end];
        const lines_copy = try allocator.dupe(DiffLine, span);

        var old_start: u32 = 0;
        var new_start: u32 = 0;
        var old_count: u32 = 0;
        var new_count: u32 = 0;
        for (span) |dl| {
            if (dl.old_lineno) |ln| {
                if (old_start == 0) old_start = ln;
                old_count += 1;
            }
            if (dl.new_lineno) |ln| {
                if (new_start == 0) new_start = ln;
                new_count += 1;
            }
        }
        // Empty sides get start = 0 in unified format.
        try hunks.append(allocator, .{
            .old_start = if (old_count == 0) 0 else old_start,
            .old_count = old_count,
            .new_start = if (new_count == 0) 0 else new_start,
            .new_count = new_count,
            .lines = lines_copy,
        });

        i = hunk_end;
    }

    return hunks.toOwnedSlice(allocator);
}

// ── 5. Build — full pipeline ────────────────────────────────────────

pub const BuildOptions = struct {
    /// Number of context lines to show around each change. Matches
    /// `git diff -U<n>` default.
    context: u32 = DEFAULT_CTX,
};

/// Build a FileDiff from two full-text blobs. Returned FileDiff owns
/// its hunks slice and per-hunk DiffLine slices; the `text` fields
/// inside those DiffLines BORROW from `a_text`/`b_text`, so both
/// inputs must outlive the returned FileDiff.
pub fn build(
    allocator: Allocator,
    filename: []const u8,
    a_text: []const u8,
    b_text: []const u8,
    options: BuildOptions,
) !FileDiff {
    const a_lines = try splitLines(allocator, a_text);
    defer allocator.free(a_lines);
    const b_lines = try splitLines(allocator, b_text);
    defer allocator.free(b_lines);

    const flat = try diffLinesRaw(allocator, a_lines, b_lines);
    defer allocator.free(flat);

    const hunks = try buildHunks(allocator, flat, options.context);

    var stats = Stats{};
    for (hunks) |h| {
        for (h.lines) |dl| switch (dl.op) {
            .insert => stats.added += 1,
            .delete => stats.removed += 1,
            .equal => {},
        };
    }

    return .{
        .a_label = filename,
        .b_label = filename,
        .hunks = hunks,
        .stats = stats,
        .allocator = allocator,
    };
}

// ── 6. Unified-diff emitter ─────────────────────────────────────────
//
// Emits classic `git diff` unified output:
//
//   --- a/filename
//   +++ b/filename
//   @@ -old_start,old_count +new_start,new_count @@
//    context line
//   -removed line
//   +added line
//
// This is what the agent's edit tool returns as the result body. LLMs
// are trained extensively on this format.

pub fn toUnified(allocator: Allocator, fd: FileDiff) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    if (fd.hunks.len == 0) {
        // No changes — still emit headers so downstream parsers
        // don't choke on an empty result.
        try w.print("--- {s}\n+++ {s}\n", .{ fd.a_label, fd.b_label });
        return aw.toOwnedSlice();
    }

    try w.print("--- {s}\n+++ {s}\n", .{ fd.a_label, fd.b_label });
    for (fd.hunks) |h| {
        // `@@ -old,count +new,count @@`. Git elides `,count` when
        // count == 1; we keep it explicit because it's less ambiguous
        // for LLM re-parsers and costs ~3 chars.
        try w.writeAll("@@ -");
        try writeRange(w, h.old_start, h.old_count);
        try w.writeAll(" +");
        try writeRange(w, h.new_start, h.new_count);
        try w.writeAll(" @@\n");
        for (h.lines) |dl| {
            const prefix: u8 = switch (dl.op) {
                .equal => ' ',
                .insert => '+',
                .delete => '-',
            };
            try w.writeByte(prefix);
            try w.writeAll(dl.text);
            try w.writeByte('\n');
        }
    }
    return aw.toOwnedSlice();
}

fn writeRange(w: *std.Io.Writer, start: u32, count: u32) !void {
    try w.print("{d},{d}", .{ start, count });
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "myers: identical inputs → all equal ops" {
    const a = [_][]const u8{ "foo", "bar", "baz" };
    const ops = try myers(testing.allocator, &a, &a);
    defer testing.allocator.free(ops);
    try testing.expectEqual(@as(usize, 3), ops.len);
    for (ops) |op| try testing.expectEqual(DiffOp.equal, op.kind);
}

test "myers: single line modification → delete + insert" {
    const a = [_][]const u8{ "foo", "bar", "baz" };
    const b = [_][]const u8{ "foo", "BAR", "baz" };
    const ops = try myers(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    // Minimum edit script: equal foo, delete bar, insert BAR, equal baz.
    try testing.expectEqual(@as(usize, 4), ops.len);
    try testing.expectEqual(DiffOp.equal, ops[0].kind);
    try testing.expectEqual(DiffOp.delete, ops[1].kind);
    try testing.expectEqual(DiffOp.insert, ops[2].kind);
    try testing.expectEqual(DiffOp.equal, ops[3].kind);
}

test "build: produces single hunk with context for small edit" {
    const a = "line1\nline2\nline3\nline4\nline5\n";
    const b = "line1\nline2\nLINE3\nline4\nline5\n";
    var fd = try build(testing.allocator, "test.txt", a, b, .{});
    defer fd.deinit();

    try testing.expectEqual(@as(usize, 1), fd.hunks.len);
    try testing.expectEqual(@as(u32, 1), fd.stats.added);
    try testing.expectEqual(@as(u32, 1), fd.stats.removed);

    const h = fd.hunks[0];
    // 2 lines of leading context + delete + insert + 2 lines trailing
    // (our DEFAULT_CTX=3, but only 2 equals available on each side).
    var deletes: u32 = 0;
    var inserts: u32 = 0;
    var equals: u32 = 0;
    for (h.lines) |dl| switch (dl.op) {
        .delete => deletes += 1,
        .insert => inserts += 1,
        .equal => equals += 1,
    };
    try testing.expectEqual(@as(u32, 1), deletes);
    try testing.expectEqual(@as(u32, 1), inserts);
    // 2 leading context (line1, line2) + 3 trailing (line4, line5, "")
    // — the trailing newline on the input produces an empty terminal
    // line that counts as context.
    try testing.expectEqual(@as(u32, 5), equals);
}

test "build: two distant edits produce two hunks" {
    // 10 lines; change line 1 and line 9. With ctx=3, the hunks can't
    // touch (gap between them > 2*ctx equal lines), so we get 2 hunks.
    const a =
        \\l1
        \\l2
        \\l3
        \\l4
        \\l5
        \\l6
        \\l7
        \\l8
        \\l9
        \\l10
    ;
    const b =
        \\L1
        \\l2
        \\l3
        \\l4
        \\l5
        \\l6
        \\l7
        \\l8
        \\L9
        \\l10
    ;
    var fd = try build(testing.allocator, "f", a, b, .{});
    defer fd.deinit();
    try testing.expectEqual(@as(usize, 2), fd.hunks.len);
}

test "build: close edits merge into one hunk" {
    // Only 2 equal lines between the two changes; with ctx=3 they must merge.
    const a =
        \\l1
        \\l2
        \\l3
        \\l4
        \\l5
        \\l6
    ;
    const b =
        \\L1
        \\l2
        \\l3
        \\L4
        \\l5
        \\l6
    ;
    var fd = try build(testing.allocator, "f", a, b, .{});
    defer fd.deinit();
    try testing.expectEqual(@as(usize, 1), fd.hunks.len);
}

test "toUnified: round-trip shape" {
    const a = "foo\nbar\nbaz\n";
    const b = "foo\nBAR\nbaz\n";
    var fd = try build(testing.allocator, "f.txt", a, b, .{});
    defer fd.deinit();

    const out = try toUnified(testing.allocator, fd);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "--- f.txt\n+++ f.txt\n@@ "));
    try testing.expect(std.mem.indexOf(u8, out, "-bar\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+BAR\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, " foo\n") != null); // context
}

test "toUnified: no-change emits headers only" {
    const a = "foo\nbar\n";
    var fd = try build(testing.allocator, "f", a, a, .{});
    defer fd.deinit();
    const out = try toUnified(testing.allocator, fd);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("--- f\n+++ f\n", out);
}

test "buildHunks: pure insert at end" {
    const a = "a\nb\nc\n";
    const b = "a\nb\nc\nd\ne\n";
    var fd = try build(testing.allocator, "f", a, b, .{});
    defer fd.deinit();
    try testing.expectEqual(@as(usize, 1), fd.hunks.len);
    try testing.expectEqual(@as(u32, 2), fd.stats.added);
    try testing.expectEqual(@as(u32, 0), fd.stats.removed);
}

test "buildHunks: pure delete" {
    const a = "a\nb\nc\nd\ne\n";
    const b = "a\nb\ne\n";
    var fd = try build(testing.allocator, "f", a, b, .{});
    defer fd.deinit();
    try testing.expectEqual(@as(u32, 0), fd.stats.added);
    try testing.expectEqual(@as(u32, 2), fd.stats.removed);
}
