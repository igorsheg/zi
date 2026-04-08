pub const builtins = @import("builtins.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
