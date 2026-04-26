const std = @import("std");
const diff = @import("diff.zig");
const json_util = @import("../ai/json_util.zig");

pub fn toJsonValue(allocator: std.mem.Allocator, document: diff.DiffDocument) !std.json.Value {
    const text = try stringify(allocator, document);
    defer allocator.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    return try json_util.cloneJsonValue(allocator, parsed.value);
}

pub fn stringify(allocator: std.mem.Allocator, document: diff.DiffDocument) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("changes");
    try jw.beginArray();
    for (document.changes) |change| try writeFileChange(&jw, change);
    try jw.endArray();
    try jw.objectField("stats");
    try writeStats(&jw, document.stats);
    try jw.endObject();
    return out.toOwnedSlice();
}

fn writeFileChange(jw: *std.json.Stringify, change: diff.FileChange) !void {
    try jw.beginObject();
    try jw.objectField("oldPath");
    try jw.write(change.old_path);
    try jw.objectField("newPath");
    try jw.write(change.new_path);
    try jw.objectField("hunks");
    try jw.beginArray();
    for (change.hunks) |hunk| try writeHunk(jw, hunk);
    try jw.endArray();
    try jw.objectField("stats");
    try writeStats(jw, change.stats);
    try jw.endObject();
}

fn writeHunk(jw: *std.json.Stringify, hunk: diff.Hunk) !void {
    try jw.beginObject();
    try jw.objectField("oldStart");
    try jw.write(hunk.old_start);
    try jw.objectField("oldCount");
    try jw.write(hunk.old_count);
    try jw.objectField("newStart");
    try jw.write(hunk.new_start);
    try jw.objectField("newCount");
    try jw.write(hunk.new_count);
    try jw.objectField("blocks");
    try jw.beginArray();
    for (hunk.blocks) |block| try writeBlock(jw, block);
    try jw.endArray();
    try jw.endObject();
}

fn writeBlock(jw: *std.json.Stringify, block: diff.HunkBlock) !void {
    try jw.beginObject();
    switch (block) {
        .context => |ctx| {
            try jw.objectField("op");
            try jw.write("context");
            try jw.objectField("oldStart");
            try jw.write(ctx.old_start);
            try jw.objectField("newStart");
            try jw.write(ctx.new_start);
            try jw.objectField("lines");
            try writeLines(jw, ctx.lines);
        },
        .delete => |del| {
            try jw.objectField("op");
            try jw.write("delete");
            try jw.objectField("oldStart");
            try jw.write(del.old_start);
            try jw.objectField("lines");
            try writeLines(jw, del.lines);
        },
        .insert => |ins| {
            try jw.objectField("op");
            try jw.write("insert");
            try jw.objectField("newStart");
            try jw.write(ins.new_start);
            try jw.objectField("lines");
            try writeLines(jw, ins.lines);
        },
        .replace => |rep| {
            try jw.objectField("op");
            try jw.write("replace");
            try jw.objectField("oldStart");
            try jw.write(rep.old_start);
            try jw.objectField("newStart");
            try jw.write(rep.new_start);
            try jw.objectField("oldLines");
            try writeLines(jw, rep.old_lines);
            try jw.objectField("newLines");
            try writeLines(jw, rep.new_lines);
        },
    }
    try jw.endObject();
}

fn writeLines(jw: *std.json.Stringify, lines: []const diff.Line) !void {
    try jw.beginArray();
    for (lines) |line| try jw.write(line.text);
    try jw.endArray();
}

fn writeStats(jw: *std.json.Stringify, stats: diff.Stats) !void {
    try jw.beginObject();
    try jw.objectField("added");
    try jw.write(stats.added);
    try jw.objectField("removed");
    try jw.write(stats.removed);
    try jw.endObject();
}

pub fn parseFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !diff.OwnedDocument {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return fromJsonValue(allocator, parsed.value);
}

pub fn fromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !diff.OwnedDocument {
    if (value != .object) return error.InvalidDiffDocument;
    const changes_val = value.object.get("changes") orelse return error.InvalidDiffDocument;
    if (changes_val != .array) return error.InvalidDiffDocument;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const document_allocator = arena.allocator();

    const changes = try document_allocator.alloc(diff.FileChange, changes_val.array.items.len);
    var built_stats = diff.Stats{};
    for (changes_val.array.items, 0..) |change_val, i| {
        changes[i] = try parseFileChange(document_allocator, change_val);
        built_stats.add(changes[i].stats);
    }

    return .{
        .document = .{
            .changes = changes,
            .stats = built_stats,
        },
        .arena = arena,
    };
}

fn parseFileChange(allocator: std.mem.Allocator, value: std.json.Value) !diff.FileChange {
    if (value != .object) return error.InvalidDiffDocument;
    const obj = value.object;
    const old_path = obj.get("oldPath") orelse return error.InvalidDiffDocument;
    const new_path = obj.get("newPath") orelse return error.InvalidDiffDocument;
    const hunks_val = obj.get("hunks") orelse return error.InvalidDiffDocument;
    if (old_path != .string or new_path != .string or hunks_val != .array) return error.InvalidDiffDocument;

    const hunks = try allocator.alloc(diff.Hunk, hunks_val.array.items.len);
    for (hunks_val.array.items, 0..) |hunk_val, i| hunks[i] = try parseHunk(allocator, hunk_val);

    var stats = diff.Stats{};
    if (obj.get("stats")) |stats_val| {
        stats = try parseStats(stats_val);
    } else {
        stats = countStats(hunks);
    }

    return .{
        .old_path = try allocator.dupe(u8, old_path.string),
        .new_path = try allocator.dupe(u8, new_path.string),
        .hunks = hunks,
        .stats = stats,
    };
}

