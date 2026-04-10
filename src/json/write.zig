const std = @import("std");

/// Materialize a writer-first serializer into an owned byte slice.
///
/// The canonical API should remain `write*(writer, value) !void`; this
/// helper exists for compatibility wrappers and tests that still want a
/// `[]u8` result.
pub fn toOwnedSlice(allocator: std.mem.Allocator, value: anytype, comptime write_fn: anytype) ![]u8 {
    var scratch_gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = scratch_gpa.deinit();
    const scratch = scratch_gpa.allocator();

    var out: std.io.Writer.Allocating = .init(scratch);
    errdefer out.deinit();

    try @call(.auto, write_fn, .{ &out.writer, value });

    const buf = try out.toOwnedSlice();
    defer scratch.free(buf);
    return try allocator.dupe(u8, buf);
}
