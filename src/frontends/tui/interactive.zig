//! Concrete coding-agent TUI frontend: owns the wake loop, translates
//! ClientEvents into agent-agnostic tui Commands, and feeds tui Effects back
//! as session commands. This is the only module that knows both vocabularies.
const std = @import("std");

const agent_mod = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const client_protocol = coding_agent.client_protocol;
const slash_commands = coding_agent.slash_commands;
const tool_metadata = coding_agent.tool_metadata;
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
const tool_title_bytes_max = 160;
const tool_timer_count_max = 8;
const tool_timer_id_bytes_max = 96;

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
    tool_timers: [tool_timer_count_max]?ToolTimer = @splat(null),
    home_dir: ?[]const u8 = null,

    fn init(
        process: runtime.Process,
        app: *session_runtime.SessionRuntime,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        initial_prompt: ?[]const u8,
    ) !InteractiveController {
        const terminal = try tui.Terminal.init(process.gpa, process.io, 80, 24);
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
            if (try self.serviceImmediateWork()) continue;

            const frame_ms: u64 = if (self.terminal.hasAnimation())
                frame_interval_ms
            else
                idle_frame_interval_ms;
            const wake = try self.app.waitAndApplyWake(self.terminal.inputFd(), frame_ms);
            // Time enters the product through ticks; refresh before handling
            // the wake so wall-clock policies (ctrl+c double press, shimmer)
            // never see stale time after a long idle wait.
            try self.tickTime();
            switch (wake) {
                .input => try self.drainInput(),
                .session, .frame => {},
            }
            _ = try self.serviceImmediateWork();
        }
    }

    fn serviceImmediateWork(self: *InteractiveController) !bool {
        try self.app.step();
        const drained = try self.drainClientEventsBounded(client_events_per_tick_max);
        try self.tickTime();
        try self.terminal.renderIfDirty();
        return drained == client_events_per_tick_max or self.app.hasImmediateWork();
    }

    fn drainInput(self: *InteractiveController) !void {
        var effects: [effect_count_max]tui.Effect = undefined;
        const result = try self.terminal.readAvailableInput(&effects);
        defer for (effects[0..result.effect_count]) |effect| effect.deinit(self.allocator);
        for (effects[0..result.effect_count]) |effect| try self.handleEffect(effect);
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
                .title = "Models",
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
            .title = "Commands",
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
            try self.appendStatus(.warning, "cancel requested");
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
        var title_buffer: [tool_title_bytes_max]u8 = undefined;
        var compact_title_buffer: [tool_title_bytes_max]u8 = undefined;
        try self.appendTool(.{
            .tool_call_id = tool_call.id,
            .name = tool_call.name,
            .presentation = toolPresentation(tool_call.name),
            .status = .pending,
            .body_mode = toolBodyMode(tool_call.name),
            .collapse = toolCollapse(tool_call.name),
            .title = formatCallTitleWithHome(&title_buffer, tool_call.name, tool_call.arguments, self.home_dir),
            .compact_title = formatCompactCallTitle(
                &compact_title_buffer,
                tool_call.name,
                tool_call.arguments,
            ),
        });
        if (toolCallPreviewText(tool_call.name, tool_call.arguments)) |preview| {
            try self.replaceToolOutput(tool_call.id, preview);
        }
    }

    fn applyToolStart(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionStart) !void {
        var title_buffer: [tool_title_bytes_max]u8 = undefined;
        var compact_title_buffer: [tool_title_bytes_max]u8 = undefined;
        try self.appendTool(toolAppend(
            payload.tool_call_id,
            payload.tool_name,
            .pending,
            formatCallTitleWithHome(&title_buffer, payload.tool_name, payload.args, self.home_dir),
            formatCompactCallTitle(&compact_title_buffer, payload.tool_name, payload.args),
            false,
        ));
        if (toolClearsCallPreviewOnStart(payload.tool_name)) {
            try self.replaceToolOutput(payload.tool_call_id, "");
        }
        if (toolShowsDuration(payload.tool_name)) self.startToolTimer(payload.tool_call_id);
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
            "",
            payload.is_error,
        ));
        try self.finishToolTimer(payload.tool_call_id);
        const text = try toolEndDisplayText(self.allocator, payload) orelse return;
        defer self.allocator.free(text);
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
            .canceled => try self.appendStatus(.warning, "canceled"),
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
        const first = normalizedToolOutputChunk(&buffer, text);
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
            const chunk = normalizedToolOutputChunk(&buffer, remaining);
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
        if (text.len == 0) return;
        _ = try self.terminal.applyCommand(.{
            .append_transcript = .{ .status = .{ .level = level, .text = boundedChunk(text) } },
        });
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

    fn tickTime(self: *InteractiveController) !void {
        _ = try self.terminal.applyCommand(.{ .tick = .{ .now_ms = self.nowMs() } });
        try self.tickToolTimers();
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

    fn finishToolTimer(self: *InteractiveController, tool_call_id: []const u8) !void {
        const timer = self.findToolTimer(tool_call_id) orelse return;
        try self.setToolDurationFooter(tool_call_id, "Took", timer.started_ms);
        self.removeToolTimer(tool_call_id);
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
            try self.setToolDurationFooter(timer.id[0..timer.id_len], "Elapsed", timer.started_ms);
        }
    }

    fn setToolDurationFooter(
        self: *InteractiveController,
        tool_call_id: []const u8,
        label: []const u8,
        started_ms: i64,
    ) !void {
        const elapsed_ms: u64 = @intCast(@max(0, self.nowMs() - started_ms));
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s} {d}.{d}s", .{
            label,
            elapsed_ms / std.time.ms_per_s,
            (elapsed_ms % std.time.ms_per_s) / 100,
        }) catch return;
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
    const prefix = utf8Prefix(text, transcript_append_max);
    if (prefix.len > 0) return prefix;
    return text[0..@min(text.len, transcript_append_max)];
}

