const std = @import("std");
const runtime = @import("../../runtime/root.zig");
const auth_mode = @import("../auth_mode.zig");
const args_mod = @import("args.zig");
const interactive = @import("../interactive.zig");
const print_mode = @import("../print_mode.zig");
const session_runtime = @import("../session_runtime.zig");
const session_listing = @import("../session_listing.zig");

const CliError = error{
    InvalidCliUsage,
    NoResumableSession,
    OutputClosed,
    UnsupportedCliFeature,
};

const stdout_buffer_size_bytes = 4096;
const stderr_buffer_size_bytes = 1024;

const CliIo = struct {
    stdout_buffer: [stdout_buffer_size_bytes]u8 = undefined,
    stderr_buffer: [stderr_buffer_size_bytes]u8 = undefined,
    stdout_file_writer: std.Io.File.Writer,
    stderr_file_writer: std.Io.File.Writer,

    fn init(self: *CliIo, io: std.Io) void {
        self.stdout_file_writer = .initStreaming(.stdout(), io, &self.stdout_buffer);
        self.stderr_file_writer = .initStreaming(.stderr(), io, &self.stderr_buffer);
    }

    fn stdout(self: *CliIo) *std.Io.Writer {
        return &self.stdout_file_writer.interface;
    }

    fn stderr(self: *CliIo) *std.Io.Writer {
        return &self.stderr_file_writer.interface;
    }

    fn flush(self: *CliIo) !void {
        try self.stdout().flush();
        try self.stderr().flush();
    }
};

pub fn main(process: runtime.Process, args_source: std.process.Args) !void {
    var cli_io: CliIo = undefined;
    cli_io.init(process.io);

    var args = try std.process.Args.Iterator.initAllocator(args_source, process.gpa);
    defer args.deinit();

    run(process, &args, cli_io.stdout(), cli_io.stderr()) catch |err| switch (err) {
        error.OutputClosed => return,
        error.InvalidCliUsage, error.NoResumableSession, error.UnsupportedCliFeature => {
            try cli_io.flush();
            std.process.exit(2);
        },
        else => |unexpected| {
            cli_io.flush() catch return unexpected;
            return unexpected;
        },
    };
    try cli_io.flush();
}

fn run(
    process: runtime.Process,
    args: *std.process.Args.Iterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    return runWithOptions(process, args, stdout, stderr, .{
        .cwd = ".",
        .agent_dir_override = null,
        .environ = process.environ,
    });
}

fn runWithOptions(
    process: runtime.Process,
    args: *std.process.Args.Iterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    auth_options: auth_mode.Options,
) !void {
    const command = args_mod.parseIterator(args) catch return usage(stderr);
    switch (command) {
        .auth => |auth| return runAuth(process, stdout, stderr, auth, auth_options),
        .app => |app| return runApp(process, stdout, stderr, app, auth_options),
    }
}

fn runAuth(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    command: anytype,
    options: auth_mode.Options,
) !void {
    return switch (command.action) {
        .login => auth_mode.login(
            process.gpa,
            process.io,
            process.zio_runtime,
            stdout,
            stderr,
            command.provider,
            options,
        ),
        .logout => auth_mode.logout(process.gpa, process.io, stdout, command.provider, options),
        .status => auth_mode.status(process.gpa, process.io, stdout, command.provider, options),
    };
}

fn runApp(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    app: anytype,
    options: auth_mode.Options,
) !void {
    if (app.help) return args_mod.writeHelp(stdout);
    if (app.unknown_flags.count > 0) return unknownFlag(stderr, app.unknown_flags.slice()[0].name);

    const stdin_is_tty = try std.Io.File.stdin().isTty(process.io);
    return switch (args_mod.resolveAppMode(app, stdin_is_tty)) {
        .text => {
            if (app.messages.count != 1) return usage(stderr);
            return runPrompt(process, stdout, stderr, app.messages.slice()[0], false, app, options);
        },
        .json => {
            if (app.messages.count != 1) return usage(stderr);
            return runPrompt(process, stdout, stderr, app.messages.slice()[0], true, app, options);
        },
        .rpc => unsupported(stderr, "rpc mode is not implemented yet"),
        .interactive => {
            if (app.messages.count > 1) return usage(stderr);
            return interactive.run(process, stdout, stderr, .{
                .cwd = options.cwd,
                .agent_dir_override = options.agent_dir_override,
                .dir = options.dir,
                .environ = options.environ,
                .resume_session_file = app.resume_session_file,
                .resume_latest = app.resume_latest,
                .initial_prompt = if (app.messages.count == 1) app.messages.slice()[0] else null,
            });
        },
    };
}

fn runPrompt(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    prompt: []const u8,
    json_output: bool,
    app_args: anytype,
    options: auth_mode.Options,
) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);

    var app = if (try selectResumeSession(process, stderr, app_args, options)) |session_file| blk: {
        defer process.gpa.free(session_file);
        break :blk try session_runtime.resumeSessionRuntime(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_file_name = session_file,
            .dir = options.dir,
            .environ = options.environ,
            .zio_runtime = process.zio_runtime,
        });
    } else blk: {
        const session_id = try std.fmt.allocPrint(process.gpa, "cli-{d}", .{timestamp});
        defer process.gpa.free(session_id);
        break :blk try session_runtime.createSessionRuntime(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_id = session_id,
            .timestamp = timestamp_text,
            .dir = options.dir,
            .environ = options.environ,
            .zio_runtime = process.zio_runtime,
        });
    };
    defer app.deinit();

    try print_mode.run(&app, stdout, stderr, .{
        .prompt = prompt,
        .output = if (json_output) .json else .text,
    });
}

