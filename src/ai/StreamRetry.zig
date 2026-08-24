const std = @import("std");
const ApiError = @import("ApiError.zig");
const Provider = @import("Provider.zig");
const Retry = @import("Retry.zig");
const StreamEvent = @import("StreamEvent.zig");
const Transport = @import("Transport.zig");
const Usage = @import("Usage.zig");

pub const default_max_incomplete_recoveries: u16 = 2;
pub const maximum_incomplete_recoveries: u16 = 16;
/// Settings `http.max_retries` admits at most 100 retries after the initial request.
/// This bound therefore counts 101 total attempts.
pub const maximum_attempts: u16 = 101;
pub const maximum_delay_ms: u64 = Retry.retry_after_max_ms;

pub const ParseError = error{ OutOfMemory, Cancelled, InvalidResponse };
pub const BuildError = error{ OutOfMemory, InvalidRequest };

/// A fresh protocol parser and its fresh request headers. All returned slices are
/// borrowed until `deinit`. Parser implementations deliver provider events to the
/// sink passed to `Factory.create`.
pub const Attempt = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Failure = struct {
        status: ?u16 = null,
        body: ?[]const u8 = null,
    };

    pub const VTable = struct {
        headers: *const fn (*anyopaque) []const Transport.Header,
        feed: *const fn (*anyopaque, Transport.SseEvent) ParseError!void,
        finalize: *const fn (*anyopaque) ParseError!void,
        deinit: *const fn (std.mem.Allocator, *anyopaque) void,
        is_complete: *const fn (*const anyopaque) bool,
        usage: *const fn (*const anyopaque) ?Usage.StreamUsage,
        recover_incomplete: *const fn (*anyopaque) ParseError!bool,
        failure: *const fn (*const anyopaque) ?Failure,
    };

    pub fn headers(self: Attempt) []const Transport.Header {
        return self.vtable.headers(self.context);
    }
    pub fn feed(self: Attempt, event: Transport.SseEvent) ParseError!void {
        return self.vtable.feed(self.context, event);
    }
    pub fn finalize(self: Attempt) ParseError!void {
        return self.vtable.finalize(self.context);
    }
    pub fn deinit(self: *Attempt, allocator: std.mem.Allocator) void {
        self.vtable.deinit(allocator, self.context);
        self.* = undefined;
    }
    pub fn isComplete(self: Attempt) bool {
        return self.vtable.is_complete(self.context);
    }
    pub fn usage(self: Attempt) ?Usage.StreamUsage {
        return self.vtable.usage(self.context);
    }
    /// True asks the driver to recreate the attempt without consuming retry budget.
    pub fn recoverIncomplete(self: Attempt) ParseError!bool {
        return self.vtable.recover_incomplete(self.context);
    }
    pub fn failure(self: Attempt) ?Failure {
        return self.vtable.failure(self.context);
    }
};

pub const Factory = struct {
    context: *anyopaque,
    create_fn: *const fn (std.mem.Allocator, *anyopaque, u16, Provider.EventSink) BuildError!Attempt,

    pub fn from(implementation: anytype) Factory {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Factory.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn create(
                allocator: std.mem.Allocator,
                context: *anyopaque,
                attempt: u16,
                sink: Provider.EventSink,
            ) BuildError!Attempt {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.create(allocator, attempt, sink);
            }
        };
        return .{ .context = implementation, .create_fn = Adapter.create };
    }

    pub fn create(
        self: Factory,
        allocator: std.mem.Allocator,
        attempt: u16,
        sink: Provider.EventSink,
    ) BuildError!Attempt {
        return self.create_fn(allocator, self.context, attempt, sink);
    }
};

pub const FailureOverride = union(enum) {
    formatted: struct {
        status: ?u16 = null,
        body: ?[]const u8 = null,
    },
    /// Bounded user-facing text. Implementations must never include credentials or secrets.
    message: []const u8,
};

pub const UnauthorizedDecision = union(enum) {
    retry,
    use_response,
    fail: FailureOverride,
};

