const std = @import("std");
const app_mod = @import("App.zig");
const composer_mod = @import("composer.zig");
const frame_mod = @import("frame.zig");
const infra = @import("../infra/root.zig");
const substrate = @import("../substrate/root.zig");

pub const output_size_bytes_default = infra.output_buffer.frame_output_size_default;
pub const input_events_per_step_max = substrate.input.events_per_feed_max;
pub const effects_per_step_max = input_events_per_step_max;
pub const paste_bytes_max = composer_mod.buffer_size_bytes_max;

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
    paste_active: bool = false,
    paste_overflow: bool = false,
    paste_len: usize = 0,
    paste_buffer: [paste_bytes_max]u8 = undefined,
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
            try self.applyInputEvent(event, effects, &result);
        }
        return result;
    }

    pub fn flushInput(self: *ProductLoop, effects: []app_mod.Effect) !FeedResult {
        var events: [1]substrate.input.InputEvent = undefined;
        const count = self.decoder.flushIncomplete(&events);
        var result: FeedResult = .{ .input_event_count = count };
        if (count == 0) return result;
        try self.applyInputEvent(events[0], effects, &result);
        return result;
    }

    fn applyInputEvent(
        self: *ProductLoop,
        event: substrate.input.InputEvent,
        effects: []app_mod.Effect,
        result: *FeedResult,
    ) !void {
        if (try self.applyPasteEvent(event, result)) return;
        if (try self.app.apply(self.allocator, .{ .input = event })) |effect| {
            self.pushEffect(effect, effects, result);
        }
    }

    fn applyPasteEvent(self: *ProductLoop, event: substrate.input.InputEvent, result: *FeedResult) !bool {
        switch (event) {
            .paste_begin => {
                self.paste_active = true;
                self.paste_overflow = false;
                self.paste_len = 0;
                return true;
            },
            .paste_end => {
                if (!self.paste_active) return true;
                defer self.resetPaste();
                if (self.paste_overflow) {
                    result.input_overflow = true;
                    result.truncated = true;
                    return true;
                }
                _ = try self.app.apply(self.allocator, .{
                    .insert_composer_text = self.paste_buffer[0..self.paste_len],
                });
                return true;
            },
            else => {},
        }

        if (!self.paste_active) return false;
        switch (event) {
            .text => |bytes| self.appendPaste(bytes.slice()),
            .key => |key| switch (key) {
                .enter => self.appendPaste("\n"),
                .tab => self.appendPaste("\t"),
                else => {},
            },
            else => {},
        }
        return true;
    }

    fn appendPaste(self: *ProductLoop, bytes: []const u8) void {
        if (self.paste_overflow) return;
        if (bytes.len > self.paste_buffer.len - self.paste_len) {
            self.paste_overflow = true;
            return;
        }
        @memcpy(self.paste_buffer[self.paste_len..][0..bytes.len], bytes);
        self.paste_len += bytes.len;
    }

    fn resetPaste(self: *ProductLoop) void {
        self.paste_active = false;
        self.paste_overflow = false;
        self.paste_len = 0;
    }

    fn pushEffect(self: *ProductLoop, effect: app_mod.Effect, effects: []app_mod.Effect, result: *FeedResult) void {
        if (result.effect_count == effects.len) {
            effect.deinit(self.allocator);
            result.effect_overflow = true;
            return;
        }
        effects[result.effect_count] = effect;
        result.effect_count += 1;
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

test "product loop bracketed paste inserts newlines without submit" {
    var loop = try ProductLoop.init(std.testing.allocator, 20, 6, infra.output_buffer.frame_output_size_min);
    defer loop.deinit();
    var effects: [2]app_mod.Effect = undefined;

    const fed = try loop.feedBytes("\x1b[200~one\ntwo\x1b[201~", &effects);
    defer for (effects[0..fed.effect_count]) |effect| effect.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 9), fed.input_event_count);
    try std.testing.expectEqual(@as(usize, 0), fed.effect_count);
    try std.testing.expectEqualStrings("one\ntwo", loop.app.composer.text());
}

test "product loop drops overflowing paste before composer mutation" {
    var loop = try ProductLoop.init(std.testing.allocator, 20, 6, infra.output_buffer.frame_output_size_min);
    defer loop.deinit();
    var effects: [1]app_mod.Effect = undefined;

    _ = try loop.feedBytes("keep", &effects);
    var begin_events: [1]app_mod.Effect = undefined;
    _ = try loop.feedBytes("\x1b[200~", &begin_events);
    var chunk = [_]u8{'x'} ** input_events_per_step_max;
    var index: usize = 0;
    while (index <= paste_bytes_max / chunk.len) : (index += 1) {
        _ = try loop.feedBytes(&chunk, &effects);
    }
    const end = try loop.feedBytes("\x1b[201~", &effects);

    try std.testing.expect(end.input_overflow);
    try std.testing.expect(end.truncated);
    try std.testing.expectEqualStrings("keep", loop.app.composer.text());
}

test "product loop normal enter still submits outside paste" {
    var loop = try ProductLoop.init(std.testing.allocator, 20, 4, infra.output_buffer.frame_output_size_min);
    defer loop.deinit();
    var effects: [1]app_mod.Effect = undefined;

    const fed = try loop.feedBytes("hello\r", &effects);
    defer for (effects[0..fed.effect_count]) |effect| effect.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), fed.effect_count);
    try std.testing.expectEqualStrings("hello", effects[0].submit_text);
}

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
