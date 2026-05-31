const std = @import("std");
const vaxis = @import("vaxis");
const tui_testing = @import("testing.zig");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    mouse: vaxis.Mouse,
};

pub const EventLoop = vaxis.Loop(Event);

pub const Terminal = struct {
    const tty_buffer_size_bytes = 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    tty_buffer: [tty_buffer_size_bytes]u8,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    alt_screen_entered: bool,

    pub fn init(
        self: *Terminal,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *std.process.Environ.Map,
    ) !void {
        self.allocator = allocator;
        self.io = io;
        self.tty_buffer = undefined;
        self.alt_screen_entered = false;

        self.tty = try vaxis.Tty.init(io, &self.tty_buffer);
        errdefer self.tty.deinit();

        self.vx = try vaxis.init(io, allocator, environ, .{});
        errdefer self.vx.deinit(allocator, self.tty.writer());
    }

    pub fn deinit(self: *Terminal) void {
        if (self.alt_screen_entered) {
            // Teardown is best-effort: if restoring the screen fails there is
            // no recovery path left, but the failure must not be silent.
            self.exitAltScreen() catch |err| std.log.warn("tui: exit alt screen failed: {t}", .{err});
        }
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.* = undefined;
    }

    pub fn eventLoop(self: *Terminal) EventLoop {
        return .init(self.io, &self.tty, &self.vx);
    }

    pub fn enterAltScreen(self: *Terminal) !void {
        if (self.alt_screen_entered) return;
        try self.vx.enterAltScreen(self.tty.writer());
        self.alt_screen_entered = true;
    }

    pub fn exitAltScreen(self: *Terminal) !void {
        if (!self.alt_screen_entered) return;
        try self.vx.exitAltScreen(self.tty.writer());
        self.alt_screen_entered = false;
    }

    pub fn resize(self: *Terminal, size: vaxis.Winsize) !void {
        try self.vx.resize(self.allocator, self.tty.writer(), size);
    }

    pub fn currentWinsize(self: *Terminal) !vaxis.Winsize {
        return self.tty.getWinsize();
    }

    pub fn drawText(self: *Terminal, text: []const u8) !void {
        const window = self.vx.window();
        window.clear();
        _ = window.print(&.{.{ .text = text }}, .{ .wrap = .word });
        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
    }
};

test "terminal substrate draws text through owned lifecycle" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &environ);
    defer terminal.deinit();

    try terminal.resize(.{
        .rows = 8,
        .cols = 32,
        .x_pixel = 32 * 8,
        .y_pixel = 8 * 16,
    });
    try terminal.enterAltScreen();
    try terminal.drawText("terminal");
    try tui_testing.expectScreenAscii(
        "terminal                        \n" ++
            "                                \n" ++
            "                                \n" ++
            "                                \n" ++
            "                                \n" ++
            "                                \n" ++
            "                                \n" ++
            "                                ",
        &terminal.vx.screen,
        32,
        8,
    );
    try terminal.exitAltScreen();
}
