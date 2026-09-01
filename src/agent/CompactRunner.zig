//! Synchronous provider-neutral compaction transaction. Compaction policy and
//! text construction remain in `Compact.zig`.

const std = @import("std");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");
const Compact = @import("Compact.zig");
const Loop = @import("Loop.zig");
const SessionModule = @import("Session.zig");
const TurnModule = @import("Turn.zig");
const ModelMetadataSourceModule = @import("ModelMetadataSource.zig");

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
    resolve_fn: *const fn (*anyopaque) bool,

    pub fn sample(self: Cancellation) bool {
        return self.sample_fn(self.context);
    }

    pub fn resolve(self: Cancellation) bool {
        return self.resolve_fn(self.context);
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

            fn resolve(context: *anyopaque) bool {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.resolve();
            }
        };
        return .{
            .context = implementation,
            .sample_fn = Adapter.sample,
            .resolve_fn = Adapter.resolve,
        };
    }
};

/// Runs immediately after accepted seed publication and before observation or
/// durability. Implementations must be allocation-free, infallible, and non-reentrant.
pub const AcceptedMutationHook = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque) void,

    pub fn call(self: AcceptedMutationHook) void {
        self.call_fn(self.context);
    }

    pub fn from(implementation: anytype) AcceptedMutationHook {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("AcceptedMutationHook.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn call(context: *anyopaque) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.call();
            }
        };
        return .{ .context = implementation, .call_fn = Adapter.call };
    }
};

pub const Params = struct {
    session: *Session,
    provider: ai.Provider.Provider,
    model: []const u8,
    /// Fixed compatibility value used when `model_metadata_source` is absent.
    model_metadata: ai.ModelMeta.Metadata = .{},
    model_metadata_source: ?ModelMetadataSourceModule.ModelMetadataSource = null,
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
    accepted_mutation_hook: ?AcceptedMutationHook = null,
};

pub const Outcome = enum {
    compacted,
    no_summary,
    provider_failure,
    cancelled,
};

pub const Mutation = enum { none, usage_only, seed_committed };

pub const Durability = enum {
    not_attempted,
    synchronized,
    unrecorded,
    failed,
    indeterminate,
};

pub const UsageDisposition = enum {
    committed,
    preparation_failed,
};

pub const PostProviderIssue = struct {
    usage_observer_failed: bool = false,
    durability: Durability = .not_attempted,
    diagnostic_omitted: bool = false,
};

pub const Result = struct {
    outcome: Outcome,
    mutation: Mutation,
    usage: UsageDisposition,
    issue: PostProviderIssue,
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
    FinalTextTooLarge,
    InvalidRegistry,
    InvalidResult,
    InvalidMaxAttempts,
    ScratchTooLarge,
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
    assembly_error: ?anyerror = null,

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

    fn resolve(self: *CancelState) bool {
        if (self.cancellation) |cancellation| self.latched = self.latched or cancellation.resolve();
        return self.latched;
    }
};

fn resolveModelMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    params: Params,
) ai.ModelMeta.Metadata {
    const source = params.model_metadata_source orelse return params.model_metadata;
    return source.resolve(allocator, io) catch params.model_metadata;
}

const UsageInputResolution = struct {
    input: SessionModule.UsageInput,
    spend: ai.UsagePricing.Spend,
    attempts: [TurnModule.maximum_retry_usages + 1]ai.Usage.StreamUsage = undefined,
    attempt_count: usize = 0,
};

