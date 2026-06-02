const std = @import("std");
const substrate = @import("../substrate/root.zig");
const composer_mod = @import("composer.zig");
const frame_mod = @import("frame.zig");
const transcript = @import("transcript.zig");

pub const ProductApp = struct {
    width: u16,
    height: u16,
    composer: composer_mod.ComposerBuffer = .{},
    transcript: transcript.TranscriptBuffer = .{},
    dirty: bool = true,

    pub fn init(width: u16, height: u16) !ProductApp {
        try frame_mod.checkSize(width, height);
        return .{ .width = width, .height = height };
    }

    pub fn deinit(self: *ProductApp, allocator: std.mem.Allocator) void {
        self.transcript.deinit(allocator);
        self.composer.deinit(allocator);
        self.* = undefined;
    }

    pub fn apply(self: *ProductApp, allocator: std.mem.Allocator, command: Command) !?Effect {
        switch (command) {
            .resize => |size| {
                try frame_mod.checkSize(size.width, size.height);
                if (self.width != size.width or self.height != size.height) {
                    self.width = size.width;
                    self.height = size.height;
                    self.dirty = true;
                }
                return null;
            },
            .input => |event| return try self.applyInput(allocator, event),
            .clear_composer => {
                self.composer.clear();
                self.dirty = true;
                return null;
            },
            .append_transcript => |append| {
                try self.transcript.append(allocator, append);
                self.dirty = true;
                return null;
            },
        }
    }

    fn applyInput(self: *ProductApp, allocator: std.mem.Allocator, event: substrate.input.InputEvent) !?Effect {
        switch (event) {
            .text => |bytes| {
                try self.composer.insertUtf8(allocator, bytes.slice());
                self.dirty = true;
            },
            .key => |key| switch (key) {
                .backspace => {
                    self.composer.backspace();
                    self.dirty = true;
                },
                .arrow_left => self.composer.moveLeft(),
                .arrow_right => self.composer.moveRight(),
                .enter => if (try self.composer.takeSubmit(allocator)) |text| {
                    self.dirty = true;
                    return .{ .submit_text = text };
                },
                .escape => return .request_shutdown,
                .ctrl => |c| if (c == 0x03) return .request_shutdown,
                else => {},
            },
            else => {},
        }
        return null;
    }
};

pub const Command = union(enum) {
    resize: Size,
    input: substrate.input.InputEvent,
    clear_composer,
    append_transcript: transcript.TranscriptAppend,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Effect = union(enum) {
    submit_text: []u8,
    request_shutdown,

    pub fn deinit(self: Effect, allocator: std.mem.Allocator) void {
        switch (self) {
            .submit_text => |text| allocator.free(text),
            .request_shutdown => {},
        }
    }
};

test "product app applies input through one mutation path" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    const text = substrate.input.InlineBytes.from("hello");
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .text = text } }) == null);
    try std.testing.expectEqualStrings("hello", app.composer.text());

    const effect = (try app.apply(std.testing.allocator, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", effect.submit_text);
    try std.testing.expectEqualStrings("", app.composer.text());
}

test "product app maps escape and ctrl-c to shutdown" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        app_mod_effect_request_shutdown,
        try app.apply(std.testing.allocator, .{ .input = .{ .key = .escape } }),
    );
    try std.testing.expectEqual(
        app_mod_effect_request_shutdown,
        try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x03 } } }),
    );
}

const app_mod_effect_request_shutdown: ?Effect = .request_shutdown;

test "product app applies transcript append through apply" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    var source = [_]u8{ 'o', 'k' };
    try std.testing.expect(try app.apply(std.testing.allocator, .{
        .append_transcript = .{ .role = .assistant, .text = &source },
    }) == null);
    source[0] = 'n';

    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.transcript.lines.items.len);
    try std.testing.expectEqualStrings("ok", app.transcript.lines.items[0].text);
}
