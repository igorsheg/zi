const std = @import("std");
const text = @import("../text/root.zig");

pub const marker_cells: usize = 2;
pub const current_tag_cells: usize = 11;
pub const detail_separator_cells: usize = 2;
pub const dim_detail_separator_cells: usize = 3;

pub const Item = struct {
    label: []const u8,
    detail: ?[]const u8 = null,
    dim: bool = false,
    current: bool = false,
    label_color: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const Options = struct {
    title: ?[]const u8 = null,
    items: []const Item,
    empty_message: ?[]const u8 = null,
    initial_index: usize = 0,
    repeat_clipped_label: bool = false,
};

pub const Limits = struct {
    max_items: usize = 4096,
    max_query_bytes: usize = 4096,
    max_frame_bytes: usize = 256 * 1024,
};

pub const Direction = enum { previous, next };

pub const Core = struct {
    allocator: std.mem.Allocator,
    options: Options,
    limits: Limits,
    matches: []usize,
    match_count: usize = 0,
    selection: usize = 0,
    first_visible: usize = 0,
    viewport_rows: usize = 1,
    query: std.ArrayList(u8) = .empty,

    pub const Error = error{ OutOfMemory, TooManyItems, InvalidLimits };

    pub fn init(
        allocator: std.mem.Allocator,
        options: Options,
        limits: Limits,
    ) Error!Core {
        if (limits.max_items == 0 or limits.max_query_bytes == 0 or limits.max_frame_bytes == 0) {
            return error.InvalidLimits;
        }
        if (options.items.len > limits.max_items) return error.TooManyItems;
        const matches = allocator.alloc(usize, options.items.len) catch return error.OutOfMemory;
        var core: Core = .{
            .allocator = allocator,
            .options = options,
            .limits = limits,
            .matches = matches,
        };
        core.updateMatches();
        if (options.initial_index != 0) core.selectItem(options.initial_index);
        return core;
    }

    pub fn deinit(self: *Core) void {
        self.allocator.free(self.matches);
        self.query.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn selectedItemIndex(self: *const Core) ?usize {
        if (self.match_count == 0) return null;
        return self.matches[self.selection];
    }

    pub fn setViewportRows(self: *Core, rows: usize) void {
        self.viewport_rows = @max(rows, 1);
        self.clampView();
    }

    pub fn appendQuery(self: *Core, bytes: []const u8) error{OutOfMemory}!void {
        if (bytes.len > self.limits.max_query_bytes -| self.query.items.len) return;
        self.query.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
        self.updateMatches();
    }

    pub fn backspaceQuery(self: *Core) void {
        if (self.query.items.len == 0) return;
        var index = self.query.items.len - 1;
        while (index != 0 and self.query.items[index] & 0xc0 == 0x80) index -= 1;
        self.query.shrinkRetainingCapacity(index);
        self.updateMatches();
    }

    pub fn clearQuery(self: *Core) void {
        if (self.query.items.len == 0) return;
        self.query.clearRetainingCapacity();
        self.updateMatches();
    }

    pub fn updateMatches(self: *Core) void {
        self.match_count = 0;
        for (self.options.items, 0..) |item, index| {
            if (!matchesQuery(item.label, self.query.items)) continue;
            self.matches[self.match_count] = index;
            self.match_count += 1;
        }
        self.selection = 0;
        self.first_visible = 0;
    }

    pub fn clampView(self: *Core) void {
        if (self.match_count == 0) {
            self.selection = 0;
            self.first_visible = 0;
            return;
        }
        const visible_rows = @max(self.viewport_rows, 1);
        self.selection = @min(self.selection, self.match_count - 1);
        if (self.selection < self.first_visible) {
            self.first_visible = self.selection;
        } else if (self.selection >= self.first_visible +| visible_rows) {
            self.first_visible = self.selection - visible_rows + 1;
        }
        if (self.match_count <= visible_rows) {
            self.first_visible = 0;
        } else if (self.first_visible > self.match_count - visible_rows) {
            self.first_visible = self.match_count - visible_rows;
        }
    }

    pub fn moveSelection(self: *Core, direction: Direction) void {
        if (self.match_count == 0) return;
        switch (direction) {
            .previous => self.selection -|= 1,
            .next => if (self.selection + 1 < self.match_count) {
                self.selection += 1;
            },
        }
        self.clampView();
    }

    pub fn pageSelection(self: *Core, direction: Direction) void {
        if (self.match_count == 0) return;
        const step = @max(self.viewport_rows / 2, 1);
        switch (direction) {
            .previous => self.selection -|= step,
            .next => self.selection = @min(self.selection +| step, self.match_count - 1),
        }
        self.centerSelection();
    }

    pub fn selectFirst(self: *Core) void {
        self.selection = 0;
        self.clampView();
    }

    pub fn selectLast(self: *Core) void {
        self.selection = if (self.match_count == 0) 0 else self.match_count - 1;
        self.clampView();
    }

    pub fn selectItem(self: *Core, item_index: usize) void {
        for (self.matches[0..self.match_count], 0..) |index, match_index| {
            if (index != item_index) continue;
            self.selection = match_index;
            self.centerSelection();
            return;
        }
    }

    fn centerSelection(self: *Core) void {
        const visible_rows = @max(self.viewport_rows, 1);
        if (self.match_count <= visible_rows) {
            self.first_visible = 0;
            return;
        }
        const half_viewport = visible_rows / 2;
        self.first_visible = self.selection -| half_viewport;
        self.first_visible = @min(self.first_visible, self.match_count - visible_rows);
    }
};

pub fn matchesQuery(label: []const u8, query: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < query.len) {
        while (cursor < query.len and query[cursor] == ' ') cursor += 1;
        const start = cursor;
        while (cursor < query.len and query[cursor] != ' ') cursor += 1;
        if (cursor != start and !containsAsciiCaseInsensitive(label, query[start..cursor])) return false;
    }
    return true;
}

fn containsAsciiCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var equal = true;
        for (needle, haystack[start..][0..needle.len]) |left, right| {
            if (std.ascii.toLower(left) != std.ascii.toLower(right)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

pub fn textCells(value: []const u8) usize {
    const line_end = std.mem.indexOfAny(u8, value, "\r\n") orelse value.len;
    return text.DisplayWidth.visibleWidth(value[0..line_end], std.math.maxInt(usize)) +
        @intFromBool(line_end < value.len);
}

pub fn labelCells(item: Item, terminal_columns: usize) usize {
    const row_cells = @max(terminal_columns -| marker_cells, 1);
    const current_cells = if (item.current) current_tag_cells else 0;
    const available_cells = row_cells -| current_cells;
    const detail = item.detail orelse return @max(available_cells, 1);
    if (detail.len == 0) return @max(available_cells, 1);
    const separator_cells = if (item.dim) dim_detail_separator_cells else detail_separator_cells;
    const adjusted = available_cells -| separator_cells -| textCells(detail);
    const minimum = available_cells / 2;
    return @max(@min(textCells(item.label), @max(minimum, adjusted)), 1);
}

fn testItems() [6]Item {
    return .{
        .{ .label = "Alpha release" },
        .{ .label = "beta alpha" },
        .{ .label = "Gamma" },
        .{ .label = "delta" },
        .{ .label = "epsilon" },
        .{ .label = "zeta" },
    };
}

test "query terms filter in any order and reset selection" {
    const items = testItems();
    var core = try Core.init(std.testing.allocator, .{ .items = &items }, .{});
    defer core.deinit();
    core.moveSelection(.next);
    try core.appendQuery("ALPHA  beta");
    try std.testing.expectEqual(@as(usize, 1), core.match_count);
    try std.testing.expectEqual(@as(?usize, 1), core.selectedItemIndex());
    try std.testing.expectEqual(@as(usize, 0), core.selection);
    core.clearQuery();
    try std.testing.expectEqual(items.len, core.match_count);
}

test "navigation clamps and pages by half a centered viewport" {
    const items = testItems();
    var core = try Core.init(std.testing.allocator, .{ .items = &items }, .{});
    defer core.deinit();
    core.setViewportRows(4);
    core.moveSelection(.previous);
    try std.testing.expectEqual(@as(usize, 0), core.selection);
    core.pageSelection(.next);
    try std.testing.expectEqual(@as(usize, 2), core.selection);
    try std.testing.expectEqual(@as(usize, 0), core.first_visible);
    core.pageSelection(.next);
    try std.testing.expectEqual(@as(usize, 4), core.selection);
    try std.testing.expectEqual(@as(usize, 2), core.first_visible);
    core.selectLast();
    core.moveSelection(.next);
    try std.testing.expectEqual(@as(usize, 5), core.selection);
}

test "query is bounded and backspace removes one UTF-8 sequence" {
    const items = [_]Item{.{ .label = "é" }};
    var core = try Core.init(std.testing.allocator, .{ .items = &items }, .{ .max_query_bytes = 2 });
    defer core.deinit();
    try core.appendQuery("é");
    try core.appendQuery("x");
    try std.testing.expectEqualStrings("é", core.query.items);
    core.backspaceQuery();
    try std.testing.expectEqualStrings("", core.query.items);
}

test "text and label cells match picker row policy" {
    try std.testing.expectEqual(@as(usize, 4), textCells("abc\nrest"));
    try std.testing.expectEqual(@as(usize, 98), labelCells(.{ .label = "x" ** 100 }, 100));
    try std.testing.expectEqual(@as(usize, 87), labelCells(.{ .label = "x" ** 100, .current = true }, 100));
    try std.testing.expectEqual(@as(usize, 90), labelCells(.{ .label = "x" ** 95, .detail = "3m ago" }, 100));
    try std.testing.expectEqual(@as(usize, 49), labelCells(.{ .label = "x" ** 95, .detail = "d" ** 90 }, 100));
}

test "item and configured bounds reject excess work" {
    const items = [_]Item{ .{ .label = "a" }, .{ .label = "b" } };
    try std.testing.expectError(error.TooManyItems, Core.init(
        std.testing.allocator,
        .{ .items = &items },
        .{ .max_items = 1 },
    ));
    try std.testing.expectError(error.InvalidLimits, Core.init(
        std.testing.allocator,
        .{ .items = &items },
        .{ .max_frame_bytes = 0 },
    ));
}