fn usageInput(
    params: Params,
    model_metadata: *const ai.ModelMeta.Metadata,
    turn: *const Turn,
    elapsed_ms: u64,
    response: ai.StreamEvent.ResponseIdentity,
) UsageInputResolution {
    const priced = ai.UsagePricing.resolveAttempts(
        turn.retryUsages(),
        turn.usage,
        elapsed_ms,
        model_metadata,
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

fn observeLatestUsage(params: Params, resolution: *const UsageInputResolution) bool {
    const observer = params.usage_observer orelse return false;
    const item = params.session.items()[params.session.items().len - 1];
    std.debug.assert(item == .turn_usage);
    observer.observe(.{
        .footer = item.turn_usage.value,
        .spend = resolution.spend,
        .attempts = resolution.attempts[0..resolution.attempt_count],
        .kind = .compaction,
        .terminal_context_tokens = null,
    }) catch return true;
    return false;
}

fn prepareUsage(
    params: Params,
    input: SessionModule.UsageInput,
) SessionModule.Error!SessionModule.PreparedUsage {
    params.session.beginCompactionMutation();
    defer params.session.endCompactionMutation();
    return params.session.prepareCompactionUsage(input);
}

fn commitUsage(params: Params, prepared: *SessionModule.PreparedUsage) void {
    params.session.beginCompactionMutation();
    defer params.session.endCompactionMutation();
    params.session.commitPreparedUsage(prepared);
}

fn prepareSeed(
    params: Params,
    seed: []const u8,
    usage: *SessionModule.PreparedUsage,
) SessionModule.Error!SessionModule.PreparedCompactSeed {
    params.session.beginCompactionMutation();
    defer params.session.endCompactionMutation();
    return params.session.prepareCompactSeed(seed, usage);
}

fn publishSeed(params: Params, prepared: *SessionModule.PreparedCompactSeed) void {
    params.session.beginCompactionMutation();
    defer params.session.endCompactionMutation();
    params.session.publishCompactSeed(prepared);
}

fn publishUsageOnly(
    params: Params,
    prepared: *SessionModule.PreparedCompactSeed,
) SessionModule.RetiredCompactSeed {
    params.session.beginCompactionMutation();
    defer params.session.endCompactionMutation();
    return params.session.publishCompactUsageOnly(prepared);
}

fn callSeam(params: Params, next_action: bool) Durability {
    const hook = params.seam_hook orelse return .unrecorded;
    const disposition = hook.call(params.session, .compaction, next_action) catch |err| return switch (err) {
        error.Indeterminate => .indeterminate,
        error.OutOfMemory, error.Failed => .failed,
    };
    return switch (disposition) {
        .synchronized => .synchronized,
        .unrecorded => .unrecorded,
    };
}

fn classifyCommitted(
    params: Params,
    resolution: *const UsageInputResolution,
    next_action: bool,
) PostProviderIssue {
    const usage_observer_failed = observeLatestUsage(params, resolution);
    return .{
        .usage_observer_failed = usage_observer_failed,
        .durability = callSeam(params, next_action and !usage_observer_failed),
    };
}

fn terminalNextAction(lease: Lease, outcome: Outcome) bool {
    return lease == .continuation and outcome != .cancelled;
}

fn ownedErrorDiagnostic(
    allocator: std.mem.Allocator,
    err: anyerror,
    issue: *PostProviderIssue,
) ?[]u8 {
    const name = @errorName(err);
    return allocator.dupe(u8, name[0..@min(name.len, maximum_diagnostic_bytes)]) catch {
        issue.diagnostic_omitted = true;
        return null;
    };
}

fn usagePreparationFailure(captured: *Captured, attempts: usize) Result {
    const diagnostic = captured.takeDiagnostic();
    return .{
        .outcome = .provider_failure,
        .mutation = .none,
        .usage = .preparation_failed,
        .issue = .{ .diagnostic_omitted = diagnostic == null },
        .attempts = attempts,
        .diagnostic = diagnostic,
    };
}

fn committedResult(
    params: Params,
    resolution: *const UsageInputResolution,
    outcome: Outcome,
    mutation: Mutation,
    attempts: usize,
    next_action: bool,
    diagnostic: ?[]u8,
    diagnostic_omitted: bool,
) Result {
    var issue = classifyCommitted(params, resolution, next_action);
    issue.diagnostic_omitted = diagnostic_omitted;
    return .{
        .outcome = outcome,
        .mutation = mutation,
        .usage = .committed,
        .issue = issue,
        .attempts = attempts,
        .diagnostic = diagnostic,
    };
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
    return runOwned(allocator, io, params, .standalone);
}

/// Runs from inside `Loop.ContinuationHook` and restores the hook phase.
pub fn runContinuation(allocator: std.mem.Allocator, io: std.Io, params: Params) RunError!Result {
    return runOwned(allocator, io, params, .continuation);
}

const Lease = enum { standalone, continuation };

fn runOwned(allocator: std.mem.Allocator, io: std.Io, params: Params, lease: Lease) RunError!Result {
    if (params.max_attempts == 0 or params.max_attempts > Compact.max_logical_attempts) {
        return error.InvalidMaxAttempts;
    }
    const owned_effort = if (params.effort) |effort| try allocator.dupe(u8, effort) else null;
    defer if (owned_effort) |effort| allocator.free(effort);
    var stable_params = params;
    stable_params.effort = owned_effort;
    return runWithLease(allocator, io, stable_params, lease);
}

fn runWithLease(allocator: std.mem.Allocator, io: std.Io, params: Params, lease: Lease) RunError!Result {
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
    var checkpoint = Compact.buildCheckpointPrompt(allocator, params.focus) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InstructionsTooLarge => return error.InstructionsTooLarge,
        error.FinalTextTooLarge => return error.FinalTextTooLarge,
        error.SummaryTooLarge => unreachable,
    };
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
        const model_metadata = resolveModelMetadata(allocator, io, params);
        const resolution = usageInput(params, &model_metadata, &turn, elapsed_ms, captured.response);
        const cancelled = cancel_state.sample();
        var prepared = prepareUsage(params, resolution.input) catch
            return usagePreparationFailure(&captured, attempt);
        defer prepared.deinit(params.session.allocator);

        if (sink.assembly_error) |assembly_error| {
            commitUsage(params, &prepared);
            var issue: PostProviderIssue = .{};
            const diagnostic = captured.takeDiagnostic() orelse
                ownedErrorDiagnostic(allocator, assembly_error, &issue);
            return committedResult(
                params,
                &resolution,
                .provider_failure,
                .usage_only,
                attempt,
                terminalNextAction(lease, .provider_failure),
                diagnostic,
                issue.diagnostic_omitted,
            );
        }
        if (stream_result) |_| {} else |stream_error| {
            commitUsage(params, &prepared);
            var issue: PostProviderIssue = .{};
            const diagnostic = captured.takeDiagnostic() orelse
                ownedErrorDiagnostic(allocator, stream_error, &issue);
            const outcome: Outcome = if (stream_error == error.Cancelled or cancelled)
                .cancelled
            else
                .provider_failure;
            return committedResult(
                params,
                &resolution,
                outcome,
                .usage_only,
                attempt,
                terminalNextAction(lease, outcome),
                diagnostic,
                issue.diagnostic_omitted,
            );
        }
        if (turn.state != .done or cancelled) {
            commitUsage(params, &prepared);
            var issue: PostProviderIssue = .{};
            const diagnostic = if (cancelled)
                captured.takeDiagnostic()
            else
                captured.takeDiagnostic() orelse ownedErrorDiagnostic(allocator, error.InvalidResult, &issue);
            const outcome: Outcome = if (cancelled) .cancelled else .provider_failure;
            return committedResult(
                params,
                &resolution,
                outcome,
                .usage_only,
                attempt,
                terminalNextAction(lease, outcome),
                diagnostic,
                issue.diagnostic_omitted,
            );
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
                    commitUsage(params, &prepared);
                    var issue: PostProviderIssue = .{};
                    const diagnostic = ownedErrorDiagnostic(allocator, err, &issue);
                    return committedResult(
                        params,
                        &resolution,
                        .provider_failure,
                        .usage_only,
                        attempt,
                        terminalNextAction(lease, .provider_failure),
                        diagnostic,
                        issue.diagnostic_omitted,
                    );
                };
                defer seed.deinit(allocator);
                var seed_candidate = prepareSeed(params, seed.bytes, &prepared) catch |err| {
                    commitUsage(params, &prepared);
                    var issue: PostProviderIssue = .{};
                    const diagnostic = ownedErrorDiagnostic(allocator, err, &issue);
                    return committedResult(
                        params,
                        &resolution,
                        .provider_failure,
                        .usage_only,
                        attempt,
                        terminalNextAction(lease, .provider_failure),
                        diagnostic,
                        issue.diagnostic_omitted,
                    );
                };
                defer seed_candidate.deinit();

                if (cancel_state.resolve()) {
                    var retired = publishUsageOnly(params, &seed_candidate);
                    retired.deinit();
                    return committedResult(
                        params,
                        &resolution,
                        .cancelled,
                        .usage_only,
                        attempt,
                        false,
                        null,
                        false,
                    );
                }

                publishSeed(params, &seed_candidate);
                if (params.accepted_mutation_hook) |hook| hook.call();
                return committedResult(
                    params,
                    &resolution,
                    .compacted,
                    .seed_committed,
                    attempt,
                    lease == .continuation,
                    null,
                    false,
                );
            }
            commitUsage(params, &prepared);
            return committedResult(
                params,
                &resolution,
                .no_summary,
                .usage_only,
                attempt,
                terminalNextAction(lease, .no_summary),
                null,
                false,
            );
        }

        commitUsage(params, &prepared);
        const retry_compaction = attempt < params.max_attempts;
        const next_action = retry_compaction or lease == .continuation;
        var issue = classifyCommitted(params, &resolution, next_action);
        if (!retry_compaction) return .{
            .outcome = .no_summary,
            .mutation = .usage_only,
            .usage = .committed,
            .issue = issue,
            .attempts = attempt,
        };
        if (issue.usage_observer_failed or
            (issue.durability != .synchronized and issue.durability != .unrecorded))
        {
            return .{
                .outcome = .provider_failure,
                .mutation = .usage_only,
                .usage = .committed,
                .issue = issue,
                .attempts = attempt,
            };
        }
        appendRejectedResponse(allocator, &scratch, turn.items.items) catch |err| {
            const diagnostic = ownedErrorDiagnostic(allocator, err, &issue);
            return .{
                .outcome = .provider_failure,
                .mutation = .usage_only,
                .usage = .committed,
                .issue = issue,
                .attempts = attempt,
                .diagnostic = diagnostic,
            };
        };
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
    ) Loop.HookError!Loop.SeamDisposition {
        std.debug.assert(kind == .compaction);
        const last = session.items()[session.items().len - 1];
        std.debug.assert(last == .turn_usage);
        self.next_actions[self.calls] = next_action;
        self.calls += 1;
        if (self.fail_at == self.calls) return error.Failed;
        return .synchronized;
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

test "rejected retries stop after observer or durability issue" {
    inline for (.{ true, false }) |fail_observer| {
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var provider: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
        var observer: ExactUsage = .{ .failure = error.Failed };
        var seam: SeamRecorder = .{ .fail_at = if (fail_observer) null else 1 };
        var result = try run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
            .system_prompt = "system",
            .usage_observer = if (fail_observer) UsageObserver.from(&observer) else null,
            .seam_hook = SeamHook.from(&seam),
        });
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), provider.calls);
        try std.testing.expectEqual(Outcome.provider_failure, result.outcome);
        try std.testing.expectEqual(Mutation.usage_only, result.mutation);
        try std.testing.expectEqual(fail_observer, result.issue.usage_observer_failed);
        try std.testing.expectEqual(
            if (fail_observer) Durability.synchronized else Durability.failed,
            result.issue.durability,
        );
        try std.testing.expectEqual(@as(usize, 1), seam.calls);
    }
}

