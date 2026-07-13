const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const app_info = @import("../app_info.zig");
const runtime = @import("../runtime/root.zig");
const coding_agent = @import("../coding_agent/root.zig");
const auth_mode = coding_agent.auth_mode;
const session_listing = coding_agent.session_listing;
const session_manager = coding_agent.session_manager;
const paths_mod = @import("../coding_agent/paths.zig");
const tui = @import("../tui/root.zig");
const print_mode = @import("../frontends/print/print_mode.zig");
const args_mod = @import("args.zig");

const CliError = error{
    InvalidCliUsage,
    NoResumableSession,
    OutputClosed,
    UnsupportedCliFeature,
    PromptFailed,
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
        error.PromptFailed => {
            try cli_io.flush();
            std.process.exit(1);
        },
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
    const cwd = try std.process.currentPathAlloc(process.io, process.gpa);
    defer process.gpa.free(cwd);
    return runWithOptions(process, args, stdout, stderr, .{
        .cwd = cwd,
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
        .login => {
            var task_runtime = try runtime.Runtime.init(process.gpa, .{});
            defer task_runtime.deinit();
            return auth_mode.login(
                process.gpa,
                process.io,
                task_runtime,
                stdout,
                stderr,
                command.provider,
                options,
            );
        },
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
    if (app.version) return stdout.print("zi {s}\n", .{app_info.version});
    if (app.help) return args_mod.writeHelp(stdout);
    const panic_test = panicTestEnabled(app);
    if (firstUnknownFlagName(app)) |name| return unknownFlag(stderr, name);
    if (!app.print and app.mode == null and app.messages.count == 0) return runTui(process, stderr, app, options, panic_test);

    const stdin_is_tty = try std.Io.File.stdin().isTty(process.io);
    return switch (args_mod.resolveAppMode(app, stdin_is_tty)) {
        .text => {
            if (app.resume_picker or app.messages.count != 1) return usage(stderr);
            return runPrompt(process, stdout, stderr, app.messages.slice()[0], false, app, options);
        },
        .json => {
            if (app.resume_picker or app.messages.count != 1) return usage(stderr);
            return runPrompt(process, stdout, stderr, app.messages.slice()[0], true, app, options);
        },
        .rpc => {
            if (app.resume_picker or app.messages.count > 1) return usage(stderr);
            return runRpc(process, stdout, stderr, app, options);
        },
        .interactive => {
            if (app.messages.count > 1 or (app.resume_picker and app.messages.count > 0)) return usage(stderr);
            return runTui(process, stderr, app, options, panic_test);
        },
    };
}

fn shouldPersistSession(app_args: anytype) bool {
    return !app_args.no_session;
}

fn runTui(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    app_args: anytype,
    options: auth_mode.Options,
    panic_test: bool,
) !void {
    if (isDumbTerminal(process)) return unsupportedTerminal(stderr);
    const stamp = session_manager.SessionStamp.now(process.io);
    var session_id_buffer: [48]u8 = undefined;
    const session_id = std.fmt.bufPrint(&session_id_buffer, "tui-{d}", .{stamp.nanoseconds}) catch unreachable;
    const agent_dir = if (options.agent_dir_override) |override|
        override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(process.gpa, options.environ);
    defer if (options.agent_dir_override == null) process.gpa.free(agent_dir);
    const discovery_paths: paths_mod.PersistencePaths = .{ .global_dir = agent_dir, .cwd = options.cwd };
    const project_trusted = if (!app_args.extensions_enabled)
        false
    else
        app_args.project_trust orelse trust: {
            if (!try coding_agent.extension_discovery.hasProjectExtensions(
                process.gpa,
                process.io,
                discovery_paths,
                options.dir,
            )) break :trust false;
            break :trust try promptProjectTrust(process.io, stderr, options.cwd);
        };
    var extension_plan = if (app_args.extensions_enabled)
        try buildExtensionLoadPlan(
            process.gpa,
            process.io,
            options.dir,
            agent_dir,
            options.cwd,
            project_trusted,
            app_args.extensions.slice(),
        )
    else
        null;
    defer if (extension_plan) |*plan| plan.deinit();
    const selected_session_file = try selectResumeSession(process, stderr, app_args, options);
    defer if (selected_session_file) |session_file| process.gpa.free(session_file);
    const open: coding_agent.session_bootstrap.OpenSpec = if (selected_session_file) |session_file| blk: {
        break :blk .{ .resume_existing = .{ .session_file_name = session_file } };
    } else .{ .create = .{
        .session_id = session_id,
        .timestamp = stamp.timestamp(),
        .persist = shouldPersistSession(app_args),
    } };

    if (builtin.is_test) {
        tui.run(process, .{
            .initial_prompt = if (app_args.messages.count == 1) app_args.messages.slice()[0] else null,
            .open = open,
            .resume_picker = app_args.resume_picker,
            .panic_test = panic_test,
            .extension_load_plan = if (extension_plan) |*plan| plan else null,
        }) catch return frontendStub(stderr);
    } else {
        tui.run(process, .{
            .initial_prompt = if (app_args.messages.count == 1) app_args.messages.slice()[0] else null,
            .open = open,
            .resume_picker = app_args.resume_picker,
            .panic_test = panic_test,
            .extension_load_plan = if (extension_plan) |*plan| plan else null,
        }) catch |err| switch (err) {
            error.UnsupportedCliFeature => return frontendStub(stderr),
            error.ExtensionHostUnavailable => return error.PromptFailed,
            error.UndrainedShutdown => std.process.exit(1),
            else => return err,
        };
    }
}

fn panicTestEnabled(app: anytype) bool {
    for (app.unknown_flags.slice()) |flag| {
        if (std.mem.eql(u8, flag.name, "panic-test")) return true;
    }
    return false;
}

fn firstUnknownFlagName(app: anytype) ?[]const u8 {
    for (app.unknown_flags.slice()) |flag| {
        if (!std.mem.eql(u8, flag.name, "panic-test")) return flag.name;
    }
    return null;
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
    var task_runtime = try runtime.Runtime.init(process.gpa, .{});
    defer task_runtime.deinit();

    const cwd = try process.gpa.dupe(u8, options.cwd);
    defer process.gpa.free(cwd);

    const agent_dir = if (options.agent_dir_override) |override|
        override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(process.gpa, options.environ);
    defer if (options.agent_dir_override == null) process.gpa.free(agent_dir);

    var extension_plan = if (app_args.extensions_enabled)
        try buildExtensionLoadPlan(
            process.gpa,
            process.io,
            options.dir,
            agent_dir,
            cwd,
            app_args.project_trust orelse false,
            app_args.extensions.slice(),
        )
    else
        null;
    defer if (extension_plan) |*plan| plan.deinit();

    var services = try coding_agent.runtime_services.RuntimeServices.init(process.gpa, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .dir = options.dir,
        .environ = options.environ,
        .task_runtime = task_runtime,
        .extension_load_plan = if (extension_plan) |*plan| plan else null,
    });
    defer services.deinit();
    if (extension_plan != null and services.extensionAvailability() != .active) {
        if (services.extensionDiagnostic()) |diagnostic| switch (diagnostic) {
            .startup => |name| try stderr.print("extension host unavailable: {s}\n", .{name}),
            .host => |host| try stderr.print("extension host unavailable: {s}\n", .{@tagName(host.failure)}),
        };
        try stderr.flush();
        return error.PromptFailed;
    }

    const selected_session_file = try selectResumeSession(process, stderr, app_args, .{
        .cwd = cwd,
        .agent_dir_override = agent_dir,
        .dir = options.dir,
        .environ = options.environ,
    });
    defer if (selected_session_file) |session_file| process.gpa.free(session_file);

    const stamp = session_manager.SessionStamp.now(services.io);
    var session_id_buffer: [48]u8 = undefined;
    const session_id = std.fmt.bufPrint(&session_id_buffer, "print-{d}", .{stamp.nanoseconds}) catch unreachable;
    const open: coding_agent.session_bootstrap.OpenSpec = if (selected_session_file) |session_file|
        .{ .resume_existing = .{ .session_file_name = session_file } }
    else
        .{ .create = .{
            .session_id = session_id,
            .timestamp = stamp.timestamp(),
            .persist = shouldPersistSession(app_args),
        } };

    var session = try coding_agent.session_bootstrap.openSession(process.gpa, &services, stamp.date(), open, .{});
    defer shutdownPromptSession(&session, services.io);

    const status = print_mode.run(process.gpa, services.io, &services, &session, stdout, stderr, .{
        .prompt = prompt,
        .output = if (json_output) .json else .text,
    }) catch |err| switch (err) {
        error.OutputClosed => return error.OutputClosed,
        else => {
            try stderr.print("{s}\n", .{@errorName(err)});
            try stderr.flush();
            return error.PromptFailed;
        },
    };
    if (status != 0) return error.PromptFailed;
}

fn buildExtensionLoadPlan(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    agent_dir: []const u8,
    cwd: []const u8,
    project_trusted: bool,
    explicit_paths: []const []const u8,
) !?coding_agent.ExtensionHost.ExtensionLoadPlan {
    return coding_agent.extension_discovery.discover(allocator, io, .{
        .paths = .{ .global_dir = agent_dir, .cwd = cwd },
        .dir = dir,
        .project_trusted = project_trusted,
        .explicit_paths = explicit_paths,
    });
}

fn promptProjectTrust(io: std.Io, stderr: *std.Io.Writer, cwd: []const u8) !bool {
    try stderr.print(
        "Project-local extensions can execute arbitrary code. Trust extensions in {s}/{s}/{s}? [y/N] ",
        .{ cwd, paths_mod.project_config_dir_name, paths_mod.extensions_dir_name },
    );
    try stderr.flush();
    var input_buffer: [32]u8 = undefined;
    var file_reader = std.Io.File.stdin().readerStreaming(io, &input_buffer);
    const line = (file_reader.interface.takeDelimiter('\n') catch return false) orelse return false;
    return projectTrustAnswer(line);
}

fn projectTrustAnswer(line: []const u8) bool {
    const answer = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn runRpc(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    app_args: anytype,
    options: auth_mode.Options,
) !void {
    _ = process;
    _ = stdout;
    _ = app_args;
    _ = options;
    return frontendStub(stderr);
}

fn frontendStub(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("this frontend is being rebuilt; try a newer build\n");
    return error.UnsupportedCliFeature;
}

fn unsupportedTerminal(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("interactive terminal unsupported for TERM=dumb; use --print or --mode text\n");
    return error.UnsupportedCliFeature;
}

fn isDumbTerminal(process: runtime.Process) bool {
    const term = process.env("TERM") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, term, " \t\r\n"), "dumb");
}

