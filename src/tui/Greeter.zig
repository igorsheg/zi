//! Empty-state greeter chrome. The app owns whether it is present; render owns
//! the built-in visual shape. Text is stored inline so future contributed
//! greeters cannot allocate or grow unbounded resident state.
const std = @import("std");
const text_mod = @import("text.zig");

const Greeter = @This();

pub const row_count: usize = 3;
pub const text_bytes_max: usize = 160;

pub const Set = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    auto_hide_on_first_input: bool = true,
};

title: [text_bytes_max]u8 = undefined,
title_len: u8 = 0,
subtitle: [text_bytes_max]u8 = undefined,
subtitle_len: u8 = 0,
auto_hide_on_first_input: bool = true,

pub fn from(update: Set) Greeter {
    var greeter: Greeter = .{};
    greeter.title_len = copySanitized(&greeter.title, update.title);
    greeter.subtitle_len = copySanitized(&greeter.subtitle, update.subtitle);
    greeter.auto_hide_on_first_input = update.auto_hide_on_first_input;
    return greeter;
}

pub fn titleSlice(self: *const Greeter) []const u8 {
    return self.title[0..self.title_len];
}

pub fn subtitleSlice(self: *const Greeter) []const u8 {
    return self.subtitle[0..self.subtitle_len];
}

fn copySanitized(dest: *[text_bytes_max]u8, bytes: []const u8) u8 {
    var scratch: [text_bytes_max]u8 = undefined;
    const clean = text_mod.sanitizeInto(&scratch, bytes);
    var len: usize = 0;
    for (clean) |byte| {
        dest[len] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
        len += 1;
    }
    return @intCast(len);
}

test "greeter stores bounded sanitized title and subtitle" {
    const greeter = Greeter.from(.{
        .title = "zi 0.1\nlocal",
        .subtitle = "Type /\xff",
    });
    try std.testing.expectEqualStrings("zi 0.1 local", greeter.titleSlice());
    try std.testing.expectEqualStrings("Type /\u{fffd}", greeter.subtitleSlice());
    try std.testing.expect(greeter.auto_hide_on_first_input);
}

test "greeter can stay visible while the composer receives input" {
    const greeter = Greeter.from(.{
        .title = "zi",
        .auto_hide_on_first_input = false,
    });
    try std.testing.expect(!greeter.auto_hide_on_first_input);
}
