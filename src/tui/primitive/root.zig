pub const chrome = @import("chrome.zig");
pub const Color = @import("color.zig").Color;
pub const Rect = @import("rect.zig").Rect;
pub const Style = @import("style.zig").Style;
pub const text = @import("text.zig");

test {
    _ = chrome;
    _ = Color;
    _ = Rect;
    _ = Style;
    _ = text;
}
