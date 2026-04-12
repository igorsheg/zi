const std = @import("std");
const diff = @import("diff.zig");

pub fn toUnified(allocator: std.mem.Allocator, document: diff.DiffDocument) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    if (document.changes.len == 0) return out.toOwnedSlice();

    for (document.changes, 0..) |change, change_index| {
        try w.print("--- {s}\n+++ {s}\n", .{ change.old_path, change.new_path });
        for (change.hunks) |h| {
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
        if (change_index + 1 < document.changes.len) try w.writeByte('\n');
    }

    return out.toOwnedSlice();
}

fn writeRange(w: *std.Io.Writer, start: u32, count: u32) !void {
    try w.print("{d},{d}", .{ start, count });
}

const testing = std.testing;

test "toUnified: emits multiple file sections" {
    const inputs = [_]diff.Input{
        .{ .old_path = "a.txt", .new_path = "a.txt", .old_text = "foo\nbar\n", .new_text = "foo\nBAR\n" },
        .{ .old_path = "b.txt", .new_path = "b.txt", .old_text = "one\ntwo\n", .new_text = "one\ntwo\nthree\n" },
    };
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    const out = try toUnified(testing.allocator, doc);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "--- a.txt\n+++ a.txt\n@@ ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--- b.txt\n+++ b.txt\n@@ ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "+three\n") != null);
}

test "toUnified: no-change document still emits headers per file" {
    const inputs = [_]diff.Input{
        .{ .old_path = "f", .new_path = "f", .old_text = "foo\nbar\n", .new_text = "foo\nbar\n" },
    };
    var doc = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer doc.deinit();

    const out = try toUnified(testing.allocator, doc);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("--- f\n+++ f\n", out);
}
