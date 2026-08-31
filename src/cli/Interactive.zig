const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const render = @import("../render/root.zig");
const terminal = @import("../terminal/root.zig");
const tool = @import("../tool/root.zig");
const text = @import("../text/root.zig");
const DiagnosticText = @import("DiagnosticText.zig");
const Args = @import("Args.zig");

comptime {
    std.debug.assert(terminal.max_prompt_bytes == Args.max_prompt_bytes);
}

pub const BeforeFirstSendError = error{
    OutOfMemory,
    Indeterminate,
    InvalidPlan,
    WriteFailed,
};

pub const BeforeFirstSend = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque) BeforeFirstSendError!void,

    pub fn call(self: BeforeFirstSend) BeforeFirstSendError!void {
        return self.call_fn(self.context);
    }

    pub fn from(implementation: anytype) BeforeFirstSend {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("BeforeFirstSend.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn call(context: *anyopaque) BeforeFirstSendError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.call();
            }
        };
        return .{ .context = implementation, .call_fn = Adapter.call };
    }
};

pub const EffortSource = struct {
    context: *anyopaque,
    resolve_fn: *const fn (*anyopaque) ?[]const u8,

    pub fn resolve(self: EffortSource) ?[]const u8 {
        return self.resolve_fn(self.context);
    }

    pub fn from(implementation: anytype) EffortSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("EffortSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn resolve(context: *anyopaque) ?[]const u8 {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.resolve();
            }
        };
        return .{ .context = implementation, .resolve_fn = Adapter.resolve };
    }
};

/// Borrowed inputs used for one complete agent-loop invocation.
pub const TurnSnapshot = struct {
    provider: ai.Provider.Provider,
    model: []const u8,
    model_metadata: ai.ModelMeta.Metadata,
    model_metadata_source: ?agent.ModelMetadataSource.ModelMetadataSource,
    system_prompt: []const u8,
    tools: []const tool.Tool.Tool,
    effort: ?[]const u8,
    image_input: ai.Provider.ImageInput,
    image_input_source: ?agent.ImageInputSource.ImageInputSource,
};

/// Supplies one coherent borrowed snapshot per interactive turn.
pub const TurnSource = struct {
    context: *anyopaque,
    snapshot_fn: *const fn (*anyopaque) TurnSnapshot,

    pub fn snapshot(self: TurnSource) TurnSnapshot {
        return self.snapshot_fn(self.context);
    }

    pub fn from(implementation: anytype) TurnSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("TurnSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn snapshot(context: *anyopaque) TurnSnapshot {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.snapshot();
            }
        };
        return .{ .context = implementation, .snapshot_fn = Adapter.snapshot };
    }
};

pub const PromptInput = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque) anyerror!terminal.Result,
    set_empty_submit_fn: *const fn (*anyopaque, bool) void,

    pub fn read(self: PromptInput) !terminal.Result {
        return self.read_fn(self.context);
    }

    pub fn setEmptySubmit(self: PromptInput, resumable: bool) void {
        self.set_empty_submit_fn(self.context, resumable);
    }

    pub fn from(implementation: anytype) PromptInput {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("PromptInput.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn read(context: *anyopaque) anyerror!terminal.Result {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.read();
            }

            fn setEmptySubmit(context: *anyopaque, resumable: bool) void {
                if (comptime @hasDecl(Implementation, "setEmptySubmit")) {
                    const self: *Implementation = @ptrCast(@alignCast(context));
                    self.setEmptySubmit(resumable);
                }
            }
        };
        return .{
            .context = implementation,
            .read_fn = Adapter.read,
            .set_empty_submit_fn = Adapter.setEmptySubmit,
        };
    }
};

pub const RecallKind = enum {
    session,
    persistent,
};

/// Synchronous prompt-recall admission. Submitted bytes are borrowed only for
/// the call; implementations copy anything they retain.
pub const PromptRecall = struct {
    context: *anyopaque,
    admit_fn: *const fn (*anyopaque, []const u8, RecallKind) anyerror!void,

    pub fn admit(self: PromptRecall, line: []const u8, kind: RecallKind) !void {
        return self.admit_fn(self.context, line, kind);
    }

    pub fn from(implementation: anytype) PromptRecall {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or
            pointer_info.pointer.is_const)
        {
            @compileError("PromptRecall.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn admit(context: *anyopaque, line: []const u8, kind: RecallKind) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return switch (kind) {
                    .session => self.admitSession(line),
                    .persistent => self.admitPersistent(line),
                };
            }
        };
        return .{ .context = implementation, .admit_fn = Adapter.admit };
    }
};

pub const CommandOutcome = enum {
    handled,
    history_changed,
    exit,
};

pub const CommandUsage = enum {
    valid,
    unknown,
    bad_usage,
};

/// Non-owning command token. Registry state is owned by `context`; name and
/// argument borrow the sanitized submitted line through synchronous execution.
pub const CommandToken = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, CommandToken) anyerror!CommandOutcome,
    registry_index: ?usize,
    name: []const u8,
    argument: ?[]const u8,
    usage: CommandUsage,

    pub fn execute(self: CommandToken) !CommandOutcome {
        return self.execute_fn(self.context, self);
    }
};

pub const CommandClassification = union(enum) {
    prompt,
    command: CommandToken,
};

/// Allocation-free command classifier. Classification performs no output or
/// handler callback; a returned token executes synchronously.
pub const CommandGateway = struct {
    context: *anyopaque,
    classify_fn: *const fn (*anyopaque, []const u8) CommandClassification,

    pub fn classify(self: CommandGateway, line: []const u8) CommandClassification {
        return self.classify_fn(self.context, line);
    }

    pub fn from(implementation: anytype) CommandGateway {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or
            pointer_info.pointer.is_const)
        {
            @compileError("CommandGateway.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn classify(context: *anyopaque, line: []const u8) CommandClassification {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.classifyCommand(line);
            }
        };
        return .{ .context = implementation, .classify_fn = Adapter.classify };
    }
};

