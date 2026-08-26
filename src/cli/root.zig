const std = @import("std");

const version = "0.1.0-dev";

pub const Args = @import("Args.zig");
pub const CodexFiles = @import("CodexFiles.zig");
pub const ProcessAdapters = @import("ProcessAdapters.zig");
pub const ProcessFacts = @import("ProcessFacts.zig");
pub const OneShot = @import("OneShot.zig");
pub const Interactive = @import("Interactive.zig");
pub const PrintRun = @import("PrintRun.zig");
pub const SessionStartup = @import("SessionStartup.zig");
pub const StartupConfig = @import("StartupConfig.zig");
pub const LocalStartup = @import("LocalStartup.zig");
pub const Stats = @import("Stats.zig");
pub const SubagentDepth = @import("SubagentDepth.zig");

fn collectArguments(
    allocator: std.mem.Allocator,
    iterator: anytype,
) error{OutOfMemory}!std.ArrayList([]const u8) {
    var arguments: std.ArrayList([]const u8) = .empty;
    errdefer arguments.deinit(allocator);
    while (arguments.items.len < Args.max_arguments + 1) {
        const argument = iterator.next() orelse break;
        try arguments.append(allocator, argument);
    }
    return arguments;
}

/// Owns process argument adaptation, bounded stdin, output, and exit mapping.
pub fn run(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.next();

    var arguments = try collectArguments(allocator, &iterator);
    defer arguments.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.Writer.init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    // Register stdout last so LIFO cleanup flushes answers before diagnostics.
    defer stdout.flush() catch {};

    const parsed = Args.parse(arguments.items);
    const options = switch (parsed) {
        .options => |value| value,
        .err => |problem| {
            try stderr.writeAll("zi: ");
            try problem.render(stderr);
            try stderr.writeByte('\n');
            return 1;
        },
    };
    switch (options.action) {
        .help => {
            try writeHelp(stdout);
            return 0;
        },
        .version => {
            try stdout.print("zi {s}\n", .{version});
            return 0;
        },
        .run => {},
    }
    var environment = ProcessAdapters.Environment.fromProcess(init);
    const parent_subagent_depth = SubagentDepth.checkEnvironment(&environment) catch {
        try stderr.print("zi: {s}\n", .{SubagentDepth.diagnostic});
        return 1;
    };
    var stdin_result: ?ProcessAdapters.StdinResult = null;
    defer if (stdin_result) |*value| value.deinit(allocator);
    var prompt: ?Args.OwnedPrompt = null;
    defer if (prompt) |*value| value.deinit(allocator);

    const mode: PrintRun.Mode = switch (options.mode) {
        .interactive => .interactive,
        .print => mode: {
            const stdin_is_tty = ProcessAdapters.isTty(init.io, .stdin());
            if (options.prompt_fragment_count == 0 and !stdin_is_tty) {
                stdin_result = ProcessAdapters.readStdin(allocator, init.io, Args.max_prompt_bytes) catch |err| {
                    try stderr.print("zi: could not read prompt from stdin: {s}\n", .{@errorName(err)});
                    return 1;
                };
            }
            const chosen = try Args.choosePrompt(allocator, &options, .{
                .stdin_is_tty = stdin_is_tty,
                .bytes = if (stdin_result) |value| value.bytes else "",
            });
            prompt = switch (chosen) {
                .none => null,
                .prompt => |value| value,
                .err => |problem| {
                    try stderr.writeAll(switch (problem) {
                        .missing => "zi: -p / --print requires a prompt argument or piped stdin\n",
                        .empty => "zi: prompt is empty\n",
                        .too_large => "zi: prompt exceeds the 1048576-byte limit\n",
                    });
                    return 1;
                },
            };
            break :mode .{ .print = prompt.?.bytes };
        },
    };

    const exit_code = PrintRun.run(init, &options, mode, parent_subagent_depth, stdout, stderr) catch |err|
        return reportRunError(stdout, stderr, err);
    try stdout.flush();
    try stderr.flush();
    return exit_code;
}

fn reportRunError(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    err: anyerror,
) std.Io.Writer.Error!u8 {
    // hax preserves the answer when terminal cleanup fails. A flush failure is
    // already superseded by the original run error, so it is deliberately ignored.
    stdout.flush() catch |flush_error| ignoreFlushFailure(flush_error);
    try stderr.print("zi: {s}\n", .{friendlyError(err)});
    return errorExitCode(err);
}

