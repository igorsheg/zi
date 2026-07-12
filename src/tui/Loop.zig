const std = @import("std");
const vaxis = @import("vaxis");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const coding_agent = @import("../coding_agent/root.zig");
const slash_commands = @import("../coding_agent/slash_commands.zig");
const runtime = @import("../runtime/root.zig");
const chrome = @import("chrome.zig");
const clipboard_image = @import("clipboard_image.zig");
const Editor = @import("Editor.zig");
const InputDecoder = @import("InputDecoder.zig");
const InputPumpMod = @import("InputPump.zig");
const InputPump = InputPumpMod.InputPump;
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");
const render_policy = @import("render_policy.zig");
const screen = @import("screen.zig");
const theme = @import("theme.zig");
const trace_mod = @import("trace.zig");
const Transcript = @import("Transcript.zig");
const tui_blocks = @import("blocks.zig");

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
pub const agent_events_per_iteration_max: usize = 8;
pub const watchdog_budget_ns: u64 = 33 * std.time.ns_per_ms;
pub const double_key_window_ns: u64 = 500 * std.time.ns_per_ms;
pub const spinner_interval_ns: u64 = 80 * std.time.ns_per_ms;
const retry_status_tick_ns: u64 = std.time.ns_per_s;
pub const shutdown_cancel_bound_ns: u64 = 5 * std.time.ns_per_s;
const session_listing_deadline_ns: u64 = 5 * std.time.ns_per_s;
const session_opening_deadline_ns: u64 = 30 * std.time.ns_per_s;
const prompt_image_deadline_ns: u64 = 10 * std.time.ns_per_s;
const restore_entries_per_iteration_max: usize = 16;
const restore_work_bytes_per_iteration_target: usize = 256 * 1024;
const exit_hint_text = "press ctrl+c again to exit";
const scratch_capacity = 8192;
const synthetic_flood_rate_bytes_per_second: u64 = 1024 * 1024;
pub const synthetic_flood_duration_ns: u64 = 30 * std.time.ns_per_s;
pub const synthetic_flood_tool_body_bytes: usize = 4 * 1024 * 1024;
const synthetic_flood_tool_emit_ns: u64 = synthetic_flood_duration_ns / 2;
const viewport_hint_buffer_len = 64;
const completion_popup_rows_max: usize = chrome.popup_rows_max;
const completion_candidates_max: usize = 64;
const completion_text_bytes_max: usize = 256;
const picker_rows_max: usize = 128;
const picker_visible_rows_max: usize = 8;
const title_buffer_len: usize = 256;
const composer_label_buffer_len: usize = 256;

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

const prompt_image_count_max: usize = 4;
const prompt_image_encoded_bytes_total_max: usize = 768 * 1024;
const prompt_image_mime_bytes_max: usize = 64;
const clipboard_temp_path_count_max: usize = prompt_image_count_max;

