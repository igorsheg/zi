const std = @import("std");
const cancel = @import("cancel.zig");

pub const max_argv_items: usize = 64;
pub const max_cwd_bytes: usize = 4096;
pub const max_output_bytes: usize = 1024 * 1024;
pub const max_timeout_ms: u64 = @intCast(std.math.maxInt(i64));

pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    stdout_limit: usize,
    stderr_limit: usize,
    timeout_ms: u64,
    kill_scope: KillScope = .process,
};

pub const KillScope = enum {
    // Kill only the spawned child process on cancellation/timeout.
    process,
    // Kill the spawned process group on cancellation/timeout. Required for
    // shell-backed tools where grandchildren may outlive the shell process.
    process_group,
};

pub const OutputLimitExceeded = enum {
    stdout,
    stderr,
    both,
    unknown,
};

pub const CapturedStream = struct {
    bytes: []const u8,
    total_bytes: usize,
    truncated: bool = false,
};

pub const RequestError = error{
    EmptyArgv,
    TooManyArgs,
    EmptyArg,
    EmptyCwd,
    CwdTooLong,
    ZeroStdoutLimit,
    ZeroStderrLimit,
    StdoutLimitTooLarge,
    StderrLimitTooLarge,
    ZeroTimeout,
    TimeoutTooLarge,
    UnsupportedKillScope,
};

pub fn validateRequest(request: Request) RequestError!void {
    if (request.argv.len == 0) return error.EmptyArgv;
    if (request.argv.len > max_argv_items) return error.TooManyArgs;
    for (request.argv) |arg| if (arg.len == 0) return error.EmptyArg;
    if (request.cwd) |cwd| {
        if (cwd.len == 0) return error.EmptyCwd;
        if (cwd.len > max_cwd_bytes) return error.CwdTooLong;
    }
    if (request.stdout_limit == 0) return error.ZeroStdoutLimit;
    if (request.stderr_limit == 0) return error.ZeroStderrLimit;
    if (request.stdout_limit > max_output_bytes) return error.StdoutLimitTooLarge;
    if (request.stderr_limit > max_output_bytes) return error.StderrLimitTooLarge;
    if (request.timeout_ms == 0) return error.ZeroTimeout;
    if (request.timeout_ms > max_timeout_ms) return error.TimeoutTooLarge;
}

pub fn validateRequestForCapabilities(request: Request, capabilities: Capabilities) RequestError!void {
    try validateRequest(request);
    if (request.kill_scope == .process_group and !capabilities.process_group_kill) return error.UnsupportedKillScope;
}

pub const OwnedCompletion = struct {
    allocator: std.mem.Allocator,
    status: Status,
    stdout: CapturedStream,
    stderr: CapturedStream,

    pub const Status = union(enum) {
        exited: u8,
        signaled: u32,
        stopped: u32,
        unknown: u32,
        invalid_request: []const u8,
        spawn_failed: []const u8,
        timed_out,
        cancelled,
        output_limit_exceeded: OutputLimitExceeded,
        internal: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, status: Status, stdout: CapturedStream, stderr: CapturedStream) !OwnedCompletion {
        const owned_stdout = try cloneCapturedStream(allocator, stdout);
        errdefer allocator.free(owned_stdout.bytes);
        const owned_stderr = try cloneCapturedStream(allocator, stderr);
        errdefer allocator.free(owned_stderr.bytes);
        const owned_status = try cloneStatus(allocator, status);
        errdefer freeStatus(allocator, owned_status);
        return .{ .allocator = allocator, .status = owned_status, .stdout = owned_stdout, .stderr = owned_stderr };
    }

    pub fn deinit(self: *OwnedCompletion) void {
        freeStatus(self.allocator, self.status);
        self.allocator.free(self.stdout.bytes);
        self.allocator.free(self.stderr.bytes);
        self.* = undefined;
    }
};

pub const CompletionSink = struct {
    // Synchronous consumption boundary. The callee must consume or move the
    // pointed-to completion before returning, either by deiniting it or by
    // transferring its fields into another single-owner container.
    ctx: ?*anyopaque = null,
    complete_fn: *const fn (completion: *OwnedCompletion, ctx: ?*anyopaque) void,

    pub fn complete(self: CompletionSink, completion: *OwnedCompletion) void {
        self.complete_fn(completion, self.ctx);
    }
};