/// Erased synchronous renderer for one outer user turn.
///
/// The implementation and observer returned by `begin` are borrowed through
/// the matching `close` and `check` calls. `close` must be safe after a failed
/// `begin`; errors are retained or returned synchronously and no callback may
/// retain event payloads.
pub const TurnRenderer = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque) anyerror!agent.Loop.Observer,
    close_fn: *const fn (*anyopaque, render.Terminal) anyerror!void,
    check_fn: *const fn (*anyopaque) anyerror!void,
    wrote_assistant_text_fn: *const fn (*anyopaque) bool,
    tool_observer_fn: *const fn (*anyopaque) ?agent.Loop.ToolObserver,

    pub fn begin(self: TurnRenderer) !agent.Loop.Observer {
        return self.begin_fn(self.context);
    }

    pub fn close(self: TurnRenderer, result: render.Terminal) !void {
        return self.close_fn(self.context, result);
    }

    pub fn check(self: TurnRenderer) !void {
        return self.check_fn(self.context);
    }

    pub fn wroteAssistantText(self: TurnRenderer) bool {
        return self.wrote_assistant_text_fn(self.context);
    }

    pub fn toolObserver(self: TurnRenderer) ?agent.Loop.ToolObserver {
        return self.tool_observer_fn(self.context);
    }

    pub fn from(implementation: anytype) TurnRenderer {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("TurnRenderer.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn begin(context: *anyopaque) anyerror!agent.Loop.Observer {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.begin();
            }

            fn close(context: *anyopaque, result: render.Terminal) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.close(result);
            }

            fn check(context: *anyopaque) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.check();
            }

            fn wroteAssistantText(context: *anyopaque) bool {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.wroteAssistantText();
            }

            fn toolObserver(context: *anyopaque) ?agent.Loop.ToolObserver {
                if (!@hasDecl(Implementation, "toolObserver")) return null;
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.toolObserver();
            }
        };
        return .{
            .context = implementation,
            .begin_fn = Adapter.begin,
            .close_fn = Adapter.close,
            .check_fn = Adapter.check,
            .wrote_assistant_text_fn = Adapter.wroteAssistantText,
            .tool_observer_fn = Adapter.toolObserver,
        };
    }
};

const PlainTurnRenderer = struct {
    stream: render.StreamRenderer,

    fn init(writer: *std.Io.Writer) PlainTurnRenderer {
        return .{ .stream = .init(writer) };
    }

    pub fn begin(self: *PlainTurnRenderer) !agent.Loop.Observer {
        return self.stream.observer();
    }

    pub fn close(self: *PlainTurnRenderer, result: render.Terminal) !void {
        self.stream.close(result);
    }

    pub fn check(self: *PlainTurnRenderer) !void {
        return self.stream.check();
    }

    pub fn wroteAssistantText(self: *PlainTurnRenderer) bool {
        return self.stream.wroteAssistantText();
    }
};

pub const Generation = struct {
    context: *anyopaque,
    arm_fn: *const fn (*anyopaque) anyerror!void,
    disarm_fn: *const fn (*anyopaque) anyerror!void,

    pub fn arm(self: Generation) !void {
        return self.arm_fn(self.context);
    }

    pub fn disarm(self: Generation) !void {
        return self.disarm_fn(self.context);
    }

    pub fn from(implementation: anytype) Generation {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Generation.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn arm(context: *anyopaque) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.clearAndArm();
            }

            fn disarm(context: *anyopaque) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.disarm();
            }
        };
        return .{
            .context = implementation,
            .arm_fn = Adapter.arm,
            .disarm_fn = Adapter.disarm,
        };
    }
};

pub const ResumeReason = enum {
    none,
    paused,
    interrupted,
    max_turns,
    provider_error,
};

pub const TurnSummary = struct {
    outcome: agent.Loop.Outcome,
    elapsed_ms: u64,
    context_tokens: ?u64,
    wrote_assistant_text: bool,
    /// Borrowed only for the synchronous `afterTurn` call.
    diagnostic: ?[]const u8 = null,
};

pub const Presentation = struct {
    context: *anyopaque,
    before_prompt_fn: *const fn (*anyopaque, ResumeReason) anyerror!void,
    before_generation_fn: *const fn (*anyopaque) anyerror!void,
    after_turn_fn: *const fn (*anyopaque, TurnSummary) anyerror!void,

    pub fn beforePrompt(self: Presentation, reason: ResumeReason) !void {
        return self.before_prompt_fn(self.context, reason);
    }

    pub fn beforeGeneration(self: Presentation) !void {
        return self.before_generation_fn(self.context);
    }

    pub fn afterTurn(self: Presentation, summary: TurnSummary) !void {
        return self.after_turn_fn(self.context, summary);
    }

    pub fn from(implementation: anytype) Presentation {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Presentation.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn beforePrompt(context: *anyopaque, reason: ResumeReason) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.beforePrompt(reason);
            }

            fn beforeGeneration(context: *anyopaque) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.beforeGeneration();
            }

            fn afterTurn(context: *anyopaque, summary: TurnSummary) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.afterTurn(summary);
            }
        };
        return .{
            .context = implementation,
            .before_prompt_fn = Adapter.beforePrompt,
            .before_generation_fn = Adapter.beforeGeneration,
            .after_turn_fn = Adapter.afterTurn,
        };
    }
};

