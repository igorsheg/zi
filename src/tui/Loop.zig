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
const viewport_hint_buffer_len = 64;
const completion_popup_rows_max: usize = 8;
const completion_candidates_max: usize = 64;
const completion_text_bytes_max: usize = 256;
const picker_rows_max: usize = 128;
const picker_filter_bytes_max: usize = 128;
const picker_visible_rows_max: usize = 8;
const title_buffer_len: usize = 256;
const footer_buffer_len: usize = 256;
const header_buffer_len: usize = 256;

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

pub const Viewport = union(enum) {
    follow,
    anchored: Anchor,

    pub const Anchor = struct {
        item_seq: u64,
        line_in_item: u32,
        lines_below_seen: u32,
    };
};

const LineRef = struct {
    item_index: usize,
    line_in_item: usize,
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

const CompletionMode = enum { slash, file };

const CompletionCandidate = struct {
    label: [completion_text_bytes_max]u8 = undefined,
    label_len: u16 = 0,
    insert: [completion_text_bytes_max]u8 = undefined,
    insert_len: u16 = 0,
    detail: [completion_text_bytes_max]u8 = undefined,
    detail_len: u16 = 0,
    selectable: bool = true,

    fn set(self: *CompletionCandidate, label: []const u8, insert: []const u8, detail: []const u8, selectable: bool) void {
        self.label_len = copyBounded(self.label[0..], label);
        self.insert_len = copyBounded(self.insert[0..], insert);
        self.detail_len = copyBounded(self.detail[0..], detail);
        self.selectable = selectable;
    }

    fn labelSlice(self: *const CompletionCandidate) []const u8 {
        return self.label[0..self.label_len];
    }

    fn insertSlice(self: *const CompletionCandidate) []const u8 {
        return self.insert[0..self.insert_len];
    }

    fn detailSlice(self: *const CompletionCandidate) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

const CompletionPopup = struct {
    active: bool = false,
    mode: CompletionMode = .slash,
    candidates: [completion_candidates_max]CompletionCandidate = undefined,
    candidate_len: usize = 0,
    selected: usize = 0,

    fn clear(self: *CompletionPopup) void {
        self.active = false;
        self.candidate_len = 0;
        self.selected = 0;
    }

    fn reset(self: *CompletionPopup, mode: CompletionMode) void {
        self.active = true;
        self.mode = mode;
        self.candidate_len = 0;
        self.selected = 0;
    }

    fn append(self: *CompletionPopup, label: []const u8, insert: []const u8, detail: []const u8, selectable: bool) void {
        if (self.candidate_len == self.candidates.len) return;
        self.candidates[self.candidate_len].set(label, insert, detail, selectable);
        self.candidate_len += 1;
    }

    fn selectedCandidate(self: *const CompletionPopup) ?*const CompletionCandidate {
        if (!self.active or self.candidate_len == 0) return null;
        return &self.candidates[@min(self.selected, self.candidate_len - 1)];
    }

    fn move(self: *CompletionPopup, delta: i32) void {
        if (!self.active or self.candidate_len == 0) return;
        const len: i32 = @intCast(self.candidate_len);
        var next: i32 = @intCast(self.selected);
        next = @mod(next + delta, len);
        self.selected = @intCast(next);
    }
};

const PickerKind = enum { model, session };

const PickerRow = struct {
    id: [completion_text_bytes_max]u8 = undefined,
    id_len: u16 = 0,
    label: [completion_text_bytes_max]u8 = undefined,
    label_len: u16 = 0,
    detail: [completion_text_bytes_max]u8 = undefined,
    detail_len: u16 = 0,
    meta: [completion_text_bytes_max]u8 = undefined,
    meta_len: u16 = 0,
    model: ?ai.Model = null,
    authed: bool = true,

    fn set(self: *PickerRow, id: []const u8, label: []const u8, detail: []const u8, meta: []const u8, model: ?ai.Model, authed: bool) void {
        self.id_len = copyBounded(self.id[0..], id);
        self.label_len = copyBounded(self.label[0..], label);
        self.detail_len = copyBounded(self.detail[0..], detail);
        self.meta_len = copyBounded(self.meta[0..], meta);
        self.model = model;
        self.authed = authed;
    }

    fn idSlice(self: *const PickerRow) []const u8 {
        return self.id[0..self.id_len];
    }

    fn labelSlice(self: *const PickerRow) []const u8 {
        return self.label[0..self.label_len];
    }

    fn detailSlice(self: *const PickerRow) []const u8 {
        return self.detail[0..self.detail_len];
    }

    fn metaSlice(self: *const PickerRow) []const u8 {
        return self.meta[0..self.meta_len];
    }
};

const Picker = struct {
    active: bool = false,
    kind: PickerKind = .model,
    title: [64]u8 = undefined,
    title_len: u8 = 0,
    filter: [picker_filter_bytes_max]u8 = undefined,
    filter_len: u8 = 0,
    rows: [picker_rows_max]PickerRow = undefined,
    row_len: usize = 0,
    selected_row: ?usize = null,
    saved_editor: [Editor.capacity]u8 = undefined,
    saved_editor_len: usize = 0,

    fn reset(self: *Picker, kind: PickerKind, title: []const u8, saved_editor: []const u8) void {
        self.active = true;
        self.kind = kind;
        self.title_len = @intCast(copyBounded(self.title[0..], title));
        self.filter_len = 0;
        self.row_len = 0;
        self.selected_row = null;
        self.saved_editor_len = copyBounded(self.saved_editor[0..], saved_editor);
    }

    fn clear(self: *Picker) void {
        self.active = false;
        self.filter_len = 0;
        self.row_len = 0;
        self.selected_row = null;
        self.saved_editor_len = 0;
    }

    fn savedEditorSlice(self: *const Picker) []const u8 {
        return self.saved_editor[0..self.saved_editor_len];
    }

    fn titleSlice(self: *const Picker) []const u8 {
        return self.title[0..self.title_len];
    }

    fn filterSlice(self: *const Picker) []const u8 {
        return self.filter[0..self.filter_len];
    }

    fn appendRow(self: *Picker, id: []const u8, label: []const u8, detail: []const u8, meta: []const u8, model: ?ai.Model, authed: bool) void {
        if (self.row_len == self.rows.len) return;
        self.rows[self.row_len].set(id, label, detail, meta, model, authed);
        if (self.selected_row == null) self.selected_row = self.row_len;
        self.row_len += 1;
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
    viewport: Viewport = .follow,
    pending_scroll_lines: i32 = 0,
    last_transcript_rows: usize = 0,
    line_prefix: [Transcript.transcript_items_max + 1]usize = undefined,
    line_item_count: usize = 0,
    transcript_line_buffer: [screen.row_capacity]screen.Line = undefined,
    viewport_hint_buffer: [viewport_hint_buffer_len]u8 = undefined,
    viewport_hint: []const u8 = "",
    pending_rebuild_revision: ?u64 = null,
    trace_io_ready: bool = false,
    queue_buffers: [4][256]u8 = undefined,
    queue_lines: [4][]const u8 = undefined,
    status_buffer: [256]u8 = undefined,
    header_buffer: [header_buffer_len]u8 = undefined,
    footer_left_buffer: [footer_buffer_len]u8 = undefined,
    footer_right_buffer: [footer_buffer_len]u8 = undefined,
    terminal_title_buffer: [title_buffer_len]u8 = undefined,
    pending_title_update: bool = false,
    services: ?*coding_agent.runtime_services.RuntimeServices = null,
    completion: CompletionPopup = .{},
    picker: Picker = .{},
    completion_lines: [completion_popup_rows_max]screen.Line = undefined,
    picker_lines: [picker_visible_rows_max]screen.Line = undefined,
    file_index: ?coding_agent.file_completion.Index = null,
    file_index_task: ?runtime.Task(anyerror!coding_agent.file_completion.Index) = null,
    file_index_failed: bool = false,
    token_cache_entry_count: usize = 0,
    token_input_total: u64 = 0,
    token_output_total: u64 = 0,
    compaction_count: usize = 0,

    pub fn init(gpa: std.mem.Allocator, initial_prompt: ?[]const u8) !Loop {
        var self: Loop = .{ .gpa = gpa, .transcript = Transcript.init(gpa) };
        if (initial_prompt) |prompt| try self.editor.insert(prompt);
        return self;
    }

    pub fn dummyForShutdown(gpa: std.mem.Allocator) Loop {
        return .{ .gpa = gpa, .transcript = Transcript.init(gpa) };
    }

    pub fn deinit(self: *Loop) void {
        if (self.file_index_task) |*task| {
            if (!task.hasResult()) task.cancel();
            var result = task.getResult() catch null;
            if (result) |*index| index.deinit(self.gpa);
        }
        if (self.file_index) |*index| index.deinit(self.gpa);
        self.transcript.deinit();
        self.* = undefined;
    }
    pub fn bindSession(self: *Loop, session: *coding_agent.AgentSession, io: std.Io, wake: *runtime.WakeEvent) void {
        self.session = session;
        self.io = io;
        self.wake = wake;
        self.trace_io_ready = true;
    }

    pub fn bindServices(self: *Loop, services: *coding_agent.runtime_services.RuntimeServices) !void {
        self.services = services;
        if (self.file_index == null and self.file_index_task == null and !self.file_index_failed) {
            self.file_index_task = try services.task_runtime.spawnBlocking(buildFileIndex, .{ self.gpa, services.dir });
        }
    }

    pub fn restoreSessionFold(self: *Loop) !void {
        const session = self.session orelse return;
        self.transcript.clear();
        self.editor.history_len = 0;
        self.editor.history_index = null;
        self.token_cache_entry_count = std.math.maxInt(usize);
        self.token_input_total = 0;
        self.token_output_total = 0;
        for (session.manager.entries.items) |entry| switch (entry) {
            .message => |message_entry| try self.restoreMessage(message_entry.message),
            .compaction => |compaction| try self.transcript.appendCompaction(compaction.summary, compaction.tokens_before),
            .model_change => |model_change| try self.noticeFmt(.info, "model: {s}/{s}", .{ model_change.provider, model_change.model_id }),
            .thinking_level_change => |change| try self.noticeFmt(.info, "thinking: {s}", .{change.thinking_level}),
        };
        self.refreshTokenCache();
        self.repinViewport();
        self.markLayoutRebuild();
        self.pending_title_update = true;
    }

    pub fn takePendingTitleUpdate(self: *Loop) bool {
        const pending = self.pending_title_update;
        self.pending_title_update = false;
        return pending;
    }

    pub fn terminalTitle(self: *Loop) []const u8 {
        const title = self.sessionTitle();
        const cwd = if (self.session) |session| session.manager.header.cwd else ".";
        const base = std.fs.path.basename(cwd);
        return std.fmt.bufPrint(&self.terminal_title_buffer, "zi - {s} - {s}", .{ title, base }) catch "zi";
    }

    pub fn enableSyntheticFlood(self: *Loop, start_ns: u64) void {
        self.synthetic_flood = .{ .enabled = true, .start_ns = start_ns, .emitted_bytes = 0 };
        self.dirty = true;
    }

    pub fn seedSyntheticItems(self: *Loop, count: usize) !void {
        for (0..count) |index| {
            var buffer: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, "seed item {d}", .{index});
            try self.transcript.appendNotice(.info, text);
        }
        self.dirty = true;
    }

    pub fn seedSyntheticTools(self: *Loop, io: std.Io, count: usize) !void {
        const body = "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\n";
        const content = [_]ai.ToolResultContent{.{ .text = .{ .text = body } }};
        for (0..count) |index| {
            var id_buffer: [64]u8 = undefined;
            const call_id = try std.fmt.bufPrint(&id_buffer, "seed-tool-{d}", .{index});
            try self.transcript.apply(io, .{ .tool_execution_end = .{
                .tool_call_id = call_id,
                .tool_name = "bash",
                .result = .{ .content = &content },
                .is_error = false,
            } });
        }
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
        if (try self.handlePickerAction(action)) return;
        if (try self.handleCompletionAction(action)) return;
        switch (action) {
            .insert => |text| {
                self.clearExitHint();
                try self.editor.insert(text);
                try self.refreshCompletion(.auto);
            },
            .key_editor => |op| {
                self.clearExitHint();
                self.applyEditorOp(op);
                try self.refreshCompletion(.auto);
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
            .expand_toggle => self.toggleExpanded(),
            .force_redraw => self.dirty = true,
            .scroll => |delta| self.queueViewportScroll(delta),
            .page_up => self.queueViewportPage(-1),
            .page_down => self.queueViewportPage(1),
            .none => {},
        }
    }

    pub fn submittedPrompt(self: *const Loop) ?[]const u8 {
        if (self.submitted_prompt) |*prompt| return prompt.text();
        return null;
    }

    pub fn composeFrame(self: *Loop, width: u16, height: u16) anyerror!screen.Frame {
        self.noteResize(width, height);
        self.refreshTokenCache();
        const rebuilt = try self.rebuildLineIndex(width);
        if (rebuilt) self.clampViewportAfterRebuild();

        const queue_lines = self.collectQueueLines();
        const popup_view = self.popupView();
        const picker_view = self.pickerView();
        const popup_rows = if (popup_view) |popup| popup.rows.len else 0;
        self.updateViewportHint();
        var transcript_rows = chrome.transcriptRowCapacityWithChrome(&self.editor, picker_view != null, queue_lines.len, self.viewport_hint.len, popup_rows, width, height);
        self.applyPendingViewportMotion(transcript_rows);
        self.updateViewportHint();
        transcript_rows = chrome.transcriptRowCapacityWithChrome(&self.editor, picker_view != null, queue_lines.len, self.viewport_hint.len, popup_rows, width, height);
        const transcript_lines = self.collectTranscriptLines(transcript_rows);
        self.last_transcript_rows = transcript_rows;

        return chrome.compose(.{
            .header = self.headerText(),
            .status = self.statusText(),
            .footer_left = self.footerLeftText(),
            .footer_right = self.footerRightText(),
            .footer_right_style = self.footerRightStyle(),
            .scratch_text = self.scratch.text(),
            .transcript_lines = transcript_lines,
            .queue_lines = queue_lines,
            .viewport_hint = self.viewport_hint,
            .editor = &self.editor,
            .editor_border_style = self.editorBorderStyle(),
            .popup = popup_view,
            .picker = picker_view,
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
        const had_width = self.last_width != 0;
        const old_revision = self.layout_epoch.revision;
        const changed = self.layout_epoch.resize(width, height);
        self.last_width = width;
        self.last_height = height;
        if (had_width and changed and self.layout_epoch.revision != old_revision) self.markLayoutRebuild();
        self.dirty = true;
    }

    pub fn markRendered(self: *Loop, now_ns: u64, render_cost_ns: u64) void {
        self.last_flush_ns = now_ns;
        self.trace.recordRender(render_cost_ns);
        self.trace.recordTranscriptEvictions(self.transcript.evicted_seqs);
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
        const file_index_changed = try self.pollFileIndexTask();
        if (file_index_changed and self.completion.active and self.completion.mode == .file) try self.refreshCompletion(.force_file);
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

    fn rebuildLineIndex(self: *Loop, width: u16) !bool {
        const rebuild_pending = self.pending_rebuild_revision != null;
        const start_ns = if (rebuild_pending) traceNowNs() else 0;
        var total: usize = 0;
        self.line_prefix[0] = 0;
        self.line_item_count = self.transcript.items.items.len;
        for (self.transcript.items.items, 0..) |item, index| {
            const lines = try self.transcript.itemLines(item, width, self.layout_epoch);
            total += lines.len;
            self.line_prefix[index + 1] = total;
        }
        if (rebuild_pending) {
            const elapsed_ns = traceNowNs() -| start_ns;
            self.trace.recordRebuild(elapsed_ns);
            self.pending_rebuild_revision = null;
        }
        return rebuild_pending;
    }

    fn collectTranscriptLines(self: *Loop, rows: usize) []const screen.Line {
        const visible_rows = @min(rows, self.transcript_line_buffer.len);
        if (visible_rows == 0 or self.totalTranscriptLines() == 0) return &.{};

        var absolute = self.viewportStart(visible_rows);
        var count: usize = 0;
        while (count < visible_rows and absolute < self.totalTranscriptLines()) : (absolute += 1) {
            const ref = self.lineRefAt(absolute) orelse break;
            const item = self.transcript.items.items[ref.item_index];
            self.transcript_line_buffer[count] = item.lines[ref.line_in_item];
            count += 1;
        }
        return self.transcript_line_buffer[0..count];
    }

    fn totalTranscriptLines(self: *const Loop) usize {
        return if (self.line_item_count == 0) 0 else self.line_prefix[self.line_item_count];
    }

    fn itemLineCount(self: *const Loop, item_index: usize) usize {
        return self.line_prefix[item_index + 1] - self.line_prefix[item_index];
    }

    fn lineRefAt(self: *const Loop, absolute: usize) ?LineRef {
        if (absolute >= self.totalTranscriptLines()) return null;
        var index: usize = 0;
        while (index < self.line_item_count) : (index += 1) {
            if (absolute < self.line_prefix[index + 1]) {
                return .{ .item_index = index, .line_in_item = absolute - self.line_prefix[index] };
            }
        }
        return null;
    }

    fn viewportStart(self: *const Loop, rows: usize) usize {
        const total = self.totalTranscriptLines();
        if (total == 0) return 0;
        const visible_rows = @max(@as(usize, 1), @min(rows, total));
        const max_start = total - visible_rows;
        return switch (self.viewport) {
            .follow => max_start,
            .anchored => |anchor| if (self.anchorAbsolute(anchor)) |absolute| @min(absolute, max_start) else 0,
        };
    }

    fn anchorAbsolute(self: *const Loop, anchor: Viewport.Anchor) ?usize {
        for (self.transcript.items.items[0..self.line_item_count], 0..) |item, index| {
            if (item.seq != anchor.item_seq) continue;
            const line_count = self.itemLineCount(index);
            if (line_count == 0) return self.line_prefix[index];
            return self.line_prefix[index] + @min(@as(usize, anchor.line_in_item), line_count - 1);
        }
        return null;
    }

    fn linesBelow(self: *const Loop, absolute: usize) u32 {
        const total = self.totalTranscriptLines();
        const below = total -| @min(total, absolute +| 1);
        return @intCast(@min(below, @as(usize, std.math.maxInt(u32))));
    }

    fn clampViewportAfterRebuild(self: *Loop) void {
        self.normalizeAnchoredViewport(true);
    }

    fn normalizeAnchoredViewport(self: *Loop, reset_seen: bool) void {
        switch (self.viewport) {
            .follow => return,
            .anchored => |*anchor| {
                for (self.transcript.items.items[0..self.line_item_count], 0..) |item, index| {
                    if (item.seq != anchor.item_seq) continue;
                    const line_count = self.itemLineCount(index);
                    if (line_count == 0) {
                        anchor.line_in_item = 0;
                        anchor.lines_below_seen = 0;
                        return;
                    }
                    const clamped_line = @min(@as(usize, anchor.line_in_item), line_count - 1);
                    const changed = clamped_line != @as(usize, anchor.line_in_item);
                    anchor.line_in_item = @intCast(clamped_line);
                    if (reset_seen or changed) anchor.lines_below_seen = self.linesBelow(self.line_prefix[index] + clamped_line);
                    return;
                }
                self.anchorOldestLiveLine();
            },
        }
    }

    fn anchorOldestLiveLine(self: *Loop) void {
        if (self.line_item_count == 0 or self.totalTranscriptLines() == 0) {
            self.viewport = .follow;
            return;
        }
        const item = self.transcript.items.items[0];
        self.viewport = .{ .anchored = .{
            .item_seq = item.seq,
            .line_in_item = 0,
            .lines_below_seen = self.linesBelow(0),
        } };
    }

    fn setAnchorAtAbsolute(self: *Loop, absolute: usize) void {
        const ref = self.lineRefAt(absolute) orelse {
            self.viewport = .follow;
            return;
        };
        const item = self.transcript.items.items[ref.item_index];
        self.viewport = .{ .anchored = .{
            .item_seq = item.seq,
            .line_in_item = @intCast(ref.line_in_item),
            .lines_below_seen = self.linesBelow(absolute),
        } };
    }

    fn updateViewportHint(self: *Loop) void {
        self.viewport_hint = "";
        self.normalizeAnchoredViewport(false);
        switch (self.viewport) {
            .follow => {},
            .anchored => |anchor| {
                const absolute = self.anchorAbsolute(anchor) orelse return;
                const new_lines = self.linesBelow(absolute) -| anchor.lines_below_seen;
                if (new_lines > 0) {
                    self.viewport_hint = std.fmt.bufPrint(&self.viewport_hint_buffer, "↓ {d} new lines", .{new_lines}) catch "";
                }
            },
        }
    }

    fn applyPendingViewportMotion(self: *Loop, rows: usize) void {
        const delta = self.pending_scroll_lines;
        self.pending_scroll_lines = 0;
        if (delta == 0 or rows == 0) return;
        const total = self.totalTranscriptLines();
        if (total == 0) {
            self.viewport = .follow;
            return;
        }
        const visible_rows = @max(@as(usize, 1), @min(rows, total));
        const max_start = total - visible_rows;
        if (delta > 0) {
            switch (self.viewport) {
                .follow => return,
                .anchored => {},
            }
        }

        const start = self.viewportStart(visible_rows);
        const target_signed = @as(i64, @intCast(start)) + @as(i64, delta);
        const target = if (target_signed <= 0) 0 else @min(@as(usize, @intCast(target_signed)), max_start);
        if (delta > 0 and target >= max_start) {
            self.viewport = .follow;
        } else {
            self.setAnchorAtAbsolute(target);
        }
    }

    fn queueViewportScroll(self: *Loop, delta: i32) void {
        const next = @as(i64, self.pending_scroll_lines) + @as(i64, delta);
        self.pending_scroll_lines = @intCast(std.math.clamp(next, -100_000, 100_000));
        self.dirty = true;
    }

    fn queueViewportPage(self: *Loop, direction: i32) void {
        const page_rows = if (self.last_transcript_rows > 2) self.last_transcript_rows - 2 else 1;
        self.queueViewportScroll(direction * @as(i32, @intCast(page_rows)));
    }

    fn repinViewport(self: *Loop) void {
        self.viewport = .follow;
        self.pending_scroll_lines = 0;
        self.viewport_hint = "";
    }

    fn toggleExpanded(self: *Loop) void {
        if (self.layout_epoch.setExpanded(!self.layout_epoch.expanded)) self.markLayoutRebuild();
        self.dirty = true;
    }

    fn setHideThinking(self: *Loop, hidden: bool) void {
        if (self.layout_epoch.setHideThinking(hidden)) self.markLayoutRebuild();
        self.dirty = true;
    }

    fn markLayoutRebuild(self: *Loop) void {
        self.transcript.markAllDirty();
        self.pending_rebuild_revision = self.layout_epoch.revision;
        self.dirty = true;
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
        return "";
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

    fn headerText(self: *Loop) []const u8 {
        const session = self.session orelse return "zi";
        const title = self.sessionTitle();
        if (self.compaction_count > 0) {
            return std.fmt.bufPrint(
                &self.header_buffer,
                "zi · {s} · {s} · thinking:{s} · compacted {d} times",
                .{ title, session.agent.state.model.id, @tagName(session.agent.state.thinking_level), self.compaction_count },
            ) catch "zi";
        }
        return std.fmt.bufPrint(
            &self.header_buffer,
            "zi · {s} · {s} · thinking:{s}",
            .{ title, session.agent.state.model.id, @tagName(session.agent.state.thinking_level) },
        ) catch "zi";
    }

    fn footerLeftText(self: *Loop) []const u8 {
        const cwd = if (self.session) |session| session.manager.header.cwd else ".";
        const home = if (self.services) |services| blk: {
            const environ = services.environ orelse break :blk null;
            break :blk environ.get("HOME") orelse environ.get("USERPROFILE");
        } else null;
        if (home) |home_dir| {
            if (home_dir.len != 0 and std.mem.eql(u8, cwd, home_dir)) return "~";
            if (home_dir.len != 0 and cwd.len > home_dir.len and std.mem.startsWith(u8, cwd, home_dir) and std.fs.path.isSep(cwd[home_dir.len])) {
                return std.fmt.bufPrint(&self.footer_left_buffer, "~{s}", .{cwd[home_dir.len..]}) catch cwd;
            }
        }
        return std.fmt.bufPrint(&self.footer_left_buffer, "{s}", .{cwd}) catch cwd;
    }

    fn footerRightText(self: *Loop) []const u8 {
        const session = self.session orelse return "";
        const usage = session.contextUsage();
        if (usage.percent_tenths) |tenths| {
            return std.fmt.bufPrint(
                &self.footer_right_buffer,
                "ctx {d}.{d}% ↑{d} ↓{d} tokens",
                .{ tenths / 10, tenths % 10, self.token_input_total, self.token_output_total },
            ) catch "ctx";
        }
        return std.fmt.bufPrint(
            &self.footer_right_buffer,
            "ctx -- ↑{d} ↓{d} tokens",
            .{ self.token_input_total, self.token_output_total },
        ) catch "ctx";
    }

    fn footerRightStyle(self: *Loop) screen.Style {
        const session = self.session orelse return screen.styles.muted;
        const tenths = session.contextUsage().percent_tenths orelse return screen.styles.muted;
        if (tenths > 900) return screen.styles.error_;
        if (tenths >= 700) return screen.styles.warn;
        return screen.styles.ok;
    }

    fn sessionTitle(self: *Loop) []const u8 {
        const session = self.session orelse return "session";
        for (session.manager.entries.items) |entry| {
            if (entry != .message or entry.message.message != .user) continue;
            const text = restoredUserText(entry.message.message.user);
            if (text.len == 0) continue;
            return text[0..@min(text.len, @as(usize, 64))];
        }
        if (session.manager.header.id.len != 0) return session.manager.header.id;
        return "session";
    }

    fn refreshTokenCache(self: *Loop) void {
        const session = self.session orelse return;
        if (self.token_cache_entry_count == session.manager.entries.items.len) return;
        self.token_cache_entry_count = session.manager.entries.items.len;
        self.token_input_total = 0;
        self.token_output_total = 0;
        self.compaction_count = 0;
        for (session.manager.entries.items) |entry| switch (entry) {
            .message => |message| {
                if (message.message != .assistant) continue;
                const usage = message.message.assistant.usage;
                self.token_input_total +|= usage.input +| usage.cache_read +| usage.cache_write;
                self.token_output_total +|= usage.output;
            },
            .compaction => self.compaction_count += 1,
            .model_change, .thinking_level_change => {},
        };
    }

    fn popupView(self: *Loop) ?chrome.PopupView {
        if (!self.completion.active or self.completion.candidate_len == 0 or self.picker.active) return null;
        const count = @min(self.completion.candidate_len, self.completion_lines.len);
        for (self.completion.candidates[0..count], 0..) |candidate, index| {
            var line: screen.Line = .{};
            line.append(.{ .text = candidate.labelSlice(), .style = if (index == self.completion.selected) screen.styles.accent else screen.styles.normal }) catch {};
            if (candidate.detailSlice().len > 0) {
                line.append(.{ .text = "  ", .style = screen.styles.muted }) catch {};
                line.append(.{ .text = candidate.detailSlice(), .style = screen.styles.muted }) catch {};
            }
            self.completion_lines[index] = line;
        }
        return .{ .rows = self.completion_lines[0..count], .selected = self.completion.selected };
    }

    fn pickerView(self: *Loop) ?chrome.PickerView {
        if (!self.picker.active) return null;
        var visible: [picker_rows_max]usize = undefined;
        const rows = self.filteredPickerRows(&visible);
        const offset = self.pickerVisibleOffset(rows);
        const count = @min(rows.len -| offset, self.picker_lines.len);
        for (rows[offset..][0..count], 0..) |row_index, visible_index| {
            const row = &self.picker.rows[row_index];
            var line: screen.Line = .{};
            line.append(.{ .text = row.labelSlice(), .style = if (self.picker.selected_row == row_index) screen.styles.accent else screen.styles.normal }) catch {};
            if (row.detailSlice().len > 0) {
                line.append(.{ .text = "  ", .style = screen.styles.muted }) catch {};
                line.append(.{ .text = row.detailSlice(), .style = screen.styles.muted }) catch {};
            }
            if (row.metaSlice().len > 0) {
                line.append(.{ .text = "  ", .style = screen.styles.muted }) catch {};
                line.append(.{ .text = row.metaSlice(), .style = screen.styles.muted }) catch {};
            }
            self.picker_lines[visible_index] = line;
        }
        return .{ .title = self.picker.titleSlice(), .filter = self.picker.filterSlice(), .rows = self.picker_lines[0..count], .selected = self.pickerSelectedVisibleIndex(rows, offset) };
    }

    fn pickerVisibleOffset(self: *Loop, rows: []const usize) usize {
        const selected = self.picker.selected_row orelse return 0;
        var selected_visible: usize = 0;
        for (rows, 0..) |row_index, index| if (row_index == selected) {
            selected_visible = index;
            break;
        };
        if (selected_visible >= picker_visible_rows_max) return selected_visible - picker_visible_rows_max + 1;
        return 0;
    }

    fn pickerSelectedVisibleIndex(self: *Loop, rows: []const usize, offset: usize) usize {
        const selected = self.picker.selected_row orelse return 0;
        for (rows[offset..@min(rows.len, offset + picker_visible_rows_max)], 0..) |row_index, index| {
            if (row_index == selected) return index;
        }
        return 0;
    }

    fn filteredPickerRows(self: *Loop, out: *[picker_rows_max]usize) []const usize {
        var count: usize = 0;
        const filter = self.picker.filterSlice();
        for (self.picker.rows[0..self.picker.row_len], 0..) |row, index| {
            if (filter.len != 0 and !fuzzyMatch(row.labelSlice(), filter) and !fuzzyMatch(row.detailSlice(), filter) and !fuzzyMatch(row.metaSlice(), filter)) continue;
            out[count] = index;
            count += 1;
        }
        return out[0..count];
    }

    fn pollFileIndexTask(self: *Loop) !bool {
        if (self.file_index_task) |*task| {
            if (!task.hasResult()) return false;
            const index = task.getResult() catch |err| {
                self.file_index_failed = true;
                self.file_index_task = null;
                try self.noticeFmt(.warn, "file index unavailable: {s}", .{@errorName(err)});
                return true;
            };
            self.file_index = index;
            self.file_index_task = null;
            self.dirty = true;
            return true;
        }
        return false;
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

    const CompletionRefresh = enum { auto, force_file };

    fn handlePickerAction(self: *Loop, action: input.Action) !bool {
        if (!self.picker.active) return false;
        switch (action) {
            .cancel => {
                try self.cancelPicker();
                return true;
            },
            .insert => |text| {
                if (self.picker.filter_len + text.len <= self.picker.filter.len and std.unicode.utf8ValidateSlice(text)) {
                    @memcpy(self.picker.filter[self.picker.filter_len..][0..text.len], text);
                    self.picker.filter_len += @intCast(text.len);
                    self.selectFirstVisiblePickerRow();
                }
                return true;
            },
            .key_editor => |op| {
                switch (op) {
                    .move_up_history => self.movePickerSelection(-1),
                    .move_down_history => self.movePickerSelection(1),
                    .backspace => self.pickerBackspace(),
                    .clear => {
                        self.picker.filter_len = 0;
                        self.selectFirstVisiblePickerRow();
                    },
                    else => {},
                }
                return true;
            },
            .submit => {
                try self.acceptPickerSelection();
                return true;
            },
            else => return true,
        }
    }

    fn handleCompletionAction(self: *Loop, action: input.Action) !bool {
        switch (action) {
            .cancel => if (self.completion.active) {
                self.completion.clear();
                self.dirty = true;
                return true;
            },
            .insert => |text| if (std.mem.eql(u8, text, "\t")) {
                if (self.completion.active) {
                    try self.acceptCompletion();
                } else {
                    try self.refreshCompletion(.force_file);
                }
                return true;
            },
            .key_editor => |op| switch (op) {
                .tab => {
                    if (self.completion.active) {
                        try self.acceptCompletion();
                    } else {
                        try self.refreshCompletion(.force_file);
                    }
                    return true;
                },
                .move_up_history => if (self.completion.active) {
                    self.completion.move(-1);
                    return true;
                },
                .move_down_history => if (self.completion.active) {
                    self.completion.move(1);
                    return true;
                },
                else => {},
            },
            .submit => if (self.completion.active) {
                if (self.completion.mode == .slash and slash_commands.dispatch(self.editor.text()) != null) return false;
                try self.acceptCompletion();
                return true;
            },
            else => {},
        }
        return false;
    }

    fn refreshCompletion(self: *Loop, mode: CompletionRefresh) !void {
        if (self.picker.active) return;
        const token = self.editor.currentToken() orelse blk: {
            if (mode != .force_file) {
                self.completion.clear();
                return;
            }
            const cursor = self.editor.cursorByte();
            break :blk Editor.Token{ .start = cursor, .end = cursor, .text = self.editor.text()[cursor..cursor] };
        };
        if (mode == .force_file) return self.refreshFileCompletion(token, true);
        if (std.mem.startsWith(u8, token.text, "/")) return self.refreshSlashCompletion(token.text);
        if (std.mem.startsWith(u8, token.text, "@")) return self.refreshFileCompletion(token, false);
        if (std.mem.startsWith(u8, self.editor.text(), "/settings ") and std.mem.startsWith(u8, token.text, "thinking:")) return self.refreshSettingsCompletion(token.text);
        self.completion.clear();
    }

    fn refreshSlashCompletion(self: *Loop, token_text: []const u8) !void {
        self.completion.reset(.slash);
        for (slash_commands.builtins) |command| {
            var label_buffer: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "/{s}", .{command.name}) catch continue;
            if (!startsWithIgnoreCase(label, token_text)) continue;
            var insert_buffer: [80]u8 = undefined;
            const insert = std.fmt.bufPrint(&insert_buffer, "/{s} ", .{command.name}) catch label;
            self.completion.append(label, insert, command.summary, true);
        }
        if (self.completion.candidate_len == 0) self.completion.clear();
    }

    fn refreshSettingsCompletion(self: *Loop, token_text: []const u8) !void {
        self.completion.reset(.slash);
        const values = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "shown", "hidden" };
        for (values) |value| {
            var label_buffer: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "thinking:{s}", .{value}) catch continue;
            if (!startsWithIgnoreCase(label, token_text)) continue;
            self.completion.append(label, label, "", true);
        }
        if (self.completion.candidate_len == 0) self.completion.clear();
    }

    fn refreshFileCompletion(self: *Loop, token: Editor.Token, forced: bool) !void {
        self.completion.reset(.file);
        _ = try self.pollFileIndexTask();
        if (self.file_index == null) {
            self.completion.append(if (self.file_index_failed) "file index unavailable" else "indexing files…", "", "", false);
            return;
        }
        const raw = if (std.mem.startsWith(u8, token.text, "@")) token.text[1..] else token.text;
        if (!forced and token.text.len == 0) {
            self.completion.clear();
            return;
        }
        var result = try self.file_index.?.query(self.gpa, raw);
        defer result.destroy(self.gpa);
        var sources_buffer: [coding_agent.file_completion.item_count_max]coding_agent.file_completion.Source = undefined;
        const sources = result.sources(&sources_buffer);
        for (sources) |source| {
            var insert_buffer: [completion_text_bytes_max]u8 = undefined;
            const insert = std.fmt.bufPrint(&insert_buffer, "@{s}", .{source.id}) catch continue;
            self.completion.append(source.label, insert, source.detail, true);
        }
        if (self.completion.candidate_len == 0) self.completion.clear();
    }

    fn acceptCompletion(self: *Loop) !void {
        const candidate = self.completion.selectedCandidate() orelse return;
        if (!candidate.selectable) return;
        const token = self.editor.currentToken() orelse blk: {
            const cursor = self.editor.cursorByte();
            break :blk Editor.Token{ .start = cursor, .end = cursor, .text = self.editor.text()[cursor..cursor] };
        };
        try self.editor.replaceToken(token, candidate.insertSlice());
        self.completion.clear();
        self.dirty = true;
    }

    fn selectFirstVisiblePickerRow(self: *Loop) void {
        var visible: [picker_rows_max]usize = undefined;
        const rows = self.filteredPickerRows(&visible);
        self.picker.selected_row = if (rows.len == 0) null else rows[0];
        self.dirty = true;
    }

    fn movePickerSelection(self: *Loop, delta: i32) void {
        var visible: [picker_rows_max]usize = undefined;
        const rows = self.filteredPickerRows(&visible);
        if (rows.len == 0) {
            self.picker.selected_row = null;
            return;
        }
        var current: usize = 0;
        if (self.picker.selected_row) |selected| for (rows, 0..) |row_index, index| {
            if (row_index == selected) {
                current = index;
                break;
            }
        };
        const len: i32 = @intCast(rows.len);
        const next = @mod(@as(i32, @intCast(current)) + delta, len);
        self.picker.selected_row = rows[@intCast(next)];
        self.dirty = true;
    }

    fn pickerBackspace(self: *Loop) void {
        if (self.picker.filter_len == 0) return;
        self.picker.filter_len -= 1;
        while (self.picker.filter_len > 0 and (self.picker.filter[self.picker.filter_len] & 0xc0) == 0x80) self.picker.filter_len -= 1;
        self.selectFirstVisiblePickerRow();
    }

    fn cancelPicker(self: *Loop) !void {
        const saved = self.picker.savedEditorSlice();
        self.editor.clear();
        try self.editor.insert(saved);
        self.picker.clear();
        self.dirty = true;
    }

    fn acceptPickerSelection(self: *Loop) !void {
        const selected = self.picker.selected_row orelse return;
        const row = self.picker.rows[selected];
        const kind = self.picker.kind;
        self.picker.clear();
        switch (kind) {
            .model => if (row.model) |model| try self.applyModelSelection(model, row.authed),
            .session => try self.switchSession(.{ .resume_existing = .{ .session_file_name = row.idSlice() } }, "resumed session"),
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
        self.repinViewport();
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
            .session => try self.showSessionNotice(),
            .model => |model| {
                if (model.len == 0) {
                    try self.openModelPicker();
                } else {
                    try self.setModelByName(model);
                }
            },
            .resume_session => |selector| {
                if (selector.len == 0) {
                    try self.openSessionPicker();
                } else {
                    try self.switchSession(.{ .resume_existing = .{ .session_file_name = selector } }, "resumed session");
                }
            },
            .new_session => {
                var id_buffer: [64]u8 = undefined;
                const stamp = coding_agent.session_manager.SessionStamp.now(self.io);
                const id = std.fmt.bufPrint(&id_buffer, "tui-{d}", .{stamp.nanoseconds}) catch "tui";
                try self.switchSession(.{ .create = .{ .session_id = id, .timestamp = stamp.timestamp() } }, "started new session");
            },
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
                self.pending_title_update = true;
                self.dirty = true;
            },
            .hide_thinking => |hidden| {
                const session = self.session orelse return true;
                const services = self.services orelse return error.NoServices;
                try services.settings_manager.setHideThinkingBlock(self.io, services.dir, hidden);
                try session.setHideThinking(hidden);
                self.setHideThinking(hidden);
            },
            .unknown => |name| {
                var available: [160]u8 = undefined;
                const catalog = slash_commands.formatAvailable(&available);
                try self.noticeFmt(.warn, "unknown command /{s} — {s}", .{ name, catalog });
            },
        }
        return true;
    }

    fn showSessionNotice(self: *Loop) !void {
        const session = self.session orelse return;
        const usage = session.contextUsage();
        const file_name = if (session.store) |store| std.fs.path.basename(store.file_name) else session.manager.header.id;
        const tokens_text = if (usage.tokens) |tokens| tokens else 0;
        const percent_text = if (usage.percent_tenths) |tenths| tenths else 0;
        var buffer: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "session: {s}\ntitle: {s}\ncwd: {s}\nmodel: {s}/{s}\nthinking: {s}\ncontext: {d}/{d} ({d}.{d}%)\nentries: {d}",
            .{
                file_name,
                self.sessionTitle(),
                session.manager.header.cwd,
                session.agent.state.model.provider,
                session.agent.state.model.id,
                @tagName(session.agent.state.thinking_level),
                tokens_text,
                usage.window,
                percent_text / 10,
                percent_text % 10,
                session.manager.entries.items.len,
            },
        ) catch "session";
        try self.notice(.info, text);
    }

    fn openModelPicker(self: *Loop) !void {
        const services = self.services orelse return error.NoServices;
        self.picker.reset(.model, "Select model", self.editor.text());
        inline for (.{ true, false }) |want_authed| {
            for (ai.getProviders()) |provider_name| {
                for (ai.getModels(provider_name)) |model| {
                    if (services.provider_registry.get(model.api) == null) continue;
                    const authed = services.auth_manager.hasAuth(model.provider);
                    if (authed != want_authed) continue;
                    var label_buffer: [completion_text_bytes_max]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buffer, "{s}/{s}", .{ model.provider, model.id }) catch model.id;
                    self.picker.appendRow(label, label, model.name, if (authed) "" else "not authenticated", model, authed);
                }
            }
        }
        self.selectFirstVisiblePickerRow();
        self.completion.clear();
    }

    fn openSessionPicker(self: *Loop) !void {
        const services = self.services orelse return error.NoServices;
        var summaries = try coding_agent.session_listing.listRuntimeSessionSummaries(self.gpa, self.io, .{
            .cwd = services.cwd,
            .agent_dir_override = services.agent_dir,
            .dir = services.dir,
            .environ = services.environ,
        });
        defer summaries.deinit(self.gpa);
        self.picker.reset(.session, "Resume session", self.editor.text());
        for (summaries.items) |summary| {
            var meta_buffer: [completion_text_bytes_max]u8 = undefined;
            const meta = std.fmt.bufPrint(&meta_buffer, "{s} {s}", .{ summary.meta, summary.aux }) catch summary.meta;
            self.picker.appendRow(summary.file_name, summary.title, summary.detail, meta, null, true);
        }
        self.selectFirstVisiblePickerRow();
        self.completion.clear();
    }

    fn setModelByName(self: *Loop, name: []const u8) !void {
        const model = self.resolveModelName(name) orelse {
            try self.noticeFmt(.warn, "unknown or unauthenticated model: {s}", .{name});
            return;
        };
        try self.applyModelSelection(model, true);
    }

    fn resolveModelName(self: *Loop, name: []const u8) ?ai.Model {
        const services = self.services orelse return null;
        if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
            const provider = name[0..slash];
            const model_id = name[slash + 1 ..];
            const model = ai.getModel(provider, model_id) orelse return null;
            if (services.provider_registry.get(model.api) == null or !services.auth_manager.hasAuth(model.provider)) return null;
            return model;
        }
        for (ai.getProviders()) |provider_name| {
            for (ai.getModels(provider_name)) |model| {
                if (!std.mem.eql(u8, model.id, name)) continue;
                if (services.provider_registry.get(model.api) == null or !services.auth_manager.hasAuth(model.provider)) continue;
                return model;
            }
        }
        return null;
    }

    fn applyModelSelection(self: *Loop, model: ai.Model, authed: bool) !void {
        if (!authed) {
            try self.noticeFmt(.warn, "unknown or unauthenticated model: {s}", .{model.id});
            return;
        }
        const services = self.services orelse return error.NoServices;
        const session = self.session orelse return;
        try session.setModel(model, coding_agent.session_bootstrap.streamFor(services, model));
        self.pending_title_update = true;
        try self.noticeFmt(.info, "model: {s}/{s}", .{ model.provider, model.id });
    }

    fn switchSession(self: *Loop, spec: coding_agent.session_bootstrap.OpenSpec, notice_text: []const u8) !void {
        if (self.driver.state != .idle) {
            try self.notice(.warn, "finish or cancel the current run first");
            return;
        }
        const services = self.services orelse return error.NoServices;
        const current = self.session orelse return;
        const wake = self.wake orelse return error.NoWake;
        const stamp = coding_agent.session_manager.SessionStamp.now(self.io);
        var next = coding_agent.session_bootstrap.openSession(self.gpa, services, stamp.date(), spec, .{
            .model = current.agent.state.model,
            .thinking_level = current.agent.state.thinking_level,
            .stream = coding_agent.session_bootstrap.streamFor(services, current.agent.state.model),
        }) catch |err| {
            try self.noticeFmt(.err, "error: {s}", .{@errorName(err)});
            return;
        };
        var committed = false;
        errdefer if (!committed) {
            next.requestShutdown();
            next.deinit();
        };
        _ = try next.agent.subscribe(.{ .context = &self.transcript, .call_fn = Transcript.applyListener });
        self.shutdownSessionForSwitch(current, wake);
        current.* = next;
        committed = true;
        self.bindSession(current, self.io, wake);
        try self.restoreSessionFold();
        try self.notice(.info, notice_text);
        self.pending_title_update = true;
        self.dirty = true;
    }

    fn shutdownSessionForSwitch(self: *Loop, session: *coding_agent.AgentSession, wake: *runtime.WakeEvent) void {
        session.requestShutdown();
        const start = nowNs(self.io);
        while (!session.shutdownComplete() and nowNs(self.io) -| start < shutdown_cancel_bound_ns) {
            wake.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
            wake.reset();
        }
        session.deinit();
    }

    fn restoreMessage(self: *Loop, message: agent_mod.AgentMessage) !void {
        switch (message) {
            .user => |user| {
                try self.transcript.apply(self.io, .{ .message_start = .{ .message = .{ .user = user } } });
                self.editor.pushHistory(restoredUserText(user));
            },
            .assistant => |assistant| {
                try self.transcript.apply(self.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
                try self.transcript.apply(self.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
            },
            .tool_result => |tool_result| {
                try self.transcript.apply(self.io, .{ .tool_execution_end = .{
                    .tool_call_id = tool_result.tool_call_id,
                    .tool_name = tool_result.tool_name,
                    .result = .{ .content = tool_result.content, .details = tool_result.details, .terminate = false },
                    .is_error = tool_result.is_error,
                } });
            },
            .custom => {},
        }
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

fn traceNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = if (ts.sec <= 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec <= 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn buildFileIndex(allocator: std.mem.Allocator, dir: std.Io.Dir) anyerror!coding_agent.file_completion.Index {
    return coding_agent.file_completion.Index.build(allocator, dir);
}

fn copyBounded(dest: []u8, source: []const u8) u16 {
    const len = @min(dest.len, source.len);
    @memcpy(dest[0..len], source[0..len]);
    return @intCast(len);
}

fn restoredUserText(user: ai.UserMessage) []const u8 {
    return switch (user.content) {
        .string => |text| text,
        .blocks => |blocks| blk: {
            for (blocks) |block| if (block == .text) break :blk block.text.text;
            break :blk "";
        },
    };
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn fuzzyMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var hay_index: usize = 0;
    for (needle) |needle_byte| {
        const lower = std.ascii.toLower(needle_byte);
        while (hay_index < haystack.len and std.ascii.toLower(haystack[hay_index]) != lower) hay_index += 1;
        if (hay_index == haystack.len) return false;
        hay_index += 1;
    }
    return true;
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

test "loop viewport anchors while appended lines arrive" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.seedSyntheticItems(10);

    var frame = try loop.composeFrame(80, 10);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("seed item 6", frame.rows()[1].copyText(&buffer));

    try loop.dispatch(.{ .scroll = -3 });
    frame = try loop.composeFrame(80, 10);
    try std.testing.expectEqualStrings("seed item 3", frame.rows()[1].copyText(&buffer));

    try loop.transcript.appendNotice(.info, "new item");
    frame = try loop.composeFrame(80, 10);
    try std.testing.expectEqualStrings("seed item 3", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("↓ 1 new lines", frame.rows()[4].copyText(&buffer));
}

test "loop viewport clamps to oldest live item after eviction" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.seedSyntheticItems(Transcript.transcript_items_max);
    _ = try loop.composeFrame(80, 8);

    try loop.dispatch(.{ .scroll = -100_000 });
    _ = try loop.composeFrame(80, 8);
    for (0..10) |index| {
        var text: [32]u8 = undefined;
        try loop.transcript.appendNotice(.info, try std.fmt.bufPrint(&text, "extra {d}", .{index}));
    }

    const frame = try loop.composeFrame(80, 8);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("seed item 10", frame.rows()[1].copyText(&buffer));
}

test "loop viewport clamps line within anchored item on width rebuild" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.transcript.appendNotice(.info, "abcdefghijklmnopqrstuvwxyz");
    _ = try loop.composeFrame(10, 6);
    loop.setAnchorAtAbsolute(2);
    const anchored_seq = loop.viewport.anchored.item_seq;

    _ = try loop.composeFrame(80, 6);
    try std.testing.expect(loop.viewport == .anchored);
    try std.testing.expectEqual(anchored_seq, loop.viewport.anchored.item_seq);
    try std.testing.expectEqual(@as(u32, 0), loop.viewport.anchored.line_in_item);
}

test "loop submit repins viewport to follow" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.seedSyntheticItems(10);
    _ = try loop.composeFrame(80, 8);
    try loop.dispatch(.{ .scroll = -3 });
    _ = try loop.composeFrame(80, 8);
    try std.testing.expect(loop.viewport == .anchored);

    try loop.dispatch(.{ .insert = "hello" });
    try loop.dispatch(.submit);
    try std.testing.expect(loop.viewport == .follow);
}

test "loop omits blank assistant rows for tool-call-only turns" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();

    try loop.transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = "Run tools" }, .timestamp = 0 } } } });

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "command", .{ .string = "pwd" });
    const call = ai.ToolCall{ .id = "call-1", .name = "bash", .arguments = .{ .object = args_object } };
    const tool_content = [_]ai.AssistantContent{.{ .tool_call = call }};
    const tool_assistant = Loop.syntheticAssistantMessage(&tool_content);
    try loop.transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = tool_assistant } } });
    try loop.transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .toolcall_start = .{
        .content_index = 0,
        .partial = tool_assistant,
    } } } });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "/tmp/repo" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .result = .{ .content = &result_content },
        .is_error = false,
    } });
    try loop.transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = tool_assistant } } });

    const final_content = [_]ai.AssistantContent{.{ .text = .{ .text = "Done" } }};
    const final_assistant = Loop.syntheticAssistantMessage(&final_content);
    try loop.transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = final_assistant } } });
    try loop.transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = final_assistant } } });

    const frame = try loop.composeFrame(80, 12);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Run tools", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("[done] $ pwd", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqualStrings("/tmp/repo", frame.rows()[3].copyText(&buffer));
    try std.testing.expectEqualStrings("Done", frame.rows()[4].copyText(&buffer));
}

