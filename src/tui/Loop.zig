const std = @import("std");
const vaxis = @import("vaxis");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const coding_agent = @import("../coding_agent/root.zig");
const slash_commands = @import("../coding_agent/slash_commands.zig");
const runtime = @import("../runtime/root.zig");
const chrome = @import("chrome.zig");
const Editor = @import("Editor.zig");
const input = @import("input.zig");
const render_policy = @import("render_policy.zig");
const screen = @import("screen.zig");
const theme = @import("theme.zig");
const trace_mod = @import("trace.zig");
const Transcript = @import("Transcript.zig");

pub const SubmittedPrompt = struct {
    buffer: [Editor.capacity]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *SubmittedPrompt, value: []const u8) void {
        std.debug.assert(value.len <= self.buffer.len);
        @memcpy(self.buffer[0..value.len], value);
        self.len = value.len;
    }

    pub fn text(self: *const SubmittedPrompt) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const frame_floor_ns: u64 = 16 * std.time.ns_per_ms;
pub const watchdog_budget_ns: u64 = 33 * std.time.ns_per_ms;
pub const double_key_window_ns: u64 = 500 * std.time.ns_per_ms;
pub const spinner_interval_ns: u64 = 80 * std.time.ns_per_ms;
pub const elapsed_tick_ns: u64 = std.time.ns_per_s;
pub const shutdown_cancel_bound_ns: u64 = 5 * std.time.ns_per_s;
const exit_hint_text = "press ctrl+c again to exit";
const scratch_capacity = 8192;
const synthetic_flood_rate_bytes_per_second: u64 = 1024 * 1024;
pub const synthetic_flood_duration_ns: u64 = 30 * std.time.ns_per_s;
pub const synthetic_flood_tool_body_bytes: usize = 4 * 1024 * 1024;
const synthetic_flood_tool_emit_ns: u64 = synthetic_flood_duration_ns / 2;
const transcript_line_buffer_count = 128;

pub const Scratch = struct {
    buffer: [scratch_capacity]u8 = undefined,
    len: usize = 0,
    evicted_bytes: usize = 0,

    pub fn text(self: *const Scratch) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn appendRepeated(self: *Scratch, byte: u8, count: usize) void {
        if (count >= self.buffer.len) {
            @memset(&self.buffer, byte);
            self.evicted_bytes += self.len + count - self.buffer.len;
            self.len = self.buffer.len;
            return;
        }
        if (count > self.buffer.len - self.len) {
            const evict_count = count - (self.buffer.len - self.len);
            std.mem.copyForwards(u8, self.buffer[0 .. self.len - evict_count], self.buffer[evict_count..self.len]);
            self.len -= evict_count;
            self.evicted_bytes += evict_count;
        }
        @memset(self.buffer[self.len..][0..count], byte);
        self.len += count;
    }
};

pub const SyntheticFlood = struct {
    enabled: bool = false,
    start_ns: u64 = 0,
    emitted_bytes: u64 = 0,
    message_started: bool = false,
    tool_emitted: bool = false,
    completed: bool = false,
};

