const std = @import("std");
const runtime = @import("../../runtime/root.zig");
const auth_mode = @import("../auth_mode.zig");
const args_mod = @import("args.zig");
const print_mode = @import("../print_mode.zig");
const sdk = @import("../sdk.zig");
const tui_mode = @import("../tui_mode.zig");

pub const parser = args_mod;
pub const Command = args_mod.Command;
pub const AppArgs = args_mod.AppArgs;
pub const AuthCommand = args_mod.AuthCommand;

pub const CliError = error{
    InvalidCliUsage,
    NoResumableSession,
    OutputClosed,
    UnsupportedCliFeature,
};

pub fn main(process: runtime.Process, args_source: std.process.Args) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), process.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), process.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(args_source, process.gpa);
    defer args.deinit();

    run(process, &args, stdout, stderr) catch |err| switch (err) {
        error.OutputClosed => return,
        error.InvalidCliUsage, error.NoResumableSession, error.UnsupportedCliFeature => {
            try flushOutputs(stdout, stderr);
            std.process.exit(2);
        },
        else => |unexpected| {
            flushOutputs(stdout, stderr) catch return unexpected;
            return unexpected;
        },
    };
    try flushOutputs(stdout, stderr);
}

pub fn run(
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
    command: args_mod.AuthCommand,
    options: auth_mode.Options,
) !void {
    return switch (command.action) {
        .login => auth_mode.login(process.gpa, process.io, stdout, stderr, command.provider, options),
        .logout => auth_mode.logout(process.gpa, process.io, stdout, command.provider, options),
        .status => auth_mode.status(process.gpa, process.io, stdout, command.provider, options),
    };
}

fn runApp(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    app: args_mod.AppArgs,
    options: auth_mode.Options,
) !void {
    if (app.help) return args_mod.writeHelp(stdout);
    if (app.unknown_flags.count > 0) return unknownFlag(stderr, app.unknown_flags.slice()[0].name);

    const stdin_is_tty = try std.Io.File.stdin().isTty(process.io);
    return switch (args_mod.resolveAppMode(app, stdin_is_tty)) {
        .text => {
            if (app.messages.count != 1) return usage(stderr);
            return runPrompt(process, stdout, stderr, app.messages.slice()[0], .text, app, options);
        },
        .json => {
            if (app.messages.count != 1) return usage(stderr);
            return runPrompt(process, stdout, stderr, app.messages.slice()[0], .json, app, options);
        },
        .rpc => unsupported(stderr, "rpc mode is not implemented yet"),
        .interactive => {
            if (app.messages.count > 1) return usage(stderr);
            const initial_prompt = if (app.messages.count == 1) app.messages.slice()[0] else null;
            const resume_session_file = try selectResumeSession(process, stderr, app, options);
            defer if (resume_session_file) |file_name| process.gpa.free(file_name);
            return tui_mode.run(process, options, .{
                .initial_prompt = initial_prompt,
                .resume_session_file = resume_session_file,
            });
        },
    };
}

fn runPrompt(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    prompt: []const u8,
    output: print_mode.OutputMode,
    app_args: args_mod.AppArgs,
    options: auth_mode.Options,
) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);

    var app = if (try selectResumeSession(process, stderr, app_args, options)) |session_file| blk: {
        defer process.gpa.free(session_file);
        break :blk try sdk.resumeRuntimeHost(process.gpa, process.io, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_file_name = session_file,
            .dir = options.dir,
            .environ = options.environ,
        });
    } else blk: {
        const session_id = try std.fmt.allocPrint(process.gpa, "cli-{d}", .{timestamp});
        defer process.gpa.free(session_id);
        break :blk try sdk.createRuntimeHost(process.gpa, process.io, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_id = session_id,
            .timestamp = timestamp_text,
            .dir = options.dir,
            .environ = options.environ,
        });
    };
    defer app.deinit();

    try print_mode.run(&app.host, stdout, stderr, .{ .prompt = prompt, .output = output });
}

fn selectResumeSession(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    app: args_mod.AppArgs,
    options: auth_mode.Options,
) !?[]const u8 {
    if (app.resume_session_file == null and !app.resume_latest) return null;
    const selected = sdk.selectRuntimeSession(process.gpa, process.io, .{
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

fn flushOutputs(stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    try stdout.flush();
    try stderr.flush();
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
    const process = testProcess(&environ);
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
    const process = testProcess(&environ);
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

test "cli selects newest resumable session through sdk policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process = testProcess(&environ);

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

test "cli selects explicit resumable session through sdk policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process = testProcess(&environ);

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
    const process = testProcess(&environ);
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
    const process = testProcess(&environ);
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
    const process = testProcess(&environ);
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

fn testProcess(environ: *std.process.Environ.Map) runtime.Process {
    return .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
    };
}

fn createCliTestDirs(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "agent");
    try dir.createDirPath(std.testing.io, "repo");
}

fn createCliStoredSession(dir: std.Io.Dir, session_id: []const u8, timestamp: []const u8) !void {
    var app_runtime = try sdk.createRuntimeHost(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-05-27",
        .session_id = session_id,
        .timestamp = timestamp,
        .dir = dir,
    });
    defer app_runtime.deinit();
}
