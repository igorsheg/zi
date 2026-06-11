const std = @import("std");

const agent_mod = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const client_protocol = coding_agent.client_protocol;
const session_listing = coding_agent.session_listing;
const session_runtime = coding_agent.session_runtime;
const runtime = @import("../../runtime/root.zig");
const tui = @import("../../tui/root.zig");

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    resume_session_file: ?[]const u8 = null,
    resume_latest: bool = false,
    initial_prompt: ?[]const u8 = null,
};

const frame_interval_ms: u64 = 16;
const effect_count_max = tui.product.terminal_loop.effects_per_step_max;
const client_events_per_tick_max = 64;
const status_id_working: tui.product.SlotContributionId = 1;
const status_id_queue: tui.product.SlotContributionId = 2;
const status_id_recovery: tui.product.SlotContributionId = 3;
const model_slot_id: tui.product.SlotContributionId = 1;
const output_size_bytes = tui.product.loop.output_size_bytes_default;
const transcript_append_max = tui.product.transcript.append_size_bytes_max;
const TranscriptAppend = tui.product.transcript.TranscriptAppend;

fn ignoreBestEffortError(err: anyerror) void {
    std.debug.assert(@errorName(err).len > 0);
}

const SubmitResult = enum { queued, queue_full };

const EventCursor = struct {
    last_seq: client_protocol.EventSeq = 0,
    recovery: Recovery = .live,

    const Recovery = enum { live, replay_requested, snapshot_requested };
};

pub fn run(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    const stamp = session_runtime.SessionStamp.now(process.io);
    var app = if (try selectResumeSession(process, stderr, options)) |session_file| blk: {
        defer process.gpa.free(session_file);
        break :blk try session_runtime.openSessionRuntime(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = stamp.date(),
            .open = .{ .resume_existing = .{ .session_file_name = session_file } },
            .dir = options.dir,
            .environ = options.environ,
        });
    } else blk: {
        var session_id_buffer: [48]u8 = undefined;
        const session_id = std.fmt.bufPrint(&session_id_buffer, "tui-{d}", .{stamp.nanoseconds}) catch
            unreachable;
        break :blk try session_runtime.openSessionRuntime(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = stamp.date(),
            .open = .{ .create = .{ .session_id = session_id, .timestamp = stamp.timestamp() } },
            .dir = options.dir,
            .environ = options.environ,
        });
    };
    defer app.deinit();

    var controller = try InteractiveController.init(process, &app, stdout, stderr, options.initial_prompt);
    defer controller.deinit();
    try controller.run();
}

