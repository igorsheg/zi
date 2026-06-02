const std = @import("std");
const runtime = @import("../runtime/root.zig");
const tui = @import("../tui/root.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const sdk = @import("sdk.zig");

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    resume_session_file: ?[]const u8 = null,
    resume_latest: bool = false,
    initial_prompt: ?[]const u8 = null,
};

const effect_count_max = tui.product.terminal_loop.effects_per_step_max;

pub fn run(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);

    var host_handle = try createHost(process, stderr, options, timestamp_text, timestamp);
    defer host_handle.deinit();

    var terminal_loop = try initTerminalLoop(process, stdout);
    defer terminal_loop.deinit();

    try terminal_loop.setup(stdout);
    defer terminal_loop.shutdown(stdout) catch {};

    if (options.initial_prompt) |prompt| try runPromptBlocking(&host_handle.host, prompt);
    try drainAndDiscardPublicEvents(&host_handle.host);

    var effects: [effect_count_max]tui.product.Effect = undefined;
    _ = try terminal_loop.product.renderIfDirty(stdout);
    while (terminal_loop.running) {
        const result = try terminal_loop.stepRead(stdout, &effects);
        defer for (effects[0..result.effect_count]) |effect| effect.deinit(process.gpa);

        for (effects[0..result.effect_count]) |effect| {
            switch (effect) {
                .submit_text => |text| try runPromptBlocking(&host_handle.host, text),
                .request_shutdown => terminal_loop.running = false,
            }
        }
        try drainAndDiscardPublicEvents(&host_handle.host);
        if (result.eof) terminal_loop.running = false;
    }
}

fn createHost(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    options: Options,
    timestamp_text: []const u8,
    timestamp: i128,
) !sdk.RuntimeHostHandle {
    if (try selectResumeSession(process, stderr, options)) |session_file| {
        defer process.gpa.free(session_file);
        return sdk.resumeRuntimeHost(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_file_name = session_file,
            .dir = options.dir,
            .environ = options.environ,
            .zio_runtime = process.zio_runtime,
        });
    }

    const session_id = try std.fmt.allocPrint(process.gpa, "interactive-{d}", .{timestamp});
    defer process.gpa.free(session_id);
    return sdk.createRuntimeHost(process.gpa, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .current_date = timestamp_text,
        .session_id = session_id,
        .timestamp = timestamp_text,
        .dir = options.dir,
        .environ = options.environ,
        .zio_runtime = process.zio_runtime,
    });
}

fn initTerminalLoop(process: runtime.Process, stdout: *std.Io.Writer) !tui.product.TerminalLoop {
    var terminal = tui.substrate.Terminal.init(process.io);
    const size = terminal.size() catch tui.substrate.terminal.Size{ .width = 80, .height = 24 };
    _ = stdout;
    return tui.product.TerminalLoop.init(
        process.gpa,
        process.io,
        size.width,
        size.height,
        tui.product.loop.output_size_bytes_default,
    );
}

fn selectResumeSession(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    options: Options,
) !?[]const u8 {
    if (options.resume_session_file == null and !options.resume_latest) return null;
    const selected = sdk.selectRuntimeSession(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .explicit_file_name = options.resume_session_file,
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

fn runPromptBlocking(host: *AgentSessionRuntimeHost, text: []const u8) !void {
    const run_handle = try host.startPromptRun(text, &.{}, .{});
    defer host.destroyPromptRun(run_handle);
    while (try host.stepPromptRun(run_handle)) {}
}

fn drainAndDiscardPublicEvents(host: *AgentSessionRuntimeHost) !void {
    while (host.drainPublicEvent()) |event| {
        var owned = event;
        owned.deinit();
    }
}