pub const RunDriver = struct {
    state: State = .idle,
    saved_prompt: ?SubmittedPrompt = null,
    overflow_count_before: usize = 0,
    overflow_retry_used: bool = false,
    retry: ?RetryDisplay = null,

    pub const RetryDisplay = struct { deadline_ns: u64, attempt: u8, max: u8 };
    pub const State = union(enum) {
        idle,
        running: coding_agent.AgentSession.RunHandle,
        retry_wait: coding_agent.AgentSession.SettleVerdict.Retry,
        compacting: struct { handle: coding_agent.AgentSession.RunHandle, will_retry: bool },
    };

    pub fn busy(self: *const RunDriver) bool {
        return self.state != .idle;
    }

    pub fn submitPrompt(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        text: []const u8,
    ) !void {
        if (text.len > Editor.capacity) return error.EditorFull;
        switch (self.state) {
            .idle => {},
            .running => return self.queuePrompt(owner, session, text, .steer),
            .retry_wait => {
                try owner.notice(.warn, "busy: waiting to retry — esc to cancel");
                return;
            },
            .compacting => {
                try owner.notice(.warn, "busy: compacting — esc to cancel");
                return;
            },
        }
        self.saved_prompt = .{};
        self.saved_prompt.?.set(text);
        self.overflow_count_before = session.contextOverflowCount();
        self.overflow_retry_used = false;
        var handle = try session.startPromptHandle(text, &.{});
        handle.setWake(io, wake);
        self.state = .{ .running = handle };
        owner.dirty = true;
    }

    pub fn queuePrompt(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        text: []const u8,
        kind: coding_agent.AgentSession.QueuePromptKind,
    ) !void {
        _ = self;
        session.queuePrompt(text, &.{}, kind) catch |err| switch (err) {
            error.QueueFull => try owner.noticeFmt(.warn, "queue is full ({d} queued)", .{session.queuedEchoes().len}),
            error.SessionNotRunning => std.debug.assert(false),
            else => return err,
        };
        owner.dirty = true;
    }

    pub fn startManualCompaction(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
    ) !void {
        if (self.state != .idle) {
            try owner.notice(.warn, "busy: compacting — esc to cancel");
            return;
        }
        const maybe = try session.startCompactionHandle(.manual, false, null);
        var handle = maybe orelse {
            try owner.notice(.info, "nothing to compact");
            return;
        };
        handle.setWake(io, wake);
        self.state = .{ .compacting = .{ .handle = handle, .will_retry = false } };
        owner.dirty = true;
    }

    pub fn pump(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
    ) !void {
        switch (self.state) {
            .idle => {},
            .running => |*handle| try self.pumpPromptHandle(owner, session, io, wake, now_ns, handle),
            .retry_wait => |retry| {
                if (self.retry) |display| {
                    if (now_ns < display.deadline_ns) return;
                }
                try self.startRetry(owner, session, io, wake, retry);
            },
            .compacting => |*state| try self.pumpCompactionHandle(owner, session, io, wake, now_ns, &state.handle, state.will_retry),
        }
    }

    pub fn cancel(self: *RunDriver, owner: *Loop, session: *coding_agent.AgentSession) void {
        switch (self.state) {
            .idle => {},
            .running => |*handle| {
                handle.cancelRequest(session);
                if (owner.editor.text().len == 0) owner.restoreQueuedText(session) catch {};
                owner.notice(.info, "aborted") catch {};
            },
            .retry_wait => {
                session.cancelRetryWait();
                self.state = .idle;
                self.retry = null;
                owner.notice(.info, "aborted") catch {};
            },
            .compacting => |*state| {
                state.handle.cancelRequest(session);
                owner.notice(.info, "aborted") catch {};
            },
        }
        owner.dirty = true;
    }

    pub fn forceCancelAndDrain(self: *RunDriver, session: *coding_agent.AgentSession, io: std.Io, wake: *runtime.WakeEvent) void {
        const start = nowNs(io);
        self.cancelNoNotice(session);
        while (self.state != .idle and nowNs(io) -| start < shutdown_cancel_bound_ns) {
            var dummy = Loop.dummyForShutdown(session.allocator);
            defer dummy.deinit();
            self.pump(&dummy, session, io, wake, nowNs(io)) catch break;
            if (self.state == .idle) break;
            wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
            wake.reset();
        }
    }

    fn cancelNoNotice(self: *RunDriver, session: *coding_agent.AgentSession) void {
        switch (self.state) {
            .idle => {},
            .running => |*handle| handle.cancelRequest(session),
            .retry_wait => {
                session.cancelRetryWait();
                self.state = .idle;
                self.retry = null;
            },
            .compacting => |*state| state.handle.cancelRequest(session),
        }
    }

    fn pumpPromptHandle(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
        handle: *coding_agent.AgentSession.RunHandle,
    ) !void {
        while (true) {
            switch (try handle.poll(session)) {
                .live => owner.dirty = true,
                .empty => return,
                .settled => break,
            }
        }
        const verdict = try handle.settle(session, .{
            .overflow_count_before = self.overflow_count_before,
            .overflow_retry_used = self.overflow_retry_used,
        });
        handle.deinitAfterSettled(session);
        self.state = .idle;
        try self.afterPromptVerdict(owner, session, io, wake, now_ns, verdict);
    }

    fn pumpCompactionHandle(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
        handle: *coding_agent.AgentSession.RunHandle,
        will_retry: bool,
    ) !void {
        while (true) {
            switch (try handle.poll(session)) {
                .live => owner.dirty = true,
                .empty => return,
                .settled => break,
            }
        }
        const compaction_run = handle.run.compaction;
        const had_summary = compaction_run.outcome == .summary;
        const verdict = try handle.settle(session, .{ .overflow_count_before = self.overflow_count_before, .overflow_retry_used = self.overflow_retry_used });
        if (had_summary) try owner.transcript.appendCompaction(compaction_run.outcome.summary, compaction_run.input.tokens_before);
        handle.deinitAfterSettled(session);
        self.state = .idle;
        if (!will_retry) {
            if (had_summary) try owner.notice(.info, "context compacted");
            owner.dirty = true;
            return;
        }
        try self.afterPromptVerdict(owner, session, io, wake, now_ns, verdict);
    }

    fn afterPromptVerdict(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
        verdict: coding_agent.AgentSession.SettleVerdict,
    ) !void {
        switch (verdict) {
            .completed => {
                if (session.shouldRunThresholdCompaction()) {
                    var maybe = try session.startCompactionHandle(.threshold, false, null);
                    if (maybe) |*handle| {
                        handle.setWake(io, wake);
                        self.state = .{ .compacting = .{ .handle = handle.*, .will_retry = false } };
                    }
                }
            },
            .failed => {
                if (session.latestAssistantError()) |err| try owner.noticeFmt(.err, "error: {s}", .{err});
            },
            .retry => |retry| try self.armRetry(session, now_ns, retry),
            .compact => |run| {
                var handle = coding_agent.AgentSession.RunHandle.compaction(run);
                handle.setWake(io, wake);
                self.state = .{ .compacting = .{ .handle = handle, .will_retry = run.will_retry } };
            },
        }
        owner.dirty = true;
    }

    fn armRetry(self: *RunDriver, session: *coding_agent.AgentSession, now_ns: u64, retry: coding_agent.AgentSession.SettleVerdict.Retry) !void {
        const delay_ns = retry.delay_ms *| std.time.ns_per_ms;
        self.retry = .{
            .deadline_ns = now_ns +| delay_ns,
            .attempt = session.retryAttempt(),
            .max = session.retry_settings.max_attempts,
        };
        self.state = .{ .retry_wait = retry };
    }

    fn startRetry(
        self: *RunDriver,
        owner: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        retry: coding_agent.AgentSession.SettleVerdict.Retry,
    ) !void {
        var handle = switch (retry.kind) {
            .continue_run => try session.startContinueHandle(),
            .resubmit_prompt => blk: {
                const saved = self.saved_prompt orelse return error.NoSavedPrompt;
                self.overflow_retry_used = true;
                break :blk try session.startPromptHandle(saved.text(), &.{});
            },
        };
        handle.setWake(io, wake);
        self.retry = null;
        self.state = .{ .running = handle };
        owner.dirty = true;
    }
};

