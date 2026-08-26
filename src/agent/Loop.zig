const std = @import("std");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");
const TurnModule = @import("Turn.zig");
const SessionModule = @import("Session.zig");
const AbortRepair = @import("AbortRepair.zig");
const ImageInputSourceModule = @import("ImageInputSource.zig");
const ModelMetadataSourceModule = @import("ModelMetadataSource.zig");

const Item = ai.Item.Item;
const Turn = TurnModule.Turn;
const Session = SessionModule.Session;

pub const default_max_turns: usize = 64;
pub const maximum_max_turns: usize = 1024;
pub const maximum_diagnostic_bytes: usize = 8 * 1024;
pub const default_maximum_request_images: usize = 20;
pub const default_maximum_request_image_base64_bytes: usize = 20 * 1024 * 1024;

pub const Signal = enum {
    none,
    pause,
    abort,
};

pub const Checkpoint = struct {
    context: *anyopaque,
    sample_fn: *const fn (*anyopaque) Signal,
    resolve_fn: ?*const fn (*anyopaque) Signal = null,

    /// Nonblocking sample used by provider ticks and running-tool cancellation.
    pub fn sample(self: Checkpoint) Signal {
        return self.sample_fn(self.context);
    }

    /// Resolves terminal-local ambiguity before an irreversible model or tool seam.
    /// Implementations without a distinct resolver retain the sample behavior.
    pub fn resolve(self: Checkpoint) Signal {
        const resolve_fn = self.resolve_fn orelse return self.sample();
        return resolve_fn(self.context);
    }

    pub fn from(implementation: anytype) Checkpoint {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Checkpoint.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn sample(context: *anyopaque) Signal {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.sample();
            }

            fn resolve(context: *anyopaque) Signal {
                const self: *Implementation = @ptrCast(@alignCast(context));
                if (@hasDecl(Implementation, "resolve")) return self.resolve();
                return self.sample();
            }
        };
        return .{
            .context = implementation,
            .sample_fn = Adapter.sample,
            .resolve_fn = Adapter.resolve,
        };
    }
};

test "checkpoint separates nonblocking samples from seam resolution" {
    const Source = struct {
        const Self = @This();

        samples: usize = 0,
        resolutions: usize = 0,

        pub fn sample(self: *Self) Signal {
            self.samples += 1;
            return .none;
        }

        pub fn resolve(self: *Self) Signal {
            self.resolutions += 1;
            return .pause;
        }
    };

    var source: Source = .{};
    const checkpoint = Checkpoint.from(&source);
    try std.testing.expectEqual(Signal.none, checkpoint.sample());
    try std.testing.expectEqual(Signal.pause, checkpoint.resolve());
    try std.testing.expectEqual(@as(usize, 1), source.samples);
    try std.testing.expectEqual(@as(usize, 1), source.resolutions);
}

pub const Observer = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, ai.StreamEvent.StreamEvent) void,

    pub fn emit(self: Observer, event: ai.StreamEvent.StreamEvent) void {
        self.emit_fn(self.context, event);
    }

    pub fn from(implementation: anytype) Observer {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Observer.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn emit(context: *anyopaque, event: ai.StreamEvent.StreamEvent) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.emit(event);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

pub const HookError = error{
    OutOfMemory,
    Failed,
    Indeterminate,
};

pub const SeamKind = enum {
    prompt,
    provider_failure,
    completion,
    tool_batch,
    compaction,
    interruption,
    pause,
    task_note,
};

/// Synchronous durability callback. The session and all of its contents are
/// borrowed only for the duration of `call`.
pub const SeamHook = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque, *const Session, SeamKind, bool) HookError!void,

    pub fn call(
        self: SeamHook,
        session: *const Session,
        kind: SeamKind,
        next_action: bool,
    ) HookError!void {
        return self.call_fn(self.context, session, kind, next_action);
    }

    pub fn from(implementation: anytype) SeamHook {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("SeamHook.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn call(
                context: *anyopaque,
                session: *const Session,
                kind: SeamKind,
                next_action: bool,
            ) HookError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.call(session, kind, next_action);
            }
        };
        return .{ .context = implementation, .call_fn = Adapter.call };
    }
};

pub const UsageKind = enum {
    ordinary,
    compaction,
};

/// Borrowed, by-value accounting observation delivered after footer admission.
pub const UsageObservation = struct {
    footer: ai.Usage.TurnUsage,
    spend: ai.UsagePricing.Spend,
    /// Ordered physical retry attempts followed by the terminal attempt.
    /// Borrowed only for the synchronous observer call.
    attempts: []const ai.Usage.StreamUsage,
    kind: UsageKind,
    terminal_context_tokens: ?u64 = null,
};

pub const UsageObserverError = error{
    OutOfMemory,
    CapacityExceeded,
    Failed,
    Indeterminate,
};

pub const UsageObserver = struct {
    context: *anyopaque,
    observe_fn: *const fn (*anyopaque, UsageObservation) UsageObserverError!void,

    pub fn observe(self: UsageObserver, observation: UsageObservation) UsageObserverError!void {
        return self.observe_fn(self.context, observation);
    }

    pub fn from(implementation: anytype) UsageObserver {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("UsageObserver.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn observe(context: *anyopaque, observation: UsageObservation) UsageObserverError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.observe(observation);
            }
        };
        return .{ .context = implementation, .observe_fn = Adapter.observe };
    }
};

/// Runs before every provider request and before its session snapshot. The
/// implementation may append provider-visible bookkeeping, but must not
/// reconfigure the session selection.
pub const PreRequestHook = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque, *Session) HookError!void,

    pub fn call(self: PreRequestHook, session: *Session) HookError!void {
        return self.call_fn(self.context, session);
    }

    pub fn from(implementation: anytype) PreRequestHook {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("PreRequestHook.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn call(context: *anyopaque, session: *Session) HookError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.call(session);
            }
        };
        return .{ .context = implementation, .call_fn = Adapter.call };
    }
};

pub const ContinuationResult = enum {
    /// Promises that the hook left the session selection unchanged, preserving
    /// Loop's active effort.
    unchanged,
    /// Refreshes Loop's active effort and emits a `.compaction` durability seam.
    changed,
    /// Refreshes Loop's active effort without claiming that context was compacted.
    selection_changed,
    paused,
};

/// Runs only at a tool continuation point. Selection refreshes make Loop read
/// the session's live effort immediately before each later provider request.
pub const ContinuationHook = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque, *Session) HookError!ContinuationResult,

    pub fn call(self: ContinuationHook, session: *Session) HookError!ContinuationResult {
        return self.call_fn(self.context, session);
    }

    pub fn from(implementation: anytype) ContinuationHook {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("ContinuationHook.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn call(context: *anyopaque, session: *Session) HookError!ContinuationResult {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.call(session);
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
    /// Fixed compatibility value used when `image_input_source` is absent.
    image_input: ai.Provider.ImageInput = .unknown,
    image_input_source: ?ImageInputSourceModule.ImageInputSource = null,
    max_turns: usize = default_max_turns,
    continued: bool = false,
    checkpoint: ?Checkpoint = null,
    observer: ?Observer = null,
    seam_hook: ?SeamHook = null,
    usage_observer: ?UsageObserver = null,
    pre_request_hook: ?PreRequestHook = null,
    continuation_hook: ?ContinuationHook = null,
    maximum_request_images: usize = default_maximum_request_images,
    maximum_request_image_base64_bytes: usize = default_maximum_request_image_base64_bytes,
};

pub const Outcome = enum {
    complete,
    provider_error,
    interrupted,
    paused,
    max_turns,
};

pub const Result = struct {
    outcome: Outcome,
    diagnostic: ?[]u8 = null,
    turns: usize = 0,
    last_context_tokens: ?u64 = null,
    final_items_from: usize = 0,
    final_items_to: usize = 0,
    abort_marker_placed: bool = false,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.diagnostic) |diagnostic| allocator.free(diagnostic);
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
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
    InvalidRegistry,
    InvalidResult,
    InvalidMaxTurns,
    RequestImageBudgetExceeded,
    InvalidItem,
    InvalidItemIndex,
    InvalidUsage,
    SessionBusy,
    HookFailed,
    HookIndeterminate,
    UsageCapacityExceeded,
};

const SignalState = struct {
    checkpoint: ?Checkpoint,
    signal: Signal = .none,

    fn record(self: *SignalState, signal: Signal) void {
        if (signal == .abort or (signal == .pause and self.signal == .none)) self.signal = signal;
    }

    fn sample(self: *SignalState) Signal {
        const checkpoint = self.checkpoint orelse return self.signal;
        self.record(checkpoint.sample());
        return self.signal;
    }

    fn resolve(self: *SignalState) Signal {
        const checkpoint = self.checkpoint orelse return self.signal;
        self.record(checkpoint.resolve());
        return self.signal;
    }

    pub fn poll(self: *SignalState) ai.Provider.DeliveryError!void {
        if (self.sample() != .none) return error.Cancelled;
    }
};

const ToolCancellation = struct {
    state: *SignalState,

    pub fn isRequested(self: *const ToolCancellation) bool {
        const checkpoint = self.state.checkpoint orelse return self.state.signal == .abort;
        self.state.record(checkpoint.sample());
        return self.state.signal == .abort;
    }
};

const Captured = struct {
    allocator: std.mem.Allocator,
    diagnostic: ?[]u8 = null,
    response: ai.StreamEvent.ResponseIdentity = .{},
    has_response: bool = false,

    fn deinit(self: *Captured) void {
        if (self.diagnostic) |value| self.allocator.free(value);
        if (self.response.id) |value| self.allocator.free(value);
        if (self.response.model) |value| self.allocator.free(value);
        if (self.response.route) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn takeDiagnostic(self: *Captured) ?[]u8 {
        const value = self.diagnostic;
        self.diagnostic = null;
        return value;
    }

    fn copyDiagnostic(self: *Captured, message: []const u8) error{OutOfMemory}!void {
        if (self.diagnostic != null) return;
        self.diagnostic = try self.allocator.dupe(u8, message[0..@min(message.len, maximum_diagnostic_bytes)]);
    }

    fn copyResponse(self: *Captured, response: ai.StreamEvent.ResponseIdentity) error{OutOfMemory}!void {
        if (self.has_response) return;
        self.has_response = true;
        self.response.id = try duplicateBounded(self.allocator, response.id);
        errdefer if (self.response.id) |value| {
            self.allocator.free(value);
            self.response.id = null;
        };
        self.response.model = try duplicateBounded(self.allocator, response.model);
        errdefer if (self.response.model) |value| {
            self.allocator.free(value);
            self.response.model = null;
        };
        self.response.route = try duplicateBounded(self.allocator, response.route);
    }
};

fn duplicateBounded(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    const bytes = value orelse return null;
    const owned = try allocator.dupe(u8, bytes[0..@min(bytes.len, maximum_diagnostic_bytes)]);
    return owned;
}

const Sink = struct {
    turn: *Turn,
    observer: ?Observer,
    captured: *Captured,
    assembly_error: ?Error = null,

    pub fn emit(self: *Sink, event: ai.StreamEvent.StreamEvent) ai.Provider.DeliveryError!void {
        if (self.observer) |observer| observer.emit(event);
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
        self.turn.consume(event) catch |err| {
            self.assembly_error = err;
            return error.Cancelled;
        };
    }
};

fn resolveImageInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    params: Params,
) Error!ai.Provider.ImageInput {
    const source = params.image_input_source orelse return params.image_input;
    return source.resolve(allocator, io) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.HookFailed,
    };
}