const NormalizedToolChunk = struct {
    text: []const u8,
    consumed: usize,
};

/// Presentation-only tool-output cleanup borrowed from pi-mono: CR is not a
/// printable row fact, and tabs become stable spaces before the transcript
/// measures/wraps them. The caller owns `buffer`; no render or transcript
/// allocation is needed for this normalization.
fn normalizedToolOutputChunk(buffer: []u8, text: []const u8) NormalizedToolChunk {
    var out: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\r') {
            index += 1;
            continue;
        }
        if (byte == '\t') {
            if (out + 3 > buffer.len) break;
            @memcpy(buffer[out..][0..3], "   ");
            out += 3;
            index += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const piece_len = if (index + len <= text.len) len else 1;
        if (out + piece_len > buffer.len) break;
        @memcpy(buffer[out..][0..piece_len], text[index..][0..piece_len]);
        out += piece_len;
        index += piece_len;
    }
    return .{ .text = buffer[0..out], .consumed = index };
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
    status: tui.Transcript.ToolStatus,
    title: []const u8,
    compact_title: []const u8,
    is_error: bool,
) tui.Transcript.Append.ToolAppend {
    return .{
        .tool_call_id = tool_call_id,
        .name = name,
        .presentation = toolPresentation(name),
        .status = if (is_error) .err else status,
        .body_mode = toolBodyMode(name),
        .collapse = toolCollapse(name),
        .title = title,
        .compact_title = compact_title,
    };
}

fn toolPresentation(name: []const u8) tui.Transcript.ToolPresentation {
    return tuiToolPresentation(tool_metadata.displayForTool(name).presentation);
}

fn tuiToolPresentation(presentation: tool_metadata.Presentation) tui.Transcript.ToolPresentation {
    return switch (presentation) {
        .generic => .generic,
        .command => .command,
        .file => .file,
        .patch => .patch,
        .search => .search,
        .directory => .directory,
    };
}

fn toolBodyMode(name: []const u8) tui.Transcript.ToolBodyMode {
    return switch (tool_metadata.displayForTool(name).body_mode) {
        .visible => .visible,
        .hidden_on_success => .hidden_on_success,
    };
}

fn toolShowsDuration(name: []const u8) bool {
    return tool_metadata.displayForTool(name).shows_duration;
}

fn toolCallPreviewText(name: []const u8, args_value: std.json.Value) ?[]const u8 {
    if (!std.mem.eql(u8, name, "write")) return null;
    const content = argString(args_value, "content") orelse return null;
    const preview = trimTrailingEmptyLines(content);
    return if (preview.len > 0) preview else null;
}

fn toolClearsCallPreviewOnStart(name: []const u8) bool {
    return std.mem.eql(u8, name, "write");
}

fn shouldHideSuccessfulToolResult(
    tool_name: []const u8,
    is_error: bool,
    details: ?std.json.Value,
) bool {
    if (is_error) return false;
    if (!std.mem.eql(u8, tool_name, "write")) return false;
    const value = details orelse return false;
    if (value != .object) return false;
    return jsonInt(value.object, "bytesWritten") != null;
}

fn toolEndDisplayText(
    allocator: std.mem.Allocator,
    payload: agent_mod.AgentEvent.ToolExecutionEnd,
) !?[]u8 {
    if (shouldHideSuccessfulToolResult(payload.tool_name, payload.is_error, payload.result.details)) return null;
    if (std.mem.eql(u8, payload.tool_name, "edit") and !payload.is_error) {
        if (payload.result.details) |details| {
            if (details == .object) {
                if (details.object.get("diff")) |diff| {
                    if (diff == .string) {
                        const copy = try allocator.dupe(u8, diff.string);
                        return copy;
                    }
                }
            }
        }
    }
    const text = try formatToolResultContent(allocator, payload.result.content, .{
        .trim_trailing_empty_lines = shouldTrimToolResult(payload.tool_name, payload.is_error),
    }) orelse return null;
    const normalized = try normalizeToolDisplayText(allocator, payload.tool_name, payload.result.details, text);
    return normalized;
}

