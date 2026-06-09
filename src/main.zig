const std = @import("std");
const cli = @import("cli/root.zig");
const runtime = @import("runtime/root.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    try cli.main(runtime.Process.init(init), init.minimal.args);
}
