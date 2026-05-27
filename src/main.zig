const std = @import("std");
const zi = @import("zi");

pub fn main(init: std.process.Init) !void {
    const process = zi.runtime.Process.init(init);

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
    _ = args.next();
    const prompt = args.next() orelse {
        try printUsageAndExit(stderr);
    };
    if (args.next() != null) {
        try printUsageAndExit(stderr);
    }

    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);
    const session_id = try std.fmt.allocPrint(process.gpa, "cli-{d}", .{timestamp});
    defer process.gpa.free(session_id);

    var runtime = try zi.coding_agent.sdk.createRuntimeHost(process.gpa, process.io, .{
        .cwd = ".",
        .agent_dir = zi.coding_agent.paths.global_config_dir_name,
        .current_date = timestamp_text,
        .session_id = session_id,
        .timestamp = timestamp_text,
    });
    defer runtime.deinit();

    try zi.coding_agent.print_mode.run(&runtime.host, stdout, stderr, .{ .prompt = prompt });
}

fn printUsageAndExit(stderr: *std.Io.Writer) !noreturn {
    try stderr.writeAll("usage: zi <prompt>\n");
    try stderr.flush();
    std.process.exit(2);
}

test "main module links zi" {
    try std.testing.expectEqual(@as(i32, 2), zi.add(1, 1));
}
