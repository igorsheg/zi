pub const bash = @import("bash.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
