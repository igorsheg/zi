const std = @import("std");
const builtin = @import("builtin");

const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const runtime = @import("../../runtime/root.zig");
const tui = @import("../../tui/root.zig");
const input_reader_mod = @import("input_reader.zig");
const pickers = @import("pickers.zig");
const trace_mod = @import("trace.zig");
const view_diff = @import("view_diff.zig");
const worker_mod = @import("worker.zig");

const client_protocol = coding_agent.client_protocol;
const vm = coding_agent.view_model;

pub const frame_interval_ms: i64 = 16;
pub const idle_wait_ms: i64 = 30_000;
const watchdog_budget_ms: u64 = 17;
const watchdog_budget_ns: u64 = watchdog_budget_ms * std.time.ns_per_ms;
const input_bytes_per_iteration_max: usize = 4 * 1024;
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
    trace: trace_mod.Stats = .{},
    chrome: vm.Chrome = .{},
    history_oldest_entry_id: [vm.history_entry_id_bytes_max]u8 = undefined,
    history_oldest_entry_id_len: usize = 0,
    last_file_completion_query: std.ArrayList(u8) = .empty,
    external_editor_counter: usize = 0,

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
        self.last_file_completion_query.deinit(self.allocator);
        closePipe(self.engine_wake_fds);
        self.* = undefined;
    }

    pub fn bootstrap(self: *Loop, version: []const u8, resume_picker: bool, initial_prompt: ?[]const u8) !void {
        try self.installGreeter(version);
        try self.installSlashCompletions();
        _ = try self.terminal.applyCommand(pickers.installKeyBindingsCommand());
        if (resume_picker) {
            _ = try self.applyCommand(.{ .replace_composer_text = "/resume " });
            try self.requestCompletion(.resume_session);
        }
        if (initial_prompt) |prompt| try self.submitText(prompt);
        try self.terminal.renderIfDirty();
    }

    pub fn run(self: *Loop) !void {
        try self.input_reader.start(self.terminal.inputFd());
        defer self.input_reader.stop();
        self.render_due_ms = nowMs();
        while (self.terminal.isRunning()) try self.step();
    }

    pub fn step(self: *Loop) !void {
        const now = nowMs();
        const timeout = if (self.input_reader.hasQueuedBytes() or self.input_reader.hasTerminalFact())
            0
        else
            pollTimeoutMs(now, self.terminal.nextDeadlineMs(), self.render_due_ms);
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = self.input_reader.wakeFd(), .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.engine_wake_fds[0], .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.worker.wakeFd(), .events = std.posix.POLL.IN, .revents = 0 },
        };
        const wait_start = nowNs();
        _ = try std.posix.poll(&poll_fds, timeout);
        self.trace.record(.wait, @intCast(nowNs() - wait_start));
        if (hasReadable(poll_fds[0].revents)) self.input_reader.drainWakeFd();
        if (hasReadable(poll_fds[1].revents)) drainPipe(self.engine_wake_fds[0]);
        if (hasReadable(poll_fds[2].revents)) self.worker.drainWakeFd();

        var watchdog: FrameWatchdog = .{};
        watchdog.begin(nowNs());
        defer watchdog.assertWithinBudget(nowNs());
        try self.serviceOnce();
    }

    fn installGreeter(self: *Loop, version: []const u8) !void {
        var title: [tui.Greeter.text_bytes_max]u8 = undefined;
        const title_text = std.fmt.bufPrint(&title, "zi {s}", .{version}) catch "zi";
        _ = try self.terminal.applyCommand(.{ .set_greeter = .{
            .title = title_text,
            .subtitle = "Type / for commands. Ask zi about zi if you get lost.",
        } });
    }

    fn installSlashCompletions(self: *Loop) !void {
        var items: [coding_agent.slash_commands.command_count_max]tui.Picker.Item = undefined;
        var labels: [coding_agent.slash_commands.command_count_max][1 + coding_agent.slash_commands.name_bytes_max]u8 = undefined;
        for (coding_agent.slash_commands.builtins, 0..) |command, index| {
            labels[index][0] = '/';
            @memcpy(labels[index][1..][0..command.name.len], command.name);
            items[index] = .{
                .id = command.name,
                .label = labels[index][0 .. 1 + command.name.len],
                .detail = command.summary,
            };
        }
        _ = try self.terminal.applyCommand(.{ .set_composer_completions = .{
            .id = pickers.command_completion_picker_id,
            .items = items[0..coding_agent.slash_commands.builtins.len],
        } });
    }

    pub fn serviceOnce(self: *Loop) !void {
        var phase_start = nowNs();
        try self.drainInput();
        self.trace.record(.input_drain, @intCast(nowNs() - phase_start));
        try self.drainOneWorkerResult();
        try self.sampleViewModel();
        const tick_ms = nowMs();
        phase_start = nowNs();
        _ = try self.applyCommand(.{ .tick = .{ .now_ms = tick_ms } });
        try self.tickToolDurations(tick_ms);
        self.trace.record(.tick, @intCast(nowNs() - phase_start));
        if (try self.terminal.drainPendingResize()) self.render_due_ms = nowMs();
        try self.renderIfDue(nowMs());
    }

    fn drainInput(self: *Loop) !void {
        var bytes: [input_reader_mod.drain_chunk_bytes_max]u8 = undefined;
        var processed: usize = 0;
        while (processed < input_bytes_per_iteration_max and
            (self.input_reader.hasQueuedBytes() or self.input_reader.hasTerminalFact()))
        {
            const limit = @min(bytes.len, input_bytes_per_iteration_max - processed);
            const drained = self.input_reader.drain(bytes[0..limit]);
            if (drained.bytes.len > 0) {
                var effects: [tui.Terminal.effects_per_read_max]tui.App.Effect = undefined;
                const result = try self.terminal.applyInputBytes(drained.bytes, &effects);
                processed += drained.bytes.len;
                if (result.priority != .none) self.render_due_ms = nowMs();
                try self.dispatchEffects(effects[0..result.effect_count]);
                try self.requestFileCompletionForComposer();
                if (result.truncated) try self.notice("input truncated");
                if (result.effect_overflow) try self.notice("input effects dropped");
            }
            if (drained.eof) self.terminal.requestStop();
            if (drained.faulted) try self.notice("input reader stopped");
            if (drained.bytes.len == 0) break;
        }
        if (self.input_reader.hasQueuedBytes()) self.render_due_ms = nowMs();
    }

    fn dispatchEffects(self: *Loop, effects: []tui.App.Effect) !void {
        for (effects) |effect| {
            defer effect.deinit(self.allocator);
            try self.dispatchEffect(effect);
        }
    }

    fn dispatchEffect(self: *Loop, effect: tui.App.Effect) !void {
        switch (effect) {
            .submit_text => |text| try self.submitText(text),
            .interrupt => self.submitSimple(.{ .cancel = .{} }) catch |err| try self.notice(submitErrorText(err)),
            .request_shutdown => {
                self.engine.requestShutdown();
                self.terminal.requestStop();
            },
            .request_clipboard_image_paste => try self.spawnClipboardImagePaste(),
            .request_copy_selection => try self.spawnCopySelection(),
            .request_transcript_history => try self.requestHistoryPage(),
            .request_transcript_tail => try self.requestTranscriptTail(),
            .edit_composer_external => |text| try self.editComposerExternal(text),
            .picker_selected => |selection| try self.handlePickerSelection(selection),
            .key_binding_triggered => |id| try self.handleKeyBinding(id),
        }
    }

    fn submitText(self: *Loop, text: []const u8) !void {
        switch (pickers.bareCommand(text)) {
            .model => {
                _ = try self.applyCommand(.{ .replace_composer_text = "/model " });
                try self.requestCompletion(.model);
                return;
            },
            .resume_session => {
                _ = try self.applyCommand(.{ .replace_composer_text = "/resume " });
                try self.requestCompletion(.resume_session);
                return;
            },
            .settings => {
                var items: [2]tui.Picker.Item = undefined;
                _ = try self.applyCommand(pickers.settingsCommand(&items, self.chrome));
                return;
            },
            .none => {},
        }
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        self.worker.spawn(.prompt_attachments, .{ .prompt_attachments = owned }) catch |err| switch (err) {
            error.Busy => {
                try self.notice("clipboard operation already running");
                return;
            },
            else => return err,
        };
    }

    fn requestCompletion(self: *Loop, kind: vm.CompletionSlot.Kind) !void {
        const query_id = pickers.commandQueryId(kind);
        self.view_cursor.noteCompletionQuery(query_id, kind);
        try self.submitSimpleWithId(query_id, .completion_snapshot);
    }

    fn requestFileCompletionForComposer(self: *Loop) !void {
        const raw_query = self.terminal.activeFileCompletionQuery() orelse {
            self.last_file_completion_query.clearRetainingCapacity();
            return;
        };
        const query = tui.text.utf8Prefix(raw_query, client_protocol.file_completion_query_bytes_max);
        if (std.mem.eql(u8, query, self.last_file_completion_query.items)) return;
        self.last_file_completion_query.clearRetainingCapacity();
        try self.last_file_completion_query.appendSlice(self.allocator, query);
        const query_id = pickers.commandQueryId(.file);
        self.view_cursor.noteCompletionQuery(query_id, .file);
        var envelope = try client_protocol.CommandEnvelope.initFileCompletion(self.allocator, query_id, query);
        errdefer envelope.deinit(self.allocator);
        self.engine.submit(envelope) catch |err| {
            envelope.deinit(self.allocator);
            try self.notice(submitErrorText(err));
        };
    }

    fn spawnClipboardImagePaste(self: *Loop) !void {
        self.worker.spawn(.clipboard_image_paste, .clipboard_image_paste) catch |err| switch (err) {
            error.Busy => return self.notice("clipboard operation already running"),
            else => return err,
        };
    }

    fn spawnCopySelection(self: *Loop) !void {
        const selected = try self.terminal.selectedText();
        switch (selected) {
            .empty => try self.notice("no selection to copy"),
            .too_large => try self.notice("selection too large to copy"),
            .text => |text| self.worker.spawn(.clipboard_copy, .{ .clipboard_copy = text }) catch |err| switch (err) {
                error.Busy => {
                    self.allocator.free(text);
                    return self.notice("clipboard operation already running");
                },
                else => {
                    self.allocator.free(text);
                    return err;
                },
            },
        }
    }

    fn requestHistoryPage(self: *Loop) !void {
        const before = if (self.history_oldest_entry_id_len > 0)
            self.history_oldest_entry_id[0..self.history_oldest_entry_id_len]
        else
            self.terminal.transcriptOldestSourceId() orelse "";
        if (before.len == 0) return;
        var envelope = try client_protocol.CommandEnvelope.initHistoryPage(
            self.allocator,
            self.nextRequestId(),
            before,
        );
        errdefer envelope.deinit(self.allocator);
        self.engine.submit(envelope) catch |err| {
            envelope.deinit(self.allocator);
            try self.notice(submitErrorText(err));
        };
    }

    fn requestTranscriptTail(self: *Loop) !void {
        if (!self.view_cursor.history_open) return;
        try self.submitSimple(.history_tail);
        self.reader_cursor.resetTranscript();
        self.view_cursor.resetTranscript();
        self.history_oldest_entry_id_len = 0;
        _ = try self.applyCommand(.clear_transcript);
    }

    fn handlePickerSelection(self: *Loop, selection: tui.Picker.Selection) !void {
        switch (selection.picker_id) {
            pickers.model_picker_id => {
                var buffer: [tui.Picker.id_bytes_max + 8]u8 = undefined;
                const prompt = pickers.modelSelectionPrompt(&buffer, selection.item_id) orelse return;
                try self.submitText(prompt);
            },
            pickers.resume_picker_id => {
                var envelope = try client_protocol.CommandEnvelope.initSwitchSession(
                    self.allocator,
                    self.nextRequestId(),
                    selection.item_id,
                );
                errdefer envelope.deinit(self.allocator);
                self.engine.submit(envelope) catch |err| {
                    envelope.deinit(self.allocator);
                    try self.notice(submitErrorText(err));
                };
            },
            pickers.settings_picker_id => {
                if (std.mem.eql(u8, selection.item_id, "open:thinking")) {
                    var items: [6]tui.Picker.Item = undefined;
                    _ = try self.applyCommand(pickers.thinkingCommand(&items, self.chrome.thinking_level));
                    return;
                }
                var buffer: [64]u8 = undefined;
                const prompt = pickers.settingsSelectionPrompt(&buffer, selection.item_id) orelse return;
                try self.submitText(prompt);
            },
            pickers.settings_thinking_picker_id => {
                var buffer: [64]u8 = undefined;
                const prompt = pickers.settingsSelectionPrompt(&buffer, selection.item_id) orelse return;
                try self.submitText(prompt);
            },
            else => {},
        }
    }

    fn handleKeyBinding(self: *Loop, id: tui.keybind.Id) !void {
        switch (id) {
            pickers.binding_open_model_picker => {
                _ = try self.applyCommand(.{ .replace_composer_text = "/model " });
                try self.requestCompletion(.model);
            },
            else => {},
        }
    }

    fn submitSimple(self: *Loop, command: client_protocol.ClientCommand) !void {
        try self.submitSimpleWithId(self.nextRequestId(), command);
    }

    fn submitSimpleWithId(self: *Loop, id: client_protocol.RequestId, command: client_protocol.ClientCommand) !void {
        var envelope: client_protocol.CommandEnvelope = .{ .id = id, .command = command };
        errdefer envelope.deinit(self.allocator);
        self.engine.submit(envelope) catch |err| {
            envelope.deinit(self.allocator);
            return err;
        };
    }

    const EditorRead = struct {
        bytes: []u8,
        len: usize,
        truncated: bool,

        fn slice(self: *const EditorRead) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    fn editComposerExternal(self: *Loop, text: []const u8) !void {
        const path = self.createEditorTempFile(text) catch |err| {
            try self.editorError("could not create editor temp file", err);
            return;
        };
        defer self.allocator.free(path);
        defer std.Io.Dir.deleteFileAbsolute(self.terminal.io, path) catch {};

        self.input_reader.stop();
        self.terminal.suspendForExternalProgram() catch |err| {
            try self.editorError("could not suspend terminal", err);
            try self.input_reader.start(self.terminal.inputFd());
            return;
        };
        const term = self.runEditor(path);
        try self.terminal.resumeAfterExternalProgramCommandPath();
        _ = try self.terminal.applyCommand(.force_redraw);
        self.render_due_ms = nowMs();
        self.input_reader.start(self.terminal.inputFd()) catch |err| {
            try self.editorError("could not restart terminal input", err);
            return;
        };

        const completed = term catch |err| {
            try self.editorError("editor failed", err);
            return;
        };
        if (!editorExitedSuccessfully(completed)) {
            try self.notice("editor exited nonzero; composer unchanged");
            return;
        }

        const edited = self.readEditorTempFile(path) catch |err| {
            try self.editorError("could not read editor temp file", err);
            return;
        };
        defer self.allocator.free(edited.bytes);
        _ = try self.applyCommand(.{ .replace_composer_text = edited.slice() });
        if (edited.truncated) try self.notice("editor input too large: pasted prefix only");
    }

    fn createEditorTempFile(self: *Loop, text: []const u8) ![]u8 {
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            self.external_editor_counter +%= 1;
            const stamp = std.Io.Clock.awake.now(self.terminal.io).nanoseconds;
            var name_buffer: [96]u8 = undefined;
            const name = std.fmt.bufPrint(
                &name_buffer,
                "zi-composer-{d}-{d}.md",
                .{ stamp, self.external_editor_counter },
            ) catch unreachable;
            const path = try std.fs.path.join(self.allocator, &.{ self.worker.tmp_dir, name });
            errdefer self.allocator.free(path);

            var file = std.Io.Dir.createFileAbsolute(self.terminal.io, path, .{
                .read = true,
                .exclusive = true,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    self.allocator.free(path);
                    continue;
                },
                else => return err,
            };
            defer file.close(self.terminal.io);

            var write_buffer: [4096]u8 = undefined;
            var writer = file.writer(self.terminal.io, &write_buffer);
            try writer.interface.writeAll(text);
            try writer.flush();
            return path;
        }
        return error.PathAlreadyExists;
    }

    fn readEditorTempFile(self: *Loop, path: []const u8) !EditorRead {
        var file = try std.Io.Dir.openFileAbsolute(self.terminal.io, path, .{});
        defer file.close(self.terminal.io);
        const read_limit = tui.Composer.buffer_size_bytes_max + 3;
        const file_len = try file.length(self.terminal.io);
        const read_len: usize = @intCast(@min(file_len, @as(u64, read_limit)));
        const bytes = try self.allocator.alloc(u8, read_len);
        errdefer self.allocator.free(bytes);
        const len = try file.readPositionalAll(self.terminal.io, bytes, 0);
        return .{ .bytes = bytes, .len = len, .truncated = file_len > read_limit };
    }

    fn runEditor(self: *Loop, path: []const u8) !std.process.Child.Term {
        const fallbacks = [_][]const u8{ "nvim", "vim", "nano" };
        for (fallbacks) |editor| {
            const argv = [_][]const u8{ editor, path };
            return self.spawnAndWait(&argv) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
        }
        return error.FileNotFound;
    }

    fn spawnAndWait(self: *Loop, argv: []const []const u8) !std.process.Child.Term {
        var child = try std.process.spawn(self.terminal.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        return child.wait(self.terminal.io);
    }

    fn editorExitedSuccessfully(term: std.process.Child.Term) bool {
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn editorError(self: *Loop, message: []const u8, err: anyerror) !void {
        var buffer: [tui.status.text_bytes_max]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ message, @errorName(err) }) catch message;
        try self.notice(text);
    }

    fn drainOneWorkerResult(self: *Loop) !void {
        var envelope = self.worker.drain() orelse return;
        defer envelope.deinit(self.allocator);
        switch (envelope) {
            .err => |err| try self.notice(workerErrorText(err)),
            .ok => |result| switch (result) {
                .clipboard_copy => |payload| {
                    if (payload.native_copied) {
                        try self.noticeLevel(.info, "selection copied");
                    } else {
                        self.terminal.copyTextWithOsc52(payload.text) catch {
                            try self.notice("clipboard copy failed");
                            return;
                        };
                        try self.noticeLevel(.info, "selection copied via terminal clipboard");
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
                        try self.notice(submitErrorText(err));
                    };
                },
            },
        }
    }

    fn sampleViewModel(self: *Loop) !void {
        var phase_start = nowNs();
        var sample = try self.engine.viewModel().sample(
            self.allocator,
            &self.reader_cursor,
            vm.sample_bytes_per_frame_max,
        );
        self.trace.record(.sample, @intCast(nowNs() - phase_start));
        defer sample.deinit(self.allocator);
        self.chrome = sample.chrome;
        if (sample.history) |*history| {
            const oldest = history.oldest_entry_id.slice();
            @memcpy(self.history_oldest_entry_id[0..oldest.len], oldest);
            self.history_oldest_entry_id_len = oldest.len;
        }
        if (sample.generation == self.view_cursor.generation and
            sample.session_epoch == self.view_cursor.epoch and
            !sample.partial) return;
        phase_start = nowNs();
        var diff = try view_diff.diff(self.allocator, &sample, &self.view_cursor);
        defer diff.deinit(self.allocator);
        for (diff.commands.items) |command| try self.applyDiffCommand(command);
        self.trace.record(.diff_apply, @intCast(nowNs() - phase_start));
    }

    fn tickToolDurations(self: *Loop, now_ms: i64) !void {
        var commands = try view_diff.tickDurations(self.allocator, &self.view_cursor, now_ms);
        defer commands.deinit(self.allocator);
        for (commands.commands.items) |command| try self.applyDiffCommand(command);
    }

    fn applyDiffCommand(self: *Loop, command: tui.Command) !void {
        _ = try self.applyCommand(command);
        freeDiffCommandScratch(self.allocator, command);
    }

    fn applyCommand(self: *Loop, command: tui.Command) !?tui.App.Effect {
        const maybe_effect = try self.terminal.applyCommand(command);
        if (maybe_effect) |effect| effect.deinit(self.allocator);
        return null;
    }

    fn renderIfDue(self: *Loop, now_ms: i64) !void {
        if (!self.terminal.isDirty() or now_ms < self.render_due_ms) return;
        if (try self.terminal.renderIfDirtyTimed(false)) |timing| {
            self.trace.record(.draw, timing.draw_ns);
            self.trace.record(.flush, timing.flush_ns);
            self.last_render_cost_ns = timing.draw_ns + timing.flush_ns;
            self.render_due_ms = nextRenderDueMs(now_ms, self.last_render_cost_ns);
        }
    }

    fn notice(self: *Loop, message: []const u8) !void {
        try self.noticeLevel(.warning, message);
    }

    fn noticeLevel(self: *Loop, level: tui.notify.Level, message: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .notify = .{
            .key = notice_key_todo,
            .message = message,
            .level = level,
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

fn submitErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.Full => "command queue full",
        else => @errorName(err),
    };
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
        .set_composer_completions => |open| allocator.free(open.items),
        .set_composer_arg_completions => |open| allocator.free(open.picker.items),
        else => {},
    }
}

