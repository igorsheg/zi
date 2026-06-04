const std = @import("std");
const runtime = @import("../runtime/root.zig");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const tui = @import("../tui/root.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const AgentSession = @import("AgentSession.zig");
const session_events = @import("session_events.zig");
const session_history_snapshot = @import("session_history_snapshot.zig");
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
const frame_interval_ms: u64 = 33;
const frame_interval_ns: i128 = frame_interval_ms * std.time.ns_per_ms;
const input_reads_per_tick_max = 1;
const prompt_progress_per_tick_max = 8;
const public_events_per_tick_max = 16;
const render_attempts_per_tick_max = 1;
const shutdown_drain_ticks_max = 30;
const pending_tool_outputs_max = 32;
const pending_tool_id_bytes_max = 128;
const pending_tool_output_bytes_max = tui.product.transcript.append_size_bytes_max;
const tool_args_preview_bytes_max = 512;

fn frameDue(now_ns: i128, last_render_ns: ?i128) bool {
    const last = last_render_ns orelse return true;
    return now_ns - last >= frame_interval_ns;
}

const TranscriptAppend = tui.product.transcript.TranscriptAppend;

fn messageAppend(
    role: tui.product.transcript.TranscriptRole,
    text: []const u8,
    mode: tui.product.transcript.TranscriptAppendMode,
) TranscriptAppend {
    return .{ .message = .{ .role = role, .text = text, .mode = mode } };
}

fn statusAppend(level: tui.product.transcript.TranscriptStatusLevel, text: []const u8) TranscriptAppend {
    return .{ .status = .{ .level = level, .text = text } };
}

fn toolAppend(
    tool_call_id: []const u8,
    name: []const u8,
    event: tui.product.transcript.TranscriptToolEvent,
    args_preview: []const u8,
) TranscriptAppend {
    return .{ .tool = .{
        .tool_call_id = tool_call_id,
        .name = name,
        .event = event,
        .args_preview = args_preview,
    } };
}

fn toolArgsPreview(tool_name: []const u8, args_value: std.json.Value) []const u8 {
    if (std.mem.eql(u8, tool_name, "bash")) return boundedArgString(args_value, "command");
    if (std.mem.eql(u8, tool_name, "grep")) return boundedArgString(args_value, "pattern");
    if (std.mem.eql(u8, tool_name, "find")) return boundedArgString(args_value, "name");
    return boundedArgString(args_value, "path");
}

fn boundedArgString(args_value: std.json.Value, key: []const u8) []const u8 {
    if (args_value != .object) return "";
    const value = args_value.object.get(key) orelse return "";
    if (value != .string) return "";
    return utf8Prefix(value.string, tool_args_preview_bytes_max);
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and (value[end] & 0xc0) == 0x80) : (end -= 1) {}
    return value[0..end];
}

fn firstToolResultText(result: agent_mod.AgentToolResult) []const u8 {
    for (result.content) |content| {
        switch (content) {
            .text => |text| return text.text,
            .image => {},
        }
    }
    return "";
}

const TranscriptProjection = union(enum) {
    append: TranscriptAppend,
    tool_output_delta: struct {
        tool_call_id: []const u8,
        text: []const u8,
        dropped_head_bytes: usize = 0,
        dropped_head_lines: usize = 0,
    },
};

fn toolOutputAppend(tool_call_id: []const u8, text: []const u8) ?TranscriptProjection {
    if (text.len == 0) return null;
    return .{ .tool_output_delta = .{ .tool_call_id = tool_call_id, .text = text } };
}

fn toolCallAppend(
    event: tui.product.transcript.TranscriptToolEvent,
    content_index: usize,
    partial: ai.AssistantMessage,
) ?TranscriptProjection {
    if (content_index >= partial.content.len) return null;
    const content = partial.content[content_index];
    if (content != .tool_call) return null;
    const tool_call = content.tool_call;
    if (tool_call.id.len == 0) return null;
    return .{ .append = toolAppend(
        tool_call.id,
        tool_call.name,
        event,
        toolArgsPreview(tool_call.name, tool_call.arguments),
    ) };
}

fn transcriptAppendFromEvent(event: session_events.AgentSessionEvent) ?TranscriptProjection {
    return switch (event) {
        .agent_event => |agent_event| transcriptAppendFromAgentEvent(agent_event),
        .prompt_command => |payload| .{ .append = statusAppend(.info, payload.message.text) },
        .compaction_start => .{ .append = statusAppend(.info, "compaction started") },
        .compaction_end => .{ .append = statusAppend(.info, "compaction ended") },
        .auto_retry_start => .{ .append = statusAppend(.info, "auto retry started") },
        .auto_retry_end => .{ .append = statusAppend(.info, "auto retry ended") },
        .public_event_overflow => .{ .append = statusAppend(.warning, "public event overflow") },
        .queue_update, .session_info_changed => null,
    };
}

