const std = @import("std");
const ai = @import("../../ai/root.zig");
const RuntimeServices = @import("../RuntimeServices.zig");
const SessionFormat = @import("../SessionFormat.zig");
const ZiPaths = @import("../ZiPaths.zig");
const args_api = @import("args.zig");
const auth_command = @import("auth_command.zig");
const initial_message = @import("initial_message.zig");
const print_mode = @import("print_mode.zig");

const max_stdin_bytes = 8 * 1024 * 1024;
const version = "0.1.0";

const Sources = struct {
    io: std.Io,

    fn nextId(context: *anyopaque) [16]u8 {
        const self: *Sources = @ptrCast(@alignCast(context));
        var value: [16]u8 = undefined;
        self.io.random(&value);
        return value;
    }

    fn nowMs(context: *anyopaque) u64 {
        const self: *Sources = @ptrCast(@alignCast(context));
        const value = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        return if (value > 0) @intCast(value) else 0;
    }

    fn view(self: *Sources) SessionFormat.Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

pub fn run(init: std.process.Init) !u8 {
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
    var parsed = try args_api.parseArgs(allocator, arguments.items);
    defer parsed.deinit();
    if (parsed.hasErrors()) {
        try writeDiagnostics(stderr, parsed.diagnostics);
        return 2;
    }
    if (parsed.help) {
        try writeHelp(stdout);
        return 0;
    }
    if (parsed.version) {
        try stdout.print("zi {s}\n", .{version});
        return 0;
    }

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("Unable to start: HOME is not set.\n");
        return 1;
    };
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    const stdin = &stdin_file.interface;

    if (parsed.auth) |command| {
        var paths = ZiPaths.init(allocator, cwd, home) catch |failure| {
            try stderr.print("Unable to resolve credential paths: {s}.\n", .{@errorName(failure)});
            return 1;
        };
        defer paths.deinit();
        const result = try auth_command.run(
            allocator,
            io,
            &paths,
            command,
            stdin,
            stdout,
            stderr,
            currentTimeMs(io),
        );
        return @intFromEnum(result);
    }

    const stdin_is_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_is_tty = std.Io.File.stdout().isTty(io) catch false;
    const mode = args_api.resolveAppMode(&parsed, stdin_is_tty, stdout_is_tty);
    if (mode != .print) {
        try stderr.writeAll("Interactive, JSON, and RPC modes are not available yet. Use --print.\n");
        return 2;
    }
    if (parsed.file_args.len > 1) {
        try stderr.writeAll("Print mode accepts at most one @file input.\n");
        return 2;
    }
    const stdin_content = if (stdin_is_tty)
        null
    else
        try stdin.allocRemaining(allocator, .limited(max_stdin_bytes));
    defer if (stdin_content) |content| allocator.free(content);
    const file_content = if (parsed.file_args.len == 1)
        std.Io.Dir.cwd().readFileAlloc(
            io,
            parsed.file_args[0],
            allocator,
            .limited(max_stdin_bytes),
        ) catch |failure| {
            try stderr.print("Unable to read {s}: {s}.\n", .{ parsed.file_args[0], @errorName(failure) });
            return 1;
        }
    else
        null;
    defer if (file_content) |content| allocator.free(content);
    var initial = initial_message.buildInitialMessage(
        allocator,
        parsed.messages,
        stdin_content,
        file_content,
    ) catch |failure| {
        try stderr.print("Unable to compose the prompt: {s}.\n", .{@errorName(failure)});
        return 2;
    };
    defer initial.deinit();

    var environment_entries: [1]ai.auth.EnvironmentEntry = undefined;
    const environment_count: usize = if (init.environ_map.get("OPENAI_API_KEY")) |key| count: {
        environment_entries[0] = .{ .name = "OPENAI_API_KEY", .value = key };
        break :count 1;
    } else 0;
    var sources: Sources = .{ .io = io };
    var runtime = RuntimeServices.create(allocator, io, .{
        .startup_cwd = cwd,
        .home = home,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = parsed.provider,
        .requested_model = parsed.model,
        .cli_api_key = parsed.api_key,
        .environment = .{ .entries = environment_entries[0..environment_count] },
    }) catch |failure| {
        try stderr.print("Unable to start the coding agent: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    defer runtime.deinit();
    const exit = try print_mode.runPrintMode(
        runtime.session(),
        .{
            .initial_message = initial.text,
            .messages = initial.remaining_messages,
        },
        stdout,
        stderr,
    );
    return @intFromEnum(exit);
}

fn currentTimeMs(io: std.Io) u64 {
    const value = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return if (value > 0) @intCast(value) else 0;
}

fn writeDiagnostics(writer: *std.Io.Writer, diagnostics: []const args_api.Diagnostic) !void {
    for (diagnostics) |diagnostic| switch (diagnostic.detail) {
        .too_many_arguments => try writer.writeAll("Too many command-line arguments.\n"),
        .arguments_too_large => try writer.writeAll("Command-line arguments exceed the size limit.\n"),
        .argument_too_large => |index| try writer.print("Argument {d} exceeds the size limit.\n", .{index}),
        .invalid_utf8 => |index| try writer.print("Argument {d} is not valid UTF-8.\n", .{index}),
        .missing_value => |option| try writer.print("{s} requires a value.\n", .{option}),
        .invalid_mode => |mode| try writer.print("Unsupported mode: {s}.\n", .{mode}),
        .invalid_auth_command => |command| try writer.print("Unsupported auth command: {s}.\n", .{command}),
        .invalid_auth_method => |method| try writer.print("Unsupported login method: {s}.\n", .{method}),
        .unknown_option => |option| try writer.print("Unknown option: {s}.\n", .{option}),
    };
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zi --print --provider PROVIDER --model MODEL [PROMPT]
        \\  zi auth login [PROVIDER] [--method browser|device-code]
        \\  zi auth logout [PROVIDER]
        \\
        \\Options:
        \\  -p, --print          Run prompts and print the final response
        \\  --provider VALUE     Select a provider
        \\  --model VALUE        Select a model
        \\  --api-key VALUE      Use an explicit API key
        \\  -h, --help           Show help
        \\  -v, --version        Show the version
        \\
    );
}