const ClipboardImagePaste = struct {
    path: []u8,
    mime_type: []u8,
    byte_len: usize,

    fn deinit(self: *ClipboardImagePaste, allocator: std.mem.Allocator) void {
        if (self.path.len > 0) allocator.free(self.path);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

const PromptImageAttachments = struct {
    items: [prompt_image_count_max]ai.ImageContent = undefined,
    len: usize = 0,

    fn images(self: *const PromptImageAttachments) []const ai.ImageContent {
        return self.items[0..self.len];
    }

    fn appendOwned(self: *PromptImageAttachments, image: ai.ImageContent) !void {
        if (self.len == self.items.len) return error.TooManyImages;
        self.items[self.len] = image;
        self.len += 1;
    }

    fn deinit(self: *PromptImageAttachments, allocator: std.mem.Allocator) void {
        for (self.items[0..self.len]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        self.len = 0;
    }
};

const PromptImages = struct {
    items: []ai.ImageContent = &.{},

    fn copy(allocator: std.mem.Allocator, source: []const ai.ImageContent) !PromptImages {
        if (source.len == 0) return .{};
        if (source.len > prompt_image_count_max) return error.TooManyImages;
        const items = try allocator.alloc(ai.ImageContent, source.len);
        errdefer allocator.free(items);
        var copied: usize = 0;
        errdefer freeItems(allocator, items[0..copied]);
        for (source, 0..) |image, index| {
            if (image.data.len > prompt_image_encoded_bytes_total_max) return error.ImageTooLarge;
            if (image.mime_type.len > prompt_image_mime_bytes_max) return error.ImageMimeTooLong;
            const data = try allocator.dupe(u8, image.data);
            errdefer allocator.free(data);
            const mime_type = try allocator.dupe(u8, image.mime_type);
            items[index] = .{ .data = data, .mime_type = mime_type };
            copied += 1;
        }
        return .{ .items = items };
    }

    fn takeAttachments(
        allocator: std.mem.Allocator,
        attachments: *PromptImageAttachments,
    ) !PromptImages {
        if (attachments.len == 0) return .{};
        const items = try allocator.alloc(ai.ImageContent, attachments.len);
        @memcpy(items, attachments.items[0..attachments.len]);
        attachments.len = 0;
        return .{ .items = items };
    }

    fn deinit(self: *PromptImages, allocator: std.mem.Allocator) void {
        freeItems(allocator, self.items);
        self.* = .{};
    }

    fn freeItems(allocator: std.mem.Allocator, items: []const ai.ImageContent) void {
        for (items) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        if (items.len > 0) allocator.free(items);
    }
};

const SavedPrompt = struct {
    text: SubmittedPrompt = .{},
    images: PromptImages = .{},

    fn set(self: *SavedPrompt, allocator: std.mem.Allocator, text: []const u8, images: []const ai.ImageContent) !void {
        self.deinit(allocator);
        self.text.set(text);
        self.images = try PromptImages.copy(allocator, images);
    }

    fn deinit(self: *SavedPrompt, allocator: std.mem.Allocator) void {
        self.images.deinit(allocator);
        self.text.len = 0;
    }
};

const RunState = struct {
    state: State = .idle,
    saved_prompt: ?SavedPrompt = null,
    overflow_count_before: usize = 0,
    overflow_retry_used: bool = false,
    retry: ?RetryDisplay = null,
    progress_pending: bool = false,
    awaiting_render: bool = false,
    next_batch_deadline_ns: ?u64 = null,

    const RetryDisplay = struct { deadline_ns: u64, attempt: u8, max: u8 };
    const State = union(enum) {
        idle,
        running: coding_agent.AgentSession.RunHandle,
        retry_wait: coding_agent.AgentSession.SettleVerdict.Retry,
        compacting: struct { handle: coding_agent.AgentSession.RunHandle, will_retry: bool },
    };
};

const CompletionMode = enum { slash, file };

const CompletionCandidate = struct {
    label: [completion_text_bytes_max]u8 = undefined,
    label_len: u16 = 0,
    insert: [coding_agent.file_completion.completion_edit_bytes_max]u8 = undefined,
    insert_len: u16 = 0,
    detail: [completion_text_bytes_max]u8 = undefined,
    detail_len: u16 = 0,
    replace_start: u16 = 0,
    replace_end: u16 = 0,
    cursor_offset: u16 = 0,
    selectable: bool = true,
    continue_completion: bool = false,

    fn set(self: *CompletionCandidate, label: []const u8, insert: []const u8, detail: []const u8, selectable: bool) void {
        self.label_len = copyBounded(self.label[0..], label);
        self.insert_len = copyBounded(self.insert[0..], insert);
        self.detail_len = copyBounded(self.detail[0..], detail);
        self.cursor_offset = self.insert_len;
        self.selectable = selectable;
        self.continue_completion = false;
    }

    fn setFile(
        self: *CompletionCandidate,
        label: []const u8,
        detail: []const u8,
        edit: coding_agent.file_completion.Edit,
    ) void {
        self.label_len = copyBounded(self.label[0..], label);
        self.insert_len = copyBounded(self.insert[0..], edit.replacementSlice());
        self.detail_len = copyBounded(self.detail[0..], detail);
        self.replace_start = @intCast(edit.replace_start);
        self.replace_end = @intCast(edit.replace_end);
        self.cursor_offset = @min(edit.cursor_offset, self.insert_len);
        self.selectable = true;
        self.continue_completion = edit.continue_completion;
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

    fn appendFile(
        self: *CompletionPopup,
        label: []const u8,
        detail: []const u8,
        edit: coding_agent.file_completion.Edit,
    ) void {
        if (self.candidate_len == self.candidates.len) return;
        self.candidates[self.candidate_len].setFile(label, detail, edit);
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

const picker_stack_depth_max: usize = 4;

const PickerKind = enum { model, session, settings_root, settings_thinking_effort, settings_thinking_visibility };

const PickerAction = union(enum) {
    none,
    apply_model,
    resume_session,
    push: PickerKind,
    thinking_level: agent_mod.ThinkingLevel,
    hide_thinking: bool,
};

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
    action: PickerAction = .none,

    fn set(self: *PickerRow, id: []const u8, label: []const u8, detail: []const u8, meta: []const u8, model: ?ai.Model, authed: bool, action: PickerAction) void {
        self.id_len = copyBounded(self.id[0..], id);
        self.label_len = copyBounded(self.label[0..], label);
        self.detail_len = copyBounded(self.detail[0..], detail);
        self.meta_len = copyBounded(self.meta[0..], meta);
        self.model = model;
        self.authed = authed;
        self.action = action;
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

const PickerFrame = struct {
    kind: PickerKind = .model,
    selected_row: ?usize = null,
};

const Picker = struct {
    active: bool = false,
    kind: PickerKind = .model,
    rows: [picker_rows_max]PickerRow = undefined,
    row_len: usize = 0,
    selected_row: ?usize = null,
    stack: [picker_stack_depth_max]PickerFrame = undefined,
    depth: usize = 0,

    fn reset(self: *Picker, next_kind: PickerKind) void {
        self.active = true;
        self.kind = next_kind;
        self.row_len = 0;
        self.selected_row = null;
        self.depth = 1;
    }

    fn push(self: *Picker, next_kind: PickerKind) bool {
        if (!self.active or self.depth == self.stack.len) return false;
        self.stack[self.depth - 1] = .{ .kind = self.kind, .selected_row = self.selected_row };
        self.kind = next_kind;
        self.row_len = 0;
        self.selected_row = null;
        self.depth += 1;
        return true;
    }

    fn pop(self: *Picker) bool {
        if (!self.active or self.depth <= 1) return false;
        self.depth -= 1;
        const frame = self.stack[self.depth - 1];
        self.kind = frame.kind;
        self.row_len = 0;
        self.selected_row = frame.selected_row;
        return true;
    }

    fn clear(self: *Picker) void {
        self.active = false;
        self.row_len = 0;
        self.selected_row = null;
        self.depth = 0;
    }

    fn top(self: *Picker) *Picker {
        std.debug.assert(self.active and self.depth > 0);
        return self;
    }

    fn topConst(self: *const Picker) *const Picker {
        std.debug.assert(self.active and self.depth > 0);
        return self;
    }

    fn currentKind(self: *const Picker) PickerKind {
        return self.kind;
    }

    fn appendRow(self: *Picker, id: []const u8, label: []const u8, detail: []const u8, meta: []const u8, model: ?ai.Model, authed: bool, action: PickerAction) void {
        if (self.row_len == self.rows.len) return;
        self.rows[self.row_len].set(id, label, detail, meta, model, authed, action);
        if (self.selected_row == null) self.selected_row = self.row_len;
        self.row_len += 1;
    }
};

const Composer = struct {
    editor: Editor = .{},
    preferred_column_cells: ?usize = null,
    completion: CompletionPopup = .{},
    picker: Picker = .{},
    dismissed_picker_kind: ?PickerKind = null,
    dismissed_picker_text: [Editor.capacity]u8 = undefined,
    dismissed_picker_text_len: usize = 0,
    completion_lines: [completion_popup_rows_max]screen.Line = undefined,
    picker_lines: [picker_visible_rows_max]screen.Line = undefined,
    file_index: ?coding_agent.file_completion.Index = null,
    file_index_task: ?runtime.Task(anyerror!coding_agent.file_completion.Index) = null,
    file_index_stale: bool = false,
    file_index_failed: bool = false,
    scoped_file_query_task: ?runtime.Task(anyerror!*coding_agent.file_completion.Result) = null,
    scoped_file_query: [coding_agent.file_completion.file_completion_query_bytes_max]u8 = undefined,
    scoped_file_query_len: u16 = 0,
};

const OperationNotice = struct {
    buffer: [64]u8 = undefined,
    len: u8 = 0,

    fn init(value: []const u8) OperationNotice {
        var out: OperationNotice = .{};
        out.len = @intCast(copyBounded(&out.buffer, value));
        return out;
    }

    fn text(self: *const OperationNotice) []const u8 {
        return self.buffer[0..self.len];
    }
};

const ForegroundOperation = union(enum) {
    idle,
    listing: Listing,
    opening: Opening,
    discarding_opened: *coding_agent.AgentSession,
    draining_previous: DrainingPrevious,
    restoring: Restoring,
    preparing_images: PreparingImages,
    reading_clipboard: ReadingClipboard,

    const Listing = struct {
        task: runtime.Task(anyerror!coding_agent.session_listing.SessionSummaryList),
        cancel: *runtime.CancelSource,
        deadline_ns: u64,
        apply_result: bool = true,
    };

    const Opening = struct {
        task: runtime.Task(anyerror!*coding_agent.AgentSession),
        cancel: *runtime.CancelSource,
        deadline_ns: u64,
        apply_result: bool = true,
        success_notice: OperationNotice,
    };

    const DrainingPrevious = struct {
        next_session: *coding_agent.AgentSession,
        deadline_ns: u64,
        success_notice: OperationNotice,
    };

    const Restoring = struct {
        next_entry_index: usize = 0,
        success_notice: OperationNotice,
        awaiting_render: bool = false,
        next_step_deadline_ns: ?u64 = null,
    };

    const ReadingClipboard = struct {
        task: runtime.Task(anyerror!ClipboardImagePaste),
        deadline_ns: u64,
        apply_result: bool = true,
        timed_out: bool = false,
    };

    const PreparingImages = struct {
        task: runtime.Task(anyerror!PromptImageAttachments),
        cancel: *runtime.CancelSource,
        deadline_ns: u64,
        apply_result: bool = true,
        timed_out: bool = false,
        prompt: SubmittedPrompt,
        pinned_paths: [prompt_image_count_max]?[]u8 = @splat(null),
        pinned_path_count: usize = 0,
    };
};

pub const Loop = struct {
    gpa: std.mem.Allocator,
    decoder: InputDecoder = .{},
    observed_dropped_input_bytes: usize = 0,
    pending_input_read_ns: [InputPumpMod.stamp_capacity]u64 = undefined,
    pending_input_read_len: usize = 0,
    lone_escape_deadline_ns: ?u64 = null,
    composer: Composer = .{},
    transcript: Transcript = undefined,
    trace: trace_mod.Stats = .{},
    submitted_prompt: ?SubmittedPrompt = null,
    exit_requested: bool = false,
    dirty: bool = true,
    last_frame_start_ns: u64 = 0,
    last_animated_frame_start_ns: ?u64 = null,
    ctrl_c_deadline_ns: ?u64 = null,
    exit_hint_visible: bool = false,
    scratch: Scratch = .{},
    synthetic_flood: SyntheticFlood = .{},
    frame_input_bytes: usize = 0,
    frame_events_applied: usize = 0,
    layout_state: theme.LayoutState = .{ .width = 0, .height = 0 },
    run_state: RunState = .{},
    session: ?*coding_agent.AgentSession = null,
    persist_new_sessions: bool = true,
    io: std.Io = undefined,
    wake: ?*runtime.WakeEvent = null,
    viewport: Viewport = .follow,
    pending_scroll_lines: i32 = 0,
    last_transcript_rows: usize = 0,
    transcript_line_buffer: [screen.row_capacity]screen.Line = undefined,
    viewport_hint_buffer: [viewport_hint_buffer_len]u8 = undefined,
    viewport_hint: []const u8 = "",
    trace_io_ready: bool = false,
    queue_buffers: [4][256]u8 = undefined,
    queue_lines: [4][]const u8 = undefined,
    status_buffer: [256]u8 = undefined,
    composer_left_buffer: [composer_label_buffer_len]u8 = undefined,
    composer_right_buffer: [composer_label_buffer_len]u8 = undefined,
    terminal_title_buffer: [title_buffer_len]u8 = undefined,
    pending_title_update: bool = false,
    services: ?*coding_agent.runtime_services.RuntimeServices = null,
    foreground_operation: ForegroundOperation = .idle,
    clipboard_image_serial: u64 = 0,
    clipboard_temp_paths: [clipboard_temp_path_count_max]?[]u8 = @splat(null),
    clipboard_temp_path_count: usize = 0,
    token_cache_entry_count: usize = 0,
    token_input_total: u64 = 0,
    token_output_total: u64 = 0,
    compaction_count: usize = 0,
    shutdown_requested: bool = false,

    pub const InitOptions = struct {
        initial_prompt: ?[]const u8 = null,
        persist_new_sessions: bool = true,
    };

    pub const FrontendInit = struct {
        session: *coding_agent.AgentSession,
        services: *coding_agent.runtime_services.RuntimeServices,
        wake: *runtime.WakeEvent,
        initial_prompt: ?[]const u8,
        persist_new_sessions: bool,
        resume_picker: bool,
    };

    fn runBusy(self: *const Loop) bool {
        return self.run_state.state != .idle;
    }

    fn runCancellationOutstanding(self: *const Loop) bool {
        return switch (self.run_state.state) {
            .running => |*handle| handle.cancellationOutstanding(),
            .compacting => |*state| state.handle.cancellationOutstanding(),
            .idle, .retry_wait => false,
        };
    }

    fn deinitRunState(self: *Loop, allocator: std.mem.Allocator) void {
        self.clearRunSavedPrompt(allocator);
        self.run_state = .{};
    }

    fn clearRunSavedPrompt(self: *Loop, allocator: std.mem.Allocator) void {
        if (self.run_state.saved_prompt) |*saved| saved.deinit(allocator);
        self.run_state.saved_prompt = null;
    }

    fn startPromptRun(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        text: []const u8,
        images: []const ai.ImageContent,
    ) !void {
        if (text.len > Editor.capacity) return error.EditorFull;
        switch (self.run_state.state) {
            .idle => {},
            .running => return self.queuePromptRun(session, text, images, .steer),
            .retry_wait => {
                try self.notice(.warn, "busy: waiting to retry — esc to cancel");
                return;
            },
            .compacting => {
                try self.notice(.warn, "busy: compacting — esc to cancel");
                return;
            },
        }
        self.clearRunSavedPrompt(self.gpa);
        var saved: SavedPrompt = .{};
        errdefer saved.deinit(self.gpa);
        try saved.set(self.gpa, text, images);
        self.run_state.saved_prompt = saved;
        self.run_state.overflow_count_before = session.contextOverflowCount();
        self.run_state.overflow_retry_used = false;
        var handle = try session.startPromptHandle(text, images);
        handle.setWake(io, wake);
        self.run_state.state = .{ .running = handle };
        self.dirty = true;
    }

    fn startPreparedPromptRun(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        text: []const u8,
        attachments: *PromptImageAttachments,
    ) !void {
        std.debug.assert(self.run_state.state == .idle);
        self.clearRunSavedPrompt(self.gpa);
        var saved: SavedPrompt = .{};
        saved.text.set(text);
        saved.images = try PromptImages.takeAttachments(self.gpa, attachments);
        errdefer saved.deinit(self.gpa);
        var copied_bytes: usize = 0;
        for (saved.images.items) |image| copied_bytes +|= image.data.len;
        self.run_state.saved_prompt = saved;
        saved = .{};
        errdefer self.clearRunSavedPrompt(self.gpa);
        self.run_state.overflow_count_before = session.contextOverflowCount();
        self.run_state.overflow_retry_used = false;
        var handle = try session.startPromptHandle(text, self.run_state.saved_prompt.?.images.items);
        self.trace.recordPromptImageCompletionCopy(copied_bytes);
        handle.setWake(io, wake);
        self.run_state.state = .{ .running = handle };
        self.dirty = true;
    }

    fn queuePromptRun(
        self: *Loop,
        session: *coding_agent.AgentSession,
        text: []const u8,
        images: []const ai.ImageContent,
        kind: coding_agent.AgentSession.QueuePromptKind,
    ) !void {
        session.queuePrompt(text, images, kind) catch |err| switch (err) {
            error.QueueFull => try self.noticeFmt(.warn, "queue is full ({d} queued)", .{session.queuedEchoes().len}),
            error.SessionNotRunning => std.debug.assert(false),
            else => return err,
        };
        self.dirty = true;
    }

    fn startManualCompactionRun(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        custom_instructions: ?[]const u8,
    ) !void {
        if (self.run_state.state != .idle) {
            try self.notice(.warn, "busy: compacting — esc to cancel");
            return;
        }
        const maybe = try session.startCompactionHandle(.manual, false, custom_instructions);
        var handle = maybe orelse {
            try self.notice(.info, "nothing to compact");
            return;
        };
        handle.setWake(io, wake);
        self.run_state.state = .{ .compacting = .{ .handle = handle, .will_retry = false } };
        self.dirty = true;
    }

    fn pumpRun(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
    ) !void {
        if (self.run_state.progress_pending) {
            if (self.run_state.awaiting_render or now_ns < self.run_state.next_batch_deadline_ns.?) {
                self.trace.recordGatedDriverPollSkip();
                return;
            }
            self.run_state.progress_pending = false;
            self.run_state.next_batch_deadline_ns = null;
        }
        switch (self.run_state.state) {
            .idle => {},
            .running => |*handle| try self.pumpPromptHandle(session, io, wake, now_ns, handle),
            .retry_wait => |retry| {
                if (self.run_state.retry) |display| {
                    if (now_ns < display.deadline_ns) return;
                }
                try self.startRetry(session, io, wake, retry);
            },
            .compacting => |*state| try self.pumpCompactionHandle(session, io, wake, now_ns, &state.handle, state.will_retry),
        }
    }

    fn markRunRendered(self: *Loop, frame_start_ns: u64) void {
        if (!self.run_state.awaiting_render) return;
        std.debug.assert(self.run_state.progress_pending);
        self.run_state.awaiting_render = false;
        self.run_state.next_batch_deadline_ns = frame_start_ns +| frame_floor_ns;
    }

    fn exhaustRunEventBudget(self: *Loop) void {
        self.run_state.progress_pending = true;
        self.run_state.awaiting_render = true;
        self.run_state.next_batch_deadline_ns = null;
        self.trace.recordAgentEventBudgetExhaustion();
    }

    fn clearRunProgressGate(self: *Loop) void {
        self.run_state.progress_pending = false;
        self.run_state.awaiting_render = false;
        self.run_state.next_batch_deadline_ns = null;
    }

    fn cancelRun(self: *Loop, session: *coding_agent.AgentSession) void {
        switch (self.run_state.state) {
            .idle => {},
            .running => |*handle| {
                _ = handle.cancelRequest(session);
                if (self.composer.editor.text().len == 0) self.restoreQueuedText(session) catch {};
                // The canceled run emits the terminal assistant "aborted" message.
            },
            .retry_wait => {
                session.cancelRetryWait() catch {};
                session.emitAgentSettled() catch {};
                self.run_state.state = .idle;
                self.run_state.retry = null;
                self.clearRunSavedPrompt(self.gpa);
                self.notice(.info, "aborted") catch {};
            },
            .compacting => |*state| {
                _ = state.handle.cancelRequest(session);
            },
        }
        self.dirty = true;
    }

    fn requestRunShutdown(self: *Loop, session: *coding_agent.AgentSession) void {
        self.cancelRunNoNotice(session);
    }

    fn runShutdownComplete(self: *const Loop) bool {
        return self.run_state.state == .idle;
    }

    fn forceCancelAndDrainRun(self: *Loop, session: *coding_agent.AgentSession, io: std.Io, wake: *runtime.WakeEvent) void {
        const start = nowNs(io);
        self.cancelRunNoNotice(session);
        while (self.run_state.state != .idle and nowNs(io) -| start < shutdown_cancel_bound_ns) {
            self.clearRunProgressGate();
            self.pumpRun(session, io, wake, nowNs(io)) catch break;
            if (self.run_state.state == .idle) break;
            wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
            wake.reset();
        }
    }

    fn cancelRunNoNotice(self: *Loop, session: *coding_agent.AgentSession) void {
        switch (self.run_state.state) {
            .idle => {},
            .running => |*handle| _ = handle.cancelRequest(session),
            .retry_wait => {
                session.cancelRetryWait() catch {};
                session.emitAgentSettled() catch {};
                self.run_state.state = .idle;
                self.run_state.retry = null;
            },
            .compacting => |*state| _ = state.handle.cancelRequest(session),
        }
    }

    fn pumpPromptHandle(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
        handle: *coding_agent.AgentSession.RunHandle,
    ) !void {
        var applied: usize = 0;
        defer self.trace.recordAgentEventsApplied(applied);
        while (applied < agent_events_per_iteration_max) {
            switch (try handle.poll(session)) {
                .live => {
                    applied += 1;
                    self.frame_events_applied += 1;
                    self.dirty = true;
                },
                .empty => return,
                .settled => break,
            }
        } else {
            self.exhaustRunEventBudget();
            return;
        }
        self.clearRunProgressGate();
        const verdict = try handle.settle(session, .{
            .overflow_count_before = self.run_state.overflow_count_before,
            .overflow_retry_used = self.run_state.overflow_retry_used,
        });
        handle.deinitAfterSettled(session);
        self.run_state.state = .idle;
        try self.requestFileIndexRebuild();
        try self.afterPromptVerdict(session, io, wake, now_ns, verdict);
    }

    fn pumpCompactionHandle(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
        handle: *coding_agent.AgentSession.RunHandle,
        will_retry: bool,
    ) !void {
        var applied: usize = 0;
        defer self.trace.recordAgentEventsApplied(applied);
        while (applied < agent_events_per_iteration_max) {
            switch (try handle.poll(session)) {
                .live => {
                    applied += 1;
                    self.frame_events_applied += 1;
                    self.dirty = true;
                },
                .empty => return,
                .settled => break,
            }
        } else {
            self.exhaustRunEventBudget();
            return;
        }
        self.clearRunProgressGate();
        const compaction_run = handle.run.compaction;
        const compaction_reason = compaction_run.reason;
        const had_summary = compaction_run.outcome == .summary;
        const verdict = try handle.settle(session, .{ .overflow_count_before = self.run_state.overflow_count_before, .overflow_retry_used = self.run_state.overflow_retry_used });
        const failure_name = compactionFailureName(compaction_run);
        if (had_summary) try self.transcript.appendCompaction(compaction_run.outcome.summary, compaction_run.input.tokens_before);
        handle.deinitAfterSettled(session);
        self.run_state.state = .idle;
        if (!will_retry) {
            switch (verdict) {
                .completed => if (had_summary) try self.notice(.info, "context compacted"),
                .failed => if (failure_name) |name| {
                    if (!isCancelErrorName(name)) try self.failureNotice(coding_agent.failure_display.fromCompactionError(name));
                },
                .retry, .compact => {},
            }
            self.clearRunSavedPrompt(self.gpa);
            if (compaction_reason == .threshold) try session.emitAgentSettled();
            self.dirty = true;
            return;
        }
        try self.afterPromptVerdict(session, io, wake, now_ns, verdict);
    }

    fn afterPromptVerdict(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        now_ns: u64,
        verdict: coding_agent.AgentSession.SettleVerdict,
    ) !void {
        switch (verdict) {
            .completed => {
                self.clearRunSavedPrompt(self.gpa);
                if (session.shouldRunThresholdCompaction()) {
                    var maybe = try session.startCompactionHandle(.threshold, false, null);
                    if (maybe) |*handle| {
                        handle.setWake(io, wake);
                        self.run_state.state = .{ .compacting = .{ .handle = handle.*, .will_retry = false } };
                    } else try session.emitAgentSettled();
                } else try session.emitAgentSettled();
            },
            .failed => {
                self.clearRunSavedPrompt(self.gpa);
                if (session.latestFailureView()) |view| try self.failureNotice(view);
                try session.emitAgentSettled();
            },
            .retry => |retry| try self.armRetry(session, now_ns, retry),
            .compact => |compaction| {
                var handle = coding_agent.AgentSession.RunHandle.compaction(compaction);
                handle.setWake(io, wake);
                self.run_state.state = .{ .compacting = .{ .handle = handle, .will_retry = compaction.will_retry } };
            },
        }
        self.dirty = true;
    }

    fn armRetry(self: *Loop, session: *coding_agent.AgentSession, now_ns: u64, retry: coding_agent.AgentSession.SettleVerdict.Retry) !void {
        const delay_ns = retry.delay_ms *| std.time.ns_per_ms;
        self.run_state.retry = .{
            .deadline_ns = now_ns +| delay_ns,
            .attempt = session.retryAttempt(),
            .max = session.retryMaxAttempts(),
        };
        self.run_state.state = .{ .retry_wait = retry };
    }

    fn startRetry(
        self: *Loop,
        session: *coding_agent.AgentSession,
        io: std.Io,
        wake: *runtime.WakeEvent,
        retry: coding_agent.AgentSession.SettleVerdict.Retry,
    ) !void {
        if (retry.overflow) self.run_state.overflow_retry_used = true;
        var handle = try session.startContinueHandle();
        handle.setWake(io, wake);
        self.run_state.retry = null;
        self.run_state.state = .{ .running = handle };
        self.dirty = true;
    }

    pub fn init(self: *Loop, gpa: std.mem.Allocator, options: FrontendInit) !void {
        self.* = try initTestWithOptions(gpa, .{
            .initial_prompt = options.initial_prompt,
            .persist_new_sessions = options.persist_new_sessions,
        });
        errdefer self.deinit();
        self.session = options.session;
        self.services = options.services;
        self.io = options.services.io;
        self.wake = options.wake;
        self.trace_io_ready = true;
        if (self.composer.file_index == null and self.composer.file_index_task == null and !self.composer.file_index_failed) {
            try self.requestFileIndexRebuild();
        }
        _ = try options.session.agent.subscribe(.{
            .context = &self.transcript,
            .call_fn = Transcript.applyListener,
        });
        try self.restoreSessionFold();
        if (options.initial_prompt != null) try self.dispatch(.submit);
        if (options.resume_picker) {
            try self.dispatch(.{ .insert = "/resume" });
            try self.dispatch(.submit);
        }
    }

    pub fn initTest(gpa: std.mem.Allocator, initial_prompt: ?[]const u8) !Loop {
        return initTestWithOptions(gpa, .{ .initial_prompt = initial_prompt });
    }

    pub fn initTestWithOptions(gpa: std.mem.Allocator, options: InitOptions) !Loop {
        var self: Loop = .{
            .gpa = gpa,
            .persist_new_sessions = options.persist_new_sessions,
            .transcript = Transcript.initWithToolResolver(gpa, .{ .call_fn = resolveCodingAgentToolUi, .result_fn = resolveCodingAgentToolResultUi }),
        };
        if (options.initial_prompt) |prompt| try self.composer.editor.insert(prompt);
        return self;
    }

    pub fn deinit(self: *Loop) void {
        self.drainForegroundOperation();
        self.clearClipboardTempFiles();
        self.deinitRunState(self.gpa);
        if (self.composer.file_index_task) |*task| {
            if (!task.hasResult()) task.cancel();
            var result = task.getResult() catch null;
            if (result) |*index| index.deinit(self.gpa);
        }
        self.cancelScopedFileQuery();
        if (self.composer.file_index) |*index| index.deinit(self.gpa);
        self.transcript.deinit();
        self.* = undefined;
    }
    pub fn startNonCooperativeShutdownTaskForTest(self: *Loop) !void {
        const services = self.services orelse return error.NoRuntimeServices;
        std.debug.assert(self.foreground_operation == .idle);
        self.foreground_operation = .{ .reading_clipboard = .{
            .task = try services.task_runtime.spawnBlocking(nonCooperativeShutdownWorker, .{self.io}),
            .deadline_ns = nowNs(self.io) +| prompt_image_deadline_ns,
        } };
    }

    pub const StepInputs = struct {
        now_ns: u64,
        width: u16,
        height: u16,
    };

    pub const StepResult = struct {
        rendered: bool,
        exit_requested: bool,
    };

    pub const RunStatus = enum { exit_requested, exhausted };

    pub const RunResult = struct {
        status: RunStatus,
        iterations: usize,
        rendered_count: usize,
    };

    pub fn run(self: *Loop, terminal: *Terminal, pump: *InputPump, wake: *runtime.WakeEvent) !RunResult {
        var iterations: usize = 0;
        var rendered_count: usize = 0;
        while (true) {
            wake.waitTimeout(self.io, self.nextWaitTimeout(nowNs(self.io))) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return .{
                    .status = .exit_requested,
                    .iterations = iterations,
                    .rendered_count = rendered_count,
                },
            };
            wake.reset();

            const iteration_start_ns = nowNs(self.io);
            const winsize = try terminal.winsize();
            const result = try self.step(terminal, pump, .{
                .now_ns = iteration_start_ns,
                .width = winsize.cols,
                .height = winsize.rows,
            });
            self.trace.recordIteration(nowNs(self.io) -| iteration_start_ns);
            iterations += 1;
            if (result.rendered) rendered_count += 1;
            if (result.exit_requested) return .{
                .status = .exit_requested,
                .iterations = iterations,
                .rendered_count = rendered_count,
            };
        }
    }

    pub fn runBounded(
        self: *Loop,
        terminal: *Terminal,
        pump: *InputPump,
        inputs: StepInputs,
        max_iterations: usize,
    ) !RunResult {
        var rendered_count: usize = 0;
        for (0..max_iterations) |index| {
            const result = try self.step(terminal, pump, inputs);
            if (result.rendered) rendered_count += 1;
            if (result.exit_requested) return .{
                .status = .exit_requested,
                .iterations = index + 1,
                .rendered_count = rendered_count,
            };
        }
        return .{
            .status = .exhausted,
            .iterations = max_iterations,
            .rendered_count = rendered_count,
        };
    }

    // This is the one owner iteration: input first, then bounded continuation
    // work, terminal facts, and finally compose -> paint -> flush -> commit.
    pub fn step(self: *Loop, terminal: *Terminal, pump: *InputPump, inputs: StepInputs) !StepResult {
        const apply_start_ns = nowNs(terminal.io);
        const input_actions_before = self.trace.input_actions;
        try self.drainInputPump(pump, terminal, inputs.now_ns);
        try self.expireLoneEscapeIfDue(inputs.now_ns);
        try self.pumpAgentRun(inputs.now_ns);
        try self.tick(inputs.now_ns);
        if (self.takePendingTitleUpdate()) try terminal.setTitle(self.terminalTitle());
        const had_input = self.trace.input_actions != input_actions_before;
        const resized = self.noteResize(inputs.width, inputs.height);
        if (resized) try terminal.resizeFromTty();
        const apply_complete_ns = nowNs(terminal.io);
        if (!had_input and !resized and !self.shouldRender(inputs.now_ns)) return .{
            .rendered = false,
            .exit_requested = self.exit_requested,
        };

        const frame = try self.composeFrameAt(inputs.width, inputs.height, inputs.now_ns);
        const layout_complete_ns = nowNs(terminal.io);
        try terminal.paintCells(frame);
        const paint_complete_ns = nowNs(terminal.io);
        try terminal.flush();
        const flush_complete_ns = nowNs(terminal.io);
        self.recordPendingInputLatencies(flush_complete_ns);
        self.markRenderedWithTimings(inputs.now_ns, .{
            .apply_ns = apply_complete_ns -| apply_start_ns,
            .layout_ns = layout_complete_ns -| apply_complete_ns,
            .paint_ns = paint_complete_ns -| layout_complete_ns,
            .flush_ns = flush_complete_ns -| paint_complete_ns,
        });
        return .{ .rendered = true, .exit_requested = self.exit_requested };
    }

    fn nextWaitTimeout(self: *const Loop, now_ns: u64) std.Io.Timeout {
        const deadline_ns = self.nextDeadline();
        const resize_poll_ns = frame_floor_ns * 2;
        const idle_due_ns = now_ns +| resize_poll_ns;
        const due_ns = if (deadline_ns) |deadline| @min(deadline, idle_due_ns) else idle_due_ns;
        return .{ .duration = .{
            .raw = .fromNanoseconds(@intCast(due_ns -| now_ns)),
            .clock = .awake,
        } };
    }

    fn restoreSessionFold(self: *Loop) !void {
        const session = self.session orelse return;
        self.transcript.clear();
        self.composer.editor.history_len = 0;
        self.composer.editor.history_index = null;
        self.token_cache_entry_count = std.math.maxInt(usize);
        self.token_input_total = 0;
        self.token_output_total = 0;
        var entry_index: usize = 0;
        while (entry_index < session.manager.entries.items.len) {
            entry_index = try self.restoreEntriesStep(entry_index);
        }
        self.refreshTokenCache();
        self.repinViewport();
        self.dirty = true;
        self.pending_title_update = true;
    }

    pub fn takePendingTitleUpdate(self: *Loop) bool {
        const pending = self.pending_title_update;
        self.pending_title_update = false;
        return pending;
    }

    pub fn writeTraceReport(self: *const Loop, writer: *std.Io.Writer) !void {
        try self.trace.writeReport(writer);
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

    pub fn seedSyntheticBashSpill(self: *Loop, io: std.Io) !void {
        const body = "line 2001\nline 2002\n\n[Showing lines 3-2002 of 2002 (50KB limit). Full output: /tmp/zi-bash-test.log]";
        const content = [_]ai.ToolResultContent{.{ .text = .{ .text = body } }};

        var truncation: std.json.ObjectMap = .empty;
        defer truncation.deinit(self.gpa);
        try truncation.put(self.gpa, "truncated", .{ .bool = true });
        try truncation.put(self.gpa, "truncatedBy", .{ .string = "lines" });
        try truncation.put(self.gpa, "totalLines", .{ .integer = 2002 });
        try truncation.put(self.gpa, "totalBytes", .{ .integer = 18_000 });
        try truncation.put(self.gpa, "outputLines", .{ .integer = 2000 });
        try truncation.put(self.gpa, "outputBytes", .{ .integer = 10 });
        try truncation.put(self.gpa, "lastLinePartial", .{ .bool = false });
        try truncation.put(self.gpa, "firstLineExceedsLimit", .{ .bool = false });
        try truncation.put(self.gpa, "maxLines", .{ .integer = 2000 });
        try truncation.put(self.gpa, "maxBytes", .{ .integer = 50 * 1024 });

        var details: std.json.ObjectMap = .empty;
        defer details.deinit(self.gpa);
        try details.put(self.gpa, "truncation", .{ .object = truncation });
        try details.put(self.gpa, "fullOutputPath", .{ .string = "/tmp/zi-bash-test.log" });

        try self.transcript.apply(io, .{ .tool_execution_end = .{
            .tool_call_id = "seed-bash-spill",
            .tool_name = "bash",
            .result = .{ .content = &content, .details = .{ .object = details } },
            .is_error = false,
        } });
        self.dirty = true;
    }

    pub fn seedSyntheticWriteArgs(self: *Loop, io: std.Io) !void {
        try self.transcript.apply(io, .{ .message_start = .{ .message = .{ .assistant = syntheticAssistantMessage(&.{}) } } });

        const args_object: std.json.ObjectMap = .empty;
        const call = ai.ToolCall{ .id = "seed-write-args", .name = "write", .arguments = .{ .object = args_object } };
        const content = [_]ai.AssistantContent{.{ .tool_call = call }};
        const partial = syntheticAssistantMessage(&content);
        try self.transcript.apply(io, .{ .message_update = .{ .message = .{ .assistant = partial }, .assistant_message_event = .{ .toolcall_start = .{
            .content_index = 0,
            .partial = partial,
        } } } });
        try self.transcript.apply(io, .{ .message_update = .{ .message = .{ .assistant = partial }, .assistant_message_event = .{ .toolcall_delta = .{
            .content_index = 0,
            .delta = "{\"path\":\"src/synthetic-write.zig\",\"content\":\"streamed arg line 1\\n",
            .partial = partial,
        } } } });
        try self.transcript.apply(io, .{ .message_update = .{ .message = .{ .assistant = partial }, .assistant_message_event = .{ .toolcall_delta = .{
            .content_index = 0,
            .delta = "streamed arg line 2",
            .partial = partial,
        } } } });
        self.dirty = true;
    }

    fn feedInputBytes(self: *Loop, bytes: []const u8) InputDecoder.Error!void {
        try self.decoder.feed(bytes);
    }

    fn drainInputActions(self: *Loop, terminal: ?*Terminal, now_ns: u64) !void {
        while (try self.decoder.nextActionWithTerminal(terminal)) |action| {
            try self.dispatchAt(action, now_ns);
        }
    }

    fn drainInputPump(self: *Loop, pump: *InputPump, terminal: *Terminal, now_ns: u64) !void {
        const dropped = pump.droppedByteCount();
        if (dropped > self.observed_dropped_input_bytes) {
            self.trace.addDroppedInputBytes(dropped - self.observed_dropped_input_bytes);
            self.observed_dropped_input_bytes = dropped;
        }

        var batch: [InputDecoder.drain_capacity]u8 = undefined;
        const len = pump.drainBytes(&batch);
        self.collectConsumedInputStamps(pump);
        if (len > 0) {
            self.frame_input_bytes += len;
            self.feedInputBytes(batch[0..len]) catch |err| switch (err) {
                error.DecoderFull, error.ActionTextTooLong => return self.dropOversizeInput(len),
            };
            self.drainInputActions(terminal, now_ns) catch |err| switch (err) {
                error.DecoderFull, error.ActionTextTooLong => return self.dropOversizeInput(len),
                else => return err,
            };
        }
        self.updateLoneEscapeDeadline(now_ns);
    }

    fn dropOversizeInput(self: *Loop, count: usize) !void {
        self.decoder.reset();
        self.trace.addDroppedInputBytes(count);
        try self.notice(.warn, "input too large");
    }

    fn updateLoneEscapeDeadline(self: *Loop, now_ns: u64) void {
        if (self.decoder.needsEscapeDeadline()) {
            if (self.lone_escape_deadline_ns == null) {
                self.lone_escape_deadline_ns = now_ns +| InputDecoder.lone_escape_timeout_ns;
            }
        } else {
            self.lone_escape_deadline_ns = null;
        }
    }

    fn expireLoneEscapeIfDue(self: *Loop, now_ns: u64) !void {
        if (self.lone_escape_deadline_ns) |deadline| {
            if (now_ns >= deadline) {
                self.lone_escape_deadline_ns = null;
                try self.dispatchAt(self.decoder.expireLoneEscape(), now_ns);
            }
        }
    }

    fn collectConsumedInputStamps(self: *Loop, pump: *InputPump) void {
        var stamps: [InputPumpMod.stamp_capacity]InputPumpMod.BatchStamp = undefined;
        const count = pump.drainConsumedStamps(&stamps);
        for (stamps[0..count]) |stamp| {
            if (self.pending_input_read_len == self.pending_input_read_ns.len) {
                std.mem.copyForwards(
                    u64,
                    self.pending_input_read_ns[0 .. self.pending_input_read_len - 1],
                    self.pending_input_read_ns[1..self.pending_input_read_len],
                );
                self.pending_input_read_len -= 1;
            }
            self.pending_input_read_ns[self.pending_input_read_len] = stamp.read_ns;
            self.pending_input_read_len += 1;
        }
    }

    fn recordPendingInputLatencies(self: *Loop, flush_complete_ns: u64) void {
        for (self.pending_input_read_ns[0..self.pending_input_read_len]) |read_ns| {
            self.trace.recordInputLatency(read_ns, flush_complete_ns);
        }
        self.pending_input_read_len = 0;
    }

    pub fn dispatch(self: *Loop, action: input.Action) !void {
        try self.dispatchAt(action, 0);
    }

    pub fn dispatchAt(self: *Loop, action: input.Action, now_ns: u64) !void {
        self.trace.recordInputAction();
        self.frame_events_applied += 1;
        self.dirty = true;
        const editor_vertical = switch (action) {
            .key_editor => |op| !self.composer.picker.active and !self.composer.completion.active and (op == .move_up or op == .move_down),
            else => false,
        };
        if (!editor_vertical) self.composer.preferred_column_cells = null;
        if (try self.handlePickerAction(action)) return;
        if (try self.handleCompletionAction(action)) return;
        switch (action) {
            .insert => |text| {
                self.clearExitHint();
                try self.insertComposerText(text);
            },
            .key_editor => |op| {
                self.clearExitHint();
                try self.applyComposerEditorOp(op);
            },
            .cancel => self.handleCancel(),
            .quit_eof => {
                if (self.composer.editor.text().len == 0) {
                    self.exit_requested = true;
                } else {
                    self.clearExitHint();
                    _ = self.composer.editor.deleteForward();
                    try self.afterComposerTextMutation();
                }
            },
            .submit => try self.submitPrompt(.submit),
            .steer_submit => try self.submitPrompt(.steer_submit),
            .follow_up_submit => try self.submitPrompt(.follow_up_submit),
            .newline => {
                try self.composer.editor.insertNewline();
                try self.afterComposerTextMutation();
            },
            .dequeue_all => try self.dequeueAll(),
            .paste_image => try self.startClipboardImagePaste(),
            .clear_or_quit => try self.handleClearOrQuit(now_ns),
            .expand_toggle => self.toggleExpanded(),
            .force_redraw => self.dirty = true,
            .scroll => |delta| self.queueViewportScroll(delta),
            .page_up => self.queueViewportPage(-1),
            .page_down => self.queueViewportPage(1),
            .none => {},
        }
    }

    fn insertComposerText(self: *Loop, text: []const u8) !void {
        try self.composer.editor.insert(text);
        try self.afterComposerTextMutation();
    }

    fn applyComposerEditorOp(self: *Loop, op: input.EditorOp) !void {
        self.applyEditorOp(op);
        try self.afterComposerTextMutation();
    }

    fn afterComposerTextMutation(self: *Loop) !void {
        try self.refreshCompletion(.auto);
    }

    pub fn composerText(self: *const Loop) []const u8 {
        return self.composer.editor.text();
    }

    pub fn submittedPrompt(self: *const Loop) ?[]const u8 {
        if (self.submitted_prompt) |*prompt| return prompt.text();
        return null;
    }

    pub fn composeFrame(self: *Loop, width: u16, height: u16) anyerror!screen.Frame {
        return self.composeFrameAt(width, height, 0);
    }

    pub fn composeFrameAt(self: *Loop, width: u16, height: u16, now_ns: u64) anyerror!screen.Frame {
        _ = self.noteResize(width, height);
        self.refreshTokenCache();
        const rebuild_start_ns = traceNowNs();
        const layout_result = try self.transcript.prepareLayout(self.layout_state);
        if (layout_result == .published) {
            self.trace.recordRebuild(traceNowNs() -| rebuild_start_ns);
            self.clampViewportAfterRebuild();
        }

        const queue_lines = self.collectQueueLines();
        const status = self.statusView(now_ns);
        const status_visible = status.text.len > 0;
        self.updateViewportHint();
        const provisional_plan = chrome.planRows(.{
            .editor = &self.composer.editor,
            .picker_open = self.composer.picker.active,
            .popup_row_count = if (self.composer.picker.active or !self.composer.completion.active) 0 else chrome.popup_rows_max,
            .queue_line_count = queue_lines.len,
            .viewport_hint_len = self.viewport_hint.len,
            .status_open = status_visible,
        }, width, height);
        self.applyPendingViewportMotion(provisional_plan.transcript_rows);
        self.updateViewportHint();

        var picker_view = self.pickerView(provisional_plan.picker_rows);
        var popup_view = self.popupView(if (picker_view == null) provisional_plan.popup_rows else 0);
        const popup_rows = if (popup_view) |popup| popup.rows.len else 0;
        const plan = chrome.planRows(.{
            .editor = &self.composer.editor,
            .picker_open = picker_view != null,
            .popup_row_count = popup_rows,
            .queue_line_count = queue_lines.len,
            .viewport_hint_len = self.viewport_hint.len,
            .status_open = status_visible,
        }, width, height);
        picker_view = self.pickerView(plan.picker_rows);
        popup_view = self.popupView(if (picker_view == null) plan.popup_rows else 0);
        const transcript_lines = self.collectTranscriptLines(plan.transcript_rows);
        self.last_transcript_rows = plan.transcript_rows;
        const layout_work = self.transcript.lastLayoutWork();
        self.trace.recordLayoutWork(
            layout_work.items_laid_out,
            layout_work.source_bytes,
            layout_work.index_entries_repaired,
            layout_work.lines_materialized,
        );

        return chrome.compose(.{
            .status = status,
            .composer_top_left = self.composerLeftText(),
            .composer_top_right = self.composerRightText(),
            .scratch_text = self.scratch.text(),
            .transcript_lines = transcript_lines,
            .queue_lines = queue_lines,
            .viewport_hint = self.viewport_hint,
            .editor = &self.composer.editor,
            .popup = popup_view,
            .picker = picker_view,
        }, plan, width, height);
    }

    pub fn shouldRender(self: *const Loop, now_ns: u64) bool {
        if (self.statusAnimationDue(now_ns)) return true;
        return render_policy.shouldRenderWithFloor(
            self.dirty,
            now_ns,
            self.last_frame_start_ns,
            frame_floor_ns,
        );
    }

    fn statusAnimationDue(self: *const Loop, now_ns: u64) bool {
        if (self.transcript.hasPendingRelayout()) {
            return render_policy.shouldRenderWithFloor(
                true,
                now_ns,
                self.last_frame_start_ns,
                frame_floor_ns,
            );
        }
        if (self.statusAnimated()) {
            return render_policy.shouldRenderWithFloor(
                true,
                now_ns,
                self.last_frame_start_ns,
                frame_floor_ns,
            );
        }
        if (self.run_state.state == .retry_wait) return now_ns -| self.last_frame_start_ns >= retry_status_tick_ns;
        return false;
    }

    fn nextDeadline(self: *const Loop) ?u64 {
        var deadline: ?u64 = if (self.dirty)
            render_policy.nextRenderDueNsWithFloor(self.last_frame_start_ns, frame_floor_ns)
        else
            null;
        if (self.lone_escape_deadline_ns) |escape_deadline| {
            deadline = if (deadline) |current| @min(current, escape_deadline) else escape_deadline;
        }
        if (self.ctrl_c_deadline_ns) |ctrl_c_deadline| {
            deadline = if (deadline) |current| @min(current, ctrl_c_deadline) else ctrl_c_deadline;
        }
        switch (self.foreground_operation) {
            .idle, .discarding_opened => {},
            .listing => |listing| if (listing.apply_result) {
                deadline = if (deadline) |current| @min(current, listing.deadline_ns) else listing.deadline_ns;
            },
            .opening => |opening| if (opening.apply_result) {
                deadline = if (deadline) |current| @min(current, opening.deadline_ns) else opening.deadline_ns;
            },
            .draining_previous => |draining| deadline = if (deadline) |current| @min(current, draining.deadline_ns) else draining.deadline_ns,
            .restoring => |restoring| if (restoring.next_step_deadline_ns) |restore_deadline| {
                deadline = if (deadline) |current| @min(current, restore_deadline) else restore_deadline;
            },
            .preparing_images => |preparing| if (preparing.apply_result) {
                deadline = if (deadline) |current| @min(current, preparing.deadline_ns) else preparing.deadline_ns;
            },
            .reading_clipboard => |reading| if (reading.apply_result) {
                deadline = if (deadline) |current| @min(current, reading.deadline_ns) else reading.deadline_ns;
            },
        }
        if (self.run_state.next_batch_deadline_ns) |batch_deadline| {
            deadline = if (deadline) |current| @min(current, batch_deadline) else batch_deadline;
        }
        if (self.run_state.retry) |retry| deadline = if (deadline) |current| @min(current, retry.deadline_ns) else retry.deadline_ns;
        if (self.statusAnimated() or self.transcript.hasPendingRelayout()) {
            const animation_due = render_policy.nextRenderDueNsWithFloor(self.last_frame_start_ns, frame_floor_ns);
            deadline = if (deadline) |current| @min(current, animation_due) else animation_due;
        } else if (self.run_state.state == .retry_wait) {
            const retry_status_due = self.last_frame_start_ns +| retry_status_tick_ns;
            deadline = if (deadline) |current| @min(current, retry_status_due) else retry_status_due;
        }
        if (self.synthetic_flood.enabled and !self.synthetic_flood.completed) {
            const flood_due = self.last_frame_start_ns +| frame_floor_ns;
            deadline = if (deadline) |current| @min(current, flood_due) else flood_due;
        }
        return deadline;
    }

    pub fn noteResize(self: *Loop, width: u16, height: u16) bool {
        const width_changed = self.layout_state.width != width;
        if (!self.layout_state.resize(width, height)) return false;
        if (width_changed) self.composer.preferred_column_cells = null;
        self.dirty = true;
        return true;
    }

    pub const RenderTimings = struct {
        apply_ns: u64 = 0,
        layout_ns: u64 = 0,
        paint_ns: u64 = 0,
        flush_ns: u64 = 0,

        fn renderNs(self: RenderTimings) u64 {
            return self.layout_ns +| self.paint_ns +| self.flush_ns;
        }
    };

    pub fn markRendered(self: *Loop, frame_start_ns: u64, render_cost_ns: u64) void {
        self.markRenderedWithTimings(frame_start_ns, .{ .paint_ns = render_cost_ns });
    }

    pub fn markRenderedWithTimings(self: *Loop, frame_start_ns: u64, timings: RenderTimings) void {
        self.markRunRendered(frame_start_ns);
        switch (self.foreground_operation) {
            .restoring => |*restoring| if (restoring.awaiting_render) {
                restoring.awaiting_render = false;
                restoring.next_step_deadline_ns = frame_start_ns +| frame_floor_ns;
            },
            else => {},
        }
        if (self.statusAnimated()) {
            if (self.last_animated_frame_start_ns) |previous| {
                self.trace.recordAnimatedFrameGap(frame_start_ns -| previous, frame_floor_ns);
            }
            self.last_animated_frame_start_ns = frame_start_ns;
        } else {
            self.last_animated_frame_start_ns = null;
        }
        self.last_frame_start_ns = frame_start_ns;
        self.trace.recordRender(timings.renderNs());
        self.trace.recordTranscriptEvictions(self.transcript.evicted_seqs);
        self.trace.recordFrame(.{
            .wake_ns = frame_start_ns,
            .input_bytes = self.frame_input_bytes,
            .events_applied = self.frame_events_applied,
            .apply_us = nsToUs(timings.apply_ns),
            .layout_us = nsToUs(timings.layout_ns),
            .paint_us = nsToUs(timings.paint_ns),
            .flush_us = nsToUs(timings.flush_ns),
        });
        self.frame_input_bytes = 0;
        self.frame_events_applied = 0;
        self.dirty = false;
    }
    pub fn tick(self: *Loop, now_ns: u64) !void {
        try self.pollForegroundOperation(now_ns);
        const file_index_changed = try self.pollFileIndexTask();
        const scoped_query_ready = if (self.composer.scoped_file_query_task) |*task| task.hasResult() else false;
        if ((file_index_changed or scoped_query_ready) and self.composer.completion.active and self.composer.completion.mode == .file) {
            try self.refreshCompletion(.force_file);
        } else if (scoped_query_ready) {
            self.discardCompletedScopedFileQuery();
        }
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
        if (self.transcript.markRunningToolsDirty(now_ns)) self.dirty = true;
    }

    fn pumpAgentRun(self: *Loop, now_ns: u64) !void {
        const session = self.session orelse return;
        const wake = self.wake orelse return;
        try self.pumpRun(session, self.io, wake, now_ns);
    }

    fn shutdownAgentRun(self: *Loop) void {
        const session = self.session orelse return;
        const wake = self.wake orelse return;
        self.forceCancelAndDrainRun(session, self.io, wake);
    }

    pub fn requestShutdown(self: *Loop) void {
        if (self.shutdown_requested) return;
        self.shutdown_requested = true;
        if (self.session) |session| {
            self.requestRunShutdown(session);
            session.requestShutdown();
        }
        switch (self.foreground_operation) {
            .idle, .restoring => {},
            .listing => |*listing| {
                listing.apply_result = false;
                listing.cancel.request();
            },
            .opening => |*opening| {
                opening.apply_result = false;
                opening.cancel.request();
            },
            .discarding_opened => |next| next.requestShutdown(),
            .draining_previous => |draining| draining.next_session.requestShutdown(),
            .preparing_images => |*preparing| {
                preparing.apply_result = false;
                preparing.cancel.request();
            },
            .reading_clipboard => |*reading| reading.apply_result = false,
        }
    }

    pub fn pollShutdown(self: *Loop) bool {
        std.debug.assert(self.shutdown_requested);
        const session = self.session orelse return false;
        if (!self.runShutdownComplete()) {
            self.requestRunShutdown(session);
            self.clearRunProgressGate();
            const wake = self.wake orelse return false;
            self.pumpRun(session, self.io, wake, nowNs(self.io)) catch return false;
        }
        self.pollForegroundOperationShutdown();
        self.pollFileIndexShutdown();
        self.pollScopedFileQueryShutdown();
        session.requestShutdown();
        return self.runShutdownComplete() and
            self.foreground_operation == .idle and
            self.composer.file_index_task == null and
            self.composer.scoped_file_query_task == null and
            session.shutdownComplete();
    }

    fn pollForegroundOperationShutdown(self: *Loop) void {
        switch (self.foreground_operation) {
            .idle => {},
            .listing => |*listing| {
                if (!listing.task.hasResult()) return;
                var result = listing.task.getResult() catch null;
                if (result) |*summaries| summaries.deinit(self.gpa);
                const cancel = listing.cancel;
                cancel.deinit();
                self.gpa.destroy(cancel);
                self.foreground_operation = .idle;
            },
            .opening => |*opening| {
                if (!opening.task.hasResult()) return;
                const result = opening.task.getResult() catch null;
                const cancel = opening.cancel;
                cancel.deinit();
                self.gpa.destroy(cancel);
                if (result) |next| {
                    next.requestShutdown();
                    self.foreground_operation = .{ .discarding_opened = next };
                } else {
                    self.foreground_operation = .idle;
                }
            },
            .discarding_opened => |next| {
                next.requestShutdown();
                if (!next.shutdownComplete()) return;
                next.deinit();
                self.gpa.destroy(next);
                self.foreground_operation = .idle;
            },
            .draining_previous => |draining| {
                const current = self.session orelse return;
                current.requestShutdown();
                draining.next_session.requestShutdown();
                if (!current.shutdownComplete() or !draining.next_session.shutdownComplete()) return;
                draining.next_session.deinit();
                self.gpa.destroy(draining.next_session);
                self.foreground_operation = .idle;
            },
            .restoring => self.foreground_operation = .idle,
            .preparing_images => |*preparing| {
                if (!preparing.task.hasResult()) return;
                var result = preparing.task.getResult() catch null;
                if (result) |*images| images.deinit(self.gpa);
                const pinned = preparing.pinned_paths;
                const pinned_count = preparing.pinned_path_count;
                const cancel = preparing.cancel;
                cancel.deinit();
                self.gpa.destroy(cancel);
                self.foreground_operation = .idle;
                self.returnPinnedPromptImagePaths(pinned, pinned_count);
            },
            .reading_clipboard => |*reading| {
                if (!reading.task.hasResult()) return;
                var result = reading.task.getResult() catch null;
                if (result) |*paste| {
                    deleteClipboardTempPath(self.io, paste.path);
                    paste.deinit(self.gpa);
                }
                self.foreground_operation = .idle;
            },
        }
    }

    fn pollFileIndexShutdown(self: *Loop) void {
        if (self.composer.file_index_task) |*task| {
            if (!task.hasResult()) return;
            var result = task.getResult() catch null;
            if (result) |*index| index.deinit(self.gpa);
            self.composer.file_index_task = null;
        }
    }

    fn pollScopedFileQueryShutdown(self: *Loop) void {
        if (self.composer.scoped_file_query_task) |*task| {
            if (!task.hasResult()) return;
            const result = task.getResult() catch null;
            if (result) |value| value.destroy(self.gpa);
            self.composer.scoped_file_query_task = null;
            self.composer.scoped_file_query_len = 0;
        }
    }

    pub fn notice(self: *Loop, level: Transcript.NoticeLevel, text: []const u8) !void {
        try self.transcript.appendNotice(level, text);
        self.dirty = true;
    }

    pub fn noticeFmt(self: *Loop, level: Transcript.NoticeLevel, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.bufPrint(&self.status_buffer, fmt, args);
        try self.notice(level, text);
    }

    pub fn failureNotice(self: *Loop, view: coding_agent.failure_display.View) !void {
        var buffer: [coding_agent.failure_display.notice_bytes_max]u8 = undefined;
        const text = coding_agent.failure_display.formatNotice(&buffer, view);
        try self.notice(failureNoticeLevel(view.tone), text);
    }

    fn collectTranscriptLines(self: *Loop, rows: usize) []const screen.Line {
        const visible_rows = @min(rows, self.transcript_line_buffer.len);
        if (visible_rows == 0 or self.totalTranscriptLines() == 0) return &.{};

        var absolute = self.viewportStart(visible_rows);
        if (visible_rows == 1 and self.viewport == .follow and absolute > 0 and
            self.transcript.isItemMarginAt(absolute))
        {
            absolute -= 1;
        }
        absolute = self.skipLeadingMargin(absolute);
        return self.transcript.collectVisible(absolute, self.transcript_line_buffer[0..visible_rows]);
    }

    fn skipLeadingMargin(self: *const Loop, start: usize) usize {
        var absolute = start;
        const total = self.totalTranscriptLines();
        while (absolute + 1 < total and self.transcript.isItemMarginAt(absolute)) {
            absolute += 1;
        }
        return absolute;
    }

    fn totalTranscriptLines(self: *const Loop) usize {
        return self.transcript.totalLines();
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
        const resolved = self.transcript.resolvePosition(.{
            .item_seq = anchor.item_seq,
            .line_in_item = anchor.line_in_item,
        }) orelse return null;
        return resolved.absolute;
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
                const resolved = self.transcript.resolvePosition(.{
                    .item_seq = anchor.item_seq,
                    .line_in_item = anchor.line_in_item,
                }) orelse {
                    self.anchorOldestLiveLine();
                    return;
                };
                const changed = resolved.position.line_in_item != anchor.line_in_item;
                anchor.line_in_item = resolved.position.line_in_item;
                if (reset_seen or changed) anchor.lines_below_seen = self.linesBelow(resolved.absolute);
            },
        }
    }

    fn anchorOldestLiveLine(self: *Loop) void {
        const oldest = self.transcript.oldestPosition() orelse {
            self.viewport = .follow;
            return;
        };
        self.viewport = .{ .anchored = .{
            .item_seq = oldest.position.item_seq,
            .line_in_item = oldest.position.line_in_item,
            .lines_below_seen = self.linesBelow(oldest.absolute),
        } };
    }

    fn setAnchorAtAbsolute(self: *Loop, absolute: usize) void {
        const resolved = self.transcript.positionAtLine(absolute) orelse {
            self.viewport = .follow;
            return;
        };
        self.viewport = .{ .anchored = .{
            .item_seq = resolved.position.item_seq,
            .line_in_item = resolved.position.line_in_item,
            .lines_below_seen = self.linesBelow(resolved.absolute),
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
        _ = self.layout_state.setExpanded(!self.layout_state.expanded);
        self.dirty = true;
    }

    fn setHideThinking(self: *Loop, hidden: bool) void {
        _ = self.layout_state.setHideThinking(hidden);
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

    fn statusView(self: *Loop, now_ns: u64) chrome.StatusView {
        if (self.exit_requested) return .{ .text = "exiting" };
        if (self.exit_hint_visible) return .{ .text = exit_hint_text };
        switch (self.foreground_operation) {
            .idle => {},
            .listing => |listing| return .{ .text = if (listing.apply_result) "Loading sessions… (esc to cancel)" else "Canceling…" },
            .opening => |opening| return .{ .text = if (opening.apply_result) "Opening session… (esc to cancel)" else "Canceling…" },
            .discarding_opened => return .{ .text = "Canceling…" },
            .draining_previous => return .{ .text = "Switching session…" },
            .restoring => return .{ .text = "Restoring session…" },
            .preparing_images => |preparing| return .{ .text = if (preparing.apply_result) "Preparing images… (esc to cancel)" else "Canceling image preparation…" },
            .reading_clipboard => |reading| return .{ .text = if (reading.apply_result) "Reading clipboard image… (esc to cancel)" else "Canceling…" },
        }
        if (self.runCancellationOutstanding()) return .{ .text = "Canceling…" };
        switch (self.run_state.state) {
            .retry_wait => if (self.run_state.retry) |retry| {
                const remaining_ns = retry.deadline_ns -| now_ns;
                const remaining_s = (remaining_ns + std.time.ns_per_s - 1) / std.time.ns_per_s;
                const text = std.fmt.bufPrint(&self.status_buffer, "Retrying ({d}/{d}) in {d}s… (esc to cancel)", .{ retry.attempt, retry.max, remaining_s }) catch "Retrying";
                return .{ .text = text };
            },
            .compacting => return .{ .text = "Compacting context… (esc to cancel)", .style = screen.shimmer.base, .effect = .shimmer, .now_ns = now_ns },
            else => {},
        }
        if (self.transcript.run_active or self.run_state.state == .running) return .{ .text = "Working…", .style = screen.shimmer.base, .effect = .shimmer, .now_ns = now_ns };
        return .{};
    }

    fn statusAnimated(self: *const Loop) bool {
        return self.transcript.run_active or self.run_state.state == .running or self.run_state.state == .compacting;
    }

    fn composerRightText(self: *Loop) []const u8 {
        const session = self.session orelse return "";
        const usage = session.contextUsage();
        var percent_buffer: [16]u8 = undefined;
        var window_buffer: [16]u8 = undefined;
        const percent_text = contextPercentText(&percent_buffer, usage.percent_tenths);
        const window_text = contextWindowText(&window_buffer, usage.window);
        const thinking_level = session.agent.state.thinking_level;
        if (thinking_level == .off) {
            return std.fmt.bufPrint(
                &self.composer_right_buffer,
                "ctx {s}/{s} • {s}",
                .{ percent_text, window_text, session.agent.state.model.id },
            ) catch "ctx";
        }
        return std.fmt.bufPrint(
            &self.composer_right_buffer,
            "ctx {s}/{s} • {s} ({s})",
            .{ percent_text, window_text, session.agent.state.model.id, @tagName(thinking_level) },
        ) catch "ctx";
    }

    fn contextPercentText(buffer: []u8, percent_tenths: ?u32) []const u8 {
        const tenths = percent_tenths orelse return "--";
        return std.fmt.bufPrint(buffer, "{d}%", .{(tenths + 5) / 10}) catch "--";
    }

    fn contextWindowText(buffer: []u8, window: u64) []const u8 {
        if (window == 0) return "--";
        if (window >= 1_000_000) {
            const tenths = (window + 50_000) / 100_000;
            if (tenths % 10 == 0) return std.fmt.bufPrint(buffer, "{d}m", .{tenths / 10}) catch "--";
            return std.fmt.bufPrint(buffer, "{d}.{d}m", .{ tenths / 10, tenths % 10 }) catch "--";
        }
        if (window >= 1_000) return std.fmt.bufPrint(buffer, "{d}k", .{(window + 500) / 1_000}) catch "--";
        return std.fmt.bufPrint(buffer, "{d}", .{window}) catch "--";
    }

    fn composerLeftText(self: *Loop) []const u8 {
        const cwd = if (self.session) |session| session.manager.header.cwd else ".";
        const home = if (self.services) |services| blk: {
            const environ = services.environ orelse break :blk null;
            break :blk environ.get("HOME") orelse environ.get("USERPROFILE");
        } else null;
        if (home) |home_dir| {
            if (home_dir.len != 0 and std.mem.eql(u8, cwd, home_dir)) return "~";
            if (home_dir.len != 0 and cwd.len > home_dir.len and std.mem.startsWith(u8, cwd, home_dir) and std.fs.path.isSep(cwd[home_dir.len])) {
                return std.fmt.bufPrint(&self.composer_left_buffer, "~{s}", .{cwd[home_dir.len..]}) catch cwd;
            }
        }
        return std.fmt.bufPrint(&self.composer_left_buffer, "{s}", .{cwd}) catch cwd;
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

    fn popupView(self: *Loop, capacity: usize) ?chrome.PopupView {
        if (!self.composer.completion.active or self.composer.completion.candidate_len == 0 or self.composer.picker.active) return null;
        const visible_capacity = @min(capacity, self.composer.completion_lines.len);
        if (visible_capacity == 0) return null;
        const selected = @min(self.composer.completion.selected, self.composer.completion.candidate_len - 1);
        const offset = popupVisibleOffset(self.composer.completion.candidate_len, visible_capacity, selected);
        const count = @min(self.composer.completion.candidate_len - offset, visible_capacity);
        for (self.composer.completion.candidates[offset..][0..count], 0..) |*candidate, visible_index| {
            const absolute_index = offset + visible_index;
            var line: screen.Line = .{};
            line.append(.{ .text = candidate.labelSlice(), .style = if (absolute_index == selected) screen.text.accent else screen.text.normal }) catch {};
            if (candidate.detailSlice().len > 0) {
                line.append(.{ .text = "  ", .style = screen.text.muted }) catch {};
                line.append(.{ .text = candidate.detailSlice(), .style = screen.text.muted }) catch {};
            }
            self.composer.completion_lines[visible_index] = line;
        }
        return .{ .rows = self.composer.completion_lines[0..count], .selected = selected - offset };
    }

    fn popupVisibleOffset(total: usize, capacity: usize, selected: usize) usize {
        if (capacity == 0 or selected < capacity) return 0;
        return @min(selected - capacity + 1, total -| capacity);
    }

    fn pickerView(self: *Loop, capacity: usize) ?chrome.PickerView {
        if (!self.composer.picker.active) return null;
        const visible_capacity = @min(capacity, self.composer.picker_lines.len);
        if (visible_capacity == 0) return null;
        const frame = self.composer.picker.topConst();
        var visible: [picker_rows_max]usize = undefined;
        const rows = self.filteredPickerRows(&visible);
        const offset = self.pickerVisibleOffset(rows, visible_capacity);
        const count = @min(rows.len -| offset, visible_capacity);
        if (count == 0) {
            self.composer.picker_lines[0] = screen.singleSpanLine("  no matches", screen.text.muted);
            return .{ .rows = self.composer.picker_lines[0..1], .selected = null };
        }
        for (rows[offset..][0..count], 0..) |row_index, visible_index| {
            const row = &frame.rows[row_index];
            var line: screen.Line = .{};
            line.append(.{ .text = row.labelSlice(), .style = if (frame.selected_row == row_index) screen.text.accent else screen.text.normal }) catch {};
            if (row.detailSlice().len > 0) {
                line.append(.{ .text = "  ", .style = screen.text.muted }) catch {};
                line.append(.{ .text = row.detailSlice(), .style = screen.text.muted }) catch {};
            }
            if (row.metaSlice().len > 0) {
                line.append(.{ .text = "  ", .style = screen.text.muted }) catch {};
                line.append(.{ .text = row.metaSlice(), .style = screen.text.muted }) catch {};
            }
            self.composer.picker_lines[visible_index] = line;
        }
        return .{ .rows = self.composer.picker_lines[0..count], .selected = self.pickerSelectedVisibleIndex(rows, offset, visible_capacity) };
    }

    fn pickerVisibleOffset(self: *Loop, rows: []const usize, capacity: usize) usize {
        if (capacity == 0) return 0;
        const selected = self.composer.picker.topConst().selected_row orelse return 0;
        var selected_visible: usize = 0;
        for (rows, 0..) |row_index, index| if (row_index == selected) {
            selected_visible = index;
            break;
        };
        if (selected_visible >= capacity) return selected_visible - capacity + 1;
        return 0;
    }

    fn pickerSelectedVisibleIndex(self: *Loop, rows: []const usize, offset: usize, capacity: usize) usize {
        const selected = self.composer.picker.topConst().selected_row orelse return 0;
        for (rows[offset..@min(rows.len, offset + capacity)], 0..) |row_index, index| {
            if (row_index == selected) return index;
        }
        return 0;
    }

    fn filteredPickerRows(self: *const Loop, out: *[picker_rows_max]usize) []const usize {
        const frame = self.composer.picker.topConst();
        var count: usize = 0;
        const filter = self.pickerFilterText(frame.kind);
        for (frame.rows[0..frame.row_len], 0..) |row, index| {
            if (filter.len != 0 and !fuzzyMatch(row.labelSlice(), filter) and !fuzzyMatch(row.detailSlice(), filter) and !fuzzyMatch(row.metaSlice(), filter) and !fuzzyMatch(row.idSlice(), filter)) continue;
            out[count] = index;
            count += 1;
        }
        return out[0..count];
    }

    fn pickerFilterText(self: *const Loop, kind: PickerKind) []const u8 {
        const query = self.slashArgQuery() orelse return "";
        if (!pickerKindAcceptsQuery(kind, query.kind)) return "";
        if (pickerKindIsSettingsChild(kind)) {
            const prefix = "thinking:";
            if (std.mem.startsWith(u8, query.text, prefix)) return query.text[prefix.len..];
        }
        return query.text;
    }

    fn startClipboardImagePaste(self: *Loop) !void {
        if (self.foreground_operation != .idle) {
            try self.notice(.warn, "finish or cancel the current operation first");
            return;
        }
        const services = self.services orelse {
            try self.notice(.warn, "clipboard image paste unavailable");
            return;
        };
        if (self.clipboard_temp_path_count == self.clipboard_temp_paths.len) {
            try self.notice(.warn, "too many pasted images");
            return;
        }
        self.clipboard_image_serial +%= 1;
        if (self.clipboard_image_serial == 0) self.clipboard_image_serial = 1;
        const tmp_dir = tmpDirFromEnv(services.environ);
        // This worker uses std.Io/process_runner; keep it on an executor, not the blocking pool.
        self.foreground_operation = .{ .reading_clipboard = .{
            .task = try services.task_runtime.spawn(readClipboardImageToTempFile, .{
                self.gpa,
                self.io,
                services.task_runtime,
                services.environ,
                tmp_dir,
                self.clipboard_image_serial,
            }),
            .deadline_ns = nowNs(self.io) +| prompt_image_deadline_ns,
        } };
        self.dirty = true;
    }

    fn pollClipboardImageTask(self: *Loop, now_ns: u64) !void {
        switch (self.foreground_operation) {
            .reading_clipboard => |*reading| {
                if (reading.apply_result and now_ns >= reading.deadline_ns) {
                    reading.apply_result = false;
                    reading.timed_out = true;
                    try self.notice(.warn, "clipboard image paste timed out");
                }
                if (!reading.task.hasResult()) return;
                const apply_result = reading.apply_result;
                var result = reading.task.getResult() catch |err| {
                    self.foreground_operation = .idle;
                    if (apply_result) try self.notice(.warn, clipboardImageErrorText(err));
                    return;
                };
                self.foreground_operation = .idle;
                if (!apply_result) {
                    deleteClipboardTempPath(self.io, result.path);
                    result.deinit(self.gpa);
                    self.dirty = true;
                    return;
                }
                errdefer result.deinit(self.gpa);
                errdefer deleteClipboardTempPath(self.io, result.path);
                try self.insertClipboardImageMarker(&result);
                try self.retainClipboardTempPath(result.path);
                result.path = &.{};
                result.deinit(self.gpa);
                self.dirty = true;
            },
            else => {},
        }
    }

    fn insertClipboardImageMarker(self: *Loop, paste: *const ClipboardImagePaste) !void {
        var marker_buffer: [64]u8 = undefined;
        const marker = clipboardImageMarker(&marker_buffer, self.clipboard_image_serial, paste.mime_type, paste.byte_len);
        const expansion = try std.fmt.allocPrint(self.gpa, "@{s}", .{paste.path});
        defer self.gpa.free(expansion);
        try self.composer.editor.insertMarker(marker, expansion);
    }

    fn retainClipboardTempPath(self: *Loop, path: []u8) !void {
        if (self.clipboard_temp_path_count == self.clipboard_temp_paths.len) return error.EditorFull;
        self.clipboard_temp_paths[self.clipboard_temp_path_count] = path;
        self.clipboard_temp_path_count += 1;
    }

    fn clearClipboardTempFiles(self: *Loop) void {
        for (self.clipboard_temp_paths[0..self.clipboard_temp_path_count]) |maybe_path| {
            const path = maybe_path orelse continue;
            deleteClipboardTempPath(self.io, path);
            self.gpa.free(path);
        }
        @memset(&self.clipboard_temp_paths, null);
        self.clipboard_temp_path_count = 0;
    }

    fn isTrackedClipboardTempPath(self: *const Loop, path: []const u8) bool {
        for (self.clipboard_temp_paths[0..self.clipboard_temp_path_count]) |maybe_path| {
            const tracked = maybe_path orelse continue;
            if (std.mem.eql(u8, tracked, path)) return true;
        }
        return false;
    }

    fn requestFileIndexRebuild(self: *Loop) !void {
        const services = self.services orelse return;
        if (self.composer.file_index_task != null) {
            self.composer.file_index_stale = true;
            return;
        }
        self.composer.file_index_stale = false;
        self.composer.file_index_failed = false;
        self.composer.file_index_task = try services.task_runtime.spawnBlocking(
            buildFileIndex,
            .{ self.gpa, services.dir, services.cwd },
        );
    }

    fn pollFileIndexTask(self: *Loop) !bool {
        if (self.composer.file_index_task) |*task| {
            if (!task.hasResult()) return false;
            const rebuild_again = self.composer.file_index_stale;
            const index = task.getResult() catch |err| {
                self.composer.file_index_failed = self.composer.file_index == null;
                self.composer.file_index_task = null;
                self.composer.file_index_stale = false;
                try self.noticeFmt(.warn, "file index unavailable: {s}", .{@errorName(err)});
                return true;
            };
            if (self.composer.file_index) |*old| old.deinit(self.gpa);
            self.composer.file_index = index;
            self.composer.file_index_task = null;
            self.composer.file_index_stale = false;
            if (rebuild_again) try self.requestFileIndexRebuild();
            self.dirty = true;
            return true;
        }
        return false;
    }

    fn scopedFileQueryResult(
        self: *Loop,
        context: coding_agent.file_completion.Context,
    ) !?*coding_agent.file_completion.Result {
        const services = self.services orelse return null;
        const query = context.raw_query;
        if (self.composer.scoped_file_query_task) |*task| {
            if (std.mem.eql(u8, self.composer.scoped_file_query[0..self.composer.scoped_file_query_len], query)) {
                if (!task.hasResult()) return null;
                const result = task.getResult() catch {
                    self.composer.scoped_file_query_task = null;
                    self.composer.scoped_file_query_len = 0;
                    const empty = try self.gpa.create(coding_agent.file_completion.Result);
                    empty.* = .{};
                    return empty;
                };
                self.composer.scoped_file_query_task = null;
                self.composer.scoped_file_query_len = 0;
                return result;
            }
            if (!task.hasResult()) return null;
            self.discardCompletedScopedFileQuery();
        }

        const owned_query = try self.gpa.dupe(u8, query);
        errdefer self.gpa.free(owned_query);
        self.composer.scoped_file_query_len = copyBounded(self.composer.scoped_file_query[0..], query);
        const home = if (services.environ) |env|
            env.get("HOME") orelse env.get("USERPROFILE")
        else
            null;
        self.composer.scoped_file_query_task = try services.task_runtime.spawnBlocking(
            coding_agent.file_completion.queryScoped,
            .{ self.gpa, services.dir, services.cwd, home, owned_query },
        );
        return null;
    }

    fn discardCompletedScopedFileQuery(self: *Loop) void {
        if (self.composer.scoped_file_query_task) |*task| {
            if (!task.hasResult()) return;
            const result = task.getResult() catch null;
            if (result) |value| value.destroy(self.gpa);
        }
        self.composer.scoped_file_query_task = null;
        self.composer.scoped_file_query_len = 0;
    }

    fn cancelScopedFileQuery(self: *Loop) void {
        if (self.composer.scoped_file_query_task) |*task| {
            if (!task.hasResult()) task.cancel();
            const result = task.getResult() catch null;
            if (result) |value| value.destroy(self.gpa);
        }
        self.composer.scoped_file_query_task = null;
        self.composer.scoped_file_query_len = 0;
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
            try self.applySyntheticEvent(.{ .message_update = .{ .message = .{ .assistant = syntheticAssistantMessage(&.{}) }, .assistant_message_event = .{ .text_delta = .{
                .content_index = 0,
                .delta = delta_buffer[0..remaining],
                .partial = syntheticAssistantMessage(&.{}),
            } } } });
            self.synthetic_flood.emitted_bytes += remaining;
        }

        if (elapsed_ns >= synthetic_flood_duration_ns) {
            self.synthetic_flood.completed = true;
            try self.applySyntheticEvent(.{ .agent_end = .{ .messages = &.{} } });
        }
    }

    fn startSyntheticFloodMessage(self: *Loop) !void {
        self.synthetic_flood.message_started = true;
        try self.applySyntheticEvent(.agent_start);
        try self.applySyntheticEvent(.{ .message_start = .{ .message = .{ .assistant = syntheticAssistantMessage(&.{}) } } });
        try self.applySyntheticEvent(.{ .message_update = .{ .message = .{ .assistant = syntheticAssistantMessage(&.{}) }, .assistant_message_event = .{ .text_start = .{
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
            .move_left => _ = self.composer.editor.moveLeft(),
            .move_right => _ = self.composer.editor.moveRight(),
            .move_word_left => _ = self.composer.editor.moveWordLeft(),
            .move_word_right => _ = self.composer.editor.moveWordRight(),
            .move_up => self.moveEditorVertical(.up),
            .move_down => self.moveEditorVertical(.down),
            .backspace => _ = self.composer.editor.backspace(),
            .delete_forward => _ = self.composer.editor.deleteForward(),
            .home => self.composer.editor.moveHome(),
            .end => self.composer.editor.moveEnd(),
            .clear => {
                self.composer.editor.clear();
                self.clearClipboardTempFiles();
            },
            .kill_to_end => _ = self.composer.editor.killToEnd(),
            .kill_to_start => _ = self.composer.editor.killToStart(),
            .kill_word_back => _ = self.composer.editor.killWordBack(),
            .yank => self.composer.editor.yank() catch {},
            .undo => _ = self.composer.editor.undoLast(),
            .tab => {},
        }
    }

    fn moveEditorVertical(self: *Loop, direction: chrome.VerticalDirection) void {
        switch (chrome.verticalCursorTarget(
            &self.composer.editor,
            self.layout_state.width,
            self.layout_state.height,
            direction,
            self.composer.preferred_column_cells,
        )) {
            .cursor => |target| {
                if (self.composer.editor.moveCursorTo(target.byte)) {
                    self.composer.preferred_column_cells = target.preferred_column_cells;
                } else {
                    self.composer.preferred_column_cells = null;
                }
            },
            .history => {
                _ = switch (direction) {
                    .up => self.composer.editor.historyPrev(),
                    .down => self.composer.editor.historyNext(),
                };
                self.composer.preferred_column_cells = null;
            },
        }
    }

    const CompletionRefresh = enum { auto, force_file };
    const SlashDispatchResult = enum { not_slash, handled_clear_editor, opened_picker_keep_editor };

    const SlashArgQuery = struct {
        kind: PickerKind,
        text: []const u8,
    };

    fn handlePickerAction(self: *Loop, action: input.Action) !bool {
        if (!self.composer.picker.active) return false;
        switch (action) {
            .cancel => {
                if (self.composer.picker.currentKind() == .session) self.cancelSessionListing();
                try self.backPicker();
                return true;
            },
            .key_editor => |op| switch (op) {
                .move_up => {
                    self.movePickerSelection(-1);
                    return true;
                },
                .move_down => {
                    self.movePickerSelection(1);
                    return true;
                },
                .tab => {
                    try self.acceptPickerSelection();
                    return true;
                },
                else => return false,
            },
            .submit => {
                if (self.composer.picker.topConst().selected_row == null) return true;
                try self.acceptPickerSelection();
                return true;
            },
            else => return false,
        }
    }

    fn handleCompletionAction(self: *Loop, action: input.Action) !bool {
        switch (action) {
            .cancel => if (self.composer.completion.active) {
                self.composer.completion.clear();
                self.dirty = true;
                return true;
            },
            .insert => |text| if (std.mem.eql(u8, text, "\t")) {
                if (self.composer.completion.active) {
                    if (try self.acceptCompletion()) |mode| {
                        if (mode == .slash) try self.refreshCompletion(.auto);
                    }
                } else {
                    try self.refreshCompletion(.force_file);
                }
                return true;
            },
            .key_editor => |op| switch (op) {
                .tab => {
                    if (self.composer.completion.active) {
                        if (try self.acceptCompletion()) |mode| {
                            if (mode == .slash) try self.refreshCompletion(.auto);
                        }
                    } else {
                        try self.refreshCompletion(.force_file);
                    }
                    return true;
                },
                .move_up => if (self.composer.completion.active) {
                    self.composer.completion.move(-1);
                    return true;
                },
                .move_down => if (self.composer.completion.active) {
                    self.composer.completion.move(1);
                    return true;
                },
                else => {},
            },
            .submit => if (self.composer.completion.active) {
                if (self.composer.completion.mode == .slash) {
                    if (slash_commands.lookupInvocation(self.composer.editor.text()) != null) {
                        self.composer.completion.clear();
                    } else if ((try self.acceptCompletion()) == null) {
                        return true;
                    }
                    return false;
                }
                _ = try self.acceptCompletion();
                return true;
            },
            else => {},
        }
        return false;
    }

    fn refreshCompletion(self: *Loop, mode: CompletionRefresh) !void {
        if (mode == .auto) {
            if (try self.syncSlashArgPicker()) {
                self.composer.completion.clear();
                return;
            }
            if (self.composer.picker.active) self.composer.picker.clear();
        }
        if (mode == .force_file) return self.refreshFileCompletion(.explicit);
        const token = self.composer.editor.currentToken() orelse {
            self.composer.completion.clear();
            return;
        };
        if (token.start == 0 and std.mem.startsWith(u8, token.text, "/")) {
            return self.refreshSlashCompletion(token.text);
        }
        return self.refreshFileCompletion(.automatic);
    }

    fn refreshSlashCompletion(self: *Loop, token_text: []const u8) !void {
        self.composer.completion.reset(.slash);
        for (slash_commands.builtins) |command| {
            var label_buffer: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buffer, "/{s}", .{command.name}) catch continue;
            if (!startsWithIgnoreCase(label, token_text)) continue;
            var insert_buffer: [80]u8 = undefined;
            const insert = std.fmt.bufPrint(&insert_buffer, "/{s} ", .{command.name}) catch label;
            self.composer.completion.append(label, insert, command.summary, true);
        }
        if (self.composer.completion.candidate_len == 0) self.composer.completion.clear();
    }

    fn refreshFileCompletion(self: *Loop, trigger: coding_agent.file_completion.Trigger) !void {
        const context = coding_agent.file_completion.Context.parse(
            self.composer.editor.text(),
            self.composer.editor.cursorByte(),
            trigger,
        ) orelse {
            self.composer.completion.clear();
            return;
        };
        if (context.raw_query.len > coding_agent.file_completion.file_completion_query_bytes_max) {
            self.composer.completion.clear();
            return;
        }
        if (trigger == .explicit and context.kind == .path and context.raw_query.len > 0 and
            context.raw_query[0] == '/' and context.replace_start == 0 and
            std.mem.indexOfScalar(u8, context.raw_query[1..], '/') == null)
        {
            self.composer.completion.clear();
            return;
        }

        self.composer.completion.reset(.file);
        _ = try self.pollFileIndexTask();
        if (self.composer.file_index == null) {
            self.composer.completion.append(if (self.composer.file_index_failed) "file index unavailable" else "indexing files…", "", "", false);
            return;
        }
        var result = if (context.needsScopedQuery()) blk: {
            break :blk (try self.scopedFileQueryResult(context)) orelse {
                self.composer.completion.append("searching files…", "", "", false);
                return;
            };
        } else blk: {
            self.discardCompletedScopedFileQuery();
            break :blk try self.composer.file_index.?.query(self.gpa, context.indexQuery());
        };
        defer result.destroy(self.gpa);
        var sources_buffer: [coding_agent.file_completion.item_count_max]coding_agent.file_completion.Source = undefined;
        const sources = result.sources(&sources_buffer);
        for (sources) |source| {
            const edit = context.edit(source, self.composer.editor.text()) orelse continue;
            self.composer.completion.appendFile(source.label, source.detail, edit);
        }
        if (self.composer.completion.candidate_len == 0) self.composer.completion.clear();
    }

    fn acceptCompletion(self: *Loop) !?CompletionMode {
        const candidate = self.composer.completion.selectedCandidate() orelse return null;
        if (!candidate.selectable) return null;
        const mode = self.composer.completion.mode;
        const continue_completion = candidate.continue_completion;
        const candidate_insert = candidate.insertSlice();
        const continuation_trigger: coding_agent.file_completion.Trigger =
            if (candidate_insert.len > 0 and candidate_insert[0] == '@') .automatic else .explicit;
        if (mode == .file) {
            try self.composer.editor.replaceRange(
                candidate.replace_start,
                candidate.replace_end,
                candidate.insertSlice(),
                candidate.cursor_offset,
            );
        } else {
            const token = self.composer.editor.currentToken() orelse blk: {
                const cursor = self.composer.editor.cursorByte();
                break :blk Editor.Token{ .start = cursor, .end = cursor, .text = self.composer.editor.text()[cursor..cursor] };
            };
            try self.composer.editor.replaceToken(token, candidate.insertSlice());
        }
        self.composer.completion.clear();
        if (continue_completion) try self.refreshFileCompletion(continuation_trigger);
        self.dirty = true;
        return mode;
    }
    fn syncSlashArgPicker(self: *Loop) !bool {
        const query = self.slashArgQuery() orelse return false;
        if (self.isPickerDismissed(query.kind)) return false;
        if (self.composer.picker.active and pickerKindIsSettingsChild(self.composer.picker.currentKind()) and query.kind == .settings_root and !std.mem.startsWith(u8, query.text, "thinking:")) {
            self.openSettingsRootPicker();
        } else if (!self.composer.picker.active or !pickerKindAcceptsQuery(self.composer.picker.currentKind(), query.kind)) {
            try self.openPicker(query.kind);
        }
        self.syncPickerSelection();
        return self.composer.picker.active;
    }

    fn slashArgQuery(self: *const Loop) ?SlashArgQuery {
        const text = self.composer.editor.text();
        const cursor = self.composer.editor.cursorByte();
        if (cursor > text.len or text.len < 2 or text[0] != '/') return null;
        var name_end: usize = 1;
        while (name_end < text.len and !std.ascii.isWhitespace(text[name_end])) name_end += 1;
        if (name_end == 1 or name_end >= text.len or !std.ascii.isWhitespace(text[name_end])) return null;
        const kind = pickerKindForSlashName(text[1..name_end]) orelse return null;
        var args_start = name_end;
        while (args_start < text.len and std.ascii.isWhitespace(text[args_start])) args_start += 1;
        if (cursor < args_start) return null;
        var token_start = cursor;
        while (token_start > args_start and !std.ascii.isWhitespace(text[token_start - 1])) token_start -= 1;
        return .{ .kind = kind, .text = text[token_start..cursor] };
    }

    fn pickerKindForSlashName(name: []const u8) ?PickerKind {
        const command = slash_commands.lookup(name) orelse return null;
        return switch (command.picker) {
            .none => null,
            .model => .model,
            .session => .session,
            .settings => .settings_root,
        };
    }

    fn pickerKindIsSettings(kind: PickerKind) bool {
        return switch (kind) {
            .settings_root, .settings_thinking_effort, .settings_thinking_visibility => true,
            .model, .session => false,
        };
    }

    fn pickerKindIsSettingsChild(kind: PickerKind) bool {
        return switch (kind) {
            .settings_thinking_effort, .settings_thinking_visibility => true,
            .model, .session, .settings_root => false,
        };
    }

    fn pickerKindAcceptsQuery(kind: PickerKind, query_kind: PickerKind) bool {
        if (query_kind == .settings_root) return pickerKindIsSettings(kind);
        return kind == query_kind;
    }

    fn openPicker(self: *Loop, kind: PickerKind) !void {
        self.clearPickerDismissal();
        switch (kind) {
            .model => try self.openModelPicker(),
            .session => try self.openSessionPicker(),
            .settings_root => self.openSettingsRootPicker(),
            .settings_thinking_effort, .settings_thinking_visibility => {
                self.openSettingsRootPicker();
                try self.pushPickerFrame(kind);
            },
        }
    }

    fn pushPickerFrame(self: *Loop, kind: PickerKind) !void {
        if (!self.composer.picker.push(kind)) return error.PickerStackFull;
        self.populatePickerRowsForKind(kind);
        try self.normalizeComposerForPickerKind(kind);
        self.syncPickerSelection();
        self.composer.completion.clear();
        self.dirty = true;
    }

    fn normalizeComposerForPickerKind(self: *Loop, kind: PickerKind) !void {
        switch (kind) {
            .settings_root => try self.setComposerText("/settings "),
            .settings_thinking_effort, .settings_thinking_visibility => try self.setComposerText("/settings thinking:"),
            .model, .session => {},
        }
    }

    fn setComposerText(self: *Loop, text: []const u8) !void {
        if (std.mem.eql(u8, self.composer.editor.text(), text)) return;
        self.composer.editor.clear();
        try self.composer.editor.insert(text);
    }

    fn syncPickerSelection(self: *Loop) void {
        const frame = self.composer.picker.top();
        var visible: [picker_rows_max]usize = undefined;
        const rows = self.filteredPickerRows(&visible);
        if (frame.selected_row) |selected| {
            for (rows) |row_index| if (row_index == selected) return;
        }
        frame.selected_row = if (rows.len == 0) null else rows[0];
        self.dirty = true;
    }

    fn movePickerSelection(self: *Loop, delta: i32) void {
        const frame = self.composer.picker.top();
        var visible: [picker_rows_max]usize = undefined;
        const rows = self.filteredPickerRows(&visible);
        if (rows.len == 0) {
            frame.selected_row = null;
            return;
        }
        var current: usize = 0;
        if (frame.selected_row) |selected| for (rows, 0..) |row_index, index| {
            if (row_index == selected) {
                current = index;
                break;
            }
        };
        const len: i32 = @intCast(rows.len);
        const next = @mod(@as(i32, @intCast(current)) + delta, len);
        frame.selected_row = rows[@intCast(next)];
        self.dirty = true;
    }

    fn backPicker(self: *Loop) !void {
        if (self.composer.picker.pop()) {
            self.populatePickerRowsForKind(self.composer.picker.currentKind());
            try self.normalizeComposerForPickerKind(self.composer.picker.currentKind());
            self.syncPickerSelection();
            self.dirty = true;
            return;
        }
        self.dismissPicker();
    }

    fn dismissPicker(self: *Loop) void {
        self.composer.dismissed_picker_kind = self.composer.picker.currentKind();
        self.composer.dismissed_picker_text_len = copyBounded(self.composer.dismissed_picker_text[0..], self.composer.editor.text());
        self.composer.picker.clear();
        self.dirty = true;
    }

    fn clearPickerDismissal(self: *Loop) void {
        self.composer.dismissed_picker_kind = null;
        self.composer.dismissed_picker_text_len = 0;
    }

    fn isPickerDismissed(self: *Loop, kind: PickerKind) bool {
        const dismissed = self.composer.dismissed_picker_kind orelse return false;
        const text = self.composer.editor.text();
        if (dismissed == kind and std.mem.eql(u8, text, self.composer.dismissed_picker_text[0..self.composer.dismissed_picker_text_len])) return true;
        self.clearPickerDismissal();
        return false;
    }

    fn acceptPickerSelection(self: *Loop) !void {
        const frame = self.composer.picker.top();
        const selected = frame.selected_row orelse return;
        const row = frame.rows[selected];
        switch (row.action) {
            .none => return,
            .push => |kind| {
                try self.pushPickerFrame(kind);
                return;
            },
            .apply_model => if (row.model) |model| try self.applyModelSelection(model, row.authed),
            .resume_session => {
                if (self.noSessionMode()) {
                    try self.notice(.warn, "no-session mode: resume is disabled");
                    return;
                }
                try self.switchSession(.{ .resume_existing = .{ .session_file_name = row.idSlice() } }, "resumed session");
            },
            .thinking_level => |level| try self.applyThinkingLevelSetting(level),
            .hide_thinking => |hidden| try self.applyHideThinkingSetting(hidden),
        }
        self.composer.picker.clear();
        self.clearPickerDismissal();
        self.composer.editor.clear();
        self.composer.completion.clear();
        self.dirty = true;
    }

    fn collectTrackedPromptImagePaths(
        self: *Loop,
        prompt: []const u8,
        out: *[prompt_image_count_max]?[]u8,
    ) usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < prompt.len and count < out.len) {
            const at = std.mem.indexOfScalarPos(u8, prompt, index, '@') orelse break;
            index = at + 1;
            const path_start = index;
            while (index < prompt.len and isPromptPathByte(prompt[index])) : (index += 1) {}
            if (index == path_start) continue;
            const path = prompt[path_start..index];
            for (self.clipboard_temp_paths[0..self.clipboard_temp_path_count]) |maybe_tracked| {
                const tracked = maybe_tracked orelse continue;
                if (!std.mem.eql(u8, tracked, path)) continue;
                for (out[0..count]) |existing| {
                    if (std.mem.eql(u8, existing.?, tracked)) break;
                } else {
                    out[count] = tracked;
                    count += 1;
                }
                break;
            }
        }
        return count;
    }

    fn startPromptImagePreparation(
        self: *Loop,
        prompt: []const u8,
        paths: [prompt_image_count_max]?[]u8,
        path_count: usize,
    ) !void {
        if (self.foreground_operation != .idle) {
            try self.notice(.warn, "finish or cancel the current operation first");
            return;
        }
        const services = self.services orelse return error.NoServices;
        _ = self.session orelse return error.NoSession;

        var pinned: [prompt_image_count_max]?[]u8 = @splat(null);
        var pinned_count: usize = 0;
        errdefer self.returnPinnedPromptImagePaths(pinned, pinned_count);
        for (paths[0..path_count]) |maybe_path| {
            const path = maybe_path.?;
            pinned[pinned_count] = self.takeClipboardTempPath(path) orelse return error.ImagePathNotTracked;
            pinned_count += 1;
        }

        const cancel = try self.gpa.create(runtime.CancelSource);
        errdefer self.gpa.destroy(cancel);
        cancel.* = try runtime.CancelSource.init(self.gpa, self.io);
        errdefer cancel.deinit();
        const task = try services.task_runtime.spawn(preparePromptImagesWorker, .{
            self.gpa,
            self.io,
            pinned,
            pinned_count,
            cancel.token(),
        });
        var captured: SubmittedPrompt = .{};
        captured.set(prompt);
        self.foreground_operation = .{ .preparing_images = .{
            .task = task,
            .cancel = cancel,
            .deadline_ns = nowNs(self.io) +| prompt_image_deadline_ns,
            .prompt = captured,
            .pinned_paths = pinned,
            .pinned_path_count = pinned_count,
        } };
        self.composer.editor.pushHistory(prompt);
        self.composer.editor.clear();
        self.dirty = true;
    }

    fn pollPromptImagePreparation(self: *Loop, now_ns: u64) !void {
        switch (self.foreground_operation) {
            .preparing_images => |*preparing| {
                if (preparing.apply_result and now_ns >= preparing.deadline_ns) {
                    preparing.apply_result = false;
                    preparing.timed_out = true;
                    preparing.cancel.request();
                    try self.notice(.warn, "image preparation timed out — press up to recover the prompt");
                }
                if (!preparing.task.hasResult()) return;
                var result = preparing.task.getResult() catch |err| {
                    const apply_result = preparing.apply_result;
                    const timed_out = preparing.timed_out;
                    const pinned = preparing.pinned_paths;
                    const pinned_count = preparing.pinned_path_count;
                    self.finishPromptImagePreparation();
                    self.returnPinnedPromptImagePaths(pinned, pinned_count);
                    if (apply_result and err != error.OperationCancelled) {
                        try self.notice(.warn, "image preparation failed — press up to recover the prompt");
                    } else if (!apply_result and !timed_out) {
                        try self.notice(.info, "image preparation canceled — press up to recover the prompt");
                    }
                    return;
                };
                const apply_result = preparing.apply_result;
                const prompt = preparing.prompt;
                const pinned = preparing.pinned_paths;
                const pinned_count = preparing.pinned_path_count;
                self.finishPromptImagePreparation();
                defer result.deinit(self.gpa);
                if (!apply_result) {
                    self.returnPinnedPromptImagePaths(pinned, pinned_count);
                    try self.notice(.info, "image preparation canceled — press up to recover the prompt");
                    return;
                }
                const session = self.session orelse {
                    self.returnPinnedPromptImagePaths(pinned, pinned_count);
                    return error.NoSession;
                };
                const wake = self.wake orelse return error.NoWake;
                self.startPreparedPromptRun(session, self.io, wake, prompt.text(), &result) catch {
                    self.returnPinnedPromptImagePaths(pinned, pinned_count);
                    try self.notice(.warn, "image preparation failed — press up to recover the prompt");
                    return;
                };
                self.deletePinnedPromptImagePaths(pinned, pinned_count);
            },
            else => {},
        }
    }

    fn finishPromptImagePreparation(self: *Loop) void {
        const cancel = self.foreground_operation.preparing_images.cancel;
        cancel.deinit();
        self.gpa.destroy(cancel);
        self.foreground_operation = .idle;
        self.dirty = true;
    }

    fn takeClipboardTempPath(self: *Loop, path: []const u8) ?[]u8 {
        for (self.clipboard_temp_paths[0..self.clipboard_temp_path_count], 0..) |maybe_path, index| {
            const tracked = maybe_path orelse continue;
            if (!std.mem.eql(u8, tracked, path)) continue;
            const last = self.clipboard_temp_path_count - 1;
            self.clipboard_temp_paths[index] = self.clipboard_temp_paths[last];
            self.clipboard_temp_paths[last] = null;
            self.clipboard_temp_path_count -= 1;
            return tracked;
        }
        return null;
    }

    fn returnPinnedPromptImagePaths(
        self: *Loop,
        paths: [prompt_image_count_max]?[]u8,
        count: usize,
    ) void {
        for (paths[0..count]) |maybe_path| self.retainClipboardTempPath(maybe_path.?) catch unreachable;
    }

    fn deletePinnedPromptImagePaths(
        self: *Loop,
        paths: [prompt_image_count_max]?[]u8,
        count: usize,
    ) void {
        for (paths[0..count]) |maybe_path| {
            const path = maybe_path.?;
            deleteClipboardTempPath(self.io, path);
            self.gpa.free(path);
        }
    }

    fn clipboardImageAttachmentsFromPrompt(self: *Loop, prompt: []const u8) !PromptImageAttachments {
        var attachments: PromptImageAttachments = .{};
        errdefer attachments.deinit(self.gpa);
        var index: usize = 0;
        while (index < prompt.len and attachments.len < prompt_image_count_max) {
            const at = std.mem.indexOfScalarPos(u8, prompt, index, '@') orelse break;
            index = at + 1;
            const path_start = index;
            while (index < prompt.len and isPromptPathByte(prompt[index])) : (index += 1) {}
            if (index == path_start) continue;
            const path = prompt[path_start..index];
            if (!self.isTrackedClipboardTempPath(path)) continue;
            try attachments.appendOwned(try self.readPromptImageAttachment(path));
        }
        return attachments;
    }

    fn readPromptImageAttachment(self: *Loop, path: []const u8) !ai.ImageContent {
        const mime_type = mimeTypeForImagePath(path) orelse return error.UnsupportedFormat;
        var file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        const file_len = try file.length(self.io);
        if (file_len == 0) return error.NoImage;
        const raw_len: usize = @intCast(file_len);
        const encoded_len = std.base64.standard.Encoder.calcSize(raw_len);
        if (encoded_len > prompt_image_encoded_bytes_total_max) return error.ImageTooLarge;
        const raw = try self.gpa.alloc(u8, raw_len);
        defer self.gpa.free(raw);
        const read_len = try file.readPositionalAll(self.io, raw, 0);
        if (read_len != raw.len) return error.ShortRead;

        const encoded = try self.gpa.alloc(u8, encoded_len);
        errdefer self.gpa.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, raw);
        const mime = try self.gpa.dupe(u8, mime_type);
        errdefer self.gpa.free(mime);
        return .{ .data = encoded, .mime_type = mime };
    }

    fn submitPrompt(self: *Loop, action: input.Action) !void {
        if (self.composer.editor.endsWithBackslash() and action == .submit) {
            _ = self.composer.editor.removeTrailingBackslash();
            try self.composer.editor.insertNewline();
            return;
        }
        const text = self.composer.editor.text();
        if (text.len == 0) return;
        if (self.foregroundOperationBlocksSubmit()) {
            try self.notice(.warn, switch (self.foreground_operation) {
                .opening, .listing => "busy: session operation in progress — esc to cancel",
                .discarding_opened, .draining_previous, .restoring => "busy: switching sessions",
                .preparing_images => "busy: preparing images — esc to cancel",
                .reading_clipboard => "busy: reading clipboard image — esc to cancel",
                .idle => unreachable,
            });
            return;
        }
        self.repinViewport();
        switch (try self.dispatchSlashIfNeeded(text)) {
            .not_slash => {},
            .handled_clear_editor => {
                self.composer.editor.clear();
                self.clearClipboardTempFiles();
                return;
            },
            .opened_picker_keep_editor => return,
        }
        var expanded_buffer: [Editor.capacity]u8 = undefined;
        const expanded = try self.composer.editor.expandedText(&expanded_buffer);
        var image_paths: [prompt_image_count_max]?[]u8 = @splat(null);
        const image_path_count = self.collectTrackedPromptImagePaths(expanded, &image_paths);
        if (image_path_count > 0) {
            if (self.run_state.state != .idle) {
                try self.notice(.warn, "wait for the current run before sending images");
                return;
            }
            try self.startPromptImagePreparation(expanded, image_paths, image_path_count);
            return;
        }
        const session = self.session orelse {
            self.submitted_prompt = .{};
            self.submitted_prompt.?.set(expanded);
            self.composer.editor.pushHistory(expanded);
            self.composer.editor.clear();
            self.clearClipboardTempFiles();
            return;
        };
        const wake = self.wake orelse return error.NoWake;
        switch (action) {
            .follow_up_submit => try self.queuePromptRun(session, expanded, &.{}, .follow_up),
            .steer_submit => try self.queuePromptRun(session, expanded, &.{}, .steer),
            else => if (self.run_state.state == .running)
                try self.queuePromptRun(session, expanded, &.{}, .steer)
            else
                try self.startPromptRun(session, self.io, wake, expanded, &.{}),
        }
        self.composer.editor.pushHistory(expanded);
        self.composer.editor.clear();
        self.clearClipboardTempFiles();
    }

    fn dispatchSlashIfNeeded(self: *Loop, text: []const u8) !SlashDispatchResult {
        const action = slash_commands.dispatch(text) orelse return .not_slash;
        switch (action) {
            .help => {
                var buffer: [160]u8 = undefined;
                try self.notice(.info, slash_commands.formatAvailable(&buffer));
            },
            .session => try self.showSessionNotice(),
            .model => |model| {
                if (model.len == 0) {
                    try self.ensureSlashArgSpace("model");
                    try self.openPicker(.model);
                    return .opened_picker_keep_editor;
                } else {
                    try self.setModelByName(model);
                }
            },
            .resume_session => |selector| {
                if (self.noSessionMode()) {
                    try self.notice(.warn, "no-session mode: resume is disabled");
                    return .handled_clear_editor;
                }
                if (selector.len == 0) {
                    try self.ensureSlashArgSpace("resume");
                    try self.openPicker(.session);
                    return .opened_picker_keep_editor;
                } else {
                    try self.switchSession(.{ .resume_existing = .{ .session_file_name = selector } }, "resumed session");
                }
            },
            .new_session => {
                var id_buffer: [64]u8 = undefined;
                const stamp = coding_agent.session_manager.SessionStamp.now(self.io);
                const id = std.fmt.bufPrint(&id_buffer, "tui-{d}", .{stamp.nanoseconds}) catch "tui";
                try self.switchSession(.{ .create = .{
                    .session_id = id,
                    .timestamp = stamp.timestamp(),
                    .persist = self.shouldPersistNewSession(),
                } }, "started new session");
            },
            .compact => |instructions| {
                const session = self.session orelse {
                    try self.notice(.info, "nothing to compact");
                    return .handled_clear_editor;
                };
                const wake = self.wake orelse return error.NoWake;
                try self.startManualCompactionRun(
                    session,
                    self.io,
                    wake,
                    if (instructions.len > 0) instructions else null,
                );
            },
            .settings => {
                try self.ensureSlashArgSpace("settings");
                try self.openPicker(.settings_root);
                return .opened_picker_keep_editor;
            },
            .thinking_level => |level| try self.applyThinkingLevelSetting(level),
            .hide_thinking => |hidden| try self.applyHideThinkingSetting(hidden),
            .unknown => |name| {
                var available: [160]u8 = undefined;
                const catalog = slash_commands.formatAvailable(&available);
                try self.noticeFmt(.warn, "unknown command /{s} — {s}", .{ name, catalog });
            },
        }
        return .handled_clear_editor;
    }

    fn foregroundOperationBlocksSubmit(self: *const Loop) bool {
        return switch (self.foreground_operation) {
            .idle => false,
            .listing => |listing| listing.apply_result,
            .opening, .discarding_opened, .draining_previous, .restoring, .preparing_images, .reading_clipboard => true,
        };
    }

    fn noSessionMode(self: *Loop) bool {
        return !self.persist_new_sessions;
    }

    fn shouldPersistNewSession(self: *Loop) bool {
        return self.persist_new_sessions;
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

    fn ensureSlashArgSpace(self: *Loop, name: []const u8) !void {
        var prefix_buffer: [slash_commands.name_bytes_max + 2]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buffer, "/{s}", .{name}) catch return error.EditorFull;
        const text = self.composer.editor.text();
        if (std.mem.eql(u8, text, prefix)) {
            try self.composer.editor.insert(" ");
            return;
        }
        if (!std.mem.startsWith(u8, text, prefix)) return;
        for (text[prefix.len..]) |byte| if (!std.ascii.isWhitespace(byte)) return;
        var desired_buffer: [slash_commands.name_bytes_max + 3]u8 = undefined;
        const desired = std.fmt.bufPrint(&desired_buffer, "/{s} ", .{name}) catch return error.EditorFull;
        if (std.mem.eql(u8, text, desired)) return;
        self.composer.editor.clear();
        try self.composer.editor.insert(desired);
    }

    fn openModelPicker(self: *Loop) !void {
        const services = self.services orelse return error.NoServices;
        self.composer.picker.reset(.model);
        inline for (.{ true, false }) |want_authed| {
            for (ai.getProviders()) |provider_name| {
                for (ai.getModels(provider_name)) |model| {
                    if (services.provider_registry.get(model.api) == null) continue;
                    const authed = services.auth_manager.hasAuth(model.provider);
                    if (authed != want_authed) continue;
                    var label_buffer: [completion_text_bytes_max]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buffer, "{s}/{s}", .{ model.provider, model.id }) catch model.id;
                    self.composer.picker.appendRow(label, label, model.name, if (authed) "" else "not authenticated", model, authed, .apply_model);
                }
            }
        }
        self.syncPickerSelection();
        self.composer.completion.clear();
    }

    fn openSessionPicker(self: *Loop) !void {
        if (self.noSessionMode()) {
            try self.notice(.warn, "no-session mode: resume is disabled");
            return;
        }
        if (self.run_state.state != .idle or self.foreground_operation != .idle) {
            try self.notice(.warn, "finish or cancel the current operation first");
            return;
        }
        const services = self.services orelse return error.NoServices;
        self.composer.picker.reset(.session);
        self.composer.completion.clear();

        const cancel = try self.gpa.create(runtime.CancelSource);
        errdefer self.gpa.destroy(cancel);
        cancel.* = try runtime.CancelSource.init(self.gpa, self.io);
        errdefer cancel.deinit();
        const task = try services.task_runtime.spawn(listSessionSummariesWorker, .{
            self.gpa,
            self.io,
            services.cwd,
            services.agent_dir,
            services.dir,
            services.environ,
            cancel.token(),
        });
        self.foreground_operation = .{ .listing = .{
            .task = task,
            .cancel = cancel,
            .deadline_ns = nowNs(self.io) +| session_listing_deadline_ns,
        } };
        self.dirty = true;
    }

    fn pollForegroundOperation(self: *Loop, now_ns: u64) !void {
        switch (self.foreground_operation) {
            .idle, .discarding_opened => {},
            .listing => |*listing| try self.pollSessionListing(listing, now_ns),
            .opening => |*opening| try self.pollSessionOpening(opening, now_ns),
            .draining_previous => |*draining| try self.pollPreviousSessionDrain(draining, now_ns),
            .restoring => |*restoring| try self.pollSessionRestore(restoring, now_ns),
            .preparing_images => try self.pollPromptImagePreparation(now_ns),
            .reading_clipboard => try self.pollClipboardImageTask(now_ns),
        }
    }

    fn pollSessionListing(self: *Loop, listing: *ForegroundOperation.Listing, now_ns: u64) !void {
        if (listing.apply_result and now_ns >= listing.deadline_ns) {
            listing.apply_result = false;
            listing.cancel.request();
            if (self.composer.picker.active and self.composer.picker.currentKind() == .session) self.composer.picker.clear();
            try self.notice(.warn, "session listing timed out");
        }
        if (!listing.task.hasResult()) return;
        var summaries = listing.task.getResult() catch |err| {
            const apply_result = listing.apply_result;
            self.finishSessionListing();
            if (apply_result and err != error.OperationCancelled) {
                try self.noticeFmt(.warn, "session listing failed: {s}", .{@errorName(err)});
            }
            return;
        };
        const apply_result = listing.apply_result and self.composer.picker.active and self.composer.picker.currentKind() == .session;
        self.finishSessionListing();
        defer summaries.deinit(self.gpa);
        if (!apply_result) return;
        for (summaries.items) |summary| {
            var meta_buffer: [completion_text_bytes_max]u8 = undefined;
            const meta = std.fmt.bufPrint(&meta_buffer, "{s} {s}", .{ summary.meta, summary.aux }) catch summary.meta;
            self.composer.picker.appendRow(summary.file_name, summary.title, summary.detail, meta, null, true, .resume_session);
        }
        self.syncPickerSelection();
        self.dirty = true;
    }

    fn pollSessionOpening(self: *Loop, opening: *ForegroundOperation.Opening, now_ns: u64) !void {
        if (opening.apply_result and now_ns >= opening.deadline_ns) {
            opening.apply_result = false;
            opening.cancel.request();
            try self.notice(.warn, "session opening timed out");
        }
        if (!opening.task.hasResult()) return;
        const next = opening.task.getResult() catch |err| {
            const apply_result = opening.apply_result;
            self.finishSessionOpening();
            if (apply_result and err != error.OperationCancelled) {
                try self.failureNotice(coding_agent.failure_display.fromSessionOpenError(@errorName(err)));
            }
            return;
        };
        const apply_result = opening.apply_result;
        const success_notice = opening.success_notice;
        self.finishSessionOpening();
        if (!apply_result) {
            destroyOpenedSession(self.gpa, next);
            return;
        }
        _ = next.agent.subscribe(.{ .context = &self.transcript, .call_fn = Transcript.applyListener }) catch |err| {
            destroyOpenedSession(self.gpa, next);
            try self.failureNotice(coding_agent.failure_display.fromSessionOpenError(@errorName(err)));
            return;
        };
        const current = self.session orelse {
            destroyOpenedSession(self.gpa, next);
            return error.NoSession;
        };
        current.requestShutdown();
        self.foreground_operation = .{ .draining_previous = .{
            .next_session = next,
            .deadline_ns = now_ns +| shutdown_cancel_bound_ns,
            .success_notice = success_notice,
        } };
        self.dirty = true;
    }

    fn pollPreviousSessionDrain(self: *Loop, draining: *ForegroundOperation.DrainingPrevious, now_ns: u64) !void {
        const current = self.session orelse return error.NoSession;
        if (!current.shutdownComplete()) {
            if (now_ns >= draining.deadline_ns) return error.SessionShutdownTimedOut;
            return;
        }
        const next = draining.next_session;
        const success_notice = draining.success_notice;
        current.deinit();
        current.* = next.*;
        self.gpa.destroy(next);
        _ = self.wake orelse return error.NoWake;
        self.beginInteractiveRestore(success_notice);
    }

    fn beginInteractiveRestore(self: *Loop, success_notice: OperationNotice) void {
        self.transcript.clear();
        self.composer.editor.history_len = 0;
        self.composer.editor.history_index = null;
        self.token_cache_entry_count = std.math.maxInt(usize);
        self.token_input_total = 0;
        self.token_output_total = 0;
        self.foreground_operation = .{ .restoring = .{ .success_notice = success_notice } };
        self.repinViewport();
        self.dirty = true;
    }

    fn pollSessionRestore(self: *Loop, restoring: *ForegroundOperation.Restoring, now_ns: u64) !void {
        if (restoring.awaiting_render) return;
        if (restoring.next_step_deadline_ns) |deadline| {
            if (now_ns < deadline) return;
            restoring.next_step_deadline_ns = null;
        }
        const session = self.session orelse return error.NoSession;
        restoring.next_entry_index = try self.restoreEntriesStep(restoring.next_entry_index);
        if (restoring.next_entry_index < session.manager.entries.items.len) {
            restoring.awaiting_render = true;
            self.dirty = true;
            return;
        }
        const success_notice = restoring.success_notice;
        self.foreground_operation = .idle;
        self.refreshTokenCache();
        self.repinViewport();
        self.pending_title_update = true;
        try self.notice(.info, success_notice.text());
        self.dirty = true;
    }

    fn restoreEntriesStep(self: *Loop, start_index: usize) !usize {
        const session = self.session orelse return error.NoSession;
        var index = start_index;
        var count: usize = 0;
        var work_bytes: usize = 0;
        while (index < session.manager.entries.items.len and count < restore_entries_per_iteration_max) {
            const entry = session.manager.entries.items[index];
            const entry_bytes = restoreEntryWorkBytes(entry);
            if (count > 0 and entry_bytes > restore_work_bytes_per_iteration_target -| work_bytes) break;
            switch (entry) {
                .message => |message_entry| try self.restoreMessage(message_entry.message),
                .compaction => |compaction| try self.transcript.appendCompaction(compaction.summary, compaction.tokens_before),
                .model_change => |model_change| try self.noticeFmt(.info, "model: {s}/{s}", .{ model_change.provider, model_change.model_id }),
                .thinking_level_change => |change| try self.noticeFmt(.info, "thinking: {s}", .{change.thinking_level}),
            }
            index += 1;
            count += 1;
            work_bytes +|= entry_bytes;
        }
        self.trace.recordRestoreWork(count, work_bytes);
        return index;
    }

    fn cancelSessionListing(self: *Loop) void {
        switch (self.foreground_operation) {
            .listing => |*listing| if (listing.apply_result) {
                listing.apply_result = false;
                listing.cancel.request();
                self.dirty = true;
            },
            else => {},
        }
    }

    fn finishSessionListing(self: *Loop) void {
        const cancel = self.foreground_operation.listing.cancel;
        cancel.deinit();
        self.gpa.destroy(cancel);
        self.foreground_operation = .idle;
        self.dirty = true;
    }

    fn finishSessionOpening(self: *Loop) void {
        const cancel = self.foreground_operation.opening.cancel;
        cancel.deinit();
        self.gpa.destroy(cancel);
        self.foreground_operation = .idle;
        self.dirty = true;
    }

    fn drainForegroundOperation(self: *Loop) void {
        switch (self.foreground_operation) {
            .idle, .restoring => self.foreground_operation = .idle,
            .listing => |*listing| {
                listing.apply_result = false;
                listing.cancel.request();
                if (!listing.task.hasResult()) listing.task.cancel();
                var result = listing.task.getResult() catch null;
                if (result) |*summaries| summaries.deinit(self.gpa);
                listing.cancel.deinit();
                self.gpa.destroy(listing.cancel);
                self.foreground_operation = .idle;
            },
            .opening => |*opening| {
                opening.apply_result = false;
                opening.cancel.request();
                if (!opening.task.hasResult()) opening.task.cancel();
                const result = opening.task.getResult() catch null;
                if (result) |next| destroyOpenedSession(self.gpa, next);
                opening.cancel.deinit();
                self.gpa.destroy(opening.cancel);
                self.foreground_operation = .idle;
            },
            .discarding_opened => |next| {
                destroyOpenedSession(self.gpa, next);
                self.foreground_operation = .idle;
            },
            .draining_previous => |draining| {
                destroyOpenedSession(self.gpa, draining.next_session);
                self.foreground_operation = .idle;
            },
            .preparing_images => |*preparing| {
                preparing.apply_result = false;
                preparing.cancel.request();
                if (!preparing.task.hasResult()) preparing.task.cancel();
                var result = preparing.task.getResult() catch null;
                if (result) |*images| images.deinit(self.gpa);
                const pinned = preparing.pinned_paths;
                const pinned_count = preparing.pinned_path_count;
                preparing.cancel.deinit();
                self.gpa.destroy(preparing.cancel);
                self.foreground_operation = .idle;
                self.returnPinnedPromptImagePaths(pinned, pinned_count);
            },
            .reading_clipboard => |*reading| {
                if (!reading.task.hasResult()) reading.task.cancel();
                var result = reading.task.getResult() catch null;
                if (result) |*paste| {
                    deleteClipboardTempPath(self.io, paste.path);
                    paste.deinit(self.gpa);
                }
                self.foreground_operation = .idle;
            },
        }
    }

    fn openSettingsRootPicker(self: *Loop) void {
        self.composer.picker.reset(.settings_root);
        self.populateSettingsRootPicker();
        self.syncPickerSelection();
        self.composer.completion.clear();
    }

    fn populatePickerRowsForKind(self: *Loop, kind: PickerKind) void {
        switch (kind) {
            .settings_root => self.populateSettingsRootPicker(),
            .settings_thinking_effort => self.populateThinkingEffortPicker(),
            .settings_thinking_visibility => self.populateThinkingVisibilityPicker(),
            .model, .session => {},
        }
    }

    fn populateSettingsRootPicker(self: *Loop) void {
        self.composer.picker.appendRow("thinking-effort", "Thinking effort", "set reasoning level", "", null, true, .{ .push = .settings_thinking_effort });
        self.composer.picker.appendRow("thinking-visibility", "Thinking visibility", "show or hide thinking blocks", "", null, true, .{ .push = .settings_thinking_visibility });
    }

    fn populateThinkingEffortPicker(self: *Loop) void {
        self.composer.picker.appendRow("thinking:off", "off", "disable reasoning", "", null, true, .{ .thinking_level = .off });
        self.composer.picker.appendRow("thinking:minimal", "minimal", "minimal reasoning", "", null, true, .{ .thinking_level = .minimal });
        self.composer.picker.appendRow("thinking:low", "low", "low reasoning", "", null, true, .{ .thinking_level = .low });
        self.composer.picker.appendRow("thinking:medium", "medium", "balanced reasoning", "", null, true, .{ .thinking_level = .medium });
        self.composer.picker.appendRow("thinking:high", "high", "deep reasoning", "", null, true, .{ .thinking_level = .high });
        self.composer.picker.appendRow("thinking:xhigh", "xhigh", "maximum reasoning", "", null, true, .{ .thinking_level = .xhigh });
    }

    fn populateThinkingVisibilityPicker(self: *Loop) void {
        self.composer.picker.appendRow("thinking:shown", "shown", "show thinking blocks", "", null, true, .{ .hide_thinking = false });
        self.composer.picker.appendRow("thinking:hidden", "hidden", "hide thinking blocks", "", null, true, .{ .hide_thinking = true });
    }

    fn applyThinkingLevelSetting(self: *Loop, level: agent_mod.ThinkingLevel) !void {
        const session = self.session orelse return;
        const services = self.services orelse return error.NoServices;
        try services.settings_manager.setDefaultThinkingLevel(self.io, services.dir, @tagName(level));
        try session.setThinkingLevel(level);
        self.pending_title_update = true;
        self.dirty = true;
    }

    fn applyHideThinkingSetting(self: *Loop, hidden: bool) !void {
        const session = self.session orelse return;
        const services = self.services orelse return error.NoServices;
        try services.settings_manager.setHideThinkingBlock(self.io, services.dir, hidden);
        try session.setHideThinking(hidden);
        self.setHideThinking(hidden);
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
        try services.settings_manager.setDefaultModel(self.io, services.dir, model.provider, model.id);
        try session.setModel(model, coding_agent.session_bootstrap.streamFor(services, model));
        self.pending_title_update = true;
        try self.noticeFmt(.info, "model: {s}/{s}", .{ model.provider, model.id });
    }

    fn switchSession(self: *Loop, spec: coding_agent.session_bootstrap.OpenSpec, notice_text: []const u8) !void {
        if (self.run_state.state != .idle or self.foreground_operation != .idle) {
            try self.notice(.warn, "finish or cancel the current operation first");
            return;
        }
        const services = self.services orelse return error.NoServices;
        const current = self.session orelse return;
        const stamp = coding_agent.session_manager.SessionStamp.now(self.io);
        const request = try SessionOpenRequest.init(self.gpa, services, stamp.date(), spec, current.agent.state.model, current.agent.state.thinking_level);
        errdefer request.destroy();
        const cancel = try self.gpa.create(runtime.CancelSource);
        errdefer self.gpa.destroy(cancel);
        cancel.* = try runtime.CancelSource.init(self.gpa, self.io);
        errdefer cancel.deinit();
        request.cancel_token = cancel.token();
        const task = try services.task_runtime.spawn(openSessionWorker, .{request});
        self.foreground_operation = .{ .opening = .{
            .task = task,
            .cancel = cancel,
            .deadline_ns = nowNs(self.io) +| session_opening_deadline_ns,
            .success_notice = OperationNotice.init(notice_text),
        } };
        self.composer.picker.clear();
        self.clearPickerDismissal();
        self.composer.completion.clear();
        self.composer.editor.clear();
        self.dirty = true;
    }

    fn restoreMessage(self: *Loop, message: agent_mod.AgentMessage) !void {
        switch (message) {
            .user => |user| {
                try self.transcript.apply(self.io, .{ .message_start = .{ .message = .{ .user = user } } });
                self.composer.editor.pushHistory(restoredUserText(user));
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
            .custom => |custom| try self.transcript.apply(self.io, .{ .message_start = .{ .message = .{ .custom = custom } } }),
        }
    }

    fn dequeueAll(self: *Loop) !void {
        const session = self.session orelse return;
        try self.restoreQueuedText(session);
    }

    fn restoreQueuedText(self: *Loop, session: *coding_agent.AgentSession) !void {
        if (self.composer.editor.text().len != 0) return;
        const echoes = session.queuedEchoes();
        for (echoes, 0..) |echo, index| {
            if (index > 0) try self.composer.editor.insert("\n");
            try self.composer.editor.insert(echo.text);
        }
        try session.clearQueue();
        self.dirty = true;
    }

    fn handleCancel(self: *Loop) void {
        self.clearExitHint();
        if (self.cancelForegroundOperation()) return;
        if (self.run_state.state != .idle) {
            const session = self.session orelse return;
            self.cancelRun(session);
        }
    }

    fn cancelForegroundOperation(self: *Loop) bool {
        switch (self.foreground_operation) {
            .idle => return false,
            .listing => |*listing| if (listing.apply_result) {
                listing.apply_result = false;
                listing.cancel.request();
            },
            .opening => |*opening| if (opening.apply_result) {
                opening.apply_result = false;
                opening.cancel.request();
            },
            .preparing_images => |*preparing| if (preparing.apply_result) {
                preparing.apply_result = false;
                preparing.cancel.request();
            },
            .reading_clipboard => |*reading| reading.apply_result = false,
            .discarding_opened, .draining_previous, .restoring => {},
        }
        self.dirty = true;
        return true;
    }

    fn handleClearOrQuit(self: *Loop, now_ns: u64) !void {
        if (self.ctrl_c_deadline_ns) |deadline| {
            if (now_ns <= deadline) {
                self.exit_requested = true;
                return;
            }
        }
        if (self.composer.editor.text().len != 0) {
            self.composer.editor.clear();
            self.clearClipboardTempFiles();
            try self.afterComposerTextMutation();
        }
        self.exit_hint_visible = true;
        self.ctrl_c_deadline_ns = now_ns +| double_key_window_ns;
    }

    fn clearExitHint(self: *Loop) void {
        self.ctrl_c_deadline_ns = null;
        self.exit_hint_visible = false;
    }
};

const SessionOpenRequest = struct {
    allocator: std.mem.Allocator,
    services: *coding_agent.runtime_services.RuntimeServices,
    current_date: []u8,
    spec: coding_agent.session_bootstrap.OpenSpec,
    model: ai.Model,
    thinking_level: agent_mod.ThinkingLevel,
    cancel_token: runtime.CancelToken = undefined,

    fn init(
        allocator: std.mem.Allocator,
        services: *coding_agent.runtime_services.RuntimeServices,
        current_date: []const u8,
        spec: coding_agent.session_bootstrap.OpenSpec,
        model: ai.Model,
        thinking_level: agent_mod.ThinkingLevel,
    ) !*SessionOpenRequest {
        const self = try allocator.create(SessionOpenRequest);
        errdefer allocator.destroy(self);
        const date = try allocator.dupe(u8, current_date);
        errdefer allocator.free(date);
        const owned_spec: coding_agent.session_bootstrap.OpenSpec = switch (spec) {
            .create => |create| blk: {
                const session_id = try allocator.dupe(u8, create.session_id);
                errdefer allocator.free(session_id);
                const timestamp = try allocator.dupe(u8, create.timestamp);
                break :blk .{ .create = .{
                    .session_id = session_id,
                    .timestamp = timestamp,
                    .persist = create.persist,
                } };
            },
            .resume_existing => |existing| .{ .resume_existing = .{
                .session_file_name = try allocator.dupe(u8, existing.session_file_name),
            } },
        };
        self.* = .{
            .allocator = allocator,
            .services = services,
            .current_date = date,
            .spec = owned_spec,
            .model = model,
            .thinking_level = thinking_level,
        };
        return self;
    }

    fn destroy(self: *SessionOpenRequest) void {
        const allocator = self.allocator;
        allocator.free(self.current_date);
        switch (self.spec) {
            .create => |create| {
                allocator.free(create.session_id);
                allocator.free(create.timestamp);
            },
            .resume_existing => |existing| allocator.free(existing.session_file_name),
        }
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn openSessionWorker(request: *SessionOpenRequest) anyerror!*coding_agent.AgentSession {
    defer request.destroy();
    try request.cancel_token.throwIfRequested();
    const next = try request.allocator.create(coding_agent.AgentSession);
    errdefer request.allocator.destroy(next);
    next.* = try coding_agent.session_bootstrap.openSession(
        request.allocator,
        request.services,
        request.current_date,
        request.spec,
        .{
            .model = request.model,
            .thinking_level = request.thinking_level,
            .stream = coding_agent.session_bootstrap.streamFor(request.services, request.model),
            .cancel_token = request.cancel_token,
        },
    );
    errdefer {
        next.requestShutdown();
        next.deinit();
    }
    try request.cancel_token.throwIfRequested();
    return next;
}

fn destroyOpenedSession(allocator: std.mem.Allocator, session: *coding_agent.AgentSession) void {
    session.requestShutdown();
    std.debug.assert(session.shutdownComplete());
    session.deinit();
    allocator.destroy(session);
}

fn listSessionSummariesWorker(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    agent_dir: []const u8,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
    cancel_token: runtime.CancelToken,
) anyerror!coding_agent.session_listing.SessionSummaryList {
    try cancel_token.throwIfRequested();
    return coding_agent.session_listing.listRuntimeSessionSummaries(allocator, io, .{
        .cwd = cwd,
        .agent_dir_override = agent_dir,
        .dir = dir,
        .environ = environ,
        .cancel_token = cancel_token,
    });
}

fn preparePromptImagesWorker(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: [prompt_image_count_max]?[]u8,
    path_count: usize,
    cancel_token: runtime.CancelToken,
) anyerror!PromptImageAttachments {
    var attachments: PromptImageAttachments = .{};
    errdefer attachments.deinit(allocator);
    var encoded_total: usize = 0;
    for (paths[0..path_count]) |maybe_path| {
        try cancel_token.throwIfRequested();
        const path = maybe_path.?;
        const mime_type = mimeTypeForImagePath(path) orelse return error.UnsupportedFormat;
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        const file_len = try file.length(io);
        if (file_len == 0) return error.NoImage;
        const raw_len = std.math.cast(usize, file_len) orelse return error.ImageTooLarge;
        const encoded_len = std.base64.standard.Encoder.calcSize(raw_len);
        if (encoded_len > prompt_image_encoded_bytes_total_max -| encoded_total) return error.ImageTooLarge;
        const raw = try allocator.alloc(u8, raw_len);
        defer allocator.free(raw);
        var offset: usize = 0;
        while (offset < raw.len) {
            try cancel_token.throwIfRequested();
            const end = @min(offset + 256 * 1024, raw.len);
            const read_len = try file.readPositionalAll(io, raw[offset..end], offset);
            if (read_len != end - offset) return error.ShortRead;
            offset = end;
            try runtime.yield();
        }
        const encoded = try allocator.alloc(u8, encoded_len);
        errdefer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, raw);
        const mime = try allocator.dupe(u8, mime_type);
        errdefer allocator.free(mime);
        try attachments.appendOwned(.{ .data = encoded, .mime_type = mime });
        encoded_total += encoded_len;
    }
    try cancel_token.throwIfRequested();
    return attachments;
}

fn restoreEntryWorkBytes(entry: coding_agent.session_manager.SessionEntry) usize {
    var total: usize = 64;
    total +|= entry.id().len;
    switch (entry) {
        .message => |message| total +|= restoreMessageWorkBytes(message.message),
        .compaction => |compaction| total +|= compaction.summary.len +| compaction.first_kept_entry_id.len,
        .model_change => |change| total +|= change.provider.len +| change.model_id.len,
        .thinking_level_change => |change| total +|= change.thinking_level.len,
    }
    return @min(total, coding_agent.session_manager.max_session_line_bytes);
}

fn restoreMessageWorkBytes(message: agent_mod.AgentMessage) usize {
    var total: usize = 64;
    switch (message) {
        .user => |user| switch (user.content) {
            .string => |text| total +|= text.len,
            .blocks => |blocks| for (blocks) |block| {
                total +|= 64;
                total +|= switch (block) {
                    .text => |text| text.text.len +| if (text.text_signature) |signature| signature.len else 0,
                    .image => |image| image.data.len +| image.mime_type.len,
                };
            },
        },
        .assistant => |assistant| {
            total +|= assistant.api.len +| assistant.provider.len +| assistant.model.len;
            if (assistant.response_id) |value| total +|= value.len;
            if (assistant.error_message) |value| total +|= value.len;
            for (assistant.content) |content| {
                total +|= 64;
                total +|= switch (content) {
                    .text => |text| text.text.len +| if (text.text_signature) |signature| signature.len else 0,
                    .thinking => |thinking| thinking.thinking.len +| if (thinking.thinking_signature) |signature| signature.len else 0,
                    .tool_call => |call| call.id.len +| call.name.len +| jsonWorkBytes(call.arguments),
                };
            }
        },
        .tool_result => |result| {
            total +|= result.tool_call_id.len +| result.tool_name.len;
            for (result.content) |content| {
                total +|= 64;
                total +|= switch (content) {
                    .text => |text| text.text.len +| if (text.text_signature) |signature| signature.len else 0,
                    .image => |image| image.data.len +| image.mime_type.len,
                };
            }
            if (result.details) |details| total +|= jsonWorkBytes(details);
        },
        .custom => |custom| total +|= custom.kind.len +| jsonWorkBytes(custom.payload),
    }
    return total;
}

fn jsonWorkBytes(value: std.json.Value) usize {
    var total: usize = 64;
    switch (value) {
        .string => |text| total +|= text.len,
        .array => |array| {
            for (array.items) |item| total +|= jsonWorkBytes(item);
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| total +|= entry.key_ptr.*.len +| jsonWorkBytes(entry.value_ptr.*);
        },
        else => {},
    }
    return total;
}

fn isPromptPathByte(byte: u8) bool {
    return switch (byte) {
        0...32, '"', '\'', '<', '>' => false,
        else => true,
    };
}

fn mimeTypeForImagePath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    return null;
}

fn nonEmptyEnv(environ: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const env = environ orelse return null;
    const value = env.get(name) orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len == 0) null else value;
}

fn tmpDirFromEnv(environ: ?*const std.process.Environ.Map) []const u8 {
    return nonEmptyEnv(environ, "TMPDIR") orelse
        nonEmptyEnv(environ, "TEMP") orelse
        nonEmptyEnv(environ, "TMP") orelse
        "/tmp";
}

fn nonCooperativeShutdownWorker(io: std.Io) anyerror!ClipboardImagePaste {
    io.sleep(.fromSeconds(30), .awake) catch {};
    return error.OperationCancelled;
}

fn readClipboardImageToTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *runtime.Runtime,
    environ: ?*const std.process.Environ.Map,
    tmp_dir: []const u8,
    serial: u64,
) anyerror!ClipboardImagePaste {
    var image = try clipboard_image.read(allocator, io, task_runtime, environ);
    defer image.deinit(allocator);

    const path = try createClipboardImageTempFile(allocator, io, tmp_dir, serial, &image);
    errdefer {
        deleteClipboardTempPath(io, path);
        allocator.free(path);
    }
    const mime_type = try allocator.dupe(u8, image.mime_type);
    errdefer allocator.free(mime_type);
    return .{ .path = path, .mime_type = mime_type, .byte_len = image.bytes.len };
}

fn createClipboardImageTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_dir: []const u8,
    serial: u64,
    image: *const clipboard_image.ClipboardImage,
) ![]u8 {
    const ext = clipboard_image.extensionForMimeType(image.mime_type) orelse return error.UnsupportedFormat;
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        const stamp = std.Io.Clock.awake.now(io).nanoseconds;
        var name_buffer: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "zi-clipboard-{d}-{d}-{d}.{s}", .{ stamp, serial, attempts, ext }) catch unreachable;
        const path = try std.fs.path.join(allocator, &.{ tmp_dir, name });
        errdefer allocator.free(path);

        var file = std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        defer file.close(io);

        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        try writer.interface.writeAll(image.bytes);
        try writer.flush();
        return path;
    }
    return error.PathAlreadyExists;
}

fn deleteClipboardTempPath(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

fn clipboardImageErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoImage => "clipboard has no image",
        error.UnsupportedFormat => "clipboard image format unsupported",
        error.ToolUnavailable => "clipboard image tool unavailable",
        error.ImageTooLarge => "clipboard image too large",
        error.Timeout => "clipboard image paste timed out",
        error.EditorFull => "composer is full",
        else => "could not paste clipboard image",
    };
}

fn clipboardImageMarker(buffer: []u8, serial: u64, mime_type: []const u8, byte_len: usize) []const u8 {
    const ext = clipboard_image.extensionForMimeType(mime_type) orelse "img";
    const kib = (byte_len + 1023) / 1024;
    if (kib < 1024) {
        return std.fmt.bufPrint(buffer, "[image #{d} {s} {d} KiB]", .{ serial, ext, kib }) catch "[image]";
    }
    const tenths = (kib * 10 + 512) / 1024;
    return std.fmt.bufPrint(buffer, "[image #{d} {s} {d}.{d} MiB]", .{ serial, ext, tenths / 10, tenths % 10 }) catch "[image]";
}

fn compactionFailureName(run: *const coding_agent.AgentSession.CompactionRun) ?[]const u8 {
    return switch (run.outcome) {
        .failure => |err| @errorName(err),
        .pending => "MissingCompactionSummary",
        .summary => null,
    };
}

fn isCancelErrorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "OperationCancelled") or std.mem.eql(u8, name, "Canceled");
}

