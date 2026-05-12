const std = @import("std");

pub fn toOwnedSlice(allocator: std.mem.Allocator, value: anytype, comptime write_fn: anytype) ![]u8 {
    var scratch_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = scratch_gpa.deinit();
    const scratch = scratch_gpa.allocator();

    var out: std.Io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();

    try @call(.auto, write_fn, .{ &out.writer, value });

    const buf = try out.toOwnedSlice();
    defer scratch.free(buf);
    return try allocator.dupe(u8, buf);
}
