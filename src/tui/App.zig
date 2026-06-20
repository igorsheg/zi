//! The single owner of TUI product state. Every mutation flows through
//! `apply(Command) -> ?Effect`; `Effect` is returned data for the frontend
//! adapter, never a second mutation path. No I/O happens here, which keeps
//! the whole product core synchronous and unit-testable.
//!
//! `apply` is total over operational input: oversize pastes, invalid UTF-8,
//! unknown tool ids, and full status slots degrade into transcript notices
//! or no-ops. Only OutOfMemory propagates. Time enters exclusively through
//! `Command.tick` (wall-clock ms) — App never reads a clock.
const std = @import("std");
const Composer = @import("Composer.zig");
const Greeter = @import("Greeter.zig");
const Picker = @import("Picker.zig");
const PromptHistory = @import("PromptHistory.zig");
const Transcript = @import("Transcript.zig");
const input_mod = @import("input.zig");
const notify_mod = @import("notify.zig");
const render = @import("render.zig");
const status_mod = @import("status.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("theme.zig");

const App = @This();

/// Second ctrl+c within this window exits; the first clears the composer.
pub const double_press_window_ms: i64 = 500;
pub const mouse_wheel_scroll_rows: usize = 3;
pub const tail_autoscroll_detach_rows: usize = mouse_wheel_scroll_rows * 2;
const composer_scroll_status_id: status_mod.ContributionId = std.math.maxInt(status_mod.ContributionId);

const ScrollResult = enum { moved, boundary };
const ScrollAttachment = enum { auto, detached };

const TranscriptViewport = struct {
    scroll_rows: usize = 0,
    attachment: ScrollAttachment = .auto,

    fn clear(self: *TranscriptViewport) void {
        self.* = .{};
    }

    fn historyPrepended(self: *TranscriptViewport, max_scroll: usize) void {
        self.scroll_rows = max_scroll;
        self.attachment = .detached;
    }

    fn scrollUp(self: *TranscriptViewport, rows: usize, max_scroll: usize) ScrollResult {
        if (rows == 0 or self.scroll_rows == max_scroll) return .boundary;
        const next = @min(max_scroll, self.scroll_rows + rows);
        if (next == self.scroll_rows) return .boundary;
        self.scroll_rows = next;
        self.updateAttachmentFromDistance();
        return .moved;
    }

    fn scrollDown(self: *TranscriptViewport, rows: usize) bool {
        if (rows == 0) return false;
        const next = self.scroll_rows -| rows;
        if (next == self.scroll_rows) return false;
        self.scroll_rows = next;
        self.updateAttachmentFromDistance();
        return true;
    }

    fn followTail(self: *TranscriptViewport) bool {
        if (self.scroll_rows == 0 and self.attachment == .auto) return false;
        self.scroll_rows = 0;
        self.attachment = .auto;
        return true;
    }

    fn tailMutated(self: *TranscriptViewport, before_max: usize, after_max: usize) void {
        if (self.attachment == .auto or self.scroll_rows <= tail_autoscroll_detach_rows) {
            self.attachment = .auto;
            self.scroll_rows = 0;
            return;
        }
        self.scroll_rows = @min(after_max, self.scroll_rows + (after_max -| before_max));
    }

    fn clampOrFollow(self: *TranscriptViewport, max_scroll: usize) void {
        if (self.attachment == .auto) {
            self.scroll_rows = 0;
        } else {
            self.scroll_rows = @min(self.scroll_rows, max_scroll);
        }
    }

    fn updateAttachmentFromDistance(self: *TranscriptViewport) void {
        self.attachment = if (self.scroll_rows > tail_autoscroll_detach_rows) .detached else .auto;
    }
};

width: u16,
height: u16,
composer: Composer = .{},
prompt_history: PromptHistory = .{},
history_cursor_from_newest: ?usize = null,
history_draft: std.ArrayList(u8) = .empty,
history_draft_cursor_byte_index: usize = 0,
transcript: Transcript = .{},
greeter: ?Greeter = null,
completion: Completion = .{},
status: status_mod.Store = .{},
notify: notify_mod.Store = .{},
viewport: TranscriptViewport = .{},
theme: theme_mod.Theme,
tools_expanded: bool = false,
now_ms: i64 = 0,
last_clear_ms: ?i64 = null,
in_paste: bool = false,
/// Coalesces the composer-full notice: a 17 KB paste arrives as hundreds of
/// rejected inserts and must produce one warning, not hundreds.
composer_full_noticed: bool = false,
dirty: bool = true,

pub fn init(width: u16, height: u16, terminal_info: theme_mod.TerminalInfo) App {
    return .{
        .width = width,
        .height = height,
        .theme = theme_mod.resolve(.codex, terminal_info),
    };
}

pub fn deinit(self: *App, gpa: std.mem.Allocator) void {
    self.history_draft.deinit(gpa);
    self.prompt_history.deinit(gpa);
    self.completion.deinit(gpa);
    self.transcript.deinit(gpa);
    self.composer.deinit(gpa);
    self.* = undefined;
}

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Tick = struct {
    now_ms: i64,
};

pub const ToolOutputDelta = struct {
    tool_call_id: []const u8,
    text: []const u8,
    dropped_head_bytes: usize = 0,
    dropped_head_lines: usize = 0,
};

pub const ToolText = struct {
    tool_call_id: []const u8,
    text: []const u8,
};

pub const SlashArgAccept = enum {
    insert_argument,
    emit_selection,
};

pub const SlashArgCompletionOpen = struct {
    command_name: []const u8,
    picker: Picker.Open,
    accept: SlashArgAccept = .insert_argument,
};

const slash_arg_command_name_bytes_max: usize = 32;
const slash_arg_completion_count_max: usize = 8;

const SlashArgCompletion = struct {
    command_name: [slash_arg_command_name_bytes_max]u8 = undefined,
    command_name_len: u8 = 0,
    accept: SlashArgAccept = .insert_argument,
    picker: Picker,

    fn init(gpa: std.mem.Allocator, open: SlashArgCompletionOpen) error{OutOfMemory}!SlashArgCompletion {
        var self: SlashArgCompletion = .{ .picker = undefined };
        const command_name = text_mod.utf8Prefix(open.command_name, slash_arg_command_name_bytes_max);
        @memcpy(self.command_name[0..command_name.len], command_name);
        self.command_name_len = @intCast(command_name.len);
        self.accept = open.accept;
        self.picker = try Picker.init(gpa, open.picker);
        return self;
    }

    fn deinit(self: *SlashArgCompletion, gpa: std.mem.Allocator) void {
        self.picker.deinit(gpa);
        self.* = undefined;
    }

    fn commandName(self: *const SlashArgCompletion) []const u8 {
        return self.command_name[0..self.command_name_len];
    }
};

/// Single owner for popup/listbox state. It stores candidate lists installed
/// by the frontend, but exposes at most one visible picker at a time:
/// modal > slash-arg completion > command completion. The composer remains
/// text focus for non-modal completions.
const Completion = struct {
    modal: ?Picker = null,
    command: ?Picker = null,
    slash_args: [slash_arg_completion_count_max]?SlashArgCompletion = @splat(null),
    hidden_until_edit: bool = false,

    fn deinit(self: *Completion, gpa: std.mem.Allocator) void {
        if (self.modal) |*picker| picker.deinit(gpa);
        if (self.command) |*picker| picker.deinit(gpa);
        self.clearSlashArgSlots(gpa);
        self.* = undefined;
    }

    fn setModal(self: *Completion, gpa: std.mem.Allocator, open: Picker.Open) error{OutOfMemory}!void {
        var next = try Picker.init(gpa, open);
        errdefer next.deinit(gpa);
        if (self.modal) |*picker| picker.deinit(gpa);
        self.modal = next;
    }

    fn closeModal(self: *Completion, gpa: std.mem.Allocator) bool {
        if (self.modal) |*picker| {
            picker.deinit(gpa);
            self.modal = null;
            return true;
        }
        return false;
    }

    fn setCommand(self: *Completion, gpa: std.mem.Allocator, open: Picker.Open) error{OutOfMemory}!void {
        var next = try Picker.init(gpa, open);
        errdefer next.deinit(gpa);
        if (self.command) |*picker| picker.deinit(gpa);
        self.command = next;
    }

    fn setSlashArg(
        self: *Completion,
        gpa: std.mem.Allocator,
        open: SlashArgCompletionOpen,
    ) error{OutOfMemory}!void {
        var next = try SlashArgCompletion.init(gpa, open);
        errdefer next.deinit(gpa);
        // Frontend-installed hints are bounded; if full, newest replaces slot 0.
        const slot = self.slashArgSlot(open.command_name) orelse self.emptySlashArgSlot() orelse &self.slash_args[0];
        if (slot.*) |*completion| completion.deinit(gpa);
        slot.* = next;
    }

    fn clearSlashArgSlots(self: *Completion, gpa: std.mem.Allocator) void {
        for (&self.slash_args) |*slot| {
            if (slot.*) |*completion| completion.deinit(gpa);
            slot.* = null;
        }
    }

    fn slashArgSlot(self: *Completion, raw_command_name: []const u8) ?*?SlashArgCompletion {
        const command_name = text_mod.utf8Prefix(raw_command_name, slash_arg_command_name_bytes_max);
        for (&self.slash_args) |*slot| {
            const completion = if (slot.*) |*value| value else continue;
            if (std.ascii.eqlIgnoreCase(completion.commandName(), command_name)) return slot;
        }
        return null;
    }

    fn emptySlashArgSlot(self: *Completion) ?*?SlashArgCompletion {
        for (&self.slash_args) |*slot| if (slot.* == null) return slot;
        return null;
    }

    fn hideUntilEdit(self: *Completion) void {
        self.hidden_until_edit = true;
    }

    fn noteEdit(self: *Completion) void {
        self.hidden_until_edit = false;
    }

    fn sync(self: *Completion, app: *const App) void {
        if (self.command) |*picker| {
            if (app.composerCompletionQuery()) |query| picker.replaceQuery(query);
        }
        for (&self.slash_args) |*slot| {
            const completion = if (slot.*) |*value| value else continue;
            if (app.composerArgQuery(completion.commandName())) |query| {
                completion.picker.replaceQuery(query.text);
            }
        }
    }

    fn visiblePicker(self: *Completion, app: *const App) ?*Picker {
        if (self.modal) |*picker| return picker;
        if (self.activeSlashArg(app)) |completion| return &completion.picker;
        if (self.activeCommand(app)) |picker| return picker;
        return null;
    }

    fn activeCommand(self: *Completion, app: *const App) ?*Picker {
        if (self.hidden_until_edit) return null;
        if (self.modal != null or self.activeSlashArg(app) != null) return null;
        if (self.command == null or app.composerCompletionQuery() == null) return null;
        return &self.command.?;
    }

    fn activeSlashArg(self: *Completion, app: *const App) ?*SlashArgCompletion {
        if (self.hidden_until_edit or self.modal != null) return null;
        for (&self.slash_args) |*slot| {
            const completion = if (slot.*) |*value| value else continue;
            if (app.composerArgQuery(completion.commandName()) != null) return completion;
        }
        return null;
    }
};

pub const Command = union(enum) {
    resize: Size,
    input: input_mod.Input,
    tick: Tick,
    clear_transcript,
    append_transcript: Transcript.Append,
    tool_output_delta: ToolOutputDelta,
    front_tool_output_delta: ToolOutputDelta,
    replace_tool_output: ToolText,
    replace_front_tool_output: ToolText,
    replace_tool_footer: ToolText,
    replace_front_tool_footer: ToolText,
    mark_pending_tools_canceled,
    prepend_transcript: Transcript.Prepend,
    set_greeter: Greeter.Set,
    open_picker: Picker.Open,
    close_picker,
    set_composer_completions: Picker.Open,
    set_composer_arg_completions: SlashArgCompletionOpen,
    replace_composer_text: []const u8,
    set_status: status_mod.Set,
    clear_status: status_mod.Clear,
    notify: notify_mod.Notify,
    clear_notify: notify_mod.Clear,
};

pub const Effect = union(enum) {
    submit_text: []u8,
    edit_composer_external: []u8,
    picker_selected: Picker.Selection,
    interrupt,
    request_shutdown,
    request_transcript_history,

    pub fn deinit(self: Effect, gpa: std.mem.Allocator) void {
        switch (self) {
            .submit_text, .edit_composer_external => |text| gpa.free(text),
            .picker_selected => |selection| gpa.free(selection.item_id),
            .interrupt, .request_shutdown, .request_transcript_history => {},
        }
    }
};

pub fn apply(self: *App, gpa: std.mem.Allocator, command: Command) error{OutOfMemory}!?Effect {
    switch (command) {
        .resize => |size| {
            if (self.width != size.width or self.height != size.height) {
                self.width = size.width;
                self.height = size.height;
                self.clampOrFollowViewport();
                self.syncComposerScrollHint();
                self.dirty = true;
            }
            return null;
        },
        .input => |event| return self.applyInput(gpa, event),
        .tick => |tick| {
            if (tick.now_ms != self.now_ms) {
                self.now_ms = tick.now_ms;
                const expired = self.notify.tick(self.now_ms);
                if (expired or self.statusHasAnimated()) self.dirty = true;
            }
            return null;
        },
        .clear_transcript => {
            self.transcript.clear(gpa);
            self.viewport.clear();
            self.dirty = true;
            return null;
        },
        .append_transcript => |entry| {
            const before_max = render.transcriptScrollMax(self);
            const outcome = try self.transcript.append(gpa, entry);
            self.noteOutcome(gpa, outcome);
            self.applyTailMutationScroll(before_max);
            self.dirty = true;
            return null;
        },
        .tool_output_delta => |delta| {
            const before_max = render.transcriptScrollMax(self);
            const outcome = try self.transcript.appendToolOutput(
                gpa,
                delta.tool_call_id,
                delta.text,
                delta.dropped_head_bytes,
                delta.dropped_head_lines,
            );
            self.noteOutcome(gpa, outcome);
            self.applyTailMutationScroll(before_max);
            self.dirty = true;
            return null;
        },
        .front_tool_output_delta => |delta| {
            const outcome = try self.transcript.appendFrontToolOutput(
                gpa,
                delta.tool_call_id,
                delta.text,
                delta.dropped_head_bytes,
                delta.dropped_head_lines,
            );
            self.noteOutcome(gpa, outcome);
            self.viewport.historyPrepended(render.transcriptScrollMax(self));
            self.dirty = true;
            return null;
        },
        .replace_tool_output => |replace| {
            const before_max = render.transcriptScrollMax(self);
            const outcome = try self.transcript.replaceToolOutput(gpa, replace.tool_call_id, replace.text);
            self.noteOutcome(gpa, outcome);
            self.applyTailMutationScroll(before_max);
            self.dirty = true;
            return null;
        },
        .replace_front_tool_output => |replace| {
            const outcome = try self.transcript.replaceFrontToolOutput(gpa, replace.tool_call_id, replace.text);
            self.noteOutcome(gpa, outcome);
            self.viewport.historyPrepended(render.transcriptScrollMax(self));
            self.dirty = true;
            return null;
        },
        .replace_tool_footer => |footer| {
            const before_max = render.transcriptScrollMax(self);
            const outcome = try self.transcript.replaceToolFooter(gpa, footer.tool_call_id, footer.text);
            self.noteOutcome(gpa, outcome);
            self.applyTailMutationScroll(before_max);
            self.dirty = true;
            return null;
        },
        .replace_front_tool_footer => |footer| {
            const outcome = try self.transcript.replaceFrontToolFooter(gpa, footer.tool_call_id, footer.text);
            self.noteOutcome(gpa, outcome);
            self.viewport.historyPrepended(render.transcriptScrollMax(self));
            self.dirty = true;
            return null;
        },
        .mark_pending_tools_canceled => {
            const before_max = render.transcriptScrollMax(self);
            if (self.transcript.markPendingToolsCanceled()) {
                self.applyTailMutationScroll(before_max);
                self.dirty = true;
            }
            return null;
        },
        .prepend_transcript => |rows| {
            const outcome = try self.transcript.prepend(gpa, rows);
            self.noteOutcome(gpa, outcome);
            self.viewport.historyPrepended(render.transcriptScrollMax(self));
            self.dirty = true;
            return null;
        },
        .set_greeter => |greeter| {
            self.greeter = Greeter.from(greeter);
            self.clampOrFollowViewport();
            self.dirty = true;
            return null;
        },
        .open_picker => |open| {
            try self.completion.setModal(gpa, open);
            self.dirty = true;
            return null;
        },
        .close_picker => {
            if (self.completion.closeModal(gpa)) self.dirty = true;
            return null;
        },
        .set_composer_completions => |open| {
            try self.completion.setCommand(gpa, open);
            self.syncComposerCompletion();
            self.dirty = true;
            return null;
        },
        .set_composer_arg_completions => |open| {
            try self.completion.setSlashArg(gpa, open);
            self.syncComposerCompletion();
            self.dirty = true;
            return null;
        },
        .replace_composer_text => |text| {
            var clean_buffer: [Composer.buffer_size_bytes_max]u8 = undefined;
            const bounded = if (std.unicode.utf8ValidateSlice(text))
                text_mod.utf8Prefix(text, Composer.buffer_size_bytes_max)
            else
                text_mod.sanitizeInto(&clean_buffer, text);
            try self.composer.replaceText(gpa, bounded);
            self.resetHistoryNavigation();
            self.completion.noteEdit();
            self.syncComposerCompletion();
            self.syncComposerScrollHint();
            self.dirty = true;
            return null;
        },
        .set_status => |update| {
            if (self.status.set(update, self.now_ms) == .dropped_full) {
                try self.notice(gpa, .warning, "status line full");
            }
            self.dirty = true;
            return null;
        },
        .clear_status => |request| {
            if (self.status.clear(request)) self.dirty = true;
            return null;
        },
        .notify => |update| {
            switch (self.notify.notify(update, self.now_ms)) {
                .ok => self.dirty = true,
                .dropped_full => try self.notice(gpa, .warning, "notifications full"),
                .update_only_miss => {},
            }
            return null;
        },
        .clear_notify => |request| {
            if (self.notify.clear(request)) self.dirty = true;
            return null;
        },
    }
}

fn applyInput(self: *App, gpa: std.mem.Allocator, event: input_mod.Input) error{OutOfMemory}!?Effect {
    switch (event) {
        .paste_begin => {
            self.in_paste = true;
            return null;
        },
        .paste_end => {
            self.in_paste = false;
            return null;
        },
        else => {},
    }
    if (self.completion.modal != null) return self.applyPickerInput(gpa, event);
    const completion_result = try self.applyCompletionInput(gpa, event);
    if (completion_result.consumed) return completion_result.effect;

    // Bracketed-paste content arrives as ordinary key events between the
    // markers. Enter inside a paste is data, not a submit.
    if (self.in_paste) {
        switch (event) {
            .text => |bytes| return self.composerInsert(gpa, bytes.slice()),
            .key => |key| switch (key) {
                .enter, .newline => return self.composerInsert(gpa, "\n"),
                .tab => return self.composerInsert(gpa, "\t"),
                else => return null,
            },
            else => return null,
        }
    }

    switch (input_mod.resolve(event)) {
        .composer_insert => |bytes| return self.composerInsert(gpa, bytes.slice()),
        .composer_newline => return self.composerInsert(gpa, "\n"),
        .composer_backspace => self.composerTextEdit(Composer.backspace),
        .composer_delete_forward => self.composerTextEdit(Composer.deleteForward),
        .composer_left => self.composerCursorEdit(Composer.moveLeft),
        .composer_right => self.composerCursorEdit(Composer.moveRight),
        .composer_up => try self.composerUpOrHistory(gpa),
        .composer_down => try self.composerDownOrHistory(gpa),
        .composer_start => self.composerCursorEdit(Composer.moveStart),
        .composer_end => self.composerCursorEdit(Composer.moveEnd),
        .composer_submit => {
            if (try self.composerSubmit(gpa)) |effect| return effect;
        },
        .transcript_page_up => if (self.scrollUp(render.transcriptVisibleRows(self)) == .boundary) {
            return .request_transcript_history;
        },
        .transcript_page_down => self.scrollDown(render.transcriptVisibleRows(self)),
        .transcript_scroll_up => if (self.scrollUp(mouse_wheel_scroll_rows) == .boundary) {
            return .request_transcript_history;
        },
        .transcript_scroll_down => self.scrollDown(mouse_wheel_scroll_rows),
        .transcript_follow_tail => self.followTail(),
        .toggle_tool_expansion => {
            self.tools_expanded = !self.tools_expanded;
            self.clampOrFollowViewport();
            self.dirty = true;
        },
        .interrupt => return .interrupt,
        .clear_or_exit => return self.clearOrExit(),
        .exit_if_composer_empty => if (self.composer.text().len == 0) return .request_shutdown,
        .open_external_editor => return try self.openExternalEditor(gpa),
        .none => {},
    }
    return null;
}

const CompletionInputResult = struct {
    consumed: bool = false,
    effect: ?Effect = null,
};

/// Composer completions follow combobox semantics: the composer keeps text
/// focus, printable input edits the composer, and only navigation/acceptance
/// keys act on the popup listbox.
fn applyCompletionInput(
    self: *App,
    gpa: std.mem.Allocator,
    event: input_mod.Input,
) error{OutOfMemory}!CompletionInputResult {
    const completion_picker = self.visiblePicker() orelse return .{};
    switch (event) {
        .key => |key| switch (key) {
            .enter => {
                if (self.composerCompletionQueryMatchesSelected()) return .{};
                const effect = try self.acceptComposerCompletion(gpa);
                if (effect == null and self.completionHasNoSelection()) return .{};
                return .{ .consumed = true, .effect = effect };
            },
            .escape => {
                self.completion.hideUntilEdit();
                self.dirty = true;
                return .{ .consumed = true };
            },
            .tab => return .{ .consumed = true, .effect = try self.acceptComposerCompletion(gpa) },
            .arrow_up => {
                _ = try completion_picker.applyInput(gpa, .{ .key = .arrow_up });
                self.dirty = true;
                return .{ .consumed = true };
            },
            .arrow_down => {
                _ = try completion_picker.applyInput(gpa, .{ .key = .arrow_down });
                self.dirty = true;
                return .{ .consumed = true };
            },
            else => return .{},
        },
        .wheel_up => {
            _ = try completion_picker.applyInput(gpa, .wheel_up);
            self.dirty = true;
            return .{ .consumed = true };
        },
        .wheel_down => {
            _ = try completion_picker.applyInput(gpa, .wheel_down);
            self.dirty = true;
            return .{ .consumed = true };
        },
        else => return .{},
    }
}

fn applyPickerInput(self: *App, gpa: std.mem.Allocator, event: input_mod.Input) error{OutOfMemory}!?Effect {
    if (self.in_paste) {
        switch (event) {
            .text => {},
            .key => |key| switch (key) {
                .enter, .newline, .tab => {
                    const as_text = input_mod.InlineBytes.from(" ");
                    return self.applyPickerInput(gpa, .{ .text = as_text });
                },
                else => return null,
            },
            else => return null,
        }
    }

    const modal = if (self.completion.modal) |*picker| picker else return null;
    const result = try modal.applyInput(gpa, event);
    self.dirty = true;
    switch (result) {
        .none => return null,
        .closed => {
            _ = self.completion.closeModal(gpa);
            return null;
        },
        .selected => |selection| {
            _ = self.completion.closeModal(gpa);
            return .{ .picker_selected = selection };
        },
    }
}

fn composerInsert(self: *App, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?Effect {
    // Key text is operational input; sanitize so Composer's valid-UTF-8
    // contract holds even against a terminal that emits garbage. Worst case
    // every byte becomes a 3-byte replacement char.
    var clean_buffer: [input_mod.inline_text_bytes_max * 3]u8 = undefined;
    const clean = if (std.unicode.utf8ValidateSlice(bytes))
        bytes
    else
        text_mod.sanitizeInto(&clean_buffer, bytes);
    switch (try self.composer.insert(gpa, clean)) {
        .ok, .inserted_truncated => |result| {
            if (clean.len > 0) self.noteGreeterCharacterInput();
            self.resetHistoryNavigation();
            self.completion.noteEdit();
            self.syncComposerCompletion();
            self.syncComposerScrollHint();
            self.composer_full_noticed = false;
            self.dirty = true;
            if (result == .inserted_truncated) try self.noticeComposerFull(gpa);
        },
        .rejected_full => try self.noticeComposerFull(gpa),
    }
    return null;
}

fn noticeComposerFull(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    if (self.composer_full_noticed) return;
    self.composer_full_noticed = true;
    try self.notice(gpa, .warning, "input too large: composer is full, extra input dropped");
}

fn openExternalEditor(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!Effect {
    return .{ .edit_composer_external = try gpa.dupe(u8, self.composer.text()) };
}

fn noteGreeterCharacterInput(self: *App) void {
    if (self.greeter) |greeter| {
        if (greeter.auto_hide_on_first_input) {
            self.greeter = null;
            self.clampOrFollowViewport();
        }
    }
}

fn composerSubmit(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!?Effect {
    const text = self.composer.submitSlice() orelse {
        if (self.composer.text().len != 0) self.composer.clear();
        self.resetHistoryNavigation();
        self.completion.noteEdit();
        self.syncComposerScrollHint();
        self.dirty = true;
        return null;
    };

    const submitted = try gpa.dupe(u8, text);
    errdefer gpa.free(submitted);
    try self.prompt_history.record(gpa, text);

    self.composer.clear();
    self.resetHistoryNavigation();
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.composer_full_noticed = false;
    self.dirty = true;
    return .{ .submit_text = submitted };
}

fn composerTextEdit(self: *App, comptime edit: fn (*Composer) void) void {
    edit(&self.composer);
    self.resetHistoryNavigation();
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.dirty = true;
}

fn composerCursorEdit(self: *App, comptime edit: fn (*Composer) void) void {
    edit(&self.composer);
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.dirty = true;
}

fn composerUpOrHistory(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    if (self.composer.text().len != 0 and
        self.composer.moveVertical(render.composerTextWidth(self.width), .up) == .moved)
    {
        self.syncComposerScrollHint();
        self.dirty = true;
        return;
    }
    try self.historyPrevious(gpa);
}

fn composerDownOrHistory(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    if (self.composer.text().len != 0 and
        self.composer.moveVertical(render.composerTextWidth(self.width), .down) == .moved)
    {
        self.syncComposerScrollHint();
        self.dirty = true;
        return;
    }
    try self.historyNext(gpa);
}

fn historyPrevious(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    if (self.prompt_history.len() == 0) return;

    const next_offset = if (self.history_cursor_from_newest) |offset| blk: {
        if (offset + 1 >= self.prompt_history.len()) return;
        break :blk offset + 1;
    } else blk: {
        try self.saveHistoryDraft(gpa);
        break :blk 0;
    };

    const text = self.prompt_history.getFromNewest(next_offset).?;
    try self.composer.replaceText(gpa, text);
    self.history_cursor_from_newest = next_offset;
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.composer_full_noticed = false;
    self.dirty = true;
}

fn historyNext(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    const offset = self.history_cursor_from_newest orelse return;
    if (offset == 0) {
        try self.composer.replaceTextAtCursor(
            gpa,
            self.history_draft.items,
            self.history_draft_cursor_byte_index,
        );
        self.resetHistoryNavigation();
    } else {
        const next_offset = offset - 1;
        const text = self.prompt_history.getFromNewest(next_offset).?;
        try self.composer.replaceText(gpa, text);
        self.history_cursor_from_newest = next_offset;
    }
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.composer_full_noticed = false;
    self.dirty = true;
}

fn saveHistoryDraft(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    try self.history_draft.ensureTotalCapacity(gpa, self.composer.text().len);
    self.history_draft.clearRetainingCapacity();
    self.history_draft.appendSliceAssumeCapacity(self.composer.text());
    self.history_draft_cursor_byte_index = self.composer.cursor_byte_index;
}

fn resetHistoryNavigation(self: *App) void {
    self.history_cursor_from_newest = null;
    self.history_draft.clearRetainingCapacity();
    self.history_draft_cursor_byte_index = 0;
}

pub fn visiblePicker(self: *App) ?*Picker {
    return self.completion.visiblePicker(self);
}

pub fn visiblePickerFocusesFilter(self: *const App) bool {
    return self.completion.modal != null;
}

fn composerCompletionVisible(self: *App) bool {
    return self.visiblePicker() != null;
}

fn syncComposerCompletion(self: *App) void {
    self.completion.sync(self);
}

fn syncComposerScrollHint(self: *App) void {
    var rows: [Composer.visible_rows_max]Composer.VisualRow = undefined;
    const projection = self.composer.visibleRows(render.composerTextWidth(self.width), &rows);
    const hidden_above = projection.first_visible_row;
    const hidden_below = projection.total_rows -| (projection.first_visible_row + projection.visible_count);

    _ = self.status.clear(.{ .slot = .composer_bottom_right, .id = composer_scroll_status_id });
    if (hidden_above == 0 and hidden_below == 0) {
        _ = self.status.clear(.{ .slot = .composer_bottom_left, .id = composer_scroll_status_id });
        return;
    }

    var buffer: [64]u8 = undefined;
    const text = if (hidden_above > 0 and hidden_below > 0)
        std.fmt.bufPrint(&buffer, "↑ {} more · ↓ {} more", .{ hidden_above, hidden_below }) catch return
    else if (hidden_above > 0)
        std.fmt.bufPrint(&buffer, "↑ {} more", .{hidden_above}) catch return
    else
        std.fmt.bufPrint(&buffer, "↓ {} more", .{hidden_below}) catch return;
    _ = self.status.set(.{
        .slot = .composer_bottom_left,
        .id = composer_scroll_status_id,
        .priority = -1000,
        .text = text,
    }, self.now_ms);
}

fn statusHasAnimated(self: *const App) bool {
    if (self.notify.hasAnimated(self.now_ms)) return true;
    const slots = [_]status_mod.Slot{
        .composer_left,
        .composer_right,
        .composer_bottom_left,
        .composer_bottom_right,
        .status_line,
    };
    for (slots) |slot| {
        if (self.status.hasAnimated(slot, self.now_ms)) return true;
    }
    return false;
}

fn completionHasNoSelection(self: *App) bool {
    const completion_picker = self.visiblePicker() orelse return false;
    return completion_picker.selectedIndex() == null;
}

fn composerCompletionQueryMatchesSelected(self: *App) bool {
    if (self.activeComposerArgCompletion()) |completion| {
        if (completion.accept != .insert_argument) return false;
        const query = self.composerArgQuery(completion.commandName()) orelse return false;
        const index = completion.picker.selectedIndex() orelse return false;
        const item = completion.picker.itemAt(index);
        return std.ascii.eqlIgnoreCase(item.idSlice(), query.text);
    }
    const completion = self.activeCommandCompletion() orelse return false;
    const query = self.composerCompletionQuery() orelse return false;
    const index = completion.selectedIndex() orelse return false;
    const item = completion.itemAt(index);
    return std.ascii.eqlIgnoreCase(item.idSlice(), query);
}

fn activeCommandCompletion(self: *App) ?*Picker {
    return self.completion.activeCommand(self);
}

fn activeComposerArgCompletion(self: *App) ?*SlashArgCompletion {
    return self.completion.activeSlashArg(self);
}

fn composerCompletionQuery(self: *const App) ?[]const u8 {
    const text = self.composer.text();
    if (text.len == 0 or text[0] != '/') return null;
    const cursor = self.composer.cursor_byte_index;
    if (cursor == 0) return null;
    var end: usize = 1;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
    if (cursor > end) return null;
    return text[1..cursor];
}

const ComposerArgQuery = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

fn composerArgQuery(self: *const App, command_name: []const u8) ?ComposerArgQuery {
    const text = self.composer.text();
    if (text.len < command_name.len + 2 or text[0] != '/') return null;
    var command_end: usize = 1;
    while (command_end < text.len and !std.ascii.isWhitespace(text[command_end])) command_end += 1;
    if (!std.ascii.eqlIgnoreCase(text[1..command_end], command_name)) return null;
    var arg_start = command_end;
    while (arg_start < text.len and std.ascii.isWhitespace(text[arg_start])) arg_start += 1;
    const cursor = self.composer.cursor_byte_index;
    if (cursor < arg_start) return null;
    return .{ .start = arg_start, .end = cursor, .text = text[arg_start..cursor] };
}

fn acceptComposerCompletion(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!?Effect {
    if (self.activeComposerArgCompletion()) |completion| {
        return switch (completion.accept) {
            .insert_argument => blk: {
                try self.acceptComposerArgCompletion(gpa, completion);
                break :blk null;
            },
            .emit_selection => try self.selectComposerArgCompletion(gpa, completion),
        };
    }
    const completion = self.activeCommandCompletion() orelse return null;
    const index = completion.selectedIndex() orelse return null;
    const item = completion.itemAt(index);
    var replacement: [1 + Picker.id_bytes_max + 1]u8 = undefined;
    replacement[0] = '/';
    const id = item.idSlice();
    @memcpy(replacement[1..][0..id.len], id);
    replacement[1 + id.len] = ' ';
    try self.composer.replaceText(gpa, replacement[0 .. 1 + id.len + 1]);
    self.resetHistoryNavigation();
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.composer_full_noticed = false;
    self.dirty = true;
    return null;
}

fn acceptComposerArgCompletion(
    self: *App,
    gpa: std.mem.Allocator,
    completion: *SlashArgCompletion,
) error{OutOfMemory}!void {
    const query = self.composerArgQuery(completion.commandName()) orelse return;
    const index = completion.picker.selectedIndex() orelse return;
    const item = completion.picker.itemAt(index);
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(gpa);
    const text = self.composer.text();
    try next.ensureTotalCapacity(gpa, text.len - (query.end - query.start) + item.idSlice().len);
    next.appendSliceAssumeCapacity(text[0..query.start]);
    next.appendSliceAssumeCapacity(item.idSlice());
    next.appendSliceAssumeCapacity(text[query.end..]);
    try self.composer.replaceTextAtCursor(gpa, next.items, query.start + item.idSlice().len);
    self.resetHistoryNavigation();
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.composer_full_noticed = false;
    self.dirty = true;
}

fn selectComposerArgCompletion(
    self: *App,
    gpa: std.mem.Allocator,
    completion: *SlashArgCompletion,
) error{OutOfMemory}!?Effect {
    const index = completion.picker.selectedIndex() orelse return null;
    const item = completion.picker.itemAt(index);
    const item_id = try gpa.dupe(u8, item.idSlice());
    self.composer.clear();
    self.resetHistoryNavigation();
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.composer_full_noticed = false;
    self.dirty = true;
    return .{ .picker_selected = .{ .picker_id = completion.picker.id, .item_id = item_id } };
}

fn clearOrExit(self: *App) ?Effect {
    if (self.last_clear_ms) |last_ms| {
        if (self.now_ms >= last_ms and self.now_ms - last_ms <= double_press_window_ms) {
            return .request_shutdown;
        }
    }
    self.composer.clear();
    self.resetHistoryNavigation();
    self.completion.noteEdit();
    self.syncComposerCompletion();
    self.syncComposerScrollHint();
    self.composer_full_noticed = false;
    self.last_clear_ms = self.now_ms;
    self.dirty = true;
    return null;
}

fn scrollUp(self: *App, rows: usize) ScrollResult {
    const result = self.viewport.scrollUp(rows, render.transcriptScrollMax(self));
    if (result == .moved) self.dirty = true;
    return result;
}

fn scrollDown(self: *App, rows: usize) void {
    if (self.viewport.scrollDown(rows)) self.dirty = true;
}

fn followTail(self: *App) void {
    if (self.viewport.followTail()) self.dirty = true;
}

/// Tail mutations are append/replace operations at the live end of the
/// transcript. When auto-attached, they pin to the tail. When detached, they
/// add any new bottom distance to `scroll_rows` so the user's viewport does
/// not drift while an agent streams below it.
fn applyTailMutationScroll(self: *App, before_max: usize) void {
    self.viewport.tailMutated(before_max, render.transcriptScrollMax(self));
}

fn clampOrFollowViewport(self: *App) void {
    self.viewport.clampOrFollow(render.transcriptScrollMax(self));
}

fn noteOutcome(self: *App, gpa: std.mem.Allocator, outcome: Transcript.Outcome) void {
    if (!outcome.truncated) return;
    self.appendNotice(gpa, .warning, "transcript append truncated") catch return;
}

fn appendNotice(
    self: *App,
    gpa: std.mem.Allocator,
    level: Transcript.StatusLevel,
    text: []const u8,
) error{OutOfMemory}!void {
    _ = try self.transcript.append(gpa, .{ .status = .{ .level = level, .text = text } });
    self.dirty = true;
}

/// Internal degradation notices share the transcript status vocabulary so
/// policy failures are visible to the user instead of silently dropped.
fn notice(self: *App, gpa: std.mem.Allocator, level: Transcript.StatusLevel, text: []const u8) error{OutOfMemory}!void {
    const before_max = render.transcriptScrollMax(self);
    try self.appendNotice(gpa, level, text);
    self.applyTailMutationScroll(before_max);
    self.dirty = true;
}

pub fn hasAnimation(self: *const App) bool {
    return self.status.hasAnimated(.status_line, self.now_ms) or self.notify.hasAnimated(self.now_ms);
}

pub fn nextDeadlineMs(self: *const App) ?i64 {
    return self.notify.nextDeadlineMs(self.now_ms);
}

test "submit returns owned text and clears the composer" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("hello") } });
    const effect = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(gpa);
    try std.testing.expectEqualStrings("hello", effect.submit_text);
    try std.testing.expectEqual(@as(usize, 0), app.composer.text().len);
}

test "arrow history recall preserves the current draft" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("first") } });
    const submitted = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    submitted.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("draft") } });
    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_left } });
    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_left } });
    const draft_cursor = app.composer.cursor_byte_index;

    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_up } });
    try std.testing.expectEqualStrings("first", app.composer.text());

    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_down } });
    try std.testing.expectEqualStrings("draft", app.composer.text());
    try std.testing.expectEqual(draft_cursor, app.composer.cursor_byte_index);
}