fn failureNoticeLevel(tone: coding_agent.failure_display.Tone) Transcript.NoticeLevel {
    return switch (tone) {
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
}

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

fn buildFileIndex(
    allocator: std.mem.Allocator,
    base_dir: std.Io.Dir,
    cwd: []const u8,
) anyerror!coding_agent.file_completion.Index {
    const fd = try std.posix.openat(base_dir.handle, cwd, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    defer _ = std.c.close(fd);
    return coding_agent.file_completion.Index.build(allocator, .{ .handle = fd });
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

fn resolveCodingAgentToolUi(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, args: Transcript.ToolArgs) anyerror!Transcript.ToolUi {
    const view = switch (args) {
        .value => |value| try coding_agent.tool_metadata.callViewForValue(allocator, name, value),
        .json_prefix => |prefix| try coding_agent.tool_metadata.partialCallView(allocator, name, prefix),
    };
    return .{
        .title = view.title,
        .compact_title = view.compact_title,
        .display = mapToolDisplay(view.display),
        .body_update = mapToolBodyUpdate(view.body_update),
    };
}

fn resolveCodingAgentToolResultUi(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, is_error: bool, content: []const ai.ToolResultContent, details: ?std.json.Value) anyerror!Transcript.ToolResultUi {
    const view = try coding_agent.tool_metadata.resultView(allocator, name, is_error, content, details);
    return .{ .body = view.output, .footer = view.footer };
}

fn mapToolDisplay(display: coding_agent.tool_metadata.Display) tui_blocks.ToolDisplay {
    return .{
        .presentation = switch (display.presentation) {
            .generic => .generic,
            .command => .command,
            .file => .file,
            .patch => .patch,
            .symbols => .symbols,
        },
        .body_mode = switch (display.body_mode) {
            .visible => .visible,
            .hidden_on_success => .hidden_on_success,
            .summary_only => .summary_only,
        },
        .collapse = .{
            .mode = switch (display.collapse.mode) {
                .head => .head,
                .tail => .tail,
            },
            .lines_max = display.collapse.lines_max,
        },
        .shows_duration = display.shows_duration,
        .live_updates = switch (display.live_updates) {
            .show_tail => .show_tail,
            .suppress => .suppress,
        },
    };
}

fn mapToolBodyUpdate(update: coding_agent.tool_metadata.BodyUpdate) Transcript.ToolBodyUpdate {
    return switch (update) {
        .unchanged => .unchanged,
        .clear => .clear,
        .replace => |replace| .{ .replace = .{ .body = replace.body, .footer = replace.footer } },
    };
}

fn frameRowContaining(frame: *const screen.Frame, needle: []const u8) ?usize {
    var buffer: [512]u8 = undefined;
    for (frame.rows(), 0..) |line, index| {
        if (std.mem.indexOf(u8, line.copyText(&buffer), needle) != null) return index;
    }
    return null;
}

fn expectFrameContains(frame: *const screen.Frame, needle: []const u8) !void {
    try std.testing.expect(frameRowContaining(frame, needle) != null);
}

fn expectFrameNotContains(frame: *const screen.Frame, needle: []const u8) !void {
    try std.testing.expect(frameRowContaining(frame, needle) == null);
}

fn expectFrameOrder(frame: *const screen.Frame, first: []const u8, second: []const u8) !void {
    const first_row = frameRowContaining(frame, first);
    try std.testing.expect(first_row != null);
    const second_row = frameRowContaining(frame, second);
    try std.testing.expect(second_row != null);
    try std.testing.expect(second_row.? > first_row.?);
}

test "loop vertical editor actions traverse visual rows before history" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    _ = loop.noteResize(6, 10);
    loop.composer.editor.pushHistory("older");
    try loop.composer.editor.insert("abcdefghij");

    try loop.dispatch(.{ .key_editor = .move_up });
    try std.testing.expectEqual(@as(usize, 6), loop.composer.editor.cursorByte());
    try std.testing.expectEqual(@as(?usize, 2), loop.composer.preferred_column_cells);
    try loop.dispatch(.{ .key_editor = .move_up });
    try std.testing.expectEqual(@as(usize, 2), loop.composer.editor.cursorByte());
    try loop.dispatch(.{ .key_editor = .move_up });
    try std.testing.expectEqualStrings("older", loop.composer.editor.text());
    try std.testing.expectEqual(@as(?usize, null), loop.composer.preferred_column_cells);

    try loop.dispatch(.{ .key_editor = .move_down });
    try std.testing.expectEqualStrings("abcdefghij", loop.composer.editor.text());
    loop.composer.editor.moveBufferEnd();
    try loop.dispatch(.{ .key_editor = .move_up });
    try std.testing.expect(loop.composer.preferred_column_cells != null);
    try loop.dispatch(.{ .key_editor = .move_left });
    try std.testing.expectEqual(@as(?usize, null), loop.composer.preferred_column_cells);
}

test "loop dispatch edits text through editor actions" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "abc" });
    try loop.dispatch(.{ .key_editor = .move_left });
    try loop.dispatch(.{ .insert = "x" });
    try loop.dispatch(.{ .key_editor = .backspace });

    try std.testing.expectEqualStrings("abc", loop.composer.editor.text());
    try std.testing.expect(!loop.exit_requested);
    try std.testing.expectEqual(@as(usize, 4), loop.trace.input_actions);
}

