const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const AgentSession = @import("../AgentSession.zig");
const SessionTranscript = @import("../SessionTranscript.zig");
const Policy = @import("Policy.zig");
const TurnWorker = @import("../TurnWorker.zig");
const Decoder = @import("input/Decoder.zig");
const EventLoop = @import("EventLoop.zig");
const NormalScreenRenderer = @import("NormalScreenRenderer.zig");
const LineEditor = @import("input/LineEditor.zig");
const TerminalSession = @import("terminal/Session.zig");

const App = @This();

pub const Options = struct {
    policy_limits: Policy.Limits = Policy.default_limits,
    escape_timeout_ms: i64 = 30,
};

allocator: std.mem.Allocator,
io: std.Io,
worker: *TurnWorker,
policy: Policy,
decoder: Decoder = .{},
editor: LineEditor,
renderer: NormalScreenRenderer,
escape_timeout_ms: i64,
should_exit: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    worker: *TurnWorker,
    writer: *std.Io.Writer,
    options: Options,
) !App {
    if (options.escape_timeout_ms < 0) return error.InvalidEscapeTimeout;
    var policy = try Policy.init(allocator, options.policy_limits);
    errdefer policy.deinit();
    return .{
        .allocator = allocator,
        .io = io,
        .worker = worker,
        .policy = policy,
        .editor = LineEditor.init(
            allocator,
            options.policy_limits.max_restored_draft_bytes,
        ),
        .renderer = NormalScreenRenderer.init(writer),
        .escape_timeout_ms = options.escape_timeout_ms,
    };
}

pub fn deinit(self: *App) void {
    self.editor.deinit();
    self.policy.deinit();
    self.* = undefined;
}

/// Owns raw terminal admission and runs one interactive application instance.
pub fn run(
    self: *App,
    input: std.Io.File,
    output: std.Io.File,
    transcript: ?*const SessionTranscript,
    event_loop_options: EventLoop.Options,
) !EventLoop.ExitCause {
    var terminal = try TerminalSession.start(self.io, input, output);
    defer terminal.deinit();
    return self.runWithTerminal(&terminal, transcript, event_loop_options);
}

fn runWithTerminal(
    self: *App,
    terminal: anytype,
    transcript: ?*const SessionTranscript,
    event_loop_options: EventLoop.Options,
) !EventLoop.ExitCause {
    try self.start(transcript);
    const cause = EventLoop.run(terminal, self.callbacks(), event_loop_options) catch |failure| {
        const finish_result = self.finish();
        if (finish_result) |_| {} else |_| {}
        return failure;
    };
    try self.finish();
    return cause;
}

fn callbacks(self: *App) EventLoop.Callbacks {
    return .{
        .context = self,
        .collectFactsFn = collectFacts,
        .handleByteFn = handleByte,
        .settleInputFn = settleInput,
        .resizeFn = handleResize,
        .shouldExitFn = shouldExit,
    };
}

fn start(self: *App, transcript: ?*const SessionTranscript) !void {
    try self.renderer.renderWelcome();
    if (transcript) |restored| try self.renderer.renderTranscript(restored);
    try self.renderer.redrawPrompt(&self.editor);
}

fn finish(self: *App) !void {
    try self.renderer.finish();
}

fn collectFacts(context: *anyopaque) !void {
    const self: *App = @ptrCast(@alignCast(context));
    const snapshot = self.worker.snapshot();
    if (snapshot.queued_events == 0 and snapshot.queued_completions == 0) return;

    var batch = try self.worker.takeBatch();
    defer batch.deinit(self.allocator);
    for (batch.events.items) |owned| {
        const result = self.policy.applyEvent(owned.value);
        if (result.admission == .stale) continue;
        try self.renderer.renderEvent(owned.value);
        try self.applyEffect(result.effect);
    }
    for (batch.completions.items) |completion| {
        const result = self.policy.applyCompletion(completion.run_id, completion.availability);
        if (result.admission == .stale) continue;
        if (!batchContainsAgentEnd(&batch, completion.run_id)) switch (completion.outcome) {
            .completed => {},
            .failed => |failure| try self.renderer.renderCompletionFailure(failure),
        };
        try self.applyEffect(result.effect);
    }
    try self.renderer.redrawPrompt(&self.editor);
}

