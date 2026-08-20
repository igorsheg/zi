const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const AgentSession = @import("AgentSession.zig");
const session_event = @import("AgentSessionEvent.zig");
const OwnedAgentSessionEvent = @import("OwnedAgentSessionEvent.zig");

const TurnWorker = @This();

pub const Limits = struct {
    max_prompt_bytes: usize = 1024 * 1024,
    max_queued_prompts: usize = 16,
    max_queued_events: usize = 256,
    max_queued_event_bytes: usize = OwnedAgentSessionEvent.default_max_retained_bytes,
    max_queued_completions: usize = 32,
    event: OwnedAgentSessionEvent.Limits = .{},
};

pub const StartError = error{
    OutOfMemory,
    ThreadQuotaExceeded,
    SystemResources,
    LockedMemoryLimitExceeded,
    Unexpected,
    EventsAlreadyBound,
    InvalidWorkerLimits,
};

pub const SubmitError = error{
    OutOfMemory,
    EmptyPrompt,
    PromptTooLarge,
    QueueFull,
    WorkerStopped,
    SessionUnavailable,
};

pub const RunOutcome = union(enum) {
    completed,
    failed: AgentSession.RunError,
};

pub const Completion = struct {
    run_id: agent.event.RunId,
    outcome: RunOutcome,
    availability: session_event.Availability,
};

pub const Snapshot = struct {
    processing: bool,
    queued_prompts: usize,
    queued_events: usize,
    queued_event_bytes: usize,
    queued_completions: usize,
    stop_requested: bool,
    availability: Availability,
};

pub const Availability = enum {
    ready,
    poisoned,
};

/// Detached worker output. Consumers reduce `events` in order before matching
/// `completions`; a completion also settles policy when event delivery failed
/// before the corresponding `agent_settled` event.
pub const Batch = struct {
    events: std.ArrayList(OwnedAgentSessionEvent),
    completions: std.ArrayList(Completion),

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        for (self.events.items) |*event| event.deinit();
        self.events.deinit(allocator);
        self.completions.deinit(allocator);
        self.* = undefined;
    }
};

/// Erased ownership of a runtime whose `session()` value is mutated only by
/// the worker thread. The worker also disposes the runtime on that thread.
pub const SessionOwner = struct {
    context: *anyopaque,
    session_fn: *const fn (*anyopaque) *AgentSession,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn from(implementation: anytype) SessionOwner {
        const Implementation = @TypeOf(implementation.*);
        const Adapter = struct {
            fn session(context: *anyopaque) *AgentSession {
                const value: *Implementation = @ptrCast(@alignCast(context));
                return value.session();
            }

            // The erased implementation owns its invalidation contract.
            // ziglint-ignore: Z030
            fn deinit(context: *anyopaque) void {
                const value: *Implementation = @ptrCast(@alignCast(context));
                value.deinit();
            }
        };
        return .{
            .context = implementation,
            .session_fn = Adapter.session,
            .deinit_fn = Adapter.deinit,
        };
    }

    fn session(self: SessionOwner) *AgentSession {
        return self.session_fn(self.context);
    }

    fn deinit(self: SessionOwner) void {
        self.deinit_fn(self.context);
    }
};

allocator: std.mem.Allocator,
io: std.Io,
owner: SessionOwner,
limits: Limits,
thread: std.Thread,
mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
prompts: std.ArrayList([]u8) = .empty,
events: std.ArrayList(OwnedAgentSessionEvent) = .empty,
queued_event_bytes: usize = 0,
completions: std.ArrayList(Completion) = .empty,
cancellation: ai.model.CancellationToken = .{},
active_run_id: ?agent.event.RunId = null,
admitted: bool = false,
processing: bool = false,
stop_requested: bool = false,
availability: Availability = .ready,

