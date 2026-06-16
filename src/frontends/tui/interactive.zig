//! Concrete coding-agent TUI frontend: owns the wake loop, translates
//! ClientEvents into agent-agnostic tui Commands, and feeds tui Effects back
//! as session commands. This is the only module that knows both vocabularies.
const std = @import("std");

const agent_mod = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const client_protocol = coding_agent.client_protocol;
const slash_commands = coding_agent.slash_commands;
const session_listing = coding_agent.session_listing;
const session_runtime = coding_agent.session_runtime;
const runtime = @import("../../runtime/root.zig");
const tui = @import("../../tui/root.zig");
const tool_view = @import("tool_view.zig");

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    resume_session_file: ?[]const u8 = null,
    resume_latest: bool = false,
    initial_prompt: ?[]const u8 = null,
    version: []const u8 = "0.0.0-local",
};

/// Frame pacing: 16ms while something animates (shimmer, tool timers run
/// under an active operation's shimmer), otherwise a slow heartbeat. Session
/// and input wakes interrupt either; an idle zi must not spin.
const frame_interval_ms: u64 = 16;
const idle_frame_interval_ms: u64 = 30_000;

const effect_count_max = tui.Terminal.effects_per_read_max;
const client_events_per_tick_max = 64;
const status_id_working: tui.status.ContributionId = 1;
const status_id_queue: tui.status.ContributionId = 2;
const status_id_recovery: tui.status.ContributionId = 3;
const composer_cwd_slot_id: tui.status.ContributionId = 1;
const composer_session_slot_id: tui.status.ContributionId = 2;
const model_picker_id: tui.Picker.Id = 1;
const command_completion_picker_id: tui.Picker.Id = 2;
const transcript_append_max = tui.Transcript.append_size_bytes_max;
const tool_timer_count_max = 8;
const tool_timer_id_bytes_max = 96;

fn nextWakeDelayMs(immediate_work_pending: bool, animation_active: bool) u64 {
    if (immediate_work_pending) return 0;
    return if (animation_active) frame_interval_ms else idle_frame_interval_ms;
}

fn resolveTerminalInfo(process: runtime.Process) tui.theme.TerminalInfo {
    return .{
        .scheme = if (process.env("ZI_THEME_LIGHT") != null) .light else null,
        .color_level = resolveColorLevel(process),
    };
}

fn resolveColorLevel(process: runtime.Process) tui.theme.ColorLevel {
    if (process.env("COLORTERM")) |value| {
        if (std.mem.indexOf(u8, value, "truecolor") != null) return .truecolor;
        if (std.mem.indexOf(u8, value, "24bit") != null) return .truecolor;
    }
    if (process.env("TERM")) |value| {
        if (std.mem.indexOf(u8, value, "256color") != null) return .ansi256;
    }
    return .unknown;
}

const ToolTimer = struct {
    id: [tool_timer_id_bytes_max]u8 = undefined,
    id_len: u8,
    started_ms: i64,
    footer_elapsed_s: u64 = 0,
};

fn ignoreBestEffortError(err: anyerror) void {
    std.debug.assert(@errorName(err).len > 0);
}

const SubmitResult = enum { queued, queue_full };

const EventCursor = struct {
    last_seq: client_protocol.EventSeq = 0,
    recovery: Recovery = .live,

    const Recovery = enum { live, replay_requested, snapshot_requested };
};

const RenderThrottle = struct {
    next_render_ms: i64 = 0,
    force: bool = true,

    fn requestImmediate(self: *RenderThrottle) void {
        self.force = true;
    }

    fn shouldRender(self: *RenderThrottle, now_ms: i64, coalesce: bool) bool {
        if (!self.force and coalesce and now_ms < self.next_render_ms) return false;
        self.force = false;
        self.next_render_ms = now_ms + @as(i64, @intCast(frame_interval_ms));
        return true;
    }
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

    var controller = try InteractiveController.init(
        process,
        &app,
        stdout,
        stderr,
        options.initial_prompt,
        options.version,
    );
    defer controller.deinit();
    try controller.run();
}

