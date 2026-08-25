//! Synchronous provider-neutral compaction transaction. Compaction policy and
//! text construction remain in `Compact.zig`.

const std = @import("std");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");
const Compact = @import("Compact.zig");
const Loop = @import("Loop.zig");
const SessionModule = @import("Session.zig");
const TurnModule = @import("Turn.zig");

const Item = ai.Item.Item;
const Session = SessionModule.Session;
const Turn = TurnModule.Turn;

pub const Observer = Loop.Observer;
pub const SeamHook = Loop.SeamHook;
pub const UsageObserver = Loop.UsageObserver;

pub const tool_call_rejection =
    "[rejected] Tool calls are disabled while summarizing. Respond with the summary text " ++
    "only — do not call any tools.";
const maximum_diagnostic_bytes: usize = 8 * 1024;
const maximum_scratch_items: usize = 24 * 1024;

pub const Cancellation = struct {
    context: *anyopaque,
    sample_fn: *const fn (*anyopaque) bool,

    pub fn sample(self: Cancellation) bool {
        return self.sample_fn(self.context);
    }

    pub fn from(implementation: anytype) Cancellation {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Cancellation.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn sample(context: *anyopaque) bool {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.sample();
            }
        };
        return .{ .context = implementation, .sample_fn = Adapter.sample };
    }
};

pub const Params = struct {
    session: *Session,
    provider: ai.Provider.Provider,
    model: []const u8,
    model_metadata: ai.ModelMeta.Metadata = .{},
    system_prompt: []const u8,
    tools: []const tool.Tool.Tool = &.{},
    effort: ?[]const u8 = null,
    focus: ?[]const u8 = null,
    max_attempts: usize = Compact.max_logical_attempts,
    tick: ?ai.Provider.Tick = null,
    cancellation: ?Cancellation = null,
    observer: ?Observer = null,
    seam_hook: ?SeamHook = null,
    usage_observer: ?UsageObserver = null,
};

pub const Outcome = enum {
    compacted,
    no_summary,
    provider_failure,
    cancelled,
};

pub const Result = struct {
    outcome: Outcome,
    attempts: usize,
    diagnostic: ?[]u8 = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.diagnostic) |diagnostic| allocator.free(diagnostic);
        self.* = undefined;
    }
};

pub const RunError = error{
    OutOfMemory,
    SessionBusy,
    InstructionsTooLarge,
    SummaryTooLarge,
    FinalTextTooLarge,
    TooManyItems,
    TooManyPendingToolCalls,
    TooManyRetryUsages,
    TextTooLarge,
    ReasoningTooLarge,
    ToolArgumentsTooLarge,
    ToolIdTooLarge,
    ToolNameTooLarge,
    ReasoningOpaqueTooLarge,
    UserTextTooLarge,
    ProviderIdTooLarge,
    ModelIdTooLarge,
    LabelTooLarge,
    EffortTooLarge,
    PresetTooLarge,
    RetainedDataTooLarge,
    TooManyImages,
    ImageDataTooLarge,
    ProvenanceTooLarge,
    TurnStillStreaming,
    TurnNeedsRepair,
    InvalidItemIndex,
    InvalidItem,
    InvalidUsage,
    InvalidRegistry,
    InvalidResult,
    InvalidMaxAttempts,
    ScratchTooLarge,
    HookFailed,
    HookIndeterminate,
    UsageCapacityExceeded,
};

