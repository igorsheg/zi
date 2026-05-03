//! Line-level diff component.
//!
//! Produces an arena-owned semantic diff document. The public model is
//! block-oriented: replacements are first-class hunk blocks rather than a
//! delete/insert side channel. Unified text, JSON, and TUI projections derive
//! from this model.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DiffOp = enum {
    equal,
    insert,
    delete,
};

pub const Line = struct {
    text: []const u8,
};

pub const ContextBlock = struct {
    old_start: u32,
    new_start: u32,
    lines: []const Line,
};

pub const DeleteBlock = struct {
    old_start: u32,
    lines: []const Line,
};

pub const InsertBlock = struct {
    new_start: u32,
    lines: []const Line,
};

pub const ReplaceBlock = struct {
    old_start: u32,
    new_start: u32,
    old_lines: []const Line,
    new_lines: []const Line,
};

pub const HunkBlock = union(enum) {
    context: ContextBlock,
    delete: DeleteBlock,
    insert: InsertBlock,
    replace: ReplaceBlock,

    pub fn oldCount(self: HunkBlock) u32 {
        return switch (self) {
            .context => |b| @intCast(b.lines.len),
            .delete => |b| @intCast(b.lines.len),
            .insert => 0,
            .replace => |b| @intCast(b.old_lines.len),
        };
    }

    pub fn newCount(self: HunkBlock) u32 {
        return switch (self) {
            .context => |b| @intCast(b.lines.len),
            .delete => 0,
            .insert => |b| @intCast(b.lines.len),
            .replace => |b| @intCast(b.new_lines.len),
        };
    }

    pub fn oldStart(self: HunkBlock) ?u32 {
        return switch (self) {
            .context => |b| b.old_start,
            .delete => |b| b.old_start,
            .insert => null,
            .replace => |b| b.old_start,
        };
    }

    pub fn newStart(self: HunkBlock) ?u32 {
        return switch (self) {
            .context => |b| b.new_start,
            .delete => null,
            .insert => |b| b.new_start,
            .replace => |b| b.new_start,
        };
    }
};

pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    blocks: []const HunkBlock,
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
};

pub const OwnedDocument = struct {
    document: DiffDocument,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *OwnedDocument) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const RawOp = union(enum) {
    equal: struct { old_index: u32, new_index: u32 },
    delete: u32,
    insert: u32,
};

const Range = struct {
    start: u32,
    end: u32,

    fn len(self: Range) u32 {
        return self.end - self.start;
    }
};

const Opcode = union(enum) {
    equal: struct { old: Range, new: Range },
    delete: struct { old: Range, new_at: u32 },
    insert: struct { old_at: u32, new: Range },
    replace: struct { old: Range, new: Range },
};

