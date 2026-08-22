const std = @import("std");
const ai = @import("../../ai/root.zig");
const RuntimeServices = @import("../RuntimeServices.zig");
const SystemPrompt = @import("../SystemPrompt.zig");
const SessionFormat = @import("../SessionFormat.zig");
const initial_message = @import("initial_message.zig");
const print_mode = @import("print_mode.zig");
const surface = @import("surface.zig");

const max_input_bytes = 8 * 1024 * 1024;

/// Process-owned inputs shared by admitted launch modes.
pub const LaunchContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    openai_api_key: ?[]const u8,
    sources: SessionFormat.Sources,
    stdin_is_tty: bool,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub const Sources = struct {
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

    pub fn view(self: *Sources) SessionFormat.Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

pub const PreparedInitial = struct {
    allocator: std.mem.Allocator,
    stdin_content: ?[]u8,
    file_content: ?[]u8,
    value: initial_message.InitialMessage,

    pub fn deinit(self: *PreparedInitial) void {
        self.value.deinit();
        if (self.file_content) |content| self.allocator.free(content);
        if (self.stdin_content) |content| self.allocator.free(content);
        self.* = undefined;
    }
};

pub fn prepareInitial(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
    include_piped_stdin: bool,
) !?PreparedInitial {
    const stdin_content = if (include_piped_stdin and !context.stdin_is_tty)
        try context.stdin.allocRemaining(context.allocator, .limited(max_input_bytes))
    else
        null;
    const file_content = if (request.file_path) |path|
        std.Io.Dir.cwd().readFileAlloc(
            context.io,
            path,
            context.allocator,
            .limited(max_input_bytes),
        ) catch |failure| {
            if (stdin_content) |content| context.allocator.free(content);
            try context.stderr.print("Unable to read {s}: {s}.\n", .{ path, @errorName(failure) });
            return null;
        }
    else
        null;
    const initial = initial_message.buildInitialMessage(
        context.allocator,
        request.messages(),
        stdin_content,
        file_content,
    ) catch |failure| {
        if (file_content) |content| context.allocator.free(content);
        if (stdin_content) |content| context.allocator.free(content);
        try context.stderr.print("Unable to compose the prompt: {s}.\n", .{@errorName(failure)});
        return null;
    };
    return .{
        .allocator = context.allocator,
        .stdin_content = stdin_content,
        .file_content = file_content,
        .value = initial,
    };
}

/// Creates one runtime or reports an expected launch failure to stderr.
pub fn createRuntime(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
) !?*RuntimeServices {
    var environment_entries: [1]ai.auth.EnvironmentEntry = undefined;
    const environment_count: usize = if (context.openai_api_key) |key| count: {
        environment_entries[0] = .{ .name = "OPENAI_API_KEY", .value = key };
        break :count 1;
    } else 0;
    var prompt_rules: [1][]const u8 = undefined;
    const prompt_policy: SystemPrompt.Policy = switch (request.system_prompt) {
        .default => .{ .composed = .{} },
        .append => |value| policy: {
            prompt_rules[0] = value;
            break :policy .{ .composed = .{ .rules = &prompt_rules } };
        },
        .replace => |value| .{ .verbatim = value },
    };
    return RuntimeServices.create(context.allocator, context.io, .{
        .startup_cwd = context.cwd,
        .home = context.home,
        .session = switch (request.session) {
            .new => .new,
            .continue_recent => .continue_recent,
            .open => |path| .{ .open = path },
        },
        .sources = context.sources,
        .requested_provider = request.provider,
        .requested_model = request.model,
        .cli_api_key = request.api_key,
        .project_trust = request.project_trust,
        .environment = .{ .entries = environment_entries[0..environment_count] },
        .options = .{ .prompt = .{ .policy = prompt_policy } },
    }) catch |failure| {
        if (failure == error.SelectionRequired) {
            try context.stderr.writeAll(
                "No model is available. Run `zi auth login PROVIDER` or pass --provider and --model.\n",
            );
        } else {
            try context.stderr.print("Unable to start the coding agent: {s}.\n", .{@errorName(failure)});
        }
        return null;
    };
}

pub fn createInteractiveRuntime(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
) !?RuntimeServices.Interactive {
    var environment_entries: [1]ai.auth.EnvironmentEntry = undefined;
    const environment_count: usize = if (context.openai_api_key) |key| count: {
        environment_entries[0] = .{ .name = "OPENAI_API_KEY", .value = key };
        break :count 1;
    } else 0;
    var prompt_rules: [1][]const u8 = undefined;
    const prompt_policy: SystemPrompt.Policy = switch (request.system_prompt) {
        .default => .{ .composed = .{} },
        .append => |value| policy: {
            prompt_rules[0] = value;
            break :policy .{ .composed = .{ .rules = &prompt_rules } };
        },
        .replace => |value| .{ .verbatim = value },
    };
    return RuntimeServices.createInteractive(context.allocator, context.io, .{
        .startup_cwd = context.cwd,
        .home = context.home,
        .session = switch (request.session) {
            .new => .new,
            .continue_recent => .continue_recent,
            .open => |path| .{ .open = path },
        },
        .sources = context.sources,
        .requested_provider = request.provider,
        .requested_model = request.model,
        .cli_api_key = request.api_key,
        .project_trust = request.project_trust,
        .environment = .{ .entries = environment_entries[0..environment_count] },
        .options = .{ .prompt = .{ .policy = prompt_policy } },
    }) catch |failure| {
        try context.stderr.print("Unable to start the coding agent: {s}.\n", .{@errorName(failure)});
        return null;
    };
}

/// Runs one admitted print launch and maps expected failures to process output.
pub fn runPrintLaunch(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
) !print_mode.ExitCode {
    var prepared = (try prepareInitial(request, context, true)) orelse return .failure;
    defer prepared.deinit();
    var runtime = (try createRuntime(request, context)) orelse return .failure;
    defer runtime.deinit();
    return print_mode.runPrintMode(
        runtime.session(),
        .{
            .initial_message = prepared.value.text,
            .messages = prepared.value.remaining_messages,
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
            var sources: Sources = .{ .io = std.testing.io };
            return runPrintLaunch(request, .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
                .cwd = root_path,
                .home = root_path,
                .openai_api_key = null,
                .sources = sources.view(),
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