const Captured = struct {
    allocator: std.mem.Allocator,
    response: ai.StreamEvent.ResponseIdentity = .{},
    diagnostic: ?[]u8 = null,
    has_response: bool = false,

    fn deinit(self: *Captured) void {
        if (self.response.id) |value| self.allocator.free(value);
        if (self.response.model) |value| self.allocator.free(value);
        if (self.response.route) |value| self.allocator.free(value);
        if (self.diagnostic) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn takeDiagnostic(self: *Captured) ?[]u8 {
        const result = self.diagnostic;
        self.diagnostic = null;
        return result;
    }

    fn copyOptional(self: *Captured, value: ?[]const u8) error{OutOfMemory}!?[]u8 {
        const bytes = value orelse return null;
        const owned = try self.allocator.dupe(u8, bytes[0..@min(bytes.len, maximum_diagnostic_bytes)]);
        return owned;
    }

    fn copyResponse(self: *Captured, response: ai.StreamEvent.ResponseIdentity) error{OutOfMemory}!void {
        if (self.has_response) return;
        self.has_response = true;
        self.response.id = try self.copyOptional(response.id);
        errdefer if (self.response.id) |value| {
            self.allocator.free(value);
            self.response.id = null;
        };
        self.response.model = try self.copyOptional(response.model);
        errdefer if (self.response.model) |value| {
            self.allocator.free(value);
            self.response.model = null;
        };
        self.response.route = try self.copyOptional(response.route);
    }

    fn copyDiagnostic(self: *Captured, message: []const u8) error{OutOfMemory}!void {
        if (self.diagnostic != null) return;
        self.diagnostic = try self.allocator.dupe(u8, message[0..@min(message.len, maximum_diagnostic_bytes)]);
    }
};

const Sink = struct {
    turn: *Turn,
    captured: *Captured,
    observer: ?Observer,
    assembly_error: ?RunError = null,

    pub fn emit(self: *Sink, event: ai.StreamEvent.StreamEvent) ai.Provider.DeliveryError!void {
        if (self.observer) |observer| observer.emit(event);
        self.turn.consume(event) catch |err| {
            self.assembly_error = err;
            return error.Cancelled;
        };
        switch (event) {
            .done => |done| self.captured.copyResponse(done.response) catch |err| {
                self.assembly_error = err;
                return error.Cancelled;
            },
            .failure => |failure| {
                self.captured.copyDiagnostic(failure.message) catch |err| {
                    self.assembly_error = err;
                    return error.Cancelled;
                };
                if (failure.response) |response| self.captured.copyResponse(response) catch |err| {
                    self.assembly_error = err;
                    return error.Cancelled;
                };
            },
            else => {},
        }
    }
};

const CancelState = struct {
    cancellation: ?Cancellation,
    upstream: ?ai.Provider.Tick,
    latched: bool = false,

    fn sample(self: *CancelState) bool {
        if (self.cancellation) |cancellation| self.latched = self.latched or cancellation.sample();
        return self.latched;
    }

    pub fn poll(self: *CancelState) ai.Provider.DeliveryError!void {
        if (self.upstream) |tick| try tick.poll();
        if (self.sample()) return error.Cancelled;
    }
};

fn mapHookError(err: Loop.HookError) RunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.HookFailed,
        error.Indeterminate => error.HookIndeterminate,
    };
}

const UsageInputResolution = struct {
    input: SessionModule.UsageInput,
    spend: ai.UsagePricing.Spend,
    attempts: [TurnModule.maximum_retry_usages + 1]ai.Usage.StreamUsage = undefined,
    attempt_count: usize = 0,
};

fn mapUsageObserverError(err: Loop.UsageObserverError) RunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CapacityExceeded => error.UsageCapacityExceeded,
        error.Failed => error.HookFailed,
        error.Indeterminate => error.HookIndeterminate,
    };
}

fn usageInput(
    params: Params,
    turn: *const Turn,
    elapsed_ms: u64,
    response: ai.StreamEvent.ResponseIdentity,
) UsageInputResolution {
    const priced = ai.UsagePricing.resolveAttempts(
        turn.retryUsages(),
        turn.usage,
        elapsed_ms,
        &params.model_metadata,
    );
    var result: UsageInputResolution = .{
        .input = .{
            .stream = priced.footer.stream,
            .elapsed_ms = priced.footer.elapsed_ms,
            .uncached_input_tokens = priced.footer.uncached_input_tokens,
            .cost_input_usd = priced.footer.cost_input_usd,
            .cost_cache_read_usd = priced.footer.cost_cache_read_usd,
            .cost_cache_write_usd = priced.footer.cost_cache_write_usd,
            .cost_output_usd = priced.footer.cost_output_usd,
            .cost_total_usd = priced.footer.cost_total_usd,
            .cost_estimated = priced.footer.cost_estimated,
            .response = response,
            .source_provider = params.provider.id,
            .source_model = params.model,
        },
        .spend = priced.spend,
    };
    const retries = turn.retryUsages();
    @memcpy(result.attempts[0..retries.len], retries);
    result.attempts[retries.len] = turn.usage;
    result.attempt_count = retries.len + 1;
    return result;
}

fn observeLatestUsage(params: Params, resolution: *const UsageInputResolution) RunError!void {
    const observer = params.usage_observer orelse return;
    const item = params.session.items()[params.session.items().len - 1];
    std.debug.assert(item == .turn_usage);
    observer.observe(.{
        .footer = item.turn_usage.value,
        .spend = resolution.spend,
        .attempts = resolution.attempts[0..resolution.attempt_count],
        .kind = .compaction,
        .terminal_context_tokens = null,
    }) catch |err| return mapUsageObserverError(err);
}

fn prepareUsage(
    params: Params,
    input: SessionModule.UsageInput,
) RunError!SessionModule.PreparedUsage {
    params.session.beginCompactionMutation();
    const prepared = params.session.prepareCompactionUsage(input) catch |err| {
        params.session.endCompactionMutation();
        return err;
    };
    params.session.endCompactionMutation();
    return prepared;
}

fn commitUsage(
    params: Params,
    prepared: *SessionModule.PreparedUsage,
    resolution: *const UsageInputResolution,
) RunError!void {
    params.session.beginCompactionMutation();
    params.session.commitPreparedUsage(prepared);
    params.session.endCompactionMutation();
    try observeLatestUsage(params, resolution);
}

fn commitAccepted(
    params: Params,
    seed: []const u8,
    prepared: *SessionModule.PreparedUsage,
) RunError!void {
    params.session.beginCompactionMutation();
    params.session.commitCompactSeedPrepared(seed, prepared) catch |err| {
        params.session.endCompactionMutation();
        return err;
    };
    params.session.endCompactionMutation();
}

