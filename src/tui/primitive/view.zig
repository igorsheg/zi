const std = @import("std");
const buffer = @import("buffer.zig");

pub const ViewId = enum(u32) {
    _,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn init(x: u16, y: u16, width: u16, height: u16) Rect {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        return .{ .x = x, .y = y, .width = width, .height = height };
    }
};

pub const View = struct {
    id: ViewId,
    buffer_id: buffer.BufferId,
    rect: Rect,
    scroll_row: u32 = 0,
    cursor_row: u32 = 0,
    cursor_col: u32 = 0,
    revision_seen: u64 = 0,

    pub fn init(id: ViewId, buffer_id: buffer.BufferId, rect: Rect) View {
        return .{
            .id = id,
            .buffer_id = buffer_id,
            .rect = rect,
        };
    }

    pub fn markSeen(self: *View, revision: u64) void {
        std.debug.assert(revision >= self.revision_seen);
        self.revision_seen = revision;
    }
};

test "view owns presentation state over a buffer" {
    const id: ViewId = @enumFromInt(1);
    const buffer_id: buffer.BufferId = @enumFromInt(2);
    var v = View.init(id, buffer_id, .init(0, 0, 80, 24));
    v.scroll_row = 3;
    v.markSeen(9);
    try std.testing.expectEqual(buffer_id, v.buffer_id);
    try std.testing.expectEqual(@as(u32, 3), v.scroll_row);
    try std.testing.expectEqual(@as(u64, 9), v.revision_seen);
}
