const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const AgentSession = @import("../AgentSession.zig");
const SessionTranscript = @import("../SessionTranscript.zig");
const InteractivePolicy = @import("../InteractivePolicy.zig");
const TurnWorker = @import("../TurnWorker.zig");
const InputDecoder = @import("InputDecoder.zig");
const InteractiveEventLoop = @import("InteractiveEventLoop.zig");
const InteractiveRenderer = @import("InteractiveRenderer.zig");
const LineEditor = @import("LineEditor.zig");
const TerminalSession = @import("TerminalSession.zig");

const InteractiveController = @This();

allocator: std.mem.Allocator,
io: std.Io,
worker: *TurnWorker,
policy: InteractivePolicy,
editor: LineEditor,
renderer: InteractiveRenderer,
should_exit: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    worker: *TurnWorker,
    writer: *std.Io.Writer,
) !InteractiveController {
    var policy = try InteractivePolicy.init(allocator, InteractivePolicy.default_limits);
    errdefer policy.deinit();
    return .{
        .allocator = allocator,
        .io = io,
        .worker = worker,
        .policy = policy,
        .editor = LineEditor.init(
            allocator,
            InteractivePolicy.default_limits.max_restored_draft_bytes,
        ),
        .renderer = InteractiveRenderer.init(writer),
    };
}

pub fn deinit(self: *InteractiveController) void {
    self.editor.deinit();
    self.policy.deinit();
    self.* = undefined;
}

pub fn callbacks(self: *InteractiveController) InteractiveEventLoop.Callbacks {
    return .{
        .context = self,
        .collectFactsFn = collectFacts,
        .handleActionFn = handleAction,
        .resizeFn = handleResize,
        .shouldExitFn = shouldExit,
        .nowMsFn = nowMs,
    };
}

pub fn start(
    self: *InteractiveController,
    transcript: ?*const SessionTranscript,
) !void {
    try self.renderer.renderWelcome();
    if (transcript) |restored| try self.renderer.renderTranscript(restored);
    try self.renderer.redrawPrompt(&self.editor);
}

pub fn finish(self: *InteractiveController) !void {
    try self.renderer.finish();
}

fn collectFacts(context: *anyopaque) !void {
    const self: *InteractiveController = @ptrCast(@alignCast(context));
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

fn handleAction(context: *anyopaque, action: InputDecoder.Action) !void {
    const self: *InteractiveController = @ptrCast(@alignCast(context));
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
    const self: *InteractiveController = @ptrCast(@alignCast(context));
    try self.renderer.redrawPrompt(&self.editor);
}

fn shouldExit(context: *anyopaque) bool {
    const self: *InteractiveController = @ptrCast(@alignCast(context));
    return self.should_exit;
}

fn nowMs(context: *anyopaque) i64 {
    const self: *InteractiveController = @ptrCast(@alignCast(context));
    const value = std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    return std.math.cast(i64, value) orelse std.math.maxInt(i64);
}

fn submitDraft(self: *InteractiveController) !void {
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

fn cancelAndRestore(self: *InteractiveController) !void {
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

fn applyEffect(self: *InteractiveController, effect: InteractivePolicy.Effect) !void {
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

test "controller drives one worker turn through policy and renderer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "controller" },
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
    var controller = try InteractiveController.init(
        std.testing.allocator,
        std.testing.io,
        worker,
        &output.writer,
    );
    defer controller.deinit();
    const port = controller.callbacks();
    try controller.start(null);
    for ("hello") |byte| try port.handleActionFn(port.context, .{ .text_byte = byte });
    try port.handleActionFn(port.context, .submit);

    var settled = false;
    for (0..10_000) |_| {
        try port.collectFactsFn(port.context);
        const snapshot = worker.snapshot();
        if (!snapshot.processing and
            snapshot.queued_prompts == 0 and
            snapshot.queued_events == 0 and
            snapshot.queued_completions == 0 and
            controller.policy.phase() == .idle)
        {
            settled = true;
            break;
        }
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(settled);
    try std.testing.expect(std.mem.find(u8, output.written(), "> hello\n") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "answer\n") != null);
}

test "controller binds the worker policy editor renderer and event loop ports" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var controller = try InteractiveController.init(
        std.testing.allocator,
        std.testing.io,
        undefined,
        &output.writer,
    );
    defer controller.deinit();
    _ = controller.callbacks();
    try controller.start(null);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "\r\x1b[2K> "));
}