fn resolveModelMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    params: Params,
) ai.ModelMeta.Metadata {
    const source = params.model_metadata_source orelse return params.model_metadata;
    return source.resolve(allocator, io) catch params.model_metadata;
}

fn mapHookError(err: HookError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => error.HookFailed,
        error.Indeterminate => error.HookIndeterminate,
    };
}

fn mapUsageObserverError(err: UsageObserverError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CapacityExceeded => error.UsageCapacityExceeded,
        error.Failed => error.HookFailed,
        error.Indeterminate => error.HookIndeterminate,
    };
}

fn callSeam(params: Params, kind: SeamKind, next_action: bool) Error!void {
    const hook = params.seam_hook orelse return;
    hook.call(params.session, kind, next_action) catch |err| return mapHookError(err);
}

fn absorbItems(params: Params, items: []const Item) Error!SessionModule.AbsorbResult {
    params.session.beginHookMutation();
    defer params.session.endHookMutation();
    return params.session.absorbItemsCopy(items);
}

fn replaceToolResultOwned(params: Params, index: usize, item: *Item) Error!void {
    params.session.beginHookMutation();
    defer params.session.endHookMutation();
    return params.session.replaceToolResultOwned(index, item);
}

fn markInterrupt(params: Params) Error!bool {
    params.session.beginHookMutation();
    defer params.session.endHookMutation();
    return params.session.markInterrupt();
}

fn repairTurn(
    allocator: std.mem.Allocator,
    params: Params,
    turn: *Turn,
    reason: AbortRepair.Reason,
    prepend_boundary: bool,
) Error!AbortRepair.Outcome {
    params.session.beginHookMutation();
    defer params.session.endHookMutation();
    return AbortRepair.repairAndAbsorbWithBoundary(
        allocator,
        params.session,
        turn,
        reason,
        prepend_boundary,
    );
}

