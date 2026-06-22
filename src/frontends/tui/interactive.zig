//! Concrete coding-agent TUI frontend: owns the wake loop, translates
//! ClientEvents into agent-agnostic tui Commands, and feeds tui Effects back
//! as session commands. This is the only module that knows both vocabularies.
const std = @import("std");

const agent_mod = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../../coding_agent/root.zig");
const client_protocol = coding_agent.client_protocol;
const clipboard_image = @import("clipboard_image.zig");
const slash_commands = coding_agent.slash_commands;
const session_listing = coding_agent.session_listing;
const session_runtime = coding_agent.session_runtime;
const runtime = @import("../../runtime/root.zig");
const tui = @import("../../tui/root.zig");
const tool_view = @import("tool_view.zig");

pub const StartupAction = enum {
    none,
    resume_picker,
};

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    session_selector: ?[]const u8 = null,
    continue_latest: bool = false,
    startup_action: StartupAction = .none,
    initial_prompt: ?[]const u8 = null,
    version: []const u8 = "0.0.0-local",
};

/// Frame pacing: 16ms while something animates (shimmer, tool timers run
/// under an active operation's shimmer), otherwise a slow heartbeat. Session
/// and input wakes interrupt either; an idle zi must not spin.
const frame_interval_ms: u64 = 16;
const idle_frame_interval_ms: u64 = 30_000;

const effect_count_max = tui.Terminal.effects_per_read_max;
const client_events_per_tick_max = 64;
const status_id_working: tui.status.ContributionId = 1;
const status_id_queue: tui.status.ContributionId = 2;
const status_id_recovery: tui.status.ContributionId = 3;
const status_id_completion: tui.status.ContributionId = 4;
const notify_key_cancel: tui.notify.Key = 1;
const notify_key_recovery: tui.notify.Key = 2;
const retry_reason_bytes_max: usize = 64;
const composer_cwd_slot_id: tui.status.ContributionId = 1;
const composer_session_slot_id: tui.status.ContributionId = 2;
const model_picker_id: tui.Picker.Id = 1;
const command_completion_picker_id: tui.Picker.Id = 2;
const resume_picker_id: tui.Picker.Id = 3;
const file_picker_id: tui.Picker.Id = 4;
const transcript_append_max = tui.Transcript.append_size_bytes_max;
const clipboard_image_attachment_count_max = client_protocol.submit_image_count_max;
const tool_timer_count_max = 8;
const tool_timer_id_bytes_max = 96;

fn nextWakeDelayMs(immediate_work_pending: bool, animation_active: bool) u64 {
    if (immediate_work_pending) return 0;
    return if (animation_active) frame_interval_ms else idle_frame_interval_ms;
}

fn canRequestHistoryPage(history_request_in_flight: bool, history_has_more_before: bool) bool {
    return !history_request_in_flight and history_has_more_before;
}

fn nonEmptyEnv(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (std.mem.trim(u8, text, " \t\r\n").len == 0) null else text;
}

fn isPromptPathByte(byte: u8) bool {
    return switch (byte) {
        0...32, '"', '\'', '<', '>' => false,
        else => true,
    };
}

fn isZiClipboardImagePath(path: []const u8) bool {
    const leaf = std.fs.path.basename(path);
    return std.mem.startsWith(u8, leaf, "zi-clipboard-") and mimeTypeForImagePath(path) != null;
}

fn mimeTypeForImagePath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    return null;
}

fn resolveTerminalInfo(process: runtime.Process) tui.theme.TerminalInfo {
    return .{
        .scheme = if (process.env("ZI_THEME_LIGHT") != null) .light else null,
        .color_level = resolveColorLevel(process),
    };
}

fn resolveColorLevel(process: runtime.Process) tui.theme.ColorLevel {
    if (process.env("COLORTERM")) |value| {
        if (std.mem.indexOf(u8, value, "truecolor") != null) return .truecolor;
        if (std.mem.indexOf(u8, value, "24bit") != null) return .truecolor;
    }
    if (process.env("TERM")) |value| {
        if (std.mem.indexOf(u8, value, "256color") != null) return .ansi256;
    }
    return .unknown;
}

const ToolTimer = struct {
    id: [tool_timer_id_bytes_max]u8 = undefined,
    id_len: u8,
    started_ms: i64,
    footer_elapsed_s: u64 = 0,
};

fn ignoreBestEffortError(err: anyerror) void {
    std.debug.assert(@errorName(err).len > 0);
}

const SubmitResult = enum { queued, queue_full };

const EventCursor = struct {
    last_seq: client_protocol.EventSeq = 0,
    recovery: Recovery = .live,

    const Recovery = enum { live, snapshot_requested };
};

const RenderThrottle = struct {
    next_render_ms: i64 = 0,
    force: bool = true,

    fn requestImmediate(self: *RenderThrottle) void {
        self.force = true;
    }

    fn shouldRender(self: *RenderThrottle, now_ms: i64, coalesce: bool) bool {
        if (!self.force and coalesce and now_ms < self.next_render_ms) return false;
        self.force = false;
        self.next_render_ms = now_ms + @as(i64, @intCast(frame_interval_ms));
        return true;
    }
};

pub fn run(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    const stamp = session_runtime.SessionStamp.now(process.io);
    var app = if (try selectResumeSession(process, stderr, options)) |session_file| blk: {
        defer process.gpa.free(session_file);
        break :blk try session_runtime.openSessionRuntime(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = stamp.date(),
            .open = .{ .resume_existing = .{ .session_file_name = session_file } },
            .dir = options.dir,
            .environ = options.environ,
        });
    } else blk: {
        var session_id_buffer: [48]u8 = undefined;
        const session_id = std.fmt.bufPrint(&session_id_buffer, "tui-{d}", .{stamp.nanoseconds}) catch
            unreachable;
        break :blk try session_runtime.openSessionRuntime(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = stamp.date(),
            .open = .{ .create = .{ .session_id = session_id, .timestamp = stamp.timestamp() } },
            .dir = options.dir,
            .environ = options.environ,
        });
    };
    defer app.deinit();

    var controller = try InteractiveController.init(
        process,
        &app,
        stdout,
        stderr,
        options.startup_action,
        options.initial_prompt,
        options.version,
    );
    defer controller.deinit();
    try controller.run();
}