test "arrow up moves within wrapped composer before recalling history" {
    const gpa = std.testing.allocator;
    var app = App.init(5, 24, .{}); // composer text width is 3.
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("previous") } });
    const submitted = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    submitted.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("abcdef") } });
    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_up } });
    try std.testing.expectEqualStrings("abcdef", app.composer.text());
    try std.testing.expectEqual(@as(usize, 3), app.composer.cursor_byte_index);

    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_up } });
    try std.testing.expectEqualStrings("previous", app.composer.text());
}

test "mouse wheel scrolls the resident transcript and clamps" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "one\ntwo\nthree\nfour\nfive\nsix",
    } } });
    const max_scroll = render.transcriptScrollMax(&app);
    try std.testing.expect(max_scroll > 0);

    _ = try app.apply(gpa, .{ .input = .wheel_up });
    try std.testing.expectEqual(@min(max_scroll, mouse_wheel_scroll_rows), app.viewport.scroll_rows);

    app.viewport.scroll_rows = max_scroll;
    const boundary = try app.apply(gpa, .{ .input = .wheel_up });
    try std.testing.expect(boundary.? == .request_transcript_history);

    _ = try app.apply(gpa, .{ .input = .wheel_down });
    try std.testing.expectEqual(max_scroll -| mouse_wheel_scroll_rows, app.viewport.scroll_rows);

    app.viewport.scroll_rows = 0;
    _ = try app.apply(gpa, .{ .input = .wheel_down });
    try std.testing.expectEqual(@as(usize, 0), app.viewport.scroll_rows);
}

