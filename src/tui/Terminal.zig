const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const screen_mod = @import("screen.zig");
pub const query_timeout_ms = 500;

allocator: std.mem.Allocator,
io: std.Io,
tty: ?vaxis.Tty = null,
vx: ?vaxis.Vaxis = null,
screen: screen_mod.Screen = .{},
setup_done: bool = false,
tty_buffer: [4096]u8 = undefined,

const Terminal = @This();

pub const ParserEventResult = enum {
    ignored,
    consumed,
    resized,
};

pub fn init(
    self: *Terminal,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
    };
    errdefer self.deinit();

    self.tty = try vaxis.Tty.init(io, &self.tty_buffer);
    self.vx = try vaxis.init(io, allocator, env_map, .{});
    try self.resizeFromTty();
}

pub fn deinit(self: *Terminal) void {
    self.shutdown() catch {};
    if (self.vx) |*vx| {
        if (self.tty) |*tty| {
            vx.deinit(self.allocator, tty.writer());
        }
    }
    if (self.tty) |*tty| tty.deinit();
    self.* = undefined;
}

pub fn setup(self: *Terminal) !void {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    if (self.setup_done) return;

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminalSend(tty.writer());
    if (builtin.is_test) {
        vx.queries_done.store(true, .unordered);
        try vx.enableDetectedFeatures(tty.writer());
    } else {
        try std.Io.futexWaitTimeout(
            self.io,
            std.atomic.Value(u32),
            &vx.query_futex,
            .init(0),
            .{ .duration = .{ .clock = .real, .raw = .fromMilliseconds(query_timeout_ms) } },
        );
        vx.queries_done.store(true, .unordered);
        try vx.enableDetectedFeatures(tty.writer());
    }
    try vx.setBracketedPaste(tty.writer(), true);
    try vx.setMouseMode(tty.writer(), true);
    try self.resizeFromTty();
    self.setup_done = true;
}

pub fn shutdown(self: *Terminal) !void {
    if (!self.setup_done) return;
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    try vx.resetState(tty.writer());
    self.setup_done = false;
}

pub fn resizeFromTty(self: *Terminal) !void {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    try vx.resize(self.allocator, tty.writer(), try tty.getWinsize());
}

pub fn winsize(self: *Terminal) !vaxis.Winsize {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    return tty.getWinsize();
}

pub fn resizeTo(self: *Terminal, size: vaxis.Winsize) !bool {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    if (vx.screen.width == size.cols and
        vx.screen.height == size.rows and
        vx.screen.width_pix == size.x_pixel and
        vx.screen.height_pix == size.y_pixel)
    {
        return false;
    }
    try vx.resize(self.allocator, tty.writer(), size);
    return true;
}

pub fn applyParserEvent(self: *Terminal, event: vaxis.Event) !ParserEventResult {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    switch (event) {
        .key_press => |key| return try self.applyQueryKey(key),
        .cap_kitty_keyboard => {
            vx.caps.kitty_keyboard = true;
            try self.enableDetectedFeaturesOnce();
            return .consumed;
        },
        .cap_kitty_graphics => {
            vx.caps.kitty_graphics = true;
            return .consumed;
        },
        .cap_rgb => {
            vx.caps.rgb = true;
            return .consumed;
        },
        .cap_unicode => {
            vx.caps.unicode = .unicode;
            vx.screen.width_method = .unicode;
            try self.enableDetectedFeaturesOnce();
            return .consumed;
        },
        .cap_sgr_pixels => {
            vx.caps.sgr_pixels = true;
            if (vx.state.mouse) try vx.setMouseMode(tty.writer(), true);
            return .consumed;
        },
        .cap_color_scheme_updates => {
            vx.caps.color_scheme_updates = true;
            return .consumed;
        },
        .cap_multi_cursor => {
            vx.caps.multi_cursor = true;
            return .consumed;
        },
        .cap_da1 => {
            std.Io.futexWake(vx.io, std.atomic.Value(u32), &vx.query_futex, 10);
            vx.queries_done.store(true, .unordered);
            return .consumed;
        },
        .winsize => |size| {
            vx.state.in_band_resize = true;
            return if (try self.resizeTo(size)) .resized else .consumed;
        },
        .color_report, .color_scheme => return .consumed,
        else => return .ignored,
    }
}