fn callSeam(params: Params, next_action: bool) RunError!void {
    const hook = params.seam_hook orelse return;
    hook.call(params.session, .compaction, next_action) catch |err| return mapHookError(err);
}

fn commitTerminalUsage(
    params: Params,
    prepared: *SessionModule.PreparedUsage,
    resolution: *const UsageInputResolution,
) RunError!void {
    try commitUsage(params, prepared, resolution);
    try callSeam(params, false);
}

fn copyStreamErrorDiagnostic(
    allocator: std.mem.Allocator,
    stream_error: ai.Provider.StreamError,
) error{OutOfMemory}![]u8 {
    const name = @errorName(stream_error);
    return allocator.dupe(u8, name[0..@min(name.len, maximum_diagnostic_bytes)]);
}

fn appendScratchClone(allocator: std.mem.Allocator, scratch: *std.ArrayList(Item), item: Item) RunError!void {
    if (scratch.items.len >= maximum_scratch_items) return error.ScratchTooLarge;
    var cloned = try item.clone(allocator);
    errdefer cloned.deinit(allocator);
    try scratch.append(allocator, cloned);
}

fn appendRejectedResponse(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(Item),
    response: []const Item,
) RunError!void {
    for (response) |item| try appendScratchClone(allocator, scratch, item);
    for (response) |item| if (item == .tool_call) {
        const rejected: Item = .{ .tool_result = .{
            .call_id = item.tool_call.id,
            .output = @constCast(tool_call_rejection),
            .origin = .refused,
        } };
        try appendScratchClone(allocator, scratch, rejected);
    };
}

/// Runs a standalone transaction against an idle session.
pub fn run(allocator: std.mem.Allocator, io: std.Io, params: Params) RunError!Result {
    return runWithLease(allocator, io, params, .standalone);
}

/// Runs from inside `Loop.ContinuationHook` and restores the hook phase.
pub fn runContinuation(allocator: std.mem.Allocator, io: std.Io, params: Params) RunError!Result {
    return runWithLease(allocator, io, params, .continuation);
}

const Lease = enum { standalone, continuation };

fn runWithLease(allocator: std.mem.Allocator, io: std.Io, params: Params, lease: Lease) RunError!Result {
    if (params.max_attempts == 0 or params.max_attempts > Compact.max_logical_attempts) return error.InvalidMaxAttempts;
    switch (lease) {
        .standalone => try params.session.beginStandaloneCompaction(),
        .continuation => try params.session.beginContinuationCompaction(),
    }
    defer switch (lease) {
        .standalone => params.session.endStandaloneCompaction(),
        .continuation => params.session.endContinuationCompaction(),
    };

    const dispatch = try tool.Dispatch.Dispatch.init(params.tools, .{});
    const definitions = try dispatch.advertisedDefinitions(allocator);
    defer allocator.free(definitions);
    var checkpoint = try Compact.buildCheckpointPrompt(allocator, params.focus);
    defer checkpoint.deinit(allocator);

    const retained = params.session.items();
    const floor = ai.Item.contextFloor(retained);
    const context_items = retained[floor..];
    if (context_items.len + 1 > maximum_scratch_items) return error.ScratchTooLarge;
    var scratch: std.ArrayList(Item) = .empty;
    const owned_start = context_items.len + 1;
    defer {
        if (scratch.items.len > owned_start) {
            for (scratch.items[owned_start..]) |*item| item.deinit(allocator);
        }
        scratch.deinit(allocator);
    }
    try scratch.ensureUnusedCapacity(allocator, context_items.len + 1);
    scratch.appendSliceAssumeCapacity(context_items);
    scratch.appendAssumeCapacity(.{ .user_message = .{ .text = checkpoint.bytes } });

    var cancel_state: CancelState = .{ .cancellation = params.cancellation, .upstream = params.tick };
    var attempt: usize = 0;
    while (attempt < params.max_attempts) {
        attempt += 1;
        var turn = Turn.init(allocator, .{});
        defer turn.deinit();
        var captured: Captured = .{ .allocator = allocator };
        defer captured.deinit();
        var sink: Sink = .{ .turn = &turn, .captured = &captured, .observer = params.observer };
        const started_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        const stream_result = params.provider.stream(allocator, io, .{
            .model = params.model,
            .context = .{
                .system_prompt = params.system_prompt,
                .items = scratch.items,
                .tools = definitions,
                .effort = params.effort,
            },
            .tick = ai.Provider.Tick.from(&cancel_state),
        }, ai.Provider.EventSink.from(&sink));
        const finished_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        const elapsed_ms: u64 = @intCast(@max(0, finished_ns - started_ns) / std.time.ns_per_ms);
        const resolution = usageInput(params, &turn, elapsed_ms, captured.response);
        const cancelled = cancel_state.sample();
        var prepared = try prepareUsage(params, resolution.input);
        defer prepared.deinit(params.session.allocator);

        if (sink.assembly_error) |assembly_error| {
            try commitTerminalUsage(params, &prepared, &resolution);
            return assembly_error;
        }
        if (stream_result) |_| {} else |stream_error| {
            if (stream_error == error.OutOfMemory) {
                try commitTerminalUsage(params, &prepared, &resolution);
                return error.OutOfMemory;
            }
            var diagnostic = captured.takeDiagnostic();
            errdefer if (diagnostic) |value| allocator.free(value);
            if (diagnostic == null) {
                diagnostic = copyStreamErrorDiagnostic(allocator, stream_error) catch |err| {
                    try commitTerminalUsage(params, &prepared, &resolution);
                    return err;
                };
            }
            try commitTerminalUsage(params, &prepared, &resolution);
            return .{
                .outcome = if (stream_error == error.Cancelled or cancelled) .cancelled else .provider_failure,
                .attempts = attempt,
                .diagnostic = diagnostic,
            };
        }
        if (turn.state != .done or cancelled) {
            try commitTerminalUsage(params, &prepared, &resolution);
            return .{
                .outcome = if (cancelled) .cancelled else .provider_failure,
                .attempts = attempt,
                .diagnostic = captured.takeDiagnostic(),
            };
        }

        const summary = Compact.selectSummary(.{ .terminal = .done, .items = turn.items.items });
        var has_tool_call = false;
        for (turn.items.items) |item| if (item == .tool_call) {
            has_tool_call = true;
            break;
        };
        if (!has_tool_call) {
            if (summary) |text| {
                var seed = Compact.buildSeed(allocator, text) catch |err| {
                    try commitTerminalUsage(params, &prepared, &resolution);
                    return err;
                };
                defer seed.deinit(allocator);
                commitAccepted(params, seed.bytes, &prepared) catch |err| {
                    try commitTerminalUsage(params, &prepared, &resolution);
                    return err;
                };
                try observeLatestUsage(params, &resolution);
                if (lease == .standalone) try callSeam(params, false);
                return .{ .outcome = .compacted, .attempts = attempt };
            }
            try commitTerminalUsage(params, &prepared, &resolution);
            return .{ .outcome = .no_summary, .attempts = attempt };
        }

        try commitUsage(params, &prepared, &resolution);
        if (attempt == params.max_attempts) {
            try callSeam(params, false);
            return .{ .outcome = .no_summary, .attempts = attempt };
        }
        try callSeam(params, true);
        try appendRejectedResponse(allocator, &scratch, turn.items.items);
    }

    unreachable;
}