/// Optional, single-use recovery hook for an HTTP 401 response. Returned
/// diagnostic slices are borrowed for the duration of `run`. Recovery implementations
/// must never place credentials or other secret material in a failure override.
pub const UnauthorizedRecovery = struct {
    context: *anyopaque,
    recover_fn: *const fn (
        std.mem.Allocator,
        std.Io,
        *anyopaque,
        ?Provider.Tick,
    ) error{ OutOfMemory, Cancelled }!UnauthorizedDecision,
    note_unauthorized_fn: ?*const fn (*anyopaque) void = null,

    pub fn recover(
        self: UnauthorizedRecovery,
        allocator: std.mem.Allocator,
        io: std.Io,
        tick: ?Provider.Tick,
    ) error{ OutOfMemory, Cancelled }!UnauthorizedDecision {
        return self.recover_fn(allocator, io, self.context, tick);
    }

    pub fn noteUnauthorized(self: UnauthorizedRecovery) void {
        if (self.note_unauthorized_fn) |note| note(self.context);
    }

    pub fn from(implementation: anytype) UnauthorizedRecovery {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("UnauthorizedRecovery.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn recover(
                allocator: std.mem.Allocator,
                io: std.Io,
                context: *anyopaque,
                tick: ?Provider.Tick,
            ) error{ OutOfMemory, Cancelled }!UnauthorizedDecision {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.recover(allocator, io, tick);
            }
            fn noteUnauthorized(context: *anyopaque) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.noteUnauthorized();
            }
        };
        return .{
            .context = implementation,
            .recover_fn = Adapter.recover,
            .note_unauthorized_fn = if (@hasDecl(Implementation, "noteUnauthorized"))
                Adapter.noteUnauthorized
            else
                null,
        };
    }
};

pub const Request = struct {
    url: []const u8,
    json_body: []const u8,
    tick: ?Provider.Tick = null,
    unauthorized_recovery: ?UnauthorizedRecovery = null,
    limits: Transport.Limits,
};

pub const Options = struct {
    policy: Retry.Policy = Retry.default_policy,
    max_incomplete_recoveries: u16 = default_max_incomplete_recoveries,
    /// Deterministic entropy seed. Callers may obtain it from their own RNG.
    entropy: u64 = 0,
};

pub const Error = Provider.StreamError;

/// Runs a protocol-neutral streaming request. Runtime/provider failures are
/// delivered exactly once as `.failure`; only allocation, cancellation, and an
/// invalid driver request are returned as errors.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: Transport.Transport,
    factory: Factory,
    request: Request,
    sink: Provider.EventSink,
    options: Options,
) Error!void {
    if (options.policy.max_attempts == 0 or options.policy.max_attempts > maximum_attempts or
        options.policy.base_delay_ms > maximum_delay_ms or
        options.policy.max_delay_ms > maximum_delay_ms or
        options.max_incomplete_recoveries > maximum_incomplete_recoveries or
        request.limits.max_error_body_bytes > ApiError.maximum_body_bytes)
    {
        return error.InvalidRequest;
    }

    var attempt_number: u16 = 1;
    var incomplete_recoveries: u16 = 0;
    var unauthorized_recovery_used = false;
    while (true) {
        var parser = try factory.create(allocator, attempt_number, sink);
        var parser_live = true;
        defer if (parser_live) parser.deinit(allocator);

        var adapter: ParserSink = .{ .parser = parser };
        var result = transport.ssePost(allocator, io, .{
            .url = request.url,
            .headers = parser.headers(),
            .json_body = request.json_body,
            .tick = request.tick,
            .limits = request.limits,
        }, Transport.EventSink.from(&adapter)) catch |transport_error| {
            if (adapter.parse_error) |parse_error| return parseErrorToDriver(parse_error);
            if (transport_error == error.OutOfMemory) return error.OutOfMemory;
            if (transport_error == error.Cancelled) return error.Cancelled;
            if (transport_error == error.InvalidRequest) return error.InvalidRequest;
            if (transport_error == error.InvalidResponse) return error.InvalidProviderResponse;
            const retryable = Retry.shouldAttempt(false, 0, "");
            const custom = parser.failure();
            if (retryable and attempt_number < options.policy.max_attempts) {
                const usage = parser.usage();
                const delay = Retry.delayMs(options.policy, attempt_number - 1, options.entropy +% attempt_number);
                try sink.emit(.{ .retry = .{
                    .attempt = attempt_number,
                    .maximum_attempts = options.policy.max_attempts,
                    .delay_ms = delay,
                    .usage = usage,
                } });
                parser.deinit(allocator);
                parser_live = false;
                try cancellableSleep(io, request.tick, delay);
                attempt_number += 1;
                continue;
            }
            const message = try failureMessage(allocator, custom, 0, transportErrorText(transport_error));
            defer allocator.free(message);
            try sink.emit(.{ .failure = .{ .message = message } });
            return;
        };
        var result_live = true;
        defer if (result_live) result.deinit(allocator);

        const is_success = result.status >= 200 and result.status < 300;
        const is_complete = parser.isComplete();
        if (is_success and is_complete) {
            parser.finalize() catch |parse_error| return parseErrorToDriver(parse_error);
            return;
        }
        if (is_success and !is_complete and
            try tryIncompleteRecovery(
                &parser,
                &incomplete_recoveries,
                options.max_incomplete_recoveries,
            ))
        {
            result.deinit(allocator);
            result_live = false;
            parser.deinit(allocator);
            parser_live = false;
            continue;
        }
        if (result.status == 401 and !unauthorized_recovery_used) {
            if (request.unauthorized_recovery) |recovery| {
                unauthorized_recovery_used = true;
                switch (try recovery.recover(allocator, io, request.tick)) {
                    .retry => {
                        result.deinit(allocator);
                        result_live = false;
                        parser.deinit(allocator);
                        parser_live = false;
                        continue;
                    },
                    .use_response => {},
                    .fail => |failure_override| {
                        try emitFailureOverride(allocator, sink, failure_override, result.status, recovery);
                        return;
                    },
                }
            }
        }

        const custom = parser.failure();
        const body = result.error_body orelse "";
        // hax retries an incomplete 2xx even after a transport failure because
        // tools cannot run until the complete response is admitted.
        const retryable = if (is_success)
            !is_complete
        else
            Retry.shouldAttempt(result.outcome == .completed, result.status, body);
        if (retryable and attempt_number < options.policy.max_attempts) {
            const usage = if (is_success) parser.usage() else null;
            const delay = result.retry_after_ms orelse
                Retry.delayMs(options.policy, attempt_number - 1, options.entropy +% attempt_number);
            try sink.emit(.{ .retry = .{
                .attempt = attempt_number,
                .maximum_attempts = options.policy.max_attempts,
                .delay_ms = delay,
                .http_status = if (result.status == 0) null else result.status,
                .usage = usage,
            } });
            result.deinit(allocator);
            result_live = false;
            parser.deinit(allocator);
            parser_live = false;
            try cancellableSleep(io, request.tick, delay);
            attempt_number += 1;
            continue;
        }

        if (is_success and result.outcome == .completed) {
            parser.finalize() catch |parse_error| return parseErrorToDriver(parse_error);
            return;
        }

        if (result.status == 401) {
            if (request.unauthorized_recovery) |recovery| recovery.noteUnauthorized();
        }
        const message = try failureMessage(allocator, custom, result.status, result.error_body);
        defer allocator.free(message);
        try sink.emit(.{ .failure = .{
            .message = message,
            .http_status = if (result.status == 0) null else result.status,
            .usage = if (is_success and !is_complete) parser.usage() else null,
        } });
        return;
    }
}