const InteractiveController = struct {
    allocator: std.mem.Allocator,
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    terminal_loop: tui.product.TerminalLoop,
    cancel_requested: bool = false,
    event_cursor: EventCursor = .{},
    animation_tick: u64 = 0,
    pending_input_flush: bool = false,
    assistant_text_delta_seen: bool = false,

    fn init(
        process: runtime.Process,
        app: *session_runtime.SessionRuntime,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        initial_prompt: ?[]const u8,
    ) !InteractiveController {
        var terminal_loop = try tui.product.TerminalLoop.init(
            process.gpa,
            process.io,
            80,
            24,
            output_size_bytes,
        );
        errdefer terminal_loop.deinit();
        terminal_loop.resizeFromTerminal() catch |err| ignoreBestEffortError(err);
        try terminal_loop.setup(stdout);
        try stdout.flush();
        errdefer terminal_loop.shutdown(stdout) catch |err| ignoreBestEffortError(err);

        var self: InteractiveController = .{
            .allocator = process.gpa,
            .app = app,
            .stdout = stdout,
            .stderr = stderr,
            .terminal_loop = terminal_loop,
        };
        try self.requestSnapshot();
        if (initial_prompt) |prompt| try self.submitPrompt(prompt);
        _ = try self.terminal_loop.renderIfDirty(stdout);
        try stdout.flush();
        return self;
    }

    fn deinit(self: *InteractiveController) void {
        self.terminal_loop.shutdown(self.stdout) catch |err| ignoreBestEffortError(err);
        self.stdout.flush() catch |err| ignoreBestEffortError(err);
        self.terminal_loop.deinit();
        self.* = undefined;
    }

    fn run(self: *InteractiveController) !void {
        while (self.terminal_loop.isRunning()) {
            if (try self.serviceImmediateWork()) continue;

            const wake = try self.app.waitAndApplyWake(self.terminal_loop.inputFd(), frame_interval_ms);
            switch (wake) {
                .input => try self.drainInput(),
                .session => if (self.pending_input_flush) try self.flushPendingInput(),
                .frame => if (self.pending_input_flush) try self.flushPendingInput(),
            }
            _ = try self.serviceImmediateWork();
        }
    }

    fn serviceImmediateWork(self: *InteractiveController) !bool {
        try self.app.step();
        const drained = try self.drainClientEventsBounded(client_events_per_tick_max);
        try self.tickStatus();
        try self.terminal_loop.renderIfDirty(self.stdout);
        try self.stdout.flush();
        return drained == client_events_per_tick_max or self.app.hasImmediateWork();
    }

    fn drainInput(self: *InteractiveController) !void {
        var effects: [effect_count_max]tui.product.Effect = undefined;
        const result = try self.terminal_loop.readAvailableInput(&effects);
        self.pending_input_flush = true;
        try self.handleInputResult(result, effects[0..result.effect_count]);
    }

    fn flushPendingInput(self: *InteractiveController) !void {
        self.pending_input_flush = false;
        var effects: [effect_count_max]tui.product.Effect = undefined;
        const result = try self.terminal_loop.flushPendingInput(&effects);
        try self.handleInputResult(result, effects[0..result.effect_count]);
    }

    fn handleInputResult(
        self: *InteractiveController,
        result: tui.product.terminal_loop.StepResult,
        effects: []tui.product.Effect,
    ) !void {
        defer for (effects) |effect| effect.deinit(self.allocator);
        for (effects) |effect| try self.handleEffect(effect);
        if (result.input_overflow or result.truncated) try self.applyStatus(.warning, "input truncated");
        if (result.effect_overflow) try self.applyStatus(.warning, "input effects dropped");
    }

    fn handleEffect(self: *InteractiveController, effect: tui.product.Effect) !void {
        switch (effect) {
            .submit_text => |text| try self.submitPrompt(text),
            .interrupt => try self.cancelActive(),
            .request_shutdown => {
                if (try self.submitCommand(.{ .command = .shutdown }) == .queued) {
                    self.terminal_loop.requestStop();
                }
            },
            .confirm_result => {},
        }
    }

    fn submitPrompt(self: *InteractiveController, prompt: []const u8) !void {
        const envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(self.allocator, null, prompt, .auto);
        if (try self.submitCommand(envelope) == .queued) self.cancel_requested = false;
    }

    fn cancelActive(self: *InteractiveController) !void {
        if (self.cancel_requested) return;
        if (try self.submitCommand(.{ .command = .{ .cancel = .{} } }) == .queued) {
            self.cancel_requested = true;
            try self.applyStatus(.warning, "cancel requested");
        }
    }

    fn requestSnapshot(self: *InteractiveController) !void {
        _ = try self.submitCommand(.{ .command = .snapshot });
    }

    fn requestReplay(self: *InteractiveController, after: client_protocol.EventSeq) !void {
        _ = try self.submitCommand(.{ .command = .{ .replay = .{ .after = after } } });
    }

    fn submitCommand(self: *InteractiveController, envelope: client_protocol.CommandEnvelope) !SubmitResult {
        var owned = envelope;
        self.app.submit(owned) catch |err| switch (err) {
            error.Full => {
                owned.deinit(self.allocator);
                try self.applyStatus(.err, "command queue full");
                return .queue_full;
            },
        };
        return .queued;
    }

    fn drainClientEventsBounded(self: *InteractiveController, limit: usize) !usize {
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            var envelope = self.app.drainEvent() orelse return count;
            defer envelope.deinit(self.allocator);
            try self.acceptEnvelope(envelope);
        }
        return count;
    }

    fn acceptEnvelope(self: *InteractiveController, envelope: client_protocol.EventEnvelope) !void {
        if (envelope.event == .snapshot) {
            self.event_cursor.last_seq = envelope.seq;
            self.event_cursor.recovery = .live;
            try self.clearStatus(status_id_recovery);
            try self.applyClientEvent(envelope.event);
            return;
        }

        if (self.event_cursor.recovery != .live) {
            switch (envelope.event) {
                .replay => {
                    self.event_cursor.last_seq = envelope.seq;
                    self.event_cursor.recovery = .snapshot_requested;
                    try self.appendStatus(.warning, "replay requires snapshot in TUI adapter");
                    try self.requestSnapshot();
                },
                .replay_gap => {
                    self.event_cursor.last_seq = envelope.seq;
                    self.event_cursor.recovery = .snapshot_requested;
                    try self.appendStatus(.warning, "replay gap; requesting snapshot");
                    try self.requestSnapshot();
                },
                else => {},
            }
            return;
        }

        const expected = self.event_cursor.last_seq + 1;
        if (envelope.seq != expected) {
            self.event_cursor.recovery = .replay_requested;
            try self.setRecoveryStatus("recovering event gap");
            try self.requestReplay(self.event_cursor.last_seq);
            return;
        }
        self.event_cursor.last_seq = envelope.seq;
        try self.applyClientEvent(envelope.event);
    }

    fn applyClientEvent(self: *InteractiveController, event: client_protocol.ClientEvent) !void {
        switch (event) {
            .agent_event => |payload| try self.applyAgentEvent(payload.event),
            .operation_started => try self.setWorkingStatus("working"),
            .operation_finished => |finished| try self.applyOperationFinished(finished),
            .rejected => |rejection| try self.appendStatus(.err, rejection.message.text),
            .queue_changed => |queue| try self.applyQueueChanged(queue),
            .snapshot => |snapshot| try self.applySnapshot(snapshot),
            .replay => {
                self.event_cursor.recovery = .snapshot_requested;
                try self.appendStatus(.warning, "replay requires snapshot in TUI adapter");
                try self.requestSnapshot();
            },
            .replay_gap => {
                self.event_cursor.recovery = .snapshot_requested;
                try self.appendStatus(.warning, "replay gap; requesting snapshot");
                try self.requestSnapshot();
            },
            .shutdown_started => self.terminal_loop.requestStop(),
            .compaction_start => try self.setWorkingStatus("compacting"),
            .compaction_end => |payload| if (payload.error_message) |message|
                try self.appendStatus(.warning, message.text)
            else
                try self.clearStatus(status_id_working),
            .auto_retry_start => |payload| {
                var buffer: [96]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &buffer,
                    "retry {d}/{d} in {d}ms",
                    .{ payload.attempt, payload.max_attempts, payload.delay_ms },
                ) catch "retrying";
                try self.setWorkingStatus(text);
            },
            .auto_retry_end => try self.clearStatus(status_id_working),
            .event_overflow => |overflow| {
                var buffer: [96]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &buffer,
                    "event overflow: dropped {d}",
                    .{overflow.dropped_count},
                ) catch "event overflow";
                try self.appendStatus(.warning, text);
                self.event_cursor.recovery = .replay_requested;
                try self.requestReplay(self.event_cursor.last_seq -| 1);
            },
        }
    }

    fn applyAgentEvent(self: *InteractiveController, event: agent_mod.AgentEvent) !void {
        switch (event) {
            .message_start => |payload| {
                if (payload.message == .assistant) self.assistant_text_delta_seen = false;
            },
            .message_update => |payload| try self.applyMessageUpdate(payload),
            .message_end => |payload| try self.applyMessageEnd(payload.message),
            .tool_execution_start => |payload| try self.applyToolStart(payload),
            .tool_execution_update => |payload| try self.applyToolUpdate(payload),
            .tool_execution_end => |payload| try self.applyToolEnd(payload),
            .agent_start, .agent_end, .turn_end => {},
            .turn_start => self.assistant_text_delta_seen = false,
        }
    }

    fn applyMessageUpdate(self: *InteractiveController, update: agent_mod.AgentEvent.MessageUpdate) !void {
        switch (update.assistant_message_event) {
            .text_delta => |payload| {
                self.assistant_text_delta_seen = true;
                try self.appendMessage(.assistant, payload.delta, .extend_previous_assistant_message);
            },
            .thinking_delta => |payload| try self.appendMessage(.thinking, payload.delta, .extend_previous_same_role),
            .toolcall_start => |payload| try self.applyToolCallPreview(payload.content_index, payload.partial),
            .toolcall_delta => |payload| try self.applyToolCallPreview(payload.content_index, payload.partial),
            .toolcall_end => |payload| try self.applyToolCall(payload.tool_call),
            else => {},
        }
    }

    fn applyMessageEnd(self: *InteractiveController, message: agent_mod.AgentMessage) !void {
        switch (message) {
            .user => |user| if (userText(user)) |text| try self.appendMessage(.user, text, .new_item),
            .assistant => |assistant| {
                if (assistant.error_message) |message_text| try self.appendStatus(.err, message_text);
                if (!self.assistant_text_delta_seen) try self.appendAssistantFinalText(assistant);
                self.assistant_text_delta_seen = false;
            },
            .tool_result => {},
            .custom => {},
        }
    }

    fn applyToolCallPreview(self: *InteractiveController, content_index: usize, partial: ai.AssistantMessage) !void {
        if (content_index >= partial.content.len) return;
        const content = partial.content[content_index];
        if (content != .tool_call) return;
        try self.applyToolCall(content.tool_call);
    }

    fn applyToolCall(self: *InteractiveController, tool_call: ai.ToolCall) !void {
        const title = toolTitle(tool_call.name, tool_call.arguments);
        try self.appendTool(.{
            .tool_call_id = tool_call.id,
            .name = tool_call.name,
            .presentation = toolPresentation(tool_call.name),
            .status = .pending,
            .body_mode = toolBodyMode(tool_call.name),
            .title = title,
        });
    }

    fn applyToolStart(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionStart) !void {
        try self.appendTool(toolAppend(
            payload.tool_call_id,
            payload.tool_name,
            .pending,
            toolTitle(payload.tool_name, payload.args),
            false,
        ).tool);
    }

    fn applyToolUpdate(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
        const text = firstToolResultText(payload.partial_result.content) orelse return;
        try self.appendToolOutput(payload.tool_call_id, text);
    }

    fn applyToolEnd(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
        try self.appendTool(toolAppend(
            payload.tool_call_id,
            payload.tool_name,
            if (payload.is_error) .err else .success,
            "",
            payload.is_error,
        ).tool);
        const text = firstToolResultText(payload.result.content) orelse return;
        try self.appendToolOutput(payload.tool_call_id, text);
    }

    fn applySnapshot(self: *InteractiveController, snapshot: client_protocol.Snapshot) !void {
        _ = try self.terminal_loop.applyCommand(.clear_transcript);
        var model_buffer: [160]u8 = undefined;
        const model_text = std.fmt.bufPrint(
            &model_buffer,
            "{s}/{s}",
            .{ snapshot.model.provider.text, snapshot.model.id.text },
        ) catch snapshot.model.id.text;
        _ = try self.terminal_loop.applyCommand(.{ .set_slot_contribution = .{
            .slot = .composer_top_right,
            .id = model_slot_id,
            .priority = 1,
            .text = model_text,
        } });
        for (snapshot.history.items) |item| {
            const role: tui.product.transcript.TranscriptRole = switch (item.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
            };
            try self.appendMessage(role, item.text.text, .new_item);
        }
        try self.applyQueueSnapshot(snapshot.queue);
    }

    fn applyQueueSnapshot(self: *InteractiveController, queue: client_protocol.QueueSnapshot) !void {
        try self.applyQueueCounts(queue.steering.items.len, queue.follow_up.items.len);
    }

    fn applyQueueChanged(self: *InteractiveController, queue: client_protocol.QueueChanged) !void {
        try self.applyQueueCounts(queue.steering_count, queue.follow_up_count);
    }

    fn applyQueueCounts(self: *InteractiveController, steering_count: usize, follow_up_count: usize) !void {
        if (steering_count == 0 and follow_up_count == 0) return self.clearStatus(status_id_queue);
        var buffer: [80]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "queued steer={d} followup={d}",
            .{ steering_count, follow_up_count },
        ) catch "queued prompts";
        _ = try self.terminal_loop.applyCommand(.{ .set_slot_contribution = .{
            .slot = .status_area,
            .id = status_id_queue,
            .priority = 1,
            .text = text,
        } });
    }

    fn applyOperationFinished(self: *InteractiveController, finished: client_protocol.OperationFinished) !void {
        self.cancel_requested = false;
        try self.clearStatus(status_id_working);
        switch (finished.reason) {
            .completed => {},
            .canceled => try self.appendStatus(.warning, "canceled"),
            .failed => try self.appendStatus(.err, "operation failed"),
        }
    }

    fn appendMessage(
        self: *InteractiveController,
        role: tui.product.transcript.TranscriptRole,
        text: []const u8,
        mode: tui.product.transcript.TranscriptAppendMode,
    ) !void {
        if (text.len == 0) return;
        if (!std.unicode.utf8ValidateSlice(text)) {
            try self.appendStaticStatus(.warning, "invalid message text dropped");
            return;
        }
        var remaining = text;
        var chunk_mode = mode;
        while (remaining.len > 0) {
            const chunk = utf8Prefix(remaining, transcript_append_max);
            if (chunk.len == 0) {
                try self.appendStaticStatus(.warning, "message text truncated");
                return;
            }
            _ = try self.terminal_loop.applyCommand(.{ .append_transcript = .{ .message = .{
                .role = role,
                .text = chunk,
                .mode = chunk_mode,
            } } });
            remaining = remaining[chunk.len..];
            chunk_mode = .extend_previous_same_role;
        }
    }

    fn appendAssistantFinalText(self: *InteractiveController, assistant: ai.AssistantMessage) !void {
        for (assistant.content) |content| switch (content) {
            .text => |text| try self.appendMessage(.assistant, text.text, .extend_previous_assistant_message),
            .thinking => |thinking| try self.appendMessage(.thinking, thinking.thinking, .extend_previous_same_role),
            .tool_call => {},
        };
    }

    fn appendTool(self: *InteractiveController, tool: tui.product.transcript.TranscriptAppend.ToolAppend) !void {
        if (!std.unicode.utf8ValidateSlice(tool.tool_call_id) or
            !std.unicode.utf8ValidateSlice(tool.name) or
            !std.unicode.utf8ValidateSlice(tool.title))
        {
            try self.appendStaticStatus(.warning, "invalid tool metadata dropped");
            return;
        }
        var safe_tool = tool;
        safe_tool.title = utf8Prefix(tool.title, transcript_append_max / 2);
        _ = try self.terminal_loop.applyCommand(.{ .append_transcript = .{ .tool = safe_tool } });
    }

    fn appendToolOutput(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        if (text.len == 0) return;
        if (!std.unicode.utf8ValidateSlice(tool_call_id) or !std.unicode.utf8ValidateSlice(text)) {
            try self.appendStaticStatus(.warning, "invalid tool output dropped");
            return;
        }
        var remaining = text;
        while (remaining.len > 0) {
            const chunk = utf8Prefix(remaining, transcript_append_max);
            if (chunk.len == 0) {
                try self.appendStaticStatus(.warning, "tool output truncated");
                return;
            }
            _ = try self.terminal_loop.applyCommand(.{ .tool_output_delta = .{
                .tool_call_id = tool_call_id,
                .text = chunk,
            } });
            remaining = remaining[chunk.len..];
        }
    }

    fn appendStatus(
        self: *InteractiveController,
        level: tui.product.transcript.TranscriptStatusLevel,
        text: []const u8,
    ) !void {
        if (text.len == 0) return;
        if (!std.unicode.utf8ValidateSlice(text)) {
            return self.appendStaticStatus(.warning, "invalid status text dropped");
        }
        const safe = utf8Prefix(text, transcript_append_max);
        try self.appendStaticStatus(level, safe);
    }

    fn appendStaticStatus(
        self: *InteractiveController,
        level: tui.product.transcript.TranscriptStatusLevel,
        text: []const u8,
    ) !void {
        if (text.len == 0) return;
        _ = try self.terminal_loop.applyCommand(.{
            .append_transcript = .{ .status = .{ .level = level, .text = text } },
        });
    }

    fn applyStatus(
        self: *InteractiveController,
        level: tui.product.transcript.TranscriptStatusLevel,
        text: []const u8,
    ) !void {
        try self.appendStatus(level, text);
    }

    fn setWorkingStatus(self: *InteractiveController, text: []const u8) !void {
        const safe = if (std.unicode.utf8ValidateSlice(text)) utf8Prefix(text, 512) else "working";
        _ = try self.terminal_loop.applyCommand(.{ .set_slot_contribution = .{
            .slot = .status_area,
            .id = status_id_working,
            .priority = 10,
            .text = safe,
            .effect = .shimmer,
        } });
    }

    fn setRecoveryStatus(self: *InteractiveController, text: []const u8) !void {
        const safe = if (std.unicode.utf8ValidateSlice(text)) utf8Prefix(text, 512) else "recovering";
        _ = try self.terminal_loop.applyCommand(.{ .set_slot_contribution = .{
            .slot = .status_area,
            .id = status_id_recovery,
            .priority = 9,
            .text = safe,
            .effect = .shimmer,
        } });
    }

    fn clearStatus(self: *InteractiveController, id: tui.product.SlotContributionId) !void {
        _ = try self.terminal_loop.applyCommand(.{ .clear_slot_contribution = .{ .slot = .status_area, .id = id } });
    }

    fn tickStatus(self: *InteractiveController) !void {
        self.animation_tick +%= 1;
        _ = try self.terminal_loop.applyCommand(.{ .animation_tick = self.animation_tick });
    }
};