const prompt_shutdown_bound_ns: u64 = 5 * std.time.ns_per_s;

fn shutdownPromptSession(session: *coding_agent.AgentSession, io: std.Io) void {
    session.requestShutdown();
    const start = nowNs(io);
    while (!session.shutdownComplete() and nowNs(io) -| start < prompt_shutdown_bound_ns) {
        runtime.sleep(io, .fromMilliseconds(100)) catch break;
    }
    session.deinit();
}

fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

fn selectResumeSession(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    app: anytype,
    options: auth_mode.Options,
) !?[]const u8 {
    if (app.session_selector == null and !app.continue_latest) return null;
    const selected = session_listing.selectRuntimeSession(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .selector = app.session_selector,
    }) catch |err| switch (err) {
        error.InvalidSessionFileName => {
            try stderr.writeAll("invalid session selector\n");
            return error.InvalidCliUsage;
        },
        error.AmbiguousSessionSelector => {
            try stderr.writeAll("ambiguous session selector\n");
            return error.InvalidCliUsage;
        },
        error.SessionListTruncated => {
            try stderr.writeAll("too many sessions to choose safely\n");
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

fn unknownFlag(stderr: *std.Io.Writer, name: []const u8) !void {
    try stderr.print("unsupported: unknown extension flag --{s}\n", .{name});
    try stderr.flush();
    return error.UnsupportedCliFeature;
}

fn usage(stderr: *std.Io.Writer) !void {
    try args_mod.writeUsage(stderr);
    return error.InvalidCliUsage;
}

test "project trust prompt accepts only explicit yes answers" {
    try std.testing.expect(projectTrustAnswer("y\n"));
    try std.testing.expect(projectTrustAnswer(" YES \r\n"));
    try std.testing.expect(!projectTrustAnswer("no\n"));
    try std.testing.expect(!projectTrustAnswer("\n"));
}

test "extension load plan canonicalizes and owns CLI paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "extension.ts",
        .data = "export default function () {}\n",
    });
    var plan = (try buildExtensionLoadPlan(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "missing-agent",
        "missing-repo",
        false,
        &.{"extension.ts"},
    )).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.entries.len);
    try std.testing.expect(std.fs.path.isAbsolute(plan.entries[0].canonical_path));
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

