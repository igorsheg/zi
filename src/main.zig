const std = @import("std");
const runtime = @import("runtime/root.zig");

pub const std_options: std.Options = .{
    .logFn = runtime.log.logFn,
};

pub fn main(init: std.process.Init) !void {
    try runtime.app.main(init);
}