test "rejected scratch allocation failure is classified after clean durability" {
    const ArmingSeam = struct {
        const Self = @This();
        failing: *std.testing.FailingAllocator,
        calls: usize = 0,

        pub fn call(
            self: *Self,
            _: *const Session,
            kind: Loop.SeamKind,
            next_action: bool,
        ) Loop.HookError!Loop.SeamDisposition {
            if (kind != .compaction or !next_action) return error.Failed;
            self.calls += 1;
            self.failing.fail_index = self.failing.alloc_index;
            return .synchronized;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var provider: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
    var seam: ArmingSeam = .{ .failing = &failing };
    var result = try run(failing.allocator(), std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(failing.allocator());

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(Outcome.provider_failure, result.outcome);
    try std.testing.expectEqual(Mutation.usage_only, result.mutation);
    try std.testing.expectEqual(Durability.synchronized, result.issue.durability);
    try std.testing.expect(result.issue.diagnostic_omitted);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
}

test "metadata failure preserves provider outcomes and terminal usage" {
    const Source = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            return error.Failed;
        }
    };
    inline for (.{
        .{ ScriptedProvider.Step.failure, Outcome.provider_failure },
        .{ ScriptedProvider.Step.transport_failure, Outcome.provider_failure },
        .{ ScriptedProvider.Step.cancelled, Outcome.cancelled },
    }) |case| {
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var source: Source = .{};
        var scripted: ScriptedProvider = .{ .steps = &.{case[0]} };
        var result = try run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&scripted, "provider"),
            .model = "model",
            .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
            .system_prompt = "system",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], result.outcome);
        try std.testing.expectEqual(@as(usize, 1), source.calls);
        try std.testing.expectEqual(@as(usize, 1), session.items().len);
        try std.testing.expect(session.items()[0] == .turn_usage);
    }
}

