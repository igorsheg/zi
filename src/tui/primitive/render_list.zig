const std = @import("std");
const vaxis = @import("vaxis");

const document_mod = @import("document.zig");
const text = @import("text.zig");

pub const Row = struct {
    block_id: document_mod.BlockId,
    block_revision: u64,
    line_index: usize,
    text: []const u8,
};

pub const RenderList = struct {
    rows: std.ArrayListUnmanaged(Row) = .empty,

    pub fn deinit(self: *RenderList, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = undefined;
    }

    pub fn rebuild(
        self: *RenderList,
        allocator: std.mem.Allocator,
        document: *const document_mod.Document,
        width_columns: u16,
    ) !void {
        self.rows.clearRetainingCapacity();
        if (width_columns == 0) return;
        for (document.blocks.items) |*block| {
            try appendBlockRows(allocator, &self.rows, block, width_columns);
        }
    }
};

fn appendBlockRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    block: *const document_mod.Block,
    width_columns: u16,
) !void {
    if (block.bytes.items.len == 0) {
        try rows.append(allocator, .{
            .block_id = block.id,
            .block_revision = block.revision,
            .line_index = 0,
            .text = "",
        });
        return;
    }

    var line_index: usize = 0;
    var line_start: usize = 0;
    var column: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(block.bytes.items);
    while (iter.next()) |grapheme| {
        const grapheme_bytes = block.bytes.items[grapheme.start..][0..grapheme.len];
        if (grapheme_bytes[0] == '\n') {
            try appendRow(allocator, rows, block, line_index, line_start, grapheme.start);
            line_index += 1;
            line_start = grapheme.start + grapheme.len;
            column = 0;
            continue;
        }

        const grapheme_width = text.displayWidth(grapheme_bytes);
        if (grapheme_width == 0) continue;
        if (column != 0 and column + grapheme_width > width_columns) {
            try appendRow(allocator, rows, block, line_index, line_start, grapheme.start);
            line_index += 1;
            line_start = grapheme.start;
            column = 0;
        }
        column = @min(width_columns, column + grapheme_width);
    }
    try appendRow(allocator, rows, block, line_index, line_start, block.bytes.items.len);
}

fn appendRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    block: *const document_mod.Block,
    line_index: usize,
    start: usize,
    end: usize,
) !void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= block.bytes.items.len);
    try rows.append(allocator, .{
        .block_id = block.id,
        .block_revision = block.revision,
        .line_index = line_index,
        .text = block.bytes.items[start..end],
    });
}

pub fn rowCount(document: *const document_mod.Document, width_columns: u16) usize {
    if (width_columns == 0) return 0;
    var count: usize = 0;
    for (document.blocks.items) |*block| {
        count += text.wrappedRowCount(block.bytes.items, width_columns);
    }
    return count;
}

test "render list projects document rows without owning text" {
    var document = document_mod.Document.init(.{});
    defer document.deinit(std.testing.allocator);
    const id = try document.appendBlock(std.testing.allocator);
    try document.appendText(std.testing.allocator, id, "abcd");

    var list: RenderList = .{};
    defer list.deinit(std.testing.allocator);
    try list.rebuild(std.testing.allocator, &document, 3);

    try std.testing.expectEqual(@as(usize, 2), list.rows.items.len);
    try std.testing.expectEqualStrings("abc", list.rows.items[0].text);
    try std.testing.expectEqualStrings("d", list.rows.items[1].text);
    try std.testing.expectEqual(id, list.rows.items[0].block_id);
}
