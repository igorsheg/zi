const std = @import("std");
const app_meta = @import("../app_meta.zig");

pub fn writeGeneralHelp(writer: anytype) !void {
    try writer.print(
        \\{s} — {s}
        \\
        \\Usage:
        \\  {s} [run-options] [prompt]
        \\  {s} --list-models
        \\  {s} --help
        \\  {s} --version
        \\
        \\Behavior:
        \\  {s}                     Start interactive mode
        \\  {s} "prompt"            Start interactive mode with an initial prompt
        \\  {s} -p "prompt"         Run in batch text mode and exit
        \\  {s} --mode json "prompt"
        \\                         Run in batch JSON mode and exit
        \\  {s} --continue <path>   Resume a session in interactive mode
        \\
        \\Run options:
        \\  -p, --print                  Select batch text mode; requires a prompt
        \\  --mode <text|json>           Select batch output mode; requires a prompt
        \\  --continue <path>            Resume a session in interactive mode
        \\  --model <id>                 Model ID or pattern
        \\  --api-key <key>              API key override
        \\  --no-session                 Disable session persistence
        \\  --tools <filter>             Comma-separated list of allowed tools
        \\  --append-system-prompt <text|path>
        \\                              Append literal text or file contents to the system prompt
        \\
        \\Actions:
        \\  --list-models                List models with configured auth
        \\  -h, --help                  Show help
        \\  -v, --version               Show version
        \\
        \\Notes:
        \\  - prompts and --continue cannot be combined
        \\  - batch mode is explicit: use -p or --mode
        \\  - every accepted flag either affects the plan or fails during planning
        \\
    , .{
        app_meta.name,
        app_meta.tagline,
        app_meta.name,
        app_meta.name,
        app_meta.name,
        app_meta.name,
        app_meta.name,
        app_meta.name,
        app_meta.name,
        app_meta.name,
        app_meta.name,
    });
}

pub fn writeVersion(writer: anytype) !void {
    try app_meta.writeVersionLine(writer);
}

test "general help documents explicit run behaviors and actions" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeGeneralHelp(&out.writer);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Start interactive mode with an initial prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Run in batch JSON mode and exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "List models with configured auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "prompts and --continue cannot be combined") != null);
}
