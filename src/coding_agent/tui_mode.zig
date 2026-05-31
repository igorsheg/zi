const std = @import("std");
const vaxis = @import("vaxis");

const runtime = @import("../runtime/root.zig");
const tui = @import("../tui/root.zig");
const ai = @import("../ai/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const auth_mode = @import("auth_mode.zig");
const frontend = @import("frontend.zig");
const sdk = @import("sdk.zig");

pub const Options = struct {
    initial_prompt: ?[]const u8 = null,
};

pub fn run(process: runtime.Process, options: auth_mode.Options, tui_options: Options) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);
    const session_id = try std.fmt.allocPrint(process.gpa, "cli-{d}", .{timestamp});
    defer process.gpa.free(session_id);

    var faux_provider: ?ai.FauxProvider = null;
    defer if (faux_provider) |*provider| provider.deinit();
    if (process.env("ZI_PTY_FAUX_RESPONSE")) |response_text| {
        const include_read_tool = process.env("ZI_PTY_FAUX_TOOL_READ") != null;
        const delay_per_delta_ms = try parsePtyFauxDelay(process.env("ZI_PTY_FAUX_DELAY_MS"));
        faux_provider = try buildPtyFauxProvider(
            process.gpa,
            response_text,
            include_read_tool,
            delay_per_delta_ms,
        );
    }
    const explicit_model: ?ai.Model = if (faux_provider) |*provider| provider.getModel() else null;
    const explicit_stream: ?ai.StreamFunction = if (faux_provider) |*provider|
        provider.apiProvider().stream_simple
    else
        null;

    var runtime_host = try sdk.createRuntimeHost(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .current_date = timestamp_text,
        .session_id = session_id,
        .timestamp = timestamp_text,
        .model = explicit_model,
        .stream = explicit_stream,
        .environ = process.environ,
    });
    defer runtime_host.deinit();

    var terminal: tui.terminal.Terminal = undefined;
    try terminal.init(process.gpa, process.io, process.environ);
    defer terminal.deinit();

    var loop = terminal.eventLoop();
    try loop.start();
    defer loop.stop();

    try terminal.enterAltScreen();

    var app = try tui.app.App.init(
        process.gpa,
        nonzero(terminal.vx.screen.width, 80),
        nonzero(terminal.vx.screen.height, 24),
    );
    defer app.deinit();
    var read_model = frontend.ReadModel.initFromSnapshot(runtime_host.host.statusSnapshot());

    var session: Session = .{
        .host = &runtime_host.host,
        .app = &app,
        .read_model = &read_model,
        .terminal = &terminal,
        .loop = &loop,
        .io = process.io,
        .rendered_status = read_model.status,
        .last_winsize = .{
            .rows = terminal.vx.screen.height,
            .cols = terminal.vx.screen.width,
            .x_pixel = terminal.vx.screen.width_pix,
            .y_pixel = terminal.vx.screen.height_pix,
        },
    };
    defer session.shutdown();

    // Apply the real terminal size before the first paint so surfaces are not
    // stuck at the init fallback if vaxis reported a zero size at startup.
    session.app.resize(
        nonzero(terminal.vx.screen.width, 80),
        nonzero(terminal.vx.screen.height, 24),
    );
    if (process.env("ZI_PTY_TEST_MODAL") != null) try session.openPtyTestModal();

    if (tui_options.initial_prompt) |prompt| try session.beginPrompt(prompt);
    try session.renderIfDirty();

    while (session.running) try session.tick();
}