fn appendUsage(
    params: Params,
    model_metadata: *const ai.ModelMeta.Metadata,
    input: SessionModule.UsageInput,
    prepend_boundary: bool,
    retry_usages: []const ai.Usage.StreamUsage,
    terminal_usage: ai.Usage.StreamUsage,
    terminal_context_tokens: ?u64,
) Error!void {
    const priced = ai.UsagePricing.resolveAttempts(
        retry_usages,
        terminal_usage,
        input.elapsed_ms,
        model_metadata,
    );
    var attributed = input;
    attributed.stream = priced.footer.stream;
    attributed.uncached_input_tokens = priced.footer.uncached_input_tokens;
    attributed.cost_input_usd = priced.footer.cost_input_usd;
    attributed.cost_cache_read_usd = priced.footer.cost_cache_read_usd;
    attributed.cost_cache_write_usd = priced.footer.cost_cache_write_usd;
    attributed.cost_output_usd = priced.footer.cost_output_usd;
    attributed.cost_total_usd = priced.footer.cost_total_usd;
    attributed.cost_estimated = priced.footer.cost_estimated;
    attributed.source_provider = params.provider.id;
    attributed.source_model = params.model;
    params.session.beginHookMutation();
    const admitted = params.session.addTurnUsageWithBoundary(attributed, prepend_boundary) catch |err| {
        params.session.endHookMutation();
        return err;
    };
    params.session.endHookMutation();
    if (!admitted) return;
    const observer = params.usage_observer orelse return;
    var attempts: [TurnModule.maximum_retry_usages + 1]ai.Usage.StreamUsage = undefined;
    @memcpy(attempts[0..retry_usages.len], retry_usages);
    attempts[retry_usages.len] = terminal_usage;
    const item = &params.session.items()[params.session.items().len - 1];
    std.debug.assert(item.* == .turn_usage);
    observer.observe(.{
        .footer = item.turn_usage.value,
        .spend = priced.spend,
        .attempts = attempts[0 .. retry_usages.len + 1],
        .kind = .ordinary,
        .terminal_context_tokens = terminal_context_tokens,
    }) catch |err| return mapUsageObserverError(err);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    params: Params,
) Error!Result {
    try params.session.beginRun();
    defer params.session.endRun();
    if (params.max_turns == 0 or params.max_turns > maximum_max_turns) return error.InvalidMaxTurns;
    if (params.maximum_request_images == 0 or params.maximum_request_image_base64_bytes == 0) {
        return error.InvalidResult;
    }
    const initial_effort = if (params.effort) |effort|
        try allocator.dupe(u8, effort)
    else
        null;
    defer if (initial_effort) |effort| allocator.free(effort);
    const dispatch = try tool.Dispatch.Dispatch.init(params.tools, .{});
    const definitions = try dispatch.advertisedDefinitions(allocator);
    defer allocator.free(definitions);

    var result: Result = .{
        .outcome = .max_turns,
        .final_items_from = params.session.items().len,
        .final_items_to = params.session.items().len,
    };
    errdefer result.deinit(allocator);
    var signals: SignalState = .{ .checkpoint = params.checkpoint };
    var turn = Turn.init(allocator, .{});
    defer turn.deinit();
    var use_session_effort = false;

    while (result.turns < params.max_turns) {
        if (params.pre_request_hook) |hook| {
            params.session.beginHookMutation();
            hook.call(params.session) catch |err| {
                params.session.endHookMutation();
                return mapHookError(err);
            };
            params.session.endHookMutation();
        }
        turn.reset();
        var captured: Captured = .{ .allocator = allocator };
        defer captured.deinit();
        var sink: Sink = .{
            .turn = &turn,
            .observer = params.observer,
            .captured = &captured,
        };
        const session_items = params.session.items();
        const floor = ai.Item.contextFloor(session_items);
        const request_items = session_items[floor..];
        const request_image_count = ai.Item.imageCount(request_items);
        const request_image_bytes = ai.Item.imageBase64Bytes(request_items);
        if (request_image_count > params.maximum_request_images or
            request_image_bytes > params.maximum_request_image_base64_bytes)
        {
            return error.RequestImageBudgetExceeded;
        }
        const owes_boundary = result.turns > 0 or params.continued;
        result.turns += 1;
        const request_image_input = try resolveImageInput(allocator, io, params);
        const request_effort = if (use_session_effort)
            params.session.currentSelection().effort
        else
            initial_effort;
        const started_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        const stream_failure = params.provider.stream(allocator, io, .{
            .model = params.model,
            .context = .{
                .system_prompt = params.system_prompt,
                .items = request_items,
                .tools = definitions,
                .effort = request_effort,
                .image_input = request_image_input,
            },
            .tick = ai.Provider.Tick.from(&signals),
        }, ai.Provider.EventSink.from(&sink));

        const finished_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        const elapsed_ms: u64 = @intCast(@max(0, finished_ns - started_ns) / std.time.ns_per_ms);
        if (sink.assembly_error) |assembly_error| return assembly_error;
        if (stream_failure) |_| {} else |stream_error| {
            if (stream_error == error.OutOfMemory) return error.OutOfMemory;
        }
        const model_metadata = resolveModelMetadata(allocator, io, params);
        if (turn.last_context_tokens) |tokens| result.last_context_tokens = tokens;

        if (turn.state == .failed) {
            const total_usage = turn.totalUsage();
            const terminal_usage = turn.usage;
            const retry_usages = turn.retry_usages;
            const retry_count = turn.retry_usage_count;
            const terminal_context_tokens = turn.last_context_tokens;
            const usage_reported = ai.Usage.usageReported(total_usage);
            const has_response_content = turn.hasAssistantText();
            const prepend_boundary = owes_boundary and has_response_content;
            const usage_boundary = owes_boundary and !has_response_content and usage_reported;
            const repaired = try repairTurn(
                allocator,
                params,
                &turn,
                .provider_error,
                prepend_boundary,
            );
            result.final_items_from = repaired.items_from;
            result.final_items_to = repaired.items_to;
            result.abort_marker_placed = repaired.marker_placed;
            appendUsage(
                params,
                &model_metadata,
                .{
                    .stream = total_usage,
                    .elapsed_ms = if (ai.Usage.usageReported(total_usage)) elapsed_ms else null,
                    .response = captured.response,
                },
                usage_boundary,
                retry_usages[0..retry_count],
                terminal_usage,
                terminal_context_tokens,
            ) catch |err| {
                return settleTerminalMutationFailure(params, .provider_failure, err);
            };
            result.outcome = .provider_error;
            result.diagnostic = captured.takeDiagnostic();
            try callSeam(params, .provider_failure, false);
            return result;
        }

        var pause_preempted = false;
        if (stream_failure) |_| {} else |stream_error| {
            if (stream_error == error.OutOfMemory) return error.OutOfMemory;
            if (stream_error == error.Cancelled) _ = signals.resolve();
            if (stream_error == error.Cancelled and signals.signal == .abort) {
                const total_usage = turn.totalUsage();
                const terminal_usage = turn.usage;
                const retry_usages = turn.retry_usages;
                const retry_count = turn.retry_usage_count;
                const terminal_context_tokens = turn.last_context_tokens;
                const usage_reported = ai.Usage.usageReported(total_usage);
                const has_response_content = turn.survivesCancel();
                const prepend_boundary = owes_boundary and has_response_content;
                const usage_boundary = owes_boundary and !has_response_content and usage_reported;
                const repaired = try repairTurn(
                    allocator,
                    params,
                    &turn,
                    .user_cancel,
                    prepend_boundary,
                );
                result.final_items_from = repaired.items_from;
                result.final_items_to = repaired.items_to;
                appendUsage(
                    params,
                    &model_metadata,
                    .{
                        .stream = total_usage,
                        .elapsed_ms = if (ai.Usage.usageReported(total_usage)) elapsed_ms else null,
                        .response = captured.response,
                    },
                    usage_boundary,
                    retry_usages[0..retry_count],
                    terminal_usage,
                    terminal_context_tokens,
                ) catch |err| {
                    return settleTerminalMutationFailure(params, .interruption, err);
                };
                result.outcome = .interrupted;
                result.abort_marker_placed = repaired.marker_placed;
                try callSeam(params, .interruption, false);
                return result;
            }
            if (stream_error == error.Cancelled and signals.signal == .pause) {
                const total_usage = turn.totalUsage();
                const terminal_usage = turn.usage;
                const retry_usages = turn.retry_usages;
                const retry_count = turn.retry_usage_count;
                const terminal_context_tokens = turn.last_context_tokens;
                const paused_empty = turn.items.items.len == 0;
                if (paused_empty) {
                    const usage_reported = ai.Usage.usageReported(total_usage);
                    const usage_boundary = owes_boundary and usage_reported;
                    const initial_count = params.session.items().len;
                    appendUsage(
                        params,
                        &model_metadata,
                        .{
                            .stream = total_usage,
                            .elapsed_ms = if (usage_reported) elapsed_ms else null,
                            .response = captured.response,
                        },
                        usage_boundary,
                        retry_usages[0..retry_count],
                        terminal_usage,
                        terminal_context_tokens,
                    ) catch |err| {
                        return settleTerminalMutationFailure(params, .pause, err);
                    };
                    turn.reset();
                    result.final_items_from = initial_count + @as(usize, @intFromBool(usage_boundary));
                    result.final_items_to = result.final_items_from;
                    result.outcome = .paused;
                    try callSeam(params, .pause, false);
                    return result;
                }
                pause_preempted = true;
                try turn.consume(.{ .done = .{} });
            } else {
                turn.state = .failed;
                const total_usage = turn.totalUsage();
                const terminal_usage = turn.usage;
                const retry_usages = turn.retry_usages;
                const retry_count = turn.retry_usage_count;
                const terminal_context_tokens = turn.last_context_tokens;
                const usage_reported = ai.Usage.usageReported(total_usage);
                const has_response_content = turn.hasAssistantText();
                const prepend_boundary = owes_boundary and has_response_content;
                const usage_boundary = owes_boundary and !has_response_content and usage_reported;
                try captured.copyDiagnostic(@errorName(stream_error));
                const repaired = try repairTurn(
                    allocator,
                    params,
                    &turn,
                    .provider_error,
                    prepend_boundary,
                );
                result.final_items_from = repaired.items_from;
                result.final_items_to = repaired.items_to;
                result.abort_marker_placed = repaired.marker_placed;
                appendUsage(
                    params,
                    &model_metadata,
                    .{
                        .stream = total_usage,
                        .elapsed_ms = if (ai.Usage.usageReported(total_usage)) elapsed_ms else null,
                        .response = captured.response,
                    },
                    usage_boundary,
                    retry_usages[0..retry_count],
                    terminal_usage,
                    terminal_context_tokens,
                ) catch |err| {
                    return settleTerminalMutationFailure(params, .provider_failure, err);
                };
                result.outcome = .provider_error;
                result.diagnostic = captured.takeDiagnostic();
                try callSeam(params, .provider_failure, false);
                return result;
            }
        }

        if (turn.state != .done) {
            turn.state = .failed;
            const total_usage = turn.totalUsage();
            const terminal_usage = turn.usage;
            const retry_usages = turn.retry_usages;
            const retry_count = turn.retry_usage_count;
            const terminal_context_tokens = turn.last_context_tokens;
            const usage_reported = ai.Usage.usageReported(total_usage);
            const has_response_content = turn.hasAssistantText();
            const prepend_boundary = owes_boundary and has_response_content;
            const usage_boundary = owes_boundary and !has_response_content and usage_reported;
            try captured.copyDiagnostic(@errorName(error.InvalidProviderResponse));
            const repaired = try repairTurn(
                allocator,
                params,
                &turn,
                .provider_error,
                prepend_boundary,
            );
            result.final_items_from = repaired.items_from;
            result.final_items_to = repaired.items_to;
            result.abort_marker_placed = repaired.marker_placed;
            appendUsage(
                params,
                &model_metadata,
                .{
                    .stream = total_usage,
                    .elapsed_ms = if (ai.Usage.usageReported(total_usage)) elapsed_ms else null,
                    .response = captured.response,
                },
                usage_boundary,
                retry_usages[0..retry_count],
                terminal_usage,
                terminal_context_tokens,
            ) catch |err| {
                return settleTerminalMutationFailure(params, .provider_failure, err);
            };
            result.outcome = .provider_error;
            result.diagnostic = captured.takeDiagnostic();
            try callSeam(params, .provider_failure, false);
            return result;
        }

        _ = signals.resolve();
        if (signals.signal == .abort) {
            const total_usage = turn.totalUsage();
            const terminal_usage = turn.usage;
            const retry_usages = turn.retry_usages;
            const retry_count = turn.retry_usage_count;
            const terminal_context_tokens = turn.last_context_tokens;
            const usage_reported = ai.Usage.usageReported(total_usage);
            const has_response_content = turn.survivesCancel();
            const prepend_boundary = owes_boundary and has_response_content;
            const usage_boundary = owes_boundary and !has_response_content and usage_reported;
            const repaired = try repairTurn(
                allocator,
                params,
                &turn,
                .user_cancel,
                prepend_boundary,
            );
            result.final_items_from = repaired.items_from;
            result.final_items_to = repaired.items_to;
            appendUsage(
                params,
                &model_metadata,
                .{
                    .stream = total_usage,
                    .elapsed_ms = if (ai.Usage.usageReported(total_usage)) elapsed_ms else null,
                    .response = captured.response,
                },
                usage_boundary,
                retry_usages[0..retry_count],
                terminal_usage,
                terminal_context_tokens,
            ) catch |err| {
                return settleTerminalMutationFailure(params, .interruption, err);
            };
            result.outcome = .interrupted;
            result.abort_marker_placed = repaired.marker_placed;
            try callSeam(params, .interruption, false);
            return result;
        }
        const pause_pending = pause_preempted or signals.signal == .pause;

        var placeholders: std.ArrayList(Item) = .empty;
        defer {
            for (placeholders.items) |*item| item.deinit(allocator);
            placeholders.deinit(allocator);
        }
        var had_calls = false;
        for (turn.items.items) |*item| {
            if (item.* != .tool_call) continue;
            had_calls = true;
            var placeholder = try pendingToolResult(allocator, &item.tool_call);
            errdefer placeholder.deinit(allocator);
            try placeholders.append(allocator, placeholder);
        }

        const add_boundary = owes_boundary;
        var staged: std.ArrayList(Item) = .empty;
        defer staged.deinit(allocator);
        const staged_count = @as(usize, @intFromBool(add_boundary)) +
            turn.items.items.len + placeholders.items.len;
        try staged.ensureTotalCapacity(allocator, staged_count);
        if (add_boundary) staged.appendAssumeCapacity(.turn_boundary);
        staged.appendSliceAssumeCapacity(turn.items.items);
        staged.appendSliceAssumeCapacity(placeholders.items);
        const absorbed = try absorbItems(params, staged.items);
        result.final_items_from = absorbed.items_from + @as(usize, @intFromBool(add_boundary));
        result.final_items_to = result.final_items_from + turn.items.items.len;
        const result_items_from = result.final_items_to;

        // Pre-admit the terminal usage footer before any tool side effect. This
        // makes every later settlement allocation-infallible at the record seam.
        const total_usage = turn.totalUsage();
        const terminal_usage = turn.usage;
        const retry_usages = turn.retry_usages;
        const retry_count = turn.retry_usage_count;
        const terminal_context_tokens = turn.last_context_tokens;
        appendUsage(params, &model_metadata, .{
            .stream = total_usage,
            .elapsed_ms = elapsed_ms,
            .response = captured.response,
        }, false, retry_usages[0..retry_count], terminal_usage, terminal_context_tokens) catch |err| {
            turn.reset();
            const seam_kind: SeamKind = if (pause_preempted)
                .pause
            else if (had_calls)
                .tool_batch
            else
                .completion;
            return settleTerminalMutationFailure(params, seam_kind, err);
        };

        // Every call is durably paired before a tool can produce a side effect.
        // A later failure leaves its placeholder instead of making the call retryable.
        var abort_skipped = false;
        var cancellation: ToolCancellation = .{ .state = &signals };
        var window_image_count = request_image_count +| ai.Item.imageCount(turn.items.items);
        var window_image_bytes = request_image_bytes +| ai.Item.imageBase64Bytes(turn.items.items);
        var result_index: usize = 0;
        for (turn.items.items) |*item| {
            if (item.* != .tool_call) continue;
            const call = &item.tool_call;
            const tool_image_input = resolveImageInput(
                params.session.allocator,
                io,
                params,
            ) catch |err| return settleToolFailure(params, &turn, err);
            const tool_signal = signals.resolve();
            var tool_result = (if (definitions.len == 0)
                dispatch.refused(params.session.allocator, call)
            else if (tool_signal == .abort) skipped: {
                abort_skipped = true;
                break :skipped dispatch.skipped(params.session.allocator, call);
            } else dispatch.run(params.session.allocator, io, call, .{
                .image_input = tool_image_input,
                .cancel = tool.Tool.Cancellation.from(&cancellation),
            })) catch |err| return settleToolFailure(params, &turn, err);
            var result_owned = true;
            defer if (result_owned) tool_result.deinit(params.session.allocator);
            enforceImageBudget(
                params.session.allocator,
                &tool_result.tool_result,
                window_image_count,
                window_image_bytes,
                params.maximum_request_images,
                params.maximum_request_image_base64_bytes,
            );
            const result_image_count = tool_result.tool_result.images.len;
            var result_image_bytes: usize = 0;
            for (tool_result.tool_result.images) |image| result_image_bytes +|= image.data_base64.len;
            replaceToolResultOwned(params, result_items_from + result_index, &tool_result) catch |err| {
                return settleToolFailure(params, &turn, err);
            };
            result_owned = false;
            window_image_count +|= result_image_count;
            window_image_bytes +|= result_image_bytes;
            result_index += 1;
        }

        turn.reset();

        if (abort_skipped or signals.signal == .abort) {
            result.outcome = .interrupted;
            result.abort_marker_placed = abort_skipped;
            if (!abort_skipped) {
                result.abort_marker_placed = markInterrupt(params) catch |err| {
                    return settleTerminalMutationFailure(params, .interruption, err);
                };
            }
            try callSeam(params, .interruption, false);
            return result;
        }
        _ = signals.resolve();
        if (signals.signal == .abort) {
            result.outcome = .interrupted;
            result.abort_marker_placed = markInterrupt(params) catch |err| {
                return settleTerminalMutationFailure(params, .interruption, err);
            };
            try callSeam(params, .interruption, false);
            return result;
        }
        if (pause_preempted) {
            result.outcome = .paused;
            try callSeam(params, .pause, false);
            return result;
        }
        if (!had_calls) {
            result.outcome = .complete;
            try callSeam(params, .completion, false);
            return result;
        }
        if (pause_pending or signals.signal == .pause) {
            result.outcome = .paused;
            try callSeam(params, .pause, false);
            return result;
        }
        if (result.turns == params.max_turns) {
            result.outcome = .max_turns;
            try callSeam(params, .tool_batch, false);
            return result;
        }

        try callSeam(params, .tool_batch, true);
        if (params.continuation_hook) |hook| {
            params.session.beginHookMutation();
            const continuation = hook.call(params.session) catch |err| {
                params.session.endHookMutation();
                return mapHookError(err);
            };
            params.session.endHookMutation();
            switch (continuation) {
                .unchanged => {},
                .changed, .selection_changed => {
                    use_session_effort = true;
                    if (continuation == .changed) try callSeam(params, .compaction, true);
                },
                .paused => {
                    result.outcome = .paused;
                    return result;
                },
            }
        }
    }
    return result;
}

fn settleTerminalMutationFailure(params: Params, kind: SeamKind, original_error: Error) Error {
    callSeam(params, kind, false) catch |hook_error| {
        if (hook_error == error.HookIndeterminate) return error.HookIndeterminate;
    };
    return original_error;
}

