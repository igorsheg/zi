const std = @import("std");
const runtime = @import("../runtime/root.zig");
const agent_mod = @import("../agent/root.zig");
const tui = @import("../tui/root.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const AgentSession = @import("AgentSession.zig");
const session_events = @import("session_events.zig");
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
const frame_budget_ns = 33 * std.time.ns_per_ms;
const input_poll_timeout_ms: i32 = 33;
const input_reads_per_tick_max = 1;
const prompt_progress_per_tick_max = 8;
const public_events_per_tick_max = 16;
const render_attempts_per_tick_max = 1;
const shutdown_drain_ticks_max = 30;

fn frameDue(now_ns: i128, last_render_ns: ?i128) bool {
    const last = last_render_ns orelse return true;
    return now_ns - last >= frame_budget_ns;
}

const TranscriptEventAppend = struct {
    role: tui.product.transcript.TranscriptRole,
    text: []const u8,
    mode: tui.product.transcript.TranscriptAppendMode = .new_line,
};

fn transcriptAppendFromEvent(event: session_events.AgentSessionEvent) ?TranscriptEventAppend {
    return switch (event) {
        .agent_event => |agent_event| transcriptAppendFromAgentEvent(agent_event),
        .prompt_command => |payload| .{ .role = .system, .text = payload.message.text },
        .compaction_start => .{ .role = .system, .text = "compaction started" },
        .compaction_end => .{ .role = .system, .text = "compaction ended" },
        .auto_retry_start => .{ .role = .system, .text = "auto retry started" },
        .auto_retry_end => .{ .role = .system, .text = "auto retry ended" },
        .public_event_overflow => .{ .role = .system, .text = "public event overflow" },
        .queue_update, .session_info_changed => null,
    };
}

fn transcriptAppendFromAgentEvent(event: agent_mod.AgentEvent) ?TranscriptEventAppend {
    return switch (event) {
        .agent_start => .{ .role = .system, .text = "agent started" },
        .agent_end => .{ .role = .system, .text = "agent ended" },
        .turn_start => .{ .role = .system, .text = "turn started" },
        .turn_end => .{ .role = .system, .text = "turn ended" },
        .message_update => |payload| switch (payload.assistant_message_event) {
            .text_delta => |delta| .{ .role = .assistant, .text = delta.delta, .mode = .extend_previous_same_role },
            .@"error" => .{ .role = .system, .text = "assistant error" },
            else => null,
        },
        .tool_execution_start => .{ .role = .system, .text = "tool execution started" },
        .tool_execution_update => .{ .role = .system, .text = "tool execution updated" },
        .tool_execution_end => .{ .role = .system, .text = "tool execution ended" },
        .message_start, .message_end => null,
    };
}

const InteractiveLoop = struct {
    process: runtime.Process,
    host: *AgentSessionRuntimeHost,
    terminal_loop: *tui.product.TerminalLoop,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    active_run: ?*AgentSession.LivePromptRun = null,
    cancel_requested: bool = false,
    last_render_ns: ?i128 = null,
    effects: [effect_count_max]tui.product.Effect = undefined,

    fn startPrompt(self: *InteractiveLoop, text: []const u8) !bool {
        if (self.active_run != null) {
            try self.stderr.writeAll("prompt already running; submit ignored\n");
            return false;
        }
        self.active_run = try self.host.startPromptRun(text, &.{}, .{});
        return true;
    }

    fn requestShutdown(self: *InteractiveLoop) void {
        self.terminal_loop.requestStop();
        if (!self.cancel_requested and self.active_run != null) {
            self.host.cancel();
            self.cancel_requested = true;
        }
    }

    fn tick(self: *InteractiveLoop) !void {
        try self.pollInputOnce(if (self.active_run == null) input_poll_timeout_ms else 0);
        _ = try self.drainPromptProgressBounded(prompt_progress_per_tick_max);
        try self.pollInputOnce(0);
        _ = try self.drainPublicEventsBounded(public_events_per_tick_max);
        if (render_attempts_per_tick_max > 0 and self.terminal_loop.isDirty()) {
            const now_ns = std.Io.Timestamp.now(self.process.io, .awake).nanoseconds;
            if (frameDue(now_ns, self.last_render_ns)) {
                try self.terminal_loop.renderIfDirty(self.stdout);
                try self.stdout.flush();
                self.last_render_ns = now_ns;
            }
        }
    }

    fn pollInputOnce(self: *InteractiveLoop, timeout_ms: i32) !void {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.terminal_loop.inputFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = try std.posix.poll(&fds, timeout_ms);
        if ((fds[0].revents & std.posix.POLL.IN) == 0) {
            const result = try self.terminal_loop.flushPendingInput(&self.effects);
            defer self.deinitEffects(result.effect_count);
            try self.handleStepResult(result);
            try self.applyEffects(result.effect_count);
            return;
        }
        var reads: usize = 0;
        while (reads < input_reads_per_tick_max) : (reads += 1) {
            const result = self.terminal_loop.readAvailableInput(&self.effects) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    try self.stderr.writeAll("terminal read failed; shutting down\n");
                    self.requestShutdown();
                    return;
                },
            };
            defer self.deinitEffects(result.effect_count);
            try self.handleStepResult(result);
            try self.applyEffects(result.effect_count);
        }
    }

    fn handleStepResult(self: *InteractiveLoop, result: tui.product.terminal_loop.StepResult) !void {
        if (result.input_overflow) try self.stderr.writeAll("terminal input overflow\n");
        if (result.effect_overflow) try self.stderr.writeAll("terminal effect overflow\n");
        if (result.truncated) try self.stderr.writeAll("terminal input truncated\n");
        if (result.shutdown_requested or result.eof) self.requestShutdown();
    }

    fn applyEffects(self: *InteractiveLoop, count: usize) !void {
        for (self.effects[0..count]) |effect| {
            switch (effect) {
                .submit_text => |text| {
                    if (try self.startPrompt(text)) try self.appendTranscript(.{ .role = .user, .text = text });
                },
                .request_shutdown => self.requestShutdown(),
            }
        }
    }

    fn deinitEffects(self: *InteractiveLoop, count: usize) void {
        for (self.effects[0..count]) |effect| effect.deinit(self.process.gpa);
    }

    fn drainPromptProgressBounded(self: *InteractiveLoop, limit: usize) !usize {
        const prompt_run = self.active_run orelse return 0;
        var count: usize = 0;
        while (count < limit and self.active_run != null) : (count += 1) {
            var progress = self.host.promptRunProgress(prompt_run);
            var frame_timeout = runtime.Timeout.fromMilliseconds(if (count == 0) input_poll_timeout_ms else 0);
            switch (try runtime.select(.{ .prompt = &progress, .frame = &frame_timeout })) {
                .prompt => |result| {
                    const more = try self.host.applyPromptRunProgress(prompt_run, result);
                    if (!more) {
                        self.host.destroyPromptRun(prompt_run);
                        self.active_run = null;
                    }
                },
                .frame => return count,
            }
        }
        return count;
    }

    fn drainPublicEventsBounded(self: *InteractiveLoop, limit: usize) !usize {
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            var event = self.host.drainPublicEvent() orelse return count;
            defer event.deinit();
            try self.applyPublicEventTranscript(event);
        }
        return count;
    }

    fn applyPublicEventTranscript(self: *InteractiveLoop, event: session_events.AgentSessionEvent) !void {
        if (transcriptAppendFromEvent(event)) |append| try self.appendTranscript(append);
    }

    fn appendTranscript(self: *InteractiveLoop, append: TranscriptEventAppend) !void {
        _ = try self.terminal_loop.applyCommand(.{
            .append_transcript = .{ .role = append.role, .text = append.text, .mode = append.mode },
        });
    }

    fn shutdown(self: *InteractiveLoop) void {
        if (self.active_run != null and !self.cancel_requested) {
            self.host.cancel();
            self.cancel_requested = true;
        }
        var ticks: usize = 0;
        while (self.active_run != null and ticks < shutdown_drain_ticks_max) : (ticks += 1) {
            _ = self.drainPromptProgressBounded(prompt_progress_per_tick_max) catch break;
        }
        if (self.active_run) |prompt_run| {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
    }
};

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
    try stdout.flush();
    defer {
        terminal_loop.shutdown(stdout) catch {};
        stdout.flush() catch {};
    }

    var loop: InteractiveLoop = .{
        .process = process,
        .host = &host_handle.host,
        .terminal_loop = &terminal_loop,
        .stdout = stdout,
        .stderr = stderr,
    };
    defer loop.shutdown();

    if (options.initial_prompt) |prompt| {
        if (try loop.startPrompt(prompt)) try loop.appendTranscript(.{ .role = .user, .text = prompt });
    }
    _ = try loop.drainPublicEventsBounded(public_events_per_tick_max);
    try terminal_loop.renderIfDirty(stdout);
    try stdout.flush();

    while (terminal_loop.isRunning()) try loop.tick();
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