const InteractiveController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app: *session_runtime.SessionRuntime,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    terminal: *tui.Terminal,
    cancel_requested: bool = false,
    operation_active: bool = false,
    history_oldest_entry_id: ?[]u8 = null,
    history_has_more_before: bool = false,
    history_request_in_flight: bool = false,
    completion_snapshot_requested: bool = false,
    completion_snapshot_loaded: bool = false,
    last_file_completion_query: std.ArrayList(u8) = .empty,
    last_file_completion_query_active: bool = false,
    event_cursor: EventCursor = .{},
    assistant_text_delta_seen: bool = false,
    render_throttle: RenderThrottle = .{},
    tool_timers: [tool_timer_count_max]?ToolTimer = @splat(null),
    home_dir: ?[]const u8 = null,
    editor: ?[]const u8 = null,
    tmp_dir: []const u8 = "/tmp",
    external_editor_counter: u64 = 0,

    fn init(
        process: runtime.Process,
        app: *session_runtime.SessionRuntime,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        startup_action: StartupAction,
        initial_prompt: ?[]const u8,
        version: []const u8,
    ) !InteractiveController {
        const terminal_info = resolveTerminalInfo(process);
        const terminal = try tui.Terminal.init(process.gpa, process.io, 80, 24, terminal_info);
        errdefer terminal.deinit();
        try terminal.setup();
        errdefer terminal.shutdown() catch |err| ignoreBestEffortError(err);

        var self: InteractiveController = .{
            .allocator = process.gpa,
            .io = process.io,
            .app = app,
            .stdout = stdout,
            .stderr = stderr,
            .terminal = terminal,
            .home_dir = process.env("HOME") orelse process.env("USERPROFILE"),
            .editor = nonEmptyEnv(process.env("EDITOR")),
            .tmp_dir = nonEmptyEnv(process.env("TMPDIR")) orelse
                nonEmptyEnv(process.env("TEMP")) orelse
                nonEmptyEnv(process.env("TMP")) orelse
                "/tmp",
        };
        try self.installGreeter(version);
        try self.installSlashCompletions();
        try self.requestSnapshot();
        try self.applyStartupAction(startup_action);
        if (initial_prompt) |prompt| try self.submitPrompt(prompt);
        try self.terminal.renderIfDirty();
        return self;
    }

    fn applyStartupAction(self: *InteractiveController, action: StartupAction) !void {
        switch (action) {
            .none => {},
            .resume_picker => try self.editResumeCommand(),
        }
    }

    fn deinit(self: *InteractiveController) void {
        if (self.history_oldest_entry_id) |id| self.allocator.free(id);
        self.last_file_completion_query.deinit(self.allocator);
        self.terminal.shutdown() catch |err| ignoreBestEffortError(err);
        self.terminal.deinit();
        self.* = undefined;
    }

    fn run(self: *InteractiveController) !void {
        while (self.terminal.isRunning()) {
            const immediate = try self.serviceImmediateWork();
            if (!self.terminal.isRunning()) break;

            const frame_active = self.terminal.hasAnimation() or (self.operation_active and self.terminal.isDirty());
            const wake_delay = self.clampWakeDelayToDeadline(nextWakeDelayMs(immediate, frame_active));
            const wake = try self.app.waitAndApplyWake(
                self.terminal.inputFd(),
                wake_delay,
            );
            // Time enters the product through ticks; refresh before handling
            // the wake so wall-clock policies (ctrl+c double press, shimmer)
            // never see stale time after a long idle wait.
            _ = try self.tickTime();
            switch (wake) {
                .input => try self.drainInput(),
                .session, .frame => {},
            }
            if (try self.terminal.drainPendingResize()) self.render_throttle.requestImmediate();
        }
    }

    fn serviceImmediateWork(self: *InteractiveController) !bool {
        try self.app.step();
        const drained = try self.drainClientEventsBounded(client_events_per_tick_max);
        const now_ms = try self.tickTime();
        try self.renderIfDue(now_ms);
        return drained == client_events_per_tick_max or self.app.hasImmediateWork();
    }

    fn renderIfDue(self: *InteractiveController, now_ms: i64) !void {
        if (!self.terminal.isDirty()) return;
        if (!self.render_throttle.shouldRender(now_ms, self.operation_active)) return;
        try self.terminal.renderIfDirty();
    }

    fn clampWakeDelayToDeadline(self: *InteractiveController, delay_ms: u64) u64 {
        const deadline = self.terminal.nextDeadlineMs() orelse return delay_ms;
        const now_ms = self.nowMs();
        if (deadline <= now_ms) return 0;
        return @min(delay_ms, @as(u64, @intCast(deadline - now_ms)));
    }

    fn drainInput(self: *InteractiveController) !void {
        var effects: [effect_count_max]tui.Effect = undefined;
        const result = try self.terminal.readAvailableInput(&effects);
        defer for (effects[0..result.effect_count]) |effect| effect.deinit(self.allocator);
        for (effects[0..result.effect_count]) |effect| try self.handleEffect(effect);
        try self.requestLazyCompletionSnapshot();
        try self.requestFileCompletionForComposer();
        if (result.event_count > 0) self.render_throttle.requestImmediate();
        if (result.truncated) try self.appendStatus(.warning, "input truncated");
        if (result.effect_overflow) try self.appendStatus(.warning, "input effects dropped");
    }

    fn handleEffect(self: *InteractiveController, effect: tui.Effect) !void {
        switch (effect) {
            .submit_text => |text| if (!try self.handleSubmittedCommand(text)) try self.submitPrompt(text),
            .edit_composer_external => |text| try self.editComposerExternal(text),
            .picker_selected => |selection| try self.handlePickerSelection(selection),
            .request_clipboard_image_paste => try self.handleClipboardImagePaste(),
            .interrupt => try self.cancelActive(),
            .request_transcript_history => try self.requestHistoryPage(),
            .request_shutdown => {
                if (try self.submitCommand(.{ .command = .shutdown }) == .queued) {
                    self.terminal.requestStop();
                }
            },
        }
    }

    const EditorRead = struct {
        bytes: []u8,
        len: usize,
        truncated: bool,

        fn slice(self: *const EditorRead) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    fn handleClipboardImagePaste(self: *InteractiveController) !void {
        var image = clipboard_image.read(
            self.allocator,
            self.io,
            self.app.task_runtime,
            self.app.services.environ,
        ) catch |err| {
            try self.appendClipboardImageError(err);
            return;
        };
        defer image.deinit(self.allocator);

        const path = self.createClipboardImageTempFile(&image) catch |err| {
            try self.appendClipboardImageError(err);
            return;
        };
        defer self.allocator.free(path);

        const payload = try std.fmt.allocPrint(self.allocator, "@{s}", .{path});
        defer self.allocator.free(payload);
        _ = try self.terminal.applyCommand(.{ .insert_composer_paste_marker = payload });
    }

    fn createClipboardImageTempFile(self: *InteractiveController, image: *const clipboard_image.ClipboardImage) ![]u8 {
        const ext = clipboard_image.extensionForMimeType(image.mime_type) orelse return error.UnsupportedFormat;
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            self.external_editor_counter +%= 1;
            const stamp = std.Io.Clock.awake.now(self.io).nanoseconds;
            var name_buffer: [96]u8 = undefined;
            const name = std.fmt.bufPrint(
                &name_buffer,
                "zi-clipboard-{d}-{d}.{s}",
                .{ stamp, self.external_editor_counter, ext },
            ) catch unreachable;
            const path = try std.fs.path.join(self.allocator, &.{ self.tmp_dir, name });
            errdefer self.allocator.free(path);

            var file = std.Io.Dir.createFileAbsolute(self.io, path, .{
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
            defer file.close(self.io);

            var write_buffer: [4096]u8 = undefined;
            var writer = file.writer(self.io, &write_buffer);
            try writer.interface.writeAll(image.bytes);
            try writer.flush();
            return path;
        }
        return error.PathAlreadyExists;
    }

    fn appendClipboardImageError(self: *InteractiveController, err: anyerror) !void {
        const message: []const u8 = switch (err) {
            error.NoImage => "clipboard has no image",
            error.UnsupportedFormat => "clipboard image format unsupported",
            error.ToolUnavailable => "clipboard image tool unavailable",
            error.ImageTooLarge => "clipboard image too large",
            error.Timeout => "clipboard image paste timed out",
            else => "could not paste clipboard image",
        };
        try self.appendStatus(.warning, message);
    }

    fn editComposerExternal(self: *InteractiveController, text: []const u8) !void {
        const path = self.createEditorTempFile(text) catch |err| {
            try self.appendEditorError("could not create editor temp file", err);
            return;
        };
        defer self.allocator.free(path);
        defer std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};

        self.terminal.suspendForExternalProgram() catch |err| {
            try self.appendEditorError("could not suspend terminal", err);
            return;
        };
        const term = self.runEditor(path);
        try self.terminal.resumeAfterExternalProgram();

        const completed = term catch |err| {
            try self.appendEditorError("editor failed", err);
            return;
        };
        if (!editorExitedSuccessfully(completed)) {
            try self.appendStatus(.warning, "editor exited nonzero; composer unchanged");
            return;
        }

        const edited = self.readEditorTempFile(path) catch |err| {
            try self.appendEditorError("could not read editor temp file", err);
            return;
        };
        defer self.allocator.free(edited.bytes);
        _ = try self.terminal.applyCommand(.{ .replace_composer_text = edited.slice() });
        if (edited.truncated) try self.appendStatus(.warning, "editor input too large: pasted prefix only");
    }

    fn createEditorTempFile(self: *InteractiveController, text: []const u8) ![]u8 {
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            self.external_editor_counter +%= 1;
            const stamp = std.Io.Clock.awake.now(self.io).nanoseconds;
            var name_buffer: [96]u8 = undefined;
            const name = std.fmt.bufPrint(
                &name_buffer,
                "zi-composer-{d}-{d}.md",
                .{ stamp, self.external_editor_counter },
            ) catch unreachable;
            const path = try std.fs.path.join(self.allocator, &.{ self.tmp_dir, name });
            errdefer self.allocator.free(path);

            var file = std.Io.Dir.createFileAbsolute(self.io, path, .{
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
            defer file.close(self.io);

            var write_buffer: [4096]u8 = undefined;
            var writer = file.writer(self.io, &write_buffer);
            try writer.interface.writeAll(text);
            try writer.flush();
            return path;
        }
        return error.PathAlreadyExists;
    }

    fn readEditorTempFile(self: *InteractiveController, path: []const u8) !EditorRead {
        var file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        const read_limit = tui.Composer.buffer_size_bytes_max + 3;
        const file_len = try file.length(self.io);
        const read_len: usize = @intCast(@min(file_len, @as(u64, read_limit)));
        const bytes = try self.allocator.alloc(u8, read_len);
        errdefer self.allocator.free(bytes);
        const len = try file.readPositionalAll(self.io, bytes, 0);
        return .{ .bytes = bytes, .len = len, .truncated = file_len > read_limit };
    }

    fn runEditor(self: *InteractiveController, path: []const u8) !std.process.Child.Term {
        if (self.editor) |editor| {
            const argv = [_][]const u8{ "/bin/sh", "-c", "exec $1 \"$2\"", "zi-editor", editor, path };
            return self.spawnAndWait(&argv);
        }

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

    fn spawnAndWait(self: *InteractiveController, argv: []const []const u8) !std.process.Child.Term {
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        return child.wait(self.io);
    }

    fn editorExitedSuccessfully(term: std.process.Child.Term) bool {
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn appendEditorError(self: *InteractiveController, message: []const u8, err: anyerror) !void {
        var buffer: [tui.status.text_bytes_max]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ message, @errorName(err) }) catch message;
        try self.appendStatus(.warning, text);
    }

    fn handleSubmittedCommand(self: *InteractiveController, text: []const u8) !bool {
        if (isBareResumeCommand(text)) {
            try self.editResumeCommand();
            return true;
        }
        if (isBareModelCommand(text)) {
            try self.editModelCommand();
            return true;
        }
        return false;
    }

    fn handlePickerSelection(self: *InteractiveController, selection: tui.Picker.Selection) !void {
        switch (selection.picker_id) {
            model_picker_id => try self.submitSelectedModel(selection.item_id),
            resume_picker_id => try self.submitSelectedSession(selection.item_id),
            else => {},
        }
    }

    fn submitSelectedModel(self: *InteractiveController, item_id: []const u8) !void {
        var buffer: [tui.Picker.id_bytes_max + 8]u8 = undefined;
        const prompt = std.fmt.bufPrint(&buffer, "/model {s}", .{item_id}) catch return;
        try self.submitPrompt(prompt);
    }

    fn submitSelectedSession(self: *InteractiveController, item_id: []const u8) !void {
        const envelope = try client_protocol.CommandEnvelope.initSwitchSession(self.allocator, null, item_id);
        _ = try self.submitCommand(envelope);
    }

    fn editModelCommand(self: *InteractiveController) !void {
        _ = try self.terminal.applyCommand(.{ .replace_composer_text = "/model " });
        try self.requestCompletionSnapshot();
    }

    fn editResumeCommand(self: *InteractiveController) !void {
        _ = try self.terminal.applyCommand(.{ .replace_composer_text = "/resume " });
        try self.requestCompletionSnapshot();
    }

    fn installGreeter(self: *InteractiveController, version: []const u8) !void {
        var title: [tui.Greeter.text_bytes_max]u8 = undefined;
        const title_text = std.fmt.bufPrint(&title, "zi {s}", .{version}) catch "zi";
        _ = try self.terminal.applyCommand(.{ .set_greeter = .{
            .title = title_text,
            .subtitle = "Type / for commands. Ask zi about zi if you get lost.",
        } });
    }

    fn applyCompletionSnapshot(self: *InteractiveController, snapshot: client_protocol.CompletionSnapshot) !void {
        self.completion_snapshot_requested = false;
        self.completion_snapshot_loaded = true;
        try self.clearStatus(status_id_completion);
        try self.installModelCompletions(snapshot.models);
        try self.installResumeCompletions(snapshot.resume_sessions);
    }

    fn installModelCompletions(self: *InteractiveController, list: client_protocol.CompletionList) !void {
        var items: [client_protocol.completion_item_count_max]tui.Picker.Item = undefined;
        const mapped = completionPickerItems(&items, list);
        _ = try self.terminal.applyCommand(.{ .set_composer_arg_completions = .{
            .command_name = "model",
            .picker = .{
                .id = model_picker_id,
                .items = mapped,
            },
        } });
    }

    fn installResumeCompletions(self: *InteractiveController, list: client_protocol.CompletionList) !void {
        var items: [client_protocol.completion_item_count_max]tui.Picker.Item = undefined;
        const mapped = completionPickerItems(&items, list);
        _ = try self.terminal.applyCommand(.{ .set_composer_arg_completions = .{
            .command_name = "resume",
            .accept = .emit_selection,
            .picker = .{
                .id = resume_picker_id,
                .items = mapped,
                .search_detail = true,
                .layout = .four_column,
            },
        } });
    }

    fn installFileCompletions(self: *InteractiveController, result: client_protocol.FileCompletionResult) !void {
        if (!self.last_file_completion_query_active) return;
        if (!std.mem.eql(u8, result.query.text, self.last_file_completion_query.items)) return;
        var items: [client_protocol.completion_item_count_max]tui.Picker.Item = undefined;
        const mapped = completionPickerItems(&items, result.items);
        _ = try self.terminal.applyCommand(.{ .set_file_completions = .{
            .id = file_picker_id,
            .items = mapped,
            .search_detail = true,
            .layout = .two_column,
            .truncated = result.items.truncated,
            .min_visible_rows = 4,
        } });
    }

    fn installSlashCompletions(self: *InteractiveController) !void {
        var items: [slash_commands.command_count_max]tui.Picker.Item = undefined;
        var labels: [slash_commands.command_count_max][1 + slash_commands.name_bytes_max]u8 = undefined;
        for (slash_commands.builtins, 0..) |command, index| {
            labels[index][0] = '/';
            @memcpy(labels[index][1..][0..command.name.len], command.name);
            items[index] = .{
                .id = command.name,
                .label = labels[index][0 .. 1 + command.name.len],
                .detail = command.summary,
            };
        }
        _ = try self.terminal.applyCommand(.{ .set_composer_completions = .{
            .id = command_completion_picker_id,
            .items = items[0..slash_commands.builtins.len],
        } });
    }

    fn submitPrompt(self: *InteractiveController, prompt: []const u8) !void {
        var attachments = try self.clipboardImageAttachmentsFromPrompt(prompt);
        defer PromptImageAttachments.deinit(self.allocator, &attachments);
        const envelope = try client_protocol.CommandEnvelope.initSubmitPromptWithImages(
            self.allocator,
            null,
            prompt,
            attachments.images(),
            .auto,
        );
        if (try self.submitCommand(envelope) == .queued) self.cancel_requested = false;
    }

    const PromptImageAttachments = struct {
        list: std.ArrayList(ai.ImageContent) = .empty,

        fn images(self: *const PromptImageAttachments) []const ai.ImageContent {
            return self.list.items;
        }

        fn deinit(allocator: std.mem.Allocator, self: *PromptImageAttachments) void {
            for (self.list.items) |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            }
            self.list.deinit(allocator);
            self.* = undefined;
        }
    };

    fn clipboardImageAttachmentsFromPrompt(self: *InteractiveController, prompt: []const u8) !PromptImageAttachments {
        var attachments: PromptImageAttachments = .{};
        errdefer PromptImageAttachments.deinit(self.allocator, &attachments);
        var index: usize = 0;
        while (index < prompt.len and attachments.list.items.len < clipboard_image_attachment_count_max) {
            const at = std.mem.indexOfScalarPos(u8, prompt, index, '@') orelse break;
            index = at + 1;
            const path_start = index;
            while (index < prompt.len and isPromptPathByte(prompt[index])) : (index += 1) {}
            if (index == path_start) continue;
            const path = prompt[path_start..index];
            if (!isZiClipboardImagePath(path)) continue;
            try attachments.list.append(self.allocator, try self.readPromptImageAttachment(path));
        }
        return attachments;
    }

    fn readPromptImageAttachment(self: *InteractiveController, path: []const u8) !ai.ImageContent {
        const mime_type = mimeTypeForImagePath(path) orelse return error.UnsupportedFormat;
        var file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        const file_len = try file.length(self.io);
        if (file_len == 0) return error.NoImage;
        if (file_len > client_protocol.submit_image_data_bytes_max) return error.ImageTooLarge;
        const raw = try self.allocator.alloc(u8, @intCast(file_len));
        defer self.allocator.free(raw);
        const read_len = try file.readPositionalAll(self.io, raw, 0);
        if (read_len != raw.len) return error.ShortRead;

        const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        errdefer self.allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, raw);
        const mime = try self.allocator.dupe(u8, mime_type);
        errdefer self.allocator.free(mime);
        return .{ .data = encoded, .mime_type = mime };
    }

    fn cancelActive(self: *InteractiveController) !void {
        if (self.cancel_requested) return;
        if (try self.submitCommand(.{ .command = .{ .cancel = .{} } }) == .queued) {
            self.cancel_requested = true;
            try self.appendKeyedStatusWithTone(notify_key_cancel, .info, "cancel requested", .canceled);
        }
    }

    fn requestSnapshot(self: *InteractiveController) !void {
        _ = try self.submitCommand(.{ .command = .snapshot });
    }

    fn requestCompletionSnapshot(self: *InteractiveController) !void {
        if (self.completion_snapshot_requested or self.completion_snapshot_loaded) return;
        if (try self.submitCommand(.{ .command = .completion_snapshot }) == .queued) {
            self.completion_snapshot_requested = true;
            try self.setCompletionStatus();
        }
    }

    fn requestLazyCompletionSnapshot(self: *InteractiveController) !void {
        if (!needsLazyCompletionSnapshot(self.terminal.composerText())) return;
        try self.requestCompletionSnapshot();
    }

    fn requestFileCompletionForComposer(self: *InteractiveController) !void {
        const raw_query = self.terminal.activeFileCompletionQuery() orelse {
            self.last_file_completion_query_active = false;
            self.last_file_completion_query.clearRetainingCapacity();
            return;
        };
        const query = tui.text.utf8Prefix(raw_query, client_protocol.file_completion_query_bytes_max);
        if (self.last_file_completion_query_active and
            std.mem.eql(u8, query, self.last_file_completion_query.items)) return;
        self.last_file_completion_query_active = true;
        self.last_file_completion_query.clearRetainingCapacity();
        try self.last_file_completion_query.appendSlice(self.allocator, query);
        const envelope = try client_protocol.CommandEnvelope.initFileCompletion(self.allocator, null, query);
        _ = try self.submitCommand(envelope);
    }

    fn requestHistoryPage(self: *InteractiveController) !void {
        if (!canRequestHistoryPage(self.history_request_in_flight, self.history_has_more_before)) return;
        const before_entry_id = self.history_oldest_entry_id orelse return self.requestSnapshot();
        const envelope = try client_protocol.CommandEnvelope.initHistoryPage(self.allocator, null, before_entry_id);
        if (try self.submitCommand(envelope) == .queued) self.history_request_in_flight = true;
    }

    fn submitCommand(self: *InteractiveController, envelope: client_protocol.CommandEnvelope) !SubmitResult {
        var owned = envelope;
        self.app.submit(owned) catch |err| switch (err) {
            error.Full => {
                owned.deinit(self.allocator);
                try self.appendStatus(.err, "command queue full");
                return .queue_full;
            },
        };
        return .queued;
    }

    fn drainClientEventsBounded(self: *InteractiveController, limit: usize) !usize {
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            var envelope = self.app.drainEvent() orelse return count;
            defer envelope.deinit(self.allocator);
            try self.acceptEnvelope(envelope);
        }
        return count;
    }

    fn acceptEnvelope(self: *InteractiveController, envelope: client_protocol.EventEnvelope) !void {
        if (envelope.event == .snapshot) {
            self.event_cursor.last_seq = envelope.seq;
            self.event_cursor.recovery = .live;
            try self.clearStatus(status_id_recovery);
            try self.clearNotify(notify_key_recovery);
            try self.applyClientEvent(envelope.event);
            return;
        }

        if (self.event_cursor.recovery != .live) {
            switch (envelope.event) {
                .replay => {
                    self.event_cursor.last_seq = envelope.seq;
                    self.event_cursor.recovery = .snapshot_requested;
                    try self.appendKeyedStatusWithTone(
                        notify_key_recovery,
                        .warning,
                        "replay requires snapshot in TUI adapter",
                        .warning,
                    );
                    try self.requestSnapshot();
                },
                .replay_gap => {
                    self.event_cursor.last_seq = envelope.seq;
                    self.event_cursor.recovery = .snapshot_requested;
                    try self.appendKeyedStatusWithTone(
                        notify_key_recovery,
                        .warning,
                        "replay gap; requesting snapshot",
                        .warning,
                    );
                    try self.requestSnapshot();
                },
                else => {},
            }
            return;
        }

        const expected = self.event_cursor.last_seq + 1;
        if (envelope.seq != expected) {
            self.event_cursor.recovery = .snapshot_requested;
            try self.setRecoveryStatus("recovering event gap");
            try self.appendKeyedStatusWithTone(notify_key_recovery, .warning, "recovering event gap", .warning);
            try self.requestSnapshot();
            return;
        }
        self.event_cursor.last_seq = envelope.seq;
        try self.applyClientEvent(envelope.event);
    }

    fn applyClientEvent(self: *InteractiveController, event: client_protocol.ClientEvent) !void {
        switch (event) {
            .agent_event => |payload| try self.applyAgentEvent(payload.event),
            .operation_started => {
                self.operation_active = true;
                try self.setWorkingStatus("working");
            },
            .operation_finished => |finished| {
                self.operation_active = false;
                try self.applyOperationFinished(finished);
            },
            .rejected => |rejection| {
                self.history_request_in_flight = false;
                if (self.completion_snapshot_requested) {
                    self.completion_snapshot_requested = false;
                    self.completion_snapshot_loaded = false;
                    try self.clearStatus(status_id_completion);
                }
                var buffer: [tui.status.text_bytes_max]u8 = undefined;
                try self.appendStatus(.err, formatRejectionMessage(&buffer, rejection));
            },
            .prompt_command => |command| {
                switch (command.presentation) {
                    .transcript => if (command.session_info) |info|
                        try self.appendSessionInfo(info)
                    else
                        try self.appendCustom("Command", command.message.text, .markdown),
                    .status => try self.appendStatus(
                        if (command.result == .handled) .info else .warning,
                        command.message.text,
                    ),
                }
            },
            .queue_changed => |queue| try self.applyQueueChanged(queue),
            .snapshot => |snapshot| try self.applySnapshot(snapshot),
            .completion_snapshot => |snapshot| try self.applyCompletionSnapshot(snapshot),
            .file_completion => |result| try self.installFileCompletions(result),
            .session_changed => try self.applySessionChanged(),
            .session_chrome => |chrome| try self.applySessionChrome(chrome),
            .history_page => |page| try self.applyHistoryPage(page),
            .replay => {
                self.event_cursor.recovery = .snapshot_requested;
                try self.appendKeyedStatusWithTone(
                    notify_key_recovery,
                    .warning,
                    "replay requires snapshot in TUI adapter",
                    .warning,
                );
                try self.requestSnapshot();
            },
            .replay_gap => {
                self.event_cursor.recovery = .snapshot_requested;
                try self.appendKeyedStatusWithTone(
                    notify_key_recovery,
                    .warning,
                    "replay gap; requesting snapshot",
                    .warning,
                );
                try self.requestSnapshot();
            },
            .shutdown_started => self.terminal.requestStop(),
            .compaction_start => try self.setWorkingStatus("compacting"),
            .compaction_end => |payload| try self.applyCompactionEnd(payload),
            .auto_retry_start => |payload| {
                var buffer: [tui.status.text_bytes_max]u8 = undefined;
                try self.setWorkingStatus(formatRetryStatus(&buffer, payload));
            },
            .auto_retry_end => try self.clearStatus(status_id_working),
            .event_overflow => |overflow| {
                var buffer: [96]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &buffer,
                    "event overflow: dropped {d}",
                    .{overflow.dropped_count},
                ) catch "event overflow";
                try self.appendKeyedStatusWithTone(notify_key_recovery, .warning, text, .warning);
                self.event_cursor.recovery = .snapshot_requested;
                try self.requestSnapshot();
            },
        }
    }

    fn applyAgentEvent(self: *InteractiveController, event: agent_mod.AgentEvent) !void {
        switch (event) {
            .message_start => |payload| {
                if (payload.message == .assistant) self.assistant_text_delta_seen = false;
            },
            .message_update => |payload| try self.applyMessageUpdate(payload),
            .message_end => |payload| try self.applyMessageEnd(payload.message),
            .tool_execution_start => |payload| try self.applyToolStart(payload),
            .tool_execution_update => |payload| try self.applyToolUpdate(payload),
            .tool_execution_end => |payload| try self.applyToolEnd(payload),
            .agent_start, .agent_end, .turn_end => {},
            .turn_start => self.assistant_text_delta_seen = false,
        }
    }

    fn applyMessageUpdate(self: *InteractiveController, update: agent_mod.AgentEvent.MessageUpdate) !void {
        switch (update.assistant_message_event) {
            .text_delta => |payload| {
                self.assistant_text_delta_seen = true;
                try self.appendMessage(.assistant, payload.delta, .extend_previous_assistant_message);
            },
            .thinking_delta => |payload| try self.appendMessage(.thinking, payload.delta, .extend_previous_same_role),
            .toolcall_start => |payload| try self.applyToolCallPreview(payload.content_index, payload.partial),
            .toolcall_delta => |payload| try self.applyToolCallPreview(payload.content_index, payload.partial),
            .toolcall_end => |payload| try self.applyToolCall(payload.tool_call),
            else => {},
        }
    }

    fn applyMessageEnd(self: *InteractiveController, message: agent_mod.AgentMessage) !void {
        switch (message) {
            .user => |user| if (userText(user)) |text| try self.appendMessage(.user, text, .new_item),
            .assistant => |assistant| {
                if (assistant.error_message) |message_text| {
                    if (!self.cancel_requested) try self.appendStatus(.err, message_text);
                }
                if (!self.assistant_text_delta_seen) try self.appendAssistantFinalText(assistant);
                self.assistant_text_delta_seen = false;
            },
            .tool_result => {},
            .custom => {},
        }
    }

    fn applyToolCallPreview(self: *InteractiveController, content_index: usize, partial: ai.AssistantMessage) !void {
        if (content_index >= partial.content.len) return;
        const content = partial.content[content_index];
        if (content != .tool_call) return;
        try self.applyToolCall(content.tool_call);
    }

    fn applyToolCall(self: *InteractiveController, tool_call: ai.ToolCall) !void {
        var buffers: tool_view.TitleBuffers = .{};
        try self.appendTool(tool_view.callAppend(&buffers, tool_call, self.home_dir));
        if (tool_view.callPreviewText(tool_call.name, tool_call.arguments)) |preview| {
            try self.replaceToolOutput(tool_call.id, preview);
            var footer_buffer: [tool_view.footer_bytes_max]u8 = undefined;
            try self.replaceToolFooter(
                tool_call.id,
                tool_view.callPreviewFooter(&footer_buffer, tool_call.name, tool_call.arguments),
            );
        }
    }

    fn applyToolStart(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionStart) !void {
        var buffers: tool_view.TitleBuffers = .{};
        try self.appendTool(tool_view.startAppend(&buffers, payload, self.home_dir));
        if (tool_view.clearsCallPreviewOnStart(payload.tool_name)) {
            try self.replaceToolOutput(payload.tool_call_id, "");
            try self.replaceToolFooter(payload.tool_call_id, "");
        }
        if (tool_view.showsDuration(payload.tool_name)) self.startToolTimer(payload.tool_call_id);
    }

    fn applyToolUpdate(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
        const text = tool_view.firstResultText(payload.partial_result.content) orelse return;
        try self.appendToolOutput(payload.tool_call_id, text);
    }

    fn applyToolEnd(self: *InteractiveController, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
        var metadata_buffer: [tool_view.metadata_bytes_max]u8 = undefined;
        var view = try tool_view.finish(self.allocator, &metadata_buffer, payload);
        defer view.deinit(self.allocator);

        try self.appendTool(tool_view.endAppend(payload));

        var duration_buffer: [64]u8 = undefined;
        const duration = self.finishToolTimer(payload.tool_call_id, &duration_buffer) orelse "";
        var footer_buffer: [tool_view.footer_bytes_max]u8 = undefined;
        const footer = tool_view.joinMetadata(&footer_buffer, view.metadata, duration);
        if (footer.len > 0) {
            try self.replaceToolFooter(payload.tool_call_id, footer);
        } else if (payload.is_error) {
            try self.replaceToolFooter(payload.tool_call_id, "");
        }

        const text = view.output orelse return;
        try self.replaceToolOutput(payload.tool_call_id, text);
    }

    fn applySessionChanged(self: *InteractiveController) !void {
        self.operation_active = false;
        self.cancel_requested = false;
        self.history_request_in_flight = false;
        self.history_has_more_before = false;
        self.clearOldestHistoryEntryId();
        self.clearToolTimers();
        _ = try self.terminal.applyCommand(.clear_transcript);
        try self.clearStatus(status_id_working);
        try self.clearStatus(status_id_queue);
        try self.clearStatus(status_id_completion);
        _ = try self.terminal.applyCommand(.{ .clear_notify = .all });
        self.completion_snapshot_requested = false;
        self.completion_snapshot_loaded = false;
        try self.requestSnapshot();
        try self.appendStatus(.info, "resumed session");
    }

    fn applySnapshot(self: *InteractiveController, snapshot: client_protocol.Snapshot) !void {
        _ = try self.terminal.applyCommand(.clear_transcript);
        self.operation_active = snapshot.active_request_id != null;
        self.history_request_in_flight = false;
        // Snapshot history can be wider than the TUI resident item cap. Track
        // the oldest item the TUI will actually retain after append eviction,
        // otherwise the next page would skip the evicted snapshot prefix.
        const retained_start = snapshot.history.items.len -| tui.Transcript.item_count_max;
        self.history_has_more_before = snapshot.history.dropped_items > 0 or retained_start > 0;
        if (snapshot.history.items.len > 0) {
            try self.setOldestHistoryEntryId(snapshot.history.items[retained_start].entry_id.text);
        } else {
            self.clearOldestHistoryEntryId();
        }
        try self.applySessionChromeParts(
            snapshot.header.cwd.text,
            snapshot.model,
            snapshot.context,
        );
        for (snapshot.history.items) |item| try self.applyHistoryItem(item, .append);
        try self.applyQueueCounts(snapshot.queue.steering.items.len, snapshot.queue.follow_up.items.len);
    }

    fn applySessionChrome(self: *InteractiveController, chrome: client_protocol.SessionChromeSnapshot) !void {
        try self.applySessionChromeParts(
            chrome.cwd.text,
            chrome.model,
            chrome.context,
        );
    }

    fn applySessionChromeParts(
        self: *InteractiveController,
        cwd: []const u8,
        model: client_protocol.ModelSnapshot,
        context: client_protocol.ContextUsageSnapshot,
    ) !void {
        var left_buffer: [tui.status.text_bytes_max]u8 = undefined;
        var right_buffer: [tui.status.text_bytes_max]u8 = undefined;
        const resolved_dot_cwd = if (std.mem.eql(u8, cwd, "."))
            std.Io.Dir.realPathFileAlloc(.cwd(), self.io, ".", self.allocator) catch null
        else
            null;
        defer if (resolved_dot_cwd) |path| self.allocator.free(path);
        const cwd_text = formatComposerCwd(&left_buffer, resolved_dot_cwd orelse cwd, self.home_dir);
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .composer_left,
            .id = composer_cwd_slot_id,
            .priority = 1,
            .text = cwd_text,
        } });
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .composer_right,
            .id = composer_session_slot_id,
            .priority = 1,
            .text = formatComposerRight(&right_buffer, model, context),
        } });
    }

    fn applyHistoryPage(self: *InteractiveController, page: client_protocol.HistoryPage) !void {
        self.history_request_in_flight = false;
        self.history_has_more_before = page.has_more_before;
        if (page.items.len == 0) return;

        try self.setOldestHistoryEntryId(page.items[0].entry_id.text);
        var index = page.items.len;
        while (index > 0) {
            index -= 1;
            try self.applyHistoryItem(page.items[index], .prepend);
        }
    }

    const HistoryApplyDirection = enum { append, prepend };

    fn applyHistoryItem(
        self: *InteractiveController,
        item: client_protocol.HistorySnapshotItem,
        direction: HistoryApplyDirection,
    ) !void {
        switch (direction) {
            .append => try self.appendHistoryItem(item),
            .prepend => try self.prependHistoryItem(item),
        }
    }

    fn appendHistoryItem(self: *InteractiveController, item: client_protocol.HistorySnapshotItem) !void {
        switch (item.kind) {
            .user, .assistant, .system => {
                if (item.text.text.len > 0) {
                    try self.appendMessage(historyMessageRole(item.kind).?, item.text.text, .new_item);
                }
                if (item.kind == .assistant) {
                    for (item.tool_calls) |tool_call| {
                        var buffers: tool_view.TitleBuffers = .{};
                        try self.appendTool(try tool_view.historyCallAppend(
                            self.allocator,
                            &buffers,
                            tool_call,
                            self.home_dir,
                        ));
                    }
                }
            },
            .tool_result => {
                const id = if (item.tool_call_id) |id| id.text else return;
                const name = if (item.tool_name) |name| name.text else return;
                try self.appendTool(tool_view.append(
                    id,
                    name,
                    if (item.is_error) .err else .success,
                    "",
                    "",
                    item.is_error,
                ));
                var metadata_buffer: [tool_view.metadata_bytes_max]u8 = undefined;
                var view = try tool_view.historyFinish(
                    self.allocator,
                    &metadata_buffer,
                    name,
                    item.is_error,
                    item.text.text,
                    if (item.details_json) |json| json.text else null,
                );
                defer view.deinit(self.allocator);
                if (view.metadata.len > 0) try self.replaceToolFooter(id, view.metadata);
                if (view.output) |text| try self.replaceToolOutput(id, text);
            },
        }
    }

    fn prependHistoryItem(self: *InteractiveController, item: client_protocol.HistorySnapshotItem) !void {
        switch (item.kind) {
            .user, .system => try self.prependMessage(historyMessageRole(item.kind).?, item.text.text),
            .assistant => {
                var tools = std.ArrayList(tui.Transcript.Append.ToolAppend).empty;
                defer tools.deinit(self.allocator);
                var title_buffers = std.ArrayList(tool_view.TitleBuffers).empty;
                defer title_buffers.deinit(self.allocator);
                try tools.ensureTotalCapacity(self.allocator, item.tool_calls.len);
                try title_buffers.ensureTotalCapacity(self.allocator, item.tool_calls.len);
                for (item.tool_calls) |tool_call| {
                    title_buffers.appendAssumeCapacity(.{});
                    try tools.append(self.allocator, try tool_view.historyCallAppend(
                        self.allocator,
                        &title_buffers.items[title_buffers.items.len - 1],
                        tool_call,
                        self.home_dir,
                    ));
                }
                const message: ?tui.Transcript.Append.MessageAppend = if (item.text.text.len > 0) .{
                    .role = .assistant,
                    .text = item.text.text,
                    .mode = .new_item,
                } else null;
                _ = try self.terminal.applyCommand(.{ .prepend_transcript = .{
                    .message = message,
                    .tools = tools.items,
                } });
            },
            .tool_result => {
                const id = if (item.tool_call_id) |id| id.text else return;
                const name = if (item.tool_name) |name| name.text else return;
                _ = try self.terminal.applyCommand(.{ .prepend_transcript = .{ .tools = &.{
                    tool_view.append(
                        id,
                        name,
                        if (item.is_error) .err else .success,
                        "",
                        "",
                        item.is_error,
                    ),
                } } });
                var metadata_buffer: [tool_view.metadata_bytes_max]u8 = undefined;
                var view = try tool_view.historyFinish(
                    self.allocator,
                    &metadata_buffer,
                    name,
                    item.is_error,
                    item.text.text,
                    if (item.details_json) |json| json.text else null,
                );
                defer view.deinit(self.allocator);
                if (view.metadata.len > 0) {
                    _ = try self.terminal.applyCommand(.{ .replace_front_tool_footer = .{
                        .tool_call_id = id,
                        .text = view.metadata,
                    } });
                }
                if (view.output) |text| try self.replaceFrontToolOutput(id, text);
            },
        }
    }

    fn historyMessageRole(kind: client_protocol.HistorySnapshotItem.Kind) ?tui.Transcript.Role {
        return switch (kind) {
            .user => .user,
            .assistant => .assistant,
            .system => .system,
            .tool_result => null,
        };
    }

    fn setOldestHistoryEntryId(self: *InteractiveController, entry_id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, entry_id);
        if (self.history_oldest_entry_id) |old| self.allocator.free(old);
        self.history_oldest_entry_id = owned;
    }

    fn clearOldestHistoryEntryId(self: *InteractiveController) void {
        if (self.history_oldest_entry_id) |old| self.allocator.free(old);
        self.history_oldest_entry_id = null;
    }

    fn applyQueueChanged(self: *InteractiveController, queue: client_protocol.QueueChanged) !void {
        try self.applyQueueCounts(queue.steering_count, queue.follow_up_count);
    }

    fn applyQueueCounts(self: *InteractiveController, steering_count: usize, follow_up_count: usize) !void {
        if (steering_count == 0 and follow_up_count == 0) return self.clearStatus(status_id_queue);
        var buffer: [80]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "queued: {d} steering, {d} follow-up",
            .{ steering_count, follow_up_count },
        ) catch "queued prompts";
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_queue,
            .priority = 1,
            .text = text,
        } });
    }

    fn applyOperationFinished(self: *InteractiveController, finished: client_protocol.OperationFinished) !void {
        self.cancel_requested = false;
        self.clearToolTimers();
        switch (finished.reason) {
            .completed => try self.clearStatus(status_id_working),
            .canceled => {
                _ = try self.terminal.applyCommand(.mark_pending_tools_canceled);
                try self.clearStatus(status_id_working);
                try self.appendKeyedStatusWithTone(notify_key_cancel, .info, "canceled", .canceled);
            },
            .failed => try self.clearStatus(status_id_working),
        }
    }

    fn applyCompactionEnd(self: *InteractiveController, payload: client_protocol.CompactionEnd) !void {
        if (payload.error_message) |message| try self.appendStatus(.warning, message.text);
        if (payload.will_retry or self.operation_active) {
            try self.setWorkingStatus("working");
        } else {
            try self.clearStatus(status_id_working);
        }
    }

    /// Append in transcript-cap-sized chunks. Sanitization (invalid UTF-8,
    /// split codepoints) is the transcript's job; chunk boundaries fall back
    /// to raw bytes when no UTF-8 boundary exists in range.
    fn appendMessage(
        self: *InteractiveController,
        role: tui.Transcript.Role,
        text: []const u8,
        mode: tui.Transcript.AppendMode,
    ) !void {
        if (text.len == 0) return;
        var remaining = text;
        var chunk_mode = mode;
        while (remaining.len > 0) {
            const chunk = boundedChunk(remaining);
            _ = try self.terminal.applyCommand(.{ .append_transcript = .{ .message = .{
                .role = role,
                .text = chunk,
                .mode = chunk_mode,
            } } });
            remaining = remaining[chunk.len..];
            chunk_mode = .extend_previous_same_role;
        }
    }

    fn prependMessage(
        self: *InteractiveController,
        role: tui.Transcript.Role,
        text: []const u8,
    ) !void {
        if (text.len == 0) return;
        _ = try self.terminal.applyCommand(.{ .prepend_transcript = .{ .message = .{
            .role = role,
            .text = text,
            .mode = .new_item,
        } } });
    }

    fn appendAssistantFinalText(self: *InteractiveController, assistant: ai.AssistantMessage) !void {
        for (assistant.content) |content| switch (content) {
            .text => |text| try self.appendMessage(.assistant, text.text, .extend_previous_assistant_message),
            .thinking => |thinking| try self.appendMessage(.thinking, thinking.thinking, .extend_previous_same_role),
            .tool_call => {},
        };
    }

    fn appendTool(self: *InteractiveController, tool: tui.Transcript.Append.ToolAppend) !void {
        _ = try self.terminal.applyCommand(.{ .append_transcript = .{ .tool = tool } });
    }

    /// Final tool result replaces the streamed preview (pi-mono semantics):
    /// the first normalized chunk overwrites, remaining chunks append.
    fn replaceToolOutput(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        var buffer: [transcript_append_max]u8 = undefined;
        const first = tool_view.normalizedOutputChunk(&buffer, text);
        _ = try self.terminal.applyCommand(.{ .replace_tool_output = .{
            .tool_call_id = tool_call_id,
            .text = first.text,
        } });
        try self.appendToolOutput(tool_call_id, text[first.consumed..]);
    }

    fn replaceFrontToolOutput(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        var buffer: [transcript_append_max]u8 = undefined;
        const first = tool_view.normalizedOutputChunk(&buffer, text);
        _ = try self.terminal.applyCommand(.{ .replace_front_tool_output = .{
            .tool_call_id = tool_call_id,
            .text = first.text,
        } });
        try self.appendFrontToolOutput(tool_call_id, text[first.consumed..]);
    }

    fn appendToolOutput(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        var remaining = text;
        while (remaining.len > 0) {
            var buffer: [transcript_append_max]u8 = undefined;
            const chunk = tool_view.normalizedOutputChunk(&buffer, remaining);
            if (chunk.consumed == 0) return;
            if (chunk.text.len > 0) {
                _ = try self.terminal.applyCommand(.{ .tool_output_delta = .{
                    .tool_call_id = tool_call_id,
                    .text = chunk.text,
                } });
            }
            remaining = remaining[chunk.consumed..];
        }
    }

    fn appendFrontToolOutput(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        var remaining = text;
        while (remaining.len > 0) {
            var buffer: [transcript_append_max]u8 = undefined;
            const chunk = tool_view.normalizedOutputChunk(&buffer, remaining);
            if (chunk.consumed == 0) return;
            if (chunk.text.len > 0) {
                _ = try self.terminal.applyCommand(.{ .front_tool_output_delta = .{
                    .tool_call_id = tool_call_id,
                    .text = chunk.text,
                } });
            }
            remaining = remaining[chunk.consumed..];
        }
    }

    fn appendStatus(
        self: *InteractiveController,
        level: tui.Transcript.StatusLevel,
        text: []const u8,
    ) !void {
        try self.appendStatusWithTone(level, text, switch (level) {
            .info => .accent,
            .warning => .warning,
            .err => .err,
        });
    }

    fn appendStatusWithTone(
        self: *InteractiveController,
        level: tui.Transcript.StatusLevel,
        text: []const u8,
        tone: tui.status.Tone,
    ) !void {
        try self.appendKeyedStatusWithTone(0, level, text, tone);
    }

    fn appendKeyedStatusWithTone(
        self: *InteractiveController,
        key: tui.notify.Key,
        level: tui.Transcript.StatusLevel,
        text: []const u8,
        tone: tui.status.Tone,
    ) !void {
        if (text.len == 0) return;
        _ = try self.terminal.applyCommand(.{ .notify = .{
            .key = key,
            .message = boundedChunk(text),
            .level = notifyLevel(level),
            .annote = notifyAnnote(level),
            .tone = tone,
        } });
    }

    fn appendSessionInfo(
        self: *InteractiveController,
        info: client_protocol.PromptCommandSessionInfo,
    ) !void {
        var buffer: [2048]u8 = undefined;
        try self.appendCustom("Session Info", formatSessionInfo(&buffer, info), .markdown);
    }

    fn appendCustom(
        self: *InteractiveController,
        title: []const u8,
        text: []const u8,
        format: tui.Transcript.CustomFormat,
    ) !void {
        if (title.len == 0 and text.len == 0) return;
        _ = try self.terminal.applyCommand(.{ .append_transcript = .{ .custom = .{
            .title = title,
            .text = boundedChunk(text),
            .format = format,
        } } });
    }

    fn setWorkingStatus(self: *InteractiveController, text: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 10,
            .text = text,
            .effect = .shimmer,
        } });
    }

    fn setRecoveryStatus(self: *InteractiveController, text: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_recovery,
            .priority = 9,
            .text = text,
            .effect = .shimmer,
        } });
    }

    fn setCompletionStatus(self: *InteractiveController) !void {
        _ = try self.terminal.applyCommand(.{ .set_status = .{
            .slot = .status_line,
            .id = status_id_completion,
            .priority = 8,
            .text = "loading completions",
            .effect = .shimmer,
        } });
    }

    fn clearStatus(self: *InteractiveController, id: tui.status.ContributionId) !void {
        _ = try self.terminal.applyCommand(.{ .clear_status = .{ .slot = .status_line, .id = id } });
    }

    fn clearNotify(self: *InteractiveController, key: tui.notify.Key) !void {
        _ = try self.terminal.applyCommand(.{ .clear_notify = .{ .item = .{ .key = key } } });
    }

    fn tickTime(self: *InteractiveController) !i64 {
        const now_ms = self.nowMs();
        _ = try self.terminal.applyCommand(.{ .tick = .{ .now_ms = now_ms } });
        try self.tickToolTimers();
        return now_ms;
    }

    fn nowMs(self: *InteractiveController) i64 {
        return @intCast(@divTrunc(std.Io.Clock.awake.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    fn startToolTimer(self: *InteractiveController, tool_call_id: []const u8) void {
        if (tool_call_id.len == 0 or tool_call_id.len > tool_timer_id_bytes_max) return;
        if (self.findToolTimer(tool_call_id) != null) return;
        for (&self.tool_timers) |*slot| {
            if (slot.* != null) continue;
            var timer: ToolTimer = .{ .id_len = @intCast(tool_call_id.len), .started_ms = self.nowMs() };
            @memcpy(timer.id[0..tool_call_id.len], tool_call_id);
            slot.* = timer;
            return;
        }
        // Table full: the tool simply runs without a duration footer.
    }

    fn findToolTimer(self: *InteractiveController, tool_call_id: []const u8) ?*ToolTimer {
        for (&self.tool_timers) |*slot| {
            if (slot.*) |*timer| {
                if (std.mem.eql(u8, timer.id[0..timer.id_len], tool_call_id)) return timer;
            }
        }
        return null;
    }

    fn finishToolTimer(self: *InteractiveController, tool_call_id: []const u8, buffer: []u8) ?[]const u8 {
        const timer = self.findToolTimer(tool_call_id) orelse return null;
        const text = self.toolDurationChip(buffer, "Took", timer.started_ms);
        self.removeToolTimer(tool_call_id);
        return text;
    }

    fn removeToolTimer(self: *InteractiveController, tool_call_id: []const u8) void {
        for (&self.tool_timers) |*slot| {
            if (slot.*) |*timer| {
                if (std.mem.eql(u8, timer.id[0..timer.id_len], tool_call_id)) slot.* = null;
            }
        }
    }

    fn clearToolTimers(self: *InteractiveController) void {
        self.tool_timers = @splat(null);
    }

    fn tickToolTimers(self: *InteractiveController) !void {
        for (&self.tool_timers) |*slot| {
            const timer = if (slot.*) |*value| value else continue;
            const elapsed_ms = self.nowMs() - timer.started_ms;
            const elapsed_s: u64 = if (elapsed_ms > 0) @intCast(@divTrunc(elapsed_ms, std.time.ms_per_s)) else 0;
            if (elapsed_s == timer.footer_elapsed_s) continue;
            timer.footer_elapsed_s = elapsed_s;
            var buffer: [64]u8 = undefined;
            const text = self.toolDurationChip(&buffer, "Elapsed", timer.started_ms);
            try self.replaceToolFooter(timer.id[0..timer.id_len], text);
        }
    }

    fn toolDurationChip(self: *InteractiveController, buffer: []u8, label: []const u8, started_ms: i64) []const u8 {
        const elapsed_ms: u64 = @intCast(@max(0, self.nowMs() - started_ms));
        return tool_view.durationChip(buffer, label, elapsed_ms);
    }

    fn replaceToolFooter(self: *InteractiveController, tool_call_id: []const u8, text: []const u8) !void {
        _ = try self.terminal.applyCommand(.{ .replace_tool_footer = .{
            .tool_call_id = tool_call_id,
            .text = text,
        } });
    }
};

/// Largest prefix that fits one transcript append, preferring a UTF-8
/// boundary; falls back to a raw cut when the head has no boundary (the
/// transcript sanitizes whatever arrives).
fn boundedChunk(text: []const u8) []const u8 {
    const prefix = tui.text.utf8Prefix(text, transcript_append_max);
    if (prefix.len > 0) return prefix;
    return text[0..@min(text.len, transcript_append_max)];
}

fn notifyLevel(level: tui.Transcript.StatusLevel) tui.notify.Level {
    return switch (level) {
        .info => .info,
        .warning => .warning,
        .err => .err,
    };
}

fn notifyAnnote(level: tui.Transcript.StatusLevel) ?[]const u8 {
    return switch (level) {
        .info => "",
        .warning, .err => null,
    };
}

fn formatRejectionMessage(buffer: []u8, rejection: client_protocol.Rejection) []const u8 {
    return switch (rejection.code) {
        .queue_full => std.fmt.bufPrint(
            buffer,
            "prompt queue full ({d})",
            .{agent_mod.Agent.max_queued_messages},
        ) catch "prompt queue full",
        else => rejection.message.text,
    };
}

fn formatRetryStatus(buffer: []u8, retry: client_protocol.AutoRetryStart) []const u8 {
    const reason = tui.text.utf8Prefix(retry.error_message.text, retry_reason_bytes_max);
    if (reason.len == 0) {
        return std.fmt.bufPrint(buffer, "retry {d}/{d} in {d}ms", .{
            retry.attempt,
            retry.max_attempts,
            retry.delay_ms,
        }) catch "retrying";
    }
    return std.fmt.bufPrint(buffer, "retry {d}/{d} in {d}ms: {s}", .{
        retry.attempt,
        retry.max_attempts,
        retry.delay_ms,
        reason,
    }) catch "retrying";
}

fn formatComposerRight(
    buffer: []u8,
    model: client_protocol.ModelSnapshot,
    context: client_protocol.ContextUsageSnapshot,
) []const u8 {
    var context_buffer: [32]u8 = undefined;
    const context_text = formatContextUsage(&context_buffer, context);
    if (std.mem.eql(u8, model.provider.text, "unknown") and std.mem.eql(u8, model.id.text, "unknown")) {
        return std.fmt.bufPrint(buffer, "{s} • no authenticated model", .{context_text}) catch
            "?/? • no authenticated model";
    }
    return std.fmt.bufPrint(buffer, "{s} • {s}/{s}", .{
        context_text,
        model.provider.text,
        model.id.text,
    }) catch model.id.text;
}

fn formatComposerCwd(buffer: []u8, cwd: []const u8, home_dir_raw: ?[]const u8) []const u8 {
    const suffix = homePathSuffix(cwd, home_dir_raw) orelse return cwd;
    if (suffix.len == 0) return "~";
    return std.fmt.bufPrint(buffer, "~{s}", .{suffix}) catch cwd;
}

fn homePathSuffix(path: []const u8, home_dir_raw: ?[]const u8) ?[]const u8 {
    const home_dir = trimTrailingPathSeparators(home_dir_raw orelse return null);
    if (home_dir.len == 0) return null;
    if (std.mem.eql(u8, path, home_dir)) return "";
    if (!std.mem.startsWith(u8, path, home_dir)) return null;
    if (path.len <= home_dir.len or !isPathSeparator(path[home_dir.len])) return null;
    return path[home_dir.len..];
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn formatContextUsage(buffer: []u8, context: client_protocol.ContextUsageSnapshot) []const u8 {
    var window_buffer: [24]u8 = undefined;
    const window = if (context.window == 0) "?" else formatTokenCount(&window_buffer, context.window);
    if (context.percent_tenths) |tenths| {
        return std.fmt.bufPrint(buffer, "{d}.{d}%/{s}", .{ tenths / 10, tenths % 10, window }) catch "?/?";
    }
    return std.fmt.bufPrint(buffer, "?/{s}", .{window}) catch "?/?";
}

fn formatTokenCount(buffer: []u8, tokens: u64) []const u8 {
    if (tokens >= 1000) return std.fmt.bufPrint(buffer, "{d}k", .{(tokens + 500) / 1000}) catch "?";
    return std.fmt.bufPrint(buffer, "{d}", .{tokens}) catch "?";
}

fn formatSessionInfo(buffer: []u8, info: client_protocol.PromptCommandSessionInfo) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (info.file) |file| {
        writer.print("File: {s}\n", .{file.text}) catch return "session status unavailable";
    } else {
        writer.writeAll("File: In-memory\n") catch return "session status unavailable";
    }
    writer.print("ID: {s}\n\n", .{info.id.text}) catch return "session status unavailable";
    writer.writeAll("**Messages**\n") catch return "session status unavailable";
    writer.print("User: {d}\n", .{info.user_messages}) catch return "session status unavailable";
    writer.print("Assistant: {d}\n", .{info.assistant_messages}) catch return "session status unavailable";
    writer.print("Tool Calls: {d}\n", .{info.tool_calls}) catch return "session status unavailable";
    writer.print("Tool Results: {d}\n", .{info.tool_results}) catch return "session status unavailable";
    writer.print("Total: {d}\n\n", .{info.total_messages}) catch return "session status unavailable";
    writer.writeAll("**Tokens**\n") catch return "session status unavailable";
    writer.print("Input: {d}\n", .{info.input_tokens}) catch return "session status unavailable";
    writer.print("Output: {d}\n", .{info.output_tokens}) catch return "session status unavailable";
    if (info.cache_read_tokens > 0) {
        writer.print("Cache Read: {d}\n", .{info.cache_read_tokens}) catch return "session status unavailable";
    }
    if (info.cache_write_tokens > 0) {
        writer.print("Cache Write: {d}\n", .{info.cache_write_tokens}) catch return "session status unavailable";
    }
    writer.print("Total: {d}", .{info.total_tokens}) catch return "session status unavailable";
    if (info.cost > 0) {
        writer.print("\n\n**Cost**\nTotal: {d:.4}", .{info.cost}) catch return "session status unavailable";
    }
    return writer.buffered();
}

fn isBareModelCommand(text: []const u8) bool {
    return isBareSlashCommand(text, .model);
}

fn isBareResumeCommand(text: []const u8) bool {
    return isBareSlashCommand(text, .resume_session);
}

fn isBareSlashCommand(text: []const u8, id: slash_commands.Id) bool {
    const invocation = slash_commands.parseInvocation(text) orelse return false;
    const spec = slash_commands.lookup(invocation.name) orelse return false;
    return spec.id == id and invocation.args.len == 0;
}

fn needsLazyCompletionSnapshot(text: []const u8) bool {
    const invocation = slash_commands.parseInvocation(text) orelse return false;
    const spec = slash_commands.lookup(invocation.name) orelse return false;
    switch (spec.picker) {
        .model, .session => {},
        .none => return false,
    }
    const command_end = 1 + invocation.name.len;
    return text.len > command_end and std.ascii.isWhitespace(text[command_end]);
}

fn completionPickerItems(
    buffer: *[client_protocol.completion_item_count_max]tui.Picker.Item,
    list: client_protocol.CompletionList,
) []const tui.Picker.Item {
    const keep = @min(list.items.len, buffer.len);
    for (list.items[0..keep], 0..) |item, index| {
        buffer[index] = .{
            .id = item.id.text,
            .label = item.label.text,
            .detail = item.detail.text,
            .meta = item.meta.text,
            .aux = item.aux.text,
        };
    }
    return buffer[0..keep];
}

fn testModelSnapshot(
    allocator: std.mem.Allocator,
    provider: []const u8,
    id: []const u8,
) !client_protocol.ModelSnapshot {
    var provider_text = try client_protocol.EventText.init(allocator, provider);
    errdefer provider_text.deinit(allocator);
    return .{
        .provider = provider_text,
        .id = try client_protocol.EventText.init(allocator, id),
    };
}

test "composer right reports unauthenticated unknown model" {
    var model = try testModelSnapshot(std.testing.allocator, "unknown", "unknown");
    defer model.deinit(std.testing.allocator);

    var buffer: [tui.status.text_bytes_max]u8 = undefined;
    const text = formatComposerRight(&buffer, model, .{});
    try std.testing.expectEqualStrings("?/? • no authenticated model", text);
}

test "composer right omits thinking level until providers enforce it" {
    var model = try testModelSnapshot(std.testing.allocator, "openai", "gpt-5");
    defer model.deinit(std.testing.allocator);

    var buffer: [tui.status.text_bytes_max]u8 = undefined;
    const text = formatComposerRight(&buffer, model, .{ .window = 100_000, .percent_tenths = 123 });
    try std.testing.expectEqualStrings("12.3%/100k • openai/gpt-5", text);
    try std.testing.expect(std.mem.indexOf(u8, text, "thinking") == null);
}

test "model slash parser only claims bare command" {
    try std.testing.expect(isBareModelCommand("/model"));
    try std.testing.expect(isBareModelCommand("/model   "));
    try std.testing.expect(!isBareModelCommand("/model gpt-5.1"));
    try std.testing.expect(!isBareModelCommand("/modelx"));
}

test "lazy completion snapshot waits for picker command argument" {
    try std.testing.expect(!needsLazyCompletionSnapshot("/model"));
    try std.testing.expect(needsLazyCompletionSnapshot("/model "));
    try std.testing.expect(needsLazyCompletionSnapshot("/resume session"));
    try std.testing.expect(!needsLazyCompletionSnapshot("/help "));
    try std.testing.expect(!needsLazyCompletionSnapshot("/modelx "));
}

test "completion picker items come only from protocol snapshot data" {
    const source = [_]client_protocol.CompletionItem.Source{.{
        .id = "custom/not-in-model-table",
        .label = "custom label",
        .detail = "custom detail",
    }};
    var list = try client_protocol.CompletionList.init(std.testing.allocator, &source, false);
    defer list.deinit(std.testing.allocator);

    var items: [client_protocol.completion_item_count_max]tui.Picker.Item = undefined;
    const mapped = completionPickerItems(&items, list);
    try std.testing.expectEqual(@as(usize, 1), mapped.len);
    try std.testing.expectEqualStrings("custom/not-in-model-table", mapped[0].id);
    try std.testing.expectEqualStrings("custom label", mapped[0].label);
    try std.testing.expectEqualStrings("custom detail", mapped[0].detail);
}

test "operation completion does not clear notification" {
    const terminal = try tui.Terminal.init(std.testing.allocator, std.testing.io, 80, 24, .{});
    defer terminal.deinit();
    var stdout_discard = std.Io.Writer.Discarding.init(&.{});
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .app = undefined,
        .stdout = &stdout_discard.writer,
        .stderr = &stderr_discard.writer,
        .terminal = terminal,
    };

    try controller.appendStatus(.warning, "keep me");
    try controller.setWorkingStatus("working");
    try controller.applyOperationFinished(.{ .reason = .completed });

    var status_views: [tui.status.entry_count_max]tui.status.View = undefined;
    const status_count = terminal.app.status.ordered(.status_line, &status_views);
    try std.testing.expectEqual(@as(usize, 0), status_count);

    var notify_views: [tui.notify.item_count_max]tui.notify.View = undefined;
    const notify_count = terminal.app.notify.ordered(terminal.app.now_ms, &notify_views);
    try std.testing.expectEqual(@as(usize, 1), notify_count);
    try std.testing.expectEqualStrings("keep me", notify_views[0].message);
}

test "cancel notification updates in place without info annote" {
    const terminal = try tui.Terminal.init(std.testing.allocator, std.testing.io, 80, 24, .{});
    defer terminal.deinit();
    var stdout_discard = std.Io.Writer.Discarding.init(&.{});
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .app = undefined,
        .stdout = &stdout_discard.writer,
        .stderr = &stderr_discard.writer,
        .terminal = terminal,
    };

    try controller.appendKeyedStatusWithTone(notify_key_cancel, .info, "cancel requested", .canceled);
    try controller.appendKeyedStatusWithTone(notify_key_cancel, .info, "canceled", .canceled);

    var notify_views: [tui.notify.item_count_max]tui.notify.View = undefined;
    const notify_count = terminal.app.notify.ordered(terminal.app.now_ms, &notify_views);
    try std.testing.expectEqual(@as(usize, 1), notify_count);
    try std.testing.expectEqualStrings("canceled", notify_views[0].message);
    try std.testing.expectEqualStrings("", notify_views[0].annote);
}

