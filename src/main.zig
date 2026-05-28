const std = @import("std");
const zi = @import("zi");

pub fn main(init: std.process.Init) !void {
    const process = zi.zistd.Process.init(init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), process.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), process.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, process.gpa);
    defer args.deinit();
    try zi.coding_agent.cli.run(process, &args, stdout, stderr);
}

test "main module links zi" {
    try std.testing.expectEqual(@as(i32, 2), zi.add(1, 1));
}