test "final seam failure preserves atomic seed and accepted usage" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var scripted: ScriptedProvider = .{ .steps = &.{.success} };
    var seam: SeamRecorder = .{ .fail_at = 1 };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&scripted, "provider"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mutation.seed_committed, result.mutation);
    try std.testing.expectEqual(Durability.failed, result.issue.durability);
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
    var result = run(allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&scripted, "provider"),
        .model = "model",
        .system_prompt = "system",
        .focus = "focus",
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), scripted.calls);
        return err;
    };
    defer result.deinit(allocator);
    try std.testing.expect(scripted.calls > 0);
    if (result.usage == .committed) try std.testing.expect(result.mutation != .none);
}

test "compaction transaction classifies post-provider allocation failures without leaks" {
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        exerciseRunAllocations(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        };
        if (!failing.has_induced_failure) break;
    } else return error.TestUnexpectedResult;
}

const CompactionSeamRecorder = struct {
    actions: [8]bool = undefined,
    count: usize = 0,

    pub fn call(
        self: *CompactionSeamRecorder,
        _: *const Session,
        kind: Loop.SeamKind,
        next_action: bool,
    ) Loop.HookError!Loop.SeamDisposition {
        if (kind != .compaction) return .synchronized;
        self.actions[self.count] = next_action;
        self.count += 1;
        return .synchronized;
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
            return .selection_changed;
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

fn exerciseEffortOwnership(lease: Lease) !void {
    const EffortProvider = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            const effort = request.context.effort orelse return error.InvalidRequest;
            if (!std.mem.eql(u8, effort, "original-effort")) return error.InvalidRequest;
            self.calls += 1;
            if (self.calls == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
                try sink.emit(.{ .tool_call_end = "call" });
                try sink.emit(.{ .done = .{} });
                return;
            }
            try sink.emit(.{ .text_delta = "summary" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const ReplacingSource = struct {
        const Self = @This();
        effort: *[]u8,
        calls: usize = 0,

        pub fn resolve(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            if (self.calls == 1) {
                allocator.free(self.effort.*);
                self.effort.* = try allocator.dupe(u8, "replaced-effort");
            }
            return .{};
        }
    };

    var effort = try std.testing.allocator.dupe(u8, "original-effort");
    defer std.testing.allocator.free(effort);
    var source: ReplacingSource = .{ .effort = &effort };
    var provider: EffortProvider = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    if (lease == .continuation) {
        try session.beginRun();
        session.beginHookMutation();
    }
    defer if (lease == .continuation) {
        session.endHookMutation();
        session.endRun();
    };
    const params: Params = .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
        .effort = effort,
    };
    var result = switch (lease) {
        .standalone => try run(std.testing.allocator, std.testing.io, params),
        .continuation => try runContinuation(std.testing.allocator, std.testing.io, params),
    };
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.compacted, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), result.attempts);
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    try std.testing.expectEqual(@as(usize, 2), source.calls);
    try std.testing.expectEqualStrings("replaced-effort", effort);
}

test "continuation terminal outcomes advertise the following main request" {
    inline for (.{ ScriptedProvider.Step.failure, ScriptedProvider.Step.empty }) |step| {
        var provider: ScriptedProvider = .{ .steps = &.{step} };
        var seam: SeamRecorder = .{};
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        try session.beginRun();
        session.beginHookMutation();
        defer {
            session.endHookMutation();
            session.endRun();
        }

        var result = try runContinuation(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "compact"),
            .model = "model",
            .system_prompt = "system",
            .seam_hook = SeamHook.from(&seam),
        });
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), seam.calls);
        try std.testing.expect(seam.next_actions[0]);
        try std.testing.expect(result.outcome == .provider_failure or result.outcome == .no_summary);
    }
}