fn settleToolFailure(params: Params, turn: *Turn, original_error: Error) Error {
    turn.reset();
    callSeam(params, .tool_batch, false) catch |hook_error| {
        if (hook_error == error.HookIndeterminate) return error.HookIndeterminate;
    };
    return original_error;
}

fn pendingToolResult(
    allocator: std.mem.Allocator,
    call: *const ai.Item.ToolCall,
) error{OutOfMemory}!Item {
    const call_id = try allocator.dupe(u8, call.id);
    errdefer allocator.free(call_id);
    const output = try allocator.dupe(u8, "error: tool execution did not complete");
    return .{ .tool_result = .{
        .call_id = call_id,
        .output = output,
        .origin = .skipped,
    } };
}

fn enforceImageBudget(
    allocator: std.mem.Allocator,
    result: *ai.Item.ToolResult,
    existing_count: usize,
    existing_bytes: usize,
    maximum_count: usize,
    maximum_bytes: usize,
) void {
    if (result.images.len == 0) return;
    var incoming_bytes: usize = 0;
    for (result.images) |image| incoming_bytes +|= image.data_base64.len;
    const exceeds_count = result.images.len > maximum_count -| existing_count;
    const exceeds_bytes = incoming_bytes > maximum_bytes -| existing_bytes;
    if (!exceeds_count and !exceeds_bytes) return;

    for (result.images) |*image| image.deinit(allocator);
    allocator.free(result.images);
    result.images = &.{};
}

const test_definition: tool.Tool.Definition = .{
    .name = "echo",
    .description = "echo arguments",
    .parameters = &.{},
};

test "loop commits a tool batch before requesting the final response" {
    const FakeProvider = struct {
        const Self = @This();
        round: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.round += 1;
            if (self.round == 1) {
                if (request.context.items.len != 0 or request.context.tools.len != 1)
                    return error.InvalidRequest;
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
                try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 2, .output_tokens = 1 } } });
                return;
            }
            if (request.context.items.len != 3 or
                request.context.items[0] != .tool_call or
                request.context.items[1] != .tool_result or
                request.context.items[2] != .turn_usage)
            {
                return error.InvalidRequest;
            }
            try sink.emit(.{ .text_delta = "finished" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 4, .output_tokens = 2 } } });
        }
    };
    const FakeTool = struct {
        const Self = @This();
        runs: usize = 0,

        pub fn runTool(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            args_json: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.runs += 1;
            if (!std.mem.eql(u8, "{}", args_json.?)) return error.InvalidResult;
            return .{ .output = try allocator.dupe(u8, "ok") };
        }

        pub const run = runTool;
    };

    var provider_impl: FakeProvider = .{};
    var tool_impl: FakeTool = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&tool_impl, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "configured-provider",
        .model = "configured-model",
    });
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider_impl, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.complete, loop_result.outcome);
    try std.testing.expectEqual(@as(usize, 2), loop_result.turns);
    try std.testing.expectEqual(@as(?u64, 6), loop_result.last_context_tokens);
    try std.testing.expectEqual(@as(usize, 1), tool_impl.runs);
    try std.testing.expectEqualStrings(
        "finished",
        session.items()[loop_result.final_items_from].assistant_message.text,
    );
    var usage_count: usize = 0;
    for (session.items()) |item| if (item == .turn_usage) {
        usage_count += 1;
        try std.testing.expectEqualStrings("fake", item.turn_usage.source.?.provider.?);
        try std.testing.expectEqualStrings("model", item.turn_usage.source.?.model.?);
    };
    try std.testing.expectEqual(@as(usize, 2), usage_count);
}

test "loop provider failure copies diagnostics and keeps reported usage" {
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
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "partial" });
            var message = [_]u8{ 'b', 'o', 'o', 'm' };
            try sink.emit(.{ .failure = .{
                .message = &message,
                .usage = .{ .input_tokens = 7, .output_tokens = 1 },
                .response = .{ .id = "response" },
            } });
            message = @splat('x');
        }
    };
    var source: Source = .{};
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .model_metadata = .{ .rates = .{ .input = 1, .output = 1 } },
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
    });
    defer loop_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.provider_error, loop_result.outcome);
    try std.testing.expect(loop_result.abort_marker_placed);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqualStrings("boom", loop_result.diagnostic.?);
    try std.testing.expectEqual(@as(?u64, 8), loop_result.last_context_tokens);
    try std.testing.expect(session.items().len >= 2);
    try std.testing.expect(session.items()[session.items().len - 1] == .turn_usage);
    try std.testing.expectEqualStrings(
        "response",
        session.items()[session.items().len - 1].turn_usage.value.provenance.response_id.?,
    );
    const usage_source = session.items()[session.items().len - 1].turn_usage.source.?;
    try std.testing.expectEqualStrings("fake", usage_source.provider.?);
    try std.testing.expectEqualStrings("model", usage_source.model.?);
}

test "loop recovers the typed assembly error before metadata refresh" {
    const Source = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            return error.OutOfMemory;
        }
    };
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            const too_long = "x" ** 513;
            try sink.emit(.{ .tool_call_start = .{ .id = "id", .name = too_long } });
        }
    };
    var source: Source = .{};
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.ToolNameTooLarge, run(
        std.testing.allocator,
        std.testing.io,
        .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&fake, "fake"),
            .model = "model",
            .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
            .system_prompt = "system",
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "provider stream OOM precedes metadata refresh" {
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
    var source: Source = .{};
    var provider: Provider = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.OutOfMemory, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "provider"),
        .model = "model",
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
    }));
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "loop pause preempts an empty provider without leaving history" {
    const Pause = struct {
        const Self = @This();
        pub fn sample(_: *Self) Signal {
            return .pause;
        }
    };
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            request: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try request.tick.?.poll();
        }
    };
    var pause: Pause = .{};
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&pause),
    });
    defer loop_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.paused, loop_result.outcome);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
    try std.testing.expect(!loop_result.abort_marker_placed);
}

test "cancelled pause resolves a pending stronger abort before settlement" {
    const Pending = struct {
        const Self = @This();
        resolutions: usize = 0,

        pub fn sample(_: *Self) Signal {
            return .pause;
        }

        pub fn resolve(self: *Self) Signal {
            self.resolutions += 1;
            return .abort;
        }
    };
    const Fake = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            request: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try request.tick.?.poll();
        }
    };

    var pending: Pending = .{};
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&pending),
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.interrupted, loop_result.outcome);
    try std.testing.expectEqual(@as(usize, 1), pending.resolutions);
}

test "cancelled abort seams repaired assistant and banked usage exactly once" {
    const Abort = struct {
        const Self = @This();
        pub fn sample(_: *Self) Signal {
            return .abort;
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
            try sink.emit(.{ .retry = .{
                .attempt = 1,
                .maximum_attempts = 2,
                .delay_ms = 0,
                .usage = .{ .input_tokens = 7 },
            } });
            try sink.emit(.{ .text_delta = "partial" });
            try request.tick.?.poll();
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        kind: ?SeamKind = null,
        next_action: bool = true,
        item_count: usize = 0,

        pub fn call(
            self: *Self,
            session: *const Session,
            kind: SeamKind,
            next_action: bool,
        ) HookError!void {
            self.calls += 1;
            self.kind = kind;
            self.next_action = next_action;
            self.item_count = session.items().len;
        }
    };

    var abort: Abort = .{};
    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&abort),
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.interrupted, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expectEqual(SeamKind.interruption, seam.kind.?);
    try std.testing.expect(!seam.next_action);
    try std.testing.expectEqual(@as(usize, 2), seam.item_count);
    try std.testing.expectEqual(ai.Item.AssistantOrigin.interrupted, session.items()[0].assistant_message.origin);
    try std.testing.expectEqual(@as(u64, 7), session.items()[1].turn_usage.value.stream.input_tokens);
}

test "cancelled empty pause seams banked usage exactly once" {
    const Pause = struct {
        const Self = @This();
        pub fn sample(_: *Self) Signal {
            return .pause;
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
            try sink.emit(.{ .retry = .{
                .attempt = 1,
                .maximum_attempts = 2,
                .delay_ms = 0,
                .usage = .{ .output_tokens = 5 },
            } });
            try request.tick.?.poll();
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        kind: ?SeamKind = null,
        next_action: bool = true,
        item_count: usize = 0,

        pub fn call(
            self: *Self,
            session: *const Session,
            kind: SeamKind,
            next_action: bool,
        ) HookError!void {
            self.calls += 1;
            self.kind = kind;
            self.next_action = next_action;
            self.item_count = session.items().len;
        }
    };

    var pause: Pause = .{};
    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&pause),
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.paused, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expectEqual(SeamKind.pause, seam.kind.?);
    try std.testing.expect(!seam.next_action);
    try std.testing.expectEqual(@as(usize, 1), seam.item_count);
    try std.testing.expectEqual(@as(u64, 5), session.items()[0].turn_usage.value.stream.output_tokens);
}

test "terminal usage hook failure keeps precedence after one interruption seam" {
    const Abort = struct {
        const Self = @This();
        pub fn sample(_: *Self) Signal {
            return .abort;
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
            try sink.emit(.{ .retry = .{
                .attempt = 1,
                .maximum_attempts = 2,
                .delay_ms = 0,
                .usage = .{ .input_tokens = 1 },
            } });
            try sink.emit(.{ .text_delta = "partial" });
            try request.tick.?.poll();
        }
    };
    const Usage = struct {
        const Self = @This();
        pub fn observe(_: *Self, _: UsageObservation) HookError!void {
            return error.Failed;
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn call(self: *Self, _: *const Session, kind: SeamKind, next_action: bool) HookError!void {
            self.calls += 1;
            if (kind != .interruption or next_action) return error.Indeterminate;
            return error.Failed;
        }
    };

    var abort: Abort = .{};
    var provider: Provider = .{};
    var usage: Usage = .{};
    var seam: Seam = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.HookFailed, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&abort),
        .seam_hook = SeamHook.from(&seam),
        .usage_observer = UsageObserver.from(&usage),
    }));
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expectEqual(@as(usize, 2), session.items().len);
    try std.testing.expectEqual(ai.Item.AssistantOrigin.interrupted, session.items()[0].assistant_message.origin);
}

test "loop refuses disabled tools before an abort and pairs the call" {
    const Abort = struct {
        const Self = @This();
        samples: usize = 0,
        pub fn sample(self: *Self) Signal {
            self.samples += 1;
            return if (self.samples == 1) .none else .abort;
        }
    };
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "missing" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    var abort: Abort = .{};
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&abort),
    });
    defer loop_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.interrupted, loop_result.outcome);
    try std.testing.expect(session.items()[0] == .tool_call);
    try std.testing.expectEqual(ai.Item.ToolResultOrigin.refused, session.items()[1].tool_result.origin);
    try std.testing.expectEqualStrings(
        "error: tool calls are disabled in this session",
        session.items()[1].tool_result.output,
    );
}

