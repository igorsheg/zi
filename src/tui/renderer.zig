const std = @import("std");
const runtime_fd = @import("terminal/fd.zig");
const ansi = @import("terminal/ansi.zig");
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Buffer = buffer_mod.Buffer;
const Region = buffer_mod.Region;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    current: Buffer,
    next: Buffer,
    output: std.ArrayListUnmanaged(u8) = .empty,
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    force_redraw: bool,

    pub fn init(allocator: std.mem.Allocator, fd: std.posix.fd_t, width: u32, height: u32) !Renderer {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacity(allocator, @as(usize, width) * @as(usize, height) * 4);

        var current = try Buffer.init(allocator, width, height);
        errdefer current.deinit();
        var next = try Buffer.init(allocator, width, height);
        errdefer next.deinit();

        return .{
            .allocator = allocator,
            .current = current,
            .next = next,
            .output = output,
            .fd = fd,
            .width = width,
            .height = height,
            .force_redraw = true,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.current.deinit();
        self.next.deinit();
        self.output.deinit(self.allocator);
    }

    pub fn begin(self: *Renderer) Region {
        self.next.clear();
        return self.next.region();
    }

    pub fn end(self: *Renderer) !void {
        self.output.clearRetainingCapacity();

        appendStr(self, ansi.sync_enable);

        var last_fg: ?Color = null;
        var last_bg: ?Color = null;
        var last_attrs: ?Attributes = null;

        const row_width: usize = @intCast(self.width);
        for (0..self.height) |y_usize| {
            const y: u32 = @intCast(y_usize);
            const row_start = y_usize * row_width;
            const current_row = self.current.cells[row_start .. row_start + row_width];
            const next_row = self.next.cells[row_start .. row_start + row_width];

            var x_usize: usize = 0;
            while (x_usize < row_width) : (x_usize += 1) {
                const curr = current_row[x_usize];
                const next_cell = next_row[x_usize];
                if (!self.force_redraw and curr.eql(next_cell)) continue;

                appendCursorPos(self, @intCast(x_usize), y);

                while (x_usize < row_width) : (x_usize += 1) {
                    const run_curr = current_row[x_usize];
                    const run_next = next_row[x_usize];
                    if (!self.force_redraw and run_curr.eql(run_next)) break;

                    if (last_fg == null or !last_fg.?.eql(run_next.fg)) {
                        appendFgColor(self, run_next.fg);
                        last_fg = run_next.fg;
                    }

                    if (last_bg == null or !last_bg.?.eql(run_next.bg)) {
                        appendBgColor(self, run_next.bg);
                        last_bg = run_next.bg;
                    }

                    if (last_attrs == null or !last_attrs.?.eql(run_next.attrs)) {
                        appendAttrs(self, run_next.attrs);
                        last_attrs = run_next.attrs;
                    }

                    if (run_next.width != 0) {
                        appendGrapheme(self, run_next.grapheme, &self.next.grapheme_pool);
                    }
                }

                if (x_usize == row_width) break;
            }
        }

        appendStr(self, ansi.reset);
        appendStr(self, ansi.sync_disable);

        writeAll(self.fd, self.output.items);

        std.mem.swap(Buffer, &self.current, &self.next);
        self.force_redraw = false;
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) !void {
        try self.current.resize(width, height);
        try self.next.resize(width, height);
        self.width = width;
        self.height = height;
        self.force_redraw = true;
    }

    pub fn forceRedraw(self: *Renderer) void {
        self.force_redraw = true;
    }
};

fn appendStr(self: *Renderer, s: []const u8) void {
    self.output.appendSlice(self.allocator, s) catch return;
}

fn appendCursorPos(self: *Renderer, x: u32, y: u32) void {
    var buf: [32]u8 = undefined;
    const s = ansi.formatCursorPos(&buf, x, y) catch return;
    self.output.appendSlice(self.allocator, s) catch return;
}

fn appendFgColor(self: *Renderer, fg: Color) void {
    switch (fg) {
        .default_color => appendStr(self, ansi.default_fg),
        .rgb24 => |rgb| {
            var buf: [24]u8 = undefined;
            const s = ansi.formatFgRgb(&buf, rgb.r, rgb.g, rgb.b) catch return;
            self.output.appendSlice(self.allocator, s) catch return;
        },
        .index => |index| {
            var buf: [16]u8 = undefined;
            const s = ansi.formatFgIndex(&buf, index) catch return;
            self.output.appendSlice(self.allocator, s) catch return;
        },
    }
}

fn appendBgColor(self: *Renderer, bg: Color) void {
    switch (bg) {
        .default_color => appendStr(self, ansi.default_bg),
        .rgb24 => |rgb| {
            var buf: [24]u8 = undefined;
            const s = ansi.formatBgRgb(&buf, rgb.r, rgb.g, rgb.b) catch return;
            self.output.appendSlice(self.allocator, s) catch return;
        },
        .index => |index| {
            var buf: [16]u8 = undefined;
            const s = ansi.formatBgIndex(&buf, index) catch return;
            self.output.appendSlice(self.allocator, s) catch return;
        },
    }
}