test "cli selects newest resumable session through runtime policy" {
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
    const app = (try args_mod.parse(&.{"--continue"})).app;
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
    const process = testProcess(&environ);

    try createCliStoredSession(tmp.dir, "session", "2026-05-27T00:00:00Z");

    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const app = (try args_mod.parse(&.{ "--session", "2026-05-27T00:00:00Z_session.jsonl" })).app;
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

test "cli selects explicit session id through runtime policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process = testProcess(&environ);

    try createCliStoredSession(tmp.dir, "tui-1781704148400901000", "2026-05-27T00:00:00Z");

    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const app = (try args_mod.parse(&.{ "--session", "tui-1781704148400901000" })).app;
    const selected = (try selectResumeSession(process, &stderr, app, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_tui-1781704148400901000.jsonl", selected);
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
    const app = (try args_mod.parse(&.{"--continue"})).app;

    try std.testing.expectError(error.NoResumableSession, selectResumeSession(process, &stderr, app, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    }));
    try std.testing.expectEqualStrings("no resumable session found\n", stderr.buffered());
}

test "cli reports invalid explicit session selector" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process = testProcess(&environ);
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const app = (try args_mod.parse(&.{ "--session", "../outside.jsonl" })).app;

    try std.testing.expectError(error.InvalidCliUsage, selectResumeSession(process, &stderr, app, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    }));
    try std.testing.expectEqualStrings("invalid session selector\n", stderr.buffered());
}

