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

    var host = try zi.coding_agent.RuntimeHost.init(process.gpa, process.io, .{
        .cwd = ".",
        .agent_dir = ".zi",
        .current_date = timestamp_text,
    }, .{
        .session_id = session_id,
        .timestamp = timestamp_text,
    });
    defer {
        drainPrintEvents(&host, stdout, stderr) catch {};
        host.requestShutdown();
        while (host.drainPublicEvent() != null) {}
        host.deinit();
    }

    try host.prompt(prompt, &.{});
    try drainPrintEvents(&host, stdout, stderr);
}

fn printUsageAndExit(stderr: *std.Io.Writer) !noreturn {
    try stderr.writeAll("usage: zi <prompt>\n");
    try stderr.flush();
    std.process.exit(2);
}

fn drainPrintEvents(
    host: *zi.coding_agent.RuntimeHost,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var wrote_text = false;
    while (host.drainPublicEvent()) |event| {
        switch (event) {
            .agent_event => |agent_event| switch (agent_event) {
                .message_end => |payload| switch (payload.message) {
                    .assistant => |assistant| {
                        if (assistant.error_message) |message| return printAssistantError(stderr, message);
                        for (assistant.content) |content| {
                            if (content != .text) continue;
                            try stdout.writeAll(content.text.text);
                            wrote_text = true;
                        }
                    },
                    else => {},
                },
                else => {},
            },
            else => {},
        }
    }
    if (wrote_text) try stdout.writeByte('\n');
}

fn printAssistantError(stdout: *std.Io.Writer, message: []const u8) !void {
    try stdout.writeAll(message);
    try stdout.writeByte('\n');
}

test "main module links zi" {
    try std.testing.expectEqual(@as(i32, 2), zi.add(1, 1));
}