/// Single owner of the frame cycle. Both the initial prompt and any future
/// interactive submission drive the one active-run path, so there is exactly
/// one place that steps the host, drains events, and paints.
const Session = struct {
    host: *AgentSessionRuntimeHost,
    app: *tui.app.App,
    read_model: *frontend.ReadModel,
    terminal: *tui.terminal.Terminal,
    loop: *tui.terminal.EventLoop,
    io: std.Io,
    active_run: ?*AgentSession.LivePromptRun = null,
    frame_gate: tui.frame.Gate = .init(frame_policy),
    input_router: tui.input_router.Router = .{},
    rendered_status: frontend.ReadModel.Status = .idle,
    last_winsize: vaxis.Winsize,
    running: bool = true,

    /// 30fps with bounded drains. Streaming bursts coalesce into at most one
    /// paint per frame, and each tick has a visible upper bound on work.
    const frame_policy: tui.frame.Policy = .{
        .interval_ns = std.time.ns_per_s / 30,
        .terminal_events_per_tick_max = 64,
        .host_events_per_tick_max = 128,
    };

    fn shutdown(self: *Session) void {
        if (self.active_run) |prompt_run| {
            self.host.cancel();
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
    }

    fn beginPrompt(self: *Session, prompt: []const u8) !void {
        std.debug.assert(self.active_run == null);
        self.active_run = try self.host.startPromptRun(prompt, &.{}, .{});
    }

    /// One iteration of the unified loop. While a run is active we poll the
    /// terminal queue without blocking and step the host; when idle we block on
    /// the next terminal event. The vaxis input thread keeps the queue filled
    /// across steps, so there is no second event source to select over here.
    fn tick(self: *Session) !void {
        try self.pollTerminalResize();
        if (self.active_run) |prompt_run| {
            _ = try self.pollEvents();
            if (!self.running) return;
            if (self.active_run == null) {
                try self.renderIfDirty();
                return;
            }
            const more = try self.host.stepPromptRun(prompt_run);
            _ = try self.drainHost();
            if (more) {
                try self.maybeRender();
            } else {
                self.finishRun();
                try self.renderIfDirty();
            }
        } else {
            try self.renderIfDirty();
            const event_count = try self.pollEvents();
            const host_event_count = try self.drainHost();
            try self.maybeRender();
            if (event_count == 0 and host_event_count == 0 and !self.app.isDirty()) {
                try self.io.sleep(.fromMilliseconds(16), .awake);
            }
        }
    }

    fn finishRun(self: *Session) void {
        if (self.active_run) |prompt_run| {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
    }

    fn pollEvents(self: *Session) !usize {
        var count: usize = 0;
        while (count < frame_policy.terminal_events_per_tick_max) : (count += 1) {
            const event = try self.loop.tryEvent() orelse return count;
            try self.handleEvent(event);
            if (!self.running) return count;
        }
        return count;
    }

    fn handleEvent(self: *Session, event: tui.terminal.Event) !void {
        switch (event) {
            .key_press => |key| {
                var router = self.input_router;
                router.focus = self.app.inputFocusTarget();
                try self.handleKeyIntent(router.route(
                    keyToRouterKey(key),
                    if (self.active_run == null) .idle else .active,
                ));
            },
            .winsize => |winsize| {
                try self.applyResize(winsize);
            },
            .focus_in, .focus_out, .mouse => {},
        }
    }

    fn pollTerminalResize(self: *Session) !void {
        const winsize = try self.terminal.currentWinsize();
        if (winsize.cols == self.last_winsize.cols and winsize.rows == self.last_winsize.rows) return;
        try self.applyResize(winsize);
    }

    fn applyResize(self: *Session, winsize: vaxis.Winsize) !void {
        self.last_winsize = winsize;
        try self.terminal.resize(winsize);
        self.app.resize(nonzero(winsize.cols, 80), nonzero(winsize.rows, 24));
        try self.renderFullFrame();
    }

    fn handleKeyIntent(self: *Session, intent: tui.input_router.Intent) !void {
        switch (intent) {
            .none => {},
            .quit => self.running = false,
            .cancel_run => {
                self.host.cancel();
                self.read_model.markCancelled();
                try self.syncStatus();
                try self.renderIfDirty();
            },
            .dismiss_focused_surface => {
                if (try self.app.dismissFocusedSurfaceByEscape()) try self.renderIfDirty();
            },
            .submit_composer => {
                try self.submitComposer();
            },
            .composer_backspace => try self.app.dispatch(.composer_backspace),
            .composer_insert => |text| try self.app.dispatch(.{ .composer_insert = text }),
        }
    }

    fn submitComposer(self: *Session) !void {
        const text = self.app.composer.text();
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;

        const owned_text = try self.app.allocator.dupe(u8, text);
        defer self.app.allocator.free(owned_text);

        try self.beginPrompt(owned_text);
        self.read_model.markRunning();
        try self.syncStatus();
        try self.app.dispatch(.composer_clear);
        try self.renderIfDirty();
    }

    fn drainHost(self: *Session) !usize {
        var count: usize = 0;
        while (count < frame_policy.host_events_per_tick_max) : (count += 1) {
            var event = self.host.drainPublicEvent() orelse break;
            defer event.deinit();
            self.read_model.apply(event);
            try self.syncStatus();
            try self.app.applyAgentSessionEvent(event);
        }
        self.app.clearEvents();
        return count;
    }

    /// Frame-gated paint: skip when nothing changed, and coalesce mutations that
    /// arrive faster than the frame interval.
    fn maybeRender(self: *Session) !void {
        if (!self.app.isDirty()) return;
        const now = self.nowNs();
        if (!self.frame_gate.shouldRender(now)) return;
        try self.renderNow(now);
    }

    /// Force a paint of any pending state, ignoring the frame gate. Used before
    /// blocking on input and when a run ends, so the final state is never stuck
    /// behind the coalescing window.
    fn renderIfDirty(self: *Session) !void {
        if (!self.app.isDirty()) return;
        try self.renderNow(self.nowNs());
    }

    fn renderFullFrame(self: *Session) !void {
        self.app.forceFullRepaint();
        self.terminal.vx.window().clear();
        try self.renderNow(self.nowNs());
    }

    fn renderNow(self: *Session, now_ns: i128) !void {
        const window = self.terminal.vx.window();
        self.app.render(window);
        // Zi does not render scaled text. Keep this optional terminal feature
        // outside our supported surface until we own a tested primitive for it.
        self.terminal.vx.caps.scaled_text = false;
        try self.terminal.vx.render(self.terminal.tty.writer());
        try self.terminal.tty.writer().flush();
        self.frame_gate.recordRender(now_ns);
    }

    fn nowNs(self: *Session) i128 {
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    }

    fn syncStatus(self: *Session) !void {
        if (self.rendered_status == self.read_model.status) return;
        self.rendered_status = self.read_model.status;
        try self.app.dispatch(.{ .buffer_replace = .{
            .id = .status,
            .bytes = statusText(self.rendered_status),
        } });
    }

    fn openPtyTestModal(self: *Session) !void {
        const screen_width = nonzero(self.terminal.vx.screen.width, 80);
        const screen_height = nonzero(self.terminal.vx.screen.height, 24);
        const width: u16 = @min(screen_width, 28);
        const height: u16 = 3;
        const x: u16 = (screen_width - width) / 2;
        const y: u16 = if (screen_height > height) (screen_height - height) / 2 else 0;
        try self.app.dispatch(.{ .open_text_surface = .{
            .surface_id = .diagnostics,
            .view_id = .diagnostics,
            .buffer_id = .diagnostics,
            .buffer_kind = .diagnostics,
            .buffer_name = "diagnostics",
            .rect = .init(x, y, width, height),
            .layer = .modal,
            .modality = .focus_trap,
            .dismiss_policy = .escape,
            .text = "PTY MODAL",
        } });
    }
};

fn nonzero(value: u16, fallback: u16) u16 {
    return if (value == 0) fallback else value;
}

fn statusText(status: frontend.ReadModel.Status) []const u8 {
    return switch (status) {
        .idle => "idle",
        .running => "running",
        .cancel_requested => "cancel requested",
        .shutdown_requested => "shutdown requested",
        .stopped => "stopped",
    };
}

fn keyToRouterKey(key: vaxis.Key) tui.input_router.Key {
    return .{
        .codepoint = if (key.codepoint == 0) null else key.codepoint,
        .text = key.text,
        .enter = key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{}),
        .backspace = key.matches(vaxis.Key.backspace, .{}),
        .escape = key.matches(0x1b, .{}),
        .modifiers = .{
            .ctrl = key.mods.ctrl,
            .alt = key.mods.alt,
            .super = key.mods.super,
            .meta = key.mods.meta,
        },
    };
}

fn buildPtyFauxProvider(
    allocator: std.mem.Allocator,
    response_text: []const u8,
    include_read_tool: bool,
    delay_per_delta_ms: u32,
) !ai.FauxProvider {
    var provider = try ai.FauxProvider.init(allocator, .{
        .min_token_size = 1,
        .max_token_size = 1,
        .delay_per_delta_ms = delay_per_delta_ms,
    });
    errdefer provider.deinit();

    if (include_read_tool) {
        var args: std.json.ObjectMap = .empty;
        defer args.deinit(allocator);
        try args.put(allocator, "path", .{ .string = "src/ai/root.zig" });
        try args.put(allocator, "offset", .{ .integer = 1 });
        try args.put(allocator, "limit", .{ .integer = 1 });

        const tool_content = [_]ai.AssistantContent{
            ai.faux.toolCall("read-tool", "read", .{ .object = args }),
        };
        const final_content = [_]ai.AssistantContent{ai.faux.text(response_text)};
        const responses = [_]ai.AssistantMessage{
            ai.faux.assistantMessage(&tool_content, .{ .stop_reason = .tool_use }),
            ai.faux.assistantMessage(&final_content, .{ .stop_reason = .stop }),
        };
        try provider.setResponses(&responses);
    } else {
        const content = [_]ai.AssistantContent{ai.faux.text(response_text)};
        const message = ai.faux.assistantMessage(&content, .{});
        try provider.setResponses(&.{message});
    }
    return provider;
}

fn parsePtyFauxDelay(value: ?[]const u8) !u32 {
    const text = value orelse return 0;
    if (text.len == 0) return 0;
    return std.fmt.parseInt(u32, text, 10);
}
