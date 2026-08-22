const std = @import("std");
const Surface = @import("Surface.zig");

/// A contiguous row span that must be repainted. Columns are inclusive.
pub const RowSpan = struct {
    row: u16,
    first_column: u16,
    last_column: u16,
};

pub const RowBounds = struct {
    top: u16,
    bottom: u16,

    pub fn empty() RowBounds {
        return .{ .top = 0, .bottom = 0 };
    }

    pub fn isEmpty(self: RowBounds) bool {
        return self.top == 0 and self.bottom == 0;
    }
};

/// Allocation-free iterator over rows whose rendered content differs.
pub const Iterator = struct {
    previous: ?*const Surface,
    current: *const Surface,
    next_row: u16,
    last_row: u16,
    full_repaint: bool,

    pub fn init(previous: ?*const Surface, current: *const Surface) Iterator {
        return initUnchecked(previous, current, .{ .top = 1, .bottom = current.rows });
    }

    /// Restricts every emitted span to an admitted row band. A renderer can use
    /// this to prove that preserved normal-buffer rows are never repainted.
    pub fn initBounded(
        previous: ?*const Surface,
        current: *const Surface,
        bounds: RowBounds,
    ) !Iterator {
        if (bounds.isEmpty()) return initUnchecked(previous, current, bounds);
        if (bounds.top == 0 or bounds.bottom < bounds.top or bounds.bottom > current.rows) {
            return error.InvalidRowBounds;
        }
        return initUnchecked(previous, current, bounds);
    }

    fn initUnchecked(
        previous: ?*const Surface,
        current: *const Surface,
        bounds: RowBounds,
    ) Iterator {
        return .{
            .previous = previous,
            .current = current,
            .next_row = bounds.top,
            .last_row = bounds.bottom,
            .full_repaint = previous == null or
                previous.?.rows != current.rows or previous.?.columns != current.columns,
        };
    }

    pub fn next(self: *Iterator) ?RowSpan {
        while (self.next_row != 0 and self.next_row <= self.last_row) {
            const row = self.next_row;
            self.next_row = if (row == self.last_row) 0 else row + 1;
            if (self.full_repaint or !Surface.rowEqual(self.previous.?, self.current, row)) {
                return .{
                    .row = row,
                    .first_column = 1,
                    .last_column = self.current.columns,
                };
            }
        }
        return null;
    }
};

test "diff emits nothing for identical frames" {
    var previous = try Surface.init(std.testing.allocator, 2, 4);
    defer previous.deinit();
    _ = try previous.writeText(1, 1, "same", .{});
    var current = try previous.clone(std.testing.allocator);
    defer current.deinit();

    var iterator = Iterator.init(&previous, &current);
    try std.testing.expect(iterator.next() == null);
}

test "diff emits one changed row span" {
    var previous = try Surface.init(std.testing.allocator, 3, 4);
    defer previous.deinit();
    var current = try previous.clone(std.testing.allocator);
    defer current.deinit();
    _ = try current.writeText(2, 2, "x", .{});

    var iterator = Iterator.init(&previous, &current);
    const expected: RowSpan = .{
        .row = 2,
        .first_column = 1,
        .last_column = 4,
    };
    try std.testing.expectEqual(expected, iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "bounded diff cannot emit changes in preserved rows" {
    var previous = try Surface.init(std.testing.allocator, 4, 4);
    defer previous.deinit();
    _ = try previous.writeText(1, 1, "old", .{});
    var current = try previous.clone(std.testing.allocator);
    defer current.deinit();
    _ = try current.writeText(1, 1, "new", .{});
    _ = try current.writeText(3, 1, "own", .{});

    var iterator = try Iterator.initBounded(&previous, &current, .{ .top = 2, .bottom = 4 });
    try std.testing.expectEqual(@as(u16, 3), iterator.next().?.row);
    try std.testing.expect(iterator.next() == null);
}

test "bounded full repaint remains inside owned rows after resize" {
    var previous = try Surface.init(std.testing.allocator, 5, 4);
    defer previous.deinit();
    var current = try previous.blankResizedClone(std.testing.allocator, 4, 6);
    defer current.deinit();

    var iterator = try Iterator.initBounded(&previous, &current, .{ .top = 3, .bottom = 4 });
    try std.testing.expectEqual(@as(u16, 3), iterator.next().?.row);
    try std.testing.expectEqual(@as(u16, 4), iterator.next().?.row);
    try std.testing.expect(iterator.next() == null);
}

test "bounded diff accepts an empty band and rejects invalid bounds" {
    var current = try Surface.init(std.testing.allocator, 3, 4);
    defer current.deinit();

    var empty = try Iterator.initBounded(null, &current, .empty());
    try std.testing.expect(empty.next() == null);
    try std.testing.expectError(
        error.InvalidRowBounds,
        Iterator.initBounded(null, &current, .{ .top = 0, .bottom = 2 }),
    );
    try std.testing.expectError(
        error.InvalidRowBounds,
        Iterator.initBounded(null, &current, .{ .top = 2, .bottom = 4 }),
    );
}

test "diff compares graphemes semantically rather than by store ID" {
    var previous = try Surface.init(std.testing.allocator, 1, 4);
    defer previous.deinit();
    _ = try previous.writeText(1, 1, "界", .{});

    var current = try Surface.init(std.testing.allocator, 1, 4);
    defer current.deinit();
    _ = try current.writeText(1, 1, "x", .{});
    _ = try current.writeText(1, 1, "界", .{});
    try std.testing.expect(previous.cells[0].grapheme.? != current.cells[0].grapheme.?);

    var iterator = Iterator.init(&previous, &current);
    try std.testing.expect(iterator.next() == null);
}

test "diff repaints every row without a previous frame or after resize" {
    var previous = try Surface.init(std.testing.allocator, 2, 3);
    defer previous.deinit();
    var current = try Surface.init(std.testing.allocator, 3, 4);
    defer current.deinit();

    var absent_iterator = Iterator.init(null, &current);
    for (1..4) |row| {
        const expected: RowSpan = .{
            .row = @intCast(row),
            .first_column = 1,
            .last_column = 4,
        };
        try std.testing.expectEqual(expected, absent_iterator.next().?);
    }
    try std.testing.expect(absent_iterator.next() == null);

    var resized_iterator = Iterator.init(&previous, &current);
    for (1..4) |row| {
        const expected: RowSpan = .{
            .row = @intCast(row),
            .first_column = 1,
            .last_column = 4,
        };
        try std.testing.expectEqual(expected, resized_iterator.next().?);
    }
    try std.testing.expect(resized_iterator.next() == null);
}
