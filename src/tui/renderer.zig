const std = @import("std");
const runtime_fd = @import("terminal/fd.zig");
const ansi = @import("terminal/ansi.zig");
const cell_mod = @import("cell.zig");
const buffer_mod = @import("primitives/surface.zig");
const grapheme_mod = @import("grapheme.zig");
const deadline = @import("../zio/root.zig").deadline;
const Cell = cell_mod.Cell;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Buffer = buffer_mod.Buffer;
const Region = buffer_mod.Region;

const min_retained_output_capacity: usize = 2 * 1024 * 1024;
const max_retained_output_capacity: usize = 8 * 1024 * 1024;

fn nowUs() i64 {
    const ns = deadline.nowNs(std.Options.debug_io);
    return @intCast(@divTrunc(ns, 1000));
}

pub const Stats = struct {
    frames: u64 = 0,
    cells_scanned: u32 = 0,
    cells_changed: u32 = 0,
    cursor_moves: u32 = 0,
    fg_changes: u32 = 0,
    bg_changes: u32 = 0,
    attr_changes: u32 = 0,
    graphemes_written: u32 = 0,
    bytes_emitted: usize = 0,
    render_us: i64 = 0,
    write_us: i64 = 0,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    current: Buffer,
    next: Buffer,
    output: std.ArrayListUnmanaged(u8) = .empty,
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    force_redraw: bool,
    width_method: grapheme_mod.WidthMethod,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, fd: std.posix.fd_t, width: u32, height: u32, width_method: grapheme_mod.WidthMethod) !Renderer {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacity(allocator, @as(usize, width) * @as(usize, height) * 4);

        var current = try Buffer.init(allocator, width, height, width_method);
        errdefer current.deinit();
        var next = try Buffer.init(allocator, width, height, width_method);
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
            .width_method = width_method,
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
        const render_start = nowUs();
        var stats = Stats{ .frames = self.stats.frames + 1 };
        self.output.clearRetainingCapacity();

        appendStr(self, ansi.sync_enable);

        var style_state = StyleState{};

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
                stats.cursor_moves += 1;

                while (x_usize < row_width) : (x_usize += 1) {
                    const run_curr = current_row[x_usize];
                    const run_next = next_row[x_usize];
                    if (!self.force_redraw and run_curr.eql(run_next)) break;

                    stats.cells_changed += 1;

                    emitStyleDelta(self, run_next, &style_state, &stats);

                    if (run_next.width != 0) {
                        appendGrapheme(self, run_next.grapheme, &self.next.grapheme_pool);
                        stats.graphemes_written += 1;
                    }
                }

                if (x_usize == row_width) break;
            }
        }

        stats.cells_scanned = self.width * self.height;

        appendStr(self, ansi.reset);
        appendStr(self, ansi.sync_disable);

        const render_end = nowUs();
        stats.render_us = render_end - render_start;
        stats.bytes_emitted = self.output.items.len;

        const write_start = nowUs();
        writeAll(self.fd, self.output.items);
        const write_end = nowUs();
        stats.write_us = write_end - write_start;
        self.stats = stats;
        self.releaseOversizedOutputBuffer();

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

    fn releaseOversizedOutputBuffer(self: *Renderer) void {
        const frame_floor = @as(usize, self.width) * @as(usize, self.height) * 8;
        const retain_capacity = @max(min_retained_output_capacity, frame_floor);
        if (self.output.capacity <= @max(retain_capacity, max_retained_output_capacity)) return;
        self.output.deinit(self.allocator);
        self.output = .empty;
        self.output.ensureTotalCapacity(self.allocator, retain_capacity) catch {};
    }
};

const StyleState = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    attrs: ?Attributes = null,
};

fn emitStyleDelta(self: *Renderer, cell: Cell, state: *StyleState, stats: *Stats) void {
    if (state.fg == null or !state.fg.?.eql(cell.fg)) {
        appendFgColor(self, cell.fg);
        stats.fg_changes += 1;
        state.fg = cell.fg;
    }

    if (state.bg == null or !state.bg.?.eql(cell.bg)) {
        appendBgColor(self, cell.bg);
        stats.bg_changes += 1;
        state.bg = cell.bg;
    }

    if (state.attrs == null or !state.attrs.?.eql(cell.attrs)) {
        appendAttrs(self, cell.attrs);
        stats.attr_changes += 1;
        state.attrs = cell.attrs;
    }
}

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

test "Renderer end writes a frame and promotes it to current" {
    const pipe = try testPipe();
    defer runtime_fd.close(pipe[0]);
    defer runtime_fd.close(pipe[1]);

    var r = try Renderer.init(std.testing.allocator, pipe[1], 5, 1, .wcwidth);
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
    try std.testing.expectEqual(@as(u64, 1), r.stats.frames);
    try std.testing.expect(r.stats.cells_changed > 0);
    try std.testing.expect(r.stats.bytes_emitted > 0);
}

test "Renderer emits wide-cell overwrites as concrete cell updates" {
    const pipe = try testPipe();
    defer runtime_fd.close(pipe[0]);
    defer runtime_fd.close(pipe[1]);

    var r = try Renderer.init(std.testing.allocator, pipe[1], 4, 1, .wcwidth);
    defer r.deinit();

    {
        const reg = r.begin();
        _ = reg.writeStr(0, 0, "界x", Color.default, Color.default, Attributes.none);
        try r.end();
        var drain: [4096]u8 = undefined;
        _ = try readPipe(pipe[0], &drain);
    }

    {
        const reg = r.begin();
        _ = reg.writeStr(1, 0, "A", Color.default, Color.default, Attributes.none);
        try r.end();

        var read_buf: [4096]u8 = undefined;
        const output = try readPipe(pipe[0], &read_buf);
        try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
        try std.testing.expectEqual(@as(u21, ' '), r.current.get(0, 0).grapheme.codepoint);
        try std.testing.expectEqual(@as(u21, 'A'), r.current.get(1, 0).grapheme.codepoint);
        try std.testing.expectEqual(@as(u21, ' '), r.current.get(2, 0).grapheme.codepoint);
    }
}

test "Renderer diffs subsequent frames and clears deleted cells" {
    const pipe = try testPipe();
    defer runtime_fd.close(pipe[0]);
    defer runtime_fd.close(pipe[1]);

    var r = try Renderer.init(std.testing.allocator, pipe[1], 10, 1, .wcwidth);
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
