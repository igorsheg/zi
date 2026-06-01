const std = @import("std");
const vaxis = @import("vaxis");

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    mouse: vaxis.Mouse,
};

pub const EventLoop = vaxis.Loop(Event);

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    alt_screen_entered: bool = false,

    pub fn init(
        self: *Terminal,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *std.process.Environ.Map,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .tty = try vaxis.Tty.init(io, &.{}),
            .vx = undefined,
        };
        errdefer self.tty.deinit();
        self.vx = try vaxis.init(io, allocator, environ, .{});
        errdefer self.vx.deinit(allocator, self.tty.writer());
    }

    pub fn deinit(self: *Terminal) void {
        if (self.alt_screen_entered) {
            self.vx.exitAltScreen(self.tty.writer()) catch |err| {
                std.log.warn("failed to exit alternate screen: {s}", .{@errorName(err)});
            };
            self.alt_screen_entered = false;
        }
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.* = undefined;
    }

    pub fn eventLoop(self: *Terminal) EventLoop {
        return .init(self.io, &self.tty, &self.vx);
    }

    pub fn enterAltScreen(self: *Terminal) !void {
        try self.vx.enterAltScreen(self.tty.writer());
        self.alt_screen_entered = true;
    }

    pub fn resize(self: *Terminal, winsize: vaxis.Winsize) !void {
        try self.vx.resize(self.allocator, self.tty.writer(), winsize);
    }

    pub fn currentWinsize(self: *Terminal) !vaxis.Winsize {
        return .{
            .rows = self.vx.screen.height,
            .cols = self.vx.screen.width,
            .x_pixel = self.vx.screen.width_pix,
            .y_pixel = self.vx.screen.height_pix,
        };
    }
};
