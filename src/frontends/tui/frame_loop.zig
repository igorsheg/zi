const std = @import("std");
const builtin = @import("builtin");

const coding_agent = @import("../../coding_agent/root.zig");
const tui = @import("../../tui/root.zig");
const input_reader_mod = @import("input_reader.zig");
const view_diff = @import("view_diff.zig");
const worker_mod = @import("worker.zig");

const client_protocol = coding_agent.client_protocol;
const vm = coding_agent.view_model;

pub const frame_interval_ms: i64 = 16;
pub const idle_wait_ms: i64 = 30_000;
const watchdog_budget_ms: u64 = 33;
const watchdog_budget_ns: u64 = watchdog_budget_ms * std.time.ns_per_ms;
const notice_key_todo: tui.notify.Key = 90_000;

pub const Loop = struct {
    allocator: std.mem.Allocator,
    terminal: *tui.Terminal,
    engine: *coding_agent.Engine,
    input_reader: *input_reader_mod.InputReader,
    worker: *worker_mod.Worker,
    engine_wake_fds: [2]std.c.fd_t,
    reader_cursor: vm.ReaderCursor = .{},
    view_cursor: view_diff.ViewCursor = .{},
    render_due_ms: i64 = 0,
    last_render_cost_ns: u64 = 0,
    next_request_id: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        terminal: *tui.Terminal,
        engine: *coding_agent.Engine,
        input_reader: *input_reader_mod.InputReader,
        worker: *worker_mod.Worker,
    ) !Loop {
        const engine_wake_fds = try createPipe();
        errdefer closePipe(engine_wake_fds);
        try engine.attachReaderWakeFd(engine_wake_fds[1]);
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .engine = engine,
            .input_reader = input_reader,
            .worker = worker,
            .engine_wake_fds = engine_wake_fds,
        };
    }

    pub fn deinit(self: *Loop) void {
        self.reader_cursor.deinit(self.allocator);
        self.view_cursor.deinit(self.allocator);
        closePipe(self.engine_wake_fds);
        self.* = undefined;
    }

    pub fn run(self: *Loop) !void {
        try self.input_reader.start(self.terminal.inputFd());
        defer self.input_reader.stop();
        self.render_due_ms = nowMs();
        while (self.terminal.isRunning()) try self.step();
    }

    pub fn step(self: *Loop) !void {
        var watchdog: FrameWatchdog = .{};
        watchdog.begin(nowNs());
        defer watchdog.assertWithinBudget(nowNs());

        const now = nowMs();
        const timeout = pollTimeoutMs(now, self.terminal.nextDeadlineMs(), self.render_due_ms);
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = self.input_reader.wakeFd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.engine_wake_fds[0], .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.worker.wakeFd(), .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = try std.posix.poll(&poll_fds, timeout);
        if (hasReadable(poll_fds[0].revents)) self.input_reader.drainWakeFd();
        if (hasReadable(poll_fds[1].revents)) drainPipe(self.engine_wake_fds[0]);
        if (hasReadable(poll_fds[2].revents)) self.worker.drainWakeFd();

        try self.drainInput();
        try self.drainOneWorkerResult();
        try self.sampleViewModel();
        _ = try self.applyCommand(.{ .tick = .{ .now_ms = nowMs() } });
        if (try self.terminal.drainPendingResize()) self.render_due_ms = nowMs();
        try self.renderIfDue(nowMs());
    }

    fn drainInput(self: *Loop) !void {
        var bytes: [input_reader_mod.drain_chunk_bytes_max]u8 = undefined;
        while (self.input_reader.hasQueuedBytes() or self.input_reader.hasTerminalFact()) {
            const drained = self.input_reader.drain(&bytes);
            if (drained.bytes.len > 0) {
                var effects: [tui.Terminal.effects_per_read_max]tui.App.Effect = undefined;
                const result = try self.terminal.applyInputBytes(drained.bytes, &effects);
                if (result.priority != .none) self.render_due_ms = nowMs();
                try self.dispatchEffects(effects[0..result.effect_count]);
            }
            if (drained.eof) self.terminal.requestStop();
            if (drained.faulted) try self.notice("terminal input reader failed");
            if (drained.bytes.len == 0) break;
        }
    }

    fn dispatchEffects(self: *Loop, effects: []tui.App.Effect) !void {
        for (effects) |effect| {
            defer effect.deinit(self.allocator);
            try self.dispatchEffect(effect);
        }
    }

    fn dispatchEffect(self: *Loop, effect: tui.App.Effect) !void {
        switch (effect) {
            .submit_text => |text| {
                var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(
                    self.allocator,
                    self.nextRequestId(),
                    text,
                    .auto,
                );
                errdefer envelope.deinit(self.allocator);
                self.engine.submit(envelope) catch |err| {
                    envelope.deinit(self.allocator);
                    try self.notice(@errorName(err));
                };
            },
            .interrupt => self.submitSimple(.{ .cancel = .{} }) catch |err| try self.notice(@errorName(err)),
            .request_shutdown => {
                self.engine.requestShutdown();
                self.terminal.requestStop();
            },
            .request_clipboard_image_paste,
            .request_copy_selection,
            .request_transcript_history,
            .request_transcript_tail,
            .edit_composer_external,
            .picker_selected,
            .key_binding_triggered,
            => try self.notice("TODO: frame loop run B effect wiring"),
        }
    }

    fn submitSimple(self: *Loop, command: client_protocol.ClientCommand) !void {
        var envelope: client_protocol.CommandEnvelope = .{ .id = self.nextRequestId(), .command = command };
        errdefer envelope.deinit(self.allocator);
        self.engine.submit(envelope) catch |err| {
            envelope.deinit(self.allocator);
            return err;
        };
    }

    fn drainOneWorkerResult(self: *Loop) !void {
        var envelope = self.worker.drain() orelse return;
        defer envelope.deinit(self.allocator);
        switch (envelope) {
            .err => |err| try self.notice(workerErrorText(err)),
            .ok => |result| switch (result) {
                .clipboard_copy => |payload| {
                    if (payload.native_copied) {
                        try self.notice("selection copied");
                    } else {
                        self.terminal.copyTextWithOsc52(payload.text) catch {
                            try self.notice("clipboard copy failed");
                            return;
                        };
                        try self.notice("selection copied via terminal clipboard");
                    }
                },
                .clipboard_image_paste => |payload| {
                    const marker = try std.fmt.allocPrint(self.allocator, "@{s}", .{payload.path});
                    defer self.allocator.free(marker);
                    _ = try self.applyCommand(.{ .insert_composer_paste_marker = marker });
                },
                .prompt_attachments => |payload| {
                    var command = try client_protocol.CommandEnvelope.initSubmitPromptWithImages(
                        self.allocator,
                        self.nextRequestId(),
                        payload.prompt,
                        payload.attachments.images(),
                        .auto,
                    );
                    errdefer command.deinit(self.allocator);
                    self.engine.submit(command) catch |err| {
                        command.deinit(self.allocator);
                        try self.notice(@errorName(err));
                    };
                },
            },
        }
    }

    fn sampleViewModel(self: *Loop) !void {
        var sample = try self.engine.viewModel().sample(
            self.allocator,
            &self.reader_cursor,
            vm.sample_bytes_per_frame_max,
        );
        defer sample.deinit(self.allocator);
        if (sample.generation == self.view_cursor.generation and
            sample.session_epoch == self.view_cursor.epoch and
            !sample.partial) return;
        var diff = try view_diff.diff(self.allocator, &sample, &self.view_cursor);
        defer diff.deinit(self.allocator);
        for (diff.commands.items) |command| try self.applyDiffCommand(command);
    }

    fn applyDiffCommand(self: *Loop, command: tui.Command) !void {
        _ = try self.applyCommand(command);
        freeDiffCommandScratch(self.allocator, command);
    }

    fn applyCommand(self: *Loop, command: tui.Command) !?tui.App.Effect {
        const maybe_effect = try self.terminal.applyCommand(command);
        if (maybe_effect) |effect| {
            var single = [_]tui.App.Effect{effect};
            try self.dispatchEffects(&single);
        }
        return null;
    }

    fn renderIfDue(self: *Loop, now_ms: i64) !void {
        if (!self.terminal.isDirty() or now_ms < self.render_due_ms) return;
        if (try self.terminal.renderIfDirtyTimed(false)) |timing| {
            self.last_render_cost_ns = timing.draw_ns + timing.flush_ns;
            self.render_due_ms = nextRenderDueMs(now_ms, self.last_render_cost_ns);
        }
    }

    fn notice(self: *Loop, message: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .notify = .{
            .key = notice_key_todo,
            .message = message,
            .level = .warning,
            .skip_dedup = true,
        } });
        self.render_due_ms = nowMs();
    }

    fn nextRequestId(self: *Loop) client_protocol.RequestId {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        return id;
    }
};