fn selectResumeSession(process: runtime.Process, stderr: *std.Io.Writer, options: Options) !?[]const u8 {
    if (options.resume_session_file == null and !options.resume_latest) return null;
    const selected = session_listing.selectRuntimeSession(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .explicit_file_name = options.resume_session_file,
    }) catch |err| switch (err) {
        error.InvalidSessionFileName => {
            try stderr.writeAll("invalid resume session file\n");
            return error.InvalidSessionFileName;
        },
        error.SessionListTruncated => {
            try stderr.writeAll("too many sessions to choose latest safely\n");
            return error.SessionListTruncated;
        },
        else => return err,
    };
    if (selected == null) {
        try stderr.writeAll("no resumable session found\n");
        return error.NoResumableSession;
    }
    return selected;
}

fn toolAppend(
    tool_call_id: []const u8,
    name: []const u8,
    status: tui.product.transcript.TranscriptToolStatus,
    title: []const u8,
    is_error: bool,
) TranscriptAppend {
    return .{ .tool = .{
        .tool_call_id = tool_call_id,
        .name = name,
        .presentation = toolPresentation(name),
        .status = if (is_error) .err else status,
        .body_mode = toolBodyMode(name),
        .title = title,
    } };
}

fn toolPresentation(name: []const u8) tui.product.transcript.TranscriptToolPresentation {
    if (std.mem.eql(u8, name, "bash")) return .command;
    if (std.mem.eql(u8, name, "read")) return .file;
    if (std.mem.eql(u8, name, "edit")) return .patch;
    if (std.mem.eql(u8, name, "write")) return .file;
    if (std.mem.eql(u8, name, "grep")) return .search;
    if (std.mem.eql(u8, name, "find")) return .directory;
    if (std.mem.eql(u8, name, "ls")) return .directory;
    return .generic;
}