test "compaction owns effort across metadata callbacks and logical attempts" {
    inline for (.{ Lease.standalone, Lease.continuation }) |lease| try exerciseEffortOwnership(lease);
}

fn exerciseEffortAllocationFailure(lease: Lease) !void {
    const Source = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            return .{};
        }
    };

    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var source: Source = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    if (lease == .continuation) {
        try session.beginRun();
        session.beginHookMutation();
    }
    defer if (lease == .continuation) {
        session.endHookMutation();
        session.endRun();
    };
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(buffer[0..]);
    const params: Params = .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
        .effort = "original-effort",
    };

    const result = switch (lease) {
        .standalone => run(fixed.allocator(), std.testing.io, params),
        .continuation => runContinuation(fixed.allocator(), std.testing.io, params),
    };
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 0), provider.calls);
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "compaction effort allocation failure has no provider or session effect" {
    inline for (.{ Lease.standalone, Lease.continuation }) |lease| try exerciseEffortAllocationFailure(lease);
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

        pub fn resolve(self: *Self) bool {
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

test "usage preparation failure after stream returns no mutation or callbacks" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var session = try Session.init(failing.allocator(), .{});
    defer session.deinit();
    failing.fail_index = failing.alloc_index;

    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var seam: SeamRecorder = .{};
    var usage: UsageRecorder = .{};
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
        .usage_observer = UsageObserver.from(&usage),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expectEqual(Outcome.provider_failure, result.outcome);
    try std.testing.expectEqual(Mutation.none, result.mutation);
    try std.testing.expectEqual(UsageDisposition.preparation_failed, result.usage);
    try std.testing.expectEqual(Durability.not_attempted, result.issue.durability);
    try std.testing.expect(result.issue.diagnostic_omitted);
    try std.testing.expectEqual(@as(usize, 0), seam.calls);
    try std.testing.expectEqual(@as(usize, 0), usage.calls);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "observer failure does not suppress recorded durability" {
    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var observer: ExactUsage = .{ .failure = error.Failed };
    var seam: SeamRecorder = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .usage_observer = UsageObserver.from(&observer),
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Mutation.seed_committed, result.mutation);
    try std.testing.expect(result.issue.usage_observer_failed);
    try std.testing.expectEqual(Durability.synchronized, result.issue.durability);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
}

test "late cancellation resolves once after allocation-complete seed preparation" {
    const LateCancellation = struct {
        const Self = @This();
        failing: *std.testing.FailingAllocator,
        sample_calls: usize = 0,
        resolve_calls: usize = 0,

        pub fn sample(self: *Self) bool {
            self.sample_calls += 1;
            return false;
        }

        pub fn resolve(self: *Self) bool {
            self.resolve_calls += 1;
            self.failing.fail_index = self.failing.alloc_index;
            return false;
        }
    };
    const Accepted = struct {
        const Self = @This();
        session: *Session,
        calls: usize = 0,

        pub fn call(self: *Self) void {
            const items = self.session.items();
            std.debug.assert(items.len == 3);
            std.debug.assert(items[1] == .user_message);
            std.debug.assert(items[1].user_message.origin == .compact_seed);
            self.calls += 1;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var session = try Session.init(failing.allocator(), .{});
    defer session.deinit();
    var cancellation: LateCancellation = .{ .failing = &failing };
    var accepted: Accepted = .{ .session = &session };
    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .cancellation = Cancellation.from(&cancellation),
        .accepted_mutation_hook = AcceptedMutationHook.from(&accepted),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.compacted, result.outcome);
    try std.testing.expectEqual(Mutation.seed_committed, result.mutation);
    try std.testing.expectEqual(@as(usize, 1), cancellation.resolve_calls);
    try std.testing.expectEqual(@as(usize, 1), accepted.calls);
    try std.testing.expect(!failing.has_induced_failure);
}

test "late resolved cancellation publishes usage only and skips accepted hook" {
    const LateCancellation = struct {
        const Self = @This();
        resolve_calls: usize = 0,

        pub fn sample(_: *Self) bool {
            return false;
        }

        pub fn resolve(self: *Self) bool {
            self.resolve_calls += 1;
            return true;
        }
    };
    const Accepted = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn call(self: *Self) void {
            self.calls += 1;
        }
    };

    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var cancellation: LateCancellation = .{};
    var accepted: Accepted = .{};
    var provider: ScriptedProvider = .{ .steps = &.{.success} };
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .cancellation = Cancellation.from(&cancellation),
        .accepted_mutation_hook = AcceptedMutationHook.from(&accepted),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.cancelled, result.outcome);
    try std.testing.expectEqual(Mutation.usage_only, result.mutation);
    try std.testing.expectEqual(@as(usize, 1), cancellation.resolve_calls);
    try std.testing.expectEqual(@as(usize, 0), accepted.calls);
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
    pub fn call(self: *ExactHook, _: *const Session, _: Loop.SeamKind, _: bool) Loop.HookError!Loop.SeamDisposition {
        self.calls += 1;
        return self.failure;
    }
};