test "cli accepts hidden panic test flag only for TUI dispatch" {
    const app = (try args_mod.parse(&.{"--panic-test"})).app;
    try std.testing.expect(panicTestEnabled(app));
    try std.testing.expect(firstUnknownFlagName(app) == null);

    const unknown = (try args_mod.parse(&.{"--not-real"})).app;
    try std.testing.expect(!panicTestEnabled(unknown));
    try std.testing.expectEqualStrings("not-real", firstUnknownFlagName(unknown).?);
}

test "cli text and json print frontends run through faux provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "script.md", .data = "cli print ok\n" });

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    try environ.put("ZI_FAUX_DELAY_MS", "0");
    try environ.put("ZI_FAUX_SCRIPT", "script.md");
    const process = testProcess(&environ);

    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var text_argv = [_:null]?[*:0]const u8{ "zi", "--mode", "text", "hi" };
    var text_args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&text_argv) }, std.testing.allocator);
    defer text_args.deinit();
    try runWithOptions(process, &text_args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });
    try std.testing.expectEqualStrings("cli print ok\n", output.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());

    output = std.Io.Writer.fixed(&output_buffer);
    stderr = std.Io.Writer.fixed(&stderr_buffer);
    var json_argv = [_:null]?[*:0]const u8{ "zi", "--mode", "json", "--continue", "hi" };
    var json_args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&json_argv) }, std.testing.allocator);
    defer json_args.deinit();
    try runWithOptions(process, &json_args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });
    var json_lines = std.mem.splitScalar(u8, output.buffered(), '\n');
    var header = try runtime.JsonOwned(std.json.Value).parseJson(std.testing.allocator, json_lines.next().?, .{});
    defer header.deinit();
    try std.testing.expectEqualStrings("session", header.value.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 3), header.value.object.get("version").?.integer);
    var agent_start = try runtime.JsonOwned(std.json.Value).parseJson(std.testing.allocator, json_lines.next().?, .{});
    defer agent_start.deinit();
    try std.testing.expectEqualStrings("agent_start", agent_start.value.object.get("type").?.string);
    try std.testing.expect(std.mem.endsWith(u8, output.buffered(), "{\"type\":\"agent_settled\"}\n"));
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "cli print ok") != null);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "CLI auto-discovers global extensions and honors the kill switch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);
    try tmp.dir.createDirPath(std.testing.io, "agent/extensions");

    const failing_extension =
        \\export default function activate(zi) {
        \\  zi.commands.registerPrompt({
        \\    name: "COMMAND_NAME",
        \\    description: "Fail for discovery testing",
        \\    run: () => { throw new Error("discovered"); },
        \\  });
        \\}
    ;
    const global_source = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        failing_extension,
        "COMMAND_NAME",
        "global-fail",
    );
    defer std.testing.allocator.free(global_source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/extensions/global.ts", .data = global_source });

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    try environ.put("ZI_FAUX_DELAY_MS", "0");
    try environ.put("ZI_NODE", build_options.node_executable);
    const process = testProcess(&environ);

    var output_buffer: [16 * 1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const cases = [_]struct {
        argv: []const []const u8,
        fails: bool,
    }{
        .{ .argv = &.{ "zi", "--print", "--no-session", "/global-fail" }, .fails = true },
        .{ .argv = &.{ "zi", "--print", "--no-session", "--no-extensions", "/global-fail" }, .fails = false },
    };
    for (cases) |case| {
        var output = std.Io.Writer.fixed(&output_buffer);
        var stderr = std.Io.Writer.fixed(&stderr_buffer);
        const app = (try args_mod.parse(case.argv[1..])).app;
        const result = runApp(process, &output, &stderr, app, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .dir = tmp.dir,
            .environ = process.environ,
        });
        if (case.fails)
            try std.testing.expectError(error.PromptFailed, result)
        else
            try result;
    }
}