test "scrolling without overflow keeps sticky tail attached" {
    const gpa = std.testing.allocator;
    var app = App.init(40, 12, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "short",
    } } });
    const effect = try app.apply(gpa, .{ .input = .wheel_up });
    try std.testing.expect(effect.? == .request_transcript_history);
    try std.testing.expectEqual(@as(usize, 0), app.viewport.scroll_rows);
    try std.testing.expectEqual(ScrollAttachment.auto, app.viewport.attachment);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "tail",
    } } });
    try std.testing.expectEqual(@as(usize, 0), app.viewport.scroll_rows);
    try std.testing.expectEqual(ScrollAttachment.auto, app.viewport.attachment);
}

test "greeter hides on first typed character by default" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .set_greeter = .{ .title = "zi" } });
    try std.testing.expect(app.greeter != null);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("h") } });
    try std.testing.expect(app.greeter == null);
    try std.testing.expectEqualStrings("h", app.composer.text());
}

test "greeter can opt out of first character auto hide" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .set_greeter = .{
        .title = "zi",
        .auto_hide_on_first_input = false,
    } });
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("h") } });

    try std.testing.expect(app.greeter != null);
    try std.testing.expectEqualStrings("h", app.composer.text());
}

test "tail appends stick to bottom while near tail" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "one\ntwo\nthree\nfour\nfive\nsix",
    } } });
    _ = try app.apply(gpa, .{ .input = .wheel_up });
    try std.testing.expect(app.viewport.scroll_rows > 0);
    try std.testing.expect(app.viewport.scroll_rows <= tail_autoscroll_detach_rows);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "tail",
    } } });
    try std.testing.expectEqual(@as(usize, 0), app.viewport.scroll_rows);
}

