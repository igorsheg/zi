const std = @import("std");
const diff = @import("diff.zig");

const Allocator = std.mem.Allocator;

pub const RowKind = enum {
    context,
    added,
    removed,
    gap,
};

pub const Row = struct {
    kind: RowKind,
    text: []const u8 = "",
    old_lineno: ?u32 = null,
    new_lineno: ?u32 = null,
    gap_count: u32 = 0,
};

pub const FileView = struct {
    path: []const u8,
    stats: diff.Stats,
    rows: []const Row,
};

pub const DiffView = struct {
    files: []const FileView,
    stats: diff.Stats,
    allocator: Allocator,

    pub fn deinit(self: *DiffView) void {
        for (self.files) |file| self.allocator.free(file.rows);
        self.allocator.free(self.files);
    }
};

pub fn buildView(allocator: Allocator, document: diff.DiffDocument) !DiffView {
    const files = try allocator.alloc(FileView, document.changes.len);
    errdefer allocator.free(files);

    var built: usize = 0;
    errdefer {
        for (files[0..built]) |file| allocator.free(file.rows);
    }

    for (document.changes, 0..) |change, i| {
        files[i] = try buildFileView(allocator, change);
        built += 1;
    }

    return .{
        .files = files,
        .stats = document.stats,
        .allocator = allocator,
    };
}

fn buildFileView(allocator: Allocator, change: diff.FileChange) !FileView {
    var rows_list: std.ArrayList(Row) = .empty;
    errdefer rows_list.deinit(allocator);

    var previous_hunk_end: ?u32 = null;
    for (change.hunks) |hunk| {
        if (previous_hunk_end) |old_end| {
            if (hunk.old_start > old_end) {
                try rows_list.append(allocator, .{
                    .kind = .gap,
                    .gap_count = hunk.old_start - old_end,
                });
            }
        }
        previous_hunk_end = hunk.old_start + hunk.old_count;

        for (hunk.lines) |line| {
            try rows_list.append(allocator, .{
                .kind = switch (line.op) {
                    .equal => .context,
                    .insert => .added,
                    .delete => .removed,
                },
                .text = line.text,
                .old_lineno = line.old_lineno,
                .new_lineno = line.new_lineno,
            });
        }
    }

    return .{
        .path = change.new_path,
        .stats = change.stats,
        .rows = try rows_list.toOwnedSlice(allocator),
    };
}

const testing = std.testing;

test "diff_view inserts gap rows between distant hunks" {
    const inputs = [_]diff.Input{
        .{
            .old_path = "f.txt",
            .new_path = "f.txt",
            .old_text =
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
            ,
            .new_text =
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
            ,
        },
    };
    var document = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer document.deinit();

    var view = try buildView(testing.allocator, document);
    defer view.deinit();

    try testing.expectEqual(@as(usize, 1), view.files.len);
    var saw_gap = false;
    for (view.files[0].rows) |row| {
        if (row.kind == .gap) {
            saw_gap = true;
            try testing.expectEqual(@as(u32, 1), row.gap_count);
        }
    }
    try testing.expect(saw_gap);
}

test "diff_view keeps per-file paths separate from row content" {
    const inputs = [_]diff.Input{
        .{ .old_path = "a.txt", .new_path = "a.txt", .old_text = "a\n", .new_text = "A\n" },
        .{ .old_path = "b.txt", .new_path = "b.txt", .old_text = "b\n", .new_text = "B\n" },
    };
    var document = try diff.buildDocument(testing.allocator, &inputs, .{});
    defer document.deinit();

    var view = try buildView(testing.allocator, document);
    defer view.deinit();

    try testing.expectEqual(@as(usize, 2), view.files.len);
    try testing.expectEqualStrings("a.txt", view.files[0].path);
    try testing.expectEqualStrings("b.txt", view.files[1].path);
    for (view.files[1].rows) |row| {
        try testing.expect(row.kind != .gap or row.gap_count > 0);
    }
}