pub const Inputs = struct {
    session: *agent.Session.Session,
    provider: ai.Provider.Provider,
    model: []const u8,
    model_metadata: ai.ModelMeta.Metadata = .{},
    model_metadata_source: ?agent.ModelMetadataSource.ModelMetadataSource = null,
    system_prompt: []const u8,
    tools: []const tool.Tool.Tool = &.{},
    effort: ?[]const u8 = null,
    effort_source: ?EffortSource = null,
    turn_source: ?TurnSource = null,
    image_input: ai.Provider.ImageInput = .unknown,
    image_input_source: ?agent.ImageInputSource.ImageInputSource = null,
    reader: *std.Io.Reader,
    prompt_input: ?PromptInput = null,
    prompt_recall: ?PromptRecall = null,
    command_gateway: ?CommandGateway = null,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    show_prompt: bool,
    generation: ?Generation = null,
    presentation: ?Presentation = null,
    turn_renderer: ?TurnRenderer = null,
    seam_hook: ?agent.Loop.SeamHook = null,
    checkpoint: ?agent.Loop.Checkpoint = null,
    pre_request_hook: ?agent.Loop.PreRequestHook = null,
    continuation_hook: ?agent.Loop.ContinuationHook = null,
    usage_observer: ?agent.Loop.UsageObserver = null,
    max_turns: usize = agent.Loop.maximum_max_turns,
    before_first_send: ?BeforeFirstSend = null,
};

fn fixedTurnSnapshot(inputs: Inputs) TurnSnapshot {
    return .{
        .provider = inputs.provider,
        .model = inputs.model,
        .model_metadata = inputs.model_metadata,
        .model_metadata_source = inputs.model_metadata_source,
        .system_prompt = inputs.system_prompt,
        .tools = inputs.tools,
        .effort = if (inputs.effort_source) |source| source.resolve() else inputs.effort,
        .image_input = inputs.image_input,
        .image_input_source = inputs.image_input_source,
    };
}

fn finishTurn(generation: ?Generation, renderer_instance: TurnRenderer, result: render.Terminal) ?anyerror {
    var first_error: ?anyerror = null;
    if (generation) |control| control.disarm() catch |err| {
        first_error = err;
    };
    renderer_instance.close(result) catch |err| {
        if (first_error == null) first_error = err;
    };
    renderer_instance.check() catch |err| {
        if (first_error == null) first_error = err;
    };
    return first_error;
}

/// Runs a bounded prompt REPL around the shared provider-independent agent loop.
/// Provider failures are turn-local and return control to the next prompt.
pub fn run(allocator: std.mem.Allocator, io: std.Io, inputs: Inputs) !u8 {
    var line_input = terminal.CookedLineInput.init(allocator, inputs.reader);
    var resume_reason: ResumeReason = .none;
    var abort_marker_placed = false;
    var first_send = true;
    while (true) {
        if (inputs.presentation) |presentation| try presentation.beforePrompt(resume_reason);
        if (inputs.show_prompt) {
            try inputs.stdout.writeAll("> ");
            try inputs.stdout.flush();
        }

        if (inputs.prompt_input) |prompt_input| prompt_input.setEmptySubmit(resume_reason != .none);
        var line_result = (if (inputs.prompt_input) |prompt_input|
            prompt_input.read()
        else
            line_input.read()) catch |err| switch (err) {
            error.LineTooLong, error.PromptTooLong => {
                try inputs.stderr.print(
                    "zi: prompt exceeds the {d}-byte limit\n",
                    .{terminal.max_prompt_bytes},
                );
                try inputs.stderr.flush();
                continue;
            },
            else => return err,
        };
        defer line_result.deinit(allocator);

        const submitted = switch (line_result) {
            .eof => {
                if (inputs.show_prompt) {
                    try inputs.stdout.writeByte('\n');
                    try inputs.stdout.flush();
                }
                return 0;
            },
            .submit => |line| line.bytes,
        };
        const resuming = submitted.len == 0 and resume_reason != .none;
        if (submitted.len == 0 and !resuming) continue;
        const continuing = resuming and !abort_marker_placed;

        var sanitized: ?[]u8 = null;
        defer if (sanitized) |bytes| allocator.free(bytes);
        if (resuming and abort_marker_placed) {
            try inputs.session.addContinuation();
            if (inputs.seam_hook) |seam| try seam.call(inputs.session, .prompt, false);
        } else if (!resuming) {
            sanitized = text.Utf8.sanitize(allocator, submitted, terminal.max_prompt_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ResultTooLarge => {
                    try inputs.stderr.print(
                        "zi: prompt exceeds the {d}-byte limit after UTF-8 sanitation\n",
                        .{terminal.max_prompt_bytes},
                    );
                    try inputs.stderr.flush();
                    continue;
                },
            };
            const classification: CommandClassification = if (inputs.command_gateway) |gateway|
                gateway.classify(sanitized.?)
            else
                .prompt;
            switch (classification) {
                .command => |command| {
                    if (inputs.prompt_recall) |recall| try recall.admit(submitted, .session);
                    switch (try command.execute()) {
                        .handled => continue,
                        .history_changed => {
                            resume_reason = .none;
                            abort_marker_placed = false;
                            continue;
                        },
                        .exit => return 0,
                    }
                },
                .prompt => {
                    if (inputs.prompt_recall) |recall| try recall.admit(submitted, .persistent);
                },
            }
            try inputs.session.addUser(sanitized.?);
            if (inputs.seam_hook) |seam| try seam.call(inputs.session, .prompt, false);
        }
        resume_reason = .none;
        abort_marker_placed = false;
        if (first_send) {
            if (inputs.before_first_send) |hook| try hook.call();
            first_send = false;
        }

        const turn = if (inputs.turn_source) |source| source.snapshot() else fixedTurnSnapshot(inputs);
        if (inputs.presentation) |presentation| try presentation.beforeGeneration();
        const started_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        if (inputs.generation) |generation| try generation.arm();

        var plain_renderer: PlainTurnRenderer = undefined;
        const turn_renderer = inputs.turn_renderer orelse renderer: {
            plain_renderer = .init(inputs.stdout);
            break :renderer TurnRenderer.from(&plain_renderer);
        };
        const observer = turn_renderer.begin() catch |begin_error| {
            _ = finishTurn(inputs.generation, turn_renderer, .failure);
            return begin_error;
        };

        var loop_result = agent.Loop.run(allocator, io, .{
            .session = inputs.session,
            .provider = turn.provider,
            .model = turn.model,
            .model_metadata = turn.model_metadata,
            .model_metadata_source = turn.model_metadata_source,
            .system_prompt = turn.system_prompt,
            .tools = turn.tools,
            .effort = turn.effort,
            .image_input = turn.image_input,
            .image_input_source = turn.image_input_source,
            .max_turns = inputs.max_turns,
            .continued = continuing,
            .checkpoint = inputs.checkpoint,
            .observer = observer,
            .tool_observer = turn_renderer.toolObserver(),
            .usage_observer = inputs.usage_observer,
            .seam_hook = inputs.seam_hook,
            .pre_request_hook = inputs.pre_request_hook,
            .continuation_hook = inputs.continuation_hook,
        }) catch |loop_error| {
            // The operation error remains primary; cleanup still runs best-effort.
            _ = finishTurn(inputs.generation, turn_renderer, .failure);
            return loop_error;
        };
        defer loop_result.deinit(allocator);

        const renderer_terminal: render.Terminal = switch (loop_result.outcome) {
            .complete => .complete,
            .provider_error, .max_turns => .failure,
            .paused, .interrupted => .interrupted,
        };
        if (finishTurn(inputs.generation, turn_renderer, renderer_terminal)) |cleanup_error| {
            return cleanup_error;
        }

        switch (loop_result.outcome) {
            .complete => {},
            .provider_error => {
                if (inputs.presentation == null) {
                    try inputs.stderr.writeAll("zi: provider error: ");
                    try DiagnosticText.write(inputs.stderr, loop_result.diagnostic orelse "(no message)");
                    try inputs.stderr.writeByte('\n');
                    try inputs.stderr.flush();
                }
                resume_reason = .provider_error;
                abort_marker_placed = loop_result.abort_marker_placed;
            },
            .max_turns => {
                if (inputs.presentation == null) {
                    try inputs.stderr.print(
                        "zi: max turns ({d}) exceeded; submit an empty prompt to continue\n",
                        .{inputs.max_turns},
                    );
                    try inputs.stderr.flush();
                }
                resume_reason = .max_turns;
            },
            .paused => resume_reason = .paused,
            .interrupted => {
                resume_reason = .interrupted;
                abort_marker_placed = loop_result.abort_marker_placed;
            },
        }

        const finished_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        const elapsed_ms: u64 = @intCast(@max(0, finished_ns - started_ns) / std.time.ns_per_ms);
        if (inputs.presentation) |presentation| try presentation.afterTurn(.{
            .outcome = loop_result.outcome,
            .elapsed_ms = elapsed_ms,
            .context_tokens = loop_result.last_context_tokens,
            .wrote_assistant_text = turn_renderer.wroteAssistantText(),
            .diagnostic = loop_result.diagnostic,
        });
    }
}