test "loop thinking relayout preserves anchored item" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.seedSyntheticItems(5);

    const thinking_content = [_]ai.AssistantContent{.{ .thinking = .{ .thinking = "one two three four five six seven eight nine ten" } }};
    const thinking_assistant = Loop.syntheticAssistantMessage(&thinking_content);
    try loop.transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = thinking_assistant } } });
    try loop.transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = thinking_assistant } } });

    for (0..8) |index| {
        var text: [32]u8 = undefined;
        try loop.transcript.appendNotice(.info, try std.fmt.bufPrint(&text, "after {d}", .{index}));
    }
    const anchor_item = loop.transcript.items.items[8];
    loop.viewport = .{ .anchored = .{ .item_seq = anchor_item.seq, .line_in_item = 0, .lines_below_seen = 0 } };

    var frame = try loop.composeFrame(10, 8);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("after 2", frame.rows()[1].copyText(&buffer));

    loop.setHideThinking(false);
    frame = try loop.composeFrame(10, 8);
    try std.testing.expectEqualStrings("after 2", frame.rows()[1].copyText(&buffer));
}

test "loop collapsed tool body ending newline has no blank before marker" {
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "one\ntwo\nthree\nfour\nfive\nsix\n" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .result = .{ .content = &result_content },
        .is_error = false,
    } });

    const frame = try loop.composeFrame(80, 12);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("five", frame.rows()[5].copyText(&buffer));
    try std.testing.expectEqualStrings("… 1 more lines (ctrl+o)", frame.rows()[6].copyText(&buffer));
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