test "post-tool abort mark allocation failure settles interruption once" {
    const Abort = struct {
        const Self = @This();
        failing: *std.testing.FailingAllocator,
        samples: usize = 0,

        pub fn sample(self: *Self) Signal {
            self.samples += 1;
            if (self.samples != 2) return .none;
            self.failing.fail_index = self.failing.alloc_index;
            return .abort;
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
            try sink.emit(.{ .text_delta = "complete" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn call(self: *Self, _: *const Session, kind: SeamKind, next_action: bool) HookError!void {
            if (kind != .interruption or next_action) return error.Failed;
            self.calls += 1;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var abort: Abort = .{ .failing = &failing };
    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try Session.init(failing.allocator(), .{});
    defer session.deinit();
    try std.testing.expectError(error.OutOfMemory, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&abort),
        .seam_hook = SeamHook.from(&seam),
    }));
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expectEqual(@as(usize, 2), session.items().len);
}

test "tool-cancellation abort mark allocation failure settles without replay" {
    const Abort = struct {
        const Self = @This();
        failing: *std.testing.FailingAllocator,
        samples: usize = 0,

        pub fn sample(self: *Self) Signal {
            self.samples += 1;
            if (self.samples != 4) return .none;
            self.failing.fail_index = self.failing.alloc_index;
            return .abort;
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
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Echo = struct {
        const Self = @This();
        runs: usize = 0,
        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            context: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.runs += 1;
            const output = try allocator.dupe(u8, "ok");
            _ = context.cancel.?.isRequested();
            return .{ .output = output };
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn call(self: *Self, _: *const Session, kind: SeamKind, next_action: bool) HookError!void {
            if (kind != .interruption or next_action) return error.Failed;
            self.calls += 1;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var abort: Abort = .{ .failing = &failing };
    var provider: Provider = .{};
    var echo: Echo = .{};
    var seam: Seam = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&echo, test_definition, .{})};
    var session = try Session.init(failing.allocator(), .{});
    defer session.deinit();
    try std.testing.expectError(error.OutOfMemory, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&abort),
        .tools = &tools,
        .seam_hook = SeamHook.from(&seam),
    }));
    try std.testing.expectEqual(@as(usize, 1), echo.runs);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expect(session.items()[0] == .tool_call);
    try std.testing.expect(session.items()[1] == .tool_result);
    try std.testing.expect(session.items()[2] == .turn_usage);
}

test "loop max turn still commits a paired accepted tool batch" {
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const FakeTool = struct {
        const Self = @This();
        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            return .{ .output = try allocator.dupe(u8, "ok") };
        }
    };
    var fake: Fake = .{};
    var fake_tool: FakeTool = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&fake_tool, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .max_turns = 1,
    });
    defer loop_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.max_turns, loop_result.outcome);
    try std.testing.expect(session.items()[0] == .tool_call);
    try std.testing.expect(session.items()[1] == .tool_result);
}

fn exerciseLoopAllocations(allocator: std.mem.Allocator) !void {
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn call(self: *Self, _: *const Session, kind: SeamKind, next_action: bool) HookError!void {
            if (kind != .completion or next_action) return error.Failed;
            self.calls += 1;
        }
    };

    var fake: Fake = .{};
    var seam: Seam = .{};
    var session = try Session.init(allocator, .{});
    defer session.deinit();
    var loop_result = run(allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    }) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        const expected_calls = @as(usize, @intFromBool(session.items().len != 0));
        try std.testing.expectEqual(expected_calls, seam.calls);
        return err;
    };
    loop_result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
}

test "loop releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLoopAllocations,
        .{},
    );
}

fn exerciseProviderFailureAllocations(allocator: std.mem.Allocator) !void {
    const Provider = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "partial" });
            return error.TimedOut;
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn call(self: *Self, _: *const Session, kind: SeamKind, next_action: bool) HookError!void {
            if (kind != .provider_failure or next_action) return error.Failed;
            self.calls += 1;
        }
    };

    var provider: Provider = .{};
    var seam: Seam = .{};
    var session = try Session.init(allocator, .{});
    defer session.deinit();
    var result = run(allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    }) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        const expected_calls = @as(usize, @intFromBool(session.items().len != 0));
        try std.testing.expectEqual(expected_calls, seam.calls);
        return err;
    };
    try std.testing.expectEqual(Outcome.provider_error, result.outcome);
    try std.testing.expect(result.abort_marker_placed);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    result.deinit(allocator);
}

test "provider failure allocation faults seam only admitted history" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseProviderFailureAllocations,
        .{},
    );
}

test "image budget drops new result images without allocating a note" {
    const images = try std.testing.allocator.alloc(ai.Item.Image, 1);
    images[0] = .{
        .mime = try std.testing.allocator.dupe(u8, "image/png"),
        .data_base64 = try std.testing.allocator.dupe(u8, "AAAA"),
    };
    var result: ai.Item.ToolResult = .{
        .call_id = try std.testing.allocator.dupe(u8, "call"),
        .output = try std.testing.allocator.dupe(u8, "attached"),
        .images = images,
    };
    defer {
        std.testing.allocator.free(result.call_id);
        std.testing.allocator.free(result.output);
        for (result.images) |*image| image.deinit(std.testing.allocator);
        if (result.images.len != 0) std.testing.allocator.free(result.images);
    }
    enforceImageBudget(
        std.testing.allocator,
        &result,
        default_maximum_request_images,
        0,
        default_maximum_request_images,
        default_maximum_request_image_base64_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), result.images.len);
    try std.testing.expectEqualStrings("attached", result.output);
    try std.testing.expectEqual(@as(usize, 0), result.hidden_tail_bytes);
}

test "loop leaves durable placeholders when a post-side-effect result is invalid" {
    const FakeProvider = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const InvalidTool = struct {
        const Self = @This();
        runs: usize = 0,
        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.runs += 1;
            const images = try allocator.alloc(ai.Item.Image, 1);
            images[0] = .{
                .mime = try allocator.dupe(u8, ""),
                .data_base64 = try allocator.dupe(u8, "AAAA"),
            };
            return .{ .output = try allocator.dupe(u8, "side effect happened"), .images = images };
        }
    };
    var provider: FakeProvider = .{};
    var implementation: InvalidTool = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&implementation, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.InvalidItem, run(
        std.testing.allocator,
        std.testing.io,
        .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "system",
            .tools = &tools,
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), implementation.runs);
    try std.testing.expectEqual(@as(usize, 3), session.items().len);
    try std.testing.expect(session.items()[0] == .tool_call);
    try std.testing.expect(session.items()[1] == .tool_result);
    try std.testing.expectEqualStrings(
        "error: tool execution did not complete",
        session.items()[1].tool_result.output,
    );
}

test "continued provider failure with only usage keeps its boundary" {
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .failure = .{
                .message = "failed",
                .usage = .{ .input_tokens = 3 },
            } });
        }
    };
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .continued = true,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.provider_error, result.outcome);
    try std.testing.expectEqual(@as(usize, 2), session.items().len);
    try std.testing.expect(session.items()[0] == .turn_boundary);
    try std.testing.expect(session.items()[1] == .turn_usage);
}

test "pause sampled with a final tool-free response still completes" {
    const Pause = struct {
        const Self = @This();
        pub fn sample(_: *Self) Signal {
            return .pause;
        }
    };
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "complete" });
            try sink.emit(.{ .done = .{} });
        }
    };
    var pause: Pause = .{};
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&pause),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.complete, result.outcome);
    try std.testing.expectEqualStrings("complete", session.items()[0].assistant_message.text);
}

test "post-stream abort durably seams repaired assistant and usage once" {
    const Abort = struct {
        const Self = @This();
        pub fn sample(_: *Self) Signal {
            return .abort;
        }
    };
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "answer" });
            try sink.emit(.{ .done = .{ .usage = .{ .output_tokens = 3 } } });
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        kind: ?SeamKind = null,
        next_action: bool = true,
        item_count: usize = 0,

        pub fn call(
            self: *Self,
            session: *const Session,
            kind: SeamKind,
            next_action: bool,
        ) HookError!void {
            self.calls += 1;
            self.kind = kind;
            self.next_action = next_action;
            self.item_count = session.items().len;
        }
    };

    var abort: Abort = .{};
    var fake: Fake = .{};
    var seam: Seam = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&abort),
        .seam_hook = SeamHook.from(&seam),
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.interrupted, result.outcome);
    try std.testing.expect(result.abort_marker_placed);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expectEqual(SeamKind.interruption, seam.kind.?);
    try std.testing.expect(!seam.next_action);
    try std.testing.expectEqual(@as(usize, 2), seam.item_count);
    try std.testing.expectEqual(ai.Item.AssistantOrigin.interrupted, session.items()[0].assistant_message.origin);
    try std.testing.expect(std.mem.endsWith(u8, session.items()[0].assistant_message.text, "[interrupted]"));
    try std.testing.expectEqual(@as(u64, 3), session.items()[1].turn_usage.value.stream.output_tokens);
}

test "one-shot pause sampled before a tool is retained until the seam" {
    const Pause = struct {
        const Self = @This();
        samples: usize = 0,
        pub fn sample(self: *Self) Signal {
            self.samples += 1;
            return if (self.samples == 2) .pause else .none;
        }
    };
    const Fake = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const FakeTool = struct {
        const Self = @This();
        runs: usize = 0,
        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.runs += 1;
            return .{ .output = try allocator.dupe(u8, "ok") };
        }
    };
    var pause: Pause = .{};
    var fake: Fake = .{};
    var fake_tool: FakeTool = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&fake_tool, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "fake"),
        .model = "model",
        .system_prompt = "system",
        .checkpoint = Checkpoint.from(&pause),
        .tools = &tools,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.paused, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), fake_tool.runs);
    try std.testing.expect(session.items()[1] == .tool_result);
}

test "loop refuses a request window already over its image count budget" {
    const Never = struct {
        const Self = @This();
        called: bool = false,
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.called = true;
        }
    };
    var images: [21]ai.Item.Image = undefined;
    for (&images) |*image| image.* = .{
        .mime = @constCast("image/png"),
        .data_base64 = @constCast("AAAA"),
    };
    const borrowed: Item = .{ .user_message = .{
        .text = @constCast("images"),
        .images = &images,
    } };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.appendCopy(&borrowed);
    var never: Never = .{};
    try std.testing.expectError(error.RequestImageBudgetExceeded, run(
        std.testing.allocator,
        std.testing.io,
        .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&never, "fake"),
            .model = "model",
            .system_prompt = "system",
        },
    ));
    try std.testing.expect(!never.called);
}