const ScriptedProvider = struct {
    const Step = enum { tool, empty, failure, success, transport_failure, cancelled };

    steps: []const Step,
    calls: usize = 0,

    pub fn stream(
        _: std.mem.Allocator,
        _: std.Io,
        self: *ScriptedProvider,
        request: ai.Provider.Request,
        sink: ai.Provider.EventSink,
    ) ai.Provider.StreamError!void {
        std.debug.assert(request.context.tools.len == 0);
        std.debug.assert(request.context.items.len != 0);
        var saw_checkpoint = false;
        for (request.context.items) |item| if (item == .user_message and
            std.mem.startsWith(u8, item.user_message.text, Compact.checkpoint_prompt))
        {
            saw_checkpoint = true;
        };
        std.debug.assert(saw_checkpoint);
        const step = self.steps[self.calls];
        self.calls += 1;
        const usage: ai.Usage.StreamUsage = .{
            .input_tokens = self.calls,
            .output_tokens = 1,
        };
        switch (step) {
            .tool => {
                try sink.emit(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
                try sink.emit(.{ .tool_call_end = "call" });
                try sink.emit(.{ .done = .{ .usage = usage } });
            },
            .empty => try sink.emit(.{ .done = .{ .usage = usage } }),
            .failure => try sink.emit(.{ .failure = .{
                .message = "provider failed",
                .usage = usage,
                .response = .{ .id = "failed-id" },
            } }),
            .success => {
                try sink.emit(.{ .reasoning_delta = "thought" });
                try sink.emit(.{ .text_delta = "summary" });
                try sink.emit(.{ .done = .{
                    .usage = usage,
                    .response = .{ .id = "response-id", .model = "served", .route = "route" },
                } });
            },
            .transport_failure => return error.ProviderUnavailable,
            .cancelled => return error.Cancelled,
        }
    }
};

const SeamRecorder = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    next_actions: [8]bool = undefined,

    pub fn call(
        self: *SeamRecorder,
        session: *const Session,
        kind: Loop.SeamKind,
        next_action: bool,
    ) Loop.HookError!void {
        std.debug.assert(kind == .compaction);
        const last = session.items()[session.items().len - 1];
        std.debug.assert(last == .turn_usage);
        self.next_actions[self.calls] = next_action;
        self.calls += 1;
        if (self.fail_at == self.calls) return error.Failed;
    }
};

