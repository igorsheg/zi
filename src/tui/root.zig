pub const primitive = @import("primitive/root.zig");
pub const product = @import("product/root.zig");
pub const substrate = @import("substrate/root.zig");

test {
    _ = primitive;
    _ = product;
    _ = substrate;
}
