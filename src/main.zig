const std = @import("std");
const zi = @import("zi");

pub fn main(init: std.process.Init) !void {
    const exit_code = try zi.cli.run(init);
    if (exit_code != 0) std.process.exit(exit_code);
}
