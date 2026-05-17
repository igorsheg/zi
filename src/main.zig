const std = @import("std");
const log = @import("runtime/log.zig");
const env = @import("env");
const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .logFn = log.logFn,
};

pub fn main(init: std.process.Init) !void {
    env.setProcessEnvironment(init.environ_map);
    log.setThreadLabel(.main);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const writer = &stderr_writer.interface;

    try writer.print(
        \\zi beta {s}
        \\core-only rebuild branch
        \\retained owners: runtime, agent, ai, session, json, lib
        \\removed owners: coding_agent, tui, zio, spawn, diff, image, search
        \\
    , .{build_options.version});
    try stderr_writer.end();
}