pub const Loop = struct {
    gpa: std.mem.Allocator,
    editor: Editor = .{},
    transcript: Transcript = undefined,
    trace: trace_mod.Stats = .{},
    submitted_prompt: ?SubmittedPrompt = null,
    exit_requested: bool = false,
    dirty: bool = true,
    last_flush_ns: u64 = 0,
    ctrl_c_deadline_ns: ?u64 = null,
    exit_hint_visible: bool = false,
    scratch: Scratch = .{},
    synthetic_flood: SyntheticFlood = .{},
    frame_input_bytes: usize = 0,
    frame_events_applied: usize = 0,
    layout_epoch: theme.LayoutEpoch = .{ .width = 0, .height = 0 },
    last_width: u16 = 0,
    last_height: u16 = 0,
    driver: RunDriver = .{},
    session: ?*coding_agent.AgentSession = null,
    io: std.Io = undefined,
    wake: ?*runtime.WakeEvent = null,
    transcript_line_buffer: [transcript_line_buffer_count]screen.Line = undefined,
    queue_buffers: [4][256]u8 = undefined,
    queue_lines: [4][]const u8 = undefined,
    status_buffer: [256]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, initial_prompt: ?[]const u8) !Loop {
        var self: Loop = .{ .gpa = gpa, .transcript = Transcript.init(gpa) };
        if (initial_prompt) |prompt| try self.editor.insert(prompt);
        return self;
    }

    pub fn dummyForShutdown(gpa: std.mem.Allocator) Loop {
        return .{ .gpa = gpa, .transcript = Transcript.init(gpa) };
    }

    pub fn deinit(self: *Loop) void {
        self.transcript.deinit();
        self.* = undefined;
    }

    pub fn bindSession(self: *Loop, session: *coding_agent.AgentSession, io: std.Io, wake: *runtime.WakeEvent) void {
        self.session = session;
        self.io = io;
        self.wake = wake;
    }

    pub fn enableSyntheticFlood(self: *Loop, start_ns: u64) void {
        self.synthetic_flood = .{ .enabled = true, .start_ns = start_ns, .emitted_bytes = 0 };
        self.dirty = true;
    }

    pub fn recordInputBytes(self: *Loop, count: usize) void {
        self.frame_input_bytes += count;
    }

    pub fn dispatch(self: *Loop, action: input.Action) !void {
        try self.dispatchAt(action, 0);
    }

    pub fn dispatchAt(self: *Loop, action: input.Action, now_ns: u64) !void {
        self.trace.recordInputAction();
        self.frame_events_applied += 1;
        self.dirty = true;
        switch (action) {
            .insert => |text| {
                self.clearExitHint();
                try self.editor.insert(text);
            },
            .key_editor => |op| {
                self.clearExitHint();
                self.applyEditorOp(op);
            },
            .cancel => self.handleCancel(),
            .quit_eof => {
                if (self.editor.text().len == 0) {
                    self.exit_requested = true;
                } else {
                    self.clearExitHint();
                    _ = self.editor.deleteForward();
                }
            },
            .submit => try self.submitPrompt(.submit),
            .steer_submit => try self.submitPrompt(.steer_submit),
            .follow_up_submit => try self.submitPrompt(.follow_up_submit),
            .newline => try self.editor.insertNewline(),
            .dequeue_all => try self.dequeueAll(),
            .clear_or_quit => self.handleClearOrQuit(now_ns),
            .expand_toggle => {
                _ = self.layout_epoch.setExpanded(!self.layout_epoch.expanded);
                self.dirty = true;
            },
            .force_redraw => self.dirty = true,
            .scroll, .page_up, .page_down, .none => {},
        }
    }

    pub fn submittedPrompt(self: *const Loop) ?[]const u8 {
        if (self.submitted_prompt) |*prompt| return prompt.text();
        return null;
    }

    pub fn composeFrame(self: *Loop, width: u16, height: u16) anyerror!screen.Frame {
        self.noteResize(width, height);
        const transcript_lines = try self.collectTranscriptLines(width);
        const queue_lines = self.collectQueueLines();
        return chrome.compose(.{
            .status = self.statusText(),
            .scratch_text = self.scratch.text(),
            .transcript_lines = transcript_lines,
            .queue_lines = queue_lines,
            .editor = &self.editor,
            .editor_border_style = self.editorBorderStyle(),
        }, width, height);
    }

    pub fn shouldRender(self: *const Loop, now_ns: u64) bool {
        return render_policy.shouldRenderWithFloor(
            self.dirty,
            now_ns,
            self.last_flush_ns,
            self.trace.renders.max_ns,
            frame_floor_ns,
        );
    }

    pub fn nextTimerDeadlineNs(self: *const Loop) ?u64 {
        var deadline = self.ctrl_c_deadline_ns;
        if (self.driver.retry) |retry| deadline = if (deadline) |current| @min(current, retry.deadline_ns) else retry.deadline_ns;
        if (self.transcript.run_active or self.driver.state == .compacting) {
            const spinner_due = self.last_flush_ns +| spinner_interval_ns;
            deadline = if (deadline) |current| @min(current, spinner_due) else spinner_due;
        }
        if (self.synthetic_flood.enabled and !self.synthetic_flood.completed) {
            const flood_due = self.last_flush_ns +| frame_floor_ns;
            deadline = if (deadline) |current| @min(current, flood_due) else flood_due;
        }
        return deadline;
    }

    pub fn noteResize(self: *Loop, width: u16, height: u16) void {
        if (self.last_width == width and self.last_height == height) return;
        if (self.last_width != 0 and self.last_width != width) self.trace.recordRebuild(0);
        _ = self.layout_epoch.resize(width, height);
        self.last_width = width;
        self.last_height = height;
        self.dirty = true;
    }

    pub fn markRendered(self: *Loop, now_ns: u64, render_cost_ns: u64) void {
        self.last_flush_ns = now_ns;
        self.trace.recordRender(render_cost_ns);
        self.trace.recordFrame(.{
            .wake_ns = now_ns,
            .input_bytes = self.frame_input_bytes,
            .events_applied = self.frame_events_applied,
            .paint_us = nsToUs(render_cost_ns),
        });
        self.frame_input_bytes = 0;
        self.frame_events_applied = 0;
        self.dirty = false;
    }

    pub fn tick(self: *Loop, now_ns: u64) !void {
        try self.pumpSyntheticFlood(now_ns);
        if (self.ctrl_c_deadline_ns) |deadline| {
            if (now_ns > deadline) {
                self.ctrl_c_deadline_ns = null;
                if (self.exit_hint_visible) {
                    self.exit_hint_visible = false;
                    self.dirty = true;
                }
            }
        }
        if (self.transcript.markRunningToolsDirty()) self.dirty = true;
    }

    pub fn pumpDriver(self: *Loop, now_ns: u64) !void {
        const session = self.session orelse return;
        const wake = self.wake orelse return;
        try self.driver.pump(self, session, self.io, wake, now_ns);
    }

    pub fn shutdownDriver(self: *Loop) void {
        const session = self.session orelse return;
        const wake = self.wake orelse return;
        self.driver.forceCancelAndDrain(session, self.io, wake);
    }

    pub fn notice(self: *Loop, level: Transcript.NoticeLevel, text: []const u8) !void {
        try self.transcript.appendNotice(level, text);
        self.dirty = true;
    }

    pub fn noticeFmt(self: *Loop, level: Transcript.NoticeLevel, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.status_buffer, fmt, args);
        try self.notice(level, text);
    }

    fn collectTranscriptLines(self: *Loop, width: u16) ![]const screen.Line {
        var count: usize = 0;
        for (self.transcript.items.items) |item| {
            const lines = try self.transcript.itemLines(item, width, self.layout_epoch);
            for (lines) |line| {
                if (count == self.transcript_line_buffer.len) {
                    std.mem.copyForwards(screen.Line, self.transcript_line_buffer[0 .. count - 1], self.transcript_line_buffer[1..count]);
                    count -= 1;
                }
                self.transcript_line_buffer[count] = line;
                count += 1;
            }
        }
        return self.transcript_line_buffer[0..count];
    }

    fn collectQueueLines(self: *Loop) []const []const u8 {
        const session = self.session orelse return &.{};
        const echoes = session.queuedEchoes();
        if (echoes.len == 0) return &.{};
        var count: usize = 0;
        const visible = @min(echoes.len, 3);
        for (echoes[0..visible]) |echo| {
            self.queue_lines[count] = switch (echo.kind) {
                .steering => std.fmt.bufPrint(&self.queue_buffers[count], "steering: {s}", .{echo.text}) catch echo.text,
                .follow_up => std.fmt.bufPrint(&self.queue_buffers[count], "follow-up: {s}", .{echo.text}) catch echo.text,
            };
            count += 1;
        }
        self.queue_lines[count] = "alt+q edits queued messages";
        count += 1;
        return self.queue_lines[0..count];
    }

    fn statusText(self: *Loop) []const u8 {
        if (self.exit_requested) return "exiting";
        if (self.exit_hint_visible) return exit_hint_text;
        switch (self.driver.state) {
            .retry_wait => if (self.driver.retry) |retry| {
                const now = if (self.session) |session| nowNs(session.io) else 0;
                const remaining_ns = retry.deadline_ns -| now;
                const remaining_s = (remaining_ns + std.time.ns_per_s - 1) / std.time.ns_per_s;
                return std.fmt.bufPrint(&self.status_buffer, "Retrying ({d}/{d}) in {d}s… (esc to cancel)", .{ retry.attempt, retry.max, remaining_s }) catch "Retrying";
            },
            .compacting => return "Compacting context… (esc to cancel)",
            else => {},
        }
        if (self.transcript.run_active or self.driver.state == .running) return "Working…";
        return "ready";
    }

    fn editorBorderStyle(self: *const Loop) screen.Style {
        const session = self.session orelse return screen.styles.muted;
        return switch (session.agent.state.thinking_level) {
            .off => screen.styles.muted,
            .minimal, .low => screen.styles.accent,
            .medium => screen.styles.warn,
            .high, .xhigh => screen.styles.error_,
        };
    }

    fn pumpSyntheticFlood(self: *Loop, now_ns: u64) !void {
        if (!self.synthetic_flood.enabled or self.synthetic_flood.completed) return;
        if (!self.synthetic_flood.message_started) try self.startSyntheticFloodMessage();

        const elapsed_ns = @min(now_ns -| self.synthetic_flood.start_ns, synthetic_flood_duration_ns);
        if (!self.synthetic_flood.tool_emitted and elapsed_ns >= synthetic_flood_tool_emit_ns) try self.emitSyntheticFloodToolEnd();

        const target_bytes: u64 = @intCast((@as(u128, elapsed_ns) * synthetic_flood_rate_bytes_per_second) / std.time.ns_per_s);
        var delta_buffer: [Transcript.append_chunk_bytes_max]u8 = undefined;
        @memset(&delta_buffer, 'x');
        while (self.synthetic_flood.emitted_bytes < target_bytes) {
            const remaining: usize = @intCast(@min(@as(u64, delta_buffer.len), target_bytes - self.synthetic_flood.emitted_bytes));
            try self.applySyntheticEvent(.{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
                .content_index = 0,
                .delta = delta_buffer[0..remaining],
                .partial = syntheticAssistantMessage(&.{}),
            } } } });
            self.synthetic_flood.emitted_bytes += remaining;
        }

        if (elapsed_ns >= synthetic_flood_duration_ns) {
            self.synthetic_flood.completed = true;
            try self.applySyntheticEvent(.agent_end);
        }
    }

    fn startSyntheticFloodMessage(self: *Loop) !void {
        self.synthetic_flood.message_started = true;
        try self.applySyntheticEvent(.agent_start);
        try self.applySyntheticEvent(.{ .message_start = .{ .message = .{ .assistant = syntheticAssistantMessage(&.{}) } } });
        try self.applySyntheticEvent(.{ .message_update = .{ .assistant_message_event = .{ .text_start = .{
            .content_index = 0,
            .partial = syntheticAssistantMessage(&.{}),
        } } } });
    }

    fn emitSyntheticFloodToolEnd(self: *Loop) !void {
        self.synthetic_flood.tool_emitted = true;
        const body = try self.gpa.alloc(u8, synthetic_flood_tool_body_bytes);
        defer self.gpa.free(body);
        @memset(body, 't');
        const content = [_]ai.ToolResultContent{.{ .text = .{ .text = body } }};
        try self.applySyntheticEvent(.{ .tool_execution_end = .{
            .tool_call_id = "synthetic-flood-tool",
            .tool_name = "bash",
            .result = .{ .content = &content },
            .is_error = false,
        } });
    }

    fn applySyntheticEvent(self: *Loop, event: agent_mod.AgentEvent) !void {
        try self.transcript.apply(self.io, event);
        self.frame_events_applied += 1;
        self.dirty = true;
    }

    fn syntheticAssistantMessage(content: []const ai.AssistantContent) ai.AssistantMessage {
        return .{
            .content = content,
            .api = ai.KnownApi.faux,
            .provider = ai.KnownProvider.faux,
            .model = ai.faux.default_model_id,
            .usage = ai.protocol.emptyUsage(),
            .stop_reason = .stop,
            .timestamp = 0,
        };
    }

    fn nsToUs(ns: u64) u64 {
        return ns / std.time.ns_per_us;
    }

    fn applyEditorOp(self: *Loop, op: input.EditorOp) void {
        switch (op) {
            .move_left => _ = self.editor.moveLeft(),
            .move_right => _ = self.editor.moveRight(),
            .move_word_left => _ = self.editor.moveWordLeft(),
            .move_word_right => _ = self.editor.moveWordRight(),
            .move_up_history => _ = self.editor.historyPrev(),
            .move_down_history => _ = self.editor.historyNext(),
            .backspace => _ = self.editor.backspace(),
            .delete_forward => _ = self.editor.deleteForward(),
            .home => self.editor.moveHome(),
            .end => self.editor.moveEnd(),
            .clear => self.editor.clear(),
            .kill_to_end => _ = self.editor.killToEnd(),
            .kill_to_start => _ = self.editor.killToStart(),
            .kill_word_back => _ = self.editor.killWordBack(),
            .yank => self.editor.yank() catch {},
            .undo => _ = self.editor.undoLast(),
            .tab => {},
        }
    }

    fn submitPrompt(self: *Loop, action: input.Action) !void {
        if (self.editor.endsWithBackslash() and action == .submit) {
            _ = self.editor.removeTrailingBackslash();
            try self.editor.insertNewline();
            return;
        }
        const text = self.editor.text();
        if (text.len == 0) return;
        if (try self.dispatchSlashIfNeeded(text)) {
            self.editor.clear();
            return;
        }
        var expanded_buffer: [Editor.capacity]u8 = undefined;
        const expanded = try self.editor.expandedText(&expanded_buffer);
        const session = self.session orelse {
            self.submitted_prompt = .{};
            self.submitted_prompt.?.set(expanded);
            self.editor.pushHistory(expanded);
            self.editor.clear();
            return;
        };
        const wake = self.wake orelse return error.NoWake;
        switch (action) {
            .follow_up_submit => try self.driver.queuePrompt(self, session, expanded, .follow_up),
            .steer_submit => try self.driver.queuePrompt(self, session, expanded, .steer),
            else => if (self.driver.state == .running)
                try self.driver.queuePrompt(self, session, expanded, .steer)
            else
                try self.driver.submitPrompt(self, session, self.io, wake, expanded),
        }
        self.editor.pushHistory(expanded);
        self.editor.clear();
    }

    fn dispatchSlashIfNeeded(self: *Loop, text: []const u8) !bool {
        const action = slash_commands.dispatch(text) orelse return false;
        switch (action) {
            .help => {
                var buffer: [160]u8 = undefined;
                try self.notice(.info, slash_commands.formatAvailable(&buffer));
            },
            .session => try self.notice(.info, "session"),
            .model => |model| try self.noticeFmt(.warn, "unknown or unauthenticated model: {s}", .{model}),
            .resume_session => try self.notice(.info, "resumed session"),
            .new_session => try self.notice(.info, "started new session"),
            .compact => {
                const session = self.session orelse {
                    try self.notice(.info, "nothing to compact");
                    return true;
                };
                const wake = self.wake orelse return error.NoWake;
                try self.driver.startManualCompaction(self, session, self.io, wake);
            },
            .settings => try self.notice(.warn, "usage: /settings thinking:<off|minimal|low|medium|high|xhigh|shown|hidden>"),
            .thinking_level => |level| {
                const session = self.session orelse return true;
                try session.setThinkingLevel(level);
                self.dirty = true;
            },
            .hide_thinking => |hidden| {
                const session = self.session orelse return true;
                try session.setHideThinking(hidden);
                _ = self.layout_epoch.setHideThinking(hidden);
                self.dirty = true;
            },
            .unknown => |name| {
                var available: [160]u8 = undefined;
                const catalog = slash_commands.formatAvailable(&available);
                try self.noticeFmt(.warn, "unknown command /{s} — {s}", .{ name, catalog });
            },
        }
        return true;
    }

    fn dequeueAll(self: *Loop) !void {
        const session = self.session orelse return;
        try self.restoreQueuedText(session);
    }

    fn restoreQueuedText(self: *Loop, session: *coding_agent.AgentSession) !void {
        if (self.editor.text().len != 0) return;
        const echoes = session.queuedEchoes();
        for (echoes, 0..) |echo, index| {
            if (index > 0) try self.editor.insert("\n");
            try self.editor.insert(echo.text);
        }
        session.clearQueue();
        self.dirty = true;
    }

    fn handleCancel(self: *Loop) void {
        self.clearExitHint();
        if (self.driver.state != .idle) {
            const session = self.session orelse return;
            self.driver.cancel(self, session);
        }
    }

    fn handleClearOrQuit(self: *Loop, now_ns: u64) void {
        if (self.ctrl_c_deadline_ns) |deadline| {
            if (now_ns <= deadline) {
                self.exit_requested = true;
                return;
            }
        }
        if (self.editor.text().len != 0) self.editor.clear();
        self.exit_hint_visible = true;
        self.ctrl_c_deadline_ns = now_ns +| double_key_window_ns;
    }

    fn clearExitHint(self: *Loop) void {
        self.ctrl_c_deadline_ns = null;
        self.exit_hint_visible = false;
    }
};

fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

test "loop dispatch edits text through editor actions" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "abc" });
    try loop.dispatch(.{ .key_editor = .move_left });
    try loop.dispatch(.{ .insert = "x" });
    try loop.dispatch(.{ .key_editor = .backspace });

    try std.testing.expectEqualStrings("abc", loop.editor.text());
    try std.testing.expect(!loop.exit_requested);
    try std.testing.expectEqual(@as(usize, 4), loop.trace.input_actions);
}

test "loop clear_or_quit clears first then exits" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "draft" });
    try loop.dispatch(.clear_or_quit);
    try std.testing.expectEqualStrings("", loop.editor.text());
    try std.testing.expect(!loop.exit_requested);
    try loop.dispatch(.clear_or_quit);
    try std.testing.expect(loop.exit_requested);
}

test "loop submit snapshots editor and clears input" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "hello" });
    try loop.dispatch(.submit);

    try std.testing.expectEqualStrings("hello", loop.submittedPrompt().?);
    try std.testing.expectEqualStrings("", loop.editor.text());
    try std.testing.expect(loop.dirty);
}

test "loop dispatches mapped key actions end-to-end" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(input.fromKey(.{ .codepoint = 'a', .text = "a" }));
    try loop.dispatch(input.fromKey(.{ .codepoint = 'b', .text = "b" }));
    try loop.dispatch(input.fromKey(.{ .codepoint = vaxis.Key.left }));
    try loop.dispatch(input.fromKey(.{ .codepoint = vaxis.Key.backspace }));

    try std.testing.expectEqualStrings("b", loop.editor.text());
}