pub const Contract = struct {
    max_in_flight: usize,
    completion_delivery: CompletionDelivery,
    capabilities: Capabilities,

    pub fn init(options: ContractOptions) Contract {
        if (options.max_in_flight == 0) @panic("process executor max_in_flight must be greater than zero");
        if (options.completion_delivery == .bounded_queue and options.completion_delivery.bounded_queue == 0) {
            @panic("process executor completion queue capacity must be greater than zero");
        }
        return .{
            .max_in_flight = options.max_in_flight,
            .completion_delivery = options.completion_delivery,
            .capabilities = options.capabilities,
        };
    }
};

pub const ContractOptions = struct {
    max_in_flight: usize = 1,
    completion_delivery: CompletionDelivery = .direct_owner_call,
    capabilities: Capabilities = .{},
};

pub const Capabilities = struct {
    // Backend can observe cancellation while a child is running and start kill/reap immediately.
    timely_cancellation: bool = false,
    // Backend can place child in a process group and kill that group on timeout/cancel.
    process_group_kill: bool = false,
    // Backend can independently identify which output stream crossed its byte limit.
    precise_output_limit_stream: bool = false,
};

pub const CompletionDelivery = union(enum) {
    direct_owner_call,
    bounded_queue: usize,
};

pub const ExecutionContract = struct {
    pub const exactly_one_completion_per_accepted_request = true;
    pub const cancellation_completion_is_cancelled = true;
    pub const timeout_completion_requires_child_reaped = true;
    pub const output_limits_are_hard_bounds = true;
    pub const stdout_and_stderr_must_be_drained_independently = true;
    pub const shutdown_must_observe_all_owned_children = true;
};

pub const SynchronousExecutor = struct {
    pub const contract = Contract.init(.{ .capabilities = .{} });

    // Baseline mechanism only. It proves request/result ownership and bounded
    // output, but cannot interrupt a child while std.process.run is blocked.
    // It also cannot honor process_group kill scope or identify which stream
    // crossed an output limit. A reactor-backed implementation is required for
    // timely cancellation, process-group termination, and precise pipe limits.
    pub fn run(allocator: std.mem.Allocator, io: std.Io, request: Request, token: cancel.Token, sink: CompletionSink) void {
        validateRequestForCapabilities(request, contract.capabilities) catch |err| {
            var completion = OwnedCompletion.init(allocator, .{ .invalid_request = @errorName(err) }, emptyCapturedStream(), emptyCapturedStream()) catch @panic("OOM recording process request validation failure");
            sink.complete(&completion);
            return;
        };

        if (token.isAborted()) {
            var completion = OwnedCompletion.init(allocator, .cancelled, emptyCapturedStream(), emptyCapturedStream()) catch @panic("OOM recording process cancellation");
            sink.complete(&completion);
            return;
        }

        const result = std.process.run(allocator, io, .{
            .argv = request.argv,
            .cwd = if (request.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdout_limit = .limited(request.stdout_limit),
            .stderr_limit = .limited(request.stderr_limit),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(@intCast(request.timeout_ms)), .clock = .boot } },
        }) catch |err| {
            if (token.isAborted()) {
                var completion = OwnedCompletion.init(allocator, .cancelled, emptyCapturedStream(), emptyCapturedStream()) catch @panic("OOM recording process cancellation");
                sink.complete(&completion);
                return;
            }
            const status = processRunErrorStatus(err);
            var completion = OwnedCompletion.init(allocator, status, emptyCapturedStream(), emptyCapturedStream()) catch @panic("OOM recording process failure");
            sink.complete(&completion);
            return;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const status: OwnedCompletion.Status = if (token.isAborted()) .cancelled else childTermStatus(result.term);
        var completion = OwnedCompletion.init(allocator, status, capturedStream(result.stdout), capturedStream(result.stderr)) catch @panic("OOM recording process completion");
        sink.complete(&completion);
    }
};

fn childTermStatus(term: std.process.Child.Term) OwnedCompletion.Status {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signaled = @intFromEnum(sig) },
        .stopped => |sig| .{ .stopped = @intFromEnum(sig) },
        .unknown => |code| .{ .unknown = code },
    };
}

fn capturedStream(bytes: []const u8) CapturedStream {
    return .{ .bytes = bytes, .total_bytes = bytes.len, .truncated = false };
}

fn emptyCapturedStream() CapturedStream {
    return capturedStream(&.{});
}

fn cloneCapturedStream(allocator: std.mem.Allocator, stream: CapturedStream) !CapturedStream {
    return .{
        .bytes = try allocator.dupe(u8, stream.bytes),
        .total_bytes = stream.total_bytes,
        .truncated = stream.truncated,
    };
}