fn selectResumeSession(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    app: anytype,
    options: auth_mode.Options,
) !?[]const u8 {
    if (app.resume_session_file == null and !app.resume_latest) return null;
    const selected = session_listing.selectRuntimeSession(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .explicit_file_name = app.resume_session_file,
    }) catch |err| switch (err) {
        error.InvalidSessionFileName => {
            try stderr.writeAll("invalid resume session file\n");
            return error.InvalidCliUsage;
        },
        error.SessionListTruncated => {
            try stderr.writeAll("too many sessions to choose latest safely\n");
            return error.InvalidCliUsage;
        },
        else => return err,
    };
    if (selected == null) {
        try stderr.writeAll("no resumable session found\n");
        return error.NoResumableSession;
    }
    return selected;
}

fn unsupported(stderr: *std.Io.Writer, message: []const u8) !void {
    try stderr.print("unsupported: {s}\n", .{message});
    try stderr.flush();
    return error.UnsupportedCliFeature;
}

fn unknownFlag(stderr: *std.Io.Writer, name: []const u8) !void {
    try stderr.print("unsupported: unknown extension flag --{s}\n", .{name});
    try stderr.flush();
    return error.UnsupportedCliFeature;
}

fn usage(stderr: *std.Io.Writer) !void {
    try args_mod.writeUsage(stderr);
    return error.InvalidCliUsage;
}

test "cli auth logout dispatches to auth mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data =
        \\{"openai-codex":{"type":"oauth","refresh":"refresh-token","access":"access-token","expires":123}}
        ,
    });

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const process = testProcess(zio_runtime, &environ);
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var argv = [_:null]?[*:0]const u8{ "zi", "auth", "logout", "openai-codex" };
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&argv) }, std.testing.allocator);
    defer args.deinit();

    try runWithOptions(process, &args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });

    try std.testing.expectEqualStrings("logged out openai-codex\n", output.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "cli auth status dispatches to auth mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data =
        \\{"openai-codex":{"type":"oauth","refresh":"refresh-token","access":"access-token","expires":123}}
        ,
    });

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const process = testProcess(zio_runtime, &environ);
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var argv = [_:null]?[*:0]const u8{ "zi", "auth", "status", "openai-codex" };
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&argv) }, std.testing.allocator);
    defer args.deinit();

    try runWithOptions(process, &args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });

    try std.testing.expectEqualStrings("openai-codex: authenticated\n", output.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "cli selects newest resumable session through runtime policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const process = testProcess(zio_runtime, &environ);

    try createCliStoredSession(tmp.dir, "first", "2026-05-27T00:00:00Z");
    try createCliStoredSession(tmp.dir, "second", "2026-05-28T00:00:00Z");

    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const app = (try args_mod.parse(&.{"--resume-latest"})).app;
    const selected = (try selectResumeSession(process, &stderr, app, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-28T00:00:00Z_second.jsonl", selected);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "cli selects explicit resumable session through runtime policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const process = testProcess(zio_runtime, &environ);

    try createCliStoredSession(tmp.dir, "session", "2026-05-27T00:00:00Z");

    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const app = (try args_mod.parse(&.{ "--resume", "2026-05-27T00:00:00Z_session.jsonl" })).app;
    const selected = (try selectResumeSession(process, &stderr, app, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_session.jsonl", selected);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "cli reports absent resumable session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const process = testProcess(zio_runtime, &environ);
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const app = (try args_mod.parse(&.{"--resume-latest"})).app;

    try std.testing.expectError(error.NoResumableSession, selectResumeSession(process, &stderr, app, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    }));
    try std.testing.expectEqualStrings("no resumable session found\n", stderr.buffered());
}

test "cli reports invalid explicit resume session file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const process = testProcess(zio_runtime, &environ);
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const app = (try args_mod.parse(&.{ "--resume", "../outside.jsonl" })).app;

    try std.testing.expectError(error.InvalidCliUsage, selectResumeSession(process, &stderr, app, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    }));
    try std.testing.expectEqualStrings("invalid resume session file\n", stderr.buffered());
}

test "cli usage returns an error instead of exiting" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const process = testProcess(zio_runtime, &environ);
    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var argv = [_:null]?[*:0]const u8{"zi"};
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&argv) }, std.testing.allocator);
    defer args.deinit();

    try std.testing.expectError(error.InvalidCliUsage, run(process, &args, &output, &stderr));
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expect(std.mem.startsWith(u8, stderr.buffered(), "usage: zi [options] [prompt]"));
}

fn testProcess(zio_runtime: *runtime.Runtime, environ: *std.process.Environ.Map) runtime.Process {
    return .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .zio_runtime = zio_runtime,
        .environ = environ,
    };
}

fn createCliTestDirs(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "agent");
    try dir.createDirPath(std.testing.io, "repo");
}

fn createCliStoredSession(dir: std.Io.Dir, session_id: []const u8, timestamp: []const u8) !void {
    var app_runtime = try session_runtime.createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .session_id = session_id,
        .timestamp = timestamp,
        .dir = dir,
    });
    defer app_runtime.deinit();
}