const ParserSink = struct {
    parser: Attempt,
    parse_error: ?ParseError = null,

    pub fn emit(self: *ParserSink, event: Transport.SseEvent) Transport.DeliveryError!void {
        self.parser.feed(event) catch |err| {
            self.parse_error = err;
            return error.Cancelled;
        };
    }
};

fn tryIncompleteRecovery(parser: *Attempt, count: *u16, limit: u16) Error!bool {
    if (count.* >= limit) return false;
    const redo = parser.recoverIncomplete() catch |err| return parseErrorToDriver(err);
    if (!redo) return false;
    count.* += 1;
    return true;
}

fn parseErrorToDriver(err: ParseError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.InvalidResponse => error.InvalidProviderResponse,
    };
}

fn cancellableSleep(io: std.Io, tick: ?Provider.Tick, delay_ms: u64) Error!void {
    var plan = Retry.SleepPlan.init(delay_ms);
    while (plan.needsPoll()) {
        if (tick) |value| value.poll() catch return error.Cancelled;
        const slice = plan.next() orelse break;
        io.sleep(.fromMilliseconds(@intCast(slice)), .awake) catch return error.Cancelled;
    }
}

fn emitFailureOverride(
    allocator: std.mem.Allocator,
    sink: Provider.EventSink,
    failure_override: FailureOverride,
    response_status: u16,
    recovery: UnauthorizedRecovery,
) Error!void {
    defer recovery.noteUnauthorized();
    switch (failure_override) {
        .message => |raw_message| {
            const message = ApiError.formatMessage(allocator, raw_message) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BodyTooLarge => try allocator.dupe(u8, "authentication recovery failed"),
            };
            defer allocator.free(message);
            try sink.emit(.{ .failure = .{
                .message = message,
                .http_status = response_status,
            } });
        },
        .formatted => |formatted| {
            const status = if (formatted.status) |value|
                if (value >= 100 and value <= 599) value else response_status
            else
                response_status;
            const message = try failureMessage(
                allocator,
                .{ .status = status, .body = formatted.body },
                response_status,
                null,
            );
            defer allocator.free(message);
            try sink.emit(.{ .failure = .{
                .message = message,
                .http_status = status,
            } });
        },
    }
}

fn failureMessage(
    allocator: std.mem.Allocator,
    custom: ?Attempt.Failure,
    status: u16,
    body: ?[]const u8,
) error{OutOfMemory}![]u8 {
    if (custom) |value| {
        return ApiError.format(allocator, value.status orelse status, value.body) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BodyTooLarge => formatStatusOnly(allocator, value.status orelse status),
        };
    }
    return ApiError.format(allocator, status, body) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BodyTooLarge => formatStatusOnly(allocator, status),
    };
}

