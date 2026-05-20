const std = @import("std");
const app = @import("../../runtime/app.zig");
const spec = @import("spec.zig");

pub fn writeVersion(writer: anytype) !void {
    try app.writeVersionLine(writer);
}

pub fn writeGeneral(writer: anytype) !void {
    try writer.writeAll("Usage:\n  zi [options] <prompt>\n\nOptions:\n");
    for (spec.all_flags) |flag| {
        if (flag.short) |short| {
            try writer.print("  -{c}, --{s}", .{ short, flag.long });
        } else {
            try writer.print("      --{s}", .{flag.long});
        }
        if (flag.value_name.len > 0) try writer.print(" {s}", .{flag.value_name});
        try writer.print("\n      {s}\n", .{flag.description});
    }
}

test "help includes every flag" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeGeneral(buf.writer(std.testing.allocator));
    for (spec.all_flags) |flag| try std.testing.expect(std.mem.indexOf(u8, buf.items, flag.long) != null);
}