test "loop init seeds editor from initial prompt" {
    var loop = try Loop.init(std.testing.allocator, "hello");
    defer loop.deinit();
    try std.testing.expectEqualStrings("hello", loop.editor.text());
}

test "loop composes frame and clears dirty only after render success" {
    var loop = try Loop.init(std.testing.allocator, "draft");
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "!" });
    try std.testing.expect(loop.dirty);

    const frame = try loop.composeFrame(80, 2);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("> draft!", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 8), frame.cursor.?.col);
    try std.testing.expect(loop.dirty);
    loop.markRendered(1, 2);
    try std.testing.expect(!loop.dirty);
    try std.testing.expectEqual(@as(usize, 1), loop.trace.renders.count);
}

test "loop render timing honors dirty policy" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try std.testing.expect(!loop.shouldRender(frame_floor_ns - 1));
    try std.testing.expect(loop.shouldRender(frame_floor_ns));

    loop.markRendered(frame_floor_ns, 10 * std.time.ns_per_ms);
    loop.dirty = true;
    try std.testing.expect(!loop.shouldRender(frame_floor_ns + 29 * std.time.ns_per_ms));
    try std.testing.expect(loop.shouldRender(frame_floor_ns + 30 * std.time.ns_per_ms));
}

test "loop ctrl-c hint expires on timer tick" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatchAt(.clear_or_quit, 100);
    try std.testing.expect(loop.exit_hint_visible);
    try std.testing.expectEqual(@as(?u64, 100 + double_key_window_ns), loop.nextTimerDeadlineNs());

    loop.dirty = false;
    try loop.tick(101 + double_key_window_ns);
    try std.testing.expect(!loop.exit_hint_visible);
    try std.testing.expect(loop.dirty);
}