fn transcriptAppendFromAgentEvent(event: agent_mod.AgentEvent) ?TranscriptProjection {
    return switch (event) {
        .agent_start, .agent_end, .turn_start, .turn_end => null,
        .message_update => |message_update| switch (message_update.assistant_message_event) {
            .text_delta => |delta| .{ .append = messageAppend(
                .assistant,
                delta.delta,
                .extend_previous_assistant_message,
            ) },
            .thinking_delta => |delta| .{ .append = messageAppend(
                .thinking,
                delta.delta,
                .extend_previous_same_role,
            ) },
            .toolcall_start => |payload| toolCallAppend(.toolcall_start, payload.content_index, payload.partial),
            .toolcall_delta => |payload| toolCallAppend(.toolcall_delta, payload.content_index, payload.partial),
            .toolcall_end => |payload| .{ .append = toolAppend(
                payload.tool_call.id,
                payload.tool_call.name,
                .toolcall_end,
                toolArgsPreview(payload.tool_call.name, payload.tool_call.arguments),
            ) },
            .@"error" => .{ .append = statusAppend(.err, "assistant error") },
            else => null,
        },
        .tool_execution_start => |payload| .{ .append = toolAppend(
            payload.tool_call_id,
            payload.tool_name,
            .tool_execution_start,
            toolArgsPreview(payload.tool_name, payload.args),
        ) },
        .tool_execution_update => |payload| toolOutputAppend(
            payload.tool_call_id,
            firstToolResultText(payload.partial_result),
        ),
        .tool_execution_end => |payload| .{ .append = toolAppend(
            payload.tool_call_id,
            payload.tool_name,
            .tool_execution_end,
            "",
        ) },
        .message_start, .message_end => null,
    };
}