test "lifecycle hooks order durable tool continuation and final completion" {
    const Log = struct {
        const Self = @This();
        bytes: [32]u8 = undefined,
        len: usize = 0,

        fn push(self: *Self, byte: u8) void {
            self.bytes[self.len] = byte;
            self.len += 1;
        }
    };
    const Provider = struct {
        const Self = @This();
        log: *Log,
        round: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.log.push('P');
            self.round += 1;
            if (self.round == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
                try sink.emit(.{ .tool_call_start = .{ .id = "two", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "two", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "two" });
                try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 1 } } });
                return;
            }
            if (request.context.items[request.context.items.len - 1] != .user_message) {
                return error.InvalidRequest;
            }
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{ .usage = .{ .output_tokens = 1 } } });
        }
    };
    const Echo = struct {
        const Self = @This();
        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            return .{ .output = try allocator.dupe(u8, "ok") };
        }
    };
    const Seam = struct {
        const Self = @This();
        log: *Log,

        pub fn call(
            self: *Self,
            session: *const Session,
            kind: SeamKind,
            next_action: bool,
        ) HookError!void {
            switch (kind) {
                .tool_batch => {
                    if (session.items()[session.items().len - 1] != .turn_usage) return error.Failed;
                    if (!next_action) return error.Failed;
                    self.log.push('T');
                },
                .compaction => {
                    if (session.items()[session.items().len - 1] != .user_message) return error.Failed;
                    if (!next_action) return error.Failed;
                    self.log.push('D');
                },
                .completion => {
                    if (session.items()[session.items().len - 1] != .turn_usage) return error.Failed;
                    if (next_action) return error.Failed;
                    self.log.push('F');
                },
                .prompt, .provider_failure, .interruption, .pause, .task_note => return error.Failed,
            }
        }
    };
    const Usage = struct {
        const Self = @This();
        log: *Log,

        pub fn observe(self: *Self, observation: UsageObservation) HookError!void {
            if (observation.footer.elapsed_ms == null or observation.kind != .ordinary) return error.Failed;
            self.log.push('U');
        }
    };
    const Continuation = struct {
        const Self = @This();
        log: *Log,

        pub fn call(self: *Self, session: *Session) HookError!ContinuationResult {
            session.addContinuation() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Failed,
            };
            self.log.push('C');
            return .changed;
        }
    };

    var log: Log = .{};
    var provider: Provider = .{ .log = &log };
    var echo: Echo = .{};
    var seam: Seam = .{ .log = &log };
    var usage: Usage = .{ .log = &log };
    var continuation: Continuation = .{ .log = &log };
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&echo, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.addUser("prompt outside Loop");
    try std.testing.expectEqual(@as(usize, 0), log.len);

    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .seam_hook = SeamHook.from(&seam),
        .usage_observer = UsageObserver.from(&usage),
        .continuation_hook = ContinuationHook.from(&continuation),
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("PUTCDPUF", log.bytes[0..log.len]);
    try std.testing.expectEqual(@as(usize, 2), provider.round);
}

test "failed tool seam prevents the next provider stream" {
    const Provider = struct {
        const Self = @This();
        rounds: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.rounds += 1;
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "missing" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const FailingSeam = struct {
        const Self = @This();
        pub fn call(
            _: *Self,
            _: *const Session,
            kind: SeamKind,
            _: bool,
        ) HookError!void {
            if (kind == .tool_batch) return error.Failed;
        }
    };

    var provider: Provider = .{};
    var seam: FailingSeam = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.HookFailed, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .seam_hook = SeamHook.from(&seam),
    }));
    try std.testing.expectEqual(@as(usize, 1), provider.rounds);
    try std.testing.expect(session.items()[0] == .tool_call);
    try std.testing.expect(session.items()[1] == .tool_result);
    try std.testing.expect(session.items()[2] == .turn_usage);
}

test "usage observer sees admitted provider failure and preserves out of memory" {
    const Provider = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .failure = .{
                .message = "failed",
                .usage = .{ .input_tokens = 3 },
            } });
        }
    };
    const Usage = struct {
        const Self = @This();
        calls: usize = 0,
        detailed_cause: ?[]const u8 = null,

        pub fn observe(self: *Self, observation: UsageObservation) HookError!void {
            self.calls += 1;
            if (observation.footer.stream.input_tokens != 3) return error.Failed;
            self.detailed_cause = "observer allocation failed";
            return error.OutOfMemory;
        }
    };

    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn call(self: *Self, _: *const Session, kind: SeamKind, next_action: bool) HookError!void {
            if (kind != .provider_failure or next_action) return error.Indeterminate;
            self.calls += 1;
            return error.Failed;
        }
    };

    var provider: Provider = .{};
    var usage: Usage = .{};
    var seam: Seam = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.OutOfMemory, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .usage_observer = UsageObserver.from(&usage),
        .seam_hook = SeamHook.from(&seam),
    }));
    try std.testing.expectEqual(@as(usize, 1), usage.calls);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
    try std.testing.expectEqualStrings("observer allocation failed", usage.detailed_cause.?);
    try std.testing.expect(session.items()[session.items().len - 1] == .turn_usage);
}

test "continuation hook runs without a seam hook before the next stream" {
    const Provider = struct {
        const Self = @This();
        rounds: usize = 0,

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
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
                try sink.emit(.{ .done = .{} });
                return;
            }
            const last = request.context.items[request.context.items.len - 1];
            if (last != .user_message or last.user_message.origin != .continuation) {
                return error.InvalidRequest;
            }
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Continuation = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn call(self: *Self, session: *Session) HookError!ContinuationResult {
            self.calls += 1;
            session.addContinuation() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Failed,
            };
            return .changed;
        }
    };

    var provider: Provider = .{};
    var continuation: Continuation = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .continuation_hook = ContinuationHook.from(&continuation),
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.complete, loop_result.outcome);
    try std.testing.expectEqual(@as(usize, 2), provider.rounds);
    try std.testing.expectEqual(@as(usize, 1), continuation.calls);
}

test "continuation selection results explicitly resync active effort" {
    const Mode = enum { changed, selection_changed, unchanged };
    const Provider = struct {
        const Self = @This();
        expected_second: ?[]const u8,
        rounds: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.rounds += 1;
            const expected: ?[]const u8 = if (self.rounds == 1) "high" else self.expected_second;
            if (expected) |value| {
                const actual = request.context.effort orelse return error.InvalidRequest;
                if (!std.mem.eql(u8, value, actual)) return error.InvalidRequest;
            } else if (request.context.effort != null) {
                return error.InvalidRequest;
            }
            if (self.rounds == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "missing" } });
                try sink.emit(.{ .tool_call_end = "one" });
            } else {
                try sink.emit(.{ .text_delta = "done" });
            }
            try sink.emit(.{ .done = .{} });
        }
    };
    const Continuation = struct {
        const Self = @This();
        mode: Mode,

        pub fn call(self: *Self, session: *Session) HookError!ContinuationResult {
            if (self.mode != .unchanged) {
                session.reconfigureSelection(.{
                    .effort = if (self.mode == .selection_changed) null else "low",
                }) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Failed,
                };
            }
            return switch (self.mode) {
                .changed => .changed,
                .selection_changed => .selection_changed,
                .unchanged => .unchanged,
            };
        }
    };
    const Seam = struct {
        const Self = @This();
        compactions: usize = 0,

        pub fn call(self: *Self, _: *const Session, kind: SeamKind, _: bool) HookError!void {
            if (kind == .compaction) self.compactions += 1;
        }
    };

    for ([_]Mode{ .changed, .selection_changed, .unchanged }) |mode| {
        const expected_second: ?[]const u8 = switch (mode) {
            .changed => "low",
            .selection_changed => null,
            .unchanged => "high",
        };
        var provider: Provider = .{ .expected_second = expected_second };
        var continuation: Continuation = .{ .mode = mode };
        var seam: Seam = .{};
        var session = try Session.init(std.testing.allocator, .{ .effort = "high" });
        defer session.deinit();
        var loop_result = try run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "system",
            .effort = "high",
            .seam_hook = SeamHook.from(&seam),
            .continuation_hook = ContinuationHook.from(&continuation),
        });
        defer loop_result.deinit(std.testing.allocator);

        try std.testing.expectEqual(Outcome.complete, loop_result.outcome);
        try std.testing.expectEqual(@as(usize, 2), provider.rounds);
        try std.testing.expectEqual(@as(usize, if (mode == .changed) 1 else 0), seam.compactions);
    }
}

test "initial effort survives image source catalog replacement" {
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
            const effort = request.context.effort orelse return error.InvalidRequest;
            if (!std.mem.eql(u8, "high", effort)) return error.InvalidRequest;
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const Source = struct {
        const Self = @This();
        effort: ?[]u8,
        calls: usize = 0,

        pub fn resolve(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            self.calls += 1;
            const effort = self.effort orelse return error.Failed;
            @memset(effort, 'x');
            allocator.free(effort);
            self.effort = null;
            return .unsupported;
        }
    };

    const original_effort = try std.testing.allocator.dupe(u8, "high");
    var source: Source = .{ .effort = original_effort };
    errdefer if (source.effort) |effort| std.testing.allocator.free(effort);
    var provider: Provider = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .effort = original_effort,
        .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Outcome.complete, loop_result.outcome);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    try std.testing.expect(source.effort == null);
}

test "initial effort allocation failure precedes request effects" {
    const Provider = struct {
        const Self = @This();
        called: bool = false,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.called = true;
        }
    };
    const Source = struct {
        const Self = @This();
        called: bool = false,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            self.called = true;
            return .unsupported;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var source: Source = .{};
    var provider: Provider = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.OutOfMemory, run(failing.allocator(), std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .effort = "high",
        .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
    }));

    try std.testing.expect(!source.called);
    try std.testing.expect(!provider.called);
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "run lease rejects nested runs and provider or observer mutations" {
    const NestedProvider = struct {
        const Self = @This();
        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .done = .{} });
        }
    };
    const Provider = struct {
        const Self = @This();
        session: *Session,
        mutation_busy: bool = false,
        nested_busy: bool = false,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.session.addUser("forbidden") catch |err| {
                self.mutation_busy = err == error.SessionBusy;
            };
            var nested_provider: NestedProvider = .{};
            if (run(std.testing.allocator, std.testing.io, .{
                .session = self.session,
                .provider = ai.Provider.Provider.from(&nested_provider, "nested"),
                .model = "model",
                .system_prompt = "system",
            })) |nested_result_value| {
                var nested_result = nested_result_value;
                nested_result.deinit(std.testing.allocator);
            } else |err| {
                self.nested_busy = err == error.SessionBusy;
            }
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const StreamObserver = struct {
        const Self = @This();
        session: *Session,
        mutation_busy: bool = false,

        pub fn emit(self: *Self, _: ai.StreamEvent.StreamEvent) void {
            self.session.addUser("forbidden") catch |err| {
                self.mutation_busy = err == error.SessionBusy;
            };
        }
    };
    const Usage = struct {
        const Self = @This();
        session: *Session,
        mutation_busy: bool = false,

        pub fn observe(self: *Self, _: UsageObservation) HookError!void {
            self.session.addUser("forbidden") catch |err| {
                self.mutation_busy = err == error.SessionBusy;
                return;
            };
            return error.Failed;
        }
    };
    const Seam = struct {
        const Self = @This();
        session: *Session,
        mutation_busy: bool = false,

        pub fn call(self: *Self, _: *const Session, _: SeamKind, _: bool) HookError!void {
            self.session.addUser("forbidden") catch |err| {
                self.mutation_busy = err == error.SessionBusy;
                return;
            };
            return error.Failed;
        }
    };

    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var provider: Provider = .{ .session = &session };
    var stream_observer: StreamObserver = .{ .session = &session };
    var usage: Usage = .{ .session = &session };
    var seam: Seam = .{ .session = &session };
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .observer = Observer.from(&stream_observer),
        .usage_observer = UsageObserver.from(&usage),
        .seam_hook = SeamHook.from(&seam),
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expect(provider.mutation_busy);
    try std.testing.expect(provider.nested_busy);
    try std.testing.expect(stream_observer.mutation_busy);
    try std.testing.expect(usage.mutation_busy);
    try std.testing.expect(seam.mutation_busy);
}

