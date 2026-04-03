pub const text = @import("text.zig");
pub const editor = @import("editor.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
