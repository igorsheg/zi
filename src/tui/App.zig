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
const PromptHistory = @import("PromptHistory.zig");
const Transcript = @import("Transcript.zig");
const input_mod = @import("input.zig");
const render = @import("render.zig");
const status_mod = @import("status.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("theme.zig");

const App = @This();

/// Second ctrl+c within this window exits; the first clears the composer.
pub const double_press_window_ms: i64 = 500;
pub const mouse_wheel_scroll_rows: usize = 3;

width: u16,
height: u16,
composer: Composer = .{},
prompt_history: PromptHistory = .{},
history_cursor_from_newest: ?usize = null,
history_draft: std.ArrayListUnmanaged(u8) = .empty,
history_draft_cursor_byte_index: usize = 0,
transcript: Transcript = .{},
status: status_mod.Store = .{},
scroll_rows: usize = 0,
theme: theme_mod.Theme = theme_mod.Theme.codex(),
tools_expanded: bool = false,
now_ms: i64 = 0,
last_clear_ms: ?i64 = null,
in_paste: bool = false,
/// Coalesces the composer-full notice: a 17 KB paste arrives as hundreds of
/// rejected inserts and must produce one warning, not hundreds.
composer_full_noticed: bool = false,
dirty: bool = true,

pub fn init(width: u16, height: u16) App {
    return .{ .width = width, .height = height };
}

pub fn deinit(self: *App, gpa: std.mem.Allocator) void {
    self.history_draft.deinit(gpa);
    self.prompt_history.deinit(gpa);
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

pub const Command = union(enum) {
    resize: Size,
    input: input_mod.Input,
    tick: Tick,
    clear_transcript,
    append_transcript: Transcript.Append,
    tool_output_delta: ToolOutputDelta,
    replace_tool_output: ToolText,
    replace_tool_footer: ToolText,
    prepend_transcript: Transcript.Append.MessageAppend,
    set_status: status_mod.Set,
    clear_status: status_mod.Clear,
};

pub const Effect = union(enum) {
    submit_text: []u8,
    interrupt,
    request_shutdown,
    request_transcript_history,

    pub fn deinit(self: Effect, gpa: std.mem.Allocator) void {
        switch (self) {
            .submit_text => |text| gpa.free(text),
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
                self.dirty = true;
            }
            return null;
        },
        .input => |event| return self.applyInput(gpa, event),
        .tick => |tick| {
            if (tick.now_ms != self.now_ms) {
                self.now_ms = tick.now_ms;
                if (self.status.hasAnimated(.status_line)) self.dirty = true;
            }
            return null;
        },
        .clear_transcript => {
            self.transcript.clear(gpa);
            self.scroll_rows = 0;
            self.dirty = true;
            return null;
        },
        .append_transcript => |entry| {
            const outcome = try self.transcript.append(gpa, entry);
            try self.noteOutcome(gpa, outcome);
            self.dirty = true;
            return null;
        },
        .tool_output_delta => |delta| {
            const outcome = try self.transcript.appendToolOutput(
                gpa,
                delta.tool_call_id,
                delta.text,
                delta.dropped_head_bytes,
                delta.dropped_head_lines,
            );
            try self.noteOutcome(gpa, outcome);
            self.dirty = true;
            return null;
        },
        .replace_tool_output => |replace| {
            const outcome = try self.transcript.replaceToolOutput(gpa, replace.tool_call_id, replace.text);
            try self.noteOutcome(gpa, outcome);
            self.dirty = true;
            return null;
        },
        .replace_tool_footer => |footer| {
            const outcome = try self.transcript.replaceToolFooter(gpa, footer.tool_call_id, footer.text);
            try self.noteOutcome(gpa, outcome);
            self.dirty = true;
            return null;
        },
        .prepend_transcript => |message| {
            const outcome = try self.transcript.prependMessage(gpa, message);
            try self.noteOutcome(gpa, outcome);
            self.scroll_rows = render.transcriptScrollMax(self);
            self.dirty = true;
            return null;
        },
        .set_status => |update| {
            if (self.status.set(update) == .dropped_full) try self.notice(gpa, .warning, "status line full");
            self.dirty = true;
            return null;
        },
        .clear_status => |request| {
            if (self.status.clear(request)) self.dirty = true;
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
        .toggle_tool_expansion => {
            self.tools_expanded = !self.tools_expanded;
            self.dirty = true;
        },
        .interrupt => return .interrupt,
        .clear_or_exit => return self.clearOrExit(),
        .exit_if_composer_empty => if (self.composer.text().len == 0) return .request_shutdown,
        .none => {},
    }
    return null;
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
        .ok => {
            self.resetHistoryNavigation();
            self.composer_full_noticed = false;
            self.dirty = true;
        },
        .rejected_full => {
            if (!self.composer_full_noticed) {
                self.composer_full_noticed = true;
                try self.notice(gpa, .warning, "input too large: composer is full, extra input dropped");
            }
        },
    }
    return null;
}

fn composerSubmit(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!?Effect {
    const text = self.composer.submitSlice() orelse {
        if (self.composer.text().len != 0) self.composer.clear();
        self.resetHistoryNavigation();
        self.dirty = true;
        return null;
    };

    const submitted = try gpa.dupe(u8, text);
    errdefer gpa.free(submitted);
    try self.prompt_history.record(gpa, text);

    self.composer.clear();
    self.resetHistoryNavigation();
    self.composer_full_noticed = false;
    self.dirty = true;
    return .{ .submit_text = submitted };
}

fn composerTextEdit(self: *App, comptime edit: fn (*Composer) void) void {
    edit(&self.composer);
    self.resetHistoryNavigation();
    self.dirty = true;
}

fn composerCursorEdit(self: *App, comptime edit: fn (*Composer) void) void {
    edit(&self.composer);
    self.dirty = true;
}

fn composerUpOrHistory(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    if (self.composer.text().len != 0 and
        self.composer.moveVertical(render.composerTextWidth(self.width), .up) == .moved)
    {
        self.dirty = true;
        return;
    }
    try self.historyPrevious(gpa);
}

fn composerDownOrHistory(self: *App, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    if (self.composer.text().len != 0 and
        self.composer.moveVertical(render.composerTextWidth(self.width), .down) == .moved)
    {
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

fn clearOrExit(self: *App) ?Effect {
    if (self.last_clear_ms) |last_ms| {
        if (self.now_ms >= last_ms and self.now_ms - last_ms <= double_press_window_ms) {
            return .request_shutdown;
        }
    }
    self.composer.clear();
    self.resetHistoryNavigation();
    self.composer_full_noticed = false;
    self.last_clear_ms = self.now_ms;
    self.dirty = true;
    return null;
}

const ScrollResult = enum { moved, boundary };

fn scrollUp(self: *App, rows: usize) ScrollResult {
    const max = render.transcriptScrollMax(self);
    if (rows == 0 or self.scroll_rows == max) return .boundary;
    const next = @min(max, self.scroll_rows + rows);
    if (next == self.scroll_rows) return .boundary;
    self.scroll_rows = next;
    self.dirty = true;
    return .moved;
}

fn scrollDown(self: *App, rows: usize) void {
    if (rows == 0) return;
    const next = self.scroll_rows -| rows;
    if (next == self.scroll_rows) return;
    self.scroll_rows = next;
    self.dirty = true;
}

fn noteOutcome(self: *App, gpa: std.mem.Allocator, outcome: Transcript.Outcome) error{OutOfMemory}!void {
    if (outcome.truncated) try self.notice(gpa, .warning, "transcript append truncated");
}

/// Internal degradation notices share the transcript status vocabulary so
/// policy failures are visible to the user instead of silently dropped.
fn notice(self: *App, gpa: std.mem.Allocator, level: Transcript.StatusLevel, text: []const u8) error{OutOfMemory}!void {
    _ = try self.transcript.append(gpa, .{ .status = .{ .level = level, .text = text } });
    self.dirty = true;
}

pub fn hasAnimation(self: *const App) bool {
    return self.status.hasAnimated(.status_line);
}

test "submit returns owned text and clears the composer" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24);
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("hello") } });
    const effect = (try app.apply(gpa, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(gpa);
    try std.testing.expectEqualStrings("hello", effect.submit_text);
    try std.testing.expectEqual(@as(usize, 0), app.composer.text().len);
}

test "arrow history recall preserves the current draft" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24);
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
    var app = App.init(7, 24); // composer text width is 3.
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
    var app = App.init(20, 6);
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "one\ntwo\nthree\nfour\nfive\nsix",
    } } });
    const max_scroll = render.transcriptScrollMax(&app);
    try std.testing.expect(max_scroll > 0);

    _ = try app.apply(gpa, .{ .input = .wheel_up });
    try std.testing.expectEqual(@min(max_scroll, mouse_wheel_scroll_rows), app.scroll_rows);

    app.scroll_rows = max_scroll;
    const boundary = try app.apply(gpa, .{ .input = .wheel_up });
    try std.testing.expect(boundary.? == .request_transcript_history);

    _ = try app.apply(gpa, .{ .input = .wheel_down });
    try std.testing.expectEqual(max_scroll -| mouse_wheel_scroll_rows, app.scroll_rows);

    app.scroll_rows = 0;
    _ = try app.apply(gpa, .{ .input = .wheel_down });
    try std.testing.expectEqual(@as(usize, 0), app.scroll_rows);
}