test "interactive terminal adapters preserve prompt and generation ownership" {
    const Prompt = struct {
        const Self = @This();

        calls: usize = 0,
        empty_submit: bool = false,

        pub fn read(self: *Self) !terminal.Result {
            self.calls += 1;
            return .eof;
        }

        pub fn setEmptySubmit(self: *Self, resumable: bool) void {
            self.empty_submit = resumable;
        }
    };
    const Control = struct {
        const Self = @This();

        arms: usize = 0,
        disarms: usize = 0,

        pub fn clearAndArm(self: *Self) !void {
            self.arms += 1;
        }

        pub fn disarm(self: *Self) !void {
            self.disarms += 1;
        }
    };

    var prompt: Prompt = .{};
    const prompt_input = PromptInput.from(&prompt);
    prompt_input.setEmptySubmit(true);
    var result = try prompt_input.read();
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), prompt.calls);
    try std.testing.expect(prompt.empty_submit);
    try std.testing.expect(result == .eof);

    var control: Control = .{};
    const generation = Generation.from(&control);
    try generation.arm();
    try generation.disarm();
    try std.testing.expectEqual(@as(usize, 1), control.arms);
    try std.testing.expectEqual(@as(usize, 1), control.disarms);
}

test "interactive reuses one session across prompts and exits on EOF" {
    const Control = struct {
        const Self = @This();

        active: bool = false,
        arms: usize = 0,
        disarms: usize = 0,

        pub fn clearAndArm(self: *Self) !void {
            if (self.active) return error.AlreadyArmed;
            self.active = true;
            self.arms += 1;
        }

        pub fn disarm(self: *Self) !void {
            if (!self.active) return error.NotArmed;
            self.active = false;
            self.disarms += 1;
        }
    };
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,
        control: *Control,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            if (!self.control.active) return error.InvalidRequest;
            self.calls += 1;
            const expected_user_count: usize = self.calls;
            var user_count: usize = 0;
            for (request.context.items) |item| {
                if (item == .user_message) user_count += 1;
            }
            if (user_count != expected_user_count) return error.InvalidRequest;
            try sink.emit(.{ .text_delta = if (self.calls == 1) "first" else "second" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Seam = struct {
        const Self = @This();
        prompts: usize = 0,
        completions: usize = 0,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            switch (kind) {
                .prompt => self.prompts += 1,
                .completion => self.completions += 1,
                else => {},
            }
        }
    };

    var control: Control = .{};
    var provider: Provider = .{ .control = &control };
    var seam: Seam = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .generation = Generation.from(&control),
        .seam_hook = agent.Loop.SeamHook.from(&seam),
    }));
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 2), control.arms);
    try std.testing.expectEqual(@as(usize, 2), control.disarms);
    try std.testing.expect(!control.active);
    try std.testing.expectEqual(@as(usize, 2), seam.prompts);
    try std.testing.expectEqual(@as(usize, 2), seam.completions);
    try std.testing.expectEqualStrings("first\nsecond\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "commands are classified before recall and bypass session provider flow" {
    const Recall = struct {
        const Self = @This();

        session_calls: usize = 0,
        persistent_calls: usize = 0,

        pub fn admitSession(self: *Self, line: []const u8) !void {
            try std.testing.expectEqualStrings("/help", line);
            self.session_calls += 1;
        }

        pub fn admitPersistent(self: *Self, line: []const u8) !void {
            try std.testing.expectEqualStrings("prompt", line);
            self.persistent_calls += 1;
        }
    };
    const Gateway = struct {
        const Self = @This();

        recall: *const Recall,
        classifications: usize = 0,
        executions: usize = 0,

        pub fn classifyCommand(self: *Self, line: []const u8) CommandClassification {
            self.classifications += 1;
            if (!std.mem.eql(u8, line, "/help")) return .prompt;
            return .{ .command = .{
                .context = self,
                .execute_fn = execute,
                .registry_index = 0,
                .name = line[1..],
                .argument = null,
                .usage = .valid,
            } };
        }

        fn execute(context: *anyopaque, token: CommandToken) anyerror!CommandOutcome {
            const self: *Self = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("help", token.name);
            try std.testing.expectEqual(@as(usize, 1), self.recall.session_calls);
            try std.testing.expectEqual(@as(usize, 0), self.recall.persistent_calls);
            self.executions += 1;
            return .handled;
        }
    };
    const Provider = struct {
        const Self = @This();

        recall: *const Recall,
        calls: usize = 0,
        valid: bool = true,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            self.valid = self.valid and self.recall.session_calls == 1 and
                self.recall.persistent_calls == 1;
            var users: usize = 0;
            for (request.context.items) |item| switch (item) {
                .user_message => |user| {
                    users += 1;
                    self.valid = self.valid and std.mem.eql(u8, user.text, "prompt");
                },
                else => {},
            };
            self.valid = self.valid and users == 1;
            try sink.emit(.{ .text_delta = "answer" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Seam = struct {
        const Self = @This();

        prompts: usize = 0,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            if (kind == .prompt) self.prompts += 1;
        }
    };

    var recall: Recall = .{};
    var gateway: Gateway = .{ .recall = &recall };
    var provider: Provider = .{ .recall = &recall };
    var seam: Seam = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("/help\nprompt\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .prompt_recall = PromptRecall.from(&recall),
        .command_gateway = CommandGateway.from(&gateway),
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .seam_hook = agent.Loop.SeamHook.from(&seam),
    }));
    try std.testing.expectEqual(@as(usize, 2), gateway.classifications);
    try std.testing.expectEqual(@as(usize, 1), gateway.executions);
    try std.testing.expectEqual(@as(usize, 1), recall.session_calls);
    try std.testing.expectEqual(@as(usize, 1), recall.persistent_calls);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expect(provider.valid);
    try std.testing.expectEqual(@as(usize, 1), seam.prompts);
    try std.testing.expectEqualStrings("answer\n", stdout.written());
}