const PendingToolOutput = struct {
    tool_call_id: [pending_tool_id_bytes_max]u8 = undefined,
    tool_call_id_len: usize = 0,
    text: [pending_tool_output_bytes_max]u8 = undefined,
    text_len: usize = 0,
    dropped_head_bytes: usize = 0,
    dropped_head_lines: usize = 0,

    fn id(self: *const PendingToolOutput) []const u8 {
        return self.tool_call_id[0..self.tool_call_id_len];
    }

    fn body(self: *const PendingToolOutput) []const u8 {
        return self.text[0..self.text_len];
    }

    fn init(tool_call_id: []const u8, text: []const u8) PendingToolOutput {
        var result: PendingToolOutput = .{};
        result.tool_call_id_len = @min(tool_call_id.len, pending_tool_id_bytes_max);
        @memcpy(result.tool_call_id[0..result.tool_call_id_len], tool_call_id[0..result.tool_call_id_len]);
        result.append(text);
        return result;
    }

    fn append(self: *PendingToolOutput, text: []const u8) void {
        const keep = @min(text.len, pending_tool_output_bytes_max);
        const source = text[text.len - keep ..];
        if (keep < text.len) self.recordDropped(text[0 .. text.len - keep]);
        if (self.text_len + source.len <= pending_tool_output_bytes_max) {
            @memcpy(self.text[self.text_len .. self.text_len + source.len], source);
            self.text_len += source.len;
            return;
        }
        var overflow = self.text_len + source.len - pending_tool_output_bytes_max;
        while (overflow < self.text_len and (self.text[overflow] & 0xc0) == 0x80) : (overflow += 1) {}
        self.recordDropped(self.text[0..overflow]);
        @memmove(self.text[0 .. self.text_len - overflow], self.text[overflow..self.text_len]);
        self.text_len -= overflow;
        @memcpy(self.text[self.text_len .. self.text_len + source.len], source);
        self.text_len += source.len;
    }

    fn recordDropped(self: *PendingToolOutput, bytes: []const u8) void {
        self.dropped_head_bytes += bytes.len;
        self.dropped_head_lines += std.mem.count(u8, bytes, "\n");
    }
};

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
    pending_tool_outputs: [pending_tool_outputs_max]PendingToolOutput = undefined,
    pending_tool_output_count: usize = 0,

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
        const input_ready = try self.waitForRuntimeWake();
        if (input_ready) {
            try self.drainInputReadyBounded(input_reads_per_tick_max);
        } else {
            try self.flushPendingInput();
        }
        _ = try self.drainPromptProgressBounded(prompt_progress_per_tick_max);
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

    fn waitForRuntimeWake(self: *InteractiveLoop) !bool {
        const readable = runtime.ReadableFd.initBorrowed(self.terminal_loop.inputFd());
        var input = readable.asyncReadable();
        var frame = runtime.Timeout.fromMilliseconds(frame_interval_ms);
        var public_event_wake = self.host.publicEventWake();
        if (self.active_run) |prompt_run| {
            var progress = self.host.promptRunProgress(prompt_run);
            switch (try runtime.select(.{
                .input = &input,
                .prompt = &progress,
                .public_event = public_event_wake,
                .frame = &frame,
            })) {
                .input => |result| return self.handleInputWaitResult(result),
                .prompt => |result| {
                    try self.applyPromptProgressResult(prompt_run, result);
                    return false;
                },
                .public_event => {
                    public_event_wake.reset();
                    return false;
                },
                .frame => return false,
            }
        } else {
            switch (try runtime.select(.{ .input = &input, .public_event = public_event_wake, .frame = &frame })) {
                .input => |result| return self.handleInputWaitResult(result),
                .public_event => {
                    public_event_wake.reset();
                    return false;
                },
                .frame => return false,
            }
        }
    }

    fn handleInputWaitResult(self: *InteractiveLoop, result: runtime.ReadableFdError!void) bool {
        result catch {
            self.requestShutdown();
            return false;
        };
        return true;
    }

    fn flushPendingInput(self: *InteractiveLoop) !void {
        const result = try self.terminal_loop.flushPendingInput(&self.effects);
        defer self.deinitEffects(result.effect_count);
        try self.handleStepResult(result);
        try self.applyEffects(result.effect_count);
    }

    fn drainInputReadyBounded(self: *InteractiveLoop, limit: usize) !void {
        var reads: usize = 0;
        while (reads < limit) : (reads += 1) {
            const result = self.terminal_loop.readAvailableInput(&self.effects) catch |err| switch (err) {
                error.WouldBlock => {
                    const flush = try self.terminal_loop.flushPendingInput(&self.effects);
                    defer self.deinitEffects(flush.effect_count);
                    try self.handleStepResult(flush);
                    try self.applyEffects(flush.effect_count);
                    return;
                },
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
                    if (try self.startPrompt(text)) try self.appendTranscript(messageAppend(.user, text, .new_item));
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
            var ready = runtime.Timeout.fromMilliseconds(0);
            switch (try runtime.select(.{ .prompt = &progress, .ready = &ready })) {
                .prompt => |result| try self.applyPromptProgressResult(prompt_run, result),
                .ready => return count,
            }
        }
        return count;
    }

    fn applyPromptProgressResult(
        self: *InteractiveLoop,
        prompt_run: *AgentSession.LivePromptRun,
        result: anytype,
    ) !void {
        if (self.active_run != prompt_run) return;
        const more = try self.host.applyPromptRunProgress(prompt_run, result);
        if (!more) {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
    }

    fn drainPublicEventsBounded(self: *InteractiveLoop, limit: usize) !usize {
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            var event = self.host.drainPublicEvent() orelse {
                try self.flushToolOutputCoalescer();
                return count;
            };
            defer event.deinit();
            try self.applyPublicEventTranscript(event);
        }
        try self.flushToolOutputCoalescer();
        return count;
    }

    fn applyPublicEventTranscript(self: *InteractiveLoop, event: session_events.AgentSessionEvent) !void {
        if (transcriptAppendFromEvent(event)) |projection| try self.applyTranscriptProjection(projection);
    }

    fn applyTranscriptProjection(self: *InteractiveLoop, projection: TranscriptProjection) !void {
        switch (projection) {
            .append => |append| try self.appendTranscript(append),
            .tool_output_delta => |delta| try self.queueToolOutput(delta.tool_call_id, delta.text),
        }
    }

    fn queueToolOutput(self: *InteractiveLoop, tool_call_id: []const u8, text: []const u8) !void {
        if (text.len == 0) return;
        if (tool_call_id.len > pending_tool_id_bytes_max) {
            try self.appendTranscript(statusAppend(.warning, "tool output omitted: tool id too long"));
            return;
        }
        for (self.pending_tool_outputs[0..self.pending_tool_output_count]) |*pending| {
            if (std.mem.eql(u8, pending.id(), tool_call_id)) {
                pending.append(text);
                return;
            }
        }
        if (self.pending_tool_output_count == self.pending_tool_outputs.len) {
            try self.flushToolOutputCoalescer();
        }
        if (self.pending_tool_output_count == self.pending_tool_outputs.len) return error.TooManyTools;
        self.pending_tool_outputs[self.pending_tool_output_count] = PendingToolOutput.init(tool_call_id, text);
        self.pending_tool_output_count += 1;
    }

    fn flushToolOutputCoalescer(self: *InteractiveLoop) !void {
        for (self.pending_tool_outputs[0..self.pending_tool_output_count]) |*pending| {
            _ = try self.terminal_loop.applyCommand(.{
                .tool_output_delta = .{
                    .tool_call_id = pending.id(),
                    .text = pending.body(),
                    .dropped_head_bytes = pending.dropped_head_bytes,
                    .dropped_head_lines = pending.dropped_head_lines,
                },
            });
        }
        self.pending_tool_output_count = 0;
    }

    fn appendTranscript(self: *InteractiveLoop, append: TranscriptAppend) !void {
        _ = try self.terminal_loop.applyCommand(.{ .append_transcript = append });
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

    try seedTranscriptFromSession(process.gpa, &terminal_loop, &host_handle.host);
    if (options.initial_prompt) |prompt| {
        if (try loop.startPrompt(prompt)) try loop.appendTranscript(messageAppend(.user, prompt, .new_item));
    }
    _ = try loop.drainPublicEventsBounded(public_events_per_tick_max);
    try terminal_loop.renderIfDirty(stdout);
    try stdout.flush();

    while (terminal_loop.isRunning()) try loop.tick();
}

fn seedTranscriptFromSession(
    allocator: std.mem.Allocator,
    terminal_loop: *tui.product.TerminalLoop,
    host: *AgentSessionRuntimeHost,
) !void {
    var snapshot = try host.publicHistorySnapshot(allocator);
    defer snapshot.deinit(allocator);
    try seedTranscriptFromSnapshot(terminal_loop, snapshot.items);
}

fn seedTranscriptFromSnapshot(
    terminal_loop: *tui.product.TerminalLoop,
    items: []const session_history_snapshot.Item,
) !void {
    for (items) |item| {
        _ = try terminal_loop.applyCommand(.{
            .append_transcript = messageAppend(
                transcriptRoleFromHistory(item.role),
                item.text,
                .new_item,
            ),
        });
    }
}

fn transcriptRoleFromHistory(role: session_history_snapshot.Role) tui.product.transcript.TranscriptRole {
    return switch (role) {
        .user => .user,
        .assistant => .assistant,
        .system => .system,
    };
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
    var terminal = tui.Terminal.init(process.io);
    const size = terminal.size() catch tui.TerminalSize{ .width = 80, .height = 24 };
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
    try std.testing.expect(!frameDue(1000 + frame_interval_ns - 1, 1000));
    try std.testing.expect(frameDue(1000 + frame_interval_ns, 1000));
    try std.testing.expect(frameDue(1000 + frame_interval_ns + 1, 1000));
}

test "interactive loop bounds stay responsive" {
    try std.testing.expect(frame_interval_ns <= 33 * std.time.ns_per_ms);
    try std.testing.expect(frame_interval_ms <= 33);
    try std.testing.expectEqual(@as(usize, 1), input_reads_per_tick_max);
    try std.testing.expectEqual(@as(usize, 8), prompt_progress_per_tick_max);
    try std.testing.expectEqual(@as(usize, 16), public_events_per_tick_max);
    try std.testing.expectEqual(@as(usize, 1), render_attempts_per_tick_max);
    try std.testing.expectEqual(@as(usize, 30), shutdown_drain_ticks_max);
}

test "interactive maps simple public events to transcript appends" {
    try std.testing.expect(transcriptAppendFromEvent(.{ .agent_event = .agent_start }) == null);
    try std.testing.expect(transcriptAppendFromEvent(.{ .agent_event = .turn_start }) == null);

    const overflow = transcriptAppendFromEvent(.{ .public_event_overflow = .{ .dropped_count = 4 } }).?;
    try std.testing.expect(overflow == .append);
    try std.testing.expect(overflow.append == .status);
    try std.testing.expectEqual(tui.product.transcript.TranscriptStatusLevel.warning, overflow.append.status.level);
    try std.testing.expectEqualStrings("public event overflow", overflow.append.status.text);

    try std.testing.expect(transcriptAppendFromEvent(.{ .session_info_changed = .{ .name = null } }) == null);
}

test "interactive maps tool events to typed transcript items" {
    const start = transcriptAppendFromEvent(.{ .agent_event = .{ .tool_execution_start = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .args = .null,
    } } }).?;
    try std.testing.expect(start == .append);
    try std.testing.expect(start.append == .tool);
    try std.testing.expectEqualStrings("1", start.append.tool.tool_call_id);
    try std.testing.expectEqualStrings("bash", start.append.tool.name);
    try std.testing.expectEqualStrings("", start.append.tool.args_preview);
    try std.testing.expectEqual(
        tui.product.transcript.TranscriptToolEvent.tool_execution_start,
        start.append.tool.event,
    );

    const end = transcriptAppendFromEvent(.{ .agent_event = .{ .tool_execution_end = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .result = .{ .content = &.{} },
        .is_error = true,
    } } }).?;
    try std.testing.expect(end == .append);
    try std.testing.expect(end.append == .tool);
    try std.testing.expectEqual(tui.product.transcript.TranscriptToolEvent.tool_execution_end, end.append.tool.event);
}