/// On success, ownership transfers to the worker. On failure, the caller still
/// owns `owner`; no thread can observe its session after this function returns.
/// `allocator` must remain valid and support calls from the worker and consumer
/// threads until `deinit` returns.
pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: SessionOwner,
    limits: Limits,
) StartError!*TurnWorker {
    if (limits.max_prompt_bytes == 0 or
        limits.max_queued_prompts == 0 or
        limits.max_queued_events == 0 or
        limits.max_queued_event_bytes == 0 or
        limits.max_queued_completions == 0)
    {
        return error.InvalidWorkerLimits;
    }

    const self = try allocator.create(TurnWorker);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .owner = owner,
        .limits = limits,
        .thread = undefined,
    };
    errdefer {
        self.prompts.deinit(allocator);
        self.events.deinit(allocator);
        self.completions.deinit(allocator);
    }
    try self.prompts.ensureTotalCapacity(allocator, limits.max_queued_prompts);
    try self.events.ensureTotalCapacity(allocator, limits.max_queued_events);
    try self.completions.ensureTotalCapacity(allocator, limits.max_queued_completions);

    self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    owner.session().bindEvents(.{
        .context = self,
        .emitFn = emitSessionEvent,
    }) catch |failure| {
        self.mutex.lockUncancelable(io);
        self.stop_requested = true;
        self.condition.broadcast(io);
        self.mutex.unlock(io);
        self.thread.join();
        return failure;
    };

    self.mutex.lockUncancelable(io);
    self.admitted = true;
    self.condition.broadcast(io);
    self.mutex.unlock(io);
    return self;
}

pub fn submit(self: *TurnWorker, prompt: []const u8) SubmitError!void {
    if (prompt.len == 0) return error.EmptyPrompt;
    if (prompt.len > self.limits.max_prompt_bytes) return error.PromptTooLarge;
    const owned = try self.allocator.dupe(u8, prompt);
    errdefer self.allocator.free(owned);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.stop_requested) return error.WorkerStopped;
    if (self.availability == .poisoned) return error.SessionUnavailable;
    if (self.prompts.items.len >= self.limits.max_queued_prompts) return error.QueueFull;
    self.prompts.appendAssumeCapacity(owned);
    self.condition.broadcast(self.io);
}

pub fn requestCancel(self: *TurnWorker) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (!self.processing or self.stop_requested) return false;
    self.cancellation.cancel();
    return true;
}

pub fn snapshot(self: *TurnWorker) Snapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return .{
        .processing = self.processing,
        .queued_prompts = self.prompts.items.len,
        .queued_events = self.events.items.len,
        .queued_event_bytes = self.queued_event_bytes,
        .queued_completions = self.completions.items.len,
        .stop_requested = self.stop_requested,
        .availability = self.availability,
    };
}

/// Transfers all currently queued events and completions to the caller.
pub fn takeBatch(self: *TurnWorker) error{OutOfMemory}!Batch {
    var replacement_events: std.ArrayList(OwnedAgentSessionEvent) = .empty;
    errdefer replacement_events.deinit(self.allocator);
    try replacement_events.ensureTotalCapacity(self.allocator, self.limits.max_queued_events);
    var replacement_completions: std.ArrayList(Completion) = .empty;
    errdefer replacement_completions.deinit(self.allocator);
    try replacement_completions.ensureTotalCapacity(self.allocator, self.limits.max_queued_completions);

    self.mutex.lockUncancelable(self.io);
    const events = self.events;
    const completions = self.completions;
    self.events = replacement_events;
    self.queued_event_bytes = 0;
    self.completions = replacement_completions;
    self.condition.broadcast(self.io);
    self.mutex.unlock(self.io);
    return .{ .events = events, .completions = completions };
}

fn waitUntilIdle(self: *TurnWorker) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while ((self.processing or self.prompts.items.len > 0) and !self.stop_requested) {
        self.condition.wait(self.io, &self.mutex) catch continue;
    }
}

pub fn requestStop(self: *TurnWorker) void {
    self.mutex.lockUncancelable(self.io);
    self.stop_requested = true;
    if (self.processing) self.cancellation.cancel();
    self.condition.broadcast(self.io);
    self.mutex.unlock(self.io);
}

