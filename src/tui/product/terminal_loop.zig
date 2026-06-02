const std = @import("std");
const app_mod = @import("App.zig");
const loop_mod = @import("loop.zig");
const substrate = @import("../substrate/root.zig");

pub const read_size_bytes_max = substrate.input.input_read_size_max;
pub const effects_per_step_max = loop_mod.effects_per_step_max;

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

pub const TerminalLoop = struct {
    terminal: substrate.Terminal,
    product: loop_mod.ProductLoop,
    read_buffer: [read_size_bytes_max]u8 = undefined,
    running: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        width: u16,
        height: u16,
        output_size_bytes: usize,
    ) !TerminalLoop {
        return .{
            .terminal = substrate.Terminal.init(io),
            .product = try loop_mod.ProductLoop.init(allocator, width, height, output_size_bytes),
        };
    }

    pub fn deinit(self: *TerminalLoop) void {
        self.product.deinit();
        self.* = undefined;
    }

    pub fn setup(self: *TerminalLoop, writer: *std.Io.Writer) !void {
        try self.terminal.setup(writer);
        self.running = true;
    }

    pub fn shutdown(self: *TerminalLoop, writer: *std.Io.Writer) !void {
        self.running = false;
        try self.terminal.shutdown(writer);
    }

    pub fn stepRead(
        self: *TerminalLoop,
        writer: *std.Io.Writer,
        effects: []app_mod.Effect,
    ) !StepResult {
        const read_count = try std.posix.read(self.terminal.input_fd, &self.read_buffer);
        if (read_count == 0) return .{ .eof = true, .shutdown_requested = true };
        var result = try self.stepBytes(self.read_buffer[0..read_count], writer, effects);
        result.bytes_read = read_count;
        return result;
    }

    pub fn stepBytes(
        self: *TerminalLoop,
        bytes: []const u8,
        writer: *std.Io.Writer,
        effects: []app_mod.Effect,
    ) !StepResult {
        const feed = try self.product.feedBytes(bytes, effects);
        var result = stepResultFromFeed(feed);
        result.shutdown_requested = containsShutdown(effects[0..feed.effect_count]);
        if (result.shutdown_requested) self.running = false;
        _ = try self.product.renderIfDirty(writer);
        return result;
    }

    pub fn flushInput(
        self: *TerminalLoop,
        writer: *std.Io.Writer,
        effects: []app_mod.Effect,
    ) !StepResult {
        const feed = try self.product.flushInput(effects);
        var result = stepResultFromFeed(feed);
        result.shutdown_requested = containsShutdown(effects[0..feed.effect_count]);
        if (result.shutdown_requested) self.running = false;
        _ = try self.product.renderIfDirty(writer);
        return result;
    }

    pub fn resizeFromTerminal(self: *TerminalLoop) !void {
        const size = try self.terminal.size();
        try self.product.resize(size.width, size.height);
    }
};

fn stepResultFromFeed(feed: loop_mod.FeedResult) StepResult {
    return .{
        .input_event_count = feed.input_event_count,
        .effect_count = feed.effect_count,
        .input_overflow = feed.input_overflow,
        .effect_overflow = feed.effect_overflow,
        .truncated = feed.truncated,
    };
}

fn containsShutdown(effects: []const app_mod.Effect) bool {
    for (effects) |effect| {
        if (effect == .request_shutdown) return true;
    }
    return false;
}

test "terminal loop step bytes feeds renders and returns effects" {
    var loop = try TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        20,
        4,
        loop_mod.output_size_bytes_default,
    );
    defer loop.deinit();
    loop.running = true;

    var effects: [effects_per_step_max]app_mod.Effect = undefined;
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    const result = try loop.stepBytes("hello\r", &writer, &effects);
    defer for (effects[0..result.effect_count]) |effect| effect.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), result.input_event_count);
    try std.testing.expectEqual(@as(usize, 1), result.effect_count);
    try std.testing.expectEqualStrings("hello", effects[0].submit_text);
    try std.testing.expect(loop.running);
    try std.testing.expect(!loop.product.app.dirty);
}

test "terminal loop escape requests shutdown without coding agent policy" {
    var loop = try TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        20,
        4,
        loop_mod.output_size_bytes_default,
    );
    defer loop.deinit();
    loop.running = true;

    var effects: [effects_per_step_max]app_mod.Effect = undefined;
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    try std.testing.expectEqual(@as(usize, 0), (try loop.stepBytes("\x1b", &writer, &effects)).effect_count);
    const result = try loop.flushInput(&writer, &effects);
    defer for (effects[0..result.effect_count]) |effect| effect.deinit(std.testing.allocator);

    try std.testing.expect(result.shutdown_requested);
    try std.testing.expect(!loop.running);
}