fn toolBodyMode(name: []const u8) tui.product.transcript.TranscriptToolBodyMode {
    if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "edit")) return .hidden_on_success;
    return .visible;
}

fn toolTitle(tool_name: []const u8, args_value: std.json.Value) []const u8 {
    if (std.mem.eql(u8, tool_name, "bash")) return argString(args_value, "command");
    if (std.mem.eql(u8, tool_name, "read") or
        std.mem.eql(u8, tool_name, "edit") or
        std.mem.eql(u8, tool_name, "write") or
        std.mem.eql(u8, tool_name, "ls")) return argString(args_value, "path");
    if (std.mem.eql(u8, tool_name, "grep")) return preferredArg(args_value, "pattern", "path");
    if (std.mem.eql(u8, tool_name, "find")) return preferredArg(args_value, "path", "name");
    return "";
}

fn preferredArg(args_value: std.json.Value, first_key: []const u8, second_key: []const u8) []const u8 {
    const first = argString(args_value, first_key);
    if (first.len != 0) return first;
    return argString(args_value, second_key);
}

fn argString(args_value: std.json.Value, key: []const u8) []const u8 {
    if (args_value != .object) return "";
    const value = args_value.object.get(key) orelse return "";
    if (value != .string) return "";
    return utf8Prefix(value.string, 512);
}