// Collapsed-window policy per tool, mirroring pi-mono's previews: bash shows
// the last 5 visual lines (errors live at the end), search/listing tools show
// the first lines of an already head-truncated result.
const ToolResultFormatOptions = struct {
    trim_trailing_empty_lines: bool = false,
};

fn formatToolResultContent(
    allocator: std.mem.Allocator,
    content: []const ai.ToolResultContent,
    options: ToolResultFormatOptions,
) !?[]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    for (content) |item| {
        const text = switch (item) {
            .text => |text_content| if (options.trim_trailing_empty_lines)
                trimTrailingEmptyLines(text_content.text)
            else
                text_content.text,
            .image => |image| imageFallbackText(image.mime_type),
        };
        if (text.len == 0) continue;
        if (wrote_any) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(text);
        wrote_any = true;
    }
    if (!wrote_any) {
        writer.deinit();
        return null;
    }
    const text = try writer.toOwnedSlice();
    return text;
}

fn imageFallbackText(mime_type: []const u8) []const u8 {
    if (mime_type.len == 0) return "[Image]";
    if (std.mem.eql(u8, mime_type, "image/png")) return "[Image: image/png]";
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "[Image: image/jpeg]";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "[Image: image/gif]";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "[Image: image/webp]";
    return "[Image]";
}

fn normalizeToolDisplayText(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    details: ?std.json.Value,
    owned_text: []u8,
) ![]u8 {
    errdefer allocator.free(owned_text);
    var warning_buffer: [160]u8 = undefined;
    const warning = toolDetailsWarning(&warning_buffer, tool_name, details);
    const body = stripToolSentinel(tool_name, owned_text, warning != null);
    if (!body.changed and warning == null) return owned_text;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    if (body.first.len > 0) {
        try writer.writer.writeAll(body.first);
        wrote_any = true;
    }
    if (body.second.len > 0) {
        if (wrote_any) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(body.second);
        wrote_any = true;
    }
    if (warning) |text| {
        if (wrote_any) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(text);
    }
    allocator.free(owned_text);
    return writer.toOwnedSlice();
}

const ToolDisplayBody = struct {
    first: []const u8,
    second: []const u8 = "",
    changed: bool = false,
};

fn stripToolSentinel(tool_name: []const u8, text: []const u8, has_warning: bool) ToolDisplayBody {
    if (has_warning and std.mem.eql(u8, tool_name, "bash")) {
        if (stripBashTruncationFooter(text)) |body| return body;
    }
    const sentinel = if (std.mem.eql(u8, tool_name, "grep"))
        "[grep truncated]"
    else if (std.mem.eql(u8, tool_name, "find"))
        "[find truncated]"
    else if (std.mem.eql(u8, tool_name, "ls"))
        "[listing truncated]"
    else
        return .{ .first = text };
    if (std.mem.endsWith(u8, text, sentinel)) {
        var end = text.len - sentinel.len;
        if (end > 0 and text[end - 1] == '\n') end -= 1;
        return .{ .first = trimTrailingEmptyLines(text[0..end]), .changed = true };
    }
    return .{ .first = text };
}

fn stripBashTruncationFooter(text: []const u8) ?ToolDisplayBody {
    const marker = "\n\n[Showing ";
    const start = std.mem.lastIndexOf(u8, text, marker) orelse return null;
    const close_rel = std.mem.indexOfScalar(u8, text[start + marker.len ..], ']') orelse return null;
    const close = start + marker.len + close_rel + 1;
    var tail_start = close;
    while (tail_start < text.len and (text[tail_start] == '\n' or text[tail_start] == '\r')) tail_start += 1;
    return .{
        .first = trimTrailingEmptyLines(text[0..start]),
        .second = trimTrailingEmptyLines(text[tail_start..]),
        .changed = true,
    };
}

fn toolDetailsWarning(
    buffer: []u8,
    tool_name: []const u8,
    details: ?std.json.Value,
) ?[]const u8 {
    const value = details orelse return null;
    if (value != .object) return null;
    if (std.mem.eql(u8, tool_name, "bash")) return bashDetailsWarning(buffer, value.object);
    if (std.mem.eql(u8, tool_name, "grep")) return grepDetailsWarning(buffer, value.object);
    if (std.mem.eql(u8, tool_name, "find")) return entriesDetailsWarning(buffer, value.object, "results");
    if (std.mem.eql(u8, tool_name, "ls")) return entriesDetailsWarning(buffer, value.object, "entries");
    return null;
}