test "compaction end keeps working status while operation remains active" {
    const terminal = try tui.Terminal.init(std.testing.allocator, std.testing.io, 80, 24, .{});
    defer terminal.deinit();
    var stdout_discard = std.Io.Writer.Discarding.init(&.{});
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .app = undefined,
        .stdout = &stdout_discard.writer,
        .stderr = &stderr_discard.writer,
        .terminal = terminal,
        .operation_active = true,
    };

    try controller.setWorkingStatus("compacting");
    try controller.applyCompactionEnd(.{
        .reason = .threshold,
        .aborted = false,
        .will_retry = false,
    });

    var views: [tui.status.entry_count_max]tui.status.View = undefined;
    const count = terminal.app.status.ordered(.status_line, &views);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("working", views[0].text);
}

test "compaction end clears working status only when operation is done" {
    const terminal = try tui.Terminal.init(std.testing.allocator, std.testing.io, 80, 24, .{});
    defer terminal.deinit();
    var stdout_discard = std.Io.Writer.Discarding.init(&.{});
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .app = undefined,
        .stdout = &stdout_discard.writer,
        .stderr = &stderr_discard.writer,
        .terminal = terminal,
    };

    try controller.setWorkingStatus("compacting");
    try controller.applyCompactionEnd(.{
        .reason = .threshold,
        .aborted = false,
        .will_retry = false,
    });

    var views: [tui.status.entry_count_max]tui.status.View = undefined;
    const count = terminal.app.status.ordered(.status_line, &views);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "queue status is human text" {
    const terminal = try tui.Terminal.init(std.testing.allocator, std.testing.io, 80, 24, .{});
    defer terminal.deinit();
    var stdout_discard = std.Io.Writer.Discarding.init(&.{});
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .app = undefined,
        .stdout = &stdout_discard.writer,
        .stderr = &stderr_discard.writer,
        .terminal = terminal,
    };

    try controller.applyQueueCounts(2, 3);

    var views: [tui.status.entry_count_max]tui.status.View = undefined;
    const count = terminal.app.status.ordered(.status_line, &views);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("queued: 2 steering, 3 follow-up", views[0].text);
}