const InteractiveController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    terminal: *tui.Terminal,
    cancel_requested: bool = false,
    operation_active: bool = false,
    history_oldest_entry_id: ?[]u8 = null,
    history_has_more_before: bool = false,
    history_request_in_flight: bool = false,
    event_cursor: EventCursor = .{},
    assistant_text_delta_seen: bool = false,
    render_throttle: RenderThrottle = .{},
    tool_timers: [tool_timer_count_max]?ToolTimer = @splat(null),
    home_dir: ?[]const u8 = null,

    fn init(
        process: runtime.Process,
        app: *session_runtime.SessionRuntime,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        initial_prompt: ?[]const u8,
        version: []const u8,
    ) !InteractiveController {
        const terminal_info = resolveTerminalInfo(process);
        const terminal = try tui.Terminal.init(process.gpa, process.io, 80, 24, terminal_info);
        errdefer terminal.deinit();
        try terminal.setup();
        errdefer terminal.shutdown() catch |err| ignoreBestEffortError(err);

        var self: InteractiveController = .{
            .allocator = process.gpa,
            .io = process.io,
            .app = app,
            .stdout = stdout,
            .stderr = stderr,
            .terminal = terminal,
            .home_dir = process.env("HOME") orelse process.env("USERPROFILE"),
        };
        try self.installGreeter(version);
        try self.installSlashCompletions();
        try self.installModelCompletions();
        try self.requestSnapshot();
        if (initial_prompt) |prompt| try self.submitPrompt(prompt);
        try self.terminal.renderIfDirty();
        return self;
    }

    fn deinit(self: *InteractiveController) void {
        if (self.history_oldest_entry_id) |id| self.allocator.free(id);
        self.terminal.shutdown() catch |err| ignoreBestEffortError(err);
        self.terminal.deinit();
        self.* = undefined;
    }

    fn run(self: *InteractiveController) !void {
        while (self.terminal.isRunning()) {
            const immediate = try self.serviceImmediateWork();
            if (!self.terminal.isRunning()) break;

            const frame_active = self.terminal.hasAnimation() or (self.operation_active and self.terminal.isDirty());
            const wake = try self.app.waitAndApplyWake(
                self.terminal.inputFd(),
                nextWakeDelayMs(immediate, frame_active),
            );
            // Time enters the product through ticks; refresh before handling
            // the wake so wall-clock policies (ctrl+c double press, shimmer)
            // never see stale time after a long idle wait.
            _ = try self.tickTime();
            switch (wake) {
                .input => try self.drainInput(),
                .session, .frame => {},
            }
        }
    }

    fn serviceImmediateWork(self: *InteractiveController) !bool {
        try self.app.step();
        const drained = try self.drainClientEventsBounded(client_events_per_tick_max);
        const now_ms = try self.tickTime();
        try self.renderIfDue(now_ms);
        return drained == client_events_per_tick_max or self.app.hasImmediateWork();
    }

    fn renderIfDue(self: *InteractiveController, now_ms: i64) !void {
        if (!self.terminal.isDirty()) return;
        if (!self.render_throttle.shouldRender(now_ms, self.operation_active)) return;
        try self.terminal.renderIfDirty();
    }

    fn drainInput(self: *InteractiveController) !void {
        var effects: [effect_count_max]tui.Effect = undefined;
        const result = try self.terminal.readAvailableInput(&effects);
        defer for (effects[0..result.effect_count]) |effect| effect.deinit(self.allocator);
        for (effects[0..result.effect_count]) |effect| try self.handleEffect(effect);
        if (result.event_count > 0) self.render_throttle.requestImmediate();
        if (result.truncated) try self.appendStatus(.warning, "input truncated");
        if (result.effect_overflow) try self.appendStatus(.warning, "input effects dropped");
    }

    fn handleEffect(self: *InteractiveController, effect: tui.Effect) !void {
        switch (effect) {
            .submit_text => |text| if (!try self.handleSubmittedCommand(text)) try self.submitPrompt(text),
            .picker_selected => |selection| try self.handlePickerSelection(selection),
            .interrupt => try self.cancelActive(),
            .request_transcript_history => try self.requestHistoryPage(),
            .request_shutdown => {
                if (try self.submitCommand(.{ .command = .shutdown }) == .queued) {
                    self.terminal.requestStop();
                }
            },
        }
    }

    fn handleSubmittedCommand(self: *InteractiveController, text: []const u8) !bool {
        const model_query = parseModelCommand(text) orelse return false;
        if (model_query.len > 0 and isExactModelSelector(model_query)) return false;
        try self.editModelCommand(model_query);
        return true;
    }

    fn handlePickerSelection(self: *InteractiveController, selection: tui.Picker.Selection) !void {
        switch (selection.picker_id) {
            model_picker_id => try self.submitSelectedModel(selection.item_id),
            else => {},
        }
    }

    fn submitSelectedModel(self: *InteractiveController, item_id: []const u8) !void {
        var buffer: [tui.Picker.id_bytes_max + 8]u8 = undefined;
        const prompt = std.fmt.bufPrint(&buffer, "/model {s}", .{item_id}) catch return;
        try self.submitPrompt(prompt);
    }

    fn editModelCommand(self: *InteractiveController, query: []const u8) !void {
        var buffer: [tui.Picker.query_bytes_max + 8]u8 = undefined;
        const text = if (query.len == 0)
            "/model "
        else
            std.fmt.bufPrint(&buffer, "/model {s}", .{query}) catch "/model ";
        _ = try self.terminal.applyCommand(.{ .replace_composer_text = text });
    }

    fn installGreeter(self: *InteractiveController, version: []const u8) !void {
        var title: [tui.Greeter.text_bytes_max]u8 = undefined;
        const title_text = std.fmt.bufPrint(&title, "zi {s}", .{version}) catch "zi";
        _ = try self.terminal.applyCommand(.{ .set_greeter = .{
            .title = title_text,
            .subtitle = "Type / for commands. Ask zi about zi if you get lost.",
        } });
    }

    fn installModelCompletions(self: *InteractiveController) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        var items = std.ArrayList(tui.Picker.Item).empty;
        defer items.deinit(self.allocator);

        outer: for (ai.getProviders()) |provider| {
            const authed = self.app.services.auth_manager.hasAuth(provider);
            for (ai.getModels(provider)) |model| {
                if (items.items.len == tui.Picker.item_count_max) break :outer;
                const id = try std.fmt.allocPrint(arena_allocator, "{s}/{s}", .{ model.provider, model.id });
                const available = self.app.services.provider_registry.get(model.api) != null;
                const detail = if (!available)
                    try std.fmt.allocPrint(arena_allocator, "{s} - unavailable", .{model.name})
                else if (authed)
                    try std.fmt.allocPrint(arena_allocator, "{s} - ready", .{model.name})
                else
                    try std.fmt.allocPrint(arena_allocator, "{s} - missing auth", .{model.name});
                try items.append(self.allocator, .{ .id = id, .label = id, .detail = detail });
            }
        }

        _ = try self.terminal.applyCommand(.{ .set_composer_arg_completions = .{
            .command_name = "model",
            .picker = .{
                .id = model_picker_id,
                .items = items.items,
            },
        } });
    }

    fn installSlashCompletions(self: *InteractiveController) !void {
        var items: [slash_commands.command_count_max]tui.Picker.Item = undefined;
        var labels: [slash_commands.command_count_max][1 + slash_commands.name_bytes_max]u8 = undefined;
        for (slash_commands.builtins, 0..) |command, index| {
            labels[index][0] = '/';
            @memcpy(labels[index][1..][0..command.name.len], command.name);
            items[index] = .{
                .id = command.name,
                .label = labels[index][0 .. 1 + command.name.len],
                .detail = command.summary,
            };
        }
        _ = try self.terminal.applyCommand(.{ .set_composer_completions = .{
            .id = command_completion_picker_id,
            .items = items[0..slash_commands.builtins.len],
        } });
    }

    fn submitPrompt(self: *InteractiveController, prompt: []const u8) !void {
        const envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(self.allocator, null, prompt, .auto);
        if (try self.submitCommand(envelope) == .queued) self.cancel_requested = false;
    }

    fn cancelActive(self: *InteractiveController) !void {
        if (self.cancel_requested) return;
        if (try self.submitCommand(.{ .command = .{ .cancel = .{} } }) == .queued) {
            self.cancel_requested = true;
            try self.appendStatusWithTone(.info, "cancel requested", .canceled);
        }
    }

    fn requestSnapshot(self: *InteractiveController) !void {
        _ = try self.submitCommand(.{ .command = .snapshot });
    }

    fn requestReplay(self: *InteractiveController, after: client_protocol.EventSeq) !void {
        _ = try self.submitCommand(.{ .command = .{ .replay = .{ .after = after } } });
    }

    fn requestHistoryPage(self: *InteractiveController) !void {
        if (self.operation_active or self.history_request_in_flight or !self.history_has_more_before) return;
        const before_entry_id = self.history_oldest_entry_id orelse return self.requestSnapshot();
        const envelope = try client_protocol.CommandEnvelope.initHistoryPage(self.allocator, null, before_entry_id);
        if (try self.submitCommand(envelope) == .queued) self.history_request_in_flight = true;
    }

    fn submitCommand(self: *InteractiveController, envelope: client_protocol.CommandEnvelope) !SubmitResult {
        var owned = envelope;
        self.app.submit(owned) catch |err| switch (err) {
            error.Full => {
                owned.deinit(self.allocator);
                try self.appendStatus(.err, "command queue full");
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
            .operation_started => {
                self.operation_active = true;
                try self.setWorkingStatus("working");
            },
            .operation_finished => |finished| {
                self.operation_active = false;
                try self.applyOperationFinished(finished);
            },
            .rejected => |rejection| {
                self.history_request_in_flight = false;
                try self.appendStatus(.err, rejection.message.text);
            },
            .prompt_command => |command| {
                switch (command.presentation) {
                    .transcript => if (command.session_info) |info|
                        try self.appendSessionInfo(info)
                    else
                        try self.appendCustom("Command", command.message.text, .markdown),
                    .status => try self.appendStatus(
                        if (command.result == .handled) .info else .warning,
                        command.message.text,
                    ),
                }
            },
            .queue_changed => |queue| try self.applyQueueChanged(queue),
            .snapshot => |snapshot| try self.applySnapshot(snapshot),
            .session_chrome => |chrome| try self.applySessionChrome(chrome),
            .history_page => |page| try self.applyHistoryPage(page),
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
            .shutdown_started => self.terminal.requestStop(),
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
                if (assistant.error_message) |message_text| {
                    if (!self.cancel_requested) try self.appendStatus(.err, message_text);
                }
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
        var buffers: tool_view.TitleBuffers = .{};
        try self.appendTool(tool_view.callAppend(&buffers, tool_call, self.home_dir));
        if (tool_view.callPreviewText(tool_call.name, tool_call.arguments)) |preview| {
            try self.replaceToolOutput(tool_call.id, preview);
            var footer_buffer: [tool_view.footer_bytes_max]u8 = undefined;
            try self.replaceToolFooter(
                tool_call.id,
                tool_view.callPreviewFooter(&footer_buffer, tool_call.name, tool_call.arguments),
            );
        }
    }

    fn applyToolStart(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionStart) !void {
        var buffers: tool_view.TitleBuffers = .{};
        try self.appendTool(tool_view.startAppend(&buffers, payload, self.home_dir));
        if (tool_view.clearsCallPreviewOnStart(payload.tool_name)) {
            try self.replaceToolOutput(payload.tool_call_id, "");
        }
        if (tool_view.showsDuration(payload.tool_name)) self.startToolTimer(payload.tool_call_id);
    }

    fn applyToolUpdate(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
        const text = tool_view.firstResultText(payload.partial_result.content) orelse return;
        try self.appendToolOutput(payload.tool_call_id, text);
    }

    fn applyToolEnd(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
        var metadata_buffer: [tool_view.metadata_bytes_max]u8 = undefined;
        var view = try tool_view.finish(self.allocator, &metadata_buffer, payload);
        defer view.deinit(self.allocator);

        try self.appendTool(tool_view.endAppend(payload));

        var duration_buffer: [64]u8 = undefined;
        const duration = self.finishToolTimer(payload.tool_call_id, &duration_buffer) orelse "";
        var footer_buffer: [tool_view.footer_bytes_max]u8 = undefined;
        const footer = tool_view.joinMetadata(&footer_buffer, view.metadata, duration);
        if (footer.len > 0) {
            try self.replaceToolFooter(payload.tool_call_id, footer);
        } else if (payload.is_error) {
            try self.replaceToolFooter(payload.tool_call_id, "");
        }

        const text = view.output orelse return;
        try self.replaceToolOutput(payload.tool_call_id, text);
    }

    fn applySnapshot(self: *InteractiveController, snapshot: client_protocol.Snapshot) !void {
        _ = try self.terminal.applyCommand(.clear_transcript);
        self.operation_active = snapshot.active_request_id != null;
        self.history_request_in_flight = false;
        // Snapshot history can be wider than the TUI resident item cap. Track
        // the oldest item the TUI will actually retain after append eviction,
        // otherwise the next page would skip the evicted snapshot prefix.
        const retained_start = snapshot.history.items.len -| tui.Transcript.item_count_max;
        self.history_has_more_before = snapshot.history.dropped_items > 0 or retained_start > 0;
        if (snapshot.history.items.len > 0) {
            try self.setOldestHistoryEntryId(snapshot.history.items[retained_start].entry_id.text);
        } else {
            self.clearOldestHistoryEntryId();
        }
        try self.applySessionChromeParts(
            snapshot.header.cwd.text,
            snapshot.model,
            snapshot.thinking_level,
            snapshot.context,
        );
        for (snapshot.history.items) |item| {
            const role: tui.Transcript.Role = switch (item.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
            };
            try self.appendMessage(role, item.text.text, .new_item);
        }
        try self.applyQueueCounts(snapshot.queue.steering.items.len, snapshot.queue.follow_up.items.len);
    }

    fn applySessionChrome(self: *InteractiveController, chrome: client_protocol.SessionChromeSnapshot) !void {
        try self.applySessionChromeParts(
            chrome.cwd.text,
            chrome.model,
            chrome.thinking_level,
            chrome.context,
        );
    }

    fn applySessionChromeParts(
        self: *InteractiveController,
        cwd: []const u8,
        model: client_protocol.ModelSnapshot,
        thinking_level: agent_mod.ThinkingLevel,
        context: client_protocol.ContextUsageSnapshot,
    ) !void {
        var left_buffer: [tui.status.text_bytes_max]u8 = undefined;
        var right_buffer: [tui.status.text_bytes_max]u8 = undefined;
        const resolved_dot_cwd = if (std.mem.eql(u8, cwd, "."))
            std.Io.Dir.realPathFileAlloc(.cwd(), self.io, ".", self.allocator) catch null
        else
            null;
        defer if (resolved_dot_cwd) |path| self.allocator.free(path);
        const cwd_text = formatComposerCwd(&left_buffer, resolved_dot_cwd orelse cwd, self.home_dir);
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .composer_left,
            .id = composer_cwd_slot_id,
            .priority = 1,
            .text = cwd_text,
        } });
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .composer_right,
            .id = composer_session_slot_id,
            .priority = 1,
            .text = formatComposerRight(&right_buffer, model, thinking_level, context),
        } });
    }

    fn applyHistoryPage(self: *InteractiveController, page: client_protocol.HistoryPage) !void {
        self.history_request_in_flight = false;
        self.history_has_more_before = page.has_more_before;
        if (page.items.len == 0) return;

        try self.setOldestHistoryEntryId(page.items[0].entry_id.text);
        var index = page.items.len;
        while (index > 0) {
            index -= 1;
            const item = page.items[index];
            const role: tui.Transcript.Role = switch (item.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
            };
            _ = try self.terminal.applyCommand(.{ .prepend_transcript = .{
                .role = role,
                .text = item.text.text,
                .mode = .new_item,
            } });
        }
    }

    fn setOldestHistoryEntryId(self: *InteractiveController, entry_id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, entry_id);
        if (self.history_oldest_entry_id) |old| self.allocator.free(old);
        self.history_oldest_entry_id = owned;
    }

    fn clearOldestHistoryEntryId(self: *InteractiveController) void {
        if (self.history_oldest_entry_id) |old| self.allocator.free(old);
        self.history_oldest_entry_id = null;
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
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_queue,
            .priority = 1,
            .text = text,
        } });
    }

    fn applyOperationFinished(self: *InteractiveController, finished: client_protocol.OperationFinished) !void {
        self.cancel_requested = false;
        self.clearToolTimers();
        try self.clearStatus(status_id_working);
        switch (finished.reason) {
            .completed => {},
            .canceled => try self.appendStatusWithTone(.info, "canceled", .canceled),
            .failed => try self.appendStatus(.err, "operation failed"),
        }
    }

    /// Append in transcript-cap-sized chunks. Sanitization (invalid UTF-8,
    /// split codepoints) is the transcript's job; chunk boundaries fall back
    /// to raw bytes when no UTF-8 boundary exists in range.
    fn appendMessage(
        self: *InteractiveController,
        role: tui.Transcript.Role,
        text: []const u8,
        mode: tui.Transcript.AppendMode,
    ) !void {
        if (text.len == 0) return;
        var remaining = text;
        var chunk_mode = mode;
        while (remaining.len > 0) {
            const chunk = boundedChunk(remaining);
            _ = try self.terminal.applyCommand(.{ .append_transcript = .{ .message = .{
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

    fn appendTool(self: *InteractiveController, tool: tui.Transcript.Append.ToolAppend) !void {
        _ = try self.terminal.applyCommand(.{ .append_transcript = .{ .tool = tool } });
    }

    /// Final tool result replaces the streamed preview (pi-mono semantics):
    /// the first normalized chunk overwrites, remaining chunks append.
    fn replaceToolOutput(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        var buffer: [transcript_append_max]u8 = undefined;
        const first = tool_view.normalizedOutputChunk(&buffer, text);
        _ = try self.terminal.applyCommand(.{ .replace_tool_output = .{
            .tool_call_id = tool_call_id,
            .text = first.text,
        } });
        try self.appendToolOutput(tool_call_id, text[first.consumed..]);
    }

    fn appendToolOutput(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        var remaining = text;
        while (remaining.len > 0) {
            var buffer: [transcript_append_max]u8 = undefined;
            const chunk = tool_view.normalizedOutputChunk(&buffer, remaining);
            if (chunk.consumed == 0) return;
            if (chunk.text.len > 0) {
                _ = try self.terminal.applyCommand(.{ .tool_output_delta = .{
                    .tool_call_id = tool_call_id,
                    .text = chunk.text,
                } });
            }
            remaining = remaining[chunk.consumed..];
        }
    }

    fn appendStatus(
        self: *InteractiveController,
        level: tui.Transcript.StatusLevel,
        text: []const u8,
    ) !void {
        try self.appendStatusWithTone(level, text, switch (level) {
            .info => .accent,
            .warning => .warning,
            .err => .err,
        });
    }

    fn appendStatusWithTone(
        self: *InteractiveController,
        level: tui.Transcript.StatusLevel,
        text: []const u8,
        tone: tui.status.Tone,
    ) !void {
        if (text.len == 0) return;
        var buffer: [tui.status.text_bytes_max]u8 = undefined;
        const display = switch (level) {
            .info => text,
            .warning => std.fmt.bufPrint(&buffer, "warning: {s}", .{text}) catch text,
            .err => std.fmt.bufPrint(&buffer, "error: {s}", .{text}) catch text,
        };
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 10,
            .text = boundedChunk(display),
            .effect = .shuffle,
            .tone = tone,
        } });
    }

    fn appendSessionInfo(
        self: *InteractiveController,
        info: client_protocol.PromptCommandSessionInfo,
    ) !void {
        var buffer: [2048]u8 = undefined;
        try self.appendCustom("Session Info", formatSessionInfo(&buffer, info), .markdown);
    }

    fn appendCustom(
        self: *InteractiveController,
        title: []const u8,
        text: []const u8,
        format: tui.Transcript.CustomFormat,
    ) !void {
        if (title.len == 0 and text.len == 0) return;
        _ = try self.terminal.applyCommand(.{ .append_transcript = .{ .custom = .{
            .title = title,
            .text = boundedChunk(text),
            .format = format,
        } } });
    }

    fn setWorkingStatus(self: *InteractiveController, text: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 10,
            .text = text,
            .effect = .shimmer,
        } });
    }

    fn setRecoveryStatus(self: *InteractiveController, text: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_recovery,
            .priority = 9,
            .text = text,
            .effect = .shimmer,
        } });
    }

    fn clearStatus(self: *InteractiveController, id: tui.status.ContributionId) !void {
        _ = try self.terminal.applyCommand(.{ .clear_status = .{ .slot = .status_line, .id = id } });
    }

    fn tickTime(self: *InteractiveController) !i64 {
        const now_ms = self.nowMs();
        _ = try self.terminal.applyCommand(.{ .tick = .{ .now_ms = now_ms } });
        try self.tickToolTimers();
        return now_ms;
    }

    fn nowMs(self: *InteractiveController) i64 {
        return @intCast(@divTrunc(std.Io.Clock.awake.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    fn startToolTimer(self: *InteractiveController, tool_call_id: []const u8) void {
        if (tool_call_id.len == 0 or tool_call_id.len > tool_timer_id_bytes_max) return;
        if (self.findToolTimer(tool_call_id) != null) return;
        for (&self.tool_timers) |*slot| {
            if (slot.* != null) continue;
            var timer: ToolTimer = .{ .id_len = @intCast(tool_call_id.len), .started_ms = self.nowMs() };
            @memcpy(timer.id[0..tool_call_id.len], tool_call_id);
            slot.* = timer;
            return;
        }
        // Table full: the tool simply runs without a duration footer.
    }

    fn findToolTimer(self: *InteractiveController, tool_call_id: []const u8) ?*ToolTimer {
        for (&self.tool_timers) |*slot| {
            if (slot.*) |*timer| {
                if (std.mem.eql(u8, timer.id[0..timer.id_len], tool_call_id)) return timer;
            }
        }
        return null;
    }

    fn finishToolTimer(self: *InteractiveController, tool_call_id: []const u8, buffer: []u8) ?[]const u8 {
        const timer = self.findToolTimer(tool_call_id) orelse return null;
        const text = self.toolDurationChip(buffer, "Took", timer.started_ms);
        self.removeToolTimer(tool_call_id);
        return text;
    }

    fn removeToolTimer(self: *InteractiveController, tool_call_id: []const u8) void {
        for (&self.tool_timers) |*slot| {
            if (slot.*) |*timer| {
                if (std.mem.eql(u8, timer.id[0..timer.id_len], tool_call_id)) slot.* = null;
            }
        }
    }

    fn clearToolTimers(self: *InteractiveController) void {
        self.tool_timers = @splat(null);
    }

    fn tickToolTimers(self: *InteractiveController) !void {
        for (&self.tool_timers) |*slot| {
            const timer = if (slot.*) |*value| value else continue;
            const elapsed_ms = self.nowMs() - timer.started_ms;
            const elapsed_s: u64 = if (elapsed_ms > 0) @intCast(@divTrunc(elapsed_ms, std.time.ms_per_s)) else 0;
            if (elapsed_s == timer.footer_elapsed_s) continue;
            timer.footer_elapsed_s = elapsed_s;
            var buffer: [64]u8 = undefined;
            const text = self.toolDurationChip(&buffer, "Elapsed", timer.started_ms);
            try self.replaceToolFooter(timer.id[0..timer.id_len], text);
        }
    }

    fn toolDurationChip(self: *InteractiveController, buffer: []u8, label: []const u8, started_ms: i64) []const u8 {
        const elapsed_ms: u64 = @intCast(@max(0, self.nowMs() - started_ms));
        return tool_view.durationChip(buffer, label, elapsed_ms);
    }

    fn replaceToolFooter(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .replace_tool_footer = .{
            .tool_call_id = tool_call_id,
            .text = text,
        } });
    }
};

