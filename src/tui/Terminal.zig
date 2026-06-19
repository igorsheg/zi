//! The single terminal-byte authority. Owns the vaxis terminal state, the
//! input parser, the product App, and the render transaction; nothing else
//! in the process touches the tty.
//!
//! Heap-pinned: vaxis.Tty keeps a pointer into `tty_buffer` and vaxis.Vaxis
//! keeps a pointer to `env`, so this struct must never move after `init` —
//! `init` allocates it and hands out the pointer.
//!
//! Input has one non-obvious platform split: vaxis opens /dev/tty for raw
//! mode, size, and writes, while the owner loop selects/reads *stdin* for
//! readiness, because kqueue on macOS cannot poll /dev/tty reliably.
const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("App.zig");
const input_mod = @import("input.zig");
const theme_mod = @import("theme.zig");
const render = @import("render.zig");

const Terminal = @This();

pub const effects_per_read_max = 128;
const read_size_bytes_max = 4096;
const pending_input_bytes_max = 256;

gpa: std.mem.Allocator,
io: std.Io,
env: std.process.Environ.Map,
vx: vaxis.Vaxis,
app: App,
/// Draw scratch for render; lives here so frame builds use no large stack.
scratch: render.RowScratch = undefined,
tty_buffer: [4096]u8 = undefined,
tty: ?vaxis.Tty = null,
parser: vaxis.Parser = .{},
/// Carry for an incomplete escape sequence split across reads.
pending: [pending_input_bytes_max]u8 = undefined,
pending_len: usize = 0,
running: bool = false,

pub const ReadResult = struct {
    bytes_read: usize = 0,
    event_count: usize = 0,
    effect_count: usize = 0,
    /// Input bytes were dropped (unparseable or pending overflow). The
    /// caller surfaces this as a warning; it never tears the loop down.
    truncated: bool = false,
    effect_overflow: bool = false,
    shutdown_requested: bool = false,
    eof: bool = false,
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    width: u16,
    height: u16,
    terminal_info: theme_mod.TerminalInfo,
) !*Terminal {
    const self = try gpa.create(Terminal);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .env = std.process.Environ.Map.init(gpa),
        .vx = undefined,
        .app = App.init(width, height, terminal_info),
    };
    errdefer self.env.deinit();
    self.vx = try vaxis.init(io, gpa, &self.env, .{});
    return self;
}

// The heap owner poisons itself before destroy; gpa is copied out first.
// ziglint-ignore: Z030 linter wants poison as last statement, but heap destroy must follow it.
pub fn deinit(self: *Terminal) void {
    const gpa = self.gpa;
    self.app.deinit(gpa);
    if (self.tty) |*tty| {
        self.vx.deinit(gpa, tty.writer());
    } else {
        var discard = std.Io.Writer.Discarding.init(&.{});
        self.vx.deinit(gpa, &discard.writer);
    }
    if (self.tty) |tty| tty.deinit();
    self.env.deinit();
    self.* = undefined;
    gpa.destroy(self);
}

pub fn setup(self: *Terminal) !void {
    self.tty = try vaxis.Tty.init(self.io, &self.tty_buffer);
    try self.vx.enterAltScreen(self.tty.?.writer());
    try self.vx.setBracketedPaste(self.tty.?.writer(), true);
    try self.vx.setMouseMode(self.tty.?.writer(), true);
    const ws = self.tty.?.getWinsize() catch vaxis.Winsize{
        .cols = self.app.width,
        .rows = self.app.height,
        .x_pixel = 0,
        .y_pixel = 0,
    };
    try self.applyWinsize(ws);
    self.running = true;
}

pub fn shutdown(self: *Terminal) !void {
    self.requestStop();
    if (self.tty) |*tty| try self.vx.resetState(tty.writer());
}

pub fn requestStop(self: *Terminal) void {
    self.running = false;
}

pub fn isRunning(self: *const Terminal) bool {
    return self.running;
}

