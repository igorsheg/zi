const std = @import("std");
const runtime_fd = @import("fd.zig");
const posix = std.posix;
const ansi = @import("ansi.zig");

/// Global terminal pointer for signal/panic cleanup.
/// Set by Terminal.installSignalHandlers(), cleared by Terminal.deinit().
var global_terminal: ?*Terminal = null;

fn signalCleanupHandler(_: std.posix.SIG) callconv(.c) void {
    if (global_terminal) |t| {
        t.emergencyRestore();
    }
    // Re-raise with default handler to get correct exit code
    const default_act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = 0,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &default_act, null);
    posix.sigaction(posix.SIG.TERM, &default_act, null);
    _ = posix.raise(posix.SIG.INT) catch {};
}

/// Override the default panic handler to restore terminal before crashing.
pub const panic = struct {
    pub fn call(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
        if (global_terminal) |t| {
            t.emergencyRestore();
            global_terminal = null;
        }
        std.debug.defaultPanic(msg, ret_addr);
    }
}.call;

pub const Terminal = struct {
    fd_in: posix.fd_t,
    fd_out: posix.fd_t,
    original_termios: ?posix.termios,
    width: u32,
    height: u32,
    raw_mode: bool,
    kitty_active: bool,
    modify_other_keys_active: bool,
    bracketed_paste_active: bool,
    mouse_tracking_active: bool,
    cursor_hidden: bool,

    pub fn init() Terminal {
        return .{
            .fd_in = posix.STDIN_FILENO,
            .fd_out = posix.STDOUT_FILENO,
            .original_termios = null,
            .width = 80,
            .height = 24,
            .raw_mode = false,
            .kitty_active = false,
            .modify_other_keys_active = false,
            .bracketed_paste_active = false,
            .mouse_tracking_active = false,
            .cursor_hidden = false,
        };
    }

    /// Enter raw mode: disable echo, canonical processing, signals.
    pub fn enterRawMode(self: *Terminal) !void {
        const orig = try posix.tcgetattr(self.fd_in);
        self.original_termios = orig;

        var raw = orig;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(self.fd_in, .FLUSH, raw);
        self.raw_mode = true;
    }

    /// Restore original terminal settings.
    pub fn exitRawMode(self: *Terminal) void {
        if (self.original_termios) |orig| {
            posix.tcsetattr(self.fd_in, .FLUSH, orig) catch {};
            self.original_termios = null;
        }
        self.raw_mode = false;
    }

    /// Query terminal size via ioctl.
    pub fn updateSize(self: *Terminal) void {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(self.fd_out, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0) {
            if (ws.col > 0) self.width = ws.col;
            if (ws.row > 0) self.height = ws.row;
        }
    }

    fn canControlOutput(self: *const Terminal) bool {
        const file: std.Io.File = .{ .handle = self.fd_out, .flags = .{ .nonblocking = false } };
        return file.isTty(std.Options.debug_io) catch false;
    }

    pub fn write(self: *Terminal, data: []const u8) void {
        if (!self.canControlOutput()) return;
        writeAll(self.fd_out, data);
    }

    pub fn hideCursor(self: *Terminal) void {
        if (!self.cursor_hidden) self.write(ansi.hide_cursor);
        self.cursor_hidden = true;
    }

    pub fn showCursor(self: *Terminal) void {
        if (self.cursor_hidden) self.write(ansi.show_cursor);
        self.cursor_hidden = false;
    }

    pub fn setCursorPos(self: *Terminal, col: u32, row: u32) void {
        var buf: [32]u8 = undefined;
        const s = ansi.formatCursorPos(&buf, col, row) catch return;
        self.write(s);
    }

    pub fn clearScreen(self: *Terminal) void {
        self.write(ansi.clear_and_home);
    }

    pub fn setTitle(self: *Terminal, title: []const u8) void {
        self.write(ansi.title_prefix);
        self.write(title);
        self.write(ansi.title_suffix);
    }

    pub fn enableBracketedPaste(self: *Terminal) void {
        if (!self.bracketed_paste_active) self.write(ansi.bracketed_paste_enable);
        self.bracketed_paste_active = true;
    }

    pub fn disableBracketedPaste(self: *Terminal) void {
        if (self.bracketed_paste_active) self.write(ansi.bracketed_paste_disable);
        self.bracketed_paste_active = false;
    }

    /// Query kitty keyboard protocol support (CSI ? u).
    pub fn queryKittyProtocol(self: *Terminal) void {
        self.write(ansi.kitty_query);
    }

    /// Enable kitty keyboard protocol: disambiguate + event types + alternate keys.
    pub fn enableKittyProtocol(self: *Terminal) void {
        self.write(ansi.kitty_keyboard_enable);
        self.kitty_active = true;
    }

    pub fn disableKittyProtocol(self: *Terminal) void {
        self.write(ansi.kitty_keyboard_disable);
        self.kitty_active = false;
    }

    /// Enable xterm modifyOtherKeys mode 2 (fallback when kitty unavailable).
    pub fn enableModifyOtherKeys(self: *Terminal) void {
        self.write(ansi.modify_other_keys_enable);
        self.modify_other_keys_active = true;
    }

    pub fn disableModifyOtherKeys(self: *Terminal) void {
        self.write(ansi.modify_other_keys_disable);
        self.modify_other_keys_active = false;
    }

    /// Enable SGR mouse tracking (button events + scroll wheel).
    pub fn enableMouseTracking(self: *Terminal) void {
        if (!self.mouse_tracking_active) self.write(ansi.mouse_tracking_enable);
        self.mouse_tracking_active = true;
    }

    /// Disable mouse tracking.
    pub fn disableMouseTracking(self: *Terminal) void {
        if (self.mouse_tracking_active) self.write(ansi.mouse_tracking_disable);
        self.mouse_tracking_active = false;
    }

    /// Read available input bytes (non-blocking if raw mode with MIN=0).
    pub fn readInput(self: *Terminal, buf: []u8) !usize {
        return posix.read(self.fd_in, buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
    }

    /// Install signal handlers that restore terminal on SIGINT/SIGTERM.
    /// Must be called after enterRawMode.
    pub fn installSignalHandlers(self: *Terminal) void {
        global_terminal = self;
        const act = posix.Sigaction{
            .handler = .{ .handler = signalCleanupHandler },
            .mask = 0,
            .flags = 0,
        };
        posix.sigaction(posix.SIG.TERM, &act, null);
        posix.sigaction(posix.SIG.INT, &act, null);
    }

    /// Minimal restore for signal/panic context (async-signal-safe).
    /// Only uses write() — no allocations, no locks.
    pub fn emergencyRestore(self: *Terminal) void {
        const out: std.Io.File = .{ .handle = self.fd_out, .flags = .{ .nonblocking = false } };
        var buf: [128]u8 = undefined;
        var writer = out.writer(std.Options.debug_io, &buf);
        writer.interface.writeAll(ansi.emergency_restore) catch {};
        writer.interface.flush() catch {};
        if (self.original_termios) |orig| {
            posix.tcsetattr(self.fd_in, .FLUSH, orig) catch {};
        }
    }

    /// Cleanup: restore terminal state.
    pub fn deinit(self: *Terminal) void {
        if (self.kitty_active) self.disableKittyProtocol();
        if (self.modify_other_keys_active) self.disableModifyOtherKeys();
        self.disableMouseTracking();
        self.disableBracketedPaste();
        self.showCursor();
        self.exitRawMode();
        if (global_terminal == self) global_terminal = null;
    }
};

fn writeAll(fd: posix.fd_t, data: []const u8) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var buf: [4096]u8 = undefined;
    var writer = file.writer(std.Options.debug_io, &buf);
    writer.interface.writeAll(data) catch return;
    writer.interface.flush() catch {};
}

fn testPipe() ![2]std.posix.fd_t {
    return runtime_fd.pipe();
}
test "Terminal deinit does not write control sequences to non-tty output" {
    const pipe = try testPipe();
    defer runtime_fd.close(pipe[0]);

    var t = Terminal.init();
    t.fd_out = pipe[1];
    t.hideCursor();
    t.enableBracketedPaste();
    t.enableMouseTracking();
    t.enableKittyProtocol();
    t.enableModifyOtherKeys();

    t.deinit();
    runtime_fd.close(pipe[1]);

    var read_buf: [256]u8 = undefined;
    const n = try std.posix.read(pipe[0], &read_buf);
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expect(!t.kitty_active);
    try std.testing.expect(!t.modify_other_keys_active);
    try std.testing.expect(!t.bracketed_paste_active);
    try std.testing.expect(!t.mouse_tracking_active);
    try std.testing.expect(!t.cursor_hidden);
}