test "queue full rejection uses bounded friendly text" {
    var message = try client_protocol.EventText.init(std.testing.allocator, "QueueFull");
    defer message.deinit(std.testing.allocator);
    var buffer: [tui.status.text_bytes_max]u8 = undefined;
    const text = formatRejectionMessage(&buffer, .{ .code = .queue_full, .message = message });
    try std.testing.expectEqualStrings("prompt queue full (128)", text);
}

test "retry status includes bounded reason" {
    var message = try client_protocol.EventText.init(std.testing.allocator, "provider overloaded");
    defer message.deinit(std.testing.allocator);
    var buffer: [tui.status.text_bytes_max]u8 = undefined;
    const text = formatRetryStatus(&buffer, .{
        .attempt = 2,
        .max_attempts = 3,
        .delay_ms = 250,
        .error_message = message,
    });
    try std.testing.expectEqualStrings("retry 2/3 in 250ms: provider overloaded", text);
}

test "write preview footer clears when execution starts" {
    const allocator = std.testing.allocator;
    const terminal = try tui.Terminal.init(allocator, std.testing.io, 80, 24, .{});
    defer terminal.deinit();

    var stdout_discard = std.Io.Writer.Discarding.init(&.{});
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});
    var controller: InteractiveController = .{
        .allocator = allocator,
        .io = std.testing.io,
        .app = undefined,
        .stdout = &stdout_discard.writer,
        .stderr = &stderr_discard.writer,
        .terminal = terminal,
    };

    var args = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"path":"file.txt","content":"1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12"}
    ,
        .{},
    );
    defer args.deinit();

    try controller.applyToolCall(.{ .id = "call-write", .name = "write", .arguments = args.value });
    try std.testing.expectEqualStrings(
        "Showing lines 1-10 of 12",
        terminal.app.transcript.items.items[0].body.tool.footer,
    );

    try controller.applyToolStart(.{ .tool_call_id = "call-write", .tool_name = "write", .args = args.value });
    try std.testing.expectEqualStrings("", terminal.app.transcript.items.items[0].body.tool.footer);
}

