const std = @import("std");
const app_meta = @import("../app_meta.zig");

pub fn writeGeneralHelp(writer: anytype) !void {
    try writer.print("{s} — {s}\n\n", .{ app_meta.name, app_meta.tagline });
    try writer.print(
        "Usage:\n" ++
            "  {s} [run-options] [prompt]\n" ++
            "  {s} --continue\n" ++
            "  {s} --resume\n" ++
            "  {s} --session <path|id>\n" ++
            "  {s} --list-models [search]\n" ++
            "  {s} --help\n" ++
            "  {s} --version\n\n",
        .{
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
        },
    );
    try writer.print(
        "Behavior:\n" ++
            "  {s}                     Start interactive mode\n" ++
            "  {s} \"prompt\"            Start interactive mode with an initial prompt\n" ++
            "  {s} -p \"prompt\"         Run in batch text mode and print the final assistant text\n" ++
            "  {s} --mode json \"prompt\"\n" ++
            "                         Run in batch JSON mode and emit JSON lines\n" ++
            "  printf 'text' | {s} -p    Use piped stdin as the batch prompt body\n" ++
            "  {s} --continue          Resume the most recent session for this project\n" ++
            "  {s} --resume            Open the interactive session picker\n" ++
            "  {s} --session <path|id> Resume a specific session by path or ID prefix\n\n",
        .{
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
            app_meta.name,
        },
    );
    try writer.writeAll(
        "Run options:\n" ++
            "  -p, --print                  Select batch text mode; prints the final assistant text only\n" ++
            "  --mode <text|json>           Select batch output mode; JSON emits a session header then event lines\n" ++
            "  --continue, -c               Resume the most recent session for this project\n" ++
            "  --resume, -r                 Open the interactive session picker\n" ++
            "  --session <path|id>          Resume a specific session by path or ID prefix\n" ++
            "  --model <id>                 Model ID or pattern\n" ++
            "  --api-key <key>              API key override\n" ++
            "  --no-session                 Disable session persistence\n" ++
            "  --tools <filter>             Comma-separated list of allowed tools\n" ++
            "  --append-system-prompt <text|path>\n" ++
            "                              Append literal text or file contents to the system prompt\n\n" ++
            "Actions:\n" ++
            "  --list-models [search]       List available models (optional fuzzy search)\n" ++
            "  -h, --help                   Show help\n" ++
            "  -v, --version                Show version\n\n" ++
            "Notes:\n" ++
            "  - batch mode is explicit: use -p or --mode\n" ++
            "  - piped stdin is read only for explicit batch mode, never to force batch selection\n" ++
            "  - batch mode accepts a positional prompt, piped stdin, or both; stdin is concatenated first\n" ++
            "  - empty or whitespace-only piped stdin is ignored\n" ++
            "  - batch text mode prints the final assistant text only after completion\n" ++
            "  - batch JSON mode emits a session header first when persistence is enabled\n" ++
            "  - batch text failures come from the final assistant error/abort state\n" ++
            "  - --list-models shows available models and supports an optional fuzzy search\n" ++
            "  - session targets are interactive-only and mutually exclusive\n" ++
            "  - prompts cannot be combined with --continue, --resume, or --session\n" ++
            "  - every accepted flag either affects the plan or fails during planning\n\n",
    );
}

pub fn writeVersion(writer: anytype) !void {
    try app_meta.writeVersionLine(writer);
}

test "general help documents explicit session-target behaviors and actions" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeGeneralHelp(&out.writer);
    const rendered = try out.toOwnedSlice();
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Resume the most recent session for this project") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Open the interactive session picker") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Resume a specific session by path or ID prefix") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "prints the final assistant text only") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "session header first") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Use piped stdin as the batch prompt body") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "piped stdin is read only for explicit batch mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "List available models") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "optional fuzzy search") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "session targets are interactive-only and mutually exclusive") != null);
}