fn testAssistantMessage(content: []const ai.AssistantContent) ai.AssistantMessage {
    return .{
        .content = content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

test "interactive maps thinking deltas to streaming thinking transcript" {
    const event = transcriptAppendFromEvent(.{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = testAssistantMessage(&.{}) },
        .assistant_message_event = .{ .thinking_delta = .{
            .content_index = 0,
            .delta = "considering",
            .partial = testAssistantMessage(&.{}),
        } },
    } } }).?;
    try std.testing.expect(event == .append);
    try std.testing.expect(event.append == .message);
    try std.testing.expectEqual(tui.product.transcript.TranscriptRole.thinking, event.append.message.role);
    try std.testing.expectEqual(.extend_previous_same_role, event.append.message.mode);
    try std.testing.expectEqualStrings("considering", event.append.message.text);
}

test "interactive maps tool call deltas to pending tool row" {
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "command", .{ .string = "echo streaming" });
    const content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "bash",
        .arguments = .{ .object = args },
    } }};
    const partial = testAssistantMessage(&content);

    const event = transcriptAppendFromEvent(.{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = partial },
        .assistant_message_event = .{ .toolcall_delta = .{
            .content_index = 0,
            .delta = "streaming",
            .partial = partial,
        } },
    } } }).?;
    try std.testing.expect(event == .append);
    try std.testing.expect(event.append == .tool);
    try std.testing.expectEqualStrings("call-1", event.append.tool.tool_call_id);
    try std.testing.expectEqualStrings("bash", event.append.tool.name);
    try std.testing.expectEqualStrings("echo streaming", event.append.tool.args_preview);
    try std.testing.expectEqual(tui.product.transcript.TranscriptToolEvent.toolcall_delta, event.append.tool.event);
}