pub const FrameWatchdog = struct {
    start_ns: i128 = 0,

    pub fn begin(self: *FrameWatchdog, ns: i128) void {
        self.start_ns = ns;
    }

    pub fn elapsedNs(self: *const FrameWatchdog, ns: i128) u64 {
        std.debug.assert(ns >= self.start_ns);
        return @intCast(ns - self.start_ns);
    }

    pub fn assertWithinBudget(self: *const FrameWatchdog, ns: i128) void {
        if (builtin.mode != .Debug) return;
        std.debug.assert(self.elapsedNs(ns) <= watchdog_budget_ns);
    }
};

pub fn pollTimeoutMs(now_ms: i64, app_deadline_ms: ?i64, render_due_ms: i64) i32 {
    var deadline = now_ms + idle_wait_ms;
    if (app_deadline_ms) |app_deadline| deadline = @min(deadline, app_deadline);
    deadline = @min(deadline, render_due_ms);
    const delta = @max(@as(i64, 0), deadline - now_ms);
    return @intCast(@min(delta, std.math.maxInt(i32)));
}

pub fn nextRenderDueMs(now_ms: i64, last_render_cost_ns: u64) i64 {
    const render_ms: i64 = @intCast(last_render_cost_ns / std.time.ns_per_ms);
    return now_ms + @max(frame_interval_ms, render_ms * 3);
}