fn handleByte(context: *anyopaque, byte: u8) !void {
    const self: *App = @ptrCast(@alignCast(context));
    if (self.decoder.feed(byte, self.nowMs())) |action| try self.handleAction(action);
}

fn settleInput(context: *anyopaque) !void {
    const self: *App = @ptrCast(@alignCast(context));
    if (self.decoder.flush(self.nowMs(), self.escape_timeout_ms)) |action| {
        try self.handleAction(action);
    }
}

fn handleAction(self: *App, action: Decoder.Action) !void {
    switch (action) {
        .text_byte => |byte| self.editor.insertByte(byte) catch |failure| {
            try self.renderer.renderNotice(@errorName(failure));
        },
        .submit, .follow_up => try self.submitDraft(),
        .escape => try self.cancelAndRestore(),
        .interrupt => {
            if (self.policy.phase() == .idle) {
                if (self.editor.isEmpty()) {
                    self.should_exit = true;
                } else {
                    self.editor.clear();
                }
            } else {
                try self.cancelAndRestore();
            }
        },
        .end_of_input => if (self.editor.isEmpty() and self.policy.phase() == .idle) {
            self.should_exit = true;
        },
        .backspace => self.editor.deleteBackward(),
        .delete => self.editor.deleteForward(),
        .tab => self.editor.insertByte('\t') catch |failure| {
            try self.renderer.renderNotice(@errorName(failure));
        },
        .cursor_left => self.editor.moveLeft(),
        .cursor_right => self.editor.moveRight(),
        .home => self.editor.moveHome(),
        .end => self.editor.moveEnd(),
        .cursor_up, .cursor_down, .ignored => {},
    }
    if (!self.should_exit) try self.renderer.redrawPrompt(&self.editor);
}

fn handleResize(context: *anyopaque, _: TerminalSession.Size) !void {
    const self: *App = @ptrCast(@alignCast(context));
    try self.renderer.redrawPrompt(&self.editor);
}

fn shouldExit(context: *anyopaque) bool {
    const self: *App = @ptrCast(@alignCast(context));
    return self.should_exit;
}

fn nowMs(self: *App) i64 {
    const value = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    return std.math.cast(i64, value) orelse std.math.maxInt(i64);
}

fn submitDraft(self: *App) !void {
    if (!self.editor.validUtf8()) {
        try self.renderer.renderNotice("input is not valid UTF-8");
        return;
    }
    var prepared = self.policy.prepareSubmission(self.editor.text()) catch |failure| {
        if (failure != error.EmptyPrompt) try self.renderer.renderNotice(@errorName(failure));
        return;
    };
    var prepared_live = true;
    defer if (prepared_live) prepared.deinit();
    switch (prepared.route) {
        .start => self.worker.submit(prepared.text) catch |failure| {
            try self.renderer.renderNotice(@errorName(failure));
            return;
        },
        .follow_up => {},
    }
    self.policy.commitSubmission(&prepared);
    prepared_live = false;
    self.editor.clear();
}

fn cancelAndRestore(self: *App) !void {
    var result = self.policy.escape(self.editor.text()) catch |failure| {
        try self.renderer.renderNotice(@errorName(failure));
        return;
    };
    if (result.restored) |*restored| {
        defer restored.deinit();
        try self.editor.replace(restored.text);
    }
    if (result.request_cancel) _ = self.worker.requestCancel();
}