test "immediate TUI work polls instead of starving input" {
    try std.testing.expectEqual(@as(u64, 0), nextWakeDelayMs(true, false));
    try std.testing.expectEqual(@as(u64, frame_interval_ms), nextWakeDelayMs(false, true));
    try std.testing.expectEqual(@as(u64, idle_frame_interval_ms), nextWakeDelayMs(false, false));
}

test "history paging is gated only by history state" {
    try std.testing.expect(canRequestHistoryPage(false, true));
    try std.testing.expect(!canRequestHistoryPage(true, true));
    try std.testing.expect(!canRequestHistoryPage(false, false));
}

test "render throttle coalesces active streaming but lets input render immediately" {
    var throttle: RenderThrottle = .{};
    try std.testing.expect(throttle.shouldRender(100, true));
    try std.testing.expect(!throttle.shouldRender(101, true));
    try std.testing.expect(throttle.shouldRender(101, false));
    try std.testing.expect(!throttle.shouldRender(102, true));
    throttle.requestImmediate();
    try std.testing.expect(throttle.shouldRender(102, true));
    try std.testing.expect(!throttle.shouldRender(103, true));
    try std.testing.expect(throttle.shouldRender(102 + @as(i64, @intCast(frame_interval_ms)), true));
}

test "resume picker starts from newest existing session when present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent/sessions/--repo--");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/sessions/--repo--/2026-06-10T00:00:00Z_old.jsonl",
        .data = "{\"type\":\"session\",\"version\":3,\"id\":\"old\"," ++
            "\"timestamp\":\"2026-06-10T00:00:00Z\",\"cwd\":\"repo\"}\n",
    });

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process: runtime.Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    };
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});

    const selected = try selectResumeSession(process, &stderr_discard.writer, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .startup_action = .resume_picker,
    });
    defer std.testing.allocator.free(selected.?);
    try std.testing.expectEqualStrings("2026-06-10T00:00:00Z_old.jsonl", selected.?);
}