test "interactive maps tool args to bounded args_preview" {
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "command", .{ .string = "zig build test" });

    const start = transcriptAppendFromEvent(.{ .agent_event = .{ .tool_execution_start = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .args = .{ .object = args },
    } } }).?;
    try std.testing.expect(start == .append);
    try std.testing.expect(start.append == .tool);
    try std.testing.expectEqualStrings("zig build test", start.append.tool.args_preview);
}

test "interactive seeds tui transcript from public history snapshot" {
    var terminal_loop = try tui.product.TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        20,
        4,
        tui.product.loop.output_size_bytes_default,
    );
    defer terminal_loop.deinit();

    const user_text = try std.testing.allocator.dupe(u8, "hello");
    defer std.testing.allocator.free(user_text);
    const assistant_text = try std.testing.allocator.dupe(u8, "hi");
    defer std.testing.allocator.free(assistant_text);
    const items = [_]session_history_snapshot.Item{
        .{ .role = .user, .text = user_text },
        .{ .role = .assistant, .text = assistant_text },
    };

    try seedTranscriptFromSnapshot(&terminal_loop, &items);

    try std.testing.expectEqual(@as(usize, 2), terminal_loop.product.app.transcript.items.items.len);
    try std.testing.expectEqual(.user, terminal_loop.product.app.transcript.items.items[0].message.role);
    try std.testing.expectEqualStrings("hello", terminal_loop.product.app.transcript.items.items[0].message.text);
    try std.testing.expectEqual(.assistant, terminal_loop.product.app.transcript.items.items[1].message.role);
    try std.testing.expectEqualStrings("hi", terminal_loop.product.app.transcript.items.items[1].message.text);
}