test "detached scrolling preserves viewport distance while tail grows" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten",
    } } });
    while (app.viewport.scroll_rows <= tail_autoscroll_detach_rows) {
        _ = try app.apply(gpa, .{ .input = .wheel_up });
    }
    const before_scroll = app.viewport.scroll_rows;
    const before_max = render.transcriptScrollMax(&app);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "tail",
    } } });
    const after_max = render.transcriptScrollMax(&app);
    try std.testing.expect(after_max > before_max);
    try std.testing.expectEqual(@min(after_max, before_scroll + (after_max - before_max)), app.viewport.scroll_rows);
}

test "scrolling back near the tail reattaches on next tail append" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten",
    } } });
    while (app.viewport.scroll_rows <= tail_autoscroll_detach_rows) {
        _ = try app.apply(gpa, .{ .input = .wheel_up });
    }
    while (app.viewport.scroll_rows > tail_autoscroll_detach_rows) {
        _ = try app.apply(gpa, .{ .input = .wheel_down });
    }

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "tail",
    } } });
    try std.testing.expectEqual(@as(usize, 0), app.viewport.scroll_rows);
}

test "ctrl end follows the transcript tail immediately" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten",
    } } });
    while (app.viewport.scroll_rows <= tail_autoscroll_detach_rows) {
        _ = try app.apply(gpa, .{ .input = .wheel_up });
    }

    _ = try app.apply(gpa, .{ .input = .{ .key = .ctrl_end } });
    try std.testing.expectEqual(@as(usize, 0), app.viewport.scroll_rows);
    try std.testing.expectEqual(ScrollAttachment.auto, app.viewport.attachment);
}