test "loop records frame input and event counts on render" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    loop.recordInputBytes(3);
    try loop.dispatch(.{ .insert = "abc" });
    loop.markRendered(frame_floor_ns, 2 * std.time.ns_per_us);

    const record = loop.trace.frames.newest().?;
    try std.testing.expectEqual(@as(usize, 3), record.input_bytes);
    try std.testing.expectEqual(@as(usize, 1), record.events_applied);
    try std.testing.expectEqual(@as(u64, 2), record.paint_us);
}

test "loop synthetic flood feeds real transcript events at one megabyte per second" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    loop.io = std.testing.io;
    loop.enableSyntheticFlood(0);
    try loop.tick(std.time.ns_per_s);

    try std.testing.expectEqual(@as(u64, 1024 * 1024), loop.synthetic_flood.emitted_bytes);
    try std.testing.expectEqual(@as(usize, 1), loop.transcript.items.items.len);
    try std.testing.expect(loop.transcript.items.items[0].kind == .assistant);
    try std.testing.expect(loop.transcript.items.items[0].kind.assistant.truncated);
    try std.testing.expect(loop.frame_events_applied > 1);
    try std.testing.expect(loop.dirty);
}

test "loop synthetic flood emits large tool result and completes after duration" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    loop.io = std.testing.io;
    loop.enableSyntheticFlood(0);
    try loop.tick(synthetic_flood_duration_ns);

    try std.testing.expect(loop.synthetic_flood.completed);
    try std.testing.expect(loop.synthetic_flood.tool_emitted);
    try std.testing.expect(!loop.transcript.run_active);
    try std.testing.expectEqual(@as(u64, 30 * 1024 * 1024), loop.synthetic_flood.emitted_bytes);
    try std.testing.expect(loop.transcript.items.items.len >= 2);
    const tool = loop.transcript.items.items[1];
    try std.testing.expect(tool.kind == .tool);
    try std.testing.expect(tool.kind.tool.body_truncated);
    try std.testing.expectEqual(@as(usize, @import("blocks.zig").tool_body_bytes_max), tool.kind.tool.body.items.len);
}

