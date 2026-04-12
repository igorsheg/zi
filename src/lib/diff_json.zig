const std = @import("std");
const diff = @import("diff.zig");

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .number_string => |s| return .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var out = std.json.Array.initCapacity(allocator, arr.items.len) catch return error.OutOfMemory;
            errdefer {
                for (out.items) |item| freeJsonValue(allocator, item);
                out.deinit();
            }
            for (arr.items) |item| try out.append(try cloneJsonValue(allocator, item));
            return .{ .array = out };
        },
        .object => |obj| {
            var out = std.json.ObjectMap.init(allocator);
            errdefer {
                const value_out: std.json.Value = .{ .object = out };
                freeJsonValue(allocator, value_out);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                try out.put(try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = out };
        },
    }
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mutable = arr;
            mutable.deinit();
        },
        .object => |obj| {
            var mutable = obj;
            var it = mutable.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            mutable.deinit();
        },
        else => {},
    }
}

pub fn toJsonValue(allocator: std.mem.Allocator, document: diff.DiffDocument) !std.json.Value {
    const text = try stringify(allocator, document);
    defer allocator.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    return try cloneJsonValue(allocator, parsed.value);
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
    try jw.objectField("lines");
    try jw.beginArray();
    for (hunk.lines) |line| try writeDiffLine(jw, line);
    try jw.endArray();
    try jw.endObject();
}

fn writeDiffLine(jw: *std.json.Stringify, line: diff.DiffLine) !void {
    try jw.beginObject();
    try jw.objectField("op");
    try jw.write(opToString(line.op));
    try jw.objectField("text");
    try jw.write(line.text);
    try jw.objectField("oldLineNo");
    if (line.old_lineno) |ln| try jw.write(ln) else try jw.write(null);
    try jw.objectField("newLineNo");
    if (line.new_lineno) |ln| try jw.write(ln) else try jw.write(null);
    try jw.endObject();
}

fn writeStats(jw: *std.json.Stringify, stats: diff.Stats) !void {
    try jw.beginObject();
    try jw.objectField("added");
    try jw.write(stats.added);
    try jw.objectField("removed");
    try jw.write(stats.removed);
    try jw.endObject();
}

pub fn parseFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !diff.DiffDocument {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return fromJsonValue(allocator, parsed.value);
}

pub fn fromJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !diff.DiffDocument {
    if (value != .object) return error.InvalidDiffDocument;
    const changes_val = value.object.get("changes") orelse return error.InvalidDiffDocument;
    if (changes_val != .array) return error.InvalidDiffDocument;

    var changes = try allocator.alloc(diff.FileChange, changes_val.array.items.len);
    var built_stats = diff.Stats{};
    var built_len: usize = 0;
    errdefer {
        for (changes[0..built_len]) |change| deinitFileChange(allocator, change);
        allocator.free(changes);
    }
    for (changes_val.array.items, 0..) |change_val, i| {
        changes[i] = try parseFileChange(allocator, change_val);
        built_len += 1;
        built_stats.add(changes[i].stats);
    }

    return .{ .changes = changes, .stats = built_stats, .allocator = allocator };
}

fn parseFileChange(allocator: std.mem.Allocator, value: std.json.Value) !diff.FileChange {
    if (value != .object) return error.InvalidDiffDocument;
    const obj = value.object;
    const old_path = obj.get("oldPath") orelse return error.InvalidDiffDocument;
    const new_path = obj.get("newPath") orelse return error.InvalidDiffDocument;
    const hunks_val = obj.get("hunks") orelse return error.InvalidDiffDocument;
    if (old_path != .string or new_path != .string or hunks_val != .array) return error.InvalidDiffDocument;

    const hunks = try allocator.alloc(diff.Hunk, hunks_val.array.items.len);
    var built_hunks: usize = 0;
    errdefer {
        for (hunks[0..built_hunks]) |hunk| {
            for (hunk.lines) |line| allocator.free(line.text);
            allocator.free(hunk.lines);
        }
        allocator.free(hunks);
    }
    for (hunks_val.array.items, 0..) |hunk_val, i| {
        hunks[i] = try parseHunk(allocator, hunk_val);
        built_hunks += 1;
    }

    var stats = diff.Stats{};
    if (obj.get("stats")) |stats_val| {
        stats = try parseStats(stats_val);
    } else {
        for (hunks) |hunk| {
            for (hunk.lines) |line| switch (line.op) {
                .insert => stats.added += 1,
                .delete => stats.removed += 1,
                .equal => {},
            };
        }
    }

    return .{
        .old_path = try allocator.dupe(u8, old_path.string),
        .new_path = try allocator.dupe(u8, new_path.string),
        .hunks = hunks,
        .stats = stats,
        .owns_paths = true,
        .owns_line_text = true,
    };
}