fn bashDetailsWarning(buffer: []u8, object: std.json.ObjectMap) ?[]const u8 {
    const truncation = jsonObject(object, "truncation") orelse return null;
    if (!(jsonBool(truncation, "truncated") orelse false)) return null;
    const by = jsonString(truncation, "truncatedBy") orelse "";
    const output_lines = jsonInt(truncation, "outputLines") orelse 0;
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("[Truncated: ") catch return null;
    if (std.mem.eql(u8, by, "lines")) {
        const total_lines = jsonInt(truncation, "totalLines") orelse 0;
        writer.print("showing {d} of {d} lines", .{ output_lines, total_lines }) catch return null;
    } else {
        const max_bytes = jsonInt(truncation, "maxBytes") orelse 0;
        writer.print("{d} lines shown (", .{output_lines}) catch return null;
        writeByteSize(&writer, max_bytes) catch return null;
        writer.writeAll(" limit)") catch return null;
    }
    writer.writeByte(']') catch return null;
    return writer.buffered();
}

fn writeByteSize(writer: *std.Io.Writer, bytes: i64) !void {
    if (bytes > 0 and @mod(bytes, 1024) == 0) {
        try writer.print("{d}KB", .{@divTrunc(bytes, 1024)});
    } else {
        try writer.print("{d}B", .{bytes});
    }
}

fn grepDetailsWarning(buffer: []u8, object: std.json.ObjectMap) ?[]const u8 {
    const long_lines = jsonInt(object, "longLinesTruncated") orelse 0;
    const truncation = jsonObject(object, "truncation");
    const truncated = if (truncation) |trunc| jsonBool(trunc, "truncated") orelse false else false;
    if (!truncated and long_lines == 0) return null;

    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("[Truncated: ") catch return null;
    var wrote_any = false;
    if (truncated) {
        writeTruncationReason(&writer, truncation.?, "matches", "matches") catch return null;
        wrote_any = true;
    }
    if (long_lines > 0) {
        if (wrote_any) writer.writeAll(", ") catch return null;
        writer.writeAll("some lines truncated") catch return null;
    }
    writer.writeByte(']') catch return null;
    return writer.buffered();
}

fn entriesDetailsWarning(
    buffer: []u8,
    object: std.json.ObjectMap,
    noun: []const u8,
) ?[]const u8 {
    const truncation = jsonObject(object, "truncation") orelse return null;
    if (!(jsonBool(truncation, "truncated") orelse false)) return null;
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("[Truncated: ") catch return null;
    writeTruncationReason(&writer, truncation, "entries", noun) catch return null;
    writer.writeByte(']') catch return null;
    return writer.buffered();
}

fn writeTruncationReason(
    writer: *std.Io.Writer,
    truncation: std.json.ObjectMap,
    limit_key: []const u8,
    noun: []const u8,
) !void {
    const by = jsonString(truncation, "truncatedBy") orelse "";
    if (std.mem.eql(u8, by, limit_key)) {
        if (jsonInt(truncation, "maxEntries")) |limit| {
            try writer.print("{d} {s} limit", .{ limit, noun });
            return;
        }
        if (jsonInt(truncation, "maxMatches")) |limit| {
            try writer.print("{d} {s} limit", .{ limit, noun });
            return;
        }
    }
    if (std.mem.eql(u8, by, "bytes")) {
        if (jsonInt(truncation, "maxOutputBytes")) |max_bytes| {
            try writeByteSize(writer, max_bytes);
            try writer.writeAll(" output limit");
        } else {
            try writer.writeAll("output size limit");
        }
    } else if (std.mem.eql(u8, by, "file_size")) {
        if (jsonInt(truncation, "maxFileBytes")) |max_bytes| {
            try writeByteSize(writer, max_bytes);
            try writer.writeAll(" file size limit");
        } else {
            try writer.writeAll("file size limit");
        }
    } else if (std.mem.eql(u8, by, "files")) {
        try writer.writeAll("file scan limit");
    } else {
        try writer.writeAll("output limit");
    }
}

fn jsonObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn jsonInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn shouldTrimToolResult(name: []const u8, is_error: bool) bool {
    if (is_error) return false;
    return std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "find") or
        std.mem.eql(u8, name, "ls") or
        std.mem.eql(u8, name, "write");
}

fn trimTrailingEmptyLines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and text[end - 1] == '\n') {
        end -= 1;
        if (end > 0 and text[end - 1] == '\r') end -= 1;
    }
    return text[0..end];
}

