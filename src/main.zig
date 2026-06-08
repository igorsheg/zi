const std = @import("std");
const cli = @import("coding_agent/cli/root.zig");
const runtime = @import("runtime/root.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    var zio_runtime = try runtime.Runtime.init(init.gpa, .{});
    defer zio_runtime.deinit();

    try cli.main(runtime.Process.init(zio_runtime, init), init.minimal.args);
}