test "loop clear_or_quit clears first then exits" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "draft" });
    try loop.dispatch(.clear_or_quit);
    try std.testing.expectEqualStrings("", loop.composer.editor.text());
    try std.testing.expect(!loop.exit_requested);
    try loop.dispatch(.clear_or_quit);
    try std.testing.expect(loop.exit_requested);
}

test "loop submit snapshots editor and clears input" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "hello" });
    try loop.dispatch(.submit);

    try std.testing.expectEqualStrings("hello", loop.submittedPrompt().?);
    try std.testing.expectEqualStrings("", loop.composer.editor.text());
    try std.testing.expect(loop.dirty);
}

test "loop owner step drains input before compose paint flush commit" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    var pump: InputPump = .{};
    try std.testing.expect(pump.pushBatch("hi", 1));

    const result = try loop.step(&terminal, &pump, .{
        .now_ns = frame_floor_ns,
        .width = 80,
        .height = 2,
    });

    try std.testing.expect(result.rendered);
    try std.testing.expect(!result.exit_requested);
    try std.testing.expectEqualStrings("hi", loop.composerText());
    try std.testing.expect(!loop.dirty);
    try std.testing.expectEqual(@as(usize, 1), loop.trace.renders.count);
    try std.testing.expectEqualStrings("h", terminal.vx.?.screen.readCell(0, 1).?.char.grapheme);
}

