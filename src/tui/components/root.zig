pub const text = @import("text.zig");
pub const editor = @import("editor.zig");
pub const markdown = @import("markdown.zig");
pub const footer = @import("footer.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
