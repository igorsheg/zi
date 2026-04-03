const std = @import("std");
const cell_mod = @import("cell.zig");
const buffer_mod = @import("buffer.zig");
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Buffer = buffer_mod.Buffer;
const Region = buffer_mod.Region;

pub const Renderer = struct {
    current: Buffer,
    next: Buffer,
    output: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    force_redraw: bool,

    pub fn init(allocator: std.mem.Allocator, fd: std.posix.fd_t, width: u32, height: u32) !Renderer {
        return .{
            .current = try Buffer.init(allocator, width, height),
            .next = try Buffer.init(allocator, width, height),
            .output = .empty,
            .allocator = allocator,
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

        appendStr(&self.output, self.allocator, "\x1b[?2026h");

        var last_fg: ?Color = null;
        var last_bg: ?Color = null;
        var last_attrs: ?Attributes = null;

        for (0..self.height) |y_usize| {
            const y: u32 = @intCast(y_usize);
            for (0..self.width) |x_usize| {
                const x: u32 = @intCast(x_usize);
                const curr = self.current.get(x, y);
                const next_cell = self.next.get(x, y);

                if (!self.force_redraw and curr.eql(next_cell)) continue;

                appendCursorPos(&self.output, self.allocator, x, y);

                if (last_fg == null or !last_fg.?.eql(next_cell.fg)) {
                    appendFgColor(&self.output, self.allocator, next_cell.fg);
                    last_fg = next_cell.fg;
                }

                if (last_bg == null or !last_bg.?.eql(next_cell.bg)) {
                    appendBgColor(&self.output, self.allocator, next_cell.bg);
                    last_bg = next_cell.bg;
                }

                if (last_attrs == null or !last_attrs.?.eql(next_cell.attrs)) {
                    appendAttrs(&self.output, self.allocator, next_cell.attrs);
                    last_attrs = next_cell.attrs;
                }

                if (next_cell.width == 0) continue;

                appendGrapheme(&self.output, self.allocator, next_cell.grapheme, &self.next.grapheme_pool);
            }
        }

        appendStr(&self.output, self.allocator, "\x1b[0m");
        appendStr(&self.output, self.allocator, "\x1b[?2026l");

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

fn appendStr(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) void {
    out.appendSlice(alloc, s) catch return;
}

fn appendCursorPos(out: *std.ArrayList(u8), alloc: std.mem.Allocator, x: u32, y: u32) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch return;
    out.appendSlice(alloc, s) catch return;
}

fn appendFgColor(out: *std.ArrayList(u8), alloc: std.mem.Allocator, fg: Color) void {
    if (fg.is_default) {
        appendStr(out, alloc, "\x1b[39m");
    } else {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ fg.r, fg.g, fg.b }) catch return;
        out.appendSlice(alloc, s) catch return;
    }
}

fn appendBgColor(out: *std.ArrayList(u8), alloc: std.mem.Allocator, bg: Color) void {
    if (bg.is_default) {
        appendStr(out, alloc, "\x1b[49m");
    } else {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};{d}m", .{ bg.r, bg.g, bg.b }) catch return;
        out.appendSlice(alloc, s) catch return;
    }
}

fn appendAttrs(out: *std.ArrayList(u8), alloc: std.mem.Allocator, attrs: Attributes) void {
    appendStr(out, alloc, "\x1b[22;23;24;25;27;28;29m");
    if (attrs.bold) appendStr(out, alloc, "\x1b[1m");
    if (attrs.dim) appendStr(out, alloc, "\x1b[2m");
    if (attrs.italic) appendStr(out, alloc, "\x1b[3m");
    if (attrs.underline) appendStr(out, alloc, "\x1b[4m");
    if (attrs.blink) appendStr(out, alloc, "\x1b[5m");
    if (attrs.inverse) appendStr(out, alloc, "\x1b[7m");
    if (attrs.hidden) appendStr(out, alloc, "\x1b[8m");
    if (attrs.strikethrough) appendStr(out, alloc, "\x1b[9m");
}

fn appendGrapheme(out: *std.ArrayList(u8), alloc: std.mem.Allocator, grapheme: cell_mod.Grapheme, pool: *const buffer_mod.GraphemePool) void {
    switch (grapheme) {
        .codepoint => |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return;
            out.appendSlice(alloc, buf[0..len]) catch return;
        },
        .pooled => |id| {
            const bytes = pool.get(id);
            out.appendSlice(alloc, bytes) catch return;
        },
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        written += std.posix.write(fd, data[written..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return,
        };
    }
}

test "Renderer init and deinit" {
    var r = try Renderer.init(std.testing.allocator, std.posix.STDOUT_FILENO, 10, 5);
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 10), r.width);
    try std.testing.expectEqual(@as(u32, 5), r.height);
    try std.testing.expect(r.force_redraw);
}

test "Renderer begin returns cleared buffer region" {
    var r = try Renderer.init(std.testing.allocator, std.posix.STDOUT_FILENO, 10, 5);
    defer r.deinit();

    const reg = r.begin();
    try std.testing.expectEqual(@as(u32, 10), reg.width);
    try std.testing.expectEqual(@as(u32, 5), reg.height);

    reg.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'X' } });
    try std.testing.expectEqual(@as(u21, 'X'), r.next.get(0, 0).grapheme.codepoint);
}

test "Renderer diff produces output for changed cells" {
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    var r = try Renderer.init(std.testing.allocator, pipe[1], 5, 1);
    defer r.deinit();

    const reg = r.begin();
    reg.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'A' }, .fg = Color.rgb(255, 0, 0) });
    try r.end();

    var read_buf: [4096]u8 = undefined;
    const n = try std.posix.read(pipe[0], &read_buf);
    const output = read_buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[?2026h") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[?2026l") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
}

test "Renderer skips unchanged cells" {
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);

    var r = try Renderer.init(std.testing.allocator, pipe[1], 5, 1);
    defer r.deinit();

    {
        const reg = r.begin();
        reg.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'A' } });
        try r.end();
        var drain_buf: [4096]u8 = undefined;
        _ = try std.posix.read(pipe[0], &drain_buf);
    }

    {
        const reg = r.begin();
        reg.set(0, 0, Cell{ .grapheme = .{ .codepoint = 'A' } });
        try r.end();

        var read_buf: [4096]u8 = undefined;
        const n = try std.posix.read(pipe[0], &read_buf);
        try std.testing.expect(n < 50);
    }
}
