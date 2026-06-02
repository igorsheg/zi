const std = @import("std");
const CellBuffer = @import("cell_buffer.zig").CellBuffer;
const Cell = @import("cell_buffer.zig").Cell;
const FrameOutput = @import("output_buffer.zig").FrameOutput;
const ansi = @import("../substrate/ansi.zig");
const Style = @import("../primitive/style.zig").Style;
const Color = @import("../primitive/color.zig").Color;

pub const FrameDiff = struct { changed: usize = 0, mark: usize = 0 };

pub const Renderer = struct {
    current: CellBuffer,
    next: CellBuffer,
    staged: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, max_cells: usize) !Renderer {
        var c = try CellBuffer.init(allocator, width, height, max_cells);
        errdefer c.deinit();
        return .{ .current = c, .next = try CellBuffer.init(allocator, width, height, max_cells) };
    }
    pub fn deinit(self: *Renderer) void {
        self.next.deinit();
        self.current.deinit();
        self.* = undefined;
    }
    pub fn set(self: *Renderer, x: u16, y: u16, cell: Cell) !void {
        try self.next.set(x, y, cell);
    }
    pub fn writeText(self: *Renderer, x: u16, y: u16, bytes: []const u8, style: Style) !void {
        try self.next.writeText(x, y, bytes, style);
    }
    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        std.debug.assert(!self.staged);
        var current = try CellBuffer.init(self.current.allocator, width, height, self.current.max_cells);
        errdefer current.deinit();
        var next = try CellBuffer.init(self.next.allocator, width, height, self.next.max_cells);
        errdefer next.deinit();

        self.current.deinit();
        self.next.deinit();
        self.current = current;
        self.next = next;
    }
    pub fn stage(self: *Renderer, out: *FrameOutput) !FrameDiff {
        std.debug.assert(!self.staged);
        const m = out.mark();
        var diff: FrameDiff = .{ .mark = m };
        var style: Style = .{};
        var y: u16 = 0;
        errdefer out.rollback(m);
        while (y < self.next.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.next.width) : (x += 1) {
                const n = try self.next.get(x, y);
                const c = if (x < self.current.width and y < self.current.height)
                    try self.current.get(x, y)
                else
                    Cell{};
                if (n.eql(c) or isValidContinuation(self.next, x, y)) continue;
                var buf: [32]u8 = undefined;
                try out.append(try ansi.cursor(&buf, y + 1, x + 1));
                try writeStyleTransition(&style, n.style, out);
                style = n.style;
                try writeCell(n, out);
                diff.changed += 1;
            }
        }
        try out.append(ansi.reset);
        self.staged = true;
        return diff;
    }
    pub fn commit(self: *Renderer) void {
        std.debug.assert(self.staged);
        @memcpy(self.current.cells, self.next.cells);
        self.staged = false;
    }
    pub fn discard(self: *Renderer) void {
        self.staged = false;
    }
    pub fn render(self: *Renderer, out: *FrameOutput) !void {
        _ = try self.stage(out);
        self.commit();
    }
};

fn isValidContinuation(buffer: CellBuffer, x: u16, y: u16) bool {
    const cell = buffer.get(x, y) catch return false;
    if (cell.kind != .wide_continuation) return false;
    if (x == 0) return false;
    const head = buffer.get(x - 1, y) catch return false;
    return head.kind == .wide_head;
}

fn writeCell(cell: Cell, out: *FrameOutput) !void {
    const scalar = cell.renderScalar() orelse ' ';
    var enc: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(scalar, &enc) catch blk: {
        enc[0] = '?';
        break :blk 1;
    };
    try out.append(enc[0..len]);
}
fn writeStyleTransition(current: *Style, next: Style, out: *FrameOutput) !void {
    if (!colorEql(current.fg, next.fg)) try writeColor(next.fg, true, out);
    if (!colorEql(current.bg, next.bg)) try writeColor(next.bg, false, out);
    if (current.bold != next.bold) try out.append(if (next.bold) "\x1b[1m" else "\x1b[22m");
    if (current.underline != next.underline) try out.append(if (next.underline) "\x1b[4m" else "\x1b[24m");
}
fn writeColor(color: Color, foreground: bool, out: *FrameOutput) !void {
    var buf: [32]u8 = undefined;
    const bytes = switch (color) {
        .default => if (foreground) "\x1b[39m" else "\x1b[49m",
        .indexed => |i| if (foreground)
            try std.fmt.bufPrint(&buf, "\x1b[38;5;{d}m", .{i})
        else
            try std.fmt.bufPrint(&buf, "\x1b[48;5;{d}m", .{i}),
        .rgb => |c| if (foreground)
            try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b })
        else
            try std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
    };
    try out.append(bytes);
}
fn colorEql(a: Color, b: Color) bool {
    return switch (a) {
        .default => b == .default,
        .indexed => |i| switch (b) {
            .indexed => |j| i == j,
            else => false,
        },
        .rgb => |x| switch (b) {
            .rgb => |y| x.r == y.r and x.g == y.g and x.b == y.b,
            else => false,
        },
    };
}

test "renderer stages commits retries style and wide continuation skip" {
    var r = try Renderer.init(std.testing.allocator, 3, 1, 3);
    defer r.deinit();
    var storage: [256]u8 = undefined;
    var out = FrameOutput.init(&storage);
    try r.writeText(0, 0, "中", .{ .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .bold = true });
    const d = try r.stage(&out);
    try std.testing.expectEqual(@as(usize, 1), d.changed);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1b[38;2;1;2;3m") != null);
    r.discard();
    const len = out.len();
    _ = try r.stage(&out);
    try std.testing.expect(out.len() > len);
    r.commit();
}

test "renderer rolls back on no space" {
    var r = try Renderer.init(std.testing.allocator, 1, 1, 1);
    defer r.deinit();
    try r.set(0, 0, Cell.scalar('x', .{}));
    var storage: [2]u8 = undefined;
    var out = FrameOutput.init(&storage);
    try std.testing.expectError(error.NoSpaceLeft, r.stage(&out));
    try std.testing.expectEqual(@as(usize, 0), out.len());
}