fn firstToolResultText(content: []const ai.ToolResultContent) ?[]const u8 {
    for (content) |item| if (item == .text) return item.text.text;
    return null;
}

fn userText(message: ai.UserMessage) ?[]const u8 {
    return switch (message.content) {
        .string => |text| text,
        .blocks => |blocks| for (blocks) |block| {
            if (block == .text) break block.text.text;
        } else null,
    };
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and (value[end] & 0xc0) == 0x80) : (end -= 1) {}
    return value[0..end];
}

test "tui adapter maps raw text delta into assistant transcript append" {
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .app = undefined,
        .stdout = undefined,
        .stderr = undefined,
        .terminal_loop = try tui.product.TerminalLoop.init(
            std.testing.allocator,
            std.testing.io,
            40,
            8,
            output_size_bytes,
        ),
    };

    const content = [_]ai.AssistantContent{ai.faux.text("hi")};
    const partial = ai.faux.assistantMessage(&content, .{});
    try controller.applyMessageUpdate(.{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "hi",
        .partial = partial,
    } } });
    try std.testing.expectEqual(@as(usize, 1), controller.terminal_loop.product.app.transcript.items.items.len);
    try std.testing.expectEqualStrings(
        "hi",
        controller.terminal_loop.product.app.transcript.items.items[0].message.text,
    );
    controller.terminal_loop.deinit();
}