fn workerErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoImage => "clipboard has no image",
        error.UnsupportedFormat => "clipboard image format unsupported",
        error.ToolUnavailable => "clipboard image tool unavailable",
        error.ImageTooLarge => "clipboard image too large",
        error.Timeout => "clipboard image paste timed out",
        else => "frontend worker failed",
    };
}

fn freeDiffCommandScratch(allocator: std.mem.Allocator, command: tui.Command) void {
    switch (command) {
        .open_picker => |open| allocator.free(open.items),
        .set_file_completions => |open| allocator.free(open.items),
        else => {},
    }
}

fn hasReadable(revents: anytype) bool {
    const mask: @TypeOf(revents) = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
    return (revents & mask) != 0;
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn nowNs() i128 {
    return std.time.nanoTimestamp();
}

fn createPipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    return fds;
}

fn closePipe(fds: [2]std.c.fd_t) void {
    if (fds[0] >= 0) _ = std.c.close(fds[0]);
    if (fds[1] >= 0) _ = std.c.close(fds[1]);
}

fn drainPipe(fd: std.c.fd_t) void {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    while (true) {
        _ = std.posix.poll(&fds, 0) catch return;
        if ((fds[0].revents & std.posix.POLL.IN) == 0) return;
        var buf: [64]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return;
        if (n == 0 or n < buf.len) return;
        fds[0].revents = 0;
    }
}

test "frame loop deadline uses nearest app render or idle deadline" {
    try std.testing.expectEqual(@as(i32, 16), pollTimeoutMs(100, null, 116));
    try std.testing.expectEqual(@as(i32, 5), pollTimeoutMs(100, 105, 116));
    try std.testing.expectEqual(@as(i32, 0), pollTimeoutMs(100, 99, 116));
    try std.testing.expectEqual(@as(i32, 30_000), pollTimeoutMs(100, null, 100 + idle_wait_ms + 1));
}

test "frame loop render due backs off by cost" {
    try std.testing.expectEqual(@as(i64, 116), nextRenderDueMs(100, 1 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i64, 160), nextRenderDueMs(100, 20 * std.time.ns_per_ms));
}
