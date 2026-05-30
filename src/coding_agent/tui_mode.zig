const std = @import("std");

const runtime = @import("../runtime/root.zig");
const tui = @import("../tui/root.zig");
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

    var runtime_host = try sdk.createRuntimeHost(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .current_date = timestamp_text,
        .session_id = session_id,
        .timestamp = timestamp_text,
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
    };
    defer session.shutdown();

    // Apply the real terminal size before the first paint so surfaces are not
    // stuck at the init fallback if vaxis reported a zero size at startup.
    session.app.resize(
        nonzero(terminal.vx.screen.width, 80),
        nonzero(terminal.vx.screen.height, 24),
    );

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
    last_render_ns: i128 = 0,
    running: bool = true,

    /// 30fps budget. Streaming bursts coalesce into at most one paint per tick.
    const frame_interval_ns: i128 = std.time.ns_per_s / 30;

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
        if (self.active_run) |prompt_run| {
            try self.pollEvents();
            if (!self.running) return;
            if (self.active_run == null) {
                try self.renderIfDirty();
                return;
            }
            const more = try self.host.stepPromptRun(prompt_run);
            try self.drainHost();
            if (more) {
                try self.maybeRender();
            } else {
                self.finishRun();
                try self.renderIfDirty();
            }
        } else {
            try self.renderIfDirty();
            const event = try self.loop.nextEvent();
            try self.handleEvent(event);
            try self.drainHost();
            try self.maybeRender();
        }
    }

    fn finishRun(self: *Session) void {
        if (self.active_run) |prompt_run| {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
    }

    fn pollEvents(self: *Session) !void {
        while (try self.loop.tryEvent()) |event| {
            try self.handleEvent(event);
            if (!self.running) return;
        }
    }

    fn handleEvent(self: *Session, event: tui.terminal.Event) !void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or (key.codepoint == 'c' and key.mods.ctrl)) {
                    self.running = false;
                    return;
                }
                if (key.matches(0x1b, .{}) and self.active_run != null) {
                    self.host.cancel();
                    self.read_model.markCancelled();
                }
            },
            .winsize => |winsize| {
                try self.terminal.resize(winsize);
                self.app.resize(nonzero(winsize.cols, 80), nonzero(winsize.rows, 24));
            },
            .focus_in, .focus_out, .mouse => {},
        }
    }

    fn drainHost(self: *Session) !void {
        var drain: HostDrain = .{ .app = self.app, .read_model = self.read_model };
        _ = try self.host.drainPublicEvents(.{ .context = &drain, .call_fn = HostDrain.onEvent });
        _ = self.app.drainEvents();
    }

    /// Frame-gated paint: skip when nothing changed, and coalesce mutations that
    /// arrive faster than the frame interval.
    fn maybeRender(self: *Session) !void {
        if (!self.app.isDirty()) return;
        const now = self.nowNs();
        if (!frameElapsed(now, self.last_render_ns, frame_interval_ns)) return;
        try self.renderNow(now);
    }

    /// Force a paint of any pending state, ignoring the frame gate. Used before
    /// blocking on input and when a run ends, so the final state is never stuck
    /// behind the coalescing window.
    fn renderIfDirty(self: *Session) !void {
        if (!self.app.isDirty()) return;
        try self.renderNow(self.nowNs());
    }

    fn renderNow(self: *Session, now_ns: i128) !void {
        const window = self.terminal.vx.window();
        window.clear();
        self.app.render(window);
        try self.terminal.vx.render(self.terminal.tty.writer());
        try self.terminal.tty.writer().flush();
        self.last_render_ns = now_ns;
    }

    fn nowNs(self: *Session) i128 {
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    }
};

const HostDrain = struct {
    app: *tui.app.App,
    read_model: *frontend.ReadModel,

    fn onEvent(context: ?*anyopaque, event: AgentSession.AgentSessionEvent) !void {
        const self: *HostDrain = @ptrCast(@alignCast(context.?));
        self.read_model.apply(event);
        try self.app.applyAgentSessionEvent(event);
    }
};

fn nonzero(value: u16, fallback: u16) u16 {
    return if (value == 0) fallback else value;
}

/// True once a full frame interval has passed since the last paint. Pure so the
/// coalescing rule is testable without a terminal or clock.
fn frameElapsed(now_ns: i128, last_render_ns: i128, interval_ns: i128) bool {
    return now_ns - last_render_ns >= interval_ns;
}

test "frame gate elapses only after a full interval" {
    try std.testing.expect(!frameElapsed(0, 0, 33));
    try std.testing.expect(!frameElapsed(32, 0, 33));
    try std.testing.expect(frameElapsed(33, 0, 33));
    try std.testing.expect(frameElapsed(100, 50, 33));
    try std.testing.expect(!frameElapsed(100, 90, 33));
}