test "loop nearest deadline includes lone escape and foreground operations" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.dirty = false;

    try loop.feedInputBytes("\x1b");
    loop.updateLoneEscapeDeadline(100);
    try std.testing.expectEqual(
        @as(?u64, 100 + InputDecoder.lone_escape_timeout_ns),
        loop.nextDeadline(),
    );
    try loop.expireLoneEscapeIfDue(100 + InputDecoder.lone_escape_timeout_ns);
    try std.testing.expect(loop.dirty);

    loop.dirty = false;
    loop.foreground_operation = .{ .listing = .{
        .task = undefined,
        .cancel = undefined,
        .deadline_ns = 900,
    } };
    try std.testing.expectEqual(@as(?u64, 900), loop.nextDeadline());
    try std.testing.expect(loop.foregroundOperationBlocksSubmit());
    try std.testing.expectEqualStrings("Loading sessions… (esc to cancel)", loop.statusView(0).text);

    loop.foreground_operation = .{ .reading_clipboard = .{
        .task = undefined,
        .deadline_ns = 700,
    } };
    try std.testing.expectEqual(@as(?u64, 700), loop.nextDeadline());
    try std.testing.expectEqualStrings("Reading clipboard image… (esc to cancel)", loop.statusView(0).text);
    loop.foreground_operation = .idle;
}

