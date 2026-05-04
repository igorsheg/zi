const std = @import("std");
const testing = std.testing;

pub const Excerpt = struct {
    focus: Focus,
    context: u32,

    pub const Focus = union(enum) {
        head: void,
        tail: void,
        around: u32,
    };
};

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const WindowItem = union(enum) {
    span: Span,
    gap: u32,
};

pub const WindowResult = struct {
    items: []WindowItem,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WindowResult) void {
        self.allocator.free(self.items);
    }
};

const Range = struct {
    start: u32,
    end: u32,
};

pub fn windowExcerpts(allocator: std.mem.Allocator, total: u32, excerpts: []const Excerpt) !WindowResult {
    if (excerpts.len == 0 or total == 0) {
        const items = try allocator.alloc(WindowItem, 1);
        items[0] = .{ .span = .{ .start = 0, .end = total } };
        return .{ .items = items, .allocator = allocator };
    }

    var ranges = try allocator.alloc(Range, excerpts.len);
    defer allocator.free(ranges);

    for (excerpts, 0..) |ex, i| {
        ranges[i] = switch (ex.focus) {
            .head => .{
                .start = 0,
                .end = @min(ex.context, total) -| 1,
            },
            .tail => .{
                .start = total -| ex.context,
                .end = total - 1,
            },
            .around => |idx| .{
                .start = idx -| ex.context,
                .end = @min(idx + ex.context, total - 1),
            },
        };
    }

    std.mem.sort(Range, ranges, {}, struct {
        fn cmp(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.cmp);

    var merge_len: usize = 1;
    for (ranges[1..]) |r| {
        const last = &ranges[merge_len - 1];
        if (r.start <= last.end + 1) {
            last.end = @max(last.end, r.end);
        } else {
            ranges[merge_len] = r;
            merge_len += 1;
        }
    }
    const merged = ranges[0..merge_len];

    var item_count: usize = merged.len;
    if (merged[0].start > 0) item_count += 1;
    for (merged[0 .. merged.len - 1], merged[1..]) |prev, cur| {
        if (cur.start > prev.end + 1) item_count += 1;
    }
    if (merged[merged.len - 1].end + 1 < total) item_count += 1;

    const items = try allocator.alloc(WindowItem, item_count);
    var idx: usize = 0;

    var prev_end: u32 = 0;
    for (merged) |r| {
        if (r.start > prev_end) {
            items[idx] = .{ .gap = r.start - prev_end };
            idx += 1;
        }
        items[idx] = .{ .span = .{ .start = r.start, .end = r.end + 1 } };
        idx += 1;
        prev_end = r.end + 1;
    }
    if (prev_end < total) {
        items[idx] = .{ .gap = total - prev_end };
        idx += 1;
    }

    return .{ .items = items[0..idx], .allocator = allocator };
}

test "tail excerpt shows last N lines with gap" {
    var result = try windowExcerpts(testing.allocator, 100, &.{
        .{ .focus = .tail, .context = 5 },
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.items.len);
    try testing.expectEqual(WindowItem{ .gap = 95 }, result.items[0]);
    try testing.expectEqual(WindowItem{ .span = .{ .start = 95, .end = 100 } }, result.items[1]);
}

test "head + tail excerpts merge when overlapping" {
    var result = try windowExcerpts(testing.allocator, 8, &.{
        .{ .focus = .head, .context = 5 },
        .{ .focus = .tail, .context = 5 },
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqual(WindowItem{ .span = .{ .start = 0, .end = 8 } }, result.items[0]);
}

test "head + tail excerpts with gap" {
    var result = try windowExcerpts(testing.allocator, 20, &.{
        .{ .focus = .head, .context = 3 },
        .{ .focus = .tail, .context = 5 },
    });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.items.len);
    try testing.expectEqual(WindowItem{ .span = .{ .start = 0, .end = 3 } }, result.items[0]);
    try testing.expectEqual(WindowItem{ .gap = 12 }, result.items[1]);
    try testing.expectEqual(WindowItem{ .span = .{ .start = 15, .end = 20 } }, result.items[2]);
}