fn ignoreFlushFailure(err: std.Io.Writer.Error) void {
    switch (err) {
        error.WriteFailed => return,
    }
}

fn errorExitCode(_: anyerror) u8 {
    return 1;
}

fn friendlyError(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCredential => "the selected provider needs an API key",
        error.MissingProvider => "no provider is configured",
        error.MissingModel => "no model is configured for the selected provider",
        error.UnknownProvider => "unknown provider",
        error.ProviderUnavailable => "the selected provider is unavailable in this build",
        error.AdapterUnavailable => "the selected provider adapter is not implemented",
        error.InvalidAuth => "the selected provider credentials are invalid",
        error.SecretTooLong => "a configured provider secret is too long",
        error.InvalidHeaderValue => "a configured provider header value is invalid",
        error.TooManyRules => "too many provider routing rules are configured",
        error.InvalidRule => "a provider routing rule is invalid",
        error.MissingSessionCacheKey => "the selected provider needs a valid session cache key",
        error.InvalidPath, error.InvalidStateRoot => "a configured path is invalid",
        error.PathTooLong => "a configured path is too long",
        error.TooManyPresets => "too many presets are configured",
        error.TooManyDefinitions => "too many providers are configured",
        error.TooManyWarnings => "too many configuration warnings",
        error.RetainedDataTooLarge,
        error.WarningDataTooLarge,
        error.TooLarge,
        => "configuration data exceeds a safe limit",
        error.Invalid => "configuration is invalid",
        error.OutOfMemory => "out of memory",
        error.InvalidPlan => "catalog metadata is incompatible with the selected provider",
        error.CurlGlobalInitFailed, error.UnsupportedRuntime => "HTTP transport is unavailable",
        else => @errorName(err),
    };
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zi [OPTIONS]
        \\       zi --print [OPTIONS] [PROMPT...]
        \\
        \\A terminal-native coding agent.
        \\
        \\Options:
        \\  -p, --print          Run PROMPT once and print the final answer
        \\  -c, --continue       Resume the latest session in this directory
        \\      --resume[=ID]    Resume a session (ID is required with --print)
        \\      --no-session     Do not record this conversation
        \\      --raw            Send only the prompt; disable context and tools
        \\      --bare           Disable project, skill, and delegation context
        \\      --provider NAME  Select a provider
        \\      --model ID       Select a model
        \\      --effort LEVEL   Select reasoning effort
        \\      --preset NAME    Apply a named preset
        \\  -h, --help           Show this help
        \\  -v, --version        Show the version
        \\
        \\Without --print, Zi reads repeated bounded prompts and exits on EOF.
        \\PROMPT fragments are joined with spaces. Without fragments, --print reads
        \\bounded input from stdin when stdin is not a terminal.
        \\
    );
}

test {
    _ = Args;
    _ = CodexFiles;
    _ = ProcessAdapters;
    _ = ProcessFacts;
    _ = OneShot;
    _ = Interactive;
    _ = PrintRun;
    _ = SessionStartup;
    _ = StartupConfig;
    _ = LocalStartup;
    _ = Stats;
    _ = SubagentDepth;
}

test "help documents the production one-shot flags" {
    var storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeHelp(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--provider NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--raw") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--resume[=ID]") != null);
}

test "run failure keeps an already written answer before its diagnostic" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.writeAll("answer\n");
    try std.testing.expectEqual(@as(u8, 1), try reportRunError(
        &output.writer,
        &output.writer,
        error.Failed,
    ));
    try std.testing.expectEqualStrings("answer\nzi: Failed\n", output.written());
}

test {
    _ = @import("DiagnosticText.zig");
}

test "argument collector retains one bounded overflow witness and stops" {
    const Iterator = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn next(self: *Self) ?[]const u8 {
            self.calls += 1;
            return "x";
        }
    };

    var iterator: Iterator = .{};
    var arguments = try collectArguments(std.testing.allocator, &iterator);
    defer arguments.deinit(std.testing.allocator);
    try std.testing.expectEqual(Args.max_arguments + 1, arguments.items.len);
    try std.testing.expectEqual(Args.max_arguments + 1, iterator.calls);
    switch (Args.parse(arguments.items)) {
        .err => |problem| try std.testing.expectEqual(Args.ParseErrorKind.too_many_arguments, problem.kind),
        .options => return error.TestUnexpectedResult,
    }
}
