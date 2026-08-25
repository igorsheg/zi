const std = @import("std");

const version = "0.1.0-dev";

pub const Args = @import("Args.zig");
pub const ProcessAdapters = @import("ProcessAdapters.zig");
pub const ProcessFacts = @import("ProcessFacts.zig");
pub const OneShot = @import("OneShot.zig");
pub const SessionStartup = @import("SessionStartup.zig");
pub const StartupConfig = @import("StartupConfig.zig");
pub const Stats = @import("Stats.zig");

pub const Command = union(enum) {
    help,
    version,
    unavailable_run,
    invalid: []const u8,
};

pub fn parse(arguments: []const []const u8) Command {
    if (arguments.len == 0) return .unavailable_run;
    if (arguments.len == 1) {
        if (std.mem.eql(u8, arguments[0], "-h") or std.mem.eql(u8, arguments[0], "--help")) {
            return .help;
        }
        if (std.mem.eql(u8, arguments[0], "-v") or std.mem.eql(u8, arguments[0], "--version")) {
            return .version;
        }
    }
    return .{ .invalid = arguments[0] };
}

/// Owns process argument adaptation, output, and exit-code mapping.
pub fn run(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.next();

    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    while (iterator.next()) |argument| try arguments.append(allocator, argument);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.Writer.init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};

    const exit_code = try dispatch(parse(arguments.items), stdout, stderr);
    try stdout.flush();
    try stderr.flush();
    return exit_code;
}

fn dispatch(command: Command, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    switch (command) {
        .help => {
            try writeHelp(stdout);
            return 0;
        },
        .version => {
            try stdout.print("zi {s}\n", .{version});
            return 0;
        },
        .unavailable_run => {
            try stderr.writeAll("Interactive mode is not implemented yet. Run zi --help.\n");
            return 1;
        },
        .invalid => |argument| {
            try stderr.print("Unknown argument: {s}\nRun zi --help for usage.\n", .{argument});
            return 2;
        },
    }
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zi [OPTIONS]
        \\
        \\A terminal-native coding agent. This clean rewrite currently exposes
        \\only its bootstrap command surface.
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -v, --version    Show the version
        \\
    );
}

test {
    _ = Args;
    _ = ProcessAdapters;
    _ = ProcessFacts;
    _ = OneShot;
    _ = SessionStartup;
    _ = StartupConfig;
    _ = Stats;
}

test "CLI parser admits only the bootstrap command surface" {
    try std.testing.expect(parse(&.{"--help"}) == .help);
    try std.testing.expect(parse(&.{"-h"}) == .help);
    try std.testing.expect(parse(&.{"--version"}) == .version);
    try std.testing.expect(parse(&.{"-v"}) == .version);
    try std.testing.expect(parse(&.{}) == .unavailable_run);

    const invalid = parse(&.{"--provider"});
    try std.testing.expect(invalid == .invalid);
    try std.testing.expectEqualStrings("--provider", invalid.invalid);
}