/// Largest prefix that fits one transcript append, preferring a UTF-8
/// boundary; falls back to a raw cut when the head has no boundary (the
/// transcript sanitizes whatever arrives).
fn boundedChunk(text: []const u8) []const u8 {
    const prefix = tui.text.utf8Prefix(text, transcript_append_max);
    if (prefix.len > 0) return prefix;
    return text[0..@min(text.len, transcript_append_max)];
}

fn formatComposerRight(
    buffer: []u8,
    model: client_protocol.ModelSnapshot,
    thinking_level: agent_mod.ThinkingLevel,
    context: client_protocol.ContextUsageSnapshot,
) []const u8 {
    var context_buffer: [32]u8 = undefined;
    const context_text = formatContextUsage(&context_buffer, context);
    return std.fmt.bufPrint(buffer, "{s} • {s}/{s} ({s})", .{
        context_text,
        model.provider.text,
        model.id.text,
        thinkingLevelName(thinking_level),
    }) catch model.id.text;
}

fn formatComposerCwd(buffer: []u8, cwd: []const u8, home_dir_raw: ?[]const u8) []const u8 {
    const suffix = homePathSuffix(cwd, home_dir_raw) orelse return cwd;
    if (suffix.len == 0) return "~";
    return std.fmt.bufPrint(buffer, "~{s}", .{suffix}) catch cwd;
}

