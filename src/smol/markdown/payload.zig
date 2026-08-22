// Ported from vercel-labs/fx src/core/agent/presentation/payload.zig at commit 5ed3be1.
// Licensed under Apache-2.0 and adapted for Zi.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TableColumnAlign = enum { left, right, center };

pub const TableRow = struct {
    cells: [][]u8,
};

pub const TablePayload = struct {
    rows: []TableRow,
    alignments: []TableColumnAlign,
    column_count: usize,

    pub fn deinit(self: *TablePayload, alloc: Allocator) void {
        deinitTableRows(alloc, self.rows);
        alloc.free(self.rows);
        alloc.free(self.alignments);
        self.* = undefined;
    }

    pub fn clone(self: TablePayload, alloc: Allocator) !TablePayload {
        const rows = try alloc.alloc(TableRow, self.rows.len);
        var copied_rows: usize = 0;
        errdefer {
            deinitTableRows(alloc, rows[0..copied_rows]);
            alloc.free(rows);
        }

        for (self.rows, 0..) |row, row_index| {
            const cells = try alloc.alloc([]u8, row.cells.len);
            var copied_cells: usize = 0;
            errdefer {
                for (cells[0..copied_cells]) |cell| alloc.free(cell);
                alloc.free(cells);
            }
            for (row.cells, 0..) |cell, cell_index| {
                cells[cell_index] = try alloc.dupe(u8, cell);
                copied_cells += 1;
            }
            rows[row_index] = .{ .cells = cells };
            copied_rows += 1;
        }

        const alignments = try alloc.dupe(TableColumnAlign, self.alignments);
        errdefer alloc.free(alignments);
        return .{
            .rows = rows,
            .alignments = alignments,
            .column_count = self.column_count,
        };
    }
};

pub const CodeBlockPayload = struct {
    language: []u8,
    code: []u8,

    pub fn deinit(self: *CodeBlockPayload, alloc: Allocator) void {
        alloc.free(self.language);
        alloc.free(self.code);
        self.* = undefined;
    }

    pub fn clone(self: CodeBlockPayload, alloc: Allocator) !CodeBlockPayload {
        const language = try alloc.dupe(u8, self.language);
        errdefer alloc.free(language);
        return .{
            .language = language,
            .code = try alloc.dupe(u8, self.code),
        };
    }
};

pub const TableCompletion = struct {
    ctx: *anyopaque,
    /// Takes ownership of `table` only when it returns successfully.
    deliver: *const fn (ctx: *anyopaque, table: TablePayload, out: *std.ArrayList(u8)) anyerror!void,
};

pub const CodeBlockCompletion = struct {
    ctx: *anyopaque,
    /// Takes ownership of `block` only when it returns successfully.
    deliver: *const fn (ctx: *anyopaque, block: CodeBlockPayload, out: *std.ArrayList(u8)) anyerror!void,
};

pub const ThematicRuleCompletion = struct {
    ctx: *anyopaque,
    deliver: *const fn (ctx: *anyopaque, out: *std.ArrayList(u8)) anyerror!void,
};

pub const MarkdownCompletions = struct {
    table: ?*const TableCompletion = null,
    code: ?*const CodeBlockCompletion = null,
    thematic_rule: ?*const ThematicRuleCompletion = null,
};

pub fn deinitTableRows(alloc: Allocator, rows: []TableRow) void {
    for (rows) |row| {
        for (row.cells) |cell| alloc.free(cell);
        alloc.free(row.cells);
    }
}

pub const FootnoteSink = struct {
    ctx: *anyopaque,
    register: *const fn (alloc: Allocator, ctx: *anyopaque, label: []const u8) anyerror!usize,
};

test "table payload clone and deinit" {
    const cell = try std.testing.allocator.dupe(u8, "a");
    defer std.testing.allocator.free(cell);
    const cells = [_][]u8{cell};
    var rows = [_]TableRow{.{ .cells = @constCast(&cells) }};
    var alignments = [_]TableColumnAlign{.left};
    var table = try (TablePayload{
        .rows = rows[0..],
        .alignments = alignments[0..],
        .column_count = 1,
    }).clone(std.testing.allocator);
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a", table.rows[0].cells[0]);
    try std.testing.expectEqual(@as(usize, 1), table.column_count);
}

test "code block payload clone and deinit" {
    var original: CodeBlockPayload = .{
        .language = try std.testing.allocator.dupe(u8, "zig"),
        .code = try std.testing.allocator.dupe(u8, "fn main() {}"),
    };
    defer original.deinit(std.testing.allocator);
    var block = try original.clone(std.testing.allocator);
    defer block.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig", block.language);
    try std.testing.expectEqualStrings("fn main() {}", block.code);
}