const UsageRecorder = struct {
    calls: usize = 0,
    input_tokens: [8]?u64 = .{null} ** 8,

    pub fn observe(
        self: *UsageRecorder,
        observation: Loop.UsageObservation,
    ) Loop.HookError!void {
        if (observation.kind != .compaction or observation.terminal_context_tokens != null) return error.Failed;
        self.input_tokens[self.calls] = observation.footer.stream.input_tokens;
        self.calls += 1;
    }
};

fn countItems(items: []const Item, tag: std.meta.Tag(Item)) usize {
    var count: usize = 0;
    for (items) |item| if (std.meta.activeTag(item) == tag) {
        count += 1;
    };
    return count;
}

test "rejected attempts retain only usage then success appends a seed" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .model = "requested",
    });
    defer session.deinit();
    try session.addCompactSeed("old seed");
    try session.addUser("work after old seed");
    const old_len = session.items().len;
    var scripted: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
    var seam: SeamRecorder = .{};
    var usage: UsageRecorder = .{};

    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&scripted, "provider"),
        .model = "requested",
        .system_prompt = "system",
        .effort = "high",
        .focus = "keep exact paths",
        .seam_hook = SeamHook.from(&seam),
        .usage_observer = UsageObserver.from(&usage),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.compacted, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), result.attempts);
    try std.testing.expectEqual(@as(usize, 2), usage.calls);
    try std.testing.expectEqual(@as(?u64, 1), usage.input_tokens[0]);
    try std.testing.expectEqual(@as(?u64, 2), usage.input_tokens[1]);
    try std.testing.expectEqual(@as(usize, 2), seam.calls);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, seam.next_actions[0..2]);

    const items = session.items();
    try std.testing.expectEqual(old_len + 4, items.len);
    try std.testing.expectEqual(@as(usize, 2), countItems(items[old_len..], .turn_usage));
    try std.testing.expectEqual(@as(usize, 0), countItems(items[old_len..], .assistant_message));
    try std.testing.expectEqual(@as(usize, 0), countItems(items[old_len..], .tool_call));
    const floor = ai.Item.contextFloor(items);
    try std.testing.expectEqual(items.len - 2, floor);
    try std.testing.expect(std.mem.endsWith(u8, items[floor].user_message.text, "summary"));
    const final_usage = items[items.len - 1].turn_usage;
    try std.testing.expectEqualStrings("response-id", final_usage.value.provenance.response_id.?);
    try std.testing.expectEqualStrings("served", final_usage.value.provenance.served_model.?);
    try std.testing.expectEqualStrings("route", final_usage.value.provenance.route.?);
}

test "four rejected attempts exhaust the fixed maximum" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var scripted: ScriptedProvider = .{ .steps = &.{ .tool, .tool, .tool, .tool } };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&scripted, "provider"),
        .model = "model",
        .system_prompt = "system",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.no_summary, result.outcome);
    try std.testing.expectEqual(@as(usize, 4), result.attempts);
    try std.testing.expectEqual(@as(usize, 4), session.items().len);
    try std.testing.expectError(error.InvalidMaxAttempts, run(
        std.testing.allocator,
        std.testing.io,
        .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&scripted, "provider"),
            .model = "model",
            .system_prompt = "system",
            .max_attempts = 5,
        },
    ));
}

test "provider failure and cancellation are distinct and retain usage" {
    inline for (.{
        .{ ScriptedProvider.Step.failure, Outcome.provider_failure },
        .{ ScriptedProvider.Step.transport_failure, Outcome.provider_failure },
        .{ ScriptedProvider.Step.cancelled, Outcome.cancelled },
    }) |case| {
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var scripted: ScriptedProvider = .{ .steps = &.{case[0]} };
        var result = try run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&scripted, "provider"),
            .model = "model",
            .system_prompt = "system",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], result.outcome);
        try std.testing.expectEqual(@as(usize, 1), session.items().len);
        try std.testing.expect(session.items()[0] == .turn_usage);
    }
}

test "final seam failure preserves atomic seed and accepted usage" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var scripted: ScriptedProvider = .{ .steps = &.{.success} };
    var seam: SeamRecorder = .{ .fail_at = 1 };
    try std.testing.expectError(error.HookFailed, run(
        std.testing.allocator,
        std.testing.io,
        .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&scripted, "provider"),
            .model = "model",
            .system_prompt = "system",
            .seam_hook = SeamHook.from(&seam),
        },
    ));
    try std.testing.expectEqual(@as(usize, 3), session.items().len);
    try std.testing.expect(session.items()[0] == .turn_boundary);
    try std.testing.expectEqual(ai.Item.UserOrigin.compact_seed, session.items()[1].user_message.origin);
    try std.testing.expect(session.items()[2] == .turn_usage);
}

fn exerciseRunAllocations(allocator: std.mem.Allocator) !void {
    var session = try Session.init(allocator, .{});
    defer session.deinit();
    try session.addUser("history");
    var scripted: ScriptedProvider = .{ .steps = &.{.success} };
    var result = try run(allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&scripted, "provider"),
        .model = "model",
        .system_prompt = "system",
        .focus = "focus",
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(Outcome.compacted, result.outcome);
}

