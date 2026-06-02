pub const ansi = @import("ansi.zig");
pub const input = @import("input.zig");
pub const raw_mode = @import("raw_mode.zig");
pub const terminal = @import("terminal.zig");

pub const Terminal = terminal.Terminal;

 test {
    _ = ansi;
    _ = input;
    _ = raw_mode;
    _ = terminal;
}