// Heap destruction follows explicit field invalidation.
// ziglint-ignore: Z030
pub fn deinit(self: *TurnWorker) void {
    self.requestStop();
    self.thread.join();
    for (self.prompts.items) |prompt| self.allocator.free(prompt);
    self.prompts.deinit(self.allocator);
    for (self.events.items) |*event| event.deinit();
    self.events.deinit(self.allocator);
    self.completions.deinit(self.allocator);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn workerMain(self: *TurnWorker) void {
    self.mutex.lockUncancelable(self.io);
    while (!self.admitted and !self.stop_requested) {
        self.condition.wait(self.io, &self.mutex) catch continue;
    }
    if (!self.admitted) {
        self.mutex.unlock(self.io);
        return;
    }
    self.mutex.unlock(self.io);
    defer self.owner.deinit();

    while (self.takePrompt()) |prompt| {
        defer self.allocator.free(prompt);
        const result = self.owner.session().promptWithControl(prompt, .{
            .cancellation = &self.cancellation,
        });
        const outcome: RunOutcome = if (result) |_| .completed else |failure| .{ .failed = failure };

        self.mutex.lockUncancelable(self.io);
        self.processing = false;
        const run_id = self.active_run_id orelse unreachable;
        const availability: session_event.Availability = switch (self.owner.session().state()) {
            .ready => .ready,
            .poisoned => .poisoned,
            .running => unreachable,
        };
        self.availability = switch (availability) {
            .ready => .ready,
            .poisoned => .poisoned,
        };
        while (self.completions.items.len >= self.limits.max_queued_completions and
            !self.stop_requested)
        {
            self.condition.wait(self.io, &self.mutex) catch continue;
        }
        if (!self.stop_requested) self.completions.appendAssumeCapacity(.{
            .run_id = run_id,
            .outcome = outcome,
            .availability = availability,
        });
        self.active_run_id = null;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
}

fn takePrompt(self: *TurnWorker) ?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (self.prompts.items.len == 0 and !self.stop_requested) {
        self.processing = false;
        self.condition.broadcast(self.io);
        self.condition.wait(self.io, &self.mutex) catch continue;
    }
    if (self.stop_requested) return null;
    self.cancellation = .{};
    self.processing = true;
    return self.prompts.orderedRemove(0);
}

fn emitSessionEvent(
    context: *anyopaque,
    event: AgentSession.Event,
) session_event.SinkError!void {
    const self: *TurnWorker = @ptrCast(@alignCast(context));
    if (event == .agent_start) {
        self.mutex.lockUncancelable(self.io);
        self.active_run_id = event.agent_start.run_id;
        self.mutex.unlock(self.io);
    }
    var owned = OwnedAgentSessionEvent.init(self.allocator, event, self.limits.event) catch |failure| {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.EventTooLarge, error.TooManyItems => error.ConsumerStopped,
        };
    };
    errdefer owned.deinit();

    if (owned.retained_bytes > self.limits.max_queued_event_bytes) {
        return error.ConsumerStopped;
    }

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while ((self.events.items.len >= self.limits.max_queued_events or
        self.queued_event_bytes > self.limits.max_queued_event_bytes - owned.retained_bytes) and
        !self.stop_requested)
    {
        self.condition.wait(self.io, &self.mutex) catch continue;
    }
    if (self.stop_requested) return error.ConsumerStopped;
    self.events.appendAssumeCapacity(owned);
    self.queued_event_bytes += owned.retained_bytes;
    self.condition.broadcast(self.io);
}

const TestOwner = struct {
    allocator: std.mem.Allocator,
    session_value: AgentSession,
    disposed: *std.atomic.Value(bool),

    fn create(
        allocator: std.mem.Allocator,
        model: ai.model.Model,
        cwd: std.Io.Dir,
        disposed: *std.atomic.Value(bool),
    ) !*TestOwner {
        const self = try allocator.create(TestOwner);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .session_value = try AgentSession.init(allocator, std.testing.io, model, cwd, .{}),
            .disposed = disposed,
        };
        return self;
    }

    fn session(self: *TestOwner) *AgentSession {
        return &self.session_value;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    fn deinit(self: *TestOwner) void {
        const allocator = self.allocator;
        self.session_value.deinit();
        self.disposed.store(true, .release);
        self.* = undefined;
        allocator.destroy(self);
    }
};

test "worker serializes owned prompts and publishes owned ordered events" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "worker" },
        .steps = &.{
            .{ .text = "first answer" },
            .{ .text = "second answer" },
        },
    };
    var disposed = std.atomic.Value(bool).init(false);
    const owner = try TestOwner.create(
        std.testing.allocator,
        scripted.asModel(),
        temporary.dir,
        &disposed,
    );
    var worker = try TurnWorker.start(
        std.testing.allocator,
        std.testing.io,
        SessionOwner.from(owner),
        .{},
    );
    defer worker.deinit();

    var first_prompt = [_]u8{ 'f', 'i', 'r', 's', 't' };
    try worker.submit(&first_prompt);
    @memset(&first_prompt, 'x');
    try worker.submit("second");
    worker.waitUntilIdle();

    var batch = try worker.takeBatch();
    defer batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), batch.completions.items.len);
    for (batch.completions.items, 1..) |completion, expected_run_id| {
        try std.testing.expect(completion.outcome == .completed);
        try std.testing.expectEqual(
            @as(u64, @intCast(expected_run_id)),
            @intFromEnum(completion.run_id),
        );
    }

    var starts: usize = 0;
    var settled: usize = 0;
    var first_seen = false;
    var second_seen = false;
    for (batch.events.items) |event| switch (event.value) {
        .agent_start => starts += 1,
        .message_start => |started| switch (started.message) {
            .request => |request| {
                const text = request.parts[0].user.text;
                first_seen = first_seen or std.mem.eql(u8, text, "first");
                second_seen = second_seen or std.mem.eql(u8, text, "second");
            },
            .response => {},
        },
        .agent_settled => settled += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), starts);
    try std.testing.expectEqual(@as(usize, 2), settled);
    try std.testing.expect(first_seen);
    try std.testing.expect(second_seen);
    try std.testing.expect(!disposed.load(.acquire));
}