fn formatStatusOnly(allocator: std.mem.Allocator, status: u16) error{OutOfMemory}![]u8 {
    return ApiError.format(allocator, status, null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BodyTooLarge => unreachable,
    };
}

fn transportErrorText(err: Transport.StreamError) []const u8 {
    return switch (err) {
        error.ConnectTimedOut => "connection timed out",
        error.IdleTimedOut => "stream timed out",
        error.InvalidRequest => "invalid transport request",
        error.ConnectionFailed => "connection failed",
        error.TlsVerificationFailed => "TLS certificate verification failed",
        error.InvalidResponse => "invalid transport response",
        error.OutOfMemory, error.Cancelled => unreachable,
    };
}

const TestStep = struct {
    status: u16,
    data: ?[]const u8 = null,
    body: ?[]const u8 = null,
    retry_after_ms: ?u64 = null,
    outcome: ?Transport.Outcome = null,
    transport_error: ?Transport.StreamError = null,
};

const TestTransport = struct {
    steps: []const TestStep,
    calls: usize = 0,
    header_values: [maximum_attempts]?[]const u8 = @splat(null),

    pub fn ssePost(
        allocator: std.mem.Allocator,
        _: std.Io,
        self: *TestTransport,
        request: Transport.Request,
        sink: Transport.EventSink,
    ) Transport.StreamError!Transport.Result {
        const index = self.calls;
        self.calls += 1;
        self.header_values[index] = request.headers[0].value;
        const step = self.steps[index];
        if (step.transport_error) |transport_error| return transport_error;
        if (step.data) |data| try sink.emit(.{ .data = data });
        return .{
            .status = step.status,
            .outcome = step.outcome orelse if (step.status >= 200 and step.status < 300) .completed else .failed,
            .retry_after_ms = step.retry_after_ms,
            .error_body = if (step.body) |body| try allocator.dupe(u8, body) else null,
        };
    }
};

const TestFactory = struct {
    creates: usize = 0,
    deinits: usize = 0,
    incomplete_recoveries_remaining: u16 = 0,
    finalizes: usize = 0,
    start_complete: bool = false,
    attempt_numbers: [maximum_attempts]u16 = @splat(0),

    const Parser = struct {
        owner: *TestFactory,
        sink: Provider.EventSink,
        complete: bool = false,
        usage_value: ?Usage.StreamUsage = null,
        header: [1]Transport.Header,

        fn headers(context: *anyopaque) []const Transport.Header {
            const self: *Parser = @ptrCast(@alignCast(context));
            return &self.header;
        }
        fn feed(context: *anyopaque, event: Transport.SseEvent) ParseError!void {
            const self: *Parser = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, event.data, "done")) {
                self.complete = true;
                try self.sink.emit(.{ .done = .{} });
            } else if (std.mem.eql(u8, event.data, "usage")) {
                self.usage_value = .{ .input_tokens = 7, .output_tokens = 2 };
                try self.sink.emit(.{ .text_delta = "partial" });
            }
        }
        fn finalize(context: *anyopaque) ParseError!void {
            const self: *Parser = @ptrCast(@alignCast(context));
            self.owner.finalizes += 1;
            if (!self.complete) {
                self.complete = true;
                try self.sink.emit(.{ .failure = .{
                    .message = "stream ended before completion",
                    .usage = self.usage_value,
                } });
            }
        }
        fn deinit(allocator: std.mem.Allocator, context: *anyopaque) void {
            const self: *Parser = @ptrCast(@alignCast(context));
            self.owner.deinits += 1;
            allocator.destroy(self);
        }
        fn isComplete(context: *const anyopaque) bool {
            const self: *const Parser = @ptrCast(@alignCast(context));
            return self.complete;
        }
        fn usage(context: *const anyopaque) ?Usage.StreamUsage {
            const self: *const Parser = @ptrCast(@alignCast(context));
            return self.usage_value;
        }
        fn recoverIncomplete(context: *anyopaque) ParseError!bool {
            const self: *Parser = @ptrCast(@alignCast(context));
            if (self.owner.incomplete_recoveries_remaining == 0) return false;
            self.owner.incomplete_recoveries_remaining -= 1;
            return true;
        }
        fn failure(_: *const anyopaque) ?Attempt.Failure {
            return null;
        }
        const vtable: Attempt.VTable = .{
            .headers = headers,
            .feed = feed,
            .finalize = finalize,
            .deinit = deinit,
            .is_complete = isComplete,
            .usage = usage,
            .recover_incomplete = recoverIncomplete,
            .failure = failure,
        };
    };

    fn create(
        self: *TestFactory,
        allocator: std.mem.Allocator,
        attempt_number: u16,
        sink: Provider.EventSink,
    ) BuildError!Attempt {
        self.attempt_numbers[self.creates] = attempt_number;
        self.creates += 1;
        const value = if (attempt_number == 1) "one" else "two";
        const parser = try allocator.create(Parser);
        parser.* = .{
            .owner = self,
            .sink = sink,
            .complete = self.start_complete,
            .header = .{.{ .name = "X-Attempt", .value = value }},
        };
        return .{ .context = parser, .vtable = &Parser.vtable };
    }
};

