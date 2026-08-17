const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), io, &buffer);
    try writer.interface.writeAll("zi zig substrate ready\n");
    try writer.interface.flush();
}
