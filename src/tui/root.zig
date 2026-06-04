const substrate = @import("substrate/root.zig");

pub const product = @import("product/root.zig");
pub const Terminal = substrate.Terminal;
pub const TerminalSize = substrate.terminal.Size;

test {
    _ = product;
    _ = Terminal;
    _ = TerminalSize;
}
