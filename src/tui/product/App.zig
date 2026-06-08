const std = @import("std");
const substrate = @import("../substrate/root.zig");
const composer_mod = @import("composer.zig");
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
            .modal => |modal_command| return self.applyModal(allocator, modal_command),
        }
    }

    fn applyInput(self: *ProductApp, allocator: std.mem.Allocator, event: substrate.input.InputEvent) !?Effect {
        if (self.modal != null) return self.applyModal(allocator, .{ .input = event });
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

    fn applyModal(self: *ProductApp, allocator: std.mem.Allocator, command: surface_mod.ModalCommand) !?Effect {
        const modal = if (self.modal) |*modal| modal else return null;
        if (modal.apply(command)) |result| {
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
    input: substrate.input.InputEvent,
    clear_composer,
    insert_composer_text: []const u8,
    append_transcript: transcript.TranscriptAppend,
    tool_output_delta: ToolOutputDelta,
    replace_tool_call_preview: ToolCallPreview,
    set_slot_contribution: slots_mod.SetContribution,
    animation_tick: u64,
    open_confirm: surface_mod.OpenConfirm,
    modal: surface_mod.ModalCommand,
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

test "product app applies input through one mutation path" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    const text = substrate.input.InlineBytes.from("hello");
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .text = text } }) == null);
    try std.testing.expectEqualStrings("hello", app.composer.text());

    const effect = (try app.apply(std.testing.allocator, .{ .input = .{ .key = .enter } })).?;
    defer effect.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", effect.submit_text);
    try std.testing.expectEqualStrings("", app.composer.text());
}

test "product app maps escape to interrupt not shutdown" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        app_mod_effect_interrupt,
        try app.apply(std.testing.allocator, .{ .input = .{ .key = .escape } }),
    );
}

const app_mod_effect_interrupt: ?Effect = .interrupt;
const app_mod_effect_request_shutdown: ?Effect = .request_shutdown;

fn appendTestMessage(app: *ProductApp, role: transcript.TranscriptRole, text: []const u8) !void {
    _ = try app.apply(std.testing.allocator, .{
        .append_transcript = .{ .message = .{ .role = role, .text = text } },
    });
}

test "product app applies transcript append through apply" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    var source = [_]u8{ 'o', 'k' };
    try std.testing.expect(try app.apply(std.testing.allocator, .{
        .append_transcript = .{ .message = .{ .role = .assistant, .text = &source } },
    }) == null);
    source[0] = 'n';

    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.transcript.items.items.len);
    try std.testing.expectEqualStrings("ok", app.transcript.items.items[0].message.text);
}

test "product app maps ctrl-u to transcript scroll" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    try appendTestMessage(&app, .system, "one");
    try appendTestMessage(&app, .system, "two");
    try appendTestMessage(&app, .system, "three");
    try appendTestMessage(&app, .system, "four");

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x15 } } }) == null);
    try std.testing.expectEqual(@as(usize, 1), app.transcript_scroll_rows);
}

test "product app ctrl-c clears then double press exits" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .insert_composer_text = "draft" }) == null);
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .animation_tick = 10 }) == null);
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x03 } } }) == null);
    try std.testing.expectEqualStrings("", app.composer.text());
    try std.testing.expectEqual(
        app_mod_effect_request_shutdown,
        try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x03 } } }),
    );
}

test "product app ctrl-d exits only when composer is empty" {
    var app = try ProductApp.init(20, 4);
    defer app.deinit(std.testing.allocator);

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .insert_composer_text = "draft" }) == null);
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x04 } } }) == null);
    try std.testing.expectEqualStrings("draft", app.composer.text());
    _ = try app.apply(std.testing.allocator, .clear_composer);
    try std.testing.expectEqual(
        app_mod_effect_request_shutdown,
        try app.apply(std.testing.allocator, .{ .input = .{ .key = .{ .ctrl = 0x04 } } }),
    );
}

test "product app page down at bottom does not dirty" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);
    app.dirty = false;

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .page_down } }) == null);
    try std.testing.expectEqual(@as(usize, 0), app.transcript_scroll_rows);
    try std.testing.expect(!app.dirty);
}

test "product app pages transcript scroll and append preserves it" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    try appendTestMessage(&app, .system, "one");
    try appendTestMessage(&app, .system, "two");
    try appendTestMessage(&app, .system, "three");
    try appendTestMessage(&app, .system, "four");

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .page_up } }) == null);
    try std.testing.expectEqual(@as(usize, 1), app.transcript_scroll_rows);
    try appendTestMessage(&app, .system, "five");
    try std.testing.expectEqual(@as(usize, 1), app.transcript_scroll_rows);
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{ .key = .page_down } }) == null);
    try std.testing.expectEqual(@as(usize, 0), app.transcript_scroll_rows);
}

