const std = @import("std");

pub const Viewport = struct {
    height_rows: u16 = 0,
    scroll_row_offset: usize = 0,
    follow_tail: bool = true,

    pub fn resize(self: *Viewport, height_rows: u16, content_row_count: usize) void {
        self.height_rows = height_rows;
        self.clamp(content_row_count);
    }

    pub fn updateContent(self: *Viewport, content_row_count: usize) void {
        self.clamp(content_row_count);
    }

    pub fn scrollUp(self: *Viewport, row_count: usize) void {
        self.follow_tail = false;
        self.scroll_row_offset -|= row_count;
    }

    pub fn scrollDown(self: *Viewport, row_count: usize, content_row_count: usize) void {
        self.scroll_row_offset = @min(self.scroll_row_offset + row_count, self.maxOffset(content_row_count));
        self.follow_tail = self.scroll_row_offset == self.maxOffset(content_row_count);
    }

    pub fn jumpToTail(self: *Viewport, content_row_count: usize) void {
        self.follow_tail = true;
        self.scroll_row_offset = self.maxOffset(content_row_count);
    }

    fn clamp(self: *Viewport, content_row_count: usize) void {
        const max_offset = self.maxOffset(content_row_count);
        if (self.follow_tail) {
            self.scroll_row_offset = max_offset;
        } else {
            self.scroll_row_offset = @min(self.scroll_row_offset, max_offset);
        }
    }

    fn maxOffset(self: Viewport, content_row_count: usize) usize {
        return content_row_count -| self.height_rows;
    }
};

test "viewport follows tail until user scrolls" {
    var viewport: Viewport = .{};
    viewport.resize(3, 10);
    try std.testing.expectEqual(@as(usize, 7), viewport.scroll_row_offset);
    try std.testing.expect(viewport.follow_tail);

    viewport.scrollUp(2);
    try std.testing.expectEqual(@as(usize, 5), viewport.scroll_row_offset);
    try std.testing.expect(!viewport.follow_tail);

    viewport.updateContent(12);
    try std.testing.expectEqual(@as(usize, 5), viewport.scroll_row_offset);

    viewport.jumpToTail(12);
    try std.testing.expectEqual(@as(usize, 9), viewport.scroll_row_offset);
    try std.testing.expect(viewport.follow_tail);
}
