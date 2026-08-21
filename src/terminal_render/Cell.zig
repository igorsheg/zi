const std = @import("std");
const GraphemeStore = @import("GraphemeStore.zig");
const style = @import("Style.zig");

pub const Color = style.Color;
pub const Attributes = style.Attributes;
pub const Style = style.Style;

pub const Cell = struct {
    grapheme: ?GraphemeStore.Id = null,
    width: u8 = 1,
    lead_offset: u8 = 0,
    style: Style = .{},

    pub fn isContinuation(self: Cell) bool {
        return self.lead_offset != 0;
    }

    pub fn isBlank(self: Cell) bool {
        return self.grapheme == null and self.width == 1 and
            self.lead_offset == 0 and self.style.eql(.{});
    }

    pub fn sameGeometry(a: Cell, b: Cell) bool {
        return a.width == b.width and a.lead_offset == b.lead_offset and
            a.style.eql(b.style) and (a.grapheme == null) == (b.grapheme == null);
    }
};

test "continuation cells identify their lead distance" {
    const continuation: Cell = .{ .width = 0, .lead_offset = 2 };
    try std.testing.expect(continuation.isContinuation());
    try std.testing.expect(!continuation.isBlank());
}