fn exerciseToolSettlementAllocations(allocator: std.mem.Allocator) !void {
    const Provider = struct {
        const Self = @This();
        rounds: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.rounds += 1;
            if (self.rounds == 1) {
                inline for (.{ "one", "two" }) |id| {
                    try sink.emit(.{ .tool_call_start = .{ .id = id, .name = "echo" } });
                    try sink.emit(.{ .tool_call_delta = .{ .id = id, .arguments_delta = "{}" } });
                    try sink.emit(.{ .tool_call_end = id });
                }
                try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 1 } } });
                return;
            }
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const SideEffectTool = struct {
        const Self = @This();
        side_effects: usize = 0,

        pub fn run(
            alloc: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.side_effects += 1;
            return .{ .output = try alloc.dupe(u8, "ok") };
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn call(self: *Self, _: *const Session, kind: SeamKind, _: bool) HookError!void {
            if (kind == .tool_batch) self.calls += 1;
        }
    };

    var provider: Provider = .{};
    var implementation: SideEffectTool = .{};
    var seam: Seam = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&implementation, test_definition, .{})};
    var session = try Session.init(allocator, .{});
    defer session.deinit();
    var loop_result = run(allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .seam_hook = SeamHook.from(&seam),
    }) catch |err| {
        if (session.items().len == 0) {
            try std.testing.expectEqual(@as(usize, 0), implementation.side_effects);
        } else {
            var call_count: usize = 0;
            var result_count: usize = 0;
            for (session.items()) |item| switch (item) {
                .tool_call => call_count += 1,
                .tool_result => result_count += 1,
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 2), call_count);
            try std.testing.expectEqual(call_count, result_count);
            try std.testing.expectEqual(@as(usize, 1), seam.calls);
        }
        return err;
    };
    loop_result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), implementation.side_effects);
    try std.testing.expectEqual(@as(usize, 1), seam.calls);
}

test "multi-tool allocation failures settle every accepted call before returning" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseToolSettlementAllocations,
        .{},
    );
}

test "resolved metadata prices retry and terminal usage before admission" {
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
                .maximum_attempts = 2,
                .delay_ms = 0,
                .usage = .{ .input_tokens = 7 },
            } });
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 3, .output_tokens = 2, .cost_usd = 1 } } });
        }
    };
    const Recorder = struct {
        const Self = @This();
        calls: usize = 0,
        context_tokens: ?u64 = null,
        kind: ?UsageKind = null,
        attempt_count: usize = 0,
        attempt_inputs: [2]?u64 = .{ null, null },

        pub fn observe(self: *Self, observation: UsageObservation) HookError!void {
            self.calls += 1;
            self.context_tokens = observation.terminal_context_tokens;
            self.kind = observation.kind;
            self.attempt_count = observation.attempts.len;
            for (observation.attempts, 0..) |attempt, index| {
                self.attempt_inputs[index] = attempt.input_tokens;
            }
        }
    };
    var fake: Fake = .{};
    var recorder: Recorder = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "provider"),
        .model = "model",
        .model_metadata = .{ .rates = .{ .input = 1, .output = 2 } },
        .system_prompt = "system",
        .usage_observer = UsageObserver.from(&recorder),
    });
    defer loop_result.deinit(std.testing.allocator);

    const usage = session.items()[session.items().len - 1].turn_usage.value;
    try std.testing.expectEqual(@as(?u64, 10), usage.stream.input_tokens);
    try std.testing.expectApproxEqAbs(0.00001, usage.cost_input_usd.?, 1e-15);
    try std.testing.expectApproxEqAbs(0.000004, usage.cost_output_usd.?, 1e-15);
    try std.testing.expectApproxEqAbs(1.000007, usage.cost_total_usd.?, 1e-15);
    try std.testing.expect(usage.cost_estimated);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(?u64, 5), recorder.context_tokens);
    try std.testing.expectEqual(UsageKind.ordinary, recorder.kind.?);
    try std.testing.expectEqual(@as(usize, 2), recorder.attempt_count);
    try std.testing.expectEqual(@as(?u64, 7), recorder.attempt_inputs[0]);
    try std.testing.expectEqual(@as(?u64, 3), recorder.attempt_inputs[1]);
}

test "live metadata is sampled after the stream and overrides stale fixed pricing" {
    const Source = struct {
        const Self = @This();
        metadata: ai.ModelMeta.Metadata = .{ .rates = .{ .input = 1, .output = 1 } },
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            return self.metadata;
        }
    };
    const Fake = struct {
        const Self = @This();
        source: *Source,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.source.metadata.rates.input = 3;
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 1_000_000 } } });
        }
    };
    var source: Source = .{};
    var fake: Fake = .{ .source = &source };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "provider"),
        .model = "model",
        .model_metadata = .{ .rates = .{ .input = 1, .output = 1 } },
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), source.calls);
    const usage = session.items()[session.items().len - 1].turn_usage.value;
    try std.testing.expectEqual(@as(?f64, 3), usage.cost_total_usd);
}

test "metadata source OOM falls back and persists completed usage" {
    const Source = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ModelMetadataSourceModule.CallbackError!ai.ModelMeta.Metadata {
            self.calls += 1;
            return error.OutOfMemory;
        }
    };
    const Fake = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 1_000_000 } } });
        }
    };
    var source: Source = .{};
    var fake: Fake = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var loop_result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "provider"),
        .model = "model",
        .model_metadata = .{ .rates = .{ .input = 2, .output = 1 } },
        .model_metadata_source = ModelMetadataSourceModule.ModelMetadataSource.from(&source),
        .system_prompt = "system",
    });
    defer loop_result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(Outcome.complete, loop_result.outcome);
    const usage = session.items()[session.items().len - 1].turn_usage.value;
    try std.testing.expectEqual(@as(?f64, 2), usage.cost_total_usd);
}

test "ordinary observation retains exact spend when retry is unpriced" {
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
                .maximum_attempts = 2,
                .delay_ms = 0,
                .usage = .{ .input_tokens = 10 },
            } });
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .{ .usage = .{ .input_tokens = 3, .cost_usd = 1 } } });
        }
    };
    const Recorder = struct {
        const Self = @This();
        calls: usize = 0,
        spend: ai.UsagePricing.Spend = .{},
        pub fn observe(self: *Self, observation: UsageObservation) HookError!void {
            self.calls += 1;
            self.spend = observation.spend;
        }
    };
    var fake: Fake = .{};
    var recorder: Recorder = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&fake, "provider"),
        .model = "model",
        .system_prompt = "system",
        .usage_observer = UsageObserver.from(&recorder),
    });
    defer result.deinit(std.testing.allocator);

    const footer = session.items()[session.items().len - 1].turn_usage.value;
    try std.testing.expect(footer.cost_total_usd == null);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(f64, 1), recorder.spend.known_usd);
    try std.testing.expect(recorder.spend.has_unpriced);
    try std.testing.expect(recorder.spend.estimated);
}

test "pre-request hook runs before first and next snapshots and between loop runs" {
    const Provider = struct {
        const Self = @This();
        round: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.round += 1;
            var note_count: usize = 0;
            for (request.context.items) |item| if (item == .user_message and
                item.user_message.origin == .task_note)
            {
                note_count += 1;
            };
            if (note_count != self.round) return error.InvalidRequest;
            if (self.round == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
            } else {
                try sink.emit(.{ .text_delta = "done" });
            }
            try sink.emit(.{ .done = .{} });
        }
    };
    const Echo = struct {
        const Self = @This();
        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            return .{ .output = try allocator.dupe(u8, "ok") };
        }
    };
    const Notes = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn call(self: *Self, session: *Session) HookError!void {
            self.calls += 1;
            var buffer: [32]u8 = undefined;
            const note = std.fmt.bufPrint(&buffer, "[note {d}]", .{self.calls}) catch return error.Failed;
            session.addTaskNote(note) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Failed,
            };
        }
    };

    var provider: Provider = .{};
    var echo: Echo = .{};
    var notes: Notes = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&echo, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var first = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .pre_request_hook = PreRequestHook.from(&notes),
    });
    first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), notes.calls);

    var second = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .continued = true,
        .pre_request_hook = PreRequestHook.from(&notes),
    });
    second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), notes.calls);
    try std.testing.expectEqual(@as(usize, 3), provider.round);
}

test "dynamic image input is resolved for each provider and tool operation" {
    const Source = struct {
        const Self = @This();
        values: []const ai.Provider.ImageInput,
        calls: usize = 0,
        callback_active: bool = false,

        pub fn resolve(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            self.callback_active = true;
            defer self.callback_active = false;
            const scratch = try allocator.alloc(u8, 1);
            defer allocator.free(scratch);
            const value = self.values[self.calls];
            self.calls += 1;
            return value;
        }
    };
    const Provider = struct {
        const Self = @This();
        source: *Source,
        rounds: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            if (self.source.callback_active) return error.InvalidProviderResponse;
            self.rounds += 1;
            if (self.rounds == 1) {
                if (request.context.image_input != .unknown) return error.InvalidProviderResponse;
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "image" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
                try sink.emit(.{ .tool_call_start = .{ .id = "two", .name = "image" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "two", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "two" });
            } else {
                if (request.context.image_input != .supported) return error.InvalidProviderResponse;
                var image_count: usize = 0;
                for (request.context.items) |item| {
                    if (item == .tool_result) image_count += item.tool_result.images.len;
                }
                if (image_count != 1) return error.InvalidProviderResponse;
                try sink.emit(.{ .text_delta = "done" });
            }
            try sink.emit(.{ .done = .{} });
        }
    };
    const ImageTool = struct {
        const Self = @This();
        source: *Source,
        accepted: usize = 0,
        refused: usize = 0,

        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            context: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            if (self.source.callback_active) return error.InvalidResult;
            if (context.image_input != .supported) {
                self.refused += 1;
                return .{ .output = try allocator.dupe(u8, "refused") };
            }
            self.accepted += 1;
            const output = try allocator.dupe(u8, "accepted");
            errdefer allocator.free(output);
            const images = try allocator.alloc(ai.Item.Image, 1);
            errdefer allocator.free(images);
            const mime = try allocator.dupe(u8, "image/png");
            errdefer allocator.free(mime);
            const data_base64 = try allocator.dupe(u8, "AAAA");
            images[0] = .{ .mime = mime, .data_base64 = data_base64 };
            return .{ .output = output, .images = images };
        }
    };

    const values = [_]ai.Provider.ImageInput{ .unknown, .supported, .unsupported, .supported };
    var source: Source = .{ .values = &values };
    var provider: Provider = .{ .source = &source };
    var image_tool: ImageTool = .{ .source = &source };
    const definition: tool.Tool.Definition = .{
        .name = "image",
        .description = "returns an image when accepted",
        .parameters = &.{},
    };
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&image_tool, definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.complete, result.outcome);
    try std.testing.expectEqual(@as(usize, 4), source.calls);
    try std.testing.expectEqual(@as(usize, 1), image_tool.accepted);
    try std.testing.expectEqual(@as(usize, 1), image_tool.refused);
}