test "prompt image worker enforces aggregate encoded cap and cancellation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const accepted_raw = try std.testing.allocator.alloc(u8, 64);
    defer std.testing.allocator.free(accepted_raw);
    @memset(accepted_raw, 0x5a);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "accepted.png", .data = accepted_raw });
    const oversized_raw = try std.testing.allocator.alloc(u8, 590 * 1024);
    defer std.testing.allocator.free(oversized_raw);
    @memset(oversized_raw, 0x6b);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "oversized.png", .data = oversized_raw });

    var accepted_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const accepted_len = try tmp.dir.realPathFile(std.testing.io, "accepted.png", &accepted_buffer);
    var oversized_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const oversized_len = try tmp.dir.realPathFile(std.testing.io, "oversized.png", &oversized_buffer);

    var cancel = try runtime.CancelSource.init(std.testing.allocator, std.testing.io);
    defer cancel.deinit();
    var paths: [prompt_image_count_max]?[]u8 = @splat(null);
    paths[0] = accepted_buffer[0..accepted_len];
    var images = try preparePromptImagesWorker(std.testing.allocator, std.testing.io, paths, 1, cancel.token());
    defer images.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expect(images.items[0].data.len <= prompt_image_encoded_bytes_total_max);

    paths[0] = oversized_buffer[0..oversized_len];
    try std.testing.expectError(
        error.ImageTooLarge,
        preparePromptImagesWorker(std.testing.allocator, std.testing.io, paths, 1, cancel.token()),
    );
    cancel.request();
    paths[0] = accepted_buffer[0..accepted_len];
    try std.testing.expectError(
        error.OperationCancelled,
        preparePromptImagesWorker(std.testing.allocator, std.testing.io, paths, 1, cancel.token()),
    );
}