test "loop P4 header footer cache assistant usage" {
    var fixture = try DriverTestFixture.init("done");
    defer fixture.deinit();

    const content = [_]ai.AssistantContent{ai.faux.text("usage-bearing reply")};
    var assistant = ai.faux.assistantMessage(&content, .{});
    assistant.usage.input = 70;
    assistant.usage.output = 30;
    assistant.usage.total_tokens = 100;
    const entry = try fixture.session.manager.prepareMessageEntry(.{ .assistant = assistant }, "2026-07-07T00:00:00Z");
    _ = fixture.session.manager.commitPreparedEntry(entry);

    const frame = try fixture.owner_loop.composeFrame(80, 6);
    var buffer: [160]u8 = undefined;
    const header = frame.rows()[0].copyText(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, header, "driver-test") != null);
    const footer = frame.rows()[frame.rows().len - 1].copyText(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 0.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↑70 ↓30 tokens") != null);
}

test "loop P4 header shows compaction count" {
    var fixture = try DriverTestFixture.init("done");
    defer fixture.deinit();

    const user_entry = try fixture.session.manager.prepareMessageEntry(.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }, "2026-07-07T00:00:00Z");
    const first_kept_entry_id = fixture.session.manager.commitPreparedEntry(user_entry);
    const compaction_entry = try fixture.session.manager.prepareCompactionEntry("summary", first_kept_entry_id, 100, "2026-07-07T00:00:01Z");
    _ = fixture.session.manager.commitPreparedEntry(compaction_entry);

    const frame = try fixture.owner_loop.composeFrame(80, 6);
    var buffer: [160]u8 = undefined;
    const header = frame.rows()[0].copyText(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, header, "compacted 1 times") != null);
}

