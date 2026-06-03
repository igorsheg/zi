const std = @import("std");
const substrate = @import("../substrate/root.zig");
const composer_mod = @import("composer.zig");
const frame_mod = @import("frame.zig");
const keys = @import("keys.zig");
const transcript = @import("transcript.zig");

pub const ProductApp = struct {
    width: u16,
    height: u16,
    composer: composer_mod.ComposerBuffer = .{},
    transcript: transcript.TranscriptBuffer = .{},
    transcript_scroll_rows: usize = 0,
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
                    self.clampTranscriptScroll();
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
                self.clampTranscriptScroll();
                self.dirty = true;
                return null;
            },
        }
    }

    fn applyInput(self: *ProductApp, allocator: std.mem.Allocator, event: substrate.input.InputEvent) !?Effect {
        switch (keys.resolve(event)) {
            .composer_insert => |bytes| {
                try self.composer.insertUtf8(allocator, bytes.slice());
                self.dirty = true;
            },
            .composer_backspace => {
                self.composer.backspace();
                self.dirty = true;
            },
            .composer_left => self.composer.moveLeft(),
            .composer_right => self.composer.moveRight(),
            .composer_submit => if (try self.composer.takeSubmit(allocator)) |text| {
                self.dirty = true;
                return .{ .submit_text = text };
            },
            .transcript_page_up => self.scrollTranscript(frame_mod.transcriptVisibleRows(self.height)),
            .transcript_page_down => self.scrollTranscriptDown(frame_mod.transcriptVisibleRows(self.height)),
            .request_shutdown => return .request_shutdown,
            .none => {},
        }
        return null;
    }

    fn scrollTranscript(self: *ProductApp, rows: usize) void {
        if (rows == 0) return;
        const max = self.transcriptScrollMax();
        const next = @min(max, self.transcript_scroll_rows + rows);
        if (next == self.transcript_scroll_rows) return;
        self.transcript_scroll_rows = next;
        self.dirty = true;
    }

    fn scrollTranscriptDown(self: *ProductApp, rows: usize) void {
        if (rows == 0) return;
        const next = if (self.transcript_scroll_rows > rows) self.transcript_scroll_rows - rows else 0;
        if (next == self.transcript_scroll_rows) return;
        self.transcript_scroll_rows = next;
        self.dirty = true;
    }

    fn clampTranscriptScroll(self: *ProductApp) void {
        self.transcript_scroll_rows = @min(self.transcript_scroll_rows, self.transcriptScrollMax());
    }

    fn transcriptScrollMax(self: *ProductApp) usize {
        return frame_mod.transcriptScrollMax(self.transcript, self.width, frame_mod.transcriptVisibleRows(self.height));
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

test "product app maps ctrl-u and ctrl-d to transcript scroll" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "one" } });
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "two" } });
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "three" } });
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "four" } });

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x15 } } }) == null);
    try std.testing.expectEqual(@as(usize, 1), app.transcript_scroll_rows);
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x04 } } }) == null);
    try std.testing.expectEqual(@as(usize, 0), app.transcript_scroll_rows);
}

test "product app page down at bottom does not dirty" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);
    app.dirty = false;

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .page_down } }) == null);
    try std.testing.expectEqual(@as(usize, 0), app.transcript_scroll_rows);
    try std.testing.expect(!app.dirty);
}

test "product app pages transcript scroll and append preserves it" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "one" } });
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "two" } });
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "three" } });
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "four" } });

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .page_up } }) == null);
    try std.testing.expectEqual(@as(usize, 1), app.transcript_scroll_rows);
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "five" } });
    try std.testing.expectEqual(@as(usize, 1), app.transcript_scroll_rows);
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .page_down } }) == null);
    try std.testing.expectEqual(@as(usize, 0), app.transcript_scroll_rows);
}

test "product app clamps transcript scroll after append eviction" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    for (0..transcript.line_count_max + 1) |index| {
        const text = if (index == 0) "old" else "new";
        _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = text } });
    }
    app.transcript_scroll_rows = std.math.maxInt(usize);
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .role = .system, .text = "tail" } });

    try std.testing.expect(app.transcript_scroll_rows <= app.transcriptScrollMax());
}
