const std = @import("std");
const dimensions_mod = @import("dimensions.zig");

pub const InlinePolicy = struct {
    auto_resize: bool = true,
    max_width: u32 = 2000,
    max_height: u32 = 2000,
    max_base64_bytes: usize = (9 * 1024 * 1024) / 2,
};

pub const InlineDecision = enum {
    attach_original,
    needs_resize,
};

pub fn evaluateInlineImage(raw_len: usize, dims: ?dimensions_mod.Dimensions, policy: InlinePolicy) InlineDecision {
    if (!policy.auto_resize) return .attach_original;
    if (std.base64.standard.Encoder.calcSize(raw_len) >= policy.max_base64_bytes) return .needs_resize;
    if (dims) |d| {
        if (d.width > policy.max_width or d.height > policy.max_height) return .needs_resize;
    }
    return .attach_original;
}

test "evaluateInlineImage respects auto-resize byte and dimension policy" {
    const dims_ok = dimensions_mod.Dimensions{ .width = 1200, .height = 800 };
    const dims_large = dimensions_mod.Dimensions{ .width = 3000, .height = 1200 };

    try std.testing.expectEqual(InlineDecision.attach_original, evaluateInlineImage(1024, dims_ok, .{}));
    try std.testing.expectEqual(InlineDecision.needs_resize, evaluateInlineImage(1024, dims_large, .{}));
    try std.testing.expectEqual(InlineDecision.needs_resize, evaluateInlineImage(4 * 1024 * 1024, dims_ok, .{}));
    try std.testing.expectEqual(InlineDecision.attach_original, evaluateInlineImage(4 * 1024 * 1024, dims_large, .{ .auto_resize = false }));
}
