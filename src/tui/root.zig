const std = @import("std");
const builtin = @import("builtin");
const coding_agent = @import("../coding_agent/root.zig");
const paths_mod = @import("../coding_agent/paths.zig");
const runtime = @import("../runtime/root.zig");

const InputPumpMod = @import("InputPump.zig");
pub const Editor = @import("Editor.zig");
pub const InputDecoder = @import("InputDecoder.zig");
pub const InputPump = InputPumpMod.InputPump;
pub const Terminal = @import("Terminal.zig");
pub const blocks = @import("blocks.zig");
pub const chrome = @import("chrome.zig");
pub const clipboard_image = @import("clipboard_image.zig");
pub const glyphs = @import("glyphs.zig");
pub const input = @import("input.zig");
pub const layout = @import("layout.zig");
pub const markdown = @import("markdown.zig");
pub const loop = @import("Loop.zig");
pub const render_policy = @import("render_policy.zig");
pub const screen = @import("screen.zig");
pub const theme = @import("theme.zig");
pub const text_shimmer = @import("text_shimmer.zig");
pub const trace = @import("trace.zig");
pub const testing = @import("testing/pty_harness.zig");
pub const Transcript = @import("Transcript.zig");
pub const Loop = loop.Loop;

pub const Options = struct {
    initial_prompt: ?[]const u8,
    open: coding_agent.session_bootstrap.OpenSpec,
    resume_picker: bool,
    panic_test: bool = false,
};

fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

fn persistNewSessionsForOpen(open: coding_agent.session_bootstrap.OpenSpec) bool {
    return switch (open) {
        .create => |create| create.persist,
        .resume_existing => true,
    };
}

pub fn run(process: runtime.Process, options: Options) !void {
    if (builtin.is_test) return error.UnsupportedCliFeature;

    var abandon_cleanup = false;
    var task_runtime = try runtime.Runtime.init(process.gpa, .{});
    defer if (!abandon_cleanup) task_runtime.deinit();

    const agent_dir = try paths_mod.resolveGlobalAgentDirFromEnv(process.gpa, process.environ);
    defer if (!abandon_cleanup) process.gpa.free(agent_dir);

    const cwd = try std.process.currentPathAlloc(process.io, process.gpa);
    defer if (!abandon_cleanup) process.gpa.free(cwd);

    var services = try coding_agent.runtime_services.RuntimeServices.init(process.gpa, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .environ = process.environ,
        .task_runtime = task_runtime,
    });
    defer if (!abandon_cleanup) services.deinit();
    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(process.gpa, &services, stamp.date(), options.open, .{});
    defer if (!abandon_cleanup) {
        session.requestShutdown();
        std.debug.assert(session.shutdownComplete());
        session.deinit();
    };

    var terminal: Terminal = undefined;
    try terminal.init(process.gpa, process.io, process.environ);
    defer if (!abandon_cleanup) terminal.deinit();
    try terminal.setup();

    var wake: runtime.WakeEvent = .init;
    services.setExtensionWake(&wake);
    defer if (!abandon_cleanup) services.clearExtensionWake();
    var owner_loop: Loop = undefined;
    try owner_loop.init(process.gpa, .{
        .session = &session,
        .services = &services,
        .wake = &wake,
        .initial_prompt = options.initial_prompt,
        .persist_new_sessions = persistNewSessionsForOpen(options.open),
        .resume_picker = options.resume_picker,
    });
    defer if (!abandon_cleanup) owner_loop.deinit();
    try terminal.setTitle(owner_loop.terminalTitle());

    var pump: InputPump = .{};
    try pump.startTerminal(services.io, &terminal, &wake);
    defer if (!abandon_cleanup) pump.join();
    defer if (!abandon_cleanup) pump.requestStop();
    defer if (!abandon_cleanup) writeTraceIfRequested(process, &owner_loop) catch {};

    var frontend_error: ?anyerror = null;
    runInteractive(process, options, &owner_loop, &terminal, &pump, &wake, &services) catch |err| {
        frontend_error = err;
    };
    const session_shutdown_timed_out = if (frontend_error) |err|
        err == error.SessionShutdownTimedOut
    else
        false;
    if (session_shutdown_timed_out) {
        pump.requestStop();
        owner_loop.requestShutdown();
        terminal.restoreForFatalExit();
        writeUndrainedDiagnostic(process.io);
        abandon_cleanup = true;
        return error.UndrainedShutdown;
    }
    if (!drainFrontend(&owner_loop, &pump, &wake, services.io)) {
        terminal.restoreForFatalExit();
        writeUndrainedDiagnostic(process.io);
        abandon_cleanup = true;
        return error.UndrainedShutdown;
    }
    if (frontend_error) |err| return err;
}

