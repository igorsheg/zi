const std = @import("std");
const substrate = @import("../substrate/root.zig");

pub const KeyAction = union(enum) {
    composer_insert: substrate.input.InlineBytes,
    composer_backspace,
    composer_left,
    composer_right,
    composer_start,
    composer_end,
    composer_submit,
    transcript_page_up,
    transcript_page_down,
    request_shutdown,
    none,
};

pub fn resolve(event: substrate.input.InputEvent) KeyAction {
    return switch (event) {
        .text => |bytes| .{ .composer_insert = bytes },
        .key => |key| resolveKey(key),
        else => .none,
    };
}

fn resolveKey(key: substrate.input.Key) KeyAction {
    return switch (key) {
        .backspace => .composer_backspace,
        .arrow_left => .composer_left,
        .arrow_right => .composer_right,
        .home => .composer_start,
        .end => .composer_end,
        .enter => .composer_submit,
        .page_up => .transcript_page_up,
        .page_down => .transcript_page_down,
        .escape => .request_shutdown,
        .ctrl => |c| switch (c) {
            0x03 => .request_shutdown,
            0x15 => .transcript_page_up,
            0x04 => .transcript_page_down,
            else => .none,
        },
        else => .none,
    };
}

test "product keys resolve composer actions" {
    const text = substrate.input.InlineBytes.from("a");
    try std.testing.expect(resolve(.{ .text = text }) == .composer_insert);
    try std.testing.expect(resolve(.{ .key = .backspace }) == .composer_backspace);
    try std.testing.expect(resolve(.{ .key = .arrow_left }) == .composer_left);
    try std.testing.expect(resolve(.{ .key = .arrow_right }) == .composer_right);
    try std.testing.expect(resolve(.{ .key = .home }) == .composer_start);
    try std.testing.expect(resolve(.{ .key = .end }) == .composer_end);
    try std.testing.expect(resolve(.{ .key = .enter }) == .composer_submit);
}

test "product keys resolve transcript and shutdown actions" {
    try std.testing.expect(resolve(.{ .key = .page_up }) == .transcript_page_up);
    try std.testing.expect(resolve(.{ .key = .page_down }) == .transcript_page_down);
    try std.testing.expect(resolve(.{ .key = .{ .ctrl = 0x15 } }) == .transcript_page_up);
    try std.testing.expect(resolve(.{ .key = .{ .ctrl = 0x04 } }) == .transcript_page_down);
    try std.testing.expect(resolve(.{ .key = .escape }) == .request_shutdown);
    try std.testing.expect(resolve(.{ .key = .{ .ctrl = 0x03 } }) == .request_shutdown);
    try std.testing.expect(resolve(.{ .key = .arrow_up }) == .none);
}
