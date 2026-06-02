const std = @import("std");

pub const max_sequence = 16;
pub const Key = union(enum) { char: u21, escape, enter, backspace, ctrl: u8, unknown: []const u8 };

pub fn parse(bytes: []const u8) Key {
    if (bytes.len == 0) return .{ .unknown = bytes };
    if (bytes.len > max_sequence) return .{ .unknown = bytes[0..max_sequence] };
    if (bytes[0] == 0x1b) return .escape;
    if (bytes[0] == '\r' or bytes[0] == '\n') return .enter;
    if (bytes[0] == 0x7f) return .backspace;
    if (bytes[0] > 0 and bytes[0] < 0x20) return .{ .ctrl = bytes[0] };
    if (bytes.len == 1 and bytes[0] < 0x80) return .{ .char = bytes[0] };
    if (std.unicode.utf8ValidateSlice(bytes)) return .{ .unknown = bytes };
    return .{ .unknown = bytes };
}

test "input parser handles ascii escape ctrl malformed" {
    const a: Key = .{ .char = 'a' };
    const ctrl_c: Key = .{ .ctrl = 3 };
    try std.testing.expectEqual(a, parse("a"));
    try std.testing.expectEqual(Key.escape, parse("\x1b"));
    try std.testing.expectEqual(ctrl_c, parse("\x03"));
    try std.testing.expectEqual(Key.backspace, parse("\x7f"));
    try std.testing.expect(parse("\xff") == .unknown);
}
