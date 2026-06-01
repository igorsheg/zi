pub const event_pump = @import("event_pump.zig");
pub const input = @import("input.zig");
pub const input_buffer = @import("input_buffer.zig");
pub const terminal = @import("terminal.zig");
pub const text = @import("text.zig");

test {
    _ = event_pump;
    _ = input;
    _ = input_buffer;
    _ = terminal;
    _ = text;
}