fn myersOps(
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
            try ops_rev.append(allocator, .{ .equal = .{ .old_index = @intCast(x - 1), .new_index = @intCast(y - 1) } });
            x -= 1;
            y -= 1;
        }
        if (d_walk > 0) {
            if (x > prev_x) {
                try ops_rev.append(allocator, .{ .delete = @intCast(x - 1) });
                x -= 1;
            } else {
                try ops_rev.append(allocator, .{ .insert = @intCast(y - 1) });
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

fn appendOpcode(opcodes: *std.ArrayList(Opcode), allocator: Allocator, opcode: Opcode) !void {
    switch (opcode) {
        .equal => |eq| {
            if (opcodes.items.len > 0 and opcodes.items[opcodes.items.len - 1] == .equal) {
                const last = &opcodes.items[opcodes.items.len - 1].equal;
                if (last.old.end == eq.old.start and last.new.end == eq.new.start) {
                    last.old.end = eq.old.end;
                    last.new.end = eq.new.end;
                    return;
                }
            }
        },
        .delete => |del| {
            if (opcodes.items.len > 0 and opcodes.items[opcodes.items.len - 1] == .delete) {
                const last = &opcodes.items[opcodes.items.len - 1].delete;
                if (last.old.end == del.old.start and last.new_at == del.new_at) {
                    last.old.end = del.old.end;
                    return;
                }
            }
        },
        .insert => |ins| {
            if (opcodes.items.len > 0 and opcodes.items[opcodes.items.len - 1] == .insert) {
                const last = &opcodes.items[opcodes.items.len - 1].insert;
                if (last.old_at == ins.old_at and last.new.end == ins.new.start) {
                    last.new.end = ins.new.end;
                    return;
                }
            }
        },
        .replace => {},
    }
    try opcodes.append(allocator, opcode);
}

fn compactReplacements(allocator: Allocator, opcodes: []const Opcode) ![]Opcode {
    var out: std.ArrayList(Opcode) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < opcodes.len) {
        if (i + 1 < opcodes.len and opcodes[i] == .delete and opcodes[i + 1] == .insert) {
            const del = opcodes[i].delete;
            const ins = opcodes[i + 1].insert;
            if (del.new_at == ins.new.start and ins.old_at == del.old.end) {
                try out.append(allocator, .{ .replace = .{ .old = del.old, .new = ins.new } });
                i += 2;
                continue;
            }
        }
        try out.append(allocator, opcodes[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn myersOpcodes(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
) ![]Opcode {
    const raw_ops = try myersOps(allocator, a, b);
    defer allocator.free(raw_ops);

    var opcodes: std.ArrayList(Opcode) = .empty;
    defer opcodes.deinit(allocator);

    var old_cursor: u32 = 0;
    var new_cursor: u32 = 0;
    for (raw_ops) |op| switch (op) {
        .equal => |eq| {
            try appendOpcode(&opcodes, allocator, .{ .equal = .{
                .old = .{ .start = eq.old_index, .end = eq.old_index + 1 },
                .new = .{ .start = eq.new_index, .end = eq.new_index + 1 },
            } });
            old_cursor = eq.old_index + 1;
            new_cursor = eq.new_index + 1;
        },
        .delete => |old_index| {
            try appendOpcode(&opcodes, allocator, .{ .delete = .{
                .old = .{ .start = old_index, .end = old_index + 1 },
                .new_at = new_cursor,
            } });
            old_cursor = old_index + 1;
        },
        .insert => |new_index| {
            try appendOpcode(&opcodes, allocator, .{ .insert = .{
                .old_at = old_cursor,
                .new = .{ .start = new_index, .end = new_index + 1 },
            } });
            new_cursor = new_index + 1;
        },
    };

    return compactReplacements(allocator, opcodes.items);
}

fn splitLines(allocator: Allocator, s: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try list.append(allocator, l);
    return list.toOwnedSlice(allocator);
}

const DEFAULT_CTX: u32 = 3;

fn opcodeHasChanges(opcode: Opcode) bool {
    return opcode != .equal;
}

fn findNextChange(opcodes: []const Opcode, start: usize) ?usize {
    var i = start;
    while (i < opcodes.len) : (i += 1) {
        if (opcodeHasChanges(opcodes[i])) return i;
    }
    return null;
}

fn ownLines(allocator: Allocator, source: []const []const u8, range: Range) ![]Line {
    const lines = try allocator.alloc(Line, range.len());
    var out_index: usize = 0;
    var source_index = range.start;
    errdefer {
        for (lines[0..out_index]) |line| allocator.free(line.text);
        allocator.free(lines);
    }
    while (source_index < range.end) : (source_index += 1) {
        lines[out_index] = .{ .text = try allocator.dupe(u8, source[source_index]) };
        out_index += 1;
    }
    return lines;
}

fn appendContextBlock(
    allocator: Allocator,
    blocks: *std.ArrayList(HunkBlock),
    eq: @FieldType(Opcode, "equal"),
    offset: u32,
    len: u32,
    a_lines: []const []const u8,
) !void {
    if (len == 0) return;
    try blocks.append(allocator, .{ .context = .{
        .old_start = eq.old.start + offset + 1,
        .new_start = eq.new.start + offset + 1,
        .lines = try ownLines(allocator, a_lines, .{ .start = eq.old.start + offset, .end = eq.old.start + offset + len }),
    } });
}

fn appendOpcodeBlock(
    allocator: Allocator,
    blocks: *std.ArrayList(HunkBlock),
    opcode: Opcode,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
) !void {
    switch (opcode) {
        .equal => |eq| try appendContextBlock(allocator, blocks, eq, 0, eq.old.len(), a_lines),
        .delete => |del| try blocks.append(allocator, .{ .delete = .{
            .old_start = del.old.start + 1,
            .lines = try ownLines(allocator, a_lines, del.old),
        } }),
        .insert => |ins| try blocks.append(allocator, .{ .insert = .{
            .new_start = ins.new.start + 1,
            .lines = try ownLines(allocator, b_lines, ins.new),
        } }),
        .replace => |rep| try blocks.append(allocator, .{ .replace = .{
            .old_start = rep.old.start + 1,
            .new_start = rep.new.start + 1,
            .old_lines = try ownLines(allocator, a_lines, rep.old),
            .new_lines = try ownLines(allocator, b_lines, rep.new),
        } }),
    }
}

fn makeHunk(allocator: Allocator, blocks_in: []const HunkBlock) !Hunk {
    const blocks = try allocator.dupe(HunkBlock, blocks_in);

    var old_start: u32 = 0;
    var new_start: u32 = 0;
    var old_count: u32 = 0;
    var new_count: u32 = 0;
    for (blocks) |block| {
        if (block.oldStart()) |ln| {
            if (old_start == 0) old_start = ln;
        }
        if (block.newStart()) |ln| {
            if (new_start == 0) new_start = ln;
        }
        old_count += block.oldCount();
        new_count += block.newCount();
    }

    return .{
        .old_start = if (old_count == 0) 0 else old_start,
        .old_count = old_count,
        .new_start = if (new_count == 0) 0 else new_start,
        .new_count = new_count,
        .blocks = blocks,
    };
}

fn buildHunksFromOpcodes(
    document_allocator: Allocator,
    opcodes: []const Opcode,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    ctx: u32,
) ![]Hunk {
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(document_allocator);

    var i = findNextChange(opcodes, 0) orelse return hunks.toOwnedSlice(document_allocator);
    while (i < opcodes.len) {
        var blocks: std.ArrayList(HunkBlock) = .empty;
        defer blocks.deinit(document_allocator);

        if (i > 0 and opcodes[i - 1] == .equal) {
            const eq = opcodes[i - 1].equal;
            const keep = @min(ctx, eq.old.len());
            try appendContextBlock(document_allocator, &blocks, eq, eq.old.len() - keep, keep, a_lines);
        }

        while (i < opcodes.len) {
            switch (opcodes[i]) {
                .equal => |eq| {
                    const next_change = findNextChange(opcodes, i + 1);
                    if (next_change == null) {
                        try appendContextBlock(document_allocator, &blocks, eq, 0, @min(ctx, eq.old.len()), a_lines);
                        i += 1;
                        break;
                    }
                    if (eq.old.len() > 2 * ctx) {
                        try appendContextBlock(document_allocator, &blocks, eq, 0, ctx, a_lines);
                        i = next_change.?;
                        break;
                    }
                    try appendContextBlock(document_allocator, &blocks, eq, 0, eq.old.len(), a_lines);
                    i += 1;
                },
                else => {
                    try appendOpcodeBlock(document_allocator, &blocks, opcodes[i], a_lines, b_lines);
                    i += 1;
                },
            }
        }

        try hunks.append(document_allocator, try makeHunk(document_allocator, blocks.items));
        i = findNextChange(opcodes, i) orelse break;
    }

    return hunks.toOwnedSlice(document_allocator);
}

pub const BuildOptions = struct {
    context: u32 = DEFAULT_CTX,
};

fn buildFile(
    document_allocator: Allocator,
    scratch_allocator: Allocator,
    old_path: []const u8,
    new_path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    options: BuildOptions,
) !FileChange {
    const a_lines = try splitLines(scratch_allocator, old_text);
    defer scratch_allocator.free(a_lines);
    const b_lines = try splitLines(scratch_allocator, new_text);
    defer scratch_allocator.free(b_lines);

    const opcodes = try myersOpcodes(scratch_allocator, a_lines, b_lines);
    defer scratch_allocator.free(opcodes);

    const hunks = try buildHunksFromOpcodes(document_allocator, opcodes, a_lines, b_lines, options.context);

    var stats = Stats{};
    for (hunks) |h| {
        for (h.blocks) |block| switch (block) {
            .context => {},
            .delete => |b| stats.removed += @intCast(b.lines.len),
            .insert => |b| stats.added += @intCast(b.lines.len),
            .replace => |b| {
                stats.removed += @intCast(b.old_lines.len);
                stats.added += @intCast(b.new_lines.len);
            },
        };
    }

    return .{
        .old_path = try document_allocator.dupe(u8, old_path),
        .new_path = try document_allocator.dupe(u8, new_path),
        .hunks = hunks,
        .stats = stats,
    };
}

pub fn buildDocument(
    allocator: Allocator,
    inputs: []const Input,
    options: BuildOptions,
) !OwnedDocument {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const document_allocator = arena.allocator();

    const changes = try document_allocator.alloc(FileChange, inputs.len);

    var stats = Stats{};
    for (inputs, 0..) |input, i| {
        changes[i] = try buildFile(
            document_allocator,
            allocator,
            input.old_path,
            input.new_path,
            input.old_text,
            input.new_text,
            options,
        );
        stats.add(changes[i].stats);
    }

    return .{
        .document = .{
            .changes = changes,
            .stats = stats,
        },
        .arena = arena,
    };
}

const testing = std.testing;

test "buildDocument models line states and aggregates stats" {
    const inputs = [_]Input{
        .{
            .old_path = "modify.txt",
            .new_path = "modify.txt",
            .old_text = "before\nold\nafter\n",
            .new_text = "before\nnew\nafter\n",
        },
        .{
            .old_path = "insert.txt",
            .new_path = "insert.txt",
            .old_text = "one\nthree\n",
            .new_text = "one\ntwo\nthree\n",
        },
        .{
            .old_path = "delete.txt",
            .new_path = "delete.txt",
            .old_text = "one\ntwo\nthree\n",
            .new_text = "one\nthree\n",
        },
    };

    var doc = try buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 3), doc.document.changes.len);
    try testing.expectEqual(@as(u32, 2), doc.document.stats.added);
    try testing.expectEqual(@as(u32, 2), doc.document.stats.removed);

    const modify = doc.document.changes[0];
    try testing.expectEqual(@as(u32, 1), modify.stats.added);
    try testing.expectEqual(@as(u32, 1), modify.stats.removed);
    try testing.expectEqual(@as(usize, 1), modify.hunks.len);
    try testing.expectEqual(@as(u32, 1), modify.hunks[0].old_start);
    try testing.expectEqual(@as(u32, 4), modify.hunks[0].old_count);
    try testing.expectEqual(@as(u32, 1), modify.hunks[0].new_start);
    try testing.expectEqual(@as(u32, 4), modify.hunks[0].new_count);
    try testing.expectEqual(@as(usize, 3), modify.hunks[0].blocks.len);
    try testing.expect(modify.hunks[0].blocks[0] == .context);
    try testing.expect(modify.hunks[0].blocks[1] == .replace);
    try testing.expect(modify.hunks[0].blocks[2] == .context);
    const rep = modify.hunks[0].blocks[1].replace;
    try testing.expectEqual(@as(u32, 2), rep.old_start);
    try testing.expectEqual(@as(u32, 2), rep.new_start);
    try testing.expectEqualStrings("old", rep.old_lines[0].text);
    try testing.expectEqualStrings("new", rep.new_lines[0].text);

    const insert = doc.document.changes[1];
    try testing.expectEqual(@as(u32, 1), insert.stats.added);
    try testing.expectEqual(@as(u32, 0), insert.stats.removed);
    try testing.expect(insert.hunks[0].blocks[1] == .insert);
    const ins = insert.hunks[0].blocks[1].insert;
    try testing.expectEqual(@as(u32, 2), ins.new_start);
    try testing.expectEqualStrings("two", ins.lines[0].text);

    const delete = doc.document.changes[2];
    try testing.expectEqual(@as(u32, 0), delete.stats.added);
    try testing.expectEqual(@as(u32, 1), delete.stats.removed);
    try testing.expect(delete.hunks[0].blocks[1] == .delete);
    const del = delete.hunks[0].blocks[1].delete;
    try testing.expectEqual(@as(u32, 2), del.old_start);
    try testing.expectEqualStrings("two", del.lines[0].text);
}

test "buildDocument omits hunks for unchanged files" {
    var doc = try buildDocument(testing.allocator, &[_]Input{.{
        .old_path = "same.txt",
        .new_path = "same.txt",
        .old_text = "foo\nbar\n",
        .new_text = "foo\nbar\n",
    }}, .{});
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.document.changes.len);
    try testing.expectEqual(@as(usize, 0), doc.document.changes[0].hunks.len);
    try testing.expectEqual(@as(u32, 0), doc.document.stats.added);
    try testing.expectEqual(@as(u32, 0), doc.document.stats.removed);
}

test "buildDocument separates hunks only when context gap is large" {
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
    const distant =
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
    const close =
        \\L1
        \\l2
        \\l3
        \\L4
        \\l5
        \\l6
        \\l7
        \\l8
        \\l9
        \\l10
    ;

    const inputs = [_]Input{
        .{ .old_path = "distant", .new_path = "distant", .old_text = a, .new_text = distant },
        .{ .old_path = "close", .new_path = "close", .old_text = a, .new_text = close },
    };
    var doc = try buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.document.changes[0].hunks.len);
    try testing.expectEqual(@as(usize, 1), doc.document.changes[1].hunks.len);
}
