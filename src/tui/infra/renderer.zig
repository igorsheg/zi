const std = @import("std");
const CellBuffer = @import("cell_buffer.zig").CellBuffer;
const Cell = @import("cell_buffer.zig").Cell;
const OutputBuffer = @import("output_buffer.zig").OutputBuffer;

pub const Renderer = struct {
    current: CellBuffer,
    next: CellBuffer,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, max_cells: usize) !Renderer {
        var current = try CellBuffer.init(allocator, width, height, max_cells);
        errdefer current.deinit();

        return .{
            .current = current,
            .next = try CellBuffer.init(allocator, width, height, max_cells),
        };
    }
    pub fn deinit(self: *Renderer) void { self.next.deinit(); self.current.deinit(); self.* = undefined; }
    pub fn set(self: *Renderer, x: u16, y: u16, cell: Cell) !void { try self.next.set(x, y, cell); }
    pub fn render(self: *Renderer, out: *OutputBuffer) !void {
        var y: u16 = 0;
        while (y < self.next.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.next.width) : (x += 1) {
                const n = try self.next.get(x, y);
                const c = try self.current.get(x, y);
                if (n.ch == c.ch and n.style.eql(c.style)) continue;
                var buf: [32]u8 = undefined;
                const seq = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
                try out.append(seq);
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(n.ch, &enc) catch 1;
                if (len == 1 and n.ch > 0x7f) enc[0] = '?';
                try out.append(enc[0..len]);
            }
        }
        @memcpy(self.current.cells, self.next.cells);
    }
};

test "renderer emits nothing for identical frame and bytes for changed cell" {
    var r = try Renderer.init(std.testing.allocator, 2, 1, 2);
    defer r.deinit();
    var storage: [128]u8 = undefined;
    var out = OutputBuffer.init(&storage);
    try r.render(&out);
    try std.testing.expectEqual(@as(usize, 0), out.slice().len);
    try r.set(1, 0, .{ .ch = 'x' });
    try r.render(&out);
    try std.testing.expectEqualStrings("\x1b[1;2Hx", out.slice());
}