test "worker cancellation settles ready and admits another prompt" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "worker-cancel" },
        .steps = &.{
            .{ .tool_call = .{
                .id = "call-1",
                .name = "bash",
                .arguments_json = "{\"command\":\": > started; end=$((SECONDS+5)); " ++
                    "while (( SECONDS < end )); do :; done; : > late\"}",
            } },
            .{ .text = "resumed" },
        },
    };
    var disposed = std.atomic.Value(bool).init(false);
    const owner = try TestOwner.create(
        std.testing.allocator,
        scripted.asModel(),
        temporary.dir,
        &disposed,
    );
    var worker = try TurnWorker.start(
        std.testing.allocator,
        std.testing.io,
        SessionOwner.from(owner),
        .{},
    );
    defer worker.deinit();

    try worker.submit("cancel this");
    const delay: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(1),
        .clock = .awake,
    } };
    var started = false;
    for (0..2_000) |_| {
        temporary.dir.access(std.testing.io, "started", .{}) catch |failure| switch (failure) {
            error.FileNotFound => {
                try delay.sleep(std.testing.io);
                continue;
            },
            else => return failure,
        };
        started = true;
        break;
    }
    try std.testing.expect(started);
    try std.testing.expect(worker.requestCancel());
    worker.waitUntilIdle();

    var cancelled = try worker.takeBatch();
    defer cancelled.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cancelled.completions.items.len);
    try std.testing.expect(cancelled.completions.items[0].outcome == .failed);
    try std.testing.expectEqual(
        error.Cancelled,
        cancelled.completions.items[0].outcome.failed,
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(std.testing.io, "late", .{}),
    );

    try worker.submit("continue");
    worker.waitUntilIdle();
    var resumed = try worker.takeBatch();
    defer resumed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), resumed.completions.items.len);
    try std.testing.expect(resumed.completions.items[0].outcome == .completed);
    var settled_ready = false;
    for (resumed.events.items) |event| switch (event.value) {
        .agent_settled => |settled| settled_ready = settled.availability == .ready,
        else => {},
    };
    try std.testing.expect(settled_ready);
}

test "worker rejects an event larger than its aggregate queue bound without blocking" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "worker-event-bound" },
        .steps = &.{.{ .text = "unused" }},
    };
    var disposed = std.atomic.Value(bool).init(false);
    const owner = try TestOwner.create(
        std.testing.allocator,
        scripted.asModel(),
        temporary.dir,
        &disposed,
    );
    var worker = try TurnWorker.start(
        std.testing.allocator,
        std.testing.io,
        SessionOwner.from(owner),
        .{ .max_queued_event_bytes = 1 },
    );
    defer worker.deinit();

    try worker.submit("too large");
    worker.waitUntilIdle();
    var batch = try worker.takeBatch();
    defer batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), batch.completions.items.len);
    try std.testing.expect(batch.completions.items[0].outcome == .failed);
    try std.testing.expectEqual(
        error.EventConsumerStopped,
        batch.completions.items[0].outcome.failed,
    );
}

test "worker validates submissions and disposes its session on its worker thread" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai.testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "worker-lifetime" },
        .steps = &.{.{ .text = "unused" }},
    };
    var disposed = std.atomic.Value(bool).init(false);
    const owner = try TestOwner.create(
        std.testing.allocator,
        scripted.asModel(),
        temporary.dir,
        &disposed,
    );
    var worker = try TurnWorker.start(
        std.testing.allocator,
        std.testing.io,
        SessionOwner.from(owner),
        .{ .max_prompt_bytes = 4 },
    );

    try std.testing.expectError(error.EmptyPrompt, worker.submit(""));
    try std.testing.expectError(error.PromptTooLarge, worker.submit("12345"));
    worker.deinit();
    try std.testing.expect(disposed.load(.acquire));
}