test "final seam errors preserve the accepted atomic arrangement" {
    inline for ([_]Loop.HookError{ error.OutOfMemory, error.Failed, error.Indeterminate }) |failure| {
        var provider: ScriptedProvider = .{ .steps = &.{.success} };
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var hook: ExactHook = .{ .failure = failure };
        var result = try run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
            .system_prompt = "system",
            .seam_hook = SeamHook.from(&hook),
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Mutation.seed_committed, result.mutation);
        try std.testing.expectEqual(
            if (failure == error.Indeterminate) Durability.indeterminate else Durability.failed,
            result.issue.durability,
        );
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
    inline for ([_]Loop.HookError{ error.OutOfMemory, error.Failed, error.Indeterminate }) |failure| {
        var provider: ScriptedProvider = .{ .steps = &.{.success} };
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var observer: ExactUsage = .{ .failure = failure };
        var result = try run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "provider"),
            .model = "model",
            .system_prompt = "system",
            .usage_observer = UsageObserver.from(&observer),
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(Mutation.seed_committed, result.mutation);
        try std.testing.expect(result.issue.usage_observer_failed);
        try std.testing.expectEqual(Durability.unrecorded, result.issue.durability);
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
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.provider_failure, result.outcome);
    try std.testing.expectEqual(Mutation.usage_only, result.mutation);
    try std.testing.expectEqualStrings("SummaryTooLarge", result.diagnostic.?);
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
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.provider_failure, result.outcome);
    try std.testing.expectEqual(Mutation.usage_only, result.mutation);
    try std.testing.expectEqualStrings("TooManyItems", result.diagnostic.?);
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