test "interactive overflow status is explicit" {
    var err_storage: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&err_storage);
    var loop: InteractiveLoop = undefined;
    loop.stderr = &stderr;

    try loop.handleStepResult(.{
        .input_overflow = true,
        .effect_overflow = true,
        .truncated = true,
    });

    const written = err_storage[0..stderr.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "terminal input overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "terminal effect overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "terminal input truncated") != null);
}

test "interactive frame due enforces thirty fps cadence" {
    try std.testing.expect(frameDue(1000, null));
    try std.testing.expect(!frameDue(1000 + frame_budget_ns - 1, 1000));
    try std.testing.expect(frameDue(1000 + frame_budget_ns, 1000));
    try std.testing.expect(frameDue(1000 + frame_budget_ns + 1, 1000));
}

test "interactive loop bounds stay responsive" {
    try std.testing.expect(frame_budget_ns <= 33 * std.time.ns_per_ms);
    try std.testing.expect(input_poll_timeout_ms <= 33);
    try std.testing.expectEqual(@as(usize, 1), input_reads_per_tick_max);
    try std.testing.expectEqual(@as(usize, 8), prompt_progress_per_tick_max);
    try std.testing.expectEqual(@as(usize, 16), public_events_per_tick_max);
    try std.testing.expectEqual(@as(usize, 1), render_attempts_per_tick_max);
    try std.testing.expectEqual(@as(usize, 30), shutdown_drain_ticks_max);
}

test "interactive maps simple public events to transcript appends" {
    const start = transcriptAppendFromEvent(.{ .agent_event = .agent_start }).?;
    try std.testing.expectEqual(tui.product.transcript.TranscriptRole.system, start.role);
    try std.testing.expectEqualStrings("agent started", start.text);

    const overflow = transcriptAppendFromEvent(.{ .public_event_overflow = .{ .dropped_count = 4 } }).?;
    try std.testing.expectEqual(tui.product.transcript.TranscriptRole.system, overflow.role);
    try std.testing.expectEqualStrings("public event overflow", overflow.text);

    try std.testing.expect(transcriptAppendFromEvent(.{ .session_info_changed = .{ .name = null } }) == null);
}
