const std = @import("std");
const app_mod = @import("App.zig");
const frame_mod = @import("frame.zig");
const infra = @import("../infra/root.zig");
const substrate = @import("../substrate/root.zig");

pub const output_size_bytes_default = infra.output_buffer.frame_output_size_default;
pub const input_events_per_step_max = substrate.input.events_per_feed_max;
pub const effects_per_step_max = input_events_per_step_max;

pub const FeedResult = struct {
    input_event_count: usize = 0,
    effect_count: usize = 0,
    input_overflow: bool = false,
    effect_overflow: bool = false,
    truncated: bool = false,
};

pub const ProductLoop = struct {
    allocator: std.mem.Allocator,
    app: app_mod.ProductApp,
    renderer: infra.Renderer,
    decoder: substrate.input.InputDecoder = .{},
    output_storage: []u8,
    output: infra.FrameOutput,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        output_size_bytes: usize,
    ) !ProductLoop {
        if (output_size_bytes < infra.output_buffer.frame_output_size_min) return error.OutputBufferTooSmall;
        var app = try app_mod.ProductApp.init(width, height);
        errdefer app.deinit(allocator);
        var renderer = try infra.Renderer.init(allocator, width, height, frame_mod.size_cells_max);
        errdefer renderer.deinit();
        const output_storage = try allocator.alloc(u8, output_size_bytes);
        return .{
            .allocator = allocator,
            .app = app,
            .renderer = renderer,
            .output_storage = output_storage,
            .output = infra.FrameOutput.init(output_storage),
        };
    }

    pub fn deinit(self: *ProductLoop) void {
        self.allocator.free(self.output_storage);
        self.renderer.deinit();
        self.app.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feedBytes(self: *ProductLoop, bytes: []const u8, effects: []app_mod.Effect) !FeedResult {
        var events: [input_events_per_step_max]substrate.input.InputEvent = undefined;
        const status = self.decoder.feed(bytes, &events);
        var result: FeedResult = .{
            .input_event_count = status.count,
            .input_overflow = status.overflow,
            .truncated = status.truncated,
        };

        for (events[0..status.count]) |event| {
            if (try self.app.apply(self.allocator, .{ .input = event })) |effect| {
                if (result.effect_count == effects.len) {
                    effect.deinit(self.allocator);
                    result.effect_overflow = true;
                    continue;
                }
                effects[result.effect_count] = effect;
                result.effect_count += 1;
            }
        }
        return result;
    }

    pub fn flushInput(self: *ProductLoop, effects: []app_mod.Effect) !FeedResult {
        var events: [1]substrate.input.InputEvent = undefined;
        const count = self.decoder.flushIncomplete(&events);
        var result: FeedResult = .{ .input_event_count = count };
        if (count == 0) return result;
        if (try self.app.apply(self.allocator, .{ .input = events[0] })) |effect| {
            if (effects.len == 0) {
                effect.deinit(self.allocator);
                result.effect_overflow = true;
            } else {
                effects[0] = effect;
                result.effect_count = 1;
            }
        }
        return result;
    }

    pub fn resize(self: *ProductLoop, width: u16, height: u16) !void {
        _ = try self.app.apply(self.allocator, .{ .resize = .{ .width = width, .height = height } });
    }

    pub fn renderIfDirty(self: *ProductLoop, writer: *std.Io.Writer) !infra.renderer.FrameDiff {
        if (!self.app.dirty) return .{};
        return self.render(writer);
    }

    pub fn render(self: *ProductLoop, writer: *std.Io.Writer) !infra.renderer.FrameDiff {
        self.output.reset();
        try frame_mod.Frame.build(&self.app, &self.renderer);
        const diff = self.renderer.stage(&self.output) catch |err| {
            self.renderer.discard();
            return err;
        };
        writer.writeAll(self.output.writtenSince(diff.mark)) catch |err| {
            self.renderer.discard();
            return err;
        };
        self.renderer.commit();
        self.app.dirty = false;
        return diff;
    }
};

test "product loop feeds input renders and emits submit effect" {
    var loop = try ProductLoop.init(std.testing.allocator, 20, 4, infra.output_buffer.frame_output_size_min);
    defer loop.deinit();
    var effects: [2]app_mod.Effect = undefined;

    const fed = try loop.feedBytes("hello\r", &effects);
    defer for (effects[0..fed.effect_count]) |effect| effect.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), fed.input_event_count);
    try std.testing.expectEqual(@as(usize, 1), fed.effect_count);
    try std.testing.expectEqualStrings("hello", effects[0].submit_text);

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    const diff = try loop.renderIfDirty(&writer);
    try std.testing.expect(diff.changed > 0);
    try std.testing.expect(!loop.app.dirty);
}

test "product loop does not commit renderer on output failure" {
    var loop = try ProductLoop.init(std.testing.allocator, 20, 4, infra.output_buffer.frame_output_size_min);
    defer loop.deinit();
    var effects: [1]app_mod.Effect = undefined;
    const fed = try loop.feedBytes("hello", &effects);
    defer for (effects[0..fed.effect_count]) |effect| effect.deinit(std.testing.allocator);

    var tiny_storage: [1]u8 = undefined;
    var tiny_writer = std.Io.Writer.fixed(&tiny_storage);
    try std.testing.expectError(error.WriteFailed, loop.renderIfDirty(&tiny_writer));
    try std.testing.expect(!loop.renderer.staged);
    try std.testing.expect(loop.app.dirty);

    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    _ = try loop.renderIfDirty(&writer);
    try std.testing.expect(!loop.app.dirty);
}
