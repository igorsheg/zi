const std = @import("std");
const coding_agent = @import("../coding_agent/root.zig");
const interactive = coding_agent.interactive;
const Decoder = @import("input/Decoder.zig");
const EventLoop = @import("EventLoop.zig");
const Screen = @import("Screen.zig");
const LineEditor = @import("input/LineEditor.zig");
const TerminalSession = @import("terminal/Session.zig");

const App = @This();

pub const InitOptions = struct {
    escape_timeout_ms: i64 = 30,
};

pub const RunOptions = struct {
    initial_prompts: []const []const u8 = &.{},
    poll_timeout_ms: i32 = 16,
    max_reads_per_tick: usize = 32,
};

pub const ExitCause = EventLoop.ExitCause;

io: std.Io,
controller: *interactive.SessionController,
decoder: Decoder = .{},
editor: LineEditor,
screen: Screen,
escape_timeout_ms: i64,
should_exit: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    controller: *interactive.SessionController,
    writer: *std.Io.Writer,
    options: InitOptions,
) !App {
    if (options.escape_timeout_ms < 0) return error.InvalidEscapeTimeout;
    var editor = LineEditor.init(
        allocator,
        interactive.default_limits.max_restored_draft_bytes,
    );
    errdefer editor.deinit();
    return .{
        .io = io,
        .controller = controller,
        .editor = editor,
        .screen = try Screen.init(allocator, writer, .{}),
        .escape_timeout_ms = options.escape_timeout_ms,
    };
}

pub fn deinit(self: *App) void {
    self.screen.deinit();
    self.editor.deinit();
    self.* = undefined;
}

/// Owns raw terminal admission and runs one smol client instance.
pub fn run(
    self: *App,
    input: std.Io.File,
    output: std.Io.File,
    transcript: ?*const interactive.SessionTranscript,
    options: RunOptions,
) !ExitCause {
    var terminal = try TerminalSession.start(self.io, input, output);
    defer terminal.deinit();
    return self.runWithTerminal(&terminal, transcript, options);
}

fn runWithTerminal(
    self: *App,
    terminal: anytype,
    transcript: ?*const interactive.SessionTranscript,
    options: RunOptions,
) !ExitCause {
    try self.start(transcript);
    var finish_pending = true;
    defer if (finish_pending) {
        const finish_result = self.finish();
        if (finish_result) |_| {} else |_| {}
    };
    for (options.initial_prompts) |prompt| try self.submitPrompt(prompt);
    if (terminal.querySize()) |size| self.screen.resized(size) else |_| {}
    try self.commitFrameImpl();
    const cause = try EventLoop.run(terminal, self.callbacks(), .{
        .poll_timeout_ms = options.poll_timeout_ms,
        .max_reads_per_tick = options.max_reads_per_tick,
    });
    const finish_result = self.finish();
    finish_pending = false;
    try finish_result;
    return cause;
}

fn callbacks(self: *App) EventLoop.Callbacks {
    return .{
        .context = self,
        .collectFactsFn = collectFacts,
        .handleByteFn = handleByte,
        .settleInputFn = settleInput,
        .resizeFn = handleResize,
        .commitFrameFn = commitFrame,
        .shouldExitFn = shouldExit,
    };
}

fn controllerSink(self: *App) interactive.ControllerSink {
    return .{ .context = self, .emitFn = emitControllerFact };
}

fn start(self: *App, transcript: ?*const interactive.SessionTranscript) !void {
    try self.screen.start(transcript);
}

fn finish(self: *App) !void {
    try self.screen.finish(self.frameView());
}

fn collectFacts(context: *anyopaque) !void {
    const self: *App = @ptrCast(@alignCast(context));
    if (!self.controller.hasPendingFacts()) return;

    var result = try self.controller.drain(
        self.editor.text(),
        self.controllerSink(),
    );
    defer result.deinit();
    if (result.restored) |restored| {
        try self.editor.replace(restored.text);
        self.screen.editorChanged();
    }
}

fn emitControllerFact(context: *anyopaque, fact: interactive.ControllerFact) !void {
    const self: *App = @ptrCast(@alignCast(context));
    try self.screen.apply(fact);
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
            try self.screen.notice(@errorName(failure));
        },
        .submit, .follow_up => try self.submitDraft(),
        .escape => try self.cancelAndRestore(),
        .interrupt => {
            if (self.controller.phase() == .idle) {
                if (self.editor.isEmpty()) {
                    self.should_exit = true;
                } else {
                    self.editor.clear();
                }
            } else {
                try self.cancelAndRestore();
            }
        },
        .end_of_input => if (self.editor.isEmpty() and self.controller.phase() == .idle) {
            self.should_exit = true;
        },
        .backspace => self.editor.deleteBackward(),
        .delete => self.editor.deleteForward(),
        .tab => self.editor.insertByte('\t') catch |failure| {
            try self.screen.notice(@errorName(failure));
        },
        .cursor_left => self.editor.moveLeft(),
        .cursor_right => self.editor.moveRight(),
        .home => self.editor.moveHome(),
        .end => self.editor.moveEnd(),
        .cursor_up, .cursor_down, .ignored => {},
    }
    if (!self.should_exit) self.screen.editorChanged();
}

fn handleResize(context: *anyopaque, size: TerminalSession.Size) !void {
    const self: *App = @ptrCast(@alignCast(context));
    self.screen.resized(size);
}

fn commitFrame(context: *anyopaque) !void {
    const self: *App = @ptrCast(@alignCast(context));
    try self.commitFrameImpl();
}

fn commitFrameImpl(self: *App) !void {
    try self.screen.commit(self.frameView());
}

fn frameView(self: *const App) Screen.FrameView {
    return .{
        .composer = .{
            .text = self.editor.text(),
            .cursor_byte = self.editor.cursorByte(),
        },
        .phase = self.controller.phase(),
        .queued_count = self.controller.queuedFollowUpCount(),
    };
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
        try self.screen.notice("input is not valid UTF-8");
        return;
    }
    self.submitPrompt(self.editor.text()) catch |failure| {
        if (failure == error.ModelSelectionRequired) {
            try self.screen.notice("No model selected. Run `zi auth login PROVIDER`, then restart Zi.");
        } else if (failure != error.EmptyPrompt) {
            try self.screen.notice(@errorName(failure));
        }
        return;
    };
    self.editor.clear();
}

fn submitPrompt(self: *App, prompt: []const u8) !void {
    _ = try self.controller.submit(prompt);
    self.screen.editorChanged();
}

fn cancelAndRestore(self: *App) !void {
    const restored_optional = self.controller.cancel(self.editor.text()) catch |failure| {
        try self.screen.notice(@errorName(failure));
        return;
    };
    if (restored_optional) |restored_value| {
        var restored = restored_value;
        defer restored.deinit();
        try self.editor.replace(restored.text);
    }
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
