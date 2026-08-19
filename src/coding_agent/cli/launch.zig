const std = @import("std");
const ai = @import("../../ai/root.zig");
const RuntimeServices = @import("../RuntimeServices.zig");
const SystemPrompt = @import("../SystemPrompt.zig");
const SessionFormat = @import("../SessionFormat.zig");
const initial_message = @import("initial_message.zig");
const print_mode = @import("print_mode.zig");
const surface = @import("surface.zig");

const max_input_bytes = 8 * 1024 * 1024;

/// Process-owned inputs required for one synchronous print launch.
pub const PrintLaunchContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    openai_api_key: ?[]const u8,
    stdin_is_tty: bool,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

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

/// Runs one admitted print launch and maps expected failures to process output.
pub fn runPrintLaunch(
    request: *const surface.LaunchRequest,
    context: PrintLaunchContext,
) !print_mode.ExitCode {
    const stdin_content = if (context.stdin_is_tty)
        null
    else
        try context.stdin.allocRemaining(context.allocator, .limited(max_input_bytes));
    defer if (stdin_content) |content| context.allocator.free(content);
    const file_content = if (request.file_path) |path|
        std.Io.Dir.cwd().readFileAlloc(
            context.io,
            path,
            context.allocator,
            .limited(max_input_bytes),
        ) catch |failure| {
            try context.stderr.print("Unable to read {s}: {s}.\n", .{ path, @errorName(failure) });
            return .failure;
        }
    else
        null;
    defer if (file_content) |content| context.allocator.free(content);
    var initial = initial_message.buildInitialMessage(
        context.allocator,
        request.messages(),
        stdin_content,
        file_content,
    ) catch |failure| {
        try context.stderr.print("Unable to compose the prompt: {s}.\n", .{@errorName(failure)});
        return .failure;
    };
    defer initial.deinit();

    var environment_entries: [1]ai.auth.EnvironmentEntry = undefined;
    const environment_count: usize = if (context.openai_api_key) |key| count: {
        environment_entries[0] = .{ .name = "OPENAI_API_KEY", .value = key };
        break :count 1;
    } else 0;
    var prompt_appends: [1][]const u8 = undefined;
    const prompt_policy: SystemPrompt.Policy = switch (request.system_prompt) {
        .default => .{ .composed = .{} },
        .append => |value| policy: {
            prompt_appends[0] = value;
            break :policy .{ .composed = .{ .appends = &prompt_appends } };
        },
        .replace => |value| .{ .verbatim = value },
    };
    var sources: Sources = .{ .io = context.io };
    var runtime = RuntimeServices.create(context.allocator, context.io, .{
        .startup_cwd = context.cwd,
        .home = context.home,
        .session = switch (request.session) {
            .new => .new,
            .continue_recent => .continue_recent,
            .open => |path| .{ .open = path },
        },
        .sources = sources.view(),
        .requested_provider = request.provider,
        .requested_model = request.model,
        .cli_api_key = request.api_key,
        .environment = .{ .entries = environment_entries[0..environment_count] },
        .options = .{ .prompt = .{ .policy = prompt_policy } },
    }) catch |failure| {
        try context.stderr.print("Unable to start the coding agent: {s}.\n", .{@errorName(failure)});
        return .failure;
    };
    defer runtime.deinit();
    return print_mode.runPrintMode(
        runtime.session(),
        .{
            .initial_message = initial.text,
            .messages = initial.remaining_messages,
        },
        context.stdout,
        context.stderr,
    );
}

test "print launch reopens recent and exact sessions with their restored model" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const Fixture = struct {
        fn run(
            request: *const surface.LaunchRequest,
            root_path: []const u8,
            stdout_writer: *std.Io.Writer,
            stderr_writer: *std.Io.Writer,
        ) !print_mode.ExitCode {
            var stdin = std.Io.Reader.fixed("");
            return runPrintLaunch(request, .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
                .cwd = root_path,
                .home = root_path,
                .openai_api_key = null,
                .stdin_is_tty = true,
                .stdin = &stdin,
                .stdout = stdout_writer,
                .stderr = stderr_writer,
            });
        }
    };

    const created: surface.LaunchRequest = .{
        .provider = "openai",
        .model = "gpt-5.6-sol",
        .api_key = "test-secret",
    };
    try std.testing.expect(try Fixture.run(&created, root, &stdout.writer, &stderr.writer) == .success);

    var sessions = try temporary.dir.openDir(std.testing.io, ".zi/agent/sessions", .{ .iterate = true });
    defer sessions.close(std.testing.io);
    var iterator = sessions.iterateAssumeFirstIteration();
    const entry = (try iterator.next(std.testing.io)).?;
    const session_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, ".zi/agent/sessions", entry.name });
    defer std.testing.allocator.free(session_path);
    try std.testing.expect(try iterator.next(std.testing.io) == null);

    const recent: surface.LaunchRequest = .{
        .session = .continue_recent,
        .api_key = "test-secret",
    };
    try std.testing.expect(try Fixture.run(&recent, root, &stdout.writer, &stderr.writer) == .success);

    const exact: surface.LaunchRequest = .{
        .session = .{ .open = session_path },
        .api_key = "test-secret",
    };
    try std.testing.expect(try Fixture.run(&exact, root, &stdout.writer, &stderr.writer) == .success);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());

    var verify = try temporary.dir.openDir(std.testing.io, ".zi/agent/sessions", .{ .iterate = true });
    defer verify.close(std.testing.io);
    var verify_iterator = verify.iterateAssumeFirstIteration();
    try std.testing.expect(try verify_iterator.next(std.testing.io) != null);
    try std.testing.expect(try verify_iterator.next(std.testing.io) == null);
}