test "cli json assistant failure stays zero-status while text fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    try environ.put("ZI_FAUX_DELAY_MS", "0");
    try environ.put("ZI_FAUX_ERROR_MESSAGE", "provider failure");
    const process = testProcess(&environ);

    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var json_argv = [_:null]?[*:0]const u8{ "zi", "--mode", "json", "--no-session", "hi" };
    var json_args = try std.process.Args.Iterator.initAllocator(
        .{ .vector = @ptrCast(&json_argv) },
        std.testing.allocator,
    );
    defer json_args.deinit();
    try runWithOptions(process, &json_args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "\"stopReason\":\"error\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.buffered(), "{\"type\":\"agent_settled\"}\n"));
    try std.testing.expectEqualStrings("", stderr.buffered());

    output = std.Io.Writer.fixed(&output_buffer);
    stderr = std.Io.Writer.fixed(&stderr_buffer);
    var text_argv = [_:null]?[*:0]const u8{ "zi", "--mode", "text", "--no-session", "hi" };
    var text_args = try std.process.Args.Iterator.initAllocator(
        .{ .vector = @ptrCast(&text_argv) },
        std.testing.allocator,
    );
    defer text_args.deinit();
    try std.testing.expectError(error.PromptFailed, runWithOptions(process, &text_args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    }));
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expectEqualStrings("error: provider failure\n", stderr.buffered());
}

