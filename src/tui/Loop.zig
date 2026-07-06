const std = @import("std");
const vaxis = @import("vaxis");
const chrome = @import("chrome.zig");
const Editor = @import("Editor.zig");
const input = @import("input.zig");
const render_policy = @import("render_policy.zig");
const screen = @import("screen.zig");
const trace_mod = @import("trace.zig");

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
const exit_hint_text = "press ctrl+c again to exit";
const scratch_capacity = 8192;
const synthetic_flood_rate_bytes_per_second: u64 = 50 * 1024;

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
};

pub const Loop = struct {
    editor: Editor = .{},
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
    layout_epoch: u64 = 0,
    last_width: u16 = 0,
    last_height: u16 = 0,
    pub fn init(initial_prompt: ?[]const u8) Editor.Error!Loop {
        var self: Loop = .{};
        if (initial_prompt) |prompt| try self.editor.insert(prompt);
        return self;
    }

    pub fn enableSyntheticFlood(self: *Loop, start_ns: u64) void {
        self.synthetic_flood = .{ .enabled = true, .start_ns = start_ns, .emitted_bytes = 0 };
        self.dirty = true;
    }

    pub fn recordInputBytes(self: *Loop, count: usize) void {
        self.frame_input_bytes += count;
    }

    pub fn dispatch(self: *Loop, action: input.Action) Editor.Error!void {
        try self.dispatchAt(action, 0);
    }

    pub fn dispatchAt(self: *Loop, action: input.Action, now_ns: u64) Editor.Error!void {
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
            .cancel => {},
            .quit_eof => {
                if (self.editor.text().len == 0) {
                    self.exit_requested = true;
                } else {
                    self.clearExitHint();
                    _ = self.editor.deleteForward();
                }
            },
            .submit, .steer_submit, .follow_up_submit => {
                self.clearExitHint();
                self.submitPrompt();
            },
            .clear_or_quit => self.handleClearOrQuit(now_ns),
            .scroll => {},
            .newline, .expand_toggle, .dequeue_all, .page_up, .page_down, .force_redraw, .none => {},
        }
    }

    pub fn submittedPrompt(self: *const Loop) ?[]const u8 {
        if (self.submitted_prompt) |*prompt| return prompt.text();
        return null;
    }

    pub fn composeFrame(self: *Loop, width: u16, height: u16) error{ FrameFull, LineFull }!screen.Frame {
        self.noteResize(width, height);
        const frame = try chrome.compose(.{
            .status = if (self.exit_requested)
                "exiting"
            else if (self.exit_hint_visible)
                exit_hint_text
            else
                "ready",
            .scratch_text = self.scratch.text(),
            .editor = &self.editor,
        }, width, height);
        return frame;
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
        return self.ctrl_c_deadline_ns;
    }

    pub fn noteResize(self: *Loop, width: u16, height: u16) void {
        if (self.last_width == width and self.last_height == height) return;
        if (self.last_width != 0 and self.last_width != width) {
            self.layout_epoch +%= 1;
            self.trace.recordRebuild(0);
        }
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

    pub fn tick(self: *Loop, now_ns: u64) void {
        self.pumpSyntheticFlood(now_ns);
        if (self.ctrl_c_deadline_ns) |deadline| {
            if (now_ns > deadline) {
                self.ctrl_c_deadline_ns = null;
                if (self.exit_hint_visible) {
                    self.exit_hint_visible = false;
                    self.dirty = true;
                }
            }
        }
    }

    fn pumpSyntheticFlood(self: *Loop, now_ns: u64) void {
        if (!self.synthetic_flood.enabled) return;
        const elapsed_ns = now_ns -| self.synthetic_flood.start_ns;
        const target_bytes: u64 = @intCast((@as(u128, elapsed_ns) * synthetic_flood_rate_bytes_per_second) / std.time.ns_per_s);
        if (target_bytes <= self.synthetic_flood.emitted_bytes) return;
        const append_count: usize = @intCast(target_bytes - self.synthetic_flood.emitted_bytes);
        const previous_evictions = self.scratch.evicted_bytes;
        self.scratch.appendRepeated('x', append_count);
        self.synthetic_flood.emitted_bytes = target_bytes;
        if (self.scratch.evicted_bytes > previous_evictions) {
            self.trace.frames.evictions += self.scratch.evicted_bytes - previous_evictions;
        }
        self.dirty = true;
    }

    fn nsToUs(ns: u64) u64 {
        return ns / std.time.ns_per_us;
    }

    fn applyEditorOp(self: *Loop, op: input.EditorOp) void {
        switch (op) {
            .move_left => _ = self.editor.moveLeft(),
            .move_right => _ = self.editor.moveRight(),
            .backspace => _ = self.editor.backspace(),
            .delete_forward => _ = self.editor.deleteForward(),
            .home => self.editor.moveHome(),
            .end => self.editor.moveEnd(),
            .clear => self.editor.clear(),
        }
    }

    fn submitPrompt(self: *Loop) void {
        const text = self.editor.text();
        if (text.len == 0) return;
        self.submitted_prompt = .{};
        self.submitted_prompt.?.set(text);
        self.editor.clear();
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

test "loop dispatch edits text through editor actions" {
    var loop: Loop = .{};
    try loop.dispatch(.{ .insert = "abc" });
    try loop.dispatch(.{ .key_editor = .move_left });
    try loop.dispatch(.{ .insert = "x" });
    try loop.dispatch(.{ .key_editor = .backspace });

    try std.testing.expectEqualStrings("abc", loop.editor.text());
    try std.testing.expect(!loop.exit_requested);
    try std.testing.expectEqual(@as(usize, 4), loop.trace.input_actions);
}

test "loop clear_or_quit clears first then exits" {
    var loop: Loop = .{};
    try loop.dispatch(.{ .insert = "draft" });
    try loop.dispatch(.clear_or_quit);
    try std.testing.expectEqualStrings("", loop.editor.text());
    try std.testing.expect(!loop.exit_requested);
    try loop.dispatch(.clear_or_quit);
    try std.testing.expect(loop.exit_requested);
}

test "loop submit snapshots editor and clears input" {
    var loop: Loop = .{};
    try loop.dispatch(.{ .insert = "hello" });
    try loop.dispatch(.submit);

    try std.testing.expectEqualStrings("hello", loop.submittedPrompt().?);
    try std.testing.expectEqualStrings("", loop.editor.text());
    try std.testing.expect(loop.dirty);
}

test "loop dispatches mapped key actions end-to-end" {
    var loop: Loop = .{};
    try loop.dispatch(input.fromKey(.{ .codepoint = 'a', .text = "a" }));
    try loop.dispatch(input.fromKey(.{ .codepoint = 'b', .text = "b" }));
    try loop.dispatch(input.fromKey(.{ .codepoint = vaxis.Key.left }));
    try loop.dispatch(input.fromKey(.{ .codepoint = vaxis.Key.backspace }));

    try std.testing.expectEqualStrings("b", loop.editor.text());
}

test "loop init seeds editor from initial prompt" {
    var loop = try Loop.init("hello");
    try std.testing.expectEqualStrings("hello", loop.editor.text());
}

test "loop composes frame and clears dirty only after render success" {
    var loop = try Loop.init("draft");
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
    var loop = try Loop.init(null);
    try std.testing.expect(!loop.shouldRender(frame_floor_ns - 1));
    try std.testing.expect(loop.shouldRender(frame_floor_ns));

    loop.markRendered(frame_floor_ns, 10 * std.time.ns_per_ms);
    loop.dirty = true;
    try std.testing.expect(!loop.shouldRender(frame_floor_ns + 29 * std.time.ns_per_ms));
    try std.testing.expect(loop.shouldRender(frame_floor_ns + 30 * std.time.ns_per_ms));
}

test "loop ctrl-c hint expires on timer tick" {
    var loop: Loop = .{};
    try loop.dispatchAt(.clear_or_quit, 100);
    try std.testing.expect(loop.exit_hint_visible);
    try std.testing.expectEqual(@as(?u64, 100 + double_key_window_ns), loop.nextTimerDeadlineNs());

    loop.dirty = false;
    loop.tick(101 + double_key_window_ns);
    try std.testing.expect(!loop.exit_hint_visible);
    try std.testing.expect(loop.dirty);
}

test "loop records frame input and event counts on render" {
    var loop: Loop = .{};
    loop.recordInputBytes(3);
    try loop.dispatch(.{ .insert = "abc" });
    loop.markRendered(frame_floor_ns, 2 * std.time.ns_per_us);

    const record = loop.trace.frames.newest().?;
    try std.testing.expectEqual(@as(usize, 3), record.input_bytes);
    try std.testing.expectEqual(@as(usize, 1), record.events_applied);
    try std.testing.expectEqual(@as(u64, 2), record.paint_us);
}

test "loop synthetic flood appends fifty kilobytes per second into bounded scratch" {
    var loop: Loop = .{};
    loop.enableSyntheticFlood(0);
    loop.tick(std.time.ns_per_s);

    try std.testing.expectEqual(@as(u64, 50 * 1024), loop.synthetic_flood.emitted_bytes);
    try std.testing.expectEqual(@as(usize, scratch_capacity), loop.scratch.text().len);
    try std.testing.expect(loop.scratch.evicted_bytes > 0);
    try std.testing.expect(loop.dirty);
}