test "compaction samples live metadata once per completed stream" {
    const Source = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            return .{ .rates = .{
                .input = @floatFromInt(self.calls),
                .output = 1,
            } };
        }
    };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.addUser("work");
    var provider: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
    var source: Source = .{};
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .model_metadata = .{ .rates = .{ .input = 99, .output = 99 } },
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), source.calls);
    var costs: [2]f64 = undefined;
    var count: usize = 0;
    for (session.items()) |item| if (item == .turn_usage) {
        costs[count] = item.turn_usage.value.cost_total_usd.?;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectApproxEqAbs(0.000002, costs[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.000005, costs[1], 1e-15);
}

test "compaction metadata failure falls back and persists every completed attempt" {
    const Source = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            if (self.calls == 2) return error.Failed;
            return .{ .rates = .{ .input = 1, .output = 1 } };
        }
    };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.addUser("work");
    var provider: ScriptedProvider = .{ .steps = &.{ .tool, .success } };
    var source: Source = .{};
    var seam: SeamRecorder = .{};
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .model_metadata = .{ .rates = .{ .input = 4, .output = 4 } },
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.compacted, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), source.calls);
    try std.testing.expectEqual(@as(usize, 2), countItems(session.items(), .turn_usage));
    try std.testing.expectEqual(@as(usize, 2), seam.calls);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, seam.next_actions[0..seam.calls]);
    var costs: [2]f64 = undefined;
    var count: usize = 0;
    for (session.items()) |item| if (item == .turn_usage) {
        costs[count] = item.turn_usage.value.cost_total_usd.?;
        count += 1;
    };
    try std.testing.expectApproxEqAbs(0.000002, costs[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.000012, costs[1], 1e-15);
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
