const std = @import("std");
const surface_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const grapheme = @import("../grapheme.zig");

const Allocator = std.mem.Allocator;
pub const Region = surface_mod.Region;
pub const Color = cell_mod.Color;
pub const Attributes = cell_mod.Attributes;

pub const Style = struct {
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},
};

pub const Segment = struct {
    x: u32,
    text: []const u8,
    style: Style = .{},
    link_id: u16 = 0,
};

pub const Row = struct {
    segments: []const Segment = &.{},
};

pub const Key = struct {
    width: u32 = 0,
    width_method: grapheme.WidthMethod = .wcwidth,
    expanded: bool = false,
};

pub const Builder = struct {
    allocator: Allocator,
    rows: std.ArrayListUnmanaged(Row) = .empty,

    pub fn init(allocator: Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn appendRow(self: *Builder, segments: []const Segment) !void {
        try self.rows.append(self.allocator, .{ .segments = segments });
    }

    pub fn appendSegments(self: *Builder, segments: []const Segment) !void {
        const owned = try self.allocator.dupe(Segment, segments);
        try self.appendRow(owned);
    }

    pub fn appendText(self: *Builder, x: u32, text: []const u8, style: Style) !void {
        const segments = try self.allocator.alloc(Segment, 1);
        segments[0] = .{ .x = x, .text = text, .style = style };
        try self.appendRow(segments);
    }

    pub fn appendBlank(self: *Builder) !void {
        try self.appendRow(&.{});
    }

    pub fn toOwnedRows(self: *Builder) ![]const Row {
        return try self.rows.toOwnedSlice(self.allocator);
    }
};

pub const Retained = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row = &.{},
    key: Key = .{},
    valid: bool = false,

    pub fn init(parent_allocator: Allocator) Retained {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_allocator) };
    }

    pub fn deinit(self: *Retained) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn invalidate(self: *Retained) void {
        self.valid = false;
    }

    pub fn reset(self: *Retained) Allocator {
        _ = self.arena.reset(.retain_capacity);
        self.rows = &.{};
        self.valid = false;
        return self.arena.allocator();
    }

    pub fn setRows(self: *Retained, key: Key, rows: []const Row) void {
        self.rows = rows;
        self.key = key;
        self.valid = true;
    }

    pub fn matches(self: *const Retained, key: Key) bool {
        return self.valid and self.key.width == key.width and self.key.width_method == key.width_method and self.key.expanded == key.expanded;
    }

    pub fn measure(self: *const Retained) u32 {
        return @intCast(self.rows.len);
    }

    pub fn renderSlice(self: *const Retained, region: Region, first_row: u32) void {
        renderRowsSlice(self.rows, region, first_row);
    }
};

pub fn renderRowsSlice(rows: []const Row, region: Region, first_row: u32) void {
    if (first_row >= rows.len) return;
    var y: u32 = 0;
    var idx: usize = @intCast(first_row);
    while (idx < rows.len and y < region.height) : ({ idx += 1; y += 1; }) {
        renderRow(rows[idx], region, y);
    }
}

pub fn renderRow(row: Row, region: Region, y: u32) void {
    for (row.segments) |segment| {
        _ = region.writeStrLink(segment.x, y, segment.text, segment.style.fg, segment.style.bg, segment.style.attrs, segment.link_id);
    }
}