fn applyQueryKey(self: *Terminal, key: vaxis.Key) !ParserEventResult {
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    if (vx.queries_done.load(.unordered)) return .ignored;
    if (key.codepoint == vaxis.Key.f3 and key.mods.shift) {
        vx.caps.explicit_width = true;
        vx.caps.unicode = .unicode;
        vx.screen.width_method = .unicode;
        return .consumed;
    }
    if (key.codepoint == vaxis.Key.f3 and key.mods.alt) {
        vx.caps.scaled_text = true;
        return .consumed;
    }
    return .ignored;
}

fn enableDetectedFeaturesOnce(self: *Terminal) !void {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    if (!vx.state.kitty_keyboard) return vx.enableDetectedFeatures(tty.writer());

    const kitty_cap = vx.caps.kitty_keyboard;
    vx.caps.kitty_keyboard = false;
    defer vx.caps.kitty_keyboard = kitty_cap;
    try vx.enableDetectedFeatures(tty.writer());
}

pub fn setTitle(self: *Terminal, title: []const u8) !void {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    try vx.setTitle(tty.writer(), title);
}

pub fn paint(self: *Terminal, frame: screen_mod.Frame) !void {
    const tty = if (self.tty) |*tty| tty else return error.TerminalNotInitialized;
    const vx = if (self.vx) |*vx| vx else return error.TerminalNotInitialized;
    try self.screen.paint(vx, tty.writer(), frame);
}

test "terminal wrapper paints a frame into vaxis screen" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var frame: screen_mod.Frame = .{};
    try frame.appendLine(screen_mod.singleSpanLine("hi", screen_mod.styles.normal));
    frame.cursor = .{ .col = 1, .row = 0 };
    try terminal.paint(frame);

    const vx = &terminal.vx.?;
    const cell = vx.screen.readCell(0, 0).?;
    try std.testing.expectEqualStrings("h", cell.char.grapheme);
    try std.testing.expect(vx.screen.cursor_vis);
}

test "terminal setup and shutdown are idempotent" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    try terminal.setup();
    try terminal.setup();
    try std.testing.expect(terminal.setup_done);
    try terminal.shutdown();
    try terminal.shutdown();
    try std.testing.expect(!terminal.setup_done);
}

test "terminal applies parser capability and resize events" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    try std.testing.expectEqual(ParserEventResult.consumed, try terminal.applyParserEvent(.cap_rgb));
    try std.testing.expect(terminal.vx.?.caps.rgb);

    const resized = try terminal.applyParserEvent(.{ .winsize = .{
        .rows = 24,
        .cols = 100,
        .x_pixel = 1000,
        .y_pixel = 480,
    } });
    try std.testing.expectEqual(ParserEventResult.resized, resized);
    try std.testing.expectEqual(@as(u16, 100), terminal.vx.?.screen.width);
    try std.testing.expectEqual(@as(u16, 24), terminal.vx.?.screen.height);

    const duplicate = try terminal.applyParserEvent(.{ .winsize = .{
        .rows = 24,
        .cols = 100,
        .x_pixel = 1000,
        .y_pixel = 480,
    } });
    try std.testing.expectEqual(ParserEventResult.consumed, duplicate);
}

test "terminal consumes query-only key reports" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    terminal.vx.?.queries_done.store(false, .unordered);
    try std.testing.expectEqual(ParserEventResult.consumed, try terminal.applyParserEvent(.{ .key_press = .{
        .codepoint = vaxis.Key.f3,
        .mods = .{ .shift = true },
    } }));
    try std.testing.expect(terminal.vx.?.caps.explicit_width);
}
