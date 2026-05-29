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

pub const CliError = error{
    InvalidCliUsage,
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
        error.InvalidCliUsage, error.UnsupportedCliFeature => {
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
    if (app.messages.count != 1) return usage(stderr);

    const stdin_is_tty = try std.Io.File.stdin().isTty(process.io);
    return switch (args_mod.resolveAppMode(app, stdin_is_tty)) {
        .text => runPrompt(process, stdout, stderr, app.messages.slice()[0], .text, options),
        .json => runPrompt(process, stdout, stderr, app.messages.slice()[0], .json, options),
        .rpc => unsupported(stderr, "rpc mode is not implemented yet"),
        .interactive => unsupported(stderr, "interactive mode is not implemented yet; use -p/--print"),
    };
}

fn runPrompt(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    prompt: []const u8,
    output: print_mode.OutputMode,
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

    try print_mode.run(&app.host, stdout, stderr, .{ .prompt = prompt, .output = output });
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
    try std.testing.expect(std.mem.startsWith(u8, stderr.buffered(), "usage: zi [options] <prompt>"));
}

fn testProcess(environ: *std.process.Environ.Map) runtime.Process {
    return .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = environ,
    };
}
