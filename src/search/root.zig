pub const plain = @import("plain.zig");
pub const path = @import("path.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const query = @import("query.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