test "resume picker creates new session when no resumable session exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const process: runtime.Process = .{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    };
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});

    const selected = try selectResumeSession(process, &stderr_discard.writer, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .environ = &environ,
        .startup_action = .resume_picker,
    });
    try std.testing.expect(selected == null);
}

test "TUI recovers event gaps by requesting snapshot directly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var app = try session_runtime.openSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .open = .{ .create = .{ .session_id = "session", .timestamp = "2026-06-09T00:00:00Z" } },
        .dir = tmp.dir,
        .task_runtime = task_runtime,
    });
    defer app.deinit();

    const terminal = try tui.Terminal.init(std.testing.allocator, std.testing.io, 80, 24, .{});
    defer terminal.deinit();
    var stdout_discard = std.Io.Writer.Discarding.init(&.{});
    var stderr_discard = std.Io.Writer.Discarding.init(&.{});
    var controller: InteractiveController = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .app = &app,
        .stdout = &stdout_discard.writer,
        .stderr = &stderr_discard.writer,
        .terminal = terminal,
    };

    try controller.acceptEnvelope(.{
        .seq = 2,
        .event = .{ .queue_changed = .{ .steering_count = 0, .follow_up_count = 0, .revision = 0 } },
    });
    const command = app.commands.pop().?;
    try std.testing.expect(command.command == .snapshot);

    var notify_views: [tui.notify.item_count_max]tui.notify.View = undefined;
    const notify_count = terminal.app.notify.ordered(terminal.app.now_ms, &notify_views);
    try std.testing.expectEqual(@as(usize, 1), notify_count);
    try std.testing.expectEqualStrings("recovering event gap", notify_views[0].message);
}