fn appendAttrs(self: *Renderer, attrs: Attributes) void {
    appendStr(self, ansi.attrs_reset);
    if (attrs.bold) appendStr(self, ansi.bold);
    if (attrs.dim) appendStr(self, ansi.dim);
    if (attrs.italic) appendStr(self, ansi.italic);
    if (attrs.underline) appendStr(self, ansi.underline);
    if (attrs.blink) appendStr(self, ansi.blink);
    if (attrs.inverse) appendStr(self, ansi.inverse);
    if (attrs.hidden) appendStr(self, ansi.hidden);
    if (attrs.strikethrough) appendStr(self, ansi.strikethrough);
}

fn appendGrapheme(self: *Renderer, grapheme: cell_mod.Grapheme, pool: *const buffer_mod.GraphemePool) void {
    switch (grapheme) {
        .codepoint => |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return;
            self.output.appendSlice(self.allocator, buf[0..len]) catch return;
        },
        .pooled => |id| {
            const bytes = pool.get(id);
            self.output.appendSlice(self.allocator, bytes) catch return;
        },
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var buf: [4096]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buf);
    writer.interface.writeAll(data) catch return;
    writer.interface.flush() catch {};
}

fn testPipe() ![2]std.posix.fd_t {
    return runtime_fd.pipe();
}

fn readPipe(read_fd: std.posix.fd_t, buf: []u8) ![]const u8 {
    const n = try std.posix.read(read_fd, buf);
    return buf[0..n];
}

test "Renderer owns its buffers and resize resets drawing state" {
    var r = try Renderer.init(std.testing.allocator, std.posix.STDOUT_FILENO, 10, 5);
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 10), r.width);
    try std.testing.expectEqual(@as(u32, 5), r.height);
    try std.testing.expectEqual(@as(u32, 10), r.current.width);
    try std.testing.expectEqual(@as(u32, 5), r.next.height);
    try std.testing.expect(r.force_redraw);

    r.force_redraw = false;
    try r.resize(3, 2);
    try std.testing.expectEqual(@as(u32, 3), r.width);
    try std.testing.expectEqual(@as(u32, 2), r.height);
    try std.testing.expectEqual(@as(usize, 6), r.current.cells.len);
    try std.testing.expectEqual(@as(usize, 6), r.next.cells.len);
    try std.testing.expect(r.force_redraw);
}

test "Renderer begin exposes a cleared full-frame region" {
    var r = try Renderer.init(std.testing.allocator, std.posix.STDOUT_FILENO, 10, 5);
    defer r.deinit();

    r.next.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'X' } });

    const reg = r.begin();
    try std.testing.expectEqual(@as(u32, 10), reg.width);
    try std.testing.expectEqual(@as(u32, 5), reg.height);
    try std.testing.expect(reg.get(0, 0).eql(Cell.blank));

    reg.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'Y' } });
    try std.testing.expectEqual(@as(u21, 'Y'), r.next.get(0, 0).grapheme.codepoint);
}

test "Renderer end writes a frame and promotes it to current" {
    const pipe = try testPipe();
    defer runtime_fd.close(pipe[0]);
    defer runtime_fd.close(pipe[1]);

    var r = try Renderer.init(std.testing.allocator, pipe[1], 5, 1);
    defer r.deinit();

    const reg = r.begin();
    _ = reg.writeStr(0, 0, "A", Color.rgb(255, 0, 0), Color.default, Attributes.none);
    try r.end();

    var read_buf: [4096]u8 = undefined;
    const output = try readPipe(pipe[0], &read_buf);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.sync_enable) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.sync_disable) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expectEqual(@as(u21, 'A'), r.current.get(0, 0).grapheme.codepoint);
    try std.testing.expect(!r.force_redraw);
}

test "Renderer diffs subsequent frames and clears deleted cells" {
    const pipe = try testPipe();
    defer runtime_fd.close(pipe[0]);
    defer runtime_fd.close(pipe[1]);

    var r = try Renderer.init(std.testing.allocator, pipe[1], 10, 1);
    defer r.deinit();

    {
        const reg = r.begin();
        _ = reg.writeStr(0, 0, "abc", Color.default, Color.default, Attributes.none);
        try r.end();
        var drain: [4096]u8 = undefined;
        _ = try readPipe(pipe[0], &drain);
    }

    {
        const reg = r.begin();
        _ = reg.writeStr(0, 0, "abc", Color.default, Color.default, Attributes.none);
        try r.end();
        var read_buf: [4096]u8 = undefined;
        const output = try readPipe(pipe[0], &read_buf);
        try std.testing.expect(std.mem.indexOf(u8, output, "abc") == null);
    }

    {
        const reg = r.begin();
        _ = reg.writeStr(0, 0, "ab", Color.default, Color.default, Attributes.none);
        try r.end();

        var read_buf: [4096]u8 = undefined;
        const output = try readPipe(pipe[0], &read_buf);
        try std.testing.expect(std.mem.indexOf(u8, output, ansi.sync_enable) != null);
        try std.testing.expect(std.mem.indexOf(u8, output, ansi.sync_disable) != null);
        try std.testing.expectEqual(@as(u21, 'a'), r.current.get(0, 0).grapheme.codepoint);
        try std.testing.expectEqual(@as(u21, 'b'), r.current.get(1, 0).grapheme.codepoint);
        try std.testing.expectEqual(@as(u21, ' '), r.current.get(2, 0).grapheme.codepoint);
    }
}