test "history-changing command clears resume state without rerunning first-send hook" {
    const State = struct {
        const Self = @This();
        hook_calls: usize = 0,
        prompt_reasons: [4]ResumeReason = undefined,
        prompt_count: usize = 0,

        pub fn call(self: *Self) BeforeFirstSendError!void {
            self.hook_calls += 1;
        }

        pub fn beforePrompt(self: *Self, reason: ResumeReason) !void {
            self.prompt_reasons[self.prompt_count] = reason;
            self.prompt_count += 1;
        }

        pub fn beforeGeneration(_: *Self) !void {}
        pub fn afterTurn(_: *Self, _: TurnSummary) !void {}

        pub fn classifyCommand(self: *Self, line: []const u8) CommandClassification {
            if (!std.mem.eql(u8, line, "/new")) return .prompt;
            return .{ .command = .{
                .context = self,
                .execute_fn = execute,
                .registry_index = 0,
                .name = "new",
                .argument = null,
                .usage = .valid,
            } };
        }

        fn execute(_: *anyopaque, _: CommandToken) anyerror!CommandOutcome {
            return .history_changed;
        }
    };
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            return error.InvalidRequest;
        }
    };

    var state: State = .{};
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("prompt\n/new\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .command_gateway = CommandGateway.from(&state),
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .presentation = Presentation.from(&state),
        .before_first_send = BeforeFirstSend.from(&state),
    });
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(@as(usize, 1), state.hook_calls);
    try std.testing.expectEqual(@as(usize, 3), state.prompt_count);
    try std.testing.expectEqual(ResumeReason.none, state.prompt_reasons[2]);
}

test "command admission precedes failing execution" {
    const Recall = struct {
        const Self = @This();

        calls: usize = 0,

        pub fn admitSession(self: *Self, line: []const u8) !void {
            try std.testing.expectEqualStrings("/fail", line);
            self.calls += 1;
        }

        pub fn admitPersistent(_: *Self, _: []const u8) !void {
            return error.TestUnexpectedResult;
        }
    };
    const Gateway = struct {
        const Self = @This();

        recall: *const Recall,

        pub fn classifyCommand(self: *Self, line: []const u8) CommandClassification {
            return .{ .command = .{
                .context = self,
                .execute_fn = execute,
                .registry_index = 0,
                .name = line[1..],
                .argument = null,
                .usage = .valid,
            } };
        }

        fn execute(context: *anyopaque, _: CommandToken) anyerror!CommandOutcome {
            const self: *Self = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(@as(usize, 1), self.recall.calls);
            return error.CommandFailed;
        }
    };
    const Provider = struct {
        const Self = @This();

        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
        }
    };

    var recall: Recall = .{};
    var gateway: Gateway = .{ .recall = &recall };
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("/fail\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.CommandFailed, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .prompt_recall = PromptRecall.from(&recall),
        .command_gateway = CommandGateway.from(&gateway),
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
    }));
    try std.testing.expectEqual(@as(usize, 1), recall.calls);
    try std.testing.expectEqual(@as(usize, 0), provider.calls);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "interactive disarms generation when the agent loop fails" {
    const Control = struct {
        const Self = @This();

        active: bool = false,
        arms: usize = 0,
        disarms: usize = 0,

        pub fn clearAndArm(self: *Self) !void {
            self.active = true;
            self.arms += 1;
        }

        pub fn disarm(self: *Self) !void {
            if (!self.active) return error.NotArmed;
            self.active = false;
            self.disarms += 1;
        }
    };
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            return error.OutOfMemory;
        }
    };

    var control: Control = .{};
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("prompt\n");
    var output: std.Io.Writer.Discarding = .init(&.{});

    try std.testing.expectError(error.OutOfMemory, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &output.writer,
        .stderr = &output.writer,
        .show_prompt = false,
        .generation = Generation.from(&control),
    }));
    try std.testing.expectEqual(@as(usize, 1), control.arms);
    try std.testing.expectEqual(@as(usize, 1), control.disarms);
    try std.testing.expect(!control.active);
}