test "prepending transcript history keeps the viewport on older content" {
    const gpa = std.testing.allocator;
    var app = App.init(20, 6);
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "newer\nrows\nhere",
    } } });
    _ = try app.apply(gpa, .{ .prepend_transcript = .{
        .role = .user,
        .text = "older",
        .mode = .new_item,
    } });

    try std.testing.expect(app.scroll_rows == render.transcriptScrollMax(&app));
    try std.testing.expectEqual(Transcript.Role.user, app.transcript.items.items[0].body.message.role);
}

test "paste mode turns enter into a newline and never submits" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24);
    defer app.deinit(gpa);

    _ = try app.apply(gpa, .{ .input = .paste_begin });
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("line1") } });
    const mid = try app.apply(gpa, .{ .input = .{ .key = .enter } });
    try std.testing.expect(mid == null);
    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("line2") } });
    _ = try app.apply(gpa, .{ .input = .paste_end });

    try std.testing.expectEqualStrings("line1\nline2", app.composer.text());
}

test "composer overflow degrades to one notice instead of an error" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24);
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
    var app = App.init(80, 24);
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
    var app = App.init(80, 24);
    defer app.deinit(gpa);

    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .escape } })).? == .interrupt);

    _ = try app.apply(gpa, .{ .input = .{ .text = input_mod.InlineBytes.from("x") } });
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .ctrl_d } })) == null);
    _ = try app.apply(gpa, .{ .input = .{ .key = .ctrl_c } });
    try std.testing.expect((try app.apply(gpa, .{ .input = .{ .key = .ctrl_d } })).? == .request_shutdown);
}

test "tick marks dirty only while something animates" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24);
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
}

test "invalid streamed text degrades instead of erroring" {
    const gpa = std.testing.allocator;
    var app = App.init(80, 24);
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
