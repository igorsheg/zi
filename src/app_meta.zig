const std = @import("std");

pub const name = "zi";
pub const version = "0.0.1";
pub const tagline = "AI coding agent";

pub fn writeVersionLine(writer: anytype) !void {
    try writer.print("{s} {s}\n", .{ name, version });
}

test "version line uses app metadata" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVersionLine(&out.writer);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("zi 0.0.1\n", rendered);
}