test "loop P4 restore fold renders durable user tool and assistant transcript" {
    var fixture = try DriverTestFixture.init("done");
    defer fixture.deinit();

    const user_entry = try fixture.session.manager.prepareMessageEntry(.{ .user = .{ .content = .{ .string = "Run pwd" }, .timestamp = 0 } }, "2026-07-07T00:00:00Z");
    _ = fixture.session.manager.commitPreparedEntry(user_entry);

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "command", .{ .string = "pwd" });
    const call = ai.ToolCall{ .id = "restore-call", .name = "bash", .arguments = .{ .object = args_object } };
    const tool_content = [_]ai.AssistantContent{.{ .tool_call = call }};
    const assistant = Loop.syntheticAssistantMessage(&tool_content);
    const assistant_entry = try fixture.session.manager.prepareMessageEntry(.{ .assistant = assistant }, "2026-07-07T00:00:01Z");
    _ = fixture.session.manager.commitPreparedEntry(assistant_entry);

    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "/tmp/repo" } }};
    const tool_entry = try fixture.session.manager.prepareMessageEntry(.{ .tool_result = .{
        .tool_call_id = "restore-call",
        .tool_name = "bash",
        .content = &result_content,
        .is_error = false,
        .timestamp = 0,
    } }, "2026-07-07T00:00:02Z");
    _ = fixture.session.manager.commitPreparedEntry(tool_entry);

    try fixture.owner_loop.restoreSessionFold();
    const frame = try fixture.owner_loop.composeFrame(80, 12);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Run pwd", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqualStrings("[done] $ pwd", frame.rows()[2].copyText(&buffer));
    try std.testing.expectEqualStrings("/tmp/repo", frame.rows()[3].copyText(&buffer));
}