fn runInteractive(
    process: runtime.Process,
    options: Options,
    owner_loop: *Loop,
    terminal: *Terminal,
    pump: *InputPump,
    wake: *runtime.WakeEvent,
    services: *coding_agent.runtime_services.RuntimeServices,
) !void {
    if (process.env("ZI_TUI_SYNTHETIC_ITEMS")) |value| {
        const count = std.fmt.parseInt(usize, value, 10) catch 0;
        try owner_loop.seedSyntheticItems(count);
    }
    if (process.env("ZI_TUI_SYNTHETIC_TOOLS")) |value| {
        const count = std.fmt.parseInt(usize, value, 10) catch 0;
        try owner_loop.seedSyntheticTools(services.io, count);
    }
    if (process.env("ZI_TUI_SYNTHETIC_BASH_SPILL") != null) try owner_loop.seedSyntheticBashSpill(services.io);
    if (process.env("ZI_TUI_SYNTHETIC_WRITE_ARGS") != null) try owner_loop.seedSyntheticWriteArgs(services.io);
    if (process.env("ZI_TUI_SYNTHETIC_FLOOD") != null) owner_loop.enableSyntheticFlood(nowNs(services.io));
    if (process.env("ZI_TUI_NONCOOPERATIVE_TASK") != null) try owner_loop.startNonCooperativeShutdownTaskForTest();

    if (options.panic_test) {
        try runtime.sleep(services.io, .fromSeconds(1));
        @panic("zi --panic-test");
    }

    _ = try owner_loop.run(terminal, pump, wake);
}

fn drainFrontend(owner_loop: *Loop, pump: *InputPump, wake: *runtime.WakeEvent, io: std.Io) bool {
    pump.requestStop();
    owner_loop.requestShutdown();
    const start = nowNs(io);
    while (nowNs(io) -| start < loop.shutdown_cancel_bound_ns) {
        if (owner_loop.pollShutdown() and pump.hasStopped()) return true;
        wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| {
            const ignored_shutdown_wait_error = @errorName(err);
            _ = ignored_shutdown_wait_error;
        };
        wake.reset();
    }
    return owner_loop.pollShutdown() and pump.hasStopped();
}

fn writeUndrainedDiagnostic(io: std.Io) void {
    std.Io.File.stderr().writeStreamingAll(
        io,
        "zi: fatal: shutdown deadline expired with undrained work; terminal restored\n",
    ) catch |err| {
        const ignored_fatal_diagnostic_error = @errorName(err);
        _ = ignored_fatal_diagnostic_error;
    };
}

fn writeTraceIfRequested(process: runtime.Process, owner_loop: *const Loop) !void {
    const explicit_path = process.env("ZI_TUI_TRACE_FILE");
    if (explicit_path == null and process.env("ZI_TUI_TRACE") == null) return;
    const path = if (explicit_path) |value| value else blk: {
        const tmp_dir = process.env("TMPDIR") orelse "/tmp";
        const stamp = coding_agent.session_manager.SessionStamp.now(process.io);
        const file_name = try std.fmt.allocPrint(process.gpa, "zi-tui-trace-{d}.log", .{stamp.nanoseconds});
        defer process.gpa.free(file_name);
        break :blk try std.fs.path.join(process.gpa, &.{ tmp_dir, file_name });
    };
    defer if (explicit_path == null) process.gpa.free(path);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try owner_loop.writeTraceReport(&writer);
    try std.Io.Dir.writeFile(.cwd(), process.io, .{ .sub_path = path, .data = writer.buffered() });
}

test "run exposes the P1 TUI owner boundary" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expectError(error.UnsupportedCliFeature, run(.{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    }, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    }));
}

test {
    _ = @import("testing/semantic_snapshot.zig");
    std.testing.refAllDecls(@This());
}