test "product app scroll max cache follows direct transcript revision" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), app.transcriptScrollMax());
    try app.transcript.append(std.testing.allocator, .{ .message = .{ .role = .system, .text = "one" } });
    try app.transcript.append(std.testing.allocator, .{ .message = .{ .role = .system, .text = "two" } });
    try app.transcript.append(std.testing.allocator, .{ .message = .{ .role = .system, .text = "three" } });
    try app.transcript.append(std.testing.allocator, .{ .message = .{ .role = .system, .text = "four" } });

    try std.testing.expect(app.transcriptScrollMax() > 0);
}

test "product app clamps transcript scroll after append eviction" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    for (0..transcript.line_count_max + 1) |index| {
        const text = if (index == 0) "old" else "new";
        try appendTestMessage(&app, .system, text);
    }
    app.transcript_scroll_rows = std.math.maxInt(usize);
    try appendTestMessage(&app, .system, "tail");
    app.clampTranscriptScroll();

    try std.testing.expect(app.transcript_scroll_rows <= app.transcriptScrollMax());
}

test "product app confirm modal captures input until result" {
    var app = try ProductApp.init(30, 8);
    defer app.deinit(std.testing.allocator);

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .open_confirm = .{
        .id = 1,
        .title = "Delete?",
        .body = "Really?",
    } }) == null);
    try std.testing.expect(app.modal != null);

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .input = .{
        .text = substrate.input.InlineBytes.from("x"),
    } }) == null);
    try std.testing.expectEqualStrings("", app.composer.text());

    const effect = (try app.apply(std.testing.allocator, .{ .input = .{
        .text = substrate.input.InlineBytes.from("n"),
    } })).?;
    defer effect.deinit(std.testing.allocator);
    try std.testing.expect(effect == .confirm_result);
    try std.testing.expectEqual(@as(surface_mod.ModalId, 1), effect.confirm_result.id);
    try std.testing.expect(!effect.confirm_result.accepted);
    try std.testing.expect(app.modal == null);
}

test "product app rejects second modal before mutation" {
    var app = try ProductApp.init(30, 8);
    defer app.deinit(std.testing.allocator);

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .open_confirm = .{
        .id = 1,
        .title = "One",
        .body = "",
    } }) == null);
    try std.testing.expectError(error.ModalAlreadyOpen, app.apply(std.testing.allocator, .{ .open_confirm = .{
        .id = 2,
        .title = "Two",
        .body = "",
    } }));
    const effect = (try app.apply(std.testing.allocator, .{ .modal = .confirm })).?;
    try std.testing.expect(effect.confirm_result.accepted);
}

test "product app animation tick dirties only animated status" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    app.dirty = false;
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .animation_tick = 1 }) == null);
    try std.testing.expect(!app.dirty);

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .set_slot_contribution = .{
        .slot = .status_area,
        .id = 1,
        .text = "working",
        .effect = .shimmer,
    } }) == null);
    app.dirty = false;
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .animation_tick = 2 }) == null);
    try std.testing.expect(app.dirty);
    app.dirty = false;
    try std.testing.expect(try app.apply(std.testing.allocator, .{ .animation_tick = 2 }) == null);
    try std.testing.expect(!app.dirty);
}

test "product app applies slot contributions atomically" {
    var app = try ProductApp.init(20, 5);
    defer app.deinit(std.testing.allocator);

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .set_slot_contribution = .{
        .slot = .composer_top_right,
        .id = 1,
        .text = "model: faux",
    } }) == null);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.slots.count(.composer_top_right));

    app.dirty = false;
    try std.testing.expectError(
        error.InvalidSlotContributionText,
        app.apply(std.testing.allocator, .{ .set_slot_contribution = .{
            .slot = .composer_top_right,
            .id = 2,
            .text = "bad\n",
        } }),
    );
    try std.testing.expect(!app.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.slots.count(.composer_top_right));

    try std.testing.expect(try app.apply(std.testing.allocator, .{ .clear_slot_contribution = .{
        .slot = .composer_top_right,
        .id = 1,
    } }) == null);
    try std.testing.expectEqual(@as(usize, 0), app.slots.count(.composer_top_right));
}
