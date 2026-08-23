// Adapted from vercel-labs/fx src/ui/render_engine/transcript_blocks.zig.
// Licensed under Apache-2.0 and reduced to Zi's admitted transcript classes.
const Store = @import("../transcript/Store.zig");

pub const BlockGapPolicy = struct {
    default_gap_rows: u16 = 1,

    pub fn gapBetween(
        self: BlockGapPolicy,
        previous: Store.EntryClass,
        next: Store.EntryClass,
    ) u16 {
        if (previous == .tool_status and next == .tool_status) return 0;
        return self.default_gap_rows;
    }
};

pub const default_block_gap_policy: BlockGapPolicy = .{};

pub fn footerBoundaryGapRows(tail: ?Store.EntryClass) u16 {
    return switch (tail orelse return 0) {
        .assistant_turn, .thinking, .tool_status, .system_notice, .model_change => 1,
        .welcome, .user_turn => 0,
    };
}

test "block policy clusters tools and separates conversational turns" {
    const std = @import("std");
    try std.testing.expectEqual(
        @as(u16, 0),
        default_block_gap_policy.gapBetween(.tool_status, .tool_status),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        default_block_gap_policy.gapBetween(.user_turn, .assistant_turn),
    );
    try std.testing.expectEqual(@as(u16, 1), footerBoundaryGapRows(.assistant_turn));
    try std.testing.expectEqual(@as(u16, 0), footerBoundaryGapRows(.user_turn));
}