fn toolCollapse(name: []const u8) tui.Transcript.ToolCollapse {
    const metadata = tool_metadata.displayForTool(name).collapse;
    return .{
        .mode = switch (metadata.mode) {
            .head => .head,
            .tail => .tail,
        },
        .rows_max = metadata.rows_max,
    };
}

// Header titles mirror pi-mono's renderCall text:
//   bash  ->  $ <command> (timeout Ns)
//   read  ->  read <path>:<start>-<end>
//   edit/write/ls -> <name> <path>
//   grep  ->  grep /<pattern>/ in <path> (<glob>) limit N
//   find  ->  find <pattern> in <path> (limit N)
// Missing string args render as "..." while arguments are still streaming.
fn formatCompactCallTitle(buffer: []u8, tool_name: []const u8, args_value: std.json.Value) []const u8 {
    if (!std.mem.eql(u8, tool_name, "read")) return "";
    const classification = compactReadClassification(args_value) orelse return "";
    var title: TitleBuilder = .{ .buffer = buffer };
    switch (classification.kind) {
        .skill => {
            title.add("[skill] ");
            title.add(classification.label);
        },
        .docs => {
            title.add("read docs ");
            title.add(classification.label);
        },
        .resource => {
            title.add("read resource ");
            title.add(classification.label);
        },
    }
    addReadLineRange(&title, args_value);
    title.add(" (ctrl+o to expand)");
    return title.slice();
}

fn formatCallTitle(buffer: []u8, tool_name: []const u8, args_value: std.json.Value) []const u8 {
    return formatCallTitleWithHome(buffer, tool_name, args_value, null);
}

fn formatCallTitleWithHome(
    buffer: []u8,
    tool_name: []const u8,
    args_value: std.json.Value,
    home_dir: ?[]const u8,
) []const u8 {
    var title: TitleBuilder = .{ .buffer = buffer, .home_dir = home_dir };
    if (std.mem.eql(u8, tool_name, "bash")) {
        title.add("$ ");
        title.add(argStringOrEllipsis(args_value, "command"));
        if (argInt(args_value, "timeout")) |timeout| {
            title.add(" (timeout ");
            title.addInt(timeout);
            title.add("s)");
        }
    } else if (std.mem.eql(u8, tool_name, "read")) {
        title.add("read ");
        title.addPath(argString(args_value, "file_path") orelse argStringOrEllipsis(args_value, "path"));
        addReadLineRange(&title, args_value);
    } else if (std.mem.eql(u8, tool_name, "edit") or
        std.mem.eql(u8, tool_name, "write") or
        std.mem.eql(u8, tool_name, "ls"))
    {
        title.add(tool_name);
        title.add(" ");
        if (std.mem.eql(u8, tool_name, "ls")) {
            title.addPath(argStringOrDefault(args_value, "path", "."));
        } else {
            title.addPath(argString(args_value, "file_path") orelse argStringOrEllipsis(args_value, "path"));
        }
        if (std.mem.eql(u8, tool_name, "ls")) {
            if (argPositiveInt(args_value, "limit")) |limit| {
                title.add(" (limit ");
                title.addInt(limit);
                title.add(")");
            }
        }
    } else if (std.mem.eql(u8, tool_name, "grep")) {
        title.add("grep /");
        title.add(argStringOrEllipsis(args_value, "pattern"));
        title.add("/ in ");
        title.addPath(argStringOrDefault(args_value, "path", "."));
        if (argString(args_value, "glob")) |glob| {
            title.add(" (");
            title.add(glob);
            title.add(")");
        }
        if (argPositiveInt(args_value, "limit")) |limit| {
            title.add(" limit ");
            title.addInt(limit);
        }
    } else if (std.mem.eql(u8, tool_name, "find")) {
        title.add("find ");
        title.add(argString(args_value, "pattern") orelse argStringOrEllipsis(args_value, "name"));
        title.add(" in ");
        title.addPath(argStringOrDefault(args_value, "path", "."));
        if (argPositiveInt(args_value, "limit")) |limit| {
            title.add(" (limit ");
            title.addInt(limit);
            title.add(")");
        }
    } else {
        // Unknown tool: name-only header; the projection falls back to the
        // tool name when the title is empty, so emit nothing here.
        return "";
    }
    return title.slice();
}

const CompactReadKind = enum { skill, docs, resource };

const CompactReadClassification = struct {
    kind: CompactReadKind,
    label: []const u8,
};

fn compactReadClassification(args_value: std.json.Value) ?CompactReadClassification {
    const path = argString(args_value, "file_path") orelse argString(args_value, "path") orelse return null;
    const leaf = std.fs.path.basename(path);
    if (std.mem.eql(u8, leaf, "SKILL.md")) {
        const parent = if (std.fs.path.dirname(path)) |dirname| std.fs.path.basename(dirname) else leaf;
        return .{ .kind = .skill, .label = if (parent.len > 0) parent else leaf };
    }
    if (isCompactResourceLeaf(leaf)) return .{ .kind = .resource, .label = path };
    if (!std.fs.path.isAbsolute(path) and isCompactDocsPath(path)) return .{ .kind = .docs, .label = path };
    return null;
}