fn parseHunk(allocator: std.mem.Allocator, value: std.json.Value) !diff.Hunk {
    if (value != .object) return error.InvalidDiffDocument;
    const obj = value.object;
    const lines_val = obj.get("lines") orelse return error.InvalidDiffDocument;
    if (lines_val != .array) return error.InvalidDiffDocument;

    const lines = try allocator.alloc(diff.DiffLine, lines_val.array.items.len);
    var built_lines: usize = 0;
    errdefer {
        for (lines[0..built_lines]) |line| allocator.free(line.text);
        allocator.free(lines);
    }
    for (lines_val.array.items, 0..) |line_val, i| {
        lines[i] = try parseDiffLine(allocator, line_val);
        built_lines += 1;
    }

    return .{
        .old_start = try parseRequiredU32(obj, "oldStart"),
        .old_count = try parseRequiredU32(obj, "oldCount"),
        .new_start = try parseRequiredU32(obj, "newStart"),
        .new_count = try parseRequiredU32(obj, "newCount"),
        .lines = lines,
    };
}

fn parseDiffLine(allocator: std.mem.Allocator, value: std.json.Value) !diff.DiffLine {
    if (value != .object) return error.InvalidDiffDocument;
    const obj = value.object;
    const op_val = obj.get("op") orelse return error.InvalidDiffDocument;
    const text_val = obj.get("text") orelse return error.InvalidDiffDocument;
    if (op_val != .string or text_val != .string) return error.InvalidDiffDocument;

    return .{
        .op = try parseOp(op_val.string),
        .text = try allocator.dupe(u8, text_val.string),
        .old_lineno = try parseOptionalU32(obj.get("oldLineNo")),
        .new_lineno = try parseOptionalU32(obj.get("newLineNo")),
    };
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

fn parseOptionalU32(value: ?std.json.Value) !?u32 {
    const v = value orelse return null;
    return switch (v) {
        .null => null,
        .integer => |n| if (n >= 0) std.math.cast(u32, n) orelse error.InvalidDiffDocument else error.InvalidDiffDocument,
        else => error.InvalidDiffDocument,
    };
}

fn parseOp(s: []const u8) !diff.DiffOp {
    if (std.mem.eql(u8, s, "equal")) return .equal;
    if (std.mem.eql(u8, s, "insert")) return .insert;
    if (std.mem.eql(u8, s, "delete")) return .delete;
    return error.InvalidDiffDocument;
}

fn opToString(op: diff.DiffOp) []const u8 {
    return switch (op) {
        .equal => "equal",
        .insert => "insert",
        .delete => "delete",
    };
}

fn deinitFileChange(allocator: std.mem.Allocator, change: diff.FileChange) void {
    if (change.owns_paths) {
        allocator.free(change.old_path);
        allocator.free(change.new_path);
    }
    for (change.hunks) |hunk| {
        if (change.owns_line_text) {
            for (hunk.lines) |line| allocator.free(line.text);
        }
        allocator.free(hunk.lines);
    }
    allocator.free(change.hunks);
}

const testing = std.testing;

test "diff_json: stringify and parse round-trip document" {
    const inputs = [_]diff.Input{
        .{ .old_path = "a.txt", .new_path = "a.txt", .old_text = "foo\nbar\n", .new_text = "foo\nBAR\n" },
    };
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    const text = try stringify(testing.allocator, doc);
    defer testing.allocator.free(text);

    var parsed = try parseFromSlice(testing.allocator, text);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.changes.len);
    try testing.expectEqualStrings("a.txt", parsed.changes[0].old_path);
    try testing.expectEqual(@as(u32, 1), parsed.stats.added);
    try testing.expectEqual(@as(u32, 1), parsed.stats.removed);
}

test "diff_json: toJsonValue mirrors document shape" {
    const inputs = [_]diff.Input{
        .{ .old_path = "f", .new_path = "f", .old_text = "a\nb\n", .new_text = "a\nB\n" },
    };
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    const value = try toJsonValue(testing.allocator, doc);
    defer freeJsonValue(testing.allocator, value);

    try testing.expect(value == .object);
    try testing.expectEqual(@as(usize, 1), value.object.get("changes").?.array.items.len);
    try testing.expectEqualStrings("f", value.object.get("changes").?.array.items[0].object.get("oldPath").?.string);
}
