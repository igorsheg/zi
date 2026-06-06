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
    pub fn fillRect(self: *Renderer, x: u16, y: u16, w: u16, h: u16, style: Style) !void {
        try self.next.fillRect(x, y, w, h, style);
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
    const inline_text = cell.renderText() orelse {
        try out.append(" ");
        return;
    };
    try out.append(inline_text.slice());
}
fn writeStyleTransition(current: *Style, next: Style, out: *FrameOutput) !void {
    if (!current.fg.eql(next.fg)) try writeColor(next.fg, true, out);
    if (!current.bg.eql(next.bg)) try writeColor(next.bg, false, out);
    if (current.bold != next.bold or current.dim != next.dim) {
        if (!next.bold and !next.dim) {
            try out.append("\x1b[22m");
        } else if (current.bold or current.dim) {
            try out.append("\x1b[22m");
            if (next.bold) try out.append("\x1b[1m");
            if (next.dim) try out.append("\x1b[2m");
        } else {
            if (next.bold) try out.append("\x1b[1m");
            if (next.dim) try out.append("\x1b[2m");
        }
    }
    if (current.underline != next.underline) try out.append(if (next.underline) "\x1b[4m" else "\x1b[24m");
}
fn writeColor(color: Color, foreground: bool, out: *FrameOutput) !void {
    var buf: [32]u8 = undefined;
    try out.append(try color.ansiBytes(foreground, &buf));
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

test "renderer emits dim intensity transitions" {
    var r = try Renderer.init(std.testing.allocator, 2, 1, 2);
    defer r.deinit();
    var storage: [256]u8 = undefined;
    var out = FrameOutput.init(&storage);

    try r.writeText(0, 0, "a", .{ .dim = true });
    try r.writeText(1, 0, "b", .{ .bold = true });
    _ = try r.stage(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1b[2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes(), "\x1b[22m\x1b[1m") != null);
}

test "renderer fills styled blank cells" {
    var r = try Renderer.init(std.testing.allocator, 3, 1, 3);
    defer r.deinit();
    try r.fillRect(0, 0, 3, 1, .{ .bg = .{ .indexed = 236 } });
    try std.testing.expect((try r.next.get(0, 0)).style.eql(.{ .bg = .{ .indexed = 236 } }));
    try std.testing.expect((try r.next.get(2, 0)).style.eql(.{ .bg = .{ .indexed = 236 } }));
}

test "renderer emits complete grapheme bytes" {
    var r = try Renderer.init(std.testing.allocator, 8, 1, 8);
    defer r.deinit();
    var storage: [512]u8 = undefined;
    var out = FrameOutput.init(&storage);

    try r.writeText(0, 0, "o\u{0300}中👩🏽‍🚀", .{});
    const diff = try r.stage(&out);
    try std.testing.expectEqual(@as(usize, 3), diff.changed);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes(), "o\u{0300}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes(), "中") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes(), "👩🏽‍🚀") != null);
    r.commit();
}

test "renderer clips wide grapheme at right edge" {
    var r = try Renderer.init(std.testing.allocator, 1, 1, 1);
    defer r.deinit();
    var storage: [128]u8 = undefined;
    var out = FrameOutput.init(&storage);

    try r.writeText(0, 0, "中", .{});
    const diff = try r.stage(&out);
    try std.testing.expectEqual(@as(usize, 0), diff.changed);
    try std.testing.expect((try r.next.get(0, 0)).kind == .empty);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes(), "中") == null);
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

test "renderer failed stage leaves transaction uncommitted" {
    var r = try Renderer.init(std.testing.allocator, 1, 1, 1);
    defer r.deinit();
    try r.set(0, 0, Cell.scalar('x', .{}));
    var storage: [2]u8 = undefined;
    var out = FrameOutput.init(&storage);

    try std.testing.expectError(error.NoSpaceLeft, r.stage(&out));
    try std.testing.expect(!r.staged);
    try std.testing.expect((try r.current.get(0, 0)).kind == .empty);
    try std.testing.expectEqual(@as(u21, 'x'), (try r.next.get(0, 0)).renderScalar().?);
}

test "renderer discard does not update current" {
    var r = try Renderer.init(std.testing.allocator, 2, 1, 2);
    defer r.deinit();
    var storage: [128]u8 = undefined;
    var out = FrameOutput.init(&storage);

    try r.writeText(0, 0, "x", .{});
    _ = try r.stage(&out);
    r.discard();
    try std.testing.expect(!r.staged);
    try std.testing.expect((try r.current.get(0, 0)).kind == .empty);

    out.reset();
    _ = try r.stage(&out);
    r.commit();
    try std.testing.expectEqual(@as(u21, 'x'), (try r.current.get(0, 0)).renderScalar().?);
}