test "tui adapter renders non-streaming assistant message end" {
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .app = undefined,
        .stdout = undefined,
        .stderr = undefined,
        .terminal_loop = try tui.product.TerminalLoop.init(
            std.testing.allocator,
            std.testing.io,
            40,
            8,
            output_size_bytes,
        ),
    };
    defer controller.terminal_loop.deinit();

    const content = [_]ai.AssistantContent{ai.faux.text("final")};
    const message = ai.faux.assistantMessage(&content, .{});
    try controller.applyMessageEnd(.{ .assistant = message });

    try std.testing.expectEqual(@as(usize, 1), controller.terminal_loop.product.app.transcript.items.items.len);
    try std.testing.expectEqualStrings(
        "final",
        controller.terminal_loop.product.app.transcript.items.items[0].message.text,
    );
}

test "tui adapter splits oversized operational message text" {
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .app = undefined,
        .stdout = undefined,
        .stderr = undefined,
        .terminal_loop = try tui.product.TerminalLoop.init(
            std.testing.allocator,
            std.testing.io,
            40,
            8,
            output_size_bytes,
        ),
    };
    defer controller.terminal_loop.deinit();

    const text = "a" ** (transcript_append_max + 10);
    try controller.appendMessage(.assistant, text, .new_item);

    try std.testing.expectEqual(@as(usize, 1), controller.terminal_loop.product.app.transcript.items.items.len);
    try std.testing.expectEqual(
        @as(usize, text.len),
        controller.terminal_loop.product.app.transcript.items.items[0].message.text.len,
    );
}

