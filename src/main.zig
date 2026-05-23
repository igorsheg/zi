const std = @import("std");
const zi = @import("zi");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("zi {d}\n", .{zi.add(1, 1)});
    try stdout.flush();
}

test "main module links zi" {
    try std.testing.expectEqual(@as(i32, 2), zi.add(1, 1));
}