test "loop slash help appends a notice" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "/help" });
    try loop.dispatch(.submit);
    try std.testing.expectEqual(@as(usize, 1), loop.transcript.items.items.len);
    try std.testing.expect(loop.transcript.items.items[0].kind == .notice);
}

const DriverTestFixture = struct {
    tmp: std.testing.TmpDir,
    task_runtime: *runtime.Runtime,
    provider: *ai.FauxProvider,
    session: *coding_agent.AgentSession,
    owner_loop: *Loop,
    wake: *runtime.WakeEvent,

    fn init(response_text: []const u8) !DriverTestFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
        errdefer task_runtime.deinit();
        const provider = try std.testing.allocator.create(ai.FauxProvider);
        errdefer std.testing.allocator.destroy(provider);
        provider.* = try ai.FauxProvider.init(std.testing.allocator, .{});
        errdefer provider.deinit();
        const content = [_]ai.AssistantContent{ai.faux.text(response_text)};
        const response = ai.faux.assistantMessage(&content, .{});
        try provider.setResponses(&.{response});
        try tmp.dir.createDirPath(std.testing.io, "agent");
        try tmp.dir.createDirPath(std.testing.io, "repo");
        const session = try std.testing.allocator.create(coding_agent.AgentSession);
        errdefer std.testing.allocator.destroy(session);
        session.* = try coding_agent.AgentSession.init(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir = "agent",
            .current_date = "2026-07-07",
            .session_id = "driver-test",
            .timestamp = "2026-07-07T00:00:00Z",
            .dir = tmp.dir,
            .task_runtime = task_runtime,
            .model = provider.getModel(),
            .stream = provider.apiProvider().stream,
        });
        errdefer {
            session.requestShutdown();
            session.deinit();
        }
        const owner_loop = try std.testing.allocator.create(Loop);
        errdefer std.testing.allocator.destroy(owner_loop);
        owner_loop.* = try Loop.init(std.testing.allocator, null);
        errdefer owner_loop.deinit();
        _ = try session.agent.subscribe(.{ .context = &owner_loop.transcript, .call_fn = Transcript.applyListener });
        const wake = try std.testing.allocator.create(runtime.WakeEvent);
        errdefer std.testing.allocator.destroy(wake);
        wake.* = .init;
        const fixture: DriverTestFixture = .{
            .tmp = tmp,
            .task_runtime = task_runtime,
            .provider = provider,
            .session = session,
            .owner_loop = owner_loop,
            .wake = wake,
        };
        owner_loop.bindSession(session, session.io, wake);
        return fixture;
    }

    fn deinit(self: *DriverTestFixture) void {
        self.owner_loop.shutdownDriver();
        self.session.requestShutdown();
        self.session.deinit();
        std.testing.allocator.destroy(self.session);
        self.owner_loop.deinit();
        std.testing.allocator.destroy(self.owner_loop);
        self.provider.deinit();
        std.testing.allocator.destroy(self.provider);
        std.testing.allocator.destroy(self.wake);
        self.task_runtime.deinit();
        self.tmp.cleanup();
    }
};