fn processRunErrorStatus(err: std.process.RunError) OwnedCompletion.Status {
    return switch (err) {
        error.Timeout => .timed_out,
        error.StreamTooLong => .{ .output_limit_exceeded = .unknown },

        error.OperationUnsupported,
        error.NoDevice,
        error.InvalidWtf8,
        error.InvalidBatchScriptArg,
        error.SystemResources,
        error.AccessDenied,
        error.PermissionDenied,
        error.InvalidExe,
        error.FileSystem,
        error.IsDir,
        error.FileNotFound,
        error.NotDir,
        error.FileBusy,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ResourceLimitReached,
        error.InvalidUserId,
        error.InvalidProcessGroupId,
        error.SymLinkLoop,
        error.InvalidName,
        error.ProcessAlreadyExec,
        error.UnrecognizedVolume,
        error.NameTooLong,
        error.BadPathName,
        error.NetworkNotFound,
        => .{ .spawn_failed = @errorName(err) },

        else => .{ .internal = @errorName(err) },
    };
}

fn cloneStatus(allocator: std.mem.Allocator, status: OwnedCompletion.Status) !OwnedCompletion.Status {
    return switch (status) {
        .invalid_request => |message| .{ .invalid_request = try allocator.dupe(u8, message) },
        .spawn_failed => |message| .{ .spawn_failed = try allocator.dupe(u8, message) },
        .internal => |message| .{ .internal = try allocator.dupe(u8, message) },
        else => status,
    };
}

fn freeStatus(allocator: std.mem.Allocator, status: OwnedCompletion.Status) void {
    switch (status) {
        .invalid_request => |message| allocator.free(message),
        .spawn_failed => |message| allocator.free(message),
        .internal => |message| allocator.free(message),
        else => {},
    }
}