test "fixed image input remains the fallback without a source" {
    const Provider = struct {
        const Self = @This();
        rounds: usize = 0,
        fixed_each_request: bool = true,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.rounds += 1;
            self.fixed_each_request = self.fixed_each_request and request.context.image_input == .unsupported;
            if (self.rounds == 1) {
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
            }
            try sink.emit(.{ .done = .{} });
        }
    };
    const FixedTool = struct {
        const Self = @This();
        seen: ai.Provider.ImageInput = .unknown,

        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            context: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.seen = context.image_input;
            return .{ .output = try allocator.dupe(u8, "fixed") };
        }
    };
    var provider: Provider = .{};
    var fixed_tool: FixedTool = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&fixed_tool, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .image_input = .unsupported,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(provider.fixed_each_request);
    try std.testing.expectEqual(ai.Provider.ImageInput.unsupported, fixed_tool.seen);
}

test "image input source errors precede provider side effects" {
    const Source = struct {
        const Self = @This();
        failure: ImageInputSourceModule.CallbackError,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            return self.failure;
        }
    };
    const Provider = struct {
        const Self = @This();
        called: bool = false,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ai.Provider.Request,
            _: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.called = true;
        }
    };

    for ([_]ImageInputSourceModule.CallbackError{ error.OutOfMemory, error.Failed }) |failure| {
        var source: Source = .{ .failure = failure };
        var provider: Provider = .{};
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        const expected: Error = if (failure == error.OutOfMemory) error.OutOfMemory else error.HookFailed;
        try std.testing.expectError(expected, run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "system",
            .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
        }));
        try std.testing.expect(!provider.called);
        try std.testing.expectEqual(@as(usize, 0), session.items().len);
    }
}

test "image input source failure settles a tool placeholder before returning" {
    const Source = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            self.calls += 1;
            if (self.calls == 1) return .unknown;
            return error.Failed;
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
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const SideEffectTool = struct {
        const Self = @This();
        calls: usize = 0,
        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.calls += 1;
            return .{ .output = try allocator.dupe(u8, "ran") };
        }
    };

    var source: Source = .{};
    var provider: Provider = .{};
    var side_effect_tool: SideEffectTool = .{};
    var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&side_effect_tool, test_definition, .{})};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.HookFailed, run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .tools = &tools,
        .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
    }));
    try std.testing.expectEqual(@as(usize, 0), side_effect_tool.calls);
    try std.testing.expectEqual(@as(usize, 3), session.items().len);
    try std.testing.expect(session.items()[1] == .tool_result);
    try std.testing.expectEqualStrings(
        "error: tool execution did not complete",
        session.items()[1].tool_result.output,
    );
}

test "image input is resolved for refused and abort-skipped tool actions" {
    const Mode = enum { refused, skipped };
    const Source = struct {
        const Self = @This();
        values: []const ai.Provider.ImageInput,
        calls: usize = 0,
        action_value: ?ai.Provider.ImageInput = null,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            const value = self.values[self.calls];
            self.calls += 1;
            if (self.calls == 2) self.action_value = value;
            return value;
        }
    };
    const Provider = struct {
        const Self = @This();
        mode: Mode,
        rounds: usize = 0,

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            request: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            self.rounds += 1;
            if (self.rounds == 1) {
                if (request.context.image_input != .supported) return error.InvalidProviderResponse;
                try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
                try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
                try sink.emit(.{ .tool_call_end = "one" });
            } else if (self.mode != .refused or request.context.image_input != .unknown) {
                return error.InvalidProviderResponse;
            }
            try sink.emit(.{ .done = .{} });
        }
    };
    const SideEffectTool = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.calls += 1;
            return .{ .output = try allocator.dupe(u8, "ran") };
        }
    };
    const Abort = struct {
        const Self = @This();
        samples: usize = 0,

        pub fn sample(self: *Self) Signal {
            self.samples += 1;
            return if (self.samples == 1) .none else .abort;
        }
    };

    for ([_]Mode{ .refused, .skipped }) |mode| {
        const values = [_]ai.Provider.ImageInput{ .supported, .unsupported, .unknown };
        var source: Source = .{ .values = &values };
        var provider: Provider = .{ .mode = mode };
        var side_effect_tool: SideEffectTool = .{};
        var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&side_effect_tool, test_definition, .{})};
        const selected_tools: []const tool.Tool.Tool = if (mode == .skipped) &tools else &.{};
        var abort: Abort = .{};
        var session = try Session.init(std.testing.allocator, .{});
        defer session.deinit();
        var loop_result = try run(std.testing.allocator, std.testing.io, .{
            .session = &session,
            .provider = ai.Provider.Provider.from(&provider, "fake"),
            .model = "model",
            .system_prompt = "system",
            .tools = selected_tools,
            .checkpoint = if (mode == .skipped) Checkpoint.from(&abort) else null,
            .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
        });
        defer loop_result.deinit(std.testing.allocator);

        try std.testing.expectEqual(
            if (mode == .refused) Outcome.complete else Outcome.interrupted,
            loop_result.outcome,
        );
        try std.testing.expectEqual(if (mode == .refused) @as(usize, 3) else 2, source.calls);
        try std.testing.expectEqual(ai.Provider.ImageInput.unsupported, source.action_value.?);
        try std.testing.expectEqual(@as(usize, 0), side_effect_tool.calls);
        try std.testing.expect(session.items()[1] == .tool_result);
        try std.testing.expectEqual(
            if (mode == .refused) ai.Item.ToolResultOrigin.refused else ai.Item.ToolResultOrigin.skipped,
            session.items()[1].tool_result.origin,
        );
    }
}

test "image input failure settles refused and abort-skipped placeholders" {
    const Mode = enum { refused, skipped };
    const Source = struct {
        const Self = @This();
        failure: ImageInputSourceModule.CallbackError,
        calls: usize = 0,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            self.calls += 1;
            if (self.calls == 1) return .supported;
            return self.failure;
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
            if (request.context.image_input != .supported) return error.InvalidProviderResponse;
            try sink.emit(.{ .tool_call_start = .{ .id = "one", .name = "echo" } });
            try sink.emit(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{}" } });
            try sink.emit(.{ .tool_call_end = "one" });
            try sink.emit(.{ .done = .{} });
        }
    };
    const SideEffectTool = struct {
        const Self = @This();
        calls: usize = 0,

        pub fn run(
            allocator: std.mem.Allocator,
            _: std.Io,
            self: *Self,
            _: ?[]const u8,
            _: tool.Tool.RunContext,
        ) tool.Tool.RunError!tool.Tool.Result {
            self.calls += 1;
            return .{ .output = try allocator.dupe(u8, "ran") };
        }
    };
    const Abort = struct {
        const Self = @This();
        samples: usize = 0,

        pub fn sample(self: *Self) Signal {
            self.samples += 1;
            return if (self.samples == 1) .none else .abort;
        }
    };
    const Seam = struct {
        const Self = @This();
        calls: usize = 0,
        kind: ?SeamKind = null,
        next_action: bool = true,
        item_count: usize = 0,

        pub fn call(self: *Self, session: *const Session, kind: SeamKind, next_action: bool) HookError!void {
            self.calls += 1;
            self.kind = kind;
            self.next_action = next_action;
            self.item_count = session.items().len;
        }
    };

    for ([_]Mode{ .refused, .skipped }) |mode| {
        for ([_]ImageInputSourceModule.CallbackError{ error.OutOfMemory, error.Failed }) |failure| {
            var source: Source = .{ .failure = failure };
            var provider: Provider = .{};
            var side_effect_tool: SideEffectTool = .{};
            var tools = [_]tool.Tool.Tool{tool.Tool.Tool.from(&side_effect_tool, test_definition, .{})};
            const selected_tools: []const tool.Tool.Tool = if (mode == .skipped) &tools else &.{};
            var abort: Abort = .{};
            var seam: Seam = .{};
            var session = try Session.init(std.testing.allocator, .{});
            defer session.deinit();
            const expected: Error = if (failure == error.OutOfMemory) error.OutOfMemory else error.HookFailed;
            try std.testing.expectError(expected, run(std.testing.allocator, std.testing.io, .{
                .session = &session,
                .provider = ai.Provider.Provider.from(&provider, "fake"),
                .model = "model",
                .system_prompt = "system",
                .tools = selected_tools,
                .checkpoint = if (mode == .skipped) Checkpoint.from(&abort) else null,
                .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
                .seam_hook = SeamHook.from(&seam),
            }));

            try std.testing.expectEqual(@as(usize, 2), source.calls);
            try std.testing.expectEqual(@as(usize, 0), side_effect_tool.calls);
            try std.testing.expectEqual(@as(usize, 1), seam.calls);
            try std.testing.expectEqual(SeamKind.tool_batch, seam.kind.?);
            try std.testing.expect(!seam.next_action);
            try std.testing.expectEqual(@as(usize, 3), seam.item_count);
            try std.testing.expectEqual(@as(usize, 3), session.items().len);
            try std.testing.expect(session.items()[0] == .tool_call);
            try std.testing.expect(session.items()[1] == .tool_result);
            try std.testing.expectEqual(ai.Item.ToolResultOrigin.skipped, session.items()[1].tool_result.origin);
            try std.testing.expectEqualStrings(
                "error: tool execution did not complete",
                session.items()[1].tool_result.output,
            );
            try std.testing.expect(session.items()[2] == .turn_usage);
        }
    }
}

test "image input source runs under the session lease" {
    const Source = struct {
        const Self = @This();
        session: *Session,
        mutation_busy: bool = false,

        pub fn resolve(
            _: std.mem.Allocator,
            _: std.Io,
            self: *Self,
        ) ImageInputSourceModule.CallbackError!ai.Provider.ImageInput {
            self.session.addUser("forbidden") catch |err| {
                self.mutation_busy = err == error.SessionBusy;
                return .supported;
            };
            return error.Failed;
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
            try sink.emit(.{ .done = .{} });
        }
    };

    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var source: Source = .{ .session = &session };
    var provider: Provider = .{};
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "system",
        .image_input_source = ImageInputSourceModule.ImageInputSource.from(&source),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(source.mutation_busy);
}

test "incomplete provider response exposes a repaired partial marker" {
    const Provider = struct {
        const Self = @This();

        pub fn stream(
            _: std.mem.Allocator,
            _: std.Io,
            _: *Self,
            _: ai.Provider.Request,
            sink: ai.Provider.EventSink,
        ) ai.Provider.StreamError!void {
            try sink.emit(.{ .text_delta = "partial" });
        }
    };

    var provider: Provider = .{};
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result = try run(std.testing.allocator, std.testing.io, .{
        .session = &session,
        .provider = ai.Provider.Provider.from(&provider, "fake"),
        .model = "model",
        .system_prompt = "",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Outcome.provider_error, result.outcome);
    try std.testing.expect(result.abort_marker_placed);
    try std.testing.expectEqualStrings("InvalidProviderResponse", result.diagnostic.?);
}