const TestCollector = struct {
    retries: usize = 0,
    failures: usize = 0,
    done: usize = 0,
    retry_attempt: u16 = 0,
    retry_delay: u64 = 0,
    retry_usage: ?Usage.StreamUsage = null,
    failure_usage: ?Usage.StreamUsage = null,
    failure_status: ?u16 = null,
    failure_message: [256]u8 = undefined,
    failure_message_len: usize = 0,

    fn failureMessage(self: *const TestCollector) []const u8 {
        return self.failure_message[0..self.failure_message_len];
    }

    pub fn emit(self: *TestCollector, event: StreamEvent.StreamEvent) Provider.DeliveryError!void {
        switch (event) {
            .retry => |value| {
                self.retries += 1;
                self.retry_attempt = value.attempt;
                self.retry_delay = value.delay_ms;
                self.retry_usage = value.usage;
            },
            .failure => |value| {
                self.failures += 1;
                self.failure_usage = value.usage;
                self.failure_status = value.http_status;
                self.failure_message_len = @min(value.message.len, self.failure_message.len);
                @memcpy(self.failure_message[0..self.failure_message_len], value.message[0..self.failure_message_len]);
            },
            .done => self.done += 1,
            else => {},
        }
    }
};

const test_limits: Transport.Limits = .{
    .max_request_body_bytes = 64,
    .max_header_bytes = 64,
    .max_sse_event_bytes = 64,
    .max_error_body_bytes = 64,
    .header_buffer_bytes = 64,
    .connect_timeout_ms = 1,
    .idle_timeout_ms = 1,
};

fn testRun(
    allocator: std.mem.Allocator,
    transport: *TestTransport,
    factory: *TestFactory,
    collector: *TestCollector,
    options: Options,
    tick: ?Provider.Tick,
) Error!void {
    return testRunWithUnauthorized(allocator, transport, factory, collector, options, tick, null);
}

fn testRunWithUnauthorized(
    allocator: std.mem.Allocator,
    transport: *TestTransport,
    factory: *TestFactory,
    collector: *TestCollector,
    options: Options,
    tick: ?Provider.Tick,
    unauthorized_recovery: ?UnauthorizedRecovery,
) Error!void {
    return run(
        allocator,
        std.testing.io,
        Transport.Transport.from(transport),
        Factory.from(factory),
        .{
            .url = "https://example.test",
            .json_body = "{}",
            .limits = test_limits,
            .tick = tick,
            .unauthorized_recovery = unauthorized_recovery,
        },
        Provider.EventSink.from(collector),
        options,
    );
}

const RecoveryStep = union(enum) {
    decision: UnauthorizedDecision,
    out_of_memory,
    cancelled,
};

const TestUnauthorizedRecovery = struct {
    steps: []const RecoveryStep,
    calls: usize = 0,
    unauthorized_notes: usize = 0,

    fn noteUnauthorized(self: *TestUnauthorizedRecovery) void {
        self.unauthorized_notes += 1;
    }

    fn recover(
        self: *TestUnauthorizedRecovery,
        _: std.mem.Allocator,
        _: std.Io,
        _: ?Provider.Tick,
    ) error{ OutOfMemory, Cancelled }!UnauthorizedDecision {
        const step = self.steps[self.calls];
        self.calls += 1;
        return switch (step) {
            .decision => |decision| decision,
            .out_of_memory => error.OutOfMemory,
            .cancelled => error.Cancelled,
        };
    }
};

test "incomplete 2xx retries with usage and fresh parser state" {
    const steps = [_]TestStep{
        .{ .status = 200, .data = "usage" },
        .{ .status = 200, .data = "done" },
    };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRun(std.testing.allocator, &transport, &factory, &collector, .{
        .policy = .{ .max_attempts = 2, .base_delay_ms = 0 },
    }, null);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqualStrings("one", transport.header_values[0].?);
    try std.testing.expectEqualStrings("two", transport.header_values[1].?);
    try std.testing.expectEqual(@as(usize, 2), factory.deinits);
    try std.testing.expectEqual(@as(usize, 1), collector.retries);
    try std.testing.expectEqual(@as(u16, 1), collector.retry_attempt);
    try std.testing.expectEqual(@as(?u64, 7), collector.retry_usage.?.input_tokens);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
}