fn hasReadable(revents: anytype) bool {
    const mask: @TypeOf(revents) = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;
    return (revents & mask) != 0;
}

fn nowMs() i64 {
    return @intCast(@divFloor(nowNs(), std.time.ns_per_ms));
}

fn nowNs() i128 {
    var timespec: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &timespec);
    if (std.posix.errno(rc) != .SUCCESS) return 0;
    return @as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec;
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

const TestLoop = struct {
    tmp: std.testing.TmpDir,
    provider: *ai.FauxProvider,
    engine: *coding_agent.Engine,
    terminal: *tui.Terminal,
    wake: runtime.WakeEvent = .init,
    input_reader: *input_reader_mod.InputReader,
    worker: *worker_mod.Worker,
    loop: Loop,

    fn init(reply: []const u8) !TestLoop {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "agent");
        try tmp.dir.createDirPath(std.testing.io, "repo/.zi");

        const provider = try std.testing.allocator.create(ai.FauxProvider);
        errdefer std.testing.allocator.destroy(provider);
        provider.* = try ai.FauxProvider.init(std.testing.allocator, .{ .min_token_size = 512, .max_token_size = 512 });
        errdefer provider.deinit();
        const content = [_]ai.AssistantContent{ai.faux.text(reply)};
        const message = ai.faux.assistantMessage(&content, .{});
        try provider.setResponses(&.{message});

        const engine = try coding_agent.Engine.start(std.testing.allocator, null, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .current_date = "2026-07-04",
            .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-07-04T00:00:00Z" } },
            .dir = tmp.dir,
            .stream = provider.apiProvider().stream,
        });
        errdefer {
            engine.requestShutdown();
            engine.join();
        }

        const terminal = try tui.Terminal.init(std.testing.allocator, std.testing.io, 80, 24, .{});
        errdefer terminal.deinit();
        var wake: runtime.WakeEvent = .init;
        const input_reader = try input_reader_mod.InputReader.init(std.testing.allocator, std.testing.io, std.testing.io, &wake);
        errdefer input_reader.deinit();
        const worker = try std.testing.allocator.create(worker_mod.Worker);
        errdefer std.testing.allocator.destroy(worker);
        worker.* = try worker_mod.Worker.init(std.testing.allocator, null, null, "/tmp");
        errdefer worker.deinit();
        var loop = try Loop.init(std.testing.allocator, terminal, engine, input_reader, worker);
        loop.render_due_ms = std.math.maxInt(i64);
        return .{
            .tmp = tmp,
            .provider = provider,
            .engine = engine,
            .terminal = terminal,
            .wake = wake,
            .input_reader = input_reader,
            .worker = worker,
            .loop = loop,
        };
    }

    fn deinit(self: *TestLoop) void {
        self.loop.deinit();
        self.worker.deinit();
        std.testing.allocator.destroy(self.worker);
        self.input_reader.deinit();
        self.terminal.deinit();
        self.engine.requestShutdown();
        self.engine.join();
        self.provider.deinit();
        std.testing.allocator.destroy(self.provider);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn submitPromptForTest(engine: *coding_agent.Engine, text: []const u8) !void {
    var envelope = try client_protocol.CommandEnvelope.initSubmitPrompt(engine.allocator, 1, text, .auto);
    errdefer envelope.deinit(engine.allocator);
    try engine.submit(envelope);
}

fn engineAssistantFinal(engine: *coding_agent.Engine) !bool {
    var cursor: vm.ReaderCursor = .{};
    defer cursor.deinit(std.testing.allocator);
    var sample = try engine.viewModel().sample(std.testing.allocator, &cursor, vm.sample_bytes_per_frame_max);
    defer sample.deinit(std.testing.allocator);
    for (sample.items.items) |item| {
        if (item.kind == .assistant and item.state == .final) return true;
    }
    return false;
}

test "frame loop samples assistant flood within 17ms and echoes input" {
    const gpa = std.testing.allocator;
    const flood = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(flood);
    @memset(flood, 'x');
    // Realistic prose has line breaks; an unbroken 64KiB line defeats the
    // stable-prefix wrap cache and is tracked as a separate known cost
    // (docs/parity-audit.md backlog: incremental wrap for unbroken lines).
    var nl: usize = 63;
    while (nl < flood.len) : (nl += 64) flood[nl] = '\n';

    var fixture = try TestLoop.init(flood);
    defer fixture.deinit();
    try submitPromptForTest(fixture.engine, "flood");

    var echoed = false;
    var max_ns: u64 = 0;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        if (i == 4) {
            var effects: [tui.Terminal.effects_per_read_max]tui.App.Effect = undefined;
            const result = try fixture.terminal.applyInputBytes("z", &effects);
            try fixture.loop.dispatchEffects(effects[0..result.effect_count]);
        }
        const start = nowNs();
        try fixture.loop.serviceOnce();
        const elapsed: u64 = @intCast(nowNs() - start);
        max_ns = @max(max_ns, elapsed);
        try std.testing.expect(elapsed <= watchdog_budget_ns);
        if (std.mem.eql(u8, fixture.terminal.composerText(), "z")) echoed = true;
        if (echoed and try engineAssistantFinal(fixture.engine)) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(echoed);
    try std.testing.expect(max_ns <= watchdog_budget_ns);
    try std.testing.expect(i < 4000);
}
