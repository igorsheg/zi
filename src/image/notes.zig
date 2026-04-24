const std = @import("std");
const dimensions_mod = @import("dimensions.zig");

pub fn omittedInlineNote() []const u8 {
    return "[Image omitted: could not be resized below the inline image size limit.]";
}

pub fn formatDimensionNote(
    allocator: std.mem.Allocator,
    original: dimensions_mod.Dimensions,
    displayed: dimensions_mod.Dimensions,
) !?[]u8 {
    if (original.width == displayed.width and original.height == displayed.height) return null;
    const scale = @as(f64, @floatFromInt(original.width)) / @as(f64, @floatFromInt(displayed.width));
    const note = try std.fmt.allocPrint(
        allocator,
        "[Image: original {d}x{d}, displayed at {d}x{d}. Multiply coordinates by {d:.2} to map to original image.]",
        .{ original.width, original.height, displayed.width, displayed.height, scale },
    );
    return note;
}

test "formatDimensionNote mirrors pi-mono resized-image wording" {
    const note = (try formatDimensionNote(std.testing.allocator, .{ .width = 4000, .height = 3000 }, .{ .width = 2000, .height = 1500 })).?;
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "[Image: original 4000x3000, displayed at 2000x1500. Multiply coordinates by 2.00 to map to original image.]",
        note,
    );
    try std.testing.expect((try formatDimensionNote(std.testing.allocator, .{ .width = 5, .height = 5 }, .{ .width = 5, .height = 5 })) == null);
}
