const std = @import("std");
const zi = @import("zi");

pub fn main(init: std.process.Init) !void {
    var zio_runtime = try zi.runtime.Runtime.init(init.gpa, .{});
    defer zio_runtime.deinit();

    try zi.coding_agent.cli.main(zi.runtime.Process.init(zio_runtime, init), init.minimal.args);
}