test "compaction transaction reports allocation failures without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRunAllocations,
        .{},
    );
}

const CompactionSeamRecorder = struct {
    actions: [8]bool = undefined,
    count: usize = 0,

    pub fn call(
        self: *CompactionSeamRecorder,
        _: *const Session,
        kind: Loop.SeamKind,
        next_action: bool,
    ) Loop.HookError!void {
        if (kind != .compaction) return;
        self.actions[self.count] = next_action;
        self.count += 1;
    }
};

test "Loop continuation compacts before the next provider stream" {
    const MainProvider = struct {
        const Self = @This();
        rounds: usize = 0,
        saw_seed: bool = false,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.rounds += 1;
            if (self.rounds == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "missing" } });
                try sink.emit(.{ .tool_call_end = "one" });
                try sink.emit(.{ .done = .{} });
                return;
            }
            for (request.context.items) |item| if (item == .user_message and
                item.user_message.origin == .compact_seed)
            {
                self.saw_seed = true;
            };
            if (!self.saw_seed) return error.InvalidRequest;
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Continuation = struct {
        const Self = @This();
        compactor: *ScriptedProvider,
        seam: *CompactionSeamRecorder,
        calls: usize = 0,

        pub fn call(self: *Self, session: *Session) Loop.HookError!Loop.ContinuationResult {
            self.calls += 1;
            var result = runContinuation(std.testing.allocator, std.testing.io, .{
                .session = session,
                .provider = ai.Provider.Provider.from(self.compactor, "compact"),
                .model = "model",
                .system_prompt = "system",
                .seam_hook = SeamHook.from(self.seam),
            }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Failed,
            };
            defer result.deinit(std.testing.allocator);
            if (result.outcome != .compacted) return error.Failed;
            return .changed;
        }
    };

    var main_provider: MainProvider = .{};
    var compactor: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
    var seam: CompactionSeamRecorder = .{};
    var continuation: Continuation = .{ .compactor = &compactor, .seam = &seam };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try Loop.run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&main_provider, "main"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
        .continuation_hook = Loop.ContinuationHook.from(&continuation),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Loop.Outcome.complete, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), continuation.calls);
    try std.testing.expectEqual(@as(usize, 2), main_provider.rounds);
    try std.testing.expect(main_provider.saw_seed);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, seam.actions[0..seam.count]);
}

test "provider phase rejects nested standalone and continuation compaction" {
    const NestedProvider = struct {
        const Self = @This();
        session: *Session,
        nested: *ScriptedProvider,
        rejected: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            const nested_params: Params = .{
                .session = self.session,
                .provider = ai.Provider.Provider.from(self.nested, "nested"),
                .model = "model",
                .system_prompt = "system",
            };
            if (run(std.testing.allocator, std.testing.io, nested_params)) |result_value| {
                var result = result_value;
                result.deinit(std.testing.allocator);
                return error.InvalidProviderResponse;
            } else |err| if (err == error.SessionBusy) {
                self.rejected += 1;
            } else return error.InvalidProviderResponse;
            if (runContinuation(std.testing.allocator, std.testing.io, nested_params)) |result_value| {
                var result = result_value;
                result.deinit(std.testing.allocator);
                return error.InvalidProviderResponse;
            } else |err| if (err == error.SessionBusy) {
                self.rejected += 1;
            } else return error.InvalidProviderResponse;
            try sink.emit(.{ .text_delta = "summary" });
            try sink.emit(.{ .done = .{} });
        }
    };

    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var never_called: ScriptedProvider = .{ .steps = &.{.success} };
    var provider: NestedProvider = .{ .session = &session, .nested = &never_called };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "outer"),
        .model = "model",
        .system_prompt = "system",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.compacted, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), provider.rejected);
    try std.testing.expectEqual(@as(usize, 0), never_called.calls);
}

