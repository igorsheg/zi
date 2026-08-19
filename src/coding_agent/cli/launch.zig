const std = @import("std");
const ai = @import("../../ai/root.zig");
const RuntimeServices = @import("../RuntimeServices.zig");
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
    var sources: Sources = .{ .io = context.io };
    var runtime = RuntimeServices.create(context.allocator, context.io, .{
        .startup_cwd = context.cwd,
        .home = context.home,
        .session = .new,
        .sources = sources.view(),
        .requested_provider = request.provider,
        .requested_model = request.model,
        .cli_api_key = request.api_key,
        .environment = .{ .entries = environment_entries[0..environment_count] },
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
