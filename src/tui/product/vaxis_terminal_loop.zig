const std = @import("std");
const vaxis = @import("vaxis");
const app_mod = @import("App.zig");
const frame_mod = @import("frame.zig");
const input_mod = @import("input.zig");

pub const effects_per_step_max = 128;
const read_size_bytes_max = 4096;
const pending_input_bytes_max = 256;

pub const StepResult = struct {
    bytes_read: usize = 0,
    input_event_count: usize = 0,
    effect_count: usize = 0,
    input_overflow: bool = false,
    effect_overflow: bool = false,
    truncated: bool = false,
    shutdown_requested: bool = false,
    eof: bool = false,
};

/// Owns the vaxis terminal state and the product app. Heap-pinned: vaxis.Tty
/// keeps a pointer into `tty_buffer` and vaxis.Vaxis keeps a pointer to `env`,
/// so this struct must never move after `init`.
pub const TerminalLoop = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: std.process.Environ.Map,
    vx: vaxis.Vaxis,
    app: app_mod.ProductApp,
    tty_buffer: [4096]u8 = undefined,
    tty: ?vaxis.Tty = null,
    parser: vaxis.Parser = .{},
    pending: [pending_input_bytes_max]u8 = undefined,
    pending_len: usize = 0,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, width: u16, height: u16) !*TerminalLoop {
        const self = try allocator.create(TerminalLoop);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .env = std.process.Environ.Map.init(allocator),
            .vx = undefined,
            .app = undefined,
        };
        errdefer self.env.deinit();
        self.vx = try vaxis.init(io, allocator, &self.env, .{});
        errdefer {
            var discard = std.Io.Writer.Discarding.init(&.{});
            self.vx.deinit(allocator, &discard.writer);
        }
        self.app = try app_mod.ProductApp.init(width, height);
        return self;
    }

    // ziglint-ignore: Z030 heap owner is poisoned before allocator.destroy(self).
    pub fn deinit(self: *TerminalLoop) void {
        const allocator = self.allocator;
        self.app.deinit(allocator);
        if (self.tty) |*tty| {
            self.vx.deinit(allocator, tty.writer());
        } else {
            var discard = std.Io.Writer.Discarding.init(&.{});
            self.vx.deinit(allocator, &discard.writer);
        }
        if (self.tty) |tty| tty.deinit();
        self.env.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn setup(self: *TerminalLoop) !void {
        self.tty = try vaxis.Tty.init(self.io, &self.tty_buffer);
        try self.vx.enterAltScreen(self.tty.?.writer());
        try self.vx.setBracketedPaste(self.tty.?.writer(), true);
        const ws = self.tty.?.getWinsize() catch vaxis.Winsize{
            .cols = self.app.width,
            .rows = self.app.height,
            .x_pixel = 0,
            .y_pixel = 0,
        };
        try self.applyWinsize(ws);
        self.running = true;
    }

    pub fn shutdown(self: *TerminalLoop) !void {
        self.requestStop();
        if (self.tty) |*tty| try self.vx.resetState(tty.writer());
    }

    pub fn requestStop(self: *TerminalLoop) void {
        self.running = false;
    }

    pub fn isRunning(self: *const TerminalLoop) bool {
        return self.running;
    }

    /// Readiness fd for the owner loop's select. Input is read from stdin
    /// rather than the /dev/tty handle: kqueue on macOS cannot poll /dev/tty.
    pub fn inputFd(self: *const TerminalLoop) std.posix.fd_t {
        _ = self;
        return std.posix.STDIN_FILENO;
    }

    pub fn isDirty(self: *const TerminalLoop) bool {
        return self.app.dirty;
    }

    pub fn hasAnimation(self: *const TerminalLoop) bool {
        return self.app.slots.hasAnimated(.status_area);
    }

    pub fn applyCommand(self: *TerminalLoop, command: app_mod.Command) !?app_mod.Effect {
        return self.app.apply(self.allocator, command);
    }

    /// Read whatever bytes are available on stdin and parse them into input
    /// events. Call only after the input fd reported readable, so the read
    /// does not block the owner loop.
    pub fn readAvailableInput(self: *TerminalLoop, effects: []app_mod.Effect) !StepResult {
        var buf: [pending_input_bytes_max + read_size_bytes_max]u8 = undefined;
        @memcpy(buf[0..self.pending_len], self.pending[0..self.pending_len]);
        const read_count = try std.posix.read(
            std.posix.STDIN_FILENO,
            buf[self.pending_len..][0..read_size_bytes_max],
        );
        if (read_count == 0) {
            self.requestStop();
            return .{ .eof = true, .shutdown_requested = true };
        }
        const total = self.pending_len + read_count;
        self.pending_len = 0;
        var result: StepResult = .{ .bytes_read = read_count };
        var start: usize = 0;
        while (start < total) {
            const parsed = self.parser.parse(buf[start..total], null) catch {
                result.truncated = true;
                break;
            };
            if (parsed.n == 0) {
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
            result.input_event_count += 1;
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

    /// The vaxis parser resolves a trailing lone ESC immediately, so there is
    /// no deferred-escape state to flush; only incomplete multi-byte sequences
    /// stay pending and complete on the next read.
    pub fn flushPendingInput(self: *TerminalLoop, effects: []app_mod.Effect) !StepResult {
        _ = self;
        _ = effects;
        return .{};
    }

    fn applyInput(self: *TerminalLoop, input: input_mod.Input, effects: []app_mod.Effect, result: *StepResult) !void {
        if (input == .ignored) return;
        if (try self.app.apply(self.allocator, .{ .input = input })) |effect| {
            if (result.effect_count == effects.len) {
                effect.deinit(self.allocator);
                result.effect_overflow = true;
                return;
            }
            effects[result.effect_count] = effect;
            result.effect_count += 1;
        }
    }

    pub fn renderIfDirty(self: *TerminalLoop) !void {
        if (!self.app.dirty) return;
        try frame_mod.Frame.build(&self.app, &self.vx);
        try self.vx.render(self.tty.?.writer());
        self.app.dirty = false;
    }

    pub fn resizeFromTerminal(self: *TerminalLoop) !void {
        const ws = try self.tty.?.getWinsize();
        try self.applyWinsize(ws);
    }

    fn applyWinsize(self: *TerminalLoop, ws: vaxis.Winsize) !void {
        try self.vx.resize(self.allocator, self.tty.?.writer(), ws);
        _ = try self.app.apply(self.allocator, .{ .resize = .{ .width = ws.cols, .height = ws.rows } });
    }
};

fn containsShutdown(effects: []const app_mod.Effect) bool {
    for (effects) |effect| if (effect == .request_shutdown) return true;
    return false;
}
