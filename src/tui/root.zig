pub const infra = @import("infra/root.zig");
pub const primitive = @import("primitive/root.zig");
pub const substrate = @import("substrate/root.zig");

test {
    _ = infra;
    _ = primitive;
    _ = substrate;
}