fn homePathSuffix(path: []const u8, home_dir_raw: ?[]const u8) ?[]const u8 {
    const home_dir = trimTrailingPathSeparators(home_dir_raw orelse return null);
    if (home_dir.len == 0) return null;
    if (std.mem.eql(u8, path, home_dir)) return "";
    if (!std.mem.startsWith(u8, path, home_dir)) return null;
    if (path.len <= home_dir.len or !isPathSeparator(path[home_dir.len])) return null;
    return path[home_dir.len..];
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn formatContextUsage(buffer: []u8, context: client_protocol.ContextUsageSnapshot) []const u8 {
    var window_buffer: [24]u8 = undefined;
    const window = if (context.window == 0) "?" else formatTokenCount(&window_buffer, context.window);
    if (context.percent_tenths) |tenths| {
        return std.fmt.bufPrint(buffer, "{d}.{d}%/{s}", .{ tenths / 10, tenths % 10, window }) catch "?/?";
    }
    return std.fmt.bufPrint(buffer, "?/{s}", .{window}) catch "?/?";
}

fn formatTokenCount(buffer: []u8, tokens: u64) []const u8 {
    if (tokens >= 1000) return std.fmt.bufPrint(buffer, "{d}k", .{(tokens + 500) / 1000}) catch "?";
    return std.fmt.bufPrint(buffer, "{d}", .{tokens}) catch "?";
}

fn thinkingLevelName(level: agent_mod.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn formatSessionInfo(buffer: []u8, info: client_protocol.PromptCommandSessionInfo) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (info.file) |file| {
        writer.print("File: {s}\n", .{file.text}) catch return "session status unavailable";
    } else {
        writer.writeAll("File: In-memory\n") catch return "session status unavailable";
    }
    writer.print("ID: {s}\n\n", .{info.id.text}) catch return "session status unavailable";
    writer.writeAll("**Messages**\n") catch return "session status unavailable";
    writer.print("User: {d}\n", .{info.user_messages}) catch return "session status unavailable";
    writer.print("Assistant: {d}\n", .{info.assistant_messages}) catch return "session status unavailable";
    writer.print("Tool Calls: {d}\n", .{info.tool_calls}) catch return "session status unavailable";
    writer.print("Tool Results: {d}\n", .{info.tool_results}) catch return "session status unavailable";
    writer.print("Total: {d}\n\n", .{info.total_messages}) catch return "session status unavailable";
    writer.writeAll("**Tokens**\n") catch return "session status unavailable";
    writer.print("Input: {d}\n", .{info.input_tokens}) catch return "session status unavailable";
    writer.print("Output: {d}\n", .{info.output_tokens}) catch return "session status unavailable";
    if (info.cache_read_tokens > 0) {
        writer.print("Cache Read: {d}\n", .{info.cache_read_tokens}) catch return "session status unavailable";
    }
    if (info.cache_write_tokens > 0) {
        writer.print("Cache Write: {d}\n", .{info.cache_write_tokens}) catch return "session status unavailable";
    }
    writer.print("Total: {d}", .{info.total_tokens}) catch return "session status unavailable";
    if (info.cost > 0) {
        writer.print("\n\n**Cost**\nTotal: {d:.4}", .{info.cost}) catch return "session status unavailable";
    }
    return writer.buffered();
}

fn parseModelCommand(text: []const u8) ?[]const u8 {
    const invocation = slash_commands.parseInvocation(text) orelse return null;
    const spec = slash_commands.lookup(invocation.name) orelse return null;
    if (spec.id != .model) return null;
    return invocation.args;
}

fn isExactModelSelector(selector: []const u8) bool {
    if (selector.len == 0) return false;
    if (std.mem.findScalar(u8, selector, '/')) |slash| {
        if (slash == 0 or slash + 1 >= selector.len) return false;
        return ai.getModel(selector[0..slash], selector[slash + 1 ..]) != null;
    }
    var found = false;
    for (ai.getProviders()) |provider| {
        for (ai.getModels(provider)) |model| {
            if (!std.mem.eql(u8, model.id, selector)) continue;
            if (found) return false;
            found = true;
        }
    }
    return found;
}

test "model slash parser distinguishes exact selection from picker search" {
    try std.testing.expectEqualStrings("", parseModelCommand("/model").?);
    try std.testing.expectEqualStrings("gpt", parseModelCommand("/model gpt").?);
    try std.testing.expect(parseModelCommand("/modelx") == null);
    try std.testing.expect(isExactModelSelector("openai/gpt-5.1"));
    try std.testing.expect(!isExactModelSelector("openai/nope"));
}

test "immediate TUI work polls instead of starving input" {
    try std.testing.expectEqual(@as(u64, 0), nextWakeDelayMs(true, false));
    try std.testing.expectEqual(@as(u64, frame_interval_ms), nextWakeDelayMs(false, true));
    try std.testing.expectEqual(@as(u64, idle_frame_interval_ms), nextWakeDelayMs(false, false));
}

test "render throttle coalesces active streaming but lets input render immediately" {
    var throttle: RenderThrottle = .{};
    try std.testing.expect(throttle.shouldRender(100, true));
    try std.testing.expect(!throttle.shouldRender(101, true));
    try std.testing.expect(throttle.shouldRender(101, false));
    try std.testing.expect(!throttle.shouldRender(102, true));
    throttle.requestImmediate();
    try std.testing.expect(throttle.shouldRender(102, true));
    try std.testing.expect(!throttle.shouldRender(103, true));
    try std.testing.expect(throttle.shouldRender(102 + @as(i64, @intCast(frame_interval_ms)), true));
}

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

fn userText(message: ai.UserMessage) ?[]const u8 {
    return switch (message.content) {
        .string => |text| text,
        .blocks => |blocks| for (blocks) |block| {
            if (block == .text) break block.text.text;
        } else null,
    };
}

test "composer cwd display shortens home paths" {
    var buffer: [tui.status.text_bytes_max]u8 = undefined;

    try std.testing.expectEqualStrings("~", formatComposerCwd(&buffer, "/Users/me", "/Users/me"));
    try std.testing.expectEqualStrings("~/repo", formatComposerCwd(&buffer, "/Users/me/repo", "/Users/me"));
    try std.testing.expectEqualStrings("~/repo", formatComposerCwd(&buffer, "/Users/me/repo", "/Users/me/"));
    try std.testing.expectEqualStrings("/Users/meg/repo", formatComposerCwd(&buffer, "/Users/meg/repo", "/Users/me"));
    try std.testing.expectEqualStrings("/repo", formatComposerCwd(&buffer, "/repo", null));
}