test "prepending transcript history keeps the viewport on older content" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "newer\nrows\nhere",
    } } });
    _ = try app.apply(gpa, .{ .prepend_transcript = .{ .message = .{
        .role = .user,
        .text = "older",
        .mode = .new_item,
    } } });

    try std.testing.expect(app.viewport.scroll_rows == render.transcriptScrollMax(&app));
    try std.testing.expectEqual(Transcript.Role.user, app.transcript.items.items[0].body.message.role);
}

test "mark pending tools canceled leaves completed tool cards alone" {
    const gpa = std.testing.allocator;
    var app = App.init(40, 8, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "pending",
        .name = "bash",
    } } });
    _ = try app.apply(gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "done",
        .name = "read",
        .status = .success,
    } } });
    _ = try app.apply(gpa, .{ .append_transcript = .{ .tool = .{
        .tool_call_id = "failed",
        .name = "edit",
        .status = .err,
    } } });

    _ = try app.apply(gpa, .mark_pending_tools_canceled);

    try std.testing.expectEqual(Transcript.ToolStatus.canceled, app.transcript.items.items[0].body.tool.status);
    try std.testing.expectEqual(Transcript.ToolStatus.success, app.transcript.items.items[1].body.tool.status);
    try std.testing.expectEqual(Transcript.ToolStatus.err, app.transcript.items.items[2].body.tool.status);
}