test "provider failure is turn-local and the next prompt still runs" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .failure = .{ .message = "temporary" } });
                return;
            }
            try sink.emit(.{ .text_delta = "recovered" });
            try sink.emit(.{ .done = .{} });
        }
    };

    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
    }));
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqualStrings("recovered\n", stdout.written());
    try std.testing.expectEqualStrings("zi: provider error: temporary\n", stderr.written());
}

test "empty submit resumes a failed turn without adding another user message" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            var users: usize = 0;
            for (request.context.items) |item| {
                if (item == .user_message) users += 1;
            }
            if (users != 1) return error.InvalidRequest;
            if (self.calls == 1) {
                try sink.emit(.{ .failure = .{ .message = "retry me" } });
            } else {
                try sink.emit(.{ .text_delta = "resumed" });
                try sink.emit(.{ .done = .{} });
            }
        }
    };
    const Seam = struct {
        const Self = @This();
        prompts: usize = 0,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            if (kind == .prompt) self.prompts += 1;
        }
    };

    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .seam_hook = agent.Loop.SeamHook.from(&seam),
    });
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 1), seam.prompts);
    try std.testing.expectEqualStrings("resumed\n", stdout.written());
}

test "submitted input is recalled exactly before sanitized session storage" {
    const Recall = struct {
        const Self = @This();

        called: bool = false,

        pub fn admitSession(_: *Self, _: []const u8) !void {
            return error.TestUnexpectedResult;
        }

        pub fn admitPersistent(self: *Self, line: []const u8) !void {
            try std.testing.expectEqualSlices(u8, &.{ 'a', 0, 0xff, 'b' }, line);
            self.called = true;
        }
    };
    const Provider = struct {
        const Self = @This();

        recall: *const Recall,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            if (!self.recall.called) return error.InvalidRequest;
            const expected = "a" ++ "\xef\xbf\xbd" ** 2 ++ "b";
            const user = request.context.items[1].user_message.text;
            if (!std.mem.eql(u8, expected, user)) return error.InvalidRequest;
            try sink.emit(.{ .done = .{} });
        }
    };

    var recall: Recall = .{};
    var provider: Provider = .{ .recall = &recall };
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    const bytes = [_]u8{ 'a', 0, 0xff, 'b', '\n' };
    var reader = std.Io.Reader.fixed(&bytes);
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .prompt_recall = PromptRecall.from(&recall),
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
    });
    try std.testing.expect(recall.called);
}

test "configured turn bound pauses and empty submit continues the tool tail" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "missing" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
                try sink.emit(.{ .done = .{} });
            } else {
                try sink.emit(.{ .text_delta = "done" });
                try sink.emit(.{ .done = .{} });
            }
        }
    };

    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .max_turns = 1,
    });
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqualStrings("done\n", stdout.written());
    try std.testing.expectEqualStrings(
        "zi: max turns (1) exceeded; submit an empty prompt to continue\n",
        stderr.written(),
    );
}

test "marked partial failure resumes through a durable continuation item" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .text_delta = "partial" });
                try sink.emit(.{ .failure = .{ .message = "retry me" } });
                return;
            }
            var have_continuation = false;
            for (request.context.items) |item| {
                if (item == .user_message and item.user_message.origin == .continuation) {
                    have_continuation = true;
                }
            }
            if (!have_continuation) return error.InvalidRequest;
            try sink.emit(.{ .text_delta = "resumed" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Seam = struct {
        const Self = @This();
        prompts: usize = 0,

        pub fn call(
            self: *Self,
            _: *const agent.Session.Session,
            kind: agent.Loop.SeamKind,
            _: bool,
        ) agent.Loop.HookError!void {
            if (kind == .prompt) self.prompts += 1;
        }
    };

    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .seam_hook = agent.Loop.SeamHook.from(&seam),
    });
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 2), seam.prompts);
    try std.testing.expectEqualStrings("partial\nresumed\n", stdout.written());
}

test "before-first-send hook is lazy and runs once" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            try sink.emit(.{ .done = .{} });
        }
    };
    const Hook = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn call(self: *Self) BeforeFirstSendError!void {
            self.calls += 1;
        }
    };

    var provider: Provider = .{};
    var hook: Hook = .{};
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    var empty_session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer empty_session.deinit();
    var empty_reader = std.Io.Reader.fixed("");
    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &empty_session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &empty_reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .before_first_send = BeforeFirstSend.from(&hook),
    });
    try std.testing.expectEqual(@as(usize, 0), hook.calls);

    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .before_first_send = BeforeFirstSend.from(&hook),
    });
    try std.testing.expectEqual(@as(usize, 1), hook.calls);
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
}

