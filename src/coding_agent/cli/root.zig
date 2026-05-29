const std = @import("std");
const runtime = @import("../../runtime/root.zig");
const auth_mode = @import("../auth_mode.zig");
const args_mod = @import("args.zig");
const print_mode = @import("../print_mode.zig");
const sdk = @import("../sdk.zig");

pub const parser = args_mod;
pub const Command = args_mod.Command;
pub const AppArgs = args_mod.AppArgs;
pub const AuthCommand = args_mod.AuthCommand;

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
    if (app.messages.count != 1) return usage(stderr);

    const stdin_is_tty = try std.Io.File.stdin().isTty(process.io);
    return switch (args_mod.resolveAppMode(app, stdin_is_tty)) {
        .print => runPrompt(process, stdout, stderr, app.messages.slice()[0], options),
        .interactive => unsupported(stderr, "interactive mode is not implemented yet; use -p/--print"),
    };
}

fn runPrompt(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    prompt: []const u8,
    options: auth_mode.Options,
) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);
    const session_id = try std.fmt.allocPrint(process.gpa, "cli-{d}", .{timestamp});
    defer process.gpa.free(session_id);

    var app = try sdk.createRuntimeHost(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .current_date = timestamp_text,
        .session_id = session_id,
        .timestamp = timestamp_text,
        .environ = process.environ,
    });
    defer app.deinit();

    try print_mode.run(&app.host, stdout, stderr, .{ .prompt = prompt });
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

fn usage(stderr: *std.Io.Writer) noreturn {
    args_mod.writeUsage(stderr);
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

fn testProcess(environ: *std.process.Environ.Map) runtime.Process {
    return .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
    };
}