test "loop extracts tracked clipboard image attachments from expanded prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "zi-clipboard-test.png", .data = "png-bytes" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "zi-clipboard-test.png" });
    defer std.testing.allocator.free(path);

    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.io = std.testing.io;
    loop.clipboard_temp_paths[0] = try std.testing.allocator.dupe(u8, path);
    loop.clipboard_temp_path_count = 1;

    const prompt = try std.fmt.allocPrint(std.testing.allocator, "look @{s}", .{path});
    defer std.testing.allocator.free(prompt);
    var attachments = try loop.clipboardImageAttachmentsFromPrompt(prompt);
    defer attachments.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), attachments.images().len);
    try std.testing.expectEqualStrings("image/png", attachments.images()[0].mime_type);
    try std.testing.expectEqualStrings("cG5nLWJ5dGVz", attachments.images()[0].data);
}

test "loop dispatches mapped key actions end-to-end" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(input.fromKey(.{ .codepoint = 'a', .text = "a" }));
    try loop.dispatch(input.fromKey(.{ .codepoint = 'b', .text = "b" }));
    try loop.dispatch(input.fromKey(.{ .codepoint = vaxis.Key.left }));
    try loop.dispatch(input.fromKey(.{ .codepoint = vaxis.Key.backspace }));

    try std.testing.expectEqualStrings("b", loop.composer.editor.text());
}

test "loop init seeds editor from initial prompt" {
    var loop = try Loop.initTest(std.testing.allocator, "hello");
    defer loop.deinit();
    try std.testing.expectEqualStrings("hello", loop.composer.editor.text());
}

test "loop composes frame and clears dirty only after render success" {
    var loop = try Loop.initTest(std.testing.allocator, "draft");
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "!" });
    try std.testing.expect(loop.dirty);

    const frame = try loop.composeFrame(80, 2);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("draft!", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqual(@as(u16, 6), frame.cursor.?.col);
    try std.testing.expect(loop.dirty);
    loop.markRendered(1, 2);
    try std.testing.expect(!loop.dirty);
    try std.testing.expectEqual(@as(usize, 1), loop.trace.renders.count);
}

test "loop one-row transcript gives content priority over tail margin" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.transcript.appendNotice(.info, "visible");

    const frame = try loop.composeFrame(80, 2);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(" visible", frame.rows()[0].copyText(&buffer));
}

test "loop keeps input foreground while transcript relayout is pending" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.seedSyntheticItems(Transcript.transcript_items_max);

    _ = try loop.composeFrame(80, 10);
    try std.testing.expect(loop.transcript.hasPendingRelayout());
    try std.testing.expect(
        loop.transcript.lastLayoutWork().items_laid_out <= Transcript.relayout_items_per_prepare,
    );

    try loop.dispatch(.{ .insert = "x" });
    const frame = try loop.composeFrame(80, 10);
    try std.testing.expectEqualStrings("x", loop.composer.editor.text());
    try expectFrameContains(&frame, "x");
    try std.testing.expect(loop.transcript.hasPendingRelayout());
}

test "loop viewport anchors while appended lines arrive" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.seedSyntheticItems(10);

    var frame = try loop.composeFrame(80, 10);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" seed item 7", frame.rows()[0].copyText(&buffer));

    try loop.dispatch(.{ .scroll = -3 });
    frame = try loop.composeFrame(80, 10);
    try std.testing.expectEqualStrings(" seed item 5", frame.rows()[0].copyText(&buffer));

    try loop.transcript.appendNotice(.info, "new item");
    frame = try loop.composeFrame(80, 10);
    try std.testing.expectEqualStrings(" seed item 5", frame.rows()[0].copyText(&buffer));
    try expectFrameContains(&frame, "↓ 2 new lines");
}

test "loop viewport clamps to oldest live item after eviction" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.seedSyntheticItems(Transcript.transcript_items_max);
    for (0..Transcript.transcript_items_max / Transcript.relayout_items_per_prepare + 1) |_| {
        _ = try loop.composeFrame(80, 8);
        if (!loop.transcript.hasPendingRelayout()) break;
    }
    try std.testing.expect(!loop.transcript.hasPendingRelayout());

    try loop.dispatch(.{ .scroll = -100_000 });
    _ = try loop.composeFrame(80, 8);
    for (0..10) |index| {
        var text: [32]u8 = undefined;
        try loop.transcript.appendNotice(.info, try std.fmt.bufPrint(&text, "extra {d}", .{index}));
    }

    const frame = try loop.composeFrame(80, 8);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(" seed item 10", frame.rows()[0].copyText(&buffer));
}

test "loop viewport clamps line within anchored item on width rebuild" {
    var loop = try Loop.initTest(std.testing.allocator, null);
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
    var loop = try Loop.initTest(std.testing.allocator, null);
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
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    try loop.transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = "Run tools" }, .timestamp = 0 } } } });

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "command", .{ .string = "pwd" });
    const call = ai.ToolCall{ .id = "call-1", .name = "bash", .arguments = .{ .object = args_object } };
    const tool_content = [_]ai.AssistantContent{.{ .tool_call = call }};
    const tool_assistant = Loop.syntheticAssistantMessage(&tool_content);
    try loop.transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = tool_assistant } } });
    try loop.transcript.apply(std.testing.io, .{ .message_update = .{ .message = .{ .assistant = tool_assistant }, .assistant_message_event = .{ .toolcall_start = .{
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

    const frame = try loop.composeFrame(80, 16);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", frame.rows()[0].copyText(&buffer));
    try std.testing.expect(std.meta.eql(frame.rows()[0].row_style.bg, screen.surface.user_message.bg));
    try std.testing.expectEqualStrings(" Run tools", frame.rows()[1].copyText(&buffer));
    try expectFrameContains(&frame, " $ pwd");
    try expectFrameContains(&frame, " ╭───");
    try expectFrameContains(&frame, " │ /tmp/repo");
    try expectFrameContains(&frame, " ╰───");
    try expectFrameContains(&frame, " Done");
    try expectFrameOrder(&frame, " Run tools", " $ pwd");
    try expectFrameOrder(&frame, " $ pwd", " Done");
}

test "loop thinking relayout preserves anchored item" {
    var loop = try Loop.initTest(std.testing.allocator, null);
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
    try std.testing.expectEqualStrings(" after 2", frame.rows()[0].copyText(&buffer));

    loop.setHideThinking(false);
    frame = try loop.composeFrame(10, 8);
    try std.testing.expectEqualStrings(" after 2", frame.rows()[0].copyText(&buffer));
}

test "loop collapsed tool body ending newline has no blank before marker" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "one\ntwo\nthree\nfour\nfive\nsix\n" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .result = .{ .content = &result_content },
        .is_error = false,
    } });

    const frame = try loop.composeFrame(80, 14);
    const marker_row = frameRowContaining(&frame, "│ ... (1 earlier lines, ctrl+o to expand)");
    try std.testing.expect(marker_row != null);
    try std.testing.expect(marker_row.? + 1 < frame.rows().len);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(" │ two", frame.rows()[marker_row.? + 1].copyText(&buffer));
}

test "loop tool UX shows bash live tail" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "command", .{ .string = "zig build test" });
    const args = std.json.Value{ .object = args_object };
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "bash-1", .tool_name = "bash", .args = args } });
    const update_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "compile\npass" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_update = .{ .tool_call_id = "bash-1", .tool_name = "bash", .args = args, .partial_result = .{ .content = &update_content } } });

    const frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&frame, "$ zig build test");
    try expectFrameContains(&frame, "│ pass");
}

test "loop tool UX hides successful read body" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/main.zig" });
    const args = std.json.Value{ .object = args_object };
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "read-1", .tool_name = "read", .args = args } });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "secret file body" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "read-1", .tool_name = "read", .result = .{ .content = &result_content }, .is_error = false } });

    const frame = try loop.composeFrame(80, 10);
    try expectFrameContains(&frame, "read src/main.zig");
    try expectFrameNotContains(&frame, "secret file body");
}

test "loop tool UX shows successful read body when expanded" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/main.zig" });
    const args = std.json.Value{ .object = args_object };
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "read-2", .tool_name = "read", .args = args } });

    var details_object: std.json.ObjectMap = .empty;
    defer details_object.deinit(std.testing.allocator);
    try details_object.put(std.testing.allocator, "nextOffset", .{ .integer = 51 });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "[Showing lines 1-50 of 200. Use offset=51 to continue.]" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{
        .tool_call_id = "read-2",
        .tool_name = "read",
        .result = .{ .content = &result_content, .details = .{ .object = details_object } },
        .is_error = false,
    } });

    loop.toggleExpanded();
    const frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&frame, "read src/main.zig");
    try expectFrameContains(&frame, "│ [Showing lines 1-50");
}

test "loop tool UX shows write content preview and preserves it on success" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/tui/glyphs.zig" });
    try args_object.put(std.testing.allocator, "content", .{ .string = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve\n" });
    const args = std.json.Value{ .object = args_object };
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "write-1", .tool_name = "write", .args = args } });
    const update_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "PRIVATE FILE CONTENT" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_update = .{ .tool_call_id = "write-1", .tool_name = "write", .args = args, .partial_result = .{ .content = &update_content } } });

    var frame = try loop.composeFrame(80, 24);
    try expectFrameContains(&frame, "write src/tui/glyphs.zig");
    try expectFrameContains(&frame, "│ one");
    try expectFrameContains(&frame, "│ ten");
    try expectFrameContains(&frame, "... (2 more lines, ctrl+o to expand)");
    try expectFrameNotContains(&frame, "eleven");
    try expectFrameNotContains(&frame, "PRIVATE FILE CONTENT");

    loop.toggleExpanded();
    frame = try loop.composeFrame(80, 24);
    try expectFrameContains(&frame, "│ eleven");

    var details_object: std.json.ObjectMap = .empty;
    defer details_object.deinit(std.testing.allocator);
    try details_object.put(std.testing.allocator, "bytesWritten", .{ .integer = 20 });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "Successfully wrote 20 bytes to src/tui/glyphs.zig" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "write-1", .tool_name = "write", .result = .{ .content = &result_content, .details = .{ .object = details_object } }, .is_error = false } });
    frame = try loop.composeFrame(80, 24);
    try expectFrameContains(&frame, "│ one");
    try expectFrameNotContains(&frame, "Successfully wrote 20 bytes");
}

test "loop tool UX streams write args before execution result" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    try loop.transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = Loop.syntheticAssistantMessage(&.{}) } } });

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    const call = ai.ToolCall{ .id = "write-stream", .name = "write", .arguments = .{ .object = args_object } };
    const content = [_]ai.AssistantContent{.{ .tool_call = call }};
    const partial = Loop.syntheticAssistantMessage(&content);
    try loop.transcript.apply(std.testing.io, .{ .message_update = .{ .message = .{ .assistant = partial }, .assistant_message_event = .{ .toolcall_start = .{
        .content_index = 0,
        .partial = partial,
    } } } });

    try loop.transcript.apply(std.testing.io, .{ .message_update = .{ .message = .{ .assistant = partial }, .assistant_message_event = .{ .toolcall_delta = .{
        .content_index = 0,
        .delta = "{\"path\":\"src/stream.zig\",\"content\":\"one\\n",
        .partial = partial,
    } } } });
    var frame = try loop.composeFrame(80, 16);
    try expectFrameContains(&frame, "write src/stream.zig");
    try expectFrameContains(&frame, "│ one");
    try expectFrameNotContains(&frame, "Successfully wrote");

    try loop.transcript.apply(std.testing.io, .{ .message_update = .{ .message = .{ .assistant = partial }, .assistant_message_event = .{ .toolcall_delta = .{
        .content_index = 0,
        .delta = "two",
        .partial = partial,
    } } } });
    frame = try loop.composeFrame(80, 16);
    try expectFrameContains(&frame, "│ two");
}

test "loop tool UX suppresses write result content when bytes written is known" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/tui/glyphs.zig" });
    try args_object.put(std.testing.allocator, "content", .{ .string = "preview" });
    const args = std.json.Value{ .object = args_object };
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "write-2", .tool_name = "write", .args = args } });

    var details_object: std.json.ObjectMap = .empty;
    defer details_object.deinit(std.testing.allocator);
    try details_object.put(std.testing.allocator, "bytesWritten", .{ .integer = 20 });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "PRIVATE FINAL CONTENT" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{
        .tool_call_id = "write-2",
        .tool_name = "write",
        .result = .{ .content = &result_content, .details = .{ .object = details_object } },
        .is_error = false,
    } });

    const frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&frame, "write src/tui/glyphs.zig");
    try expectFrameContains(&frame, "│ preview");
    try expectFrameNotContains(&frame, "PRIVATE FINAL CONTENT");
}

test "loop tool UX renders symbols result visibly" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/tui/Loop.zig" });
    const args = std.json.Value{ .object = args_object };
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "symbols-1", .tool_name = "symbols", .args = args } });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "750\tfn\tcomposeFrame\n1214\tfn\tpopupView" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "symbols-1", .tool_name = "symbols", .result = .{ .content = &result_content }, .is_error = false } });

    const frame = try loop.composeFrame(80, 14);
    try expectFrameContains(&frame, "symbols src/tui/Loop.zig");
    try expectFrameContains(&frame, "│ 750\tfn\tcomposeFrame");
}

test "loop tool UX renders edit patch with diff styles" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/tui/chrome.zig" });
    const args = std.json.Value{ .object = args_object };
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "edit-1", .tool_name = "edit", .args = args } });
    var details_object: std.json.ObjectMap = .empty;
    defer details_object.deinit(std.testing.allocator);
    try details_object.put(std.testing.allocator, "diff", .{ .string = "@@ line 10\n-old\n+new" });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "edited" } }};
    try loop.transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "edit-1", .tool_name = "edit", .result = .{ .content = &result_content, .details = .{ .object = details_object } }, .is_error = false } });

    const frame = try loop.composeFrame(80, 14);
    try expectFrameContains(&frame, "edit src/tui/chrome.zig");
    const added_row = frameRowContaining(&frame, "│ +new");
    try std.testing.expect(added_row != null);
    try std.testing.expect(std.meta.eql(frame.rows()[added_row.?].spans()[2].style.fg, screen.diff.added.fg));
}

test "loop working status uses shimmer effect" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.transcript.run_active = true;

    const frame = try loop.composeFrameAt(80, 3, 6 * 32 * std.time.ns_per_ms);
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Working…", frame.rows()[1].copyText(&buffer));
    try std.testing.expect(frame.rows()[1].spans().len > 1);
}

test "loop shimmer cadence recovers immediately after a slow frame" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.transcript.run_active = true;
    loop.markRendered(frame_floor_ns, 50 * std.time.ns_per_ms);
    loop.dirty = false;

    const due = frame_floor_ns * 2;
    try std.testing.expectEqual(@as(?u64, due), loop.nextDeadline());
    try std.testing.expect(!loop.shouldRender(due - 1));
    try std.testing.expect(loop.shouldRender(due));
}

test "loop retry status redraws on countdown cadence without dirty" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.run_state.state = .{ .retry_wait = .{ .delay_ms = 5_000 } };
    loop.run_state.retry = .{ .deadline_ns = 5 * std.time.ns_per_s, .attempt = 1, .max = 3 };
    loop.markRendered(0, 1 * std.time.ns_per_ms);
    loop.dirty = false;

    try std.testing.expectEqual(@as(?u64, retry_status_tick_ns), loop.nextDeadline());
    try std.testing.expect(!loop.shouldRender(retry_status_tick_ns - 1));
    try std.testing.expect(loop.shouldRender(retry_status_tick_ns));
}

test "loop dirty cadence is independent of historical render cost" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try std.testing.expect(!loop.shouldRender(frame_floor_ns - 1));
    try std.testing.expect(loop.shouldRender(frame_floor_ns));

    loop.markRendered(frame_floor_ns, 50 * std.time.ns_per_ms);
    loop.dirty = true;
    try std.testing.expect(!loop.shouldRender(frame_floor_ns * 2 - 1));
    try std.testing.expect(loop.shouldRender(frame_floor_ns * 2));
    try std.testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), loop.trace.renders.max_ns);
}

test "loop ctrl-c hint expires on timer tick" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatchAt(.clear_or_quit, 100);
    try std.testing.expect(loop.exit_hint_visible);
    loop.dirty = false;
    try std.testing.expectEqual(@as(?u64, 100 + double_key_window_ns), loop.nextDeadline());
    try loop.tick(101 + double_key_window_ns);
    try std.testing.expect(!loop.exit_hint_visible);
    try std.testing.expect(loop.dirty);
}

test "loop records frame input and event counts on render" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.frame_input_bytes += 3;
    try loop.dispatch(.{ .insert = "abc" });
    loop.markRenderedWithTimings(frame_floor_ns, .{
        .apply_ns = std.time.ns_per_us,
        .layout_ns = 2 * std.time.ns_per_us,
        .paint_ns = 3 * std.time.ns_per_us,
        .flush_ns = 4 * std.time.ns_per_us,
    });

    const record = loop.trace.frames.newest().?;
    try std.testing.expectEqual(@as(usize, 3), record.input_bytes);
    try std.testing.expectEqual(@as(usize, 1), record.events_applied);
    try std.testing.expectEqual(@as(u64, 1), record.apply_us);
    try std.testing.expectEqual(@as(u64, 2), record.layout_us);
    try std.testing.expectEqual(@as(u64, 3), record.paint_us);
    try std.testing.expectEqual(@as(u64, 4), record.flush_us);
    try std.testing.expectEqual(@as(u64, 9 * std.time.ns_per_us), loop.trace.renders.max_ns);
}

test "loop traces animated frame gaps and full-target misses" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.transcript.run_active = true;

    loop.markRendered(frame_floor_ns, 0);
    loop.markRendered(frame_floor_ns * 2, 0);
    loop.markRendered(frame_floor_ns * 5, 0);

    try std.testing.expectEqual(@as(usize, 2), loop.trace.animated_frame_gaps.count);
    try std.testing.expectEqual(@as(usize, 1), loop.trace.animated_deadline_misses);
}

test "loop synthetic flood feeds real transcript events at one megabyte per second" {
    var loop = try Loop.initTest(std.testing.allocator, null);
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
    var loop = try Loop.initTest(std.testing.allocator, null);
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
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    try loop.dispatch(.{ .insert = "/help" });
    try loop.dispatch(.submit);
    try std.testing.expectEqual(@as(usize, 1), loop.transcript.items.items.len);
    try std.testing.expect(loop.transcript.items.items[0].kind == .notice);
    try std.testing.expect(!loop.composer.completion.active);
}

test "loop enter accepts and submits selected slash completion" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    try loop.dispatch(.{ .insert = "/he" });
    try std.testing.expect(loop.composer.completion.active);
    try loop.dispatch(.submit);

    try std.testing.expectEqualStrings("", loop.composer.editor.text());
    try std.testing.expectEqual(@as(usize, 1), loop.transcript.items.items.len);
    const notice = loop.transcript.items.items[0].kind.notice;
    try std.testing.expect(std.mem.startsWith(u8, notice.text, "available commands:"));
}

