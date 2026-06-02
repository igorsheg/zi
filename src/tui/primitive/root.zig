pub const Color = @import("color.zig").Color;
pub const Rect = @import("rect.zig").Rect;
pub const Style = @import("style.zig").Style;
pub const text_width = @import("text_width.zig");

test {
    _ = Color;
    _ = Rect;
    _ = Style;
    _ = text_width;
}