fn isCompactResourceLeaf(leaf: []const u8) bool {
    return std.mem.eql(u8, leaf, "AGENTS.md") or
        std.mem.eql(u8, leaf, "AGENTS.MD") or
        std.mem.eql(u8, leaf, "CLAUDE.md") or
        std.mem.eql(u8, leaf, "CLAUDE.MD");
}

fn isCompactDocsPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "README.md") or
        std.mem.startsWith(u8, path, "docs/") or
        std.mem.startsWith(u8, path, "examples/");
}

fn addReadLineRange(title: *TitleBuilder, args_value: std.json.Value) void {
    const offset = argPositiveInt(args_value, "offset");
    const limit = argPositiveInt(args_value, "limit");
    if (offset == null and limit == null) return;
    const start = offset orelse 1;
    title.add(":");
    title.addInt(start);
    if (limit) |count| {
        // Model-supplied integers are operational input; saturate instead of
        // trusting them to stay in range.
        title.add("-");
        title.addInt(start +| count -| 1);
    }
}

/// Bounded single-line title assembly: control characters become spaces,
/// overflow truncates, and the final slice is trimmed to a UTF-8 boundary.
const TitleBuilder = struct {
    buffer: []u8,
    home_dir: ?[]const u8 = null,
    len: usize = 0,

    fn add(self: *TitleBuilder, text: []const u8) void {
        for (text) |byte| {
            if (self.len >= self.buffer.len) return;
            self.buffer[self.len] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
            self.len += 1;
        }
    }

    fn addInt(self: *TitleBuilder, value: i64) void {
        var digits: [24]u8 = undefined;
        self.add(std.fmt.bufPrint(&digits, "{d}", .{value}) catch return);
    }

    fn addPath(self: *TitleBuilder, path: []const u8) void {
        const suffix = homePathSuffix(path, self.home_dir) orelse {
            self.add(path);
            return;
        };
        self.add("~");
        self.add(suffix);
    }

    fn slice(self: *const TitleBuilder) []const u8 {
        var end = self.len;
        while (end > 0 and !std.unicode.utf8ValidateSlice(self.buffer[0..end])) end -= 1;
        return self.buffer[0..end];
    }
};

