const std = @import("std");
const auth = @import("auth.zig");
const interactive = @import("../interactive/root.zig");
const interactive_launch = @import("interactive_launch.zig");
const launch = @import("launch.zig");
const surface = @import("surface.zig");
const trust = @import("trust.zig");

const version = "0.1.0";

/// Adapts the process once, dispatches one admitted invocation, and returns its exit code.
pub fn run(init: std.process.Init, frontend: interactive.Frontend) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.Writer.init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    var argument_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer argument_iterator.deinit();
    _ = argument_iterator.next();
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    while (argument_iterator.next()) |argument| try arguments.append(allocator, argument);

    const stdin_is_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_is_tty = std.Io.File.stdout().isTty(io) catch false;
    const parsed = surface.parseInvocation(arguments.items, .{
        .stdin_is_tty = stdin_is_tty,
        .stdout_is_tty = stdout_is_tty,
    });
    switch (parsed) {
        .rejected => |rejection| {
            try writeCliDiagnostics(stderr, rejection.diagnostics());
            return 2;
        },
        .admitted => |invocation| switch (invocation) {
            .help => {
                try writeCliHelp(stdout);
                return 0;
            },
            .version => {
                try stdout.print("zi {s}\n", .{version});
                return 0;
            },
            .trust => |request| return runTrustInvocation(init, request, stdout, stderr),
            .auth => |request| return runAuthInvocation(init, request, stdout, stderr),
            .launch => |request| return runLaunchInvocation(
                init,
                &request,
                frontend,
                stdin_is_tty,
                stdout,
                stderr,
            ),
        },
    }
}

fn runTrustInvocation(
    init: std.process.Init,
    request: surface.TrustRequest,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("Unable to manage project trust: HOME is not set.\n");
        return 1;
    };
    return trust.run(request, .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .home = home,
        .stdout = stdout,
        .stderr = stderr,
    });
}

fn runAuthInvocation(
    init: std.process.Init,
    request: surface.AuthRequest,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("Unable to log in: HOME is not set.\n");
        return 1;
    };
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    return auth.run(request, .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .home = home,
        .input = &stdin_file.interface,
        .output = stdout,
        .error_output = stderr,
    });
}

fn runLaunchInvocation(
    init: std.process.Init,
    request: *const surface.LaunchRequest,
    frontend: interactive.Frontend,
    stdin_is_tty: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("Unable to start: HOME is not set.\n");
        return 1;
    };
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    var sources: launch.Sources = .{ .io = io };
    const context: launch.LaunchContext = .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .home = home,
        .openai_api_key = init.environ_map.get("OPENAI_API_KEY"),
        .sources = sources.view(),
        .stdin_is_tty = stdin_is_tty,
        .stdin = &stdin_file.interface,
        .stdout = stdout,
        .stderr = stderr,
    };
    const result = switch (request.mode) {
        .interactive => try interactive_launch.runInteractiveLaunch(request, context, frontend),
        .print => try launch.runPrintLaunch(request, context),
    };
    return @intFromEnum(result);
}

fn writeCliDiagnostics(writer: *std.Io.Writer, diagnostics: []const surface.Diagnostic) !void {
    for (diagnostics) |diagnostic| switch (diagnostic) {
        .too_many_arguments => try writer.writeAll("Too many command-line arguments.\n"),
        .arguments_too_large => try writer.writeAll("Command-line arguments exceed the size limit.\n"),
        .argument_too_large => |index| try writer.print("Argument {d} exceeds the size limit.\n", .{index}),
        .invalid_utf8 => |index| try writer.print("Argument {d} is not valid UTF-8.\n", .{index}),
        .missing_value => |option| try writer.print("{s} requires a value.\n", .{option}),
        .invalid_mode => |mode| try writer.print("Unsupported mode: {s}.\n", .{mode}),
        .unavailable_mode => |mode| switch (mode) {
            .json => try writer.writeAll("JSON mode is not available yet.\n"),
            .rpc => try writer.writeAll("RPC mode is not available yet.\n"),
        },
        .invalid_auth_command => |command| try writer.print("Unsupported auth command: {s}.\n", .{command}),
        .invalid_trust_command => |command| try writer.print("Unsupported trust command: {s}.\n", .{command}),
        .too_many_trust_arguments => try writer.writeAll("Trust commands accept at most one path.\n"),
        .conflicting_session_option => |option| try writer.print(
            "Session selection is already set; {s} cannot be combined with it.\n",
            .{option},
        ),
        .conflicting_project_trust_option => |option| try writer.print(
            "Project trust is already set; {s} cannot be combined with it.\n",
            .{option},
        ),
        .conflicting_system_prompt_option => |option| try writer.print(
            "System prompt customization is already set; {s} cannot be combined with it.\n",
            .{option},
        ),
        .too_many_file_inputs => try writer.writeAll("Print mode accepts at most one @file input.\n"),
        .unknown_option => |option| try writer.print("Unknown option: {s}.\n", .{option}),
    };
}

fn writeCliHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zi [PROMPT]
        \\  zi --provider PROVIDER --model MODEL [PROMPT]
        \\  zi (--continue | --session PATH) [PROMPT]
        \\  zi --print --provider PROVIDER --model MODEL [PROMPT]
        \\  zi --print (--continue | --session PATH) [PROMPT]
        \\  zi trust (status | allow | deny | remove) [PATH]
        \\  zi auth login PROVIDER [--device]
        \\
        \\Options:
        \\  -p, --print          Run prompts and print the final response
        \\                       Without --print, a terminal starts interactive mode
        \\  -c, --continue       Continue the most recent session for this directory
        \\  --session PATH       Continue an exact session journal
        \\  --provider VALUE     Select a provider
        \\  --model VALUE        Select a model
        \\  --api-key VALUE      Use an explicit API key
        \\  -a, --approve        Trust project prompt files for this launch
        \\  -na, --no-approve    Ignore project prompt files for this launch
        \\  --rules TEXT         Append session rules to the default system prompt
        \\  --system-prompt TEXT Replace the default system prompt
        \\  -h, --help           Show help
        \\  -v, --version        Show the version
        \\  auth login           Start the provider-owned OAuth login ceremony
        \\
        \\Interactive commands:
        \\  /login PROVIDER [--device]  Log in without leaving the TUI
        \\  /model PROVIDER/MODEL       Switch models while idle
        \\  Without an authenticated model, Zi opens a model-less session
        \\  Assistant prose and thinking render as ordered Markdown blocks
        \\  Running tools use the footer; completed tools append compact results
        \\
        \\Persistent project trust:
        \\  zi trust status [PATH]  Show the nearest saved decision
        \\  zi trust allow [PATH]   Save a trusted decision
        \\  zi trust deny [PATH]    Save an untrusted decision
        \\  zi trust remove [PATH]  Remove the exact saved decision
        \\
        \\Prompt files:
        \\  $HOME/.zi/agent/SYSTEM.md         Replace the composed prompt base
        \\  $HOME/.zi/agent/APPEND_SYSTEM.md  Append persistent rules
        \\  $CWD/.zi/SYSTEM.md                Replace the base when trusted
        \\  $CWD/.zi/APPEND_SYSTEM.md         Replace persistent rules when trusted
        \\
        \\Context files:
        \\  $HOME/.zi/agent/AGENTS.md         Add global coding instructions
        \\  Ancestor AGENTS.md or CLAUDE.md   Add broad-to-narrow project instructions
        \\
    );
}