fn parseHunk(allocator: std.mem.Allocator, value: std.json.Value) !diff.Hunk {
    if (value != .object) return error.InvalidDiffDocument;
    const obj = value.object;
    const blocks_val = obj.get("blocks") orelse return error.InvalidDiffDocument;
    if (blocks_val != .array) return error.InvalidDiffDocument;

    const blocks = try allocator.alloc(diff.HunkBlock, blocks_val.array.items.len);
    for (blocks_val.array.items, 0..) |block_val, i| blocks[i] = try parseBlock(allocator, block_val);

    return .{
        .old_start = try parseRequiredU32(obj, "oldStart"),
        .old_count = try parseRequiredU32(obj, "oldCount"),
        .new_start = try parseRequiredU32(obj, "newStart"),
        .new_count = try parseRequiredU32(obj, "newCount"),
        .blocks = blocks,
    };
}

fn parseBlock(allocator: std.mem.Allocator, value: std.json.Value) !diff.HunkBlock {
    if (value != .object) return error.InvalidDiffDocument;
    const obj = value.object;
    const op_val = obj.get("op") orelse return error.InvalidDiffDocument;
    if (op_val != .string) return error.InvalidDiffDocument;

    if (std.mem.eql(u8, op_val.string, "context")) return .{ .context = .{
        .old_start = try parseRequiredU32(obj, "oldStart"),
        .new_start = try parseRequiredU32(obj, "newStart"),
        .lines = try parseLines(allocator, obj.get("lines") orelse return error.InvalidDiffDocument),
    } };
    if (std.mem.eql(u8, op_val.string, "delete")) return .{ .delete = .{
        .old_start = try parseRequiredU32(obj, "oldStart"),
        .lines = try parseLines(allocator, obj.get("lines") orelse return error.InvalidDiffDocument),
    } };
    if (std.mem.eql(u8, op_val.string, "insert")) return .{ .insert = .{
        .new_start = try parseRequiredU32(obj, "newStart"),
        .lines = try parseLines(allocator, obj.get("lines") orelse return error.InvalidDiffDocument),
    } };
    if (std.mem.eql(u8, op_val.string, "replace")) return .{ .replace = .{
        .old_start = try parseRequiredU32(obj, "oldStart"),
        .new_start = try parseRequiredU32(obj, "newStart"),
        .old_lines = try parseLines(allocator, obj.get("oldLines") orelse return error.InvalidDiffDocument),
        .new_lines = try parseLines(allocator, obj.get("newLines") orelse return error.InvalidDiffDocument),
    } };
    return error.InvalidDiffDocument;
}

fn parseLines(allocator: std.mem.Allocator, value: std.json.Value) ![]diff.Line {
    if (value != .array) return error.InvalidDiffDocument;
    const lines = try allocator.alloc(diff.Line, value.array.items.len);
    for (value.array.items, 0..) |line_val, i| {
        if (line_val != .string) return error.InvalidDiffDocument;
        lines[i] = .{ .text = try allocator.dupe(u8, line_val.string) };
    }
    return lines;
}

fn parseStats(value: std.json.Value) !diff.Stats {
    if (value != .object) return error.InvalidDiffDocument;
    return .{
        .added = try parseRequiredU32(value.object, "added"),
        .removed = try parseRequiredU32(value.object, "removed"),
    };
}

fn parseRequiredU32(obj: std.json.ObjectMap, field: []const u8) !u32 {
    const value = obj.get(field) orelse return error.InvalidDiffDocument;
    return switch (value) {
        .integer => |n| if (n >= 0) std.math.cast(u32, n) orelse error.InvalidDiffDocument else error.InvalidDiffDocument,
        else => error.InvalidDiffDocument,
    };
}

fn countStats(hunks: []const diff.Hunk) diff.Stats {
    var stats = diff.Stats{};
    for (hunks) |hunk| for (hunk.blocks) |block| switch (block) {
        .context => {},
        .delete => |b| stats.removed += @intCast(b.lines.len),
        .insert => |b| stats.added += @intCast(b.lines.len),
        .replace => |b| {
            stats.removed += @intCast(b.old_lines.len);
            stats.added += @intCast(b.new_lines.len);
        },
    };
    return stats;
}

const testing = std.testing;

test "diff_json round-trips block document" {
    const inputs = [_]diff.Input{.{ .old_path = "a.txt", .new_path = "a.txt", .old_text = "foo\nbar\n", .new_text = "foo\nBAR\n" }};
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    const text = try stringify(testing.allocator, doc.document);
    defer testing.allocator.free(text);

    var parsed = try parseFromSlice(testing.allocator, text);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.document.changes.len);
    try testing.expectEqualStrings("a.txt", parsed.document.changes[0].old_path);
    try testing.expectEqual(@as(u32, 1), parsed.document.stats.added);
    try testing.expectEqual(@as(u32, 1), parsed.document.stats.removed);
    try testing.expect(parsed.document.changes[0].hunks[0].blocks[1] == .replace);
}

test "diff_json toJsonValue mirrors document shape" {
    const inputs = [_]diff.Input{.{ .old_path = "f", .new_path = "f", .old_text = "a\nb\n", .new_text = "a\nB\n" }};
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    const value = try toJsonValue(testing.allocator, doc.document);
    defer json_util.freeJsonValue(testing.allocator, value);

    try testing.expect(value == .object);
    try testing.expectEqual(@as(usize, 1), value.object.get("changes").?.array.items.len);
    const hunk = value.object.get("changes").?.array.items[0].object.get("hunks").?.array.items[0];
    try testing.expect(hunk.object.get("blocks") != null);
}