fn selectResumeSession(process: runtime.Process, stderr: *std.Io.Writer, options: Options) !?[]const u8 {
    const picker_latest = options.startup_action == .resume_picker and options.session_selector == null and
        !options.continue_latest;
    const wants_latest = options.continue_latest or picker_latest;
    if (options.session_selector == null and !wants_latest) return null;

    const selected = session_listing.selectRuntimeSession(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .selector = options.session_selector,
    }) catch |err| switch (err) {
        error.InvalidSessionFileName => {
            try stderr.writeAll("invalid session selector\n");
            return error.InvalidSessionFileName;
        },
        error.AmbiguousSessionSelector => {
            try stderr.writeAll("ambiguous session selector\n");
            return error.AmbiguousSessionSelector;
        },
        error.SessionListTruncated => {
            try stderr.writeAll("too many sessions to choose safely\n");
            return error.SessionListTruncated;
        },
        else => return err,
    };
    if (selected == null and !picker_latest) {
        try stderr.writeAll("no resumable session found\n");
        return error.NoResumableSession;
    }
    return selected;
}

fn userText(message: ai.UserMessage) ?[]const u8 {
    return switch (message.content) {
        .string => |text| text,
        .blocks => |blocks| for (blocks) |block| {
            if (block == .text) break block.text.text;
        } else null,
    };
}

test "composer cwd display shortens home paths" {
    var buffer: [tui.status.text_bytes_max]u8 = undefined;

    try std.testing.expectEqualStrings("~", formatComposerCwd(&buffer, "/Users/me", "/Users/me"));
    try std.testing.expectEqualStrings("~/repo", formatComposerCwd(&buffer, "/Users/me/repo", "/Users/me"));
    try std.testing.expectEqualStrings("~/repo", formatComposerCwd(&buffer, "/Users/me/repo", "/Users/me/"));
    try std.testing.expectEqualStrings("/Users/meg/repo", formatComposerCwd(&buffer, "/Users/meg/repo", "/Users/me"));
    try std.testing.expectEqualStrings("/repo", formatComposerCwd(&buffer, "/repo", null));
}