test "loop P4 file completion popup accepts selected candidate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "" });

    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    loop.file_index = try coding_agent.file_completion.Index.build(std.testing.allocator, tmp.dir);

    try loop.dispatch(.{ .insert = "@ma" });
    try std.testing.expect(loop.completion.active);
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqualStrings("@main.zig", loop.editor.text());
}

test "loop P4 model picker applies faux model through services" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_ENABLE_FAUX_PROVIDER", "1");

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var services = try coding_agent.runtime_services.RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(std.testing.allocator, &services, stamp.date(), .{ .create = .{ .session_id = "picker-test", .timestamp = stamp.timestamp() } }, .{});
    defer {
        session.requestShutdown();
        session.deinit();
    }
    var wake: runtime.WakeEvent = .init;
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.bindServices(&services);
    loop.bindSession(&session, services.io, &wake);

    try loop.dispatch(.{ .insert = "/model" });
    try loop.dispatch(.submit);
    try std.testing.expect(loop.picker.active);
    try std.testing.expectEqual(PickerKind.model, loop.picker.kind);
    try loop.dispatch(.cancel);
    try std.testing.expect(!loop.picker.active);
    try std.testing.expectEqualStrings("/model", loop.editor.text());
    try loop.dispatch(.submit);
    try std.testing.expect(loop.picker.active);
    try loop.dispatch(.submit);
    try std.testing.expectEqualStrings(ai.faux.default_model_id, session.agent.state.model.id);
}

test "loop P4 settings thinking visibility persists through services" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var services = try coding_agent.runtime_services.RuntimeServices.init(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir = "agent",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(std.testing.allocator, &services, stamp.date(), .{ .create = .{ .session_id = "settings-test", .timestamp = stamp.timestamp() } }, .{});
    defer {
        session.requestShutdown();
        session.deinit();
    }
    var wake: runtime.WakeEvent = .init;
    var loop = try Loop.init(std.testing.allocator, null);
    defer loop.deinit();
    try loop.bindServices(&services);
    loop.bindSession(&session, services.io, &wake);

    try loop.dispatch(.{ .insert = "/settings thinking:shown" });
    try loop.dispatch(.submit);
    try std.testing.expect(!session.hide_thinking);
    try std.testing.expect(!loop.layout_epoch.hide_thinking);
    try std.testing.expectEqual(false, services.settings_manager.current().global.loaded.value.hide_thinking_block.?);
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