test "prepending history tool result merges with its older tool call" {
    const gpa = std.testing.allocator;
    var app = App.init(40, 8, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "newer",
    } } });
    _ = try app.apply(gpa, .{ .prepend_transcript = .{ .tools = &.{.{
        .tool_call_id = "call-1",
        .name = "read",
        .status = .success,
    }} } });
    _ = try app.apply(gpa, .{ .replace_front_tool_output = .{
        .tool_call_id = "call-1",
        .text = "file contents",
    } });
    _ = try app.apply(gpa, .{ .prepend_transcript = .{
        .message = .{ .role = .assistant, .text = "I'll read it." },
        .tools = &.{.{
            .tool_call_id = "call-1",
            .name = "read",
            .status = .pending,
            .title = "read {}",
        }},
    } });

    try std.testing.expectEqual(@as(usize, 3), app.transcript.items.items.len);
    try std.testing.expectEqual(Transcript.Role.assistant, app.transcript.items.items[0].body.message.role);
    try std.testing.expectEqual(Transcript.ToolStatus.success, app.transcript.items.items[1].body.tool.status);
    try std.testing.expectEqualStrings("read {}", app.transcript.items.items[1].body.tool.title);
    try std.testing.expectEqualStrings("file contents", app.transcript.items.items[1].body.tool.output.items);
    try std.testing.expectEqualStrings("newer", app.transcript.items.items[2].body.message.text.items);
}

