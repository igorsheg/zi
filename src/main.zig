const std = @import("std");
const zi = @import("zi");

pub fn main(init: std.process.Init) !void {
    try zi.coding_agent.cli.main(zi.runtime.Process.init(init), init.minimal.args);
}
