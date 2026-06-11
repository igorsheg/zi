const std = @import("std");
const composer_mod = @import("composer.zig");
const input_mod = @import("input.zig");
const frame_mod = @import("frame.zig");
const keys = @import("keys.zig");
const slots_mod = @import("slots.zig");
const surface_mod = @import("surface.zig");
const theme_mod = @import("theme.zig");
const transcript = @import("transcript.zig");

pub const ProductApp = struct {
    width: u16,
    height: u16,
    composer: composer_mod.ComposerBuffer = .{},
    transcript: transcript.TranscriptBuffer = .{},
    slots: slots_mod.SlotStore = .{},
    modal: ?surface_mod.Confirm = null,
    transcript_scroll_rows: usize = 0,
    transcript_scroll_max_cache: usize = 0,
    transcript_scroll_max_revision: u64 = std.math.maxInt(u64),
    transcript_scroll_max_width: u16 = 0,
    transcript_scroll_max_visible_rows: usize = std.math.maxInt(usize),
    theme: theme_mod.Theme = theme_mod.Theme.codex(),
    animation_tick: u64 = 0,
    last_clear_tick: ?u64 = null,
    dirty: bool = true,

    pub fn init(width: u16, height: u16) !ProductApp {
        try frame_mod.checkSize(width, height);
        return .{ .width = width, .height = height };
    }

    pub fn deinit(self: *ProductApp, allocator: std.mem.Allocator) void {
        if (self.modal) |*modal| modal.deinit(allocator);
        self.slots.deinit(allocator);
        self.transcript.deinit(allocator);
        self.composer.deinit(allocator);
        self.* = undefined;
    }

    pub fn apply(self: *ProductApp, allocator: std.mem.Allocator, command: Command) !?Effect {
        switch (command) {
            .resize => |size| {
                try frame_mod.checkSize(size.width, size.height);
                if (self.width != size.width or self.height != size.height) {
                    self.width = size.width;
                    self.height = size.height;
                    self.dirty = true;
                }
                return null;
            },
            .input => |event| return try self.applyInput(allocator, event),
            .clear_composer => {
                _ = try self.applyComposer(allocator, .clear);
                return null;
            },
            .clear_transcript => {
                self.transcript.deinit(allocator);
                self.transcript = .{};
                self.transcript_scroll_rows = 0;
                self.transcript_scroll_max_cache = 0;
                self.transcript_scroll_max_revision = std.math.maxInt(u64);
                self.transcript_scroll_max_width = 0;
                self.transcript_scroll_max_visible_rows = std.math.maxInt(usize);
                self.dirty = true;
                return null;
            },
            .insert_composer_text => |text| {
                _ = try self.applyComposer(allocator, .{ .insert_utf8 = text });
                return null;
            },
            .append_transcript => |append| {
                try self.transcript.append(allocator, append);
                self.dirty = true;
                return null;
            },
            .tool_output_delta => |delta| {
                try self.transcript.appendToolOutput(
                    allocator,
                    delta.tool_call_id,
                    delta.text,
                    delta.dropped_head_bytes,
                    delta.dropped_head_lines,
                );
                self.dirty = true;
                return null;
            },
            .replace_tool_call_preview => |preview| {
                try self.transcript.replaceToolCallPreview(allocator, preview.tool_call_id, preview.text);
                self.dirty = true;
                return null;
            },
            .set_slot_contribution => |contribution| {
                try self.slots.set(allocator, contribution);
                self.dirty = true;
                return null;
            },
            .animation_tick => |tick| {
                if (tick != self.animation_tick) {
                    self.animation_tick = tick;
                    if (self.slots.hasAnimated(.status_area)) self.dirty = true;
                }
                return null;
            },
            .clear_slot_contribution => |clear| {
                if (self.slots.clear(allocator, clear)) self.dirty = true;
                return null;
            },
            .open_confirm => |open| {
                if (self.modal != null) return error.ModalAlreadyOpen;
                var confirm = try surface_mod.Confirm.init(allocator, open);
                errdefer confirm.deinit(allocator);
                self.modal = confirm;
                self.dirty = true;
                return null;
            },
        }
    }

    fn applyInput(self: *ProductApp, allocator: std.mem.Allocator, event: input_mod.Input) !?Effect {
        if (self.modal != null) return self.applyModal(allocator, event);
        switch (keys.resolve(event)) {
            .composer_insert => |bytes| {
                if (try self.applyComposer(allocator, .{ .insert_utf8 = bytes.slice() })) |effect| return effect;
            },
            .composer_backspace => if (try self.applyComposer(allocator, .backspace)) |effect| return effect,
            .composer_left => if (try self.applyComposer(allocator, .move_left)) |effect| return effect,
            .composer_right => if (try self.applyComposer(allocator, .move_right)) |effect| return effect,
            .composer_start => if (try self.applyComposer(allocator, .move_start)) |effect| return effect,
            .composer_end => if (try self.applyComposer(allocator, .move_end)) |effect| return effect,
            .composer_submit => if (try self.applyComposer(allocator, .submit)) |effect| return effect,
            .transcript_page_up => self.scrollTranscript(self.transcriptVisibleRows()),
            .transcript_page_down => self.scrollTranscriptDown(self.transcriptVisibleRows()),
            .interrupt => return .interrupt,
            .clear_or_exit => if (try self.clearOrExit(allocator)) |effect| return effect,
            .exit_if_composer_empty => if (self.composer.text().len == 0) return .request_shutdown,
            .request_shutdown => return .request_shutdown,
            .none => {},
        }
        return null;
    }

    fn clearOrExit(self: *ProductApp, allocator: std.mem.Allocator) !?Effect {
        const double_press_window_ticks = 32;
        if (self.last_clear_tick) |last_tick| {
            if (self.animation_tick >= last_tick and
                self.animation_tick - last_tick <= double_press_window_ticks)
            {
                return .request_shutdown;
            }
        }
        _ = try self.applyComposer(allocator, .clear);
        self.last_clear_tick = self.animation_tick;
        return null;
    }

    fn applyModal(self: *ProductApp, allocator: std.mem.Allocator, event: input_mod.Input) !?Effect {
        const modal = if (self.modal) |*modal| modal else return null;
        if (modal.applyInput(event)) |result| {
            modal.deinit(allocator);
            self.modal = null;
            self.dirty = true;
            return .{ .confirm_result = result };
        }
        self.dirty = true;
        return null;
    }

    fn applyComposer(
        self: *ProductApp,
        allocator: std.mem.Allocator,
        command: composer_mod.ComposerCommand,
    ) !?Effect {
        if (try self.composer.apply(allocator, command)) |text| {
            self.dirty = true;
            return .{ .submit_text = text };
        }
        self.dirty = true;
        return null;
    }

    fn scrollTranscript(self: *ProductApp, rows: usize) void {
        if (rows == 0) return;
        const max = self.transcriptScrollMax();
        const next = @min(max, self.transcript_scroll_rows + rows);
        if (next == self.transcript_scroll_rows) return;
        self.transcript_scroll_rows = next;
        self.dirty = true;
    }

    fn scrollTranscriptDown(self: *ProductApp, rows: usize) void {
        if (rows == 0) return;
        const next = if (self.transcript_scroll_rows > rows) self.transcript_scroll_rows - rows else 0;
        if (next == self.transcript_scroll_rows) return;
        self.transcript_scroll_rows = next;
        self.dirty = true;
    }

    pub fn clampTranscriptScroll(self: *ProductApp) void {
        self.transcript_scroll_rows = @min(self.transcript_scroll_rows, self.transcriptScrollMax());
    }

    fn transcriptScrollMax(self: *ProductApp) usize {
        const visible_rows = self.transcriptVisibleRows();
        if (self.transcript_scroll_max_revision != self.transcript.revision or
            self.transcript_scroll_max_width != self.width or
            self.transcript_scroll_max_visible_rows != visible_rows)
        {
            self.transcript_scroll_max_cache = frame_mod.transcriptScrollMax(
                self.transcript,
                self.width,
                visible_rows,
            );
            self.transcript_scroll_max_revision = self.transcript.revision;
            self.transcript_scroll_max_width = self.width;
            self.transcript_scroll_max_visible_rows = visible_rows;
        }
        return self.transcript_scroll_max_cache;
    }

    fn transcriptVisibleRows(self: *ProductApp) usize {
        return frame_mod.transcriptVisibleRowsWithReserved(
            self.height,
            frame_mod.composerRows(self) + frame_mod.statusRows(self),
        );
    }
};