test "picker selection returns opaque item id and closes modal" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{
        .{ .id = "openai/gpt", .label = "openai/gpt" },
        .{ .id = "anthropic/claude", .label = "anthropic/claude" },
    };
    _ = try app.apply(gpa, .{ .open_picker = .{ .id = 1, .items = &items } });
    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_down } });
    const effect = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(gpa);

    try std.testing.expect(effect == .picker_selected);
    try std.testing.expectEqual(@as(Picker.Id, 1), effect.picker_selected.picker_id);
    try std.testing.expectEqualStrings("anthropic/claude", effect.picker_selected.item_id);
    try std.testing.expect(app.completion.modal == null);
}

test "composer slash completion is combobox-style: arrows move list, typing filters input" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{
        .{ .id = "model", .label = "/model", .detail = "Select model" },
        .{ .id = "monitor", .label = "/monitor", .detail = "Show monitor" },
    };
    _ = try app.apply(gpa, .{ .set_composer_completions = .{ .id = 2, .items = &items } });

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/m") } });
    try std.testing.expectEqualStrings("/m", app.composer.text());
    try std.testing.expectEqual(@as(usize, 2), app.completion.command.?.matchCount());
    try std.testing.expectEqual(@as(usize, 0), app.completion.command.?.selectedIndex().?);

    _ = try app.apply(gpa, .{ .input = .{ .key = .arrow_down } });
    try std.testing.expectEqualStrings("/m", app.composer.text());
    try std.testing.expectEqual(@as(usize, 1), app.completion.command.?.selectedIndex().?);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("o") } });
    try std.testing.expectEqualStrings("/mo", app.composer.text());
    try std.testing.expectEqualStrings("mo", app.completion.command.?.querySlice());
    try std.testing.expectEqual(@as(usize, 2), app.completion.command.?.matchCount());
}

test "composer slash completion filters while typing and tab accepts" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{
        .{ .id = "help", .label = "help", .detail = "Show commands" },
        .{ .id = "model", .label = "model", .detail = "Select model" },
    };
    _ = try app.apply(gpa, .{ .set_composer_completions = .{ .id = 2, .items = &items } });

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/m") } });
    try std.testing.expect(app.visiblePicker() != null);
    try std.testing.expectEqualStrings("m", app.completion.command.?.querySlice());
    try std.testing.expectEqual(@as(usize, 1), app.completion.command.?.matchCount());

    _ = try app.apply(gpa, .{ .input = .{ .key = .backspace } });
    try std.testing.expectEqualStrings("", app.completion.command.?.querySlice());
    try std.testing.expectEqual(@as(usize, 2), app.completion.command.?.matchCount());

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("m") } });
    _ = try app.apply(gpa, .{ .input = .{ .key = .tab } });
    try std.testing.expectEqualStrings("/model ", app.composer.text());
    try std.testing.expect(app.visiblePicker() == null);
}

test "composer slash arg completions are keyed by command" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const model_items = [_]Picker.Item{
        .{ .id = "openai/gpt", .label = "openai/gpt" },
        .{ .id = "anthropic/claude", .label = "anthropic/claude" },
    };
    const resume_items = [_]Picker.Item{.{ .id = "2026-06-10T00:00:00Z_one.jsonl", .label = "one" }};
    _ = try app.apply(gpa, .{ .set_composer_arg_completions = .{
        .command_name = "model",
        .picker = .{ .id = 1, .items = &model_items },
    } });
    _ = try app.apply(gpa, .{ .set_composer_arg_completions = .{
        .command_name = "resume",
        .accept = .emit_selection,
        .picker = .{ .id = 3, .items = &resume_items },
    } });

    _ = try app.apply(gpa, .{ .replace_composer_text = "/model " });
    try std.testing.expectEqual(@as(Picker.Id, 1), app.visiblePicker().?.id);
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("claude") } });
    try std.testing.expectEqual(@as(Picker.Id, 1), app.visiblePicker().?.id);
    try std.testing.expectEqual(@as(usize, 1), app.visiblePicker().?.matchCount());

    _ = try app.apply(gpa, .{ .replace_composer_text = "/resume " });
    try std.testing.expectEqual(@as(Picker.Id, 3), app.visiblePicker().?.id);
}

test "composer slash arg completion can emit selected item" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{
        .{ .id = "2026-06-10T00:00:00Z_one.jsonl", .label = "one" },
        .{ .id = "2026-06-09T00:00:00Z_two.jsonl", .label = "two" },
    };
    _ = try app.apply(gpa, .{ .set_composer_arg_completions = .{
        .command_name = "resume",
        .accept = .emit_selection,
        .picker = .{ .id = 3, .items = &items },
    } });

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/resume two") } });
    const effect = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(gpa);
    try std.testing.expect(effect == .picker_selected);
    try std.testing.expectEqual(@as(Picker.Id, 3), effect.picker_selected.picker_id);
    try std.testing.expectEqualStrings("2026-06-09T00:00:00Z_two.jsonl", effect.picker_selected.item_id);
    try std.testing.expectEqualStrings("", app.composer.text());
}