/// Readiness fd for the owner loop's select; see the platform note above.
pub fn inputFd(self: *const Terminal) std.posix.fd_t {
    _ = self;
    return std.posix.STDIN_FILENO;
}

pub fn isDirty(self: *const Terminal) bool {
    return self.app.dirty;
}

pub fn hasAnimation(self: *const Terminal) bool {
    return self.app.hasAnimation();
}

pub fn composerText(self: *const Terminal) []const u8 {
    return self.app.composer.text();
}

pub fn applyCommand(self: *Terminal, command: App.Command) error{OutOfMemory}!?App.Effect {
    return self.app.apply(self.gpa, command);
}

/// Read whatever bytes are available on stdin and apply them as input.
/// Call only after the input fd reported readable so the read cannot block
/// the owner loop. Resize events are applied to vaxis and App here; product
/// effects land in `effects`.
pub fn readAvailableInput(self: *Terminal, effects: []App.Effect) !ReadResult {
    var buf: [pending_input_bytes_max + read_size_bytes_max]u8 = undefined;
    @memcpy(buf[0..self.pending_len], self.pending[0..self.pending_len]);
    const read_count = std.posix.read(
        std.posix.STDIN_FILENO,
        buf[self.pending_len..][0..read_size_bytes_max],
    ) catch |err| switch (err) {
        error.WouldBlock => return .{},
        else => return err,
    };
    if (read_count == 0) {
        self.requestStop();
        return .{ .eof = true, .shutdown_requested = true };
    }
    const total = self.pending_len + read_count;
    self.pending_len = 0;
    var result: ReadResult = .{ .bytes_read = read_count };
    var start: usize = 0;
    while (start < total) {
        const parsed = self.parser.parse(buf[start..total], null) catch {
            result.truncated = true;
            break;
        };
        if (parsed.n == 0) {
            // Incomplete sequence: carry it into the next read, bounded.
            const remaining = total - start;
            if (remaining <= self.pending.len) {
                @memcpy(self.pending[0..remaining], buf[start..total]);
                self.pending_len = remaining;
            } else {
                result.truncated = true;
            }
            break;
        }
        start += parsed.n;
        result.event_count += 1;
        const event = parsed.event orelse continue;
        switch (event) {
            .winsize => |ws| try self.applyWinsize(ws),
            else => try self.applyInput(input_mod.fromVaxis(event), effects, &result),
        }
    }
    if (containsShutdown(effects[0..result.effect_count])) {
        result.shutdown_requested = true;
        self.requestStop();
    }
    return result;
}

fn applyInput(
    self: *Terminal,
    event: input_mod.Input,
    effects: []App.Effect,
    result: *ReadResult,
) error{OutOfMemory}!void {
    if (event == .ignored) return;
    if (try self.app.apply(self.gpa, .{ .input = event })) |effect| {
        if (result.effect_count == effects.len) {
            effect.deinit(self.gpa);
            result.effect_overflow = true;
            return;
        }
        effects[result.effect_count] = effect;
        result.effect_count += 1;
    }
}

/// The render transaction: paint into vaxis' screen, then write the diff to
/// the terminal. State stays dirty until the write succeeds, so a failed
/// write retries on the next wake instead of losing the frame.
pub fn renderIfDirty(self: *Terminal) !void {
    if (!self.app.dirty) return;
    render.draw(&self.app, &self.vx, &self.scratch);
    try self.vx.render(self.tty.?.writer());
    self.app.dirty = false;
}

pub fn resizeFromTerminal(self: *Terminal) !void {
    const ws = try self.tty.?.getWinsize();
    try self.applyWinsize(ws);
}

fn applyWinsize(self: *Terminal, ws: vaxis.Winsize) !void {
    try self.vx.resize(self.gpa, self.tty.?.writer(), ws);
    _ = try self.app.apply(self.gpa, .{ .resize = .{ .width = ws.cols, .height = ws.rows } });
}

fn containsShutdown(effects: []const App.Effect) bool {
    for (effects) |effect| if (effect == .request_shutdown) return true;
    return false;
}