pub const Command = union(enum) {
    resize: Size,
    input: input_mod.Input,
    clear_composer,
    clear_transcript,
    insert_composer_text: []const u8,
    append_transcript: transcript.TranscriptAppend,
    tool_output_delta: ToolOutputDelta,
    replace_tool_call_preview: ToolCallPreview,
    set_slot_contribution: slots_mod.SetContribution,
    animation_tick: u64,
    open_confirm: surface_mod.OpenConfirm,
    clear_slot_contribution: slots_mod.ClearContribution,
};

pub const ToolOutputDelta = struct {
    tool_call_id: []const u8,
    text: []const u8,
    dropped_head_bytes: usize = 0,
    dropped_head_lines: usize = 0,
};

pub const ToolCallPreview = struct {
    tool_call_id: []const u8,
    text: []const u8,
};

pub const Size = struct {
    width: u16,
    height: u16,
};

pub const Effect = union(enum) {
    submit_text: []u8,
    request_shutdown,
    interrupt,
    confirm_result: surface_mod.ConfirmResult,

    pub fn deinit(self: Effect, allocator: std.mem.Allocator) void {
        switch (self) {
            .submit_text => |text| allocator.free(text),
            .request_shutdown, .interrupt, .confirm_result => {},
        }
    }
};

const app_mod_effect_interrupt: ?Effect = .interrupt;
const app_mod_effect_request_shutdown: ?Effect = .request_shutdown;

fn appendTestMessage(app: *ProductApp, role: transcript.TranscriptRole, text: []const u8) !void {
    _ = try app.apply(std.testing.allocator, .{
        .append_transcript = .{ .message = .{ .role = role, .text = text } },
    });
}