test "cli json no-session emits in-memory header and creates no file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "script.md", .data = "ephemeral json\n" });

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    try environ.put("ZI_FAUX_DELAY_MS", "0");
    try environ.put("ZI_FAUX_SCRIPT", "script.md");
    const process = testProcess(&environ);

    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var argv = [_:null]?[*:0]const u8{ "zi", "--mode", "json", "--no-session", "hi" };
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&argv) }, std.testing.allocator);
    defer args.deinit();

    try runWithOptions(process, &args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });
    var lines = std.mem.splitScalar(u8, output.buffered(), '\n');
    var header = try runtime.JsonOwned(std.json.Value).parseJson(std.testing.allocator, lines.next().?, .{});
    defer header.deinit();
    try std.testing.expectEqualStrings("session", header.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("repo", header.value.object.get("cwd").?.string);
    try std.testing.expect(std.mem.endsWith(u8, output.buffered(), "{\"type\":\"agent_settled\"}\n"));
    try std.testing.expectEqualStrings("", stderr.buffered());

    var sessions = try session_listing.listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });
    defer sessions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), sessions.file_names.len);
}

test "cli no-session print does not create a session file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createCliTestDirs(tmp.dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "script.md", .data = "ephemeral ok\n" });

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");
    try environ.put("ZI_FAUX_DELAY_MS", "0");
    try environ.put("ZI_FAUX_SCRIPT", "script.md");
    const process = testProcess(&environ);

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var argv = [_:null]?[*:0]const u8{ "zi", "-p", "--no-session", "hi" };
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&argv) }, std.testing.allocator);
    defer args.deinit();

    try runWithOptions(process, &args, &output, &stderr, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });
    try std.testing.expectEqualStrings("ephemeral ok\n", output.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());

    var sessions = try session_listing.listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = process.environ,
    });
    defer sessions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), sessions.file_names.len);
}

test "cli rpc frontend remains stubbed" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process = testProcess(&environ);

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    const rpc_app = (try args_mod.parse(&.{ "--mode", "rpc" })).app;
    try std.testing.expectError(error.UnsupportedCliFeature, runRpc(
        process,
        &output,
        &stderr,
        rpc_app,
        .{ .cwd = ".", .agent_dir_override = null, .environ = process.environ },
    ));
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expectEqualStrings("this frontend is being rebuilt; try a newer build\n", stderr.buffered());
}

test "cli refuses TUI on dumb terminal with print hint" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("TERM", "dumb");
    const process = testProcess(&environ);

    var output_buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stderr_buffer: [128]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var argv = [_:null]?[*:0]const u8{"zi"};
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = @ptrCast(&argv) }, std.testing.allocator);
    defer args.deinit();

    try std.testing.expectError(error.UnsupportedCliFeature, runWithOptions(process, &args, &output, &stderr, .{
        .cwd = ".",
        .agent_dir_override = null,
        .environ = process.environ,
    }));
    try std.testing.expectEqualStrings("", output.buffered());
    try std.testing.expectEqualStrings("interactive terminal unsupported for TERM=dumb; use --print or --mode text\n", stderr.buffered());
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
    try dir.createDirPath(std.testing.io, "repo/.zi");
}

fn createCliStoredSession(dir: std.Io.Dir, session_id: []const u8, timestamp: []const u8) !void {
    const sessions_dir = try (paths_mod.PersistencePaths{ .global_dir = "agent", .cwd = "repo" }).sessionsDirForCwd(std.testing.allocator);
    defer std.testing.allocator.free(sessions_dir);
    var store = try session_manager.SessionStore.create(std.testing.allocator, std.testing.io, dir, .{
        .sessions_dir = sessions_dir,
        .cwd = "repo",
        .session_id = session_id,
        .timestamp = timestamp,
    });
    defer store.deinit();
}