test "loop enter opens picker for selected picker-backed slash completion" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    try loop.dispatch(.{ .insert = "/sett" });
    try std.testing.expect(loop.composer.completion.active);
    try loop.dispatch(.submit);

    try std.testing.expect(loop.composer.picker.active);
    try std.testing.expectEqual(PickerKind.settings_root, loop.composer.picker.currentKind());
    try std.testing.expectEqualStrings("/settings ", loop.composer.editor.text());
}

test "loop tab accepts slash completion without submitting" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    try loop.dispatch(.{ .insert = "/he" });
    try std.testing.expect(loop.composer.completion.active);
    try loop.dispatch(.{ .key_editor = .tab });

    try std.testing.expectEqualStrings("/help ", loop.composer.editor.text());
    try std.testing.expectEqual(@as(usize, 0), loop.transcript.items.items.len);
}

test "loop slash completion only activates for command token at input start" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    try loop.dispatch(.{ .insert = "explain /sett" });
    try std.testing.expect(!loop.composer.completion.active);

    loop.composer.editor.clear();
    try loop.dispatch(.{ .insert = "/help /sett" });
    try std.testing.expect(!loop.composer.completion.active);

    loop.composer.editor.clear();
    try loop.dispatch(.{ .insert = " /sett" });
    try std.testing.expect(!loop.composer.completion.active);
}

test "loop picker window follows chrome candidate capacity" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    loop.composer.picker.reset(.model);
    loop.composer.picker.appendRow("0", "item0", "", "", null, true, .none);
    loop.composer.picker.appendRow("1", "item1", "", "", null, true, .none);
    loop.composer.picker.appendRow("2", "item2", "", "", null, true, .none);
    loop.composer.picker.appendRow("3", "item3", "", "", null, true, .none);
    loop.composer.picker.appendRow("4", "item4", "", "", null, true, .none);
    loop.composer.picker.appendRow("5", "item5", "", "", null, true, .none);
    loop.composer.picker.top().selected_row = 5;

    const frame = try loop.composeFrame(80, 10);
    try expectFrameContains(&frame, "› item5");
}

test "loop P4 composer chrome caches assistant usage" {
    var fixture = try RunTestFixture.init("done");
    defer fixture.deinit();

    const content = [_]ai.AssistantContent{ai.faux.text("usage-bearing reply")};
    var assistant = ai.faux.assistantMessage(&content, .{});
    assistant.usage.input = 70;
    assistant.usage.output = 30;
    assistant.usage.total_tokens = 100;
    const entry = try fixture.session.manager.prepareMessageEntry(.{ .assistant = assistant }, "2026-07-07T00:00:00Z");
    _ = fixture.session.manager.commitPreparedEntry(entry);

    const frame = try fixture.owner_loop.composeFrame(80, 6);
    try expectFrameContains(&frame, "ctx 0%/128k • faux-default");
    try std.testing.expect(frameRowContaining(&frame, "(off)") == null);
    const row_index = frameRowContaining(&frame, "ctx 0%/128k") orelse return error.MissingComposerContext;
    const top_row = frame.rows()[row_index];
    try std.testing.expect(std.meta.eql(top_row.spans()[0].style.fg, screen.text.border.fg));
    var saw_muted_ctx = false;
    for (top_row.spans()) |span| {
        if (std.mem.indexOf(u8, span.text, "ctx 0%/128k") != null) {
            saw_muted_ctx = std.meta.eql(span.style.fg, screen.text.muted.fg);
        }
    }
    try std.testing.expect(saw_muted_ctx);

    fixture.session.agent.setThinkingLevel(.low);
    const thinking_frame = try fixture.owner_loop.composeFrame(80, 6);
    try expectFrameContains(&thinking_frame, "ctx 0%/128k • faux-default (low)");
}

test "loop P4 restore renders compaction summary" {
    var fixture = try RunTestFixture.init("done");
    defer fixture.deinit();

    const user_entry = try fixture.session.manager.prepareMessageEntry(.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }, "2026-07-07T00:00:00Z");
    const first_kept_entry_id = fixture.session.manager.commitPreparedEntry(user_entry);
    const compaction_entry = try fixture.session.manager.prepareCompactionEntry("summary", first_kept_entry_id, 100, "2026-07-07T00:00:01Z");
    _ = fixture.session.manager.commitPreparedEntry(compaction_entry);

    try fixture.owner_loop.restoreSessionFold();
    const frame = try fixture.owner_loop.composeFrame(80, 14);
    try expectFrameContains(&frame, "[compaction]");
    try expectFrameContains(&frame, "Compacted from 100 tokens");
}

test "loop P4 restore fold renders durable user tool and assistant transcript" {
    var fixture = try RunTestFixture.init("done");
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
    const frame = try fixture.owner_loop.composeFrame(80, 16);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", frame.rows()[0].copyText(&buffer));
    try std.testing.expect(std.meta.eql(frame.rows()[0].row_style.bg, screen.surface.user_message.bg));
    try std.testing.expectEqualStrings(" Run pwd", frame.rows()[1].copyText(&buffer));
    try expectFrameContains(&frame, " $ pwd");
    try expectFrameContains(&frame, " ╭───");
    try expectFrameContains(&frame, " │ /tmp/repo");
    try expectFrameOrder(&frame, " $ pwd", " │ /tmp/repo");
}

test "file index worker scopes paths to the service cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/src/main.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.txt", .data = "" });

    var index = try buildFileIndex(std.testing.allocator, tmp.dir, "repo");
    defer index.deinit(std.testing.allocator);
    var result = try index.query(std.testing.allocator, "main");
    defer result.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), result.item_len);
    try std.testing.expectEqualStrings("src/main.zig", result.items[0].idSlice());
}

test "loop P4 file completion accepts inline selected candidate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "" });

    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.composer.file_index = try coding_agent.file_completion.Index.build(std.testing.allocator, tmp.dir);

    try loop.dispatch(.{ .insert = "see @ma" });
    try std.testing.expect(loop.composer.completion.active);
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqualStrings("see @main.zig ", loop.composer.editor.text());
}

test "loop file completion quotes spaces and continues inside directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "my folder");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "my folder/test.txt", .data = "" });

    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.composer.file_index = try coding_agent.file_completion.Index.build(std.testing.allocator, tmp.dir);

    try loop.dispatch(.{ .insert = "@my" });
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqualStrings("@\"my folder/\"", loop.composer.editor.text());
    try std.testing.expectEqual(loop.composer.editor.text().len - 1, loop.composer.editor.cursorByte());
    try std.testing.expect(loop.composer.completion.active);

    try loop.dispatch(.{ .insert = "te" });
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqualStrings("@\"my folder/test.txt\" ", loop.composer.editor.text());
}

test "loop explicit tab completes ordinary dot slash path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");

    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.composer.file_index = try coding_agent.file_completion.Index.build(std.testing.allocator, tmp.dir);

    try loop.dispatch(.{ .insert = "open ./sr" });
    try std.testing.expect(!loop.composer.completion.active);
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expect(loop.composer.completion.active);
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqualStrings("open ./src/", loop.composer.editor.text());
}

test "loop completion popup windows selected candidate" {
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();

    loop.composer.completion.reset(.file);
    const labels = [_][]const u8{ "item0", "item1", "item2", "item3", "item4", "item5", "item6", "item7", "item8", "item9" };
    for (labels) |label| loop.composer.completion.append(label, label, "", true);
    loop.composer.completion.selected = 9;

    const frame = try loop.composeFrame(80, 30);
    try expectFrameContains(&frame, "› item9");
    try expectFrameNotContains(&frame, "item0");
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
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.services = &services;
    loop.session = &session;
    loop.io = services.io;
    loop.wake = &wake;
    loop.trace_io_ready = true;
    try loop.requestFileIndexRebuild();

    try loop.dispatch(.{ .insert = "/resume" });
    try loop.dispatch(.submit);
    try std.testing.expect(loop.composer.picker.active);
    try std.testing.expectEqual(PickerKind.session, loop.composer.picker.currentKind());
    try std.testing.expectEqualStrings("/resume ", loop.composer.editor.text());
    try loop.dispatch(.cancel);
    loop.composer.editor.clear();

    try loop.dispatch(.{ .insert = "/model" });
    try loop.dispatch(.submit);
    try std.testing.expect(loop.composer.picker.active);
    try std.testing.expectEqual(PickerKind.model, loop.composer.picker.currentKind());
    try loop.dispatch(.cancel);
    try std.testing.expect(!loop.composer.picker.active);
    try std.testing.expectEqualStrings("/model ", loop.composer.editor.text());
    try loop.dispatch(.submit);
    try std.testing.expect(loop.composer.picker.active);
    try loop.dispatch(.{ .insert = "zzzz-no-match" });
    try std.testing.expect(loop.composer.picker.active);
    try std.testing.expect(loop.composer.picker.topConst().selected_row == null);
    var no_match_frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&no_match_frame, "  no matches");
    try loop.dispatch(.submit);
    try std.testing.expect(loop.composer.picker.active);
    try std.testing.expectEqualStrings("/model zzzz-no-match", loop.composer.editor.text());
    try loop.dispatch(.cancel);
    loop.composer.editor.clear();

    try loop.dispatch(.{ .insert = "/model" });
    try loop.dispatch(.submit);
    try std.testing.expect(loop.composer.picker.active);
    try loop.dispatch(.submit);
    try std.testing.expectEqualStrings(ai.faux.default_model_id, session.agent.state.model.id);
    const global_settings = services.settings_manager.current().global.loaded.value;
    try std.testing.expectEqualStrings(session.agent.state.model.provider, global_settings.default_provider.?);
    try std.testing.expectEqualStrings(session.agent.state.model.id, global_settings.default_model.?);
}

test "loop no-session disables resume and keeps new sessions ephemeral" {
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
    var session = try coding_agent.session_bootstrap.openSession(std.testing.allocator, &services, stamp.date(), .{ .create = .{
        .session_id = "ephemeral-test",
        .timestamp = stamp.timestamp(),
        .persist = false,
    } }, .{});
    defer {
        session.requestShutdown();
        session.deinit();
    }

    var wake: runtime.WakeEvent = .init;
    var loop = try Loop.initTestWithOptions(std.testing.allocator, .{ .persist_new_sessions = false });
    defer loop.deinit();
    loop.services = &services;
    loop.session = &session;
    loop.io = services.io;
    loop.wake = &wake;
    loop.trace_io_ready = true;
    try loop.requestFileIndexRebuild();

    try loop.dispatch(.{ .insert = "/resume" });
    try loop.dispatch(.submit);
    try std.testing.expect(!loop.composer.picker.active);
    try std.testing.expectEqualStrings("", loop.composer.editor.text());
    var frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&frame, "no-session mode: resume is disabled");

    try loop.dispatch(.{ .insert = "/new" });
    try loop.dispatch(.submit);
    try driveForegroundOperationUntilIdle(&loop, 10_000);
    try std.testing.expect(session.store == null);
    try std.testing.expect(!std.mem.eql(u8, session.manager.header.id, "ephemeral-test"));
    try std.testing.expect(!loop.shouldPersistNewSession());

    var sessions = try coding_agent.session_listing.listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });
    defer sessions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), sessions.file_names.len);
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
    var loop = try Loop.initTest(std.testing.allocator, null);
    defer loop.deinit();
    loop.services = &services;
    loop.session = &session;
    loop.io = services.io;
    loop.wake = &wake;
    loop.trace_io_ready = true;
    try loop.requestFileIndexRebuild();

    try loop.dispatch(.{ .insert = "/settings" });
    try loop.dispatch(.submit);
    try std.testing.expect(loop.composer.picker.active);
    try std.testing.expectEqual(PickerKind.settings_root, loop.composer.picker.currentKind());
    try std.testing.expectEqualStrings("/settings ", loop.composer.editor.text());

    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqual(PickerKind.settings_thinking_effort, loop.composer.picker.currentKind());
    try std.testing.expectEqualStrings("/settings thinking:", loop.composer.editor.text());
    var frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&frame, "› off");
    try loop.dispatch(.cancel);
    try std.testing.expectEqual(PickerKind.settings_root, loop.composer.picker.currentKind());
    try std.testing.expectEqualStrings("/settings ", loop.composer.editor.text());

    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqual(PickerKind.settings_thinking_effort, loop.composer.picker.currentKind());
    try loop.dispatch(.{ .insert = "high" });
    frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&frame, "› high");
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expect(!loop.composer.picker.active);
    try std.testing.expectEqualStrings("", loop.composer.editor.text());
    try std.testing.expectEqual(agent_mod.ThinkingLevel.high, session.agent.state.thinking_level);
    const global_settings = services.settings_manager.current().global.loaded.value;
    try std.testing.expectEqualStrings("high", global_settings.default_thinking_level.?);

    try loop.dispatch(.{ .insert = "/settings" });
    try loop.dispatch(.submit);
    try std.testing.expectEqual(PickerKind.settings_root, loop.composer.picker.currentKind());

    try loop.dispatch(.{ .key_editor = .move_down });
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expectEqual(PickerKind.settings_thinking_visibility, loop.composer.picker.currentKind());
    try std.testing.expectEqualStrings("/settings thinking:", loop.composer.editor.text());
    try loop.dispatch(.{ .insert = "shown" });
    frame = try loop.composeFrame(80, 12);
    try expectFrameContains(&frame, "› shown");
    try expectFrameOrder(&frame, "│/settings thinking:shown", "› shown");
    try loop.dispatch(.{ .key_editor = .tab });
    try std.testing.expect(!loop.composer.picker.active);
    try std.testing.expectEqualStrings("", loop.composer.editor.text());
    try std.testing.expect(!session.hide_thinking);
    try std.testing.expect(!loop.layout_state.hide_thinking);
    try std.testing.expectEqual(false, services.settings_manager.current().global.loaded.value.hide_thinking_block.?);
}

const RunTestFixture = struct {
    tmp: std.testing.TmpDir,
    task_runtime: *runtime.Runtime,
    provider: *ai.FauxProvider,
    session: *coding_agent.AgentSession,
    owner_loop: *Loop,
    wake: *runtime.WakeEvent,

    fn init(response_text: []const u8) !RunTestFixture {
        const content = [_]ai.AssistantContent{ai.faux.text(response_text)};
        const response = ai.faux.assistantMessage(&content, .{});
        return initWithResponse(response);
    }

    fn initWithResponse(response: ai.AssistantMessage) !RunTestFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
        errdefer task_runtime.deinit();
        const provider = try std.testing.allocator.create(ai.FauxProvider);
        errdefer std.testing.allocator.destroy(provider);
        provider.* = try ai.FauxProvider.init(std.testing.allocator, .{});
        errdefer provider.deinit();
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
        owner_loop.* = try Loop.initTest(std.testing.allocator, null);
        errdefer owner_loop.deinit();
        _ = try session.agent.subscribe(.{ .context = &owner_loop.transcript, .call_fn = Transcript.applyListener });
        const wake = try std.testing.allocator.create(runtime.WakeEvent);
        errdefer std.testing.allocator.destroy(wake);
        wake.* = .init;
        const fixture: RunTestFixture = .{
            .tmp = tmp,
            .task_runtime = task_runtime,
            .provider = provider,
            .session = session,
            .owner_loop = owner_loop,
            .wake = wake,
        };
        owner_loop.session = session;
        owner_loop.io = session.io;
        owner_loop.wake = wake;
        owner_loop.trace_io_ready = true;
        return fixture;
    }

    fn deinit(self: *RunTestFixture) void {
        self.owner_loop.shutdownAgentRun();
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

fn driveForegroundOperationUntilIdle(owner_loop: *Loop, max_iterations: usize) !void {
    var now_ns = frame_floor_ns;
    for (0..max_iterations) |_| {
        try owner_loop.tick(now_ns);
        if (owner_loop.dirty) owner_loop.markRendered(now_ns, 0);
        if (owner_loop.foreground_operation == .idle) return;
        now_ns +|= frame_floor_ns;
        try runtime.yield();
    }
    return error.ForegroundOperationDidNotSettle;
}

fn driveAgentRunUntilIdle(owner_loop: *Loop, max_iterations: usize) !void {
    var now_ns = frame_floor_ns;
    for (0..max_iterations) |_| {
        try owner_loop.pumpAgentRun(now_ns);
        if (owner_loop.dirty) owner_loop.markRendered(now_ns, 0);
        if (!owner_loop.runBusy()) return;
        now_ns +|= frame_floor_ns;
        try runtime.yield();
    }
    return error.AgentRunDidNotSettle;
}

test "agent run applies agent events in rendered deadline-gated batches" {
    const response = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(response);
    @memset(response, 'x');

    var fixture = try RunTestFixture.init(response);
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "prompt" });
    try fixture.owner_loop.dispatch(.submit);

    var now_ns = frame_floor_ns;
    var observed_gate = false;
    for (0..20_000) |_| {
        const exhaustion_before = fixture.owner_loop.trace.agent_event_budget_exhaustion_count;
        try fixture.owner_loop.pumpAgentRun(now_ns);
        try std.testing.expect(fixture.owner_loop.trace.agent_events_applied_per_iteration_max <= agent_events_per_iteration_max);

        if (fixture.owner_loop.trace.agent_event_budget_exhaustion_count > exhaustion_before) {
            if (!observed_gate) {
                observed_gate = true;
                const events_before = fixture.owner_loop.frame_events_applied;
                const skips_before = fixture.owner_loop.trace.gated_driver_poll_skip_count;
                try fixture.owner_loop.dispatch(.{ .insert = "typed" });
                try fixture.owner_loop.pumpAgentRun(now_ns);
                try std.testing.expectEqual(skips_before + 1, fixture.owner_loop.trace.gated_driver_poll_skip_count);
                try std.testing.expectEqual(events_before + 1, fixture.owner_loop.frame_events_applied);
                try std.testing.expectEqualStrings("typed", fixture.owner_loop.composer.editor.text());

                fixture.owner_loop.markRendered(now_ns, 0);
                try fixture.owner_loop.pumpAgentRun(now_ns + frame_floor_ns - 1);
                try std.testing.expectEqual(skips_before + 2, fixture.owner_loop.trace.gated_driver_poll_skip_count);
                now_ns +|= frame_floor_ns;
                continue;
            }
            fixture.owner_loop.markRendered(now_ns, 0);
        } else if (fixture.owner_loop.dirty) {
            fixture.owner_loop.markRendered(now_ns, 0);
        }

        if (!fixture.owner_loop.runBusy()) break;
        now_ns +|= frame_floor_ns;
        try runtime.yield();
    }

    try std.testing.expect(!fixture.owner_loop.runBusy());
    try std.testing.expect(observed_gate);
    try std.testing.expect(fixture.owner_loop.trace.agent_event_budget_exhaustion_count > 3);
    try std.testing.expectEqual(agent_events_per_iteration_max, fixture.owner_loop.trace.agent_events_applied_per_iteration_max);
    const assistant = fixture.owner_loop.transcript.items.items[1].kind.assistant;
    try std.testing.expectEqualStrings(response, assistant.parts.items[0].text.items);
}

test "agent run streams a faux session into transcript" {
    var fixture = try RunTestFixture.init("# hello\nstreamed markdown");
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "hi" });
    try fixture.owner_loop.dispatch(.submit);
    try driveAgentRunUntilIdle(fixture.owner_loop, 10_000);

    try std.testing.expectEqual(@as(usize, 2), fixture.owner_loop.transcript.items.items.len);
    try std.testing.expect(fixture.owner_loop.transcript.items.items[0].kind == .user);
    try std.testing.expect(fixture.owner_loop.transcript.items.items[1].kind == .assistant);
    const assistant = fixture.owner_loop.transcript.items.items[1].kind.assistant;
    try std.testing.expect(assistant.parts.items.len > 0);
    try std.testing.expectEqualStrings("# hello\nstreamed markdown", assistant.parts.items[0].text.items);
    try std.testing.expect(!fixture.owner_loop.transcript.run_active);
}

test "agent run renders actionable failure notice" {
    const failure: ai.OperationalFailure = .{
        .category = .auth_missing,
        .message = "Missing provider API key",
        .retryable = .no,
        .provider = "openai",
        .model = "gpt-5",
    };
    const response = ai.faux.assistantMessage(&.{}, .{
        .stop_reason = .error_,
        .error_message = "MissingApiKey",
        .operational_failure = failure,
    });
    var fixture = try RunTestFixture.initWithResponse(response);
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "hi" });
    try fixture.owner_loop.dispatch(.submit);
    try driveAgentRunUntilIdle(fixture.owner_loop, 10_000);

    const frame = try fixture.owner_loop.composeFrame(100, 16);
    try expectFrameContains(&frame, "error: MissingApiKey");
    try expectFrameContains(&frame, "Authentication required: Missing provider API key");
    try expectFrameContains(&frame, "source: openai/gpt-5");
    try expectFrameContains(&frame, "Set the provider API key");
}

test "manual compaction failure renders notice" {
    const response = ai.faux.assistantMessage(&.{}, .{
        .stop_reason = .error_,
        .error_message = "summary failed",
    });
    var fixture = try RunTestFixture.initWithResponse(response);
    defer fixture.deinit();
    fixture.session.compaction_settings.keep_recent_tokens = 1;

    const older = try fixture.session.manager.prepareMessageEntry(.{ .user = .{ .content = .{ .string = "aaaaaaaa" }, .timestamp = 0 } }, "2026-07-07T00:00:00Z");
    _ = fixture.session.manager.commitPreparedEntry(older);
    const newer = try fixture.session.manager.prepareMessageEntry(.{ .user = .{ .content = .{ .string = "bbbbbbbb" }, .timestamp = 0 } }, "2026-07-07T00:00:01Z");
    _ = fixture.session.manager.commitPreparedEntry(newer);

    try fixture.owner_loop.dispatch(.{ .insert = "/compact" });
    try fixture.owner_loop.dispatch(.submit);
    try driveAgentRunUntilIdle(fixture.owner_loop, 10_000);

    const frame = try fixture.owner_loop.composeFrame(100, 14);
    try expectFrameContains(&frame, "Compaction failed: CompactionSummaryGenerationFailed");
    try expectFrameContains(&frame, "retry /compact");
}

test "agent run queues steering and dequeue-all restores queued text" {
    var fixture = try RunTestFixture.init("done");
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "first" });
    try fixture.owner_loop.dispatch(.submit);
    try std.testing.expect(fixture.owner_loop.run_state.state == .running);

    try fixture.owner_loop.dispatch(.{ .insert = "steer" });
    try fixture.owner_loop.dispatch(.submit);
    try std.testing.expectEqual(@as(usize, 1), fixture.session.queuedEchoes().len);
    try std.testing.expectEqualStrings("", fixture.owner_loop.composer.editor.text());

    try fixture.owner_loop.dispatch(.dequeue_all);
    try std.testing.expectEqualStrings("steer", fixture.owner_loop.composer.editor.text());
    try std.testing.expectEqual(@as(usize, 0), fixture.session.queuedEchoes().len);
}

test "run cancel does not duplicate aborted notice" {
    var fixture = try RunTestFixture.init("done");
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "first" });
    try fixture.owner_loop.dispatch(.submit);
    try fixture.owner_loop.dispatch(.cancel);
    try driveAgentRunUntilIdle(fixture.owner_loop, 10_000);

    var aborted_assistants: usize = 0;
    var aborted_notices: usize = 0;
    for (fixture.owner_loop.transcript.items.items) |item| switch (item.kind) {
        .assistant => |assistant| {
            if (assistant.stop == .aborted) aborted_assistants += 1;
        },
        .notice => |notice| {
            if (std.mem.eql(u8, notice.text, "aborted")) aborted_notices += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), aborted_assistants);
    try std.testing.expectEqual(@as(usize, 0), aborted_notices);
}

test "run cancel restores queued text into empty editor" {
    var fixture = try RunTestFixture.init("done");
    defer fixture.deinit();

    try fixture.owner_loop.dispatch(.{ .insert = "first" });
    try fixture.owner_loop.dispatch(.submit);
    try fixture.owner_loop.dispatch(.{ .insert = "steer" });
    try fixture.owner_loop.dispatch(.submit);
    try std.testing.expectEqual(@as(usize, 1), fixture.session.queuedEchoes().len);

    try fixture.owner_loop.dispatch(.cancel);
    try std.testing.expectEqualStrings("steer", fixture.owner_loop.composer.editor.text());
    try std.testing.expectEqual(@as(usize, 0), fixture.session.queuedEchoes().len);
}