fn driveDriverUntilIdle(owner_loop: *Loop, max_iterations: usize) !void {
    for (0..max_iterations) |_| {
        try owner_loop.pumpDriver(nowNs(owner_loop.io));
        if (!owner_loop.driver.busy()) return;
        try runtime.yield();
    }
    return error.DriverDidNotSettle;
}

test "run driver streams a faux session into transcript" {
    var fixture = try DriverTestFixture.init("# hello\nstreamed markdown");
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "hi" });
    try fixture.owner_loop.dispatch(.submit);
    try driveDriverUntilIdle(fixture.owner_loop, 10_000);

    try std.testing.expectEqual(@as(usize, 2), fixture.owner_loop.transcript.items.items.len);
    try std.testing.expect(fixture.owner_loop.transcript.items.items[0].kind == .user);
    try std.testing.expect(fixture.owner_loop.transcript.items.items[1].kind == .assistant);
    const assistant = fixture.owner_loop.transcript.items.items[1].kind.assistant;
    try std.testing.expect(assistant.parts.items.len > 0);
    try std.testing.expectEqualStrings("# hello\nstreamed markdown", assistant.parts.items[0].text.items);
    try std.testing.expect(!fixture.owner_loop.transcript.run_active);
}

test "run driver queues steering and dequeue-all restores queued text" {
    var fixture = try DriverTestFixture.init("done");
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "first" });
    try fixture.owner_loop.dispatch(.submit);
    try std.testing.expect(fixture.owner_loop.driver.state == .running);

    try fixture.owner_loop.dispatch(.{ .insert = "steer" });
    try fixture.owner_loop.dispatch(.submit);
    try std.testing.expectEqual(@as(usize, 1), fixture.session.queuedEchoes().len);
    try std.testing.expectEqualStrings("", fixture.owner_loop.editor.text());

    try fixture.owner_loop.dispatch(.dequeue_all);
    try std.testing.expectEqualStrings("steer", fixture.owner_loop.editor.text());
    try std.testing.expectEqual(@as(usize, 0), fixture.session.queuedEchoes().len);
}

test "run cancel restores queued text into empty editor" {
    var fixture = try DriverTestFixture.init("done");
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "first" });
    try fixture.owner_loop.dispatch(.submit);
    try fixture.owner_loop.dispatch(.{ .insert = "steer" });
    try fixture.owner_loop.dispatch(.submit);
    try std.testing.expectEqual(@as(usize, 1), fixture.session.queuedEchoes().len);

    try fixture.owner_loop.dispatch(.cancel);
    try std.testing.expectEqualStrings("steer", fixture.owner_loop.editor.text());
    try std.testing.expectEqual(@as(usize, 0), fixture.session.queuedEchoes().len);
}