fn applyEffect(self: *App, effect: Policy.Effect) !void {
    switch (effect) {
        .none => {},
        .request_cancel => _ = self.worker.requestCancel(),
        .submit_follow_up => |prompt| {
            self.worker.submit(prompt) catch |failure| {
                self.policy.rejectFollowUpSubmission();
                try self.renderer.renderNotice(@errorName(failure));
                return;
            };
            self.policy.confirmFollowUpSubmission();
        },
        .session_poisoned => {
            const restored_optional = self.policy.restoreQueued(self.editor.text()) catch |failure| {
                try self.renderer.renderNotice(@errorName(failure));
                return;
            };
            if (restored_optional) |restored_value| {
                var restored = restored_value;
                defer restored.deinit();
                try self.editor.replace(restored.text);
            }
        },
    }
}

fn batchContainsAgentEnd(
    batch: *const TurnWorker.Batch,
    run_id: agent.event.RunId,
) bool {
    for (batch.events.items) |owned| switch (owned.value) {
        .agent_end => |ended| if (ended.run_id == run_id) return true,
        else => {},
    };
    return false;
}

const TestSessionOwner = struct {
    allocator: std.mem.Allocator,
    session_value: AgentSession,

    fn create(
        allocator: std.mem.Allocator,
        model: ai.model.Model,
        cwd: std.Io.Dir,
    ) !*TestSessionOwner {
        const self = try allocator.create(TestSessionOwner);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .session_value = try AgentSession.init(allocator, std.testing.io, model, cwd, .{}),
        };
        return self;
    }

    pub fn session(self: *TestSessionOwner) *AgentSession {
        return &self.session_value;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *TestSessionOwner) void {
        const allocator = self.allocator;
        self.session_value.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

test "app drives one worker turn through policy and renderer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "app" },
        .steps = &.{.{ .text = "answer" }},
    };
    const owner = try TestSessionOwner.create(
        std.testing.allocator,
        scripted.asModel(),
        temporary.dir,
    );
    var worker = try TurnWorker.start(
        std.testing.allocator,
        std.testing.io,
        TurnWorker.SessionOwner.from(owner),
        .{},
    );
    defer worker.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var app = try App.init(
        std.testing.allocator,
        std.testing.io,
        worker,
        &output.writer,
        .{},
    );
    defer app.deinit();
    const port = app.callbacks();
    for ("hello\r") |byte| try port.handleByteFn(port.context, byte);

    var settled = false;
    for (0..10_000) |_| {
        try port.collectFactsFn(port.context);
        const snapshot = worker.snapshot();
        if (!snapshot.processing and
            snapshot.queued_prompts == 0 and
            snapshot.queued_events == 0 and
            snapshot.queued_completions == 0 and
            app.policy.phase() == .idle)
        {
            settled = true;
            break;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(settled);
    try std.testing.expect(std.mem.find(u8, output.written(), "> hello\n") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "answer\n") != null);

    try app.finish();

    const ExitTerminal = struct {
        const Self = @This();

        delivered: bool = false,

        pub fn querySize(_: *Self) !TerminalSession.Size {
            return .{ .rows = 24, .columns = 80 };
        }

        pub fn pollInput(self: *Self, _: i32) !TerminalSession.PollResult {
            return if (self.delivered) .{} else .{ .readable = true };
        }

        pub fn read(self: *Self, bytes: []u8) !usize {
            self.delivered = true;
            bytes[0] = 4;
            return 1;
        }
    };
    var terminal: ExitTerminal = .{};
    const cause = try app.runWithTerminal(&terminal, null, .{ .poll_timeout_ms = 0 });
    try std.testing.expectEqual(EventLoop.ExitCause.requested, cause);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "\n"));
}

test "app rejects invalid input deadline configuration" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(
        error.InvalidEscapeTimeout,
        App.init(
            std.testing.allocator,
            std.testing.io,
            undefined,
            &output.writer,
            .{ .escape_timeout_ms = -1 },
        ),
    );
}