fn argString(args_value: std.json.Value, key: []const u8) ?[]const u8 {
    if (args_value != .object) return null;
    const value = args_value.object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn argStringOrEllipsis(args_value: std.json.Value, key: []const u8) []const u8 {
    return argString(args_value, key) orelse "...";
}

fn argStringOrDefault(args_value: std.json.Value, key: []const u8, default: []const u8) []const u8 {
    return argString(args_value, key) orelse default;
}

fn argPositiveInt(args_value: std.json.Value, key: []const u8) ?i64 {
    const value = argInt(args_value, key) orelse return null;
    return if (value > 0) value else null;
}

fn argInt(args_value: std.json.Value, key: []const u8) ?i64 {
    if (args_value != .object) return null;
    const value = args_value.object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
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

fn testArgs(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "tool output normalization removes carriage returns and expands tabs" {
    var buffer: [16]u8 = undefined;

    const chunk = normalizedToolOutputChunk(&buffer, "a\tb\rc");
    try std.testing.expectEqualStrings("a   bc", chunk.text);
    try std.testing.expectEqual(@as(usize, 5), chunk.consumed);

    const bounded = normalizedToolOutputChunk(buffer[0..5], "a\tb\tc");
    try std.testing.expectEqualStrings("a   b", bounded.text);
    try std.testing.expectEqual(@as(usize, 3), bounded.consumed);
}

test "composer cwd display shortens home paths" {
    var buffer: [tui.status.text_bytes_max]u8 = undefined;

    try std.testing.expectEqualStrings("~", formatComposerCwd(&buffer, "/Users/me", "/Users/me"));
    try std.testing.expectEqualStrings("~/repo", formatComposerCwd(&buffer, "/Users/me/repo", "/Users/me"));
    try std.testing.expectEqualStrings("~/repo", formatComposerCwd(&buffer, "/Users/me/repo", "/Users/me/"));
    try std.testing.expectEqualStrings("/Users/meg/repo", formatComposerCwd(&buffer, "/Users/meg/repo", "/Users/me"));
    try std.testing.expectEqualStrings("/repo", formatComposerCwd(&buffer, "/repo", null));
}

test "formatCallTitle mirrors pi-mono call headers" {
    const allocator = std.testing.allocator;
    var buffer: [tool_title_bytes_max]u8 = undefined;

    var bash_args = try testArgs(allocator, "{\"command\":\"ls -la\",\"timeout\":5}");
    defer bash_args.deinit();
    try std.testing.expectEqualStrings(
        "$ ls -la (timeout 5s)",
        formatCallTitle(&buffer, "bash", bash_args.value),
    );

    var read_args = try testArgs(allocator, "{\"path\":\"src/main.zig\",\"offset\":10,\"limit\":20}");
    defer read_args.deinit();
    try std.testing.expectEqualStrings(
        "read src/main.zig:10-29",
        formatCallTitle(&buffer, "read", read_args.value),
    );

    var read_file_path_args = try testArgs(
        allocator,
        "{\"file_path\":\"src/file.zig\",\"path\":\"ignored.zig\",\"offset\":-1,\"limit\":0}",
    );
    defer read_file_path_args.deinit();
    try std.testing.expectEqualStrings(
        "read src/file.zig",
        formatCallTitle(&buffer, "read", read_file_path_args.value),
    );

    var home_path_args = try testArgs(allocator, "{\"path\":\"/Users/me/repo/src/main.zig\"}");
    defer home_path_args.deinit();
    try std.testing.expectEqualStrings(
        "read ~/repo/src/main.zig",
        formatCallTitleWithHome(&buffer, "read", home_path_args.value, "/Users/me"),
    );

    var grep_args = try testArgs(allocator, "{\"pattern\":\"foo\",\"glob\":\"*.zig\",\"limit\":50}");
    defer grep_args.deinit();
    try std.testing.expectEqualStrings(
        "grep /foo/ in . (*.zig) limit 50",
        formatCallTitle(&buffer, "grep", grep_args.value),
    );

    var find_args = try testArgs(allocator, "{\"name\":\".zig\",\"path\":\"src\",\"limit\":25}");
    defer find_args.deinit();
    try std.testing.expectEqualStrings(
        "find .zig in src (limit 25)",
        formatCallTitle(&buffer, "find", find_args.value),
    );

    var ls_args = try testArgs(allocator, "{}");
    defer ls_args.deinit();
    try std.testing.expectEqualStrings("ls .", formatCallTitle(&buffer, "ls", ls_args.value));

    var write_args = try testArgs(allocator, "{\"file_path\":\"src/file.zig\",\"path\":\"ignored.zig\"}");
    defer write_args.deinit();
    try std.testing.expectEqualStrings("write src/file.zig", formatCallTitle(&buffer, "write", write_args.value));

    var edit_args = try testArgs(allocator, "{\"file_path\":\"src/file.zig\",\"path\":\"ignored.zig\"}");
    defer edit_args.deinit();
    try std.testing.expectEqualStrings("edit src/file.zig", formatCallTitle(&buffer, "edit", edit_args.value));
}

test "write call previews content until execution stream starts" {
    const allocator = std.testing.allocator;

    var write_args = try testArgs(allocator, "{\"path\":\"file.txt\",\"content\":\"one\\ntwo\\n\"}");
    defer write_args.deinit();
    try std.testing.expectEqualStrings("one\ntwo", toolCallPreviewText("write", write_args.value).?);
    try std.testing.expect(toolClearsCallPreviewOnStart("write"));
    try std.testing.expect(toolCallPreviewText("read", write_args.value) == null);
}

test "successful write result is hidden so streamed content remains visible" {
    const allocator = std.testing.allocator;
    var details = try testArgs(allocator, "{\"bytesWritten\":5,\"path\":\"file.txt\"}");
    defer details.deinit();
    try std.testing.expect(shouldHideSuccessfulToolResult("write", false, details.value));
    try std.testing.expect(!shouldHideSuccessfulToolResult("write", true, details.value));
    try std.testing.expect(!shouldHideSuccessfulToolResult("read", false, details.value));
}

test "tool result display joins text and image fallback" {
    const content = [_]ai.ToolResultContent{
        .{ .text = .{ .text = "Read image file [image/png]\n" } },
        .{ .image = .{ .data = "base64", .mime_type = "image/png" } },
    };
    const text = try formatToolResultContent(std.testing.allocator, &content, .{
        .trim_trailing_empty_lines = true,
    }) orelse return error.ExpectedText;
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("Read image file [image/png]\n[Image: image/png]", text);
}

test "tool display replaces raw truncation sentinels with pi style warnings" {
    const allocator = std.testing.allocator;
    var grep_details = try testArgs(
        allocator,
        "{\"longLinesTruncated\":1,\"truncation\":{\"truncated\":true,\"truncatedBy\":\"matches\",\"maxMatches\":2}}",
    );
    defer grep_details.deinit();

    const raw = try allocator.dupe(u8, "a.zig:1: foo\n[grep truncated]");
    const text = try normalizeToolDisplayText(allocator, "grep", grep_details.value, raw);
    defer allocator.free(text);

    try std.testing.expectEqualStrings(
        "a.zig:1: foo\n[Truncated: 2 matches limit, some lines truncated]",
        text,
    );
}

test "tool display formats grep byte and file-size truncation warnings" {
    const allocator = std.testing.allocator;

    var bytes_details = try testArgs(
        allocator,
        "{\"truncation\":{\"truncated\":true,\"truncatedBy\":\"bytes\",\"maxOutputBytes\":51200}}",
    );
    defer bytes_details.deinit();
    const bytes_raw = try allocator.dupe(u8, "[grep truncated]");
    const bytes_text = try normalizeToolDisplayText(allocator, "grep", bytes_details.value, bytes_raw);
    defer allocator.free(bytes_text);
    try std.testing.expectEqualStrings("[Truncated: 50KB output limit]", bytes_text);

    var file_details = try testArgs(
        allocator,
        "{\"truncation\":{\"truncated\":true,\"truncatedBy\":\"file_size\",\"maxFileBytes\":262144}}",
    );
    defer file_details.deinit();
    const file_raw = try allocator.dupe(u8, "[grep truncated]");
    const file_text = try normalizeToolDisplayText(allocator, "grep", file_details.value, file_raw);
    defer allocator.free(file_text);
    try std.testing.expectEqualStrings("[Truncated: 256KB file size limit]", file_text);
}

test "bash display replaces core truncation footer with pi style warning" {
    const allocator = std.testing.allocator;
    var details = try testArgs(
        allocator,
        "{\"truncation\":{\"truncated\":true,\"truncatedBy\":\"lines\"," ++
            "\"outputLines\":5,\"totalLines\":100,\"maxBytes\":51200}}",
    );
    defer details.deinit();

    const raw = try allocator.dupe(
        u8,
        "line 96\nline 100\n\n[Showing lines 96-100 of 100 (50KB limit)]\n\nCommand exited with code 1",
    );
    const text = try normalizeToolDisplayText(allocator, "bash", details.value, raw);
    defer allocator.free(text);

    try std.testing.expectEqualStrings(
        "line 96\nline 100\nCommand exited with code 1\n[Truncated: showing 5 of 100 lines]",
        text,
    );
}

test "read display trims trailing empty lines" {
    try std.testing.expectEqualStrings("one", trimTrailingEmptyLines("one\n"));
    try std.testing.expectEqualStrings("one", trimTrailingEmptyLines("one\n\n"));
    try std.testing.expectEqualStrings("one\ntwo", trimTrailingEmptyLines("one\ntwo"));
}

test "formatCompactCallTitle mirrors pi-mono read resource headers" {
    const allocator = std.testing.allocator;
    var buffer: [tool_title_bytes_max]u8 = undefined;

    var skill_args = try testArgs(allocator, "{\"path\":\".zi/skills/review/SKILL.md\",\"limit\":10}");
    defer skill_args.deinit();
    try std.testing.expectEqualStrings(
        "[skill] review:1-10 (ctrl+o to expand)",
        formatCompactCallTitle(&buffer, "read", skill_args.value),
    );

    var resource_args = try testArgs(allocator, "{\"path\":\"AGENTS.md\"}");
    defer resource_args.deinit();
    try std.testing.expectEqualStrings(
        "read resource AGENTS.md (ctrl+o to expand)",
        formatCompactCallTitle(&buffer, "read", resource_args.value),
    );

    var regular_args = try testArgs(allocator, "{\"path\":\"src/main.zig\"}");
    defer regular_args.deinit();
    try std.testing.expectEqualStrings("", formatCompactCallTitle(&buffer, "read", regular_args.value));
}

test "only process tools show duration footer" {
    try std.testing.expect(toolShowsDuration("bash"));
    try std.testing.expect(!toolShowsDuration("read"));
    try std.testing.expect(!toolShowsDuration("grep"));
}

test "formatCallTitle shows ellipsis while args stream and sanitizes newlines" {
    const allocator = std.testing.allocator;
    var buffer: [tool_title_bytes_max]u8 = undefined;

    var empty_args = try testArgs(allocator, "{}");
    defer empty_args.deinit();
    try std.testing.expectEqualStrings("$ ...", formatCallTitle(&buffer, "bash", empty_args.value));
    try std.testing.expectEqualStrings("", formatCallTitle(&buffer, "mystery", empty_args.value));

    var multiline_args = try testArgs(allocator, "{\"command\":\"echo a\\necho b\"}");
    defer multiline_args.deinit();
    try std.testing.expectEqualStrings(
        "$ echo a echo b",
        formatCallTitle(&buffer, "bash", multiline_args.value),
    );
}