test "tui adapter drops invalid operational message text without failing" {
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .app = undefined,
        .stdout = undefined,
        .stderr = undefined,
        .terminal_loop = try tui.product.TerminalLoop.init(
            std.testing.allocator,
            std.testing.io,
            40,
            8,
            output_size_bytes,
        ),
    };
    defer controller.terminal_loop.deinit();

    const invalid = [_]u8{0xff};
    try controller.appendMessage(.assistant, &invalid, .new_item);

    try std.testing.expectEqual(@as(usize, 1), controller.terminal_loop.product.app.transcript.items.items.len);
    try std.testing.expect(controller.terminal_loop.product.app.transcript.items.items[0] == .status);
}

test "tui adapter requests replay and recovers from snapshot after mailbox event gap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var app = try session_runtime.openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .command_capacity = 2,
        .event_capacity = 8,
    });
    defer app.deinit();

    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .app = &app,
        .stdout = undefined,
        .stderr = undefined,
        .terminal_loop = try tui.product.TerminalLoop.init(
            std.testing.allocator,
            std.testing.io,
            40,
            8,
            output_size_bytes,
        ),
    };
    defer controller.terminal_loop.deinit();

    try controller.acceptEnvelope(.{ .seq = 2, .event = .operation_started });
    try std.testing.expectEqual(EventCursor.Recovery.replay_requested, controller.event_cursor.recovery);
    try std.testing.expect(app.hasImmediateWork());
    try std.testing.expectEqual(@as(usize, 1), controller.terminal_loop.product.app.slots.count(.status_area));

    try app.step();
    while (app.drainEvent()) |event| {
        var owned = event;
        owned.deinit(std.testing.allocator);
    }

    try controller.acceptEnvelope(.{ .seq = 3, .event = .{ .replay_gap = .{
        .requested_after = 0,
        .first_retained_seq = 1,
        .last_retained_seq = 0,
    } } });
    try std.testing.expectEqual(EventCursor.Recovery.snapshot_requested, controller.event_cursor.recovery);
    try std.testing.expect(app.hasImmediateWork());

    try app.step();
    var snapshot: ?client_protocol.EventEnvelope = null;
    while (app.drainEvent()) |event| {
        var owned = event;
        if (owned.event == .snapshot) {
            snapshot = owned;
            break;
        }
        owned.deinit(std.testing.allocator);
    }

    var snapshot_event = snapshot.?;
    defer snapshot_event.deinit(std.testing.allocator);
    try controller.acceptEnvelope(snapshot_event);

    try std.testing.expectEqual(EventCursor.Recovery.live, controller.event_cursor.recovery);
    try std.testing.expectEqual(snapshot_event.seq, controller.event_cursor.last_seq);
    try std.testing.expectEqual(@as(usize, 0), controller.terminal_loop.product.app.slots.count(.status_area));
}
