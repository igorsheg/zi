const std = @import("std");
const cli = @import("cli/root.zig");
const runtime = @import("runtime/root.zig");
const vaxis = @import("vaxis");

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(message: []const u8, return_address: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(message, return_address);
}

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    try cli.main(runtime.Process.init(init), init.minimal.args);
}