test "effort source resolves after the lazy first-send hook" {
    const State = struct {
        const Self = @This();
        effort: []const u8 = "old",

        pub fn resolve(self: *Self) ?[]const u8 {
            return self.effort;
        }

        pub fn call(self: *Self) BeforeFirstSendError!void {
            self.effort = "new";
        }
    };
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            if (!std.mem.eql(u8, request.context.effort orelse "", "new")) return error.InvalidRequest;
            try sink.emit(.{ .done = .{} });
        }
    };

    var state: State = .{};
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .effort = "old",
        .effort_source = EffortSource.from(&state),
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .before_first_send = BeforeFirstSend.from(&state),
    });
}

test "turn source supplies one coherent snapshot for each loop run" {
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,
        snapshot_calls: ?*usize = null,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            const models = [_][]const u8{ "model-one", "model-two" };
            const efforts = [_][]const u8{ "low", "high" };
            const prompts = [_][]const u8{ "system-one", "system-two" };
            const snapshot_calls = self.snapshot_calls orelse return error.InvalidRequest;
            if (snapshot_calls.* != self.calls + 1) return error.InvalidRequest;
            if (!std.mem.eql(u8, request.model, models[self.calls])) return error.InvalidRequest;
            if (!std.mem.eql(u8, request.context.effort orelse "", efforts[self.calls])) {
                return error.InvalidRequest;
            }
            if (!std.mem.eql(u8, request.context.system_prompt, prompts[self.calls])) {
                return error.InvalidRequest;
            }
            self.calls += 1;
            try sink.emit(.{ .done = .{} });
        }
    };
    const Source = struct {
        const Self = @This();
        calls: usize = 0,
        provider: *Provider,

        pub fn snapshot(self: *Self) TurnSnapshot {
            const models = [_][]const u8{ "model-one", "model-two" };
            const efforts = [_][]const u8{ "low", "high" };
            const prompts = [_][]const u8{ "system-one", "system-two" };
            const index = self.calls;
            self.calls += 1;
            return .{
                .provider = ai.Provider.Provider.from(self.provider, "snapshot"),
                .model = models[index],
                .model_metadata = .{},
                .model_metadata_source = null,
                .system_prompt = prompts[index],
                .tools = &.{},
                .effort = efforts[index],
                .image_input = .unknown,
                .image_input_source = null,
            };
        }
    };

    var provider: Provider = .{};
    var source: Source = .{ .provider = &provider };
    provider.snapshot_calls = &source.calls;
    var fallback_provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    _ = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fallback_provider, "fallback"),
        .model = "fallback-model",
        .system_prompt = "fallback-system",
        .effort = "fallback-effort",
        .turn_source = TurnSource.from(&source),
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
    });
    try std.testing.expectEqual(@as(usize, 2), source.calls);
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 0), fallback_provider.calls);
}

test "presentation callbacks report ordered turns and precise resume reasons" {
    const Event = enum { before_prompt, before_generation, after_turn };
    const Control = struct {
        const Self = @This();
        active: bool = false,

        pub fn clearAndArm(self: *Self) !void {
            self.active = true;
        }

        pub fn disarm(self: *Self) !void {
            self.active = false;
        }
    };
    const Provider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .text_delta = "answer" });
                try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 2, .output_tokens = 1 } } });
            } else {
                try sink.emit(.{ .failure = .{ .message = "temporary" } });
            }
        }
    };
    const Recorder = struct {
        const Self = @This();
        events: [7]Event = undefined,
        event_count: usize = 0,
        reasons: [3]ResumeReason = undefined,
        reason_count: usize = 0,
        summaries: [2]TurnSummary = undefined,
        summary_count: usize = 0,
        control: *Control,
        stdout: *std.Io.Writer.Allocating,

        pub fn beforePrompt(self: *Self, reason: ResumeReason) !void {
            self.events[self.event_count] = .before_prompt;
            self.event_count += 1;
            self.reasons[self.reason_count] = reason;
            self.reason_count += 1;
        }

        pub fn beforeGeneration(self: *Self) !void {
            self.events[self.event_count] = .before_generation;
            self.event_count += 1;
        }

        pub fn afterTurn(self: *Self, summary: TurnSummary) !void {
            if (self.control.active) return error.GenerationStillArmed;
            if (summary.outcome == .complete and !std.mem.eql(u8, self.stdout.written(), "answer\n")) {
                return error.RendererNotClosed;
            }
            if (summary.outcome == .provider_error and
                !std.mem.eql(u8, summary.diagnostic orelse "", "temporary"))
            {
                return error.DiagnosticNotReported;
            }
            self.events[self.event_count] = .after_turn;
            self.event_count += 1;
            self.summaries[self.summary_count] = summary;
            self.summary_count += 1;
        }
    };

    var control: Control = .{};
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\ntwo\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    var recorder: Recorder = .{ .control = &control, .stdout = &stdout };

    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .generation = Generation.from(&control),
        .presentation = Presentation.from(&recorder),
    }));

    try std.testing.expectEqualSlices(Event, &.{
        .before_prompt,
        .before_generation,
        .after_turn,
        .before_prompt,
        .before_generation,
        .after_turn,
        .before_prompt,
    }, recorder.events[0..recorder.event_count]);
    try std.testing.expectEqualSlices(
        ResumeReason,
        &.{ .none, .none, .provider_error },
        recorder.reasons[0..recorder.reason_count],
    );
    try std.testing.expectEqual(agent.Loop.Outcome.complete, recorder.summaries[0].outcome);
    try std.testing.expectEqual(@as(?u64, 3), recorder.summaries[0].context_tokens);
    try std.testing.expect(recorder.summaries[0].wrote_assistant_text);
    try std.testing.expectEqual(agent.Loop.Outcome.provider_error, recorder.summaries[1].outcome);
    try std.testing.expectEqual(@as(?u64, null), recorder.summaries[1].context_tokens);
    try std.testing.expect(!recorder.summaries[1].wrote_assistant_text);
}