test "terminal quota 429 is not retried and non-2xx strands no usage" {
    const steps = [_]TestStep{.{
        .status = 429,
        .data = "usage",
        .body = "{\"error\":{\"type\":\"insufficient_quota\"}}",
    }};
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRun(std.testing.allocator, &transport, &factory, &collector, .{}, null);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(@as(usize, 0), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
    try std.testing.expect(collector.failure_usage == null);
    try std.testing.expectEqual(@as(?u16, 429), collector.failure_status);
}

test "bounded incomplete recovery recreates parser without consuming attempt" {
    const steps = [_]TestStep{
        .{ .status = 200 },
        .{ .status = 200, .data = "done" },
    };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{ .incomplete_recoveries_remaining = 1 };
    var collector: TestCollector = .{};
    try testRun(std.testing.allocator, &transport, &factory, &collector, .{}, null);
    try std.testing.expectEqualSlices(u16, &.{ 1, 1 }, factory.attempt_numbers[0..2]);
    try std.testing.expectEqual(@as(usize, 0), collector.retries);
    try std.testing.expectEqual(@as(usize, 2), factory.deinits);
}

test "exhausted incomplete 2xx attaches stranded usage once" {
    const steps = [_]TestStep{.{ .status = 200, .data = "usage" }};
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRun(std.testing.allocator, &transport, &factory, &collector, .{
        .policy = .{ .max_attempts = 1 },
    }, null);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
    try std.testing.expectEqual(@as(?u64, 7), collector.failure_usage.?.input_tokens);
}

test "sleep polls cancellation and allocation failure leaves no parser" {
    const Ticker = struct {
        const Self = @This();
        polls: usize = 0,
        pub fn poll(self: *Self) Provider.DeliveryError!void {
            self.polls += 1;
            if (self.polls == 2) return error.Cancelled;
        }
    };
    const steps = [_]TestStep{
        .{ .status = 503, .retry_after_ms = 250 },
        .{ .status = 200, .data = "done" },
    };
    var ticker: Ticker = .{};
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try std.testing.expectError(error.Cancelled, testRun(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{ .policy = .{ .max_attempts = 2 } },
        Provider.Tick.from(&ticker),
    ));
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(@as(u64, 250), collector.retry_delay);
    try std.testing.expectEqual(@as(usize, 1), factory.deinits);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    transport.calls = 0;
    factory = .{};
    collector = .{};
    try std.testing.expectError(error.OutOfMemory, testRun(
        failing.allocator(),
        &transport,
        &factory,
        &collector,
        .{},
        null,
    ));
    try std.testing.expectEqual(@as(usize, 0), factory.deinits);
}

test "non-2xx cannot become success from a complete parser" {
    const steps = [_]TestStep{.{ .status = 500, .body = "failed" }};
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{ .start_complete = true, .incomplete_recoveries_remaining = 1 };
    var collector: TestCollector = .{};
    try testRun(std.testing.allocator, &transport, &factory, &collector, .{
        .policy = .{ .max_attempts = 1 },
    }, null);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
    try std.testing.expectEqual(@as(?u16, 500), collector.failure_status);
    try std.testing.expectEqual(@as(usize, 0), factory.finalizes);
    try std.testing.expectEqual(@as(u16, 1), factory.incomplete_recoveries_remaining);
}

test "transport errors do not invoke incomplete parser recovery" {
    const steps = [_]TestStep{.{ .status = 0, .transport_error = error.ConnectionFailed }};
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{ .incomplete_recoveries_remaining = 1 };
    var collector: TestCollector = .{};
    try testRun(std.testing.allocator, &transport, &factory, &collector, .{
        .policy = .{ .max_attempts = 1 },
    }, null);
    try std.testing.expectEqual(@as(u16, 1), factory.incomplete_recoveries_remaining);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
}

test "failed incomplete 2xx retries without finalizing and strands usage at exhaustion" {
    const steps = [_]TestStep{
        .{ .status = 200, .data = "usage", .outcome = .failed },
        .{ .status = 200, .data = "usage", .outcome = .failed },
    };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRun(std.testing.allocator, &transport, &factory, &collector, .{
        .policy = .{ .max_attempts = 2, .base_delay_ms = 0 },
    }, null);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
    try std.testing.expectEqual(@as(?u64, 7), collector.failure_usage.?.input_tokens);
    try std.testing.expectEqual(@as(usize, 0), factory.finalizes);
}

test "401 recovery retries once without consuming attempt" {
    const steps = [_]TestStep{
        .{ .status = 401, .body = "expired" },
        .{ .status = 200, .data = "done" },
    };
    const recovery_steps = [_]RecoveryStep{.{ .decision = .retry }};
    var recovery: TestUnauthorizedRecovery = .{ .steps = &recovery_steps };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{},
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqual(@as(usize, 1), recovery.calls);
    try std.testing.expectEqualSlices(u16, &.{ 1, 1 }, factory.attempt_numbers[0..2]);
    try std.testing.expectEqual(@as(usize, 0), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
    try std.testing.expectEqual(@as(usize, 2), factory.deinits);
}

test "unauthorized recovery is used at most once and never for 403" {
    const recovery_steps = [_]RecoveryStep{.{ .decision = .retry }};
    var recovery: TestUnauthorizedRecovery = .{ .steps = &recovery_steps };
    const unauthorized_steps = [_]TestStep{
        .{ .status = 401, .body = "first" },
        .{ .status = 401, .body = "second" },
    };
    var transport: TestTransport = .{ .steps = &unauthorized_steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{ .policy = .{ .max_attempts = 1 } },
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqual(@as(usize, 1), recovery.calls);
    try std.testing.expectEqual(@as(usize, 1), recovery.unauthorized_notes);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
    try std.testing.expectEqual(@as(?u16, 401), collector.failure_status);

    const forbidden_steps = [_]TestStep{.{ .status = 403, .body = "forbidden" }};
    transport = .{ .steps = &forbidden_steps };
    factory = .{};
    collector = .{};
    recovery.calls = 0;
    recovery.unauthorized_notes = 0;
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{ .policy = .{ .max_attempts = 1 } },
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqual(@as(usize, 0), recovery.calls);
    try std.testing.expectEqual(@as(usize, 0), recovery.unauthorized_notes);
    try std.testing.expectEqual(@as(?u16, 403), collector.failure_status);
}

test "unauthorized recovery can use the original response" {
    const steps = [_]TestStep{.{ .status = 401, .body = "original" }};
    const recovery_steps = [_]RecoveryStep{.{ .decision = .use_response }};
    var recovery: TestUnauthorizedRecovery = .{ .steps = &recovery_steps };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{ .policy = .{ .max_attempts = 1 } },
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqual(@as(usize, 1), recovery.calls);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
    try std.testing.expect(std.mem.indexOf(u8, collector.failureMessage(), "original") != null);
}

test "unauthorized failure override supports message and formatted diagnostics" {
    const steps = [_]TestStep{.{ .status = 401, .body = "response diagnostic" }};
    const message_steps = [_]RecoveryStep{.{ .decision = .{ .fail = .{ .message = "refresh failed" } } }};
    var recovery: TestUnauthorizedRecovery = .{ .steps = &message_steps };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{},
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqualStrings("refresh failed", collector.failureMessage());
    try std.testing.expectEqual(@as(?u16, 401), collector.failure_status);

    const formatted_steps = [_]RecoveryStep{.{ .decision = .{ .fail = .{ .formatted = .{
        .status = 498,
        .body = "refresh rejected",
    } } } }};
    recovery = .{ .steps = &formatted_steps };
    transport.calls = 0;
    factory = .{};
    collector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{},
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expect(std.mem.indexOf(u8, collector.failureMessage(), "refresh rejected") != null);
    try std.testing.expectEqual(@as(?u16, 498), collector.failure_status);

    const invalid_status_steps = [_]RecoveryStep{.{ .decision = .{ .fail = .{ .formatted = .{
        .status = 42,
        .body = "invalid status",
    } } } }};
    recovery = .{ .steps = &invalid_status_steps };
    transport.calls = 0;
    factory = .{};
    collector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{},
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqual(@as(?u16, 401), collector.failure_status);

    const oversized = "secret" ** (ApiError.maximum_body_bytes / "secret".len + 1);
    const oversized_steps = [_]RecoveryStep{.{ .decision = .{ .fail = .{ .message = oversized } } }};
    recovery = .{ .steps = &oversized_steps };
    transport.calls = 0;
    factory = .{};
    collector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{},
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqualStrings("authentication recovery failed", collector.failureMessage());
}

test "unauthorized recovery cancellation and allocation failure clean up" {
    const steps = [_]TestStep{.{ .status = 401 }};
    inline for (.{ RecoveryStep.cancelled, RecoveryStep.out_of_memory }) |recovery_error| {
        const recovery_steps = [_]RecoveryStep{recovery_error};
        var recovery: TestUnauthorizedRecovery = .{ .steps = &recovery_steps };
        var transport: TestTransport = .{ .steps = &steps };
        var factory: TestFactory = .{};
        var collector: TestCollector = .{};
        const result = testRunWithUnauthorized(
            std.testing.allocator,
            &transport,
            &factory,
            &collector,
            .{},
            null,
            UnauthorizedRecovery.from(&recovery),
        );
        switch (recovery_error) {
            .cancelled => try std.testing.expectError(error.Cancelled, result),
            .out_of_memory => try std.testing.expectError(error.OutOfMemory, result),
            else => unreachable,
        }
        try std.testing.expectEqual(@as(usize, 1), recovery.calls);
        try std.testing.expectEqual(@as(usize, 1), factory.deinits);
    }
}

test "incomplete, unauthorized, and normal retry counters are independent" {
    const steps = [_]TestStep{
        .{ .status = 401 },
        .{ .status = 200 },
        .{ .status = 503 },
        .{ .status = 200, .data = "done" },
    };
    const recovery_steps = [_]RecoveryStep{.{ .decision = .retry }};
    var recovery: TestUnauthorizedRecovery = .{ .steps = &recovery_steps };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{ .incomplete_recoveries_remaining = 1 };
    var collector: TestCollector = .{};
    try testRunWithUnauthorized(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{ .policy = .{ .max_attempts = 2, .base_delay_ms = 0 } },
        null,
        UnauthorizedRecovery.from(&recovery),
    );
    try std.testing.expectEqualSlices(u16, &.{ 1, 1, 1, 2 }, factory.attempt_numbers[0..4]);
    try std.testing.expectEqual(@as(usize, 1), recovery.calls);
    try std.testing.expectEqual(@as(usize, 1), collector.retries);
    try std.testing.expectEqual(@as(u16, 1), collector.retry_attempt);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
}

test "retry policy performs 100 retries plus the initial attempt" {
    var steps: [maximum_attempts]TestStep = @splat(.{ .status = 503 });
    steps[maximum_attempts - 1] = .{ .status = 200, .data = "done" };
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};

    try testRun(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{ .policy = .{ .max_attempts = maximum_attempts, .base_delay_ms = 0 } },
        null,
    );
    try std.testing.expectEqual(@as(u16, 101), maximum_attempts);
    try std.testing.expectEqual(@as(usize, maximum_attempts), transport.calls);
    try std.testing.expectEqual(@as(usize, maximum_attempts), factory.creates);
    try std.testing.expectEqual(@as(usize, maximum_attempts), factory.deinits);
    try std.testing.expectEqual(@as(usize, maximum_attempts - 1), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.done);
    try std.testing.expectEqual(@as(usize, 0), collector.failures);
}

test "retry policy rejects zero and more than 101 attempts" {
    const steps = [_]TestStep{.{ .status = 200, .data = "done" }};
    inline for (.{ @as(u16, 0), maximum_attempts + 1 }) |max_attempts| {
        var transport: TestTransport = .{ .steps = &steps };
        var factory: TestFactory = .{};
        var collector: TestCollector = .{};
        try std.testing.expectError(error.InvalidRequest, testRun(
            std.testing.allocator,
            &transport,
            &factory,
            &collector,
            .{ .policy = .{ .max_attempts = max_attempts } },
            null,
        ));
        try std.testing.expectEqual(@as(usize, 0), transport.calls);
    }
}

test "one maximum attempt dispatches exactly once" {
    const steps = [_]TestStep{.{ .status = 503 }};
    var transport: TestTransport = .{ .steps = &steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};

    try testRun(
        std.testing.allocator,
        &transport,
        &factory,
        &collector,
        .{ .policy = .{ .max_attempts = 1 } },
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(@as(usize, 0), collector.retries);
    try std.testing.expectEqual(@as(usize, 1), collector.failures);
}

fn exerciseOversizedFormattedFallback(allocator: std.mem.Allocator) !void {
    const oversized = "x" ** (ApiError.maximum_body_bytes + 1);
    const message = try failureMessage(allocator, .{
        .status = 401,
        .body = oversized,
    }, 401, null);
    defer allocator.free(message);
    try std.testing.expectEqualStrings("HTTP 401", message);
}

test "oversized formatted fallback propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseOversizedFormattedFallback,
        .{},
    );
}

fn exerciseRecoveryFailureNoteAllocations(allocator: std.mem.Allocator) !void {
    const transport_steps = [_]TestStep{.{ .status = 401 }};
    const recovery_steps = [_]RecoveryStep{.{ .decision = .{ .fail = .{
        .message = "refresh rejected",
    } } }};
    var transport: TestTransport = .{ .steps = &transport_steps };
    var factory: TestFactory = .{};
    var collector: TestCollector = .{};
    var recovery: TestUnauthorizedRecovery = .{ .steps = &recovery_steps };
    testRunWithUnauthorized(
        allocator,
        &transport,
        &factory,
        &collector,
        .{},
        null,
        UnauthorizedRecovery.from(&recovery),
    ) catch |err| {
        if (recovery.calls != 0) {
            try std.testing.expectEqual(@as(usize, 1), recovery.unauthorized_notes);
        }
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), recovery.unauthorized_notes);
}

test "recovery failure always notes unauthorized after diagnostic consumption" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRecoveryFailureNoteAllocations,
        .{},
    );
}
