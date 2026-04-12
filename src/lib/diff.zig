//! Line-level diff component.
//!
//! Produces a structured document diff from one or more file changes.
//! The core Myers line-diff and hunk grouping behavior stays identical;
//! only the canonical data model is widened from one file to many.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DiffOp = enum {
    equal,
    insert,
    delete,
};

pub const DiffLine = struct {
    op: DiffOp,
    text: []const u8,
    old_lineno: ?u32 = null,
    new_lineno: ?u32 = null,
};

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

    pub fn add(self: *Stats, other: Stats) void {
        self.added += other.added;
        self.removed += other.removed;
    }
};

pub const FileChange = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []const Hunk,
    stats: Stats,
    owns_paths: bool = false,
    owns_line_text: bool = false,
};

pub const Input = struct {
    old_path: []const u8,
    new_path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

pub const DiffDocument = struct {
    changes: []const FileChange,
    stats: Stats,
    allocator: Allocator,

    pub fn deinit(self: *DiffDocument) void {
        for (self.changes) |change| {
            if (change.owns_paths) {
                self.allocator.free(change.old_path);
                self.allocator.free(change.new_path);
            }
            for (change.hunks) |h| {
                if (change.owns_line_text) {
                    for (h.lines) |line| self.allocator.free(line.text);
                }
                self.allocator.free(h.lines);
            }
            self.allocator.free(change.hunks);
        }
        self.allocator.free(self.changes);
    }
};

const RawOp = struct {
    kind: DiffOp,
    idx: u32,
};

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
    var v = try allocator.alloc(i64, graph_size);
    defer allocator.free(v);
    @memset(v, 0);

    var trace: std.ArrayList([]i64) = .empty;
    defer {
        for (trace.items) |frame| allocator.free(frame);
        trace.deinit(allocator);
    }
    try trace.ensureTotalCapacity(allocator, max + 1);

    var reached = false;
    var final_d: usize = 0;
    outer: for (0..max + 1) |d| {
        const frame = try allocator.dupe(i64, v);
        trace.appendAssumeCapacity(frame);

        const di: i64 = @intCast(d);
        var k: i64 = -di;
        while (k <= di) : (k += 2) {
            const idx_center: usize = @intCast(k + @as(i64, @intCast(max)));
            var x: i64 = blk: {
                if (k == -di or (k != di and v[idx_center - 1] < v[idx_center + 1])) {
                    break :blk v[idx_center + 1];
                } else {
                    break :blk v[idx_center - 1] + 1;
                }
            };
            var y: i64 = x - k;

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
    if (!reached) return error.DiffFailed;

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

    const ops = try allocator.alloc(RawOp, ops_rev.items.len);
    for (ops_rev.items, 0..) |op, i| {
        ops[ops_rev.items.len - 1 - i] = op;
    }
    return ops;
}

fn splitLines(allocator: Allocator, s: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try list.append(allocator, l);
    return list.toOwnedSlice(allocator);
}

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
            .equal => .{ .op = .equal, .text = a_lines[op.idx], .old_lineno = old_lineno, .new_lineno = new_lineno },
            .delete => .{ .op = .delete, .text = a_lines[op.idx], .old_lineno = old_lineno },
            .insert => .{ .op = .insert, .text = b_lines[op.idx], .new_lineno = new_lineno },
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
        while (i < flat.len and flat[i].op == .equal) : (i += 1) {}
        if (i >= flat.len) break;

        const hunk_start: usize = i -| ctx;

        var j = i;
        while (j < flat.len) {
            while (j < flat.len and flat[j].op != .equal) : (j += 1) {}
            var k = j;
            while (k < flat.len and k - j < 2 * ctx and flat[k].op == .equal) : (k += 1) {}
            if (k < flat.len and flat[k].op != .equal) {
                j = k;
                continue;
            }
            break;
        }
        const hunk_end: usize = @min(flat.len, j + ctx);

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

pub const BuildOptions = struct {
    context: u32 = DEFAULT_CTX,
};

pub fn buildFile(
    allocator: Allocator,
    old_path: []const u8,
    new_path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    options: BuildOptions,
) !FileChange {
    const a_lines = try splitLines(allocator, old_text);
    defer allocator.free(a_lines);
    const b_lines = try splitLines(allocator, new_text);
    defer allocator.free(b_lines);

    const flat = try diffLinesRaw(allocator, a_lines, b_lines);
    defer allocator.free(flat);

    const hunks = try buildHunks(allocator, flat, options.context);
    errdefer {
        for (hunks) |h| allocator.free(h.lines);
        allocator.free(hunks);
    }

    var stats = Stats{};
    for (hunks) |h| {
        for (h.lines) |dl| switch (dl.op) {
            .insert => stats.added += 1,
            .delete => stats.removed += 1,
            .equal => {},
        };
    }

    return .{
        .old_path = old_path,
        .new_path = new_path,
        .hunks = hunks,
        .stats = stats,
    };
}

pub fn buildDocument(
    allocator: Allocator,
    inputs: []const Input,
    options: BuildOptions,
) !DiffDocument {
    const changes = try allocator.alloc(FileChange, inputs.len);
    errdefer allocator.free(changes);

    var built: usize = 0;
    errdefer {
        for (changes[0..built]) |change| {
            for (change.hunks) |h| allocator.free(h.lines);
            allocator.free(change.hunks);
        }
    }

    var stats = Stats{};
    for (inputs, 0..) |input, i| {
        changes[i] = try buildFile(
            allocator,
            input.old_path,
            input.new_path,
            input.old_text,
            input.new_text,
            options,
        );
        built += 1;
        stats.add(changes[i].stats);
    }

    return .{
        .changes = changes,
        .stats = stats,
        .allocator = allocator,
    };
}

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
    try testing.expectEqual(@as(usize, 4), ops.len);
    try testing.expectEqual(DiffOp.equal, ops[0].kind);
    try testing.expectEqual(DiffOp.delete, ops[1].kind);
    try testing.expectEqual(DiffOp.insert, ops[2].kind);
    try testing.expectEqual(DiffOp.equal, ops[3].kind);
}

test "buildFile: produces single hunk with context for small edit" {
    const a = "line1\nline2\nline3\nline4\nline5\n";
    const b = "line1\nline2\nLINE3\nline4\nline5\n";
    const change = try buildFile(testing.allocator, "test.txt", "test.txt", a, b, .{});
    defer {
        for (change.hunks) |h| testing.allocator.free(h.lines);
        testing.allocator.free(change.hunks);
    }

    try testing.expectEqual(@as(usize, 1), change.hunks.len);
    try testing.expectEqual(@as(u32, 1), change.stats.added);
    try testing.expectEqual(@as(u32, 1), change.stats.removed);

    const h = change.hunks[0];
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
    try testing.expectEqual(@as(u32, 5), equals);
}

test "buildDocument: aggregates multiple file changes" {
    const inputs = [_]Input{
        .{ .old_path = "a.txt", .new_path = "a.txt", .old_text = "foo\nbar\n", .new_text = "foo\nBAR\n" },
        .{ .old_path = "b.txt", .new_path = "b.txt", .old_text = "one\ntwo\n", .new_text = "one\ntwo\nthree\n" },
    };

    var doc = try buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.changes.len);
    try testing.expectEqual(@as(u32, 2), doc.stats.added);
    try testing.expectEqual(@as(u32, 1), doc.stats.removed);
}

test "buildFile: two distant edits produce two hunks" {
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
    const change = try buildFile(testing.allocator, "f", "f", a, b, .{});
    defer {
        for (change.hunks) |h| testing.allocator.free(h.lines);
        testing.allocator.free(change.hunks);
    }
    try testing.expectEqual(@as(usize, 2), change.hunks.len);
}

test "buildFile: close edits merge into one hunk" {
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
    const change = try buildFile(testing.allocator, "f", "f", a, b, .{});
    defer {
        for (change.hunks) |h| testing.allocator.free(h.lines);
        testing.allocator.free(change.hunks);
    }
    try testing.expectEqual(@as(usize, 1), change.hunks.len);
}