test "presentation callback errors propagate after generation and rendering close" {
    const Control = struct {
        const Self = @This();
        active: bool = false,

        pub fn clearAndArm(self: *Self) !void {
            self.active = true;
        }

        pub fn disarm(self: *Self) !void {
            self.active = false;
        }
    };
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "answer" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const FailingPresentation = struct {
        const Self = @This();
        control: *Control,
        stdout: *std.Io.Writer.Allocating,

        pub fn beforePrompt(_: *Self, _: ResumeReason) !void {}
        pub fn beforeGeneration(_: *Self) !void {}

        pub fn afterTurn(self: *Self, _: TurnSummary) !void {
            if (self.control.active) return error.GenerationStillArmed;
            if (!std.mem.eql(u8, self.stdout.written(), "answer\n")) return error.RendererNotClosed;
            return error.PresentationFailed;
        }
    };

    var control: Control = .{};
    var provider: Provider = .{};
    var session = try agent.Session.Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var reader = std.Io.Reader.fixed("one\n");
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    var presentation: FailingPresentation = .{ .control = &control, .stdout = &stdout };

    try std.testing.expectError(error.PresentationFailed, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
        .reader = &reader,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .show_prompt = false,
        .generation = Generation.from(&control),
        .presentation = Presentation.from(&presentation),
    }));
    try std.testing.expect(!control.active);
    try std.testing.expectEqualStrings("answer\n", stdout.written());
}

test "presentation adapter propagates every callback error" {
    const Failing = struct {
        const Self = @This();

        pub fn beforePrompt(_: *Self, _: ResumeReason) !void {
            return error.BeforePromptFailed;
        }

        pub fn beforeGeneration(_: *Self) !void {
            return error.BeforeGenerationFailed;
        }

        pub fn afterTurn(_: *Self, _: TurnSummary) !void {
            return error.AfterTurnFailed;
        }
    };

    var failing: Failing = .{};
    const presentation = Presentation.from(&failing);
    try std.testing.expectError(error.BeforePromptFailed, presentation.beforePrompt(.none));
    try std.testing.expectError(error.BeforeGenerationFailed, presentation.beforeGeneration());
    try std.testing.expectError(error.AfterTurnFailed, presentation.afterTurn(.{
        .outcome = .complete,
        .elapsed_ms = 0,
        .context_tokens = null,
        .wrote_assistant_text = false,
    }));
}

test "custom turn renderer observes lifecycle and operation errors stay primary" {
    const Renderer = struct {
        const Self = @This();

        fail_begin: bool = false,
        fail_close: bool = false,
        fail_check: bool = false,
        begins: usize = 0,
        closes: usize = 0,
        checks: usize = 0,
        events: usize = 0,
        terminal: ?render.Terminal = null,

        pub fn begin(self: *Self) !agent.Loop.Observer {
            self.begins += 1;
            if (self.fail_begin) return error.RenderBeginFailed;
            return agent.Loop.Observer.from(self);
        }

        pub fn emit(self: *Self, _: ai.StreamEvent.StreamEvent) void {
            self.events += 1;
        }

        pub fn close(self: *Self, terminal_result: render.Terminal) !void {
            self.closes += 1;
            self.terminal = terminal_result;
            if (self.fail_close) return error.RenderCloseFailed;
        }

        pub fn check(self: *Self) !void {
            self.checks += 1;
            if (self.fail_check) return error.RenderCheckFailed;
        }

        pub fn wroteAssistantText(_: *Self) bool {
            return false;
        }
    };
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "answer" });
            try sink.emit(.{ .done = .{} });
        }
    };

    // Loop validation is the primary failure even when renderer cleanup fails.
    {
        var provider: Provider = .{};
        var renderer: Renderer = .{ .fail_close = true, .fail_check = true };
        var session = try agent.Session.Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var reader = std.Io.Reader.fixed("go\n");
        var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr.deinit();

        try std.testing.expectError(error.InvalidMaxTurns, run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "",
            .reader = &reader,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
            .show_prompt = false,
            .turn_renderer = TurnRenderer.from(&renderer),
            .max_turns = 0,
        }));
        try std.testing.expectEqual(@as(usize, 1), renderer.begins);
        try std.testing.expectEqual(@as(usize, 1), renderer.closes);
        try std.testing.expectEqual(@as(usize, 1), renderer.checks);
        try std.testing.expectEqual(render.Terminal.failure, renderer.terminal.?);
    }

    // A begin failure remains primary, but its close-safe lifecycle still runs.
    {
        var provider: Provider = .{};
        var renderer: Renderer = .{ .fail_begin = true, .fail_close = true, .fail_check = true };
        var session = try agent.Session.Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var reader = std.Io.Reader.fixed("go\n");
        var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr.deinit();

        try std.testing.expectError(error.RenderBeginFailed, run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "",
            .reader = &reader,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
            .show_prompt = false,
            .turn_renderer = TurnRenderer.from(&renderer),
        }));
        try std.testing.expectEqual(@as(usize, 1), renderer.closes);
        try std.testing.expectEqual(@as(usize, 1), renderer.checks);
    }

    // With a successful operation, the first cleanup error is returned.
    {
        var provider: Provider = .{};
        var renderer: Renderer = .{ .fail_close = true, .fail_check = true };
        var session = try agent.Session.Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var reader = std.Io.Reader.fixed("go\n");
        var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr.deinit();

        try std.testing.expectError(error.RenderCloseFailed, run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "",
            .reader = &reader,
            .stdout = &stdout.writer,
            .stderr = &stderr.writer,
            .show_prompt = false,
            .turn_renderer = TurnRenderer.from(&renderer),
        }));
        try std.testing.expect(renderer.events >= 2);
        try std.testing.expectEqual(render.Terminal.complete, renderer.terminal.?);
        try std.testing.expectEqual(@as(usize, 1), renderer.checks);
    }
}