test "process executor validates process request bounds" {
    const too_many_args = [_][]const u8{"a"} ** (max_argv_items + 1);
    var too_long_cwd = [_]u8{'a'} ** (max_cwd_bytes + 1);

    try std.testing.expectError(error.EmptyArgv, validateRequest(.{ .argv = &.{}, .stdout_limit = 1, .stderr_limit = 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.TooManyArgs, validateRequest(.{ .argv = &too_many_args, .stdout_limit = 1, .stderr_limit = 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.EmptyArg, validateRequest(.{ .argv = &.{""}, .stdout_limit = 1, .stderr_limit = 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.EmptyCwd, validateRequest(.{ .argv = &.{"echo"}, .cwd = "", .stdout_limit = 1, .stderr_limit = 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.CwdTooLong, validateRequest(.{ .argv = &.{"echo"}, .cwd = &too_long_cwd, .stdout_limit = 1, .stderr_limit = 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.ZeroStdoutLimit, validateRequest(.{ .argv = &.{"echo"}, .stdout_limit = 0, .stderr_limit = 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.ZeroStderrLimit, validateRequest(.{ .argv = &.{"echo"}, .stdout_limit = 1, .stderr_limit = 0, .timeout_ms = 1 }));
    try std.testing.expectError(error.StdoutLimitTooLarge, validateRequest(.{ .argv = &.{"echo"}, .stdout_limit = max_output_bytes + 1, .stderr_limit = 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.StderrLimitTooLarge, validateRequest(.{ .argv = &.{"echo"}, .stdout_limit = 1, .stderr_limit = max_output_bytes + 1, .timeout_ms = 1 }));
    try std.testing.expectError(error.ZeroTimeout, validateRequest(.{ .argv = &.{"echo"}, .stdout_limit = 1, .stderr_limit = 1, .timeout_ms = 0 }));
    try std.testing.expectError(error.TimeoutTooLarge, validateRequest(.{ .argv = &.{"echo"}, .stdout_limit = 1, .stderr_limit = 1, .timeout_ms = max_timeout_ms + 1 }));
}

test "process executor rejects unsupported process group kill scope" {
    try std.testing.expectError(error.UnsupportedKillScope, validateRequestForCapabilities(.{
        .argv = &.{"echo"},
        .stdout_limit = 1,
        .stderr_limit = 1,
        .timeout_ms = 1,
        .kill_scope = .process_group,
    }, .{}));
}

test "synchronous process executor declares baseline-only capabilities" {
    try std.testing.expect(!SynchronousExecutor.contract.capabilities.timely_cancellation);
    try std.testing.expect(!SynchronousExecutor.contract.capabilities.process_group_kill);
    try std.testing.expect(!SynchronousExecutor.contract.capabilities.precise_output_limit_stream);
}

test "process completion owns output and status strings" {
    var completion = try OwnedCompletion.init(std.testing.allocator, .{ .spawn_failed = "missing" }, capturedStream("out"), capturedStream("err"));
    defer completion.deinit();

    try std.testing.expectEqualStrings("out", completion.stdout.bytes);
    try std.testing.expectEqual(@as(usize, 3), completion.stdout.total_bytes);
    try std.testing.expectEqualStrings("err", completion.stderr.bytes);
    try std.testing.expectEqualStrings("missing", completion.status.spawn_failed);
}

const TestCapture = struct {
    completion: ?OwnedCompletion = null,

    fn complete(completion: *OwnedCompletion, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.completion = completion.*;
        completion.* = undefined;
    }

    fn deinit(self: *@This()) void {
        if (self.completion) |*completion| completion.deinit();
        self.* = undefined;
    }
};

fn runTestProcess(request: Request, token: cancel.Token) TestCapture {
    var capture = TestCapture{};
    SynchronousExecutor.run(std.testing.allocator, std.testing.io, request, token, .{ .complete_fn = TestCapture.complete, .ctx = &capture });
    return capture;
}

test "synchronous process executor captures stdout" {
    var capture = runTestProcess(.{
        .argv = &.{ "/bin/sh", "-c", "printf hello" },
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .timeout_ms = 5_000,
    }, .none);
    defer capture.deinit();

    try std.testing.expectEqualStrings("hello", capture.completion.?.stdout.bytes);
    try std.testing.expectEqual(@as(usize, 5), capture.completion.?.stdout.total_bytes);
    try std.testing.expect(capture.completion.?.status == .exited);
    try std.testing.expectEqual(@as(u8, 0), capture.completion.?.status.exited);
}

test "synchronous process executor reports pre-cancelled request" {
    var source = cancel.Source{};
    const token = source.beginRun();
    source.requestAbort();
    var capture = runTestProcess(.{ .argv = &.{ "/bin/sh", "-c", "printf nope" }, .stdout_limit = 1024, .stderr_limit = 1024, .timeout_ms = 5_000 }, token);
    defer capture.deinit();

    try std.testing.expect(capture.completion.?.status == .cancelled);
}

test "synchronous process executor rejects unsupported process group kill scope" {
    var capture = runTestProcess(.{
        .argv = &.{ "/bin/sh", "-c", "printf nope" },
        .stdout_limit = 1024,
        .stderr_limit = 1024,
        .timeout_ms = 5_000,
        .kill_scope = .process_group,
    }, .none);
    defer capture.deinit();

    try std.testing.expect(capture.completion.?.status == .invalid_request);
    try std.testing.expectEqualStrings("UnsupportedKillScope", capture.completion.?.status.invalid_request);
}

test "synchronous process executor captures stderr" {
    var capture = runTestProcess(.{ .argv = &.{ "/bin/sh", "-c", "printf err >&2" }, .stdout_limit = 1024, .stderr_limit = 1024, .timeout_ms = 5_000 }, .none);
    defer capture.deinit();

    try std.testing.expectEqualStrings("err", capture.completion.?.stderr.bytes);
    try std.testing.expect(capture.completion.?.status == .exited);
}

test "synchronous process executor reports missing executable" {
    var capture = runTestProcess(.{ .argv = &.{"/definitely/missing/zi-process-test"}, .stdout_limit = 1024, .stderr_limit = 1024, .timeout_ms = 5_000 }, .none);
    defer capture.deinit();

    try std.testing.expect(capture.completion.?.status == .spawn_failed);
}

test "synchronous process executor reports output limit exceeded" {
    var capture = runTestProcess(.{ .argv = &.{ "/bin/sh", "-c", "printf too-long" }, .stdout_limit = 1, .stderr_limit = 1024, .timeout_ms = 5_000 }, .none);
    defer capture.deinit();

    try std.testing.expect(capture.completion.?.status == .output_limit_exceeded);
    try std.testing.expectEqual(OutputLimitExceeded.unknown, capture.completion.?.status.output_limit_exceeded);
}

test "synchronous process executor reports stderr output limit exceeded as unknown stream" {
    var capture = runTestProcess(.{ .argv = &.{ "/bin/sh", "-c", "printf too-long >&2" }, .stdout_limit = 1024, .stderr_limit = 1, .timeout_ms = 5_000 }, .none);
    defer capture.deinit();

    try std.testing.expect(capture.completion.?.status == .output_limit_exceeded);
    try std.testing.expectEqual(OutputLimitExceeded.unknown, capture.completion.?.status.output_limit_exceeded);
}

test "synchronous process executor reports timeout" {
    var capture = runTestProcess(.{ .argv = &.{ "/bin/sh", "-c", "sleep 1" }, .stdout_limit = 1024, .stderr_limit = 1024, .timeout_ms = 1 }, .none);
    defer capture.deinit();

    try std.testing.expect(capture.completion.?.status == .timed_out);
}