test "retry request owns full rejected response feedback and advertises tools" {
    const NeverTool = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn run(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.calls += 1;
            return error.InvalidResult;
        }
    };
    const FeedbackProvider = struct {
        const Self = @This();
        calls: usize = 0,
        saw_feedback: bool = false,
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.calls += 1;
            if (request.context.tools.len != 1) return error.InvalidRequest;
            if (self.calls == 1) {
                try sink.emit(.{ .reasoning_delta = "reason" });
                try sink.emit(.{ .text_delta = "bad text" });
                try sink.emit(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "call" });
                try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 1 } } });
                return;
            }
            var call_index: ?usize = null;
            for (request.context.items, 0..) |item, index| {
                if (item == .tool_call) call_index = index;
            }
            const index = call_index orelse return error.InvalidRequest;
            if (index == 0 or index + 1 >= request.context.items.len) return error.InvalidRequest;
            if (request.context.items[index - 1] != .assistant_message) return error.InvalidRequest;
            const result = request.context.items[index + 1];
            if (result != .tool_result) return error.InvalidRequest;
            if (!std.mem.eql(u8, result.tool_result.call_id, "call")) return error.InvalidRequest;
            if (!std.mem.eql(u8, result.tool_result.output, tool_call_rejection)) return error.InvalidRequest;
            if (result.tool_result.origin != .refused) return error.InvalidRequest;
            self.saw_feedback = true;
            try sink.emit(.{ .text_delta = "summary" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 2 } } });
        }
    };

    var never_tool: NeverTool = .{};
    const tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&never_tool, .{
        .name = "read",
        .description = "read",
        .parameters = &.{},
    }, .{})};
    var provider: FeedbackProvider = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "actual-provider"),
        .model = "actual-model",
        .system_prompt = "system",
        .tools = &tools,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.compacted, result.outcome);
    try std.testing.expect(provider.saw_feedback);
    try std.testing.expectEqual(@as(usize, 0), never_tool.calls);
    try std.testing.expectEqual(@as(usize, 4), session.items().len);
    try std.testing.expect(session.items()[0] == .turn_usage);
    try std.testing.expect(session.items()[1] == .turn_boundary);
    try std.testing.expect(session.items()[2] == .user_message);
    try std.testing.expect(session.items()[3] == .turn_usage);
}

test "completed tool-free empty response stops after one attempt" {
    var provider: ScriptedProvider = .{ .steps = &.{ .empty, .success } };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.no_summary, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), result.attempts);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
}

test "post-stream cancellation discards a complete summary but retains usage" {
    const Sampler = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn sample(self: *Self) bool {
            self.calls += 1;
            return true;
        }
    };
    var sampler: Sampler = .{};
    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .cancellation = Cancellation.from(&sampler),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.cancelled, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try std.testing.expect(session.items()[0] == .turn_usage);
}

test "accepted usage records actual request provider and model" {
    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "old-provider",
        .model = "old-model",
    });
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "actual-provider"),
        .model = "actual-model",
        .system_prompt = "system",
    });
    defer result.deinit(std.testing.allocator);
    const usage = session.items()[session.items().len - 1].turn_usage;
    try std.testing.expectEqualStrings("actual-provider", usage.source.?.provider.?);
    try std.testing.expectEqualStrings("actual-model", usage.source.?.model.?);
}

const ExactHook = struct {
    failure: Loop.HookError,
    calls: usize = 0,
    pub fn call(self: *ExactHook, _: *const Session, _: Loop.SeamKind, _: bool) Loop.HookError!void {
        self.calls += 1;
        return self.failure;
    }
};

test "final seam errors preserve the accepted atomic arrangement" {
    inline for (.{
        .{ error.OutOfMemory, error.OutOfMemory },
        .{ error.Failed, error.HookFailed },
        .{ error.Indeterminate, error.HookIndeterminate },
    }) |case| {
        var provider: ScriptedProvider = .{ .steps = &.{.success} };
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var hook: ExactHook = .{ .failure = case[0] };
        try std.testing.expectError(case[1], run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
            .system_prompt = "system",
            .seam_hook = SeamHook.from(&hook),
        }));
        try std.testing.expectEqual(@as(usize, 3), session.items().len);
        try std.testing.expect(session.items()[0] == .turn_boundary);
        try std.testing.expect(session.items()[1] == .user_message);
        try std.testing.expect(session.items()[2] == .turn_usage);
    }
}

const ExactUsage = struct {
    failure: Loop.HookError,
    calls: usize = 0,
    pub fn observe(self: *ExactUsage, _: Loop.UsageObservation) Loop.HookError!void {
        self.calls += 1;
        return self.failure;
    }
};

test "accepted usage observer errors preserve the atomic arrangement" {
    inline for (.{
        .{ error.OutOfMemory, error.OutOfMemory },
        .{ error.Failed, error.HookFailed },
        .{ error.Indeterminate, error.HookIndeterminate },
    }) |case| {
        var provider: ScriptedProvider = .{ .steps = &.{.success} };
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var observer: ExactUsage = .{ .failure = case[0] };
        try std.testing.expectError(case[1], run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
            .system_prompt = "system",
            .usage_observer = UsageObserver.from(&observer),
        }));
        try std.testing.expectEqual(@as(usize, 3), session.items().len);
        try std.testing.expect(session.items()[0] == .turn_boundary);
        try std.testing.expect(session.items()[1] == .user_message);
        try std.testing.expect(session.items()[2] == .turn_usage);
    }
}

test "standalone allocation failure releases the compaction lease" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, run(failing.allocator(), std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
    }));
    provider.calls = 0;
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.compacted, result.outcome);
}

test "oversized accepted summary commits prepared usage and terminal seam" {
    const Provider = struct {
        const Self = @This();
        text: []const u8,
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = self.text });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 7 } } });
        }
    };
    const text = "x" ** (Compact.max_summary_bytes + 1);
    var provider: Provider = .{ .text = text };
    var seam: SeamRecorder = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.SummaryTooLarge, run(
        std.testing.allocator,
        std.testing.io,
        .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
            .system_prompt = "system",
            .seam_hook = SeamHook.from(&seam),
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try std.testing.expectEqual(@as(?u64, 7), session.items()[0].turn_usage.value.stream.input_tokens);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expect(!seam.next_actions[0]);
}