test "composer slash arg completion with no match submits text" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{.{ .id = "2026-06-10T00:00:00Z_one.jsonl", .label = "one" }};
    _ = try app.apply(gpa, .{ .set_composer_arg_completions = .{
        .command_name = "resume",
        .accept = .emit_selection,
        .picker = .{ .id = 3, .items = &items },
    } });

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/resume tui-178") } });
    const effect = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(gpa);
    try std.testing.expect(effect == .submit_text);
    try std.testing.expectEqualStrings("/resume tui-178", effect.submit_text);
}

test "composer slash completion escape hides until the next edit" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{.{ .id = "model", .label = "/model", .detail = "Select model" }};
    _ = try app.apply(gpa, .{ .set_composer_completions = .{ .id = 2, .items = &items } });

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/m") } });
    try std.testing.expect(app.visiblePicker() != null);
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .escape } })) == null);
    try std.testing.expect(app.visiblePicker() == null);

    _ = try app.apply(gpa, .{ .input = .{ .key = .backspace } });
    try std.testing.expect(app.visiblePicker() != null);
}

test "composer slash completion enter accepts only incomplete command" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{.{ .id = "model", .label = "/model", .detail = "Select model" }};
    _ = try app.apply(gpa, .{ .set_composer_completions = .{ .id = 2, .items = &items } });

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("/m") } });
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .enter } })) == null);
    try std.testing.expectEqualStrings("/model ", app.composer.text());

    _ = try app.apply(gpa, .{ .input = .{ .key = .backspace } });
    const effect = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(gpa);
    try std.testing.expectEqualStrings("/model", effect.submit_text);
}

test "picker escape closes without interrupting the session" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const items = [_]Picker.Item{.{ .id = "one", .label = "one" }};
    _ = try app.apply(gpa, .{ .open_picker = .{ .id = 1, .items = &items } });
    const effect = try app.apply(gpa, .{ .input = .{ .key = .escape } });

    try std.testing.expect(effect == null);
    try std.testing.expect(app.completion.modal == null);
}

test "paste mode turns enter into a newline and never submits" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .paste_begin });
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("line1") } });
    const mid = try app.apply(gpa, .{ .input = .{ .key = .enter } });
    try std.testing.expect(mid == null);
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("line2") } });
    _ = try app.apply(gpa, .{ .input = .paste_end });

    try std.testing.expectEqualStrings("line1\nline2", app.composer.text());
}

test "composer overflow fills remaining capacity before warning" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const almost_big = try gpa.alloc(u8, Composer.buffer_size_bytes_max - 1);
    defer gpa.free(almost_big);
    @memset(almost_big, 'x');
    _ = try app.apply(gpa, .{ .replace_composer_text = almost_big });
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("yz") } });

    try std.testing.expectEqual(Composer.buffer_size_bytes_max, app.composer.text().len);
    try std.testing.expectEqual('y', app.composer.text()[app.composer.text().len - 1]);
    var warnings: usize = 0;
    for (app.transcript.items.items) |item| {
        if (item.body == .status and item.body.status.level == .warning) warnings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), warnings);
}

test "composer overflow degrades to one notice instead of an error" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    var fill: [64]u8 = undefined;
    @memset(&fill, 'x');
    var inserted: usize = 0;
    while (inserted < Composer.buffer_size_bytes_max) : (inserted += fill.len) {
        _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from(&fill) } });
    }
    // Two rejected inserts -> exactly one warning item.
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("y") } });
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("z") } });

    var warnings: usize = 0;
    for (app.transcript.items.items) |item| {
        if (item.body == .status and item.body.status.level == .warning) warnings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), warnings);
}

test "ctrl+c clears first, exits on wall-clock double press" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("draft") } });
    _ = try app.apply(gpa, .{ .tick = .{ .now_ms = 1_000 } });
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .ctrl_c } })) == null);
    try std.testing.expectEqual(@as(usize, 0), app.composer.text().len);

    // Past the window: clears again instead of exiting.
    _ = try app.apply(gpa, .{ .tick = .{ .now_ms = 1_000 + double_press_window_ms + 1 } });
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .ctrl_c } })) == null);

    // Inside the window: exit.
    _ = try app.apply(gpa, .{ .tick = .{ .now_ms = 1_000 + double_press_window_ms + 100 } });
    const effect = try app.apply(gpa, .{ .input = .{ .key = .ctrl_c } });
    try std.testing.expect(effect.? == .request_shutdown);
}

test "escape interrupts and ctrl+d exits only when empty" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .escape } })).? == .interrupt);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("x") } });
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .ctrl_d } })) == null);
    _ = try app.apply(gpa, .{ .input = .{ .key = .ctrl_c } });
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .ctrl_d } })).? == .request_shutdown);
}

test "ctrl+g emits an owned external editor request" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("draft") } });
    const effect = (try app.apply(gpa, .{ .input = .{ .key = .ctrl_g } })).?;
    defer effect.deinit(gpa);

    try std.testing.expect(effect == .edit_composer_external);
    try std.testing.expectEqualStrings("draft", effect.edit_composer_external);
    try std.testing.expectEqualStrings("draft", app.composer.text());
}

test "tick marks dirty only while something animates" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);
    app.dirty = false;

    _ = try app.apply(gpa, .{ .tick = .{ .now_ms = 100 } });
    try std.testing.expect(!app.dirty);

    _ = try app.apply(gpa, .{ .set_status = .{
        .slot = .status_line,
        .id = 1,
        .text = "working",
        .effect = .shimmer,
    } });
    app.dirty = false;
    _ = try app.apply(gpa, .{ .tick = .{ .now_ms = 200 } });
    try std.testing.expect(app.dirty);

    _ = try app.apply(gpa, .{ .clear_status = .{ .slot = .status_line, .id = 1 } });
    _ = try app.apply(gpa, .{ .set_status = .{
        .slot = .status_line,
        .id = 1,
        .text = "canceled",
        .effect = .shuffle,
    } });
    app.dirty = false;
    _ = try app.apply(gpa, .{ .tick = .{ .now_ms = 700 } });
    try std.testing.expect(app.dirty);
    app.dirty = false;
    _ = try app.apply(gpa, .{ .tick = .{ .now_ms = 900 } });
    try std.testing.expect(!app.dirty);
}

test "invalid streamed text degrades instead of erroring" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24, .{});
    defer app.deinit(gpa);

    const effect = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "bad\xffbyte",
    } } });
    try std.testing.expect(effect == null);
    try std.testing.expectEqualStrings(
        "bad\u{fffd}byte",
        app.transcript.items.items[0].body.message.text.items,
    );
}

// Truncation warnings are UI hints; the transcript mutation is the fact.
test "truncation notice oom does not fail transcript append" {
    const oversized = "x" ** (Transcript.append_size_bytes_max + 1);
    var saw_notice_oom = false;

    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var app = App.init(80, 24, .{});
        defer app.deinit(gpa);

        const effect = app.apply(gpa, .{ .append_transcript = .{ .message = .{
            .role = .assistant,
            .text = oversized,
        } } }) catch continue;
        if (effect) |value| {
            value.deinit(gpa);
            return error.UnexpectedEffect;
        }
        if (!failing.has_induced_failure) continue;

        saw_notice_oom = true;
        try std.testing.expectEqual(@as(usize, 1), app.transcript.items.items.len);
        try std.testing.expectEqual(
            Transcript.append_size_bytes_max,
            app.transcript.items.items[0].body.message.text.items.len,
        );
        break;
    }

    try std.testing.expect(saw_notice_oom);
}
