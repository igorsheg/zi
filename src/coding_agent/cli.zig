const std = @import("std");
const runtime = @import("../zistd/root.zig");
const auth_mode = @import("auth_mode.zig");
const paths_mod = @import("paths.zig");
const print_mode = @import("print_mode.zig");
const sdk = @import("sdk.zig");

pub fn run(
    process: runtime.Process,
    args: *std.process.Args.Iterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    return runWithOptions(process, args, stdout, stderr, .{
        .cwd = ".",
        .agent_dir = paths_mod.global_config_dir_name,
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
    _ = args.next();
    const first = args.next() orelse return usage(stderr);
    if (std.mem.eql(u8, first, "auth")) {
        return runAuth(process, args, stdout, stderr, auth_options);
    }
    if (args.next() != null) return usage(stderr);
    return runPrompt(process, stdout, stderr, first);
}

fn runAuth(
    process: runtime.Process,
    args: *std.process.Args.Iterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: auth_mode.Options,
) !void {
    const action = args.next() orelse return usage(stderr);
    const provider = args.next() orelse return usage(stderr);
    if (args.next() != null) return usage(stderr);

    if (std.mem.eql(u8, action, "login")) {
        return auth_mode.login(process.gpa, process.io, stdout, stderr, provider, options);
    }
    if (std.mem.eql(u8, action, "logout")) {
        return auth_mode.logout(process.gpa, process.io, stdout, provider, options);
    }
    if (std.mem.eql(u8, action, "status")) {
        return auth_mode.status(process.gpa, process.io, stdout, provider, options);
    }
    return usage(stderr);
}

fn runPrompt(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    prompt: []const u8,
) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);
    const session_id = try std.fmt.allocPrint(process.gpa, "cli-{d}", .{timestamp});
    defer process.gpa.free(session_id);

    var app = try sdk.createRuntimeHost(process.gpa, process.io, .{
        .cwd = ".",
        .agent_dir = paths_mod.global_config_dir_name,
        .current_date = timestamp_text,
        .session_id = session_id,
        .timestamp = timestamp_text,
        .environ = process.environ,
    });
    defer app.deinit();

    try print_mode.run(&app.host, stdout, stderr, .{ .prompt = prompt });
}

fn usage(stderr: *std.Io.Writer) noreturn {
    stderr.writeAll(
        \\usage: zi <prompt>
        \\       zi auth login openai-codex
        \\       zi auth logout openai-codex
        \\       zi auth status openai-codex
        \\
    ) catch std.process.exit(2);
    stderr.flush() catch std.process.exit(2);
    std.process.exit(2);
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
        .agent_dir = "agent",
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
        .agent_dir = "agent",
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