test "direct provider error has an owned diagnostic and retains usage" {
    var provider: ScriptedProvider = .{ .steps = &.{.transport_failure} };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.provider_failure, result.outcome);
    try std.testing.expectEqualStrings("ProviderUnavailable", result.diagnostic.?);
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
}

test "standalone rejected usage and accepted arrangement have ordered seams" {
    var provider: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
    var seam: SeamRecorder = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, seam.next_actions[0..seam.calls]);
}

test "accepted seed admission failure still commits its prepared usage" {
    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var seam: SeamRecorder = .{};
    var session = try Session.init(std.testing.allocator, .{ .limits = .{ .items = 1 } });
    defer session.deinit();
    try std.testing.expectError(error.TooManyItems, run(
        std.testing.allocator,
        std.testing.io,
        .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
            .system_prompt = "system",
            .seam_hook = SeamHook.from(&seam),
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try std.testing.expect(session.items()[0] == .turn_usage);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expect(!seam.next_actions[0]);
}

test "every compaction attempt is priced and observed in the total" {
    const CostObserver = struct {
        const Self = @This();
        calls: usize = 0,
        total: f64 = 0,

        pub fn observe(self: *Self, observation: Loop.UsageObservation) Loop.HookError!void {
            self.calls += 1;
            self.total += observation.footer.cost_total_usd.?;
            if (!observation.footer.cost_estimated) return error.Failed;
        }
    };
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .model = "model",
    });
    defer session.deinit();
    try session.addCompactSeed("old seed");
    try session.addUser("work");
    var provider: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
    var costs: CostObserver = .{};
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .model_metadata = .{ .rates = .{ .input = 1, .output = 1 } },
        .system_prompt = "system",
        .usage_observer = UsageObserver.from(&costs),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), costs.calls);
    try std.testing.expectApproxEqAbs(0.000005, costs.total, 1e-15);
}

test "physical retries fold into the accepted aggregate footer" {
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .retry = .{
                .attempt = 1,
                .maximum_attempts = 3,
                .delay_ms = 0,
                .usage = .{ .input_tokens = 10 },
            } });
            try sink.emit(.{ .retry = .{
                .attempt = 2,
                .maximum_attempts = 3,
                .delay_ms = 0,
                .usage = .{ .input_tokens = 20 },
            } });
            try sink.emit(.{ .text_delta = "summary" });
            try sink.emit(.{ .done = .{
                .usage = .{ .input_tokens = 3, .output_tokens = 2, .cost_usd = 1 },
                .response = .{ .id = "terminal" },
            } });
        }
    };
    const Costs = struct {
        const Self = @This();
        calls: usize = 0,
        total: f64 = 0,
        has_unpriced: bool = false,
        attempt_count: usize = 0,
        attempt_inputs: [3]?u64 = .{ null, null, null },
        pub fn observe(self: *Self, observation: Loop.UsageObservation) Loop.HookError!void {
            self.calls += 1;
            self.total += observation.spend.known_usd;
            self.has_unpriced = self.has_unpriced or observation.spend.has_unpriced;
            self.attempt_count = observation.attempts.len;
            for (observation.attempts, 0..) |attempt, index| {
                self.attempt_inputs[index] = attempt.input_tokens;
            }
        }
    };
    var session = try Session.init(std.testing.allocator, .{ .provider_id = "provider", .model = "model" });
    defer session.deinit();
    try session.addUser("work");
    const items_from = session.items().len;
    var fake: Fake = .{};
    var costs: Costs = .{};
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "provider"),
        .model = "model",
        .system_prompt = "system",
        .usage_observer = UsageObserver.from(&costs),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), costs.calls);
    try std.testing.expectApproxEqAbs(1, costs.total, 1e-15);
    const added = session.items()[items_from..];
    try std.testing.expectEqual(@as(usize, 3), added.len);
    try std.testing.expect(added[0] == .turn_boundary);
    try std.testing.expect(added[1] == .user_message);
    try std.testing.expect(added[2] == .turn_usage);
    const usage = added[2].turn_usage.value;
    try std.testing.expectEqual(@as(?u64, 33), usage.stream.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), usage.stream.output_tokens);
    try std.testing.expect(usage.cost_total_usd == null);
    try std.testing.expect(costs.has_unpriced);
    try std.testing.expectEqual(@as(usize, 3), costs.attempt_count);
    try std.testing.expectEqual(@as(?u64, 10), costs.attempt_inputs[0]);
    try std.testing.expectEqual(@as(?u64, 20), costs.attempt_inputs[1]);
    try std.testing.expectEqual(@as(?u64, 3), costs.attempt_inputs[2]);
    try std.testing.expectEqualStrings("terminal", usage.provenance.response_id.?);
}
