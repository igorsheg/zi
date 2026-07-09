const std = @import("std");
const builtin = @import("builtin");
const async_runtime = @import("Runtime.zig");
const cancel = @import("cancel.zig");
const WakeEvent = @import("wake_event.zig").WakeEvent;
const ByteBuilder = @import("byte_builder.zig").ByteBuilder;
const Runtime = async_runtime.Runtime;

pub const RunOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    environ: ?*const std.process.Environ.Map = null,
    timeout_ms: u64,
    termination_grace_ms: u64 = 100,
    max_stdout_bytes: usize,
    max_stderr_bytes: usize,
    cancel_token: ?cancel.CancelToken = null,
    on_output: ?OutputObserver = null,
};

pub const OutputStream = enum { stdout, stderr };

pub const OutputObserver = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, OutputStream, []const u8) anyerror!void,

    pub fn call(self: OutputObserver, stream: OutputStream, bytes: []const u8) anyerror!void {
        try self.call_fn(self.context, stream, bytes);
    }
};

const output_chunk_bytes_max = 4096;
const output_chunk_queue_capacity = 64;

const OutputChunk = struct {
    stream: OutputStream,
    bytes: [output_chunk_bytes_max]u8 = undefined,
    len: usize = 0,

    fn init(stream: OutputStream, data: []const u8) OutputChunk {
        std.debug.assert(data.len <= output_chunk_bytes_max);
        var result: OutputChunk = .{ .stream = stream, .len = data.len };
        @memcpy(result.bytes[0..data.len], data);
        return result;
    }

    fn slice(self: *const OutputChunk) []const u8 {
        return self.bytes[0..self.len];
    }
};

const OutputBuffer = struct {
    bytes: ByteBuilder,
    io: std.Io,
    wake: *WakeEvent,
    limit_exceeded: bool = false,
    err: ?anyerror = null,

    fn fault(self: *OutputBuffer) void {
        self.wake.set(self.io);
    }

    fn deinit(self: *OutputBuffer) void {
        self.bytes.deinit();
        self.* = undefined;
    }
};

const process_wait_error = @typeInfo(@typeInfo(@TypeOf(waitForProcess)).@"fn".return_type.?)
    .error_union.error_set;
const ProcessWaitResult = process_wait_error!std.process.Child.Term;
const TimeoutResult = std.Io.Cancelable!void;
const CancelWaitResult = error{ OperationCancelled, Canceled }!void;
const ProcessWaitState = enum {
    before_wait,
    active,
    drained,
};

fn ResultSlot(comptime Result: type) type {
    return struct {
        ready: std.atomic.Value(bool) = .init(false),
        result: Result = undefined,
        io: std.Io,
        wake: *WakeEvent,

        fn complete(self: *@This(), result: Result) void {
            self.result = result;
            self.ready.store(true, .release);
            self.wake.set(self.io);
        }

        fn isReady(self: *const @This()) bool {
            return self.ready.load(.acquire);
        }
    };
}

const ProcessWaitSlot = ResultSlot(ProcessWaitResult);
const TimeoutSlot = ResultSlot(TimeoutResult);
const CancelSlot = ResultSlot(CancelWaitResult);
const ReaderSlot = ResultSlot(void);
const OutputChunkQueue = std.Io.Queue(OutputChunk);

fn publishProcessWait(slot: *ProcessWaitSlot, io: std.Io, child: *std.process.Child) void {
    slot.complete(waitForProcess(io, child));
}

fn publishTimeout(slot: *TimeoutSlot, io: std.Io, timeout_ms: u64) void {
    slot.complete(waitForTimeout(io, timeout_ms));
}

fn publishCancel(slot: *CancelSlot, token: cancel.CancelToken) void {
    slot.complete(waitForCancel(token));
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    task_runtime: *Runtime,
    options: RunOptions,
) !std.process.RunResult {
    _ = task_runtime;
    std.debug.assert(options.argv.len > 0);
    std.debug.assert(options.timeout_ms > 0);
    std.debug.assert(options.termination_grace_ms > 0);
    std.debug.assert(options.max_stdout_bytes > 0);
    std.debug.assert(options.max_stderr_bytes > 0);

    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = options.environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    var process_wait_state: ProcessWaitState = .before_wait;
    errdefer if (process_wait_state == .before_wait) child.kill(io);

    const stdout_file = child.stdout orelse return error.MissingStdoutPipe;
    const stderr_file = child.stderr orelse return error.MissingStderrPipe;
    child.stdout = null;
    child.stderr = null;

    var owner_wake: WakeEvent = .init;
    var output_chunks_storage: [output_chunk_queue_capacity]OutputChunk = undefined;
    var output_chunks = OutputChunkQueue.init(&output_chunks_storage);

    var stdout_buffer: OutputBuffer = .{
        .bytes = ByteBuilder.initBounded(allocator, options.max_stdout_bytes),
        .io = io,
        .wake = &owner_wake,
    };
    defer stdout_buffer.deinit();
    var stderr_buffer: OutputBuffer = .{
        .bytes = ByteBuilder.initBounded(allocator, options.max_stderr_bytes),
        .io = io,
        .wake = &owner_wake,
    };
    defer stderr_buffer.deinit();

    var stdout_slot: ReaderSlot = .{ .io = io, .wake = &owner_wake };
    var stdout_reader = try std.Io.concurrent(io, readPipeToBuffer, .{
        &stdout_slot,
        io,
        stdout_file,
        &stdout_buffer,
        OutputStream.stdout,
        &output_chunks,
        &owner_wake,
    });
    defer stdout_reader.cancel(io);
    var stderr_slot: ReaderSlot = .{ .io = io, .wake = &owner_wake };
    var stderr_reader = try std.Io.concurrent(io, readPipeToBuffer, .{
        &stderr_slot,
        io,
        stderr_file,
        &stderr_buffer,
        OutputStream.stderr,
        &output_chunks,
        &owner_wake,
    });
    defer stderr_reader.cancel(io);

    var process_slot: ProcessWaitSlot = .{ .io = io, .wake = &owner_wake };
    var process_wait = try std.Io.concurrent(io, publishProcessWait, .{ &process_slot, io, &child });
    process_wait_state = .active;
    defer if (process_wait_state == .active) process_wait.cancel(io);
    errdefer if (process_wait_state == .active) {
        terminateAndDrainProcess(
            io,
            &child,
            &process_wait,
            options.termination_grace_ms,
            &process_wait_state,
            &stdout_reader,
            &stderr_reader,
        ) catch {
            process_wait.cancel(io);
            stdout_reader.cancel(io);
            stderr_reader.cancel(io);
            process_wait_state = .drained;
        };
    };

    var timeout_slot: TimeoutSlot = .{ .io = io, .wake = &owner_wake };
    var timeout_wait = try std.Io.concurrent(io, publishTimeout, .{ &timeout_slot, io, options.timeout_ms });
    defer timeout_wait.cancel(io);

    var cancel_slot: CancelSlot = .{ .io = io, .wake = &owner_wake };
    var cancel_wait: ?std.Io.Future(void) = if (options.cancel_token) |cancel_token|
        try std.Io.concurrent(io, publishCancel, .{ &cancel_slot, cancel_token })
    else
        null;
    defer if (cancel_wait) |*future| future.cancel(io);

    const term = while (true) {
        try drainOutputChunks(io, options.on_output, &output_chunks);

        if (process_slot.isReady()) {
            process_wait.await(io);
            const completed_term = try completeProcessWait(process_slot.result, &process_wait_state);
            try drainReadersAfterProcessExit(
                io,
                options.on_output,
                &output_chunks,
                &owner_wake,
                &stdout_slot,
                &stderr_slot,
            );
            break completed_term;
        }

        if (timeout_slot.isReady()) {
            timeout_wait.await(io);
            try terminateAndDrainProcess(
                io,
                &child,
                &process_wait,
                options.termination_grace_ms,
                &process_wait_state,
                &stdout_reader,
                &stderr_reader,
            );
            return error.Timeout;
        }

        if (options.cancel_token != null and cancel_slot.isReady()) {
            cancel_wait.?.await(io);
            cancel_slot.result catch |err| switch (err) {
                error.OperationCancelled => {
                    try terminateAndDrainProcess(
                        io,
                        &child,
                        &process_wait,
                        options.termination_grace_ms,
                        &process_wait_state,
                        &stdout_reader,
                        &stderr_reader,
                    );
                    return error.OperationCancelled;
                },
                error.Canceled => return error.Canceled,
            };
            std.debug.assert(false);
            return error.Canceled;
        }

        if (stdout_buffer.err != null or stderr_buffer.err != null or
            stdout_buffer.limit_exceeded or stderr_buffer.limit_exceeded)
        {
            try terminateAndDrainProcess(
                io,
                &child,
                &process_wait,
                options.termination_grace_ms,
                &process_wait_state,
                &stdout_reader,
                &stderr_reader,
            );
            if (stdout_buffer.limit_exceeded or stderr_buffer.limit_exceeded) return error.StreamTooLong;
            if (stdout_buffer.err) |err| return err;
            if (stderr_buffer.err) |err| return err;
            return error.StreamTooLong;
        }

        owner_wake.reset();
        try drainOutputChunks(io, options.on_output, &output_chunks);
        if (process_slot.isReady() or timeout_slot.isReady() or
            (options.cancel_token != null and cancel_slot.isReady()) or
            stdout_buffer.err != null or stderr_buffer.err != null or
            stdout_buffer.limit_exceeded or stderr_buffer.limit_exceeded)
        {
            continue;
        }
        try owner_wake.wait(io);
    };

    stdout_reader.await(io);
    stderr_reader.await(io);
    try drainOutputChunks(io, options.on_output, &output_chunks);
    if (stdout_buffer.limit_exceeded or stderr_buffer.limit_exceeded) return error.StreamTooLong;
    if (stdout_buffer.err) |err| return err;
    if (stderr_buffer.err) |err| return err;

    const stdout = try stdout_buffer.bytes.toOwnedSlice();
    errdefer allocator.free(stdout);
    const stderr = try stderr_buffer.bytes.toOwnedSlice();
    errdefer allocator.free(stderr);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .term = term,
    };
}

fn waitForProcess(io: std.Io, child: *std.process.Child) !std.process.Child.Term {
    return child.wait(io);
}

fn waitForTimeout(io: std.Io, timeout_ms: u64) std.Io.Cancelable!void {
    try io.sleep(durationFromMilliseconds(timeout_ms), .awake);
}

fn waitForCancel(token: cancel.CancelToken) error{ OperationCancelled, Canceled }!void {
    return token.wait();
}

fn completeProcessWait(
    result: ProcessWaitResult,
    process_wait_state: *ProcessWaitState,
) ProcessWaitResult {
    const completed_term = try result;
    process_wait_state.* = .drained;
    return completed_term;
}

fn emitOutputChunk(observer: ?OutputObserver, chunk: OutputChunk) !void {
    if (observer) |callback| try callback.call(chunk.stream, chunk.slice());
}

fn drainOutputChunks(io: std.Io, observer: ?OutputObserver, output_chunks: *OutputChunkQueue) !void {
    while (true) {
        var item: [1]OutputChunk = undefined;
        const count = output_chunks.get(io, &item, 0) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        if (count == 0) return;
        try emitOutputChunk(observer, item[0]);
    }
}

fn drainReadersAfterProcessExit(
    io: std.Io,
    observer: ?OutputObserver,
    output_chunks: *OutputChunkQueue,
    wake: *WakeEvent,
    stdout_slot: *const ReaderSlot,
    stderr_slot: *const ReaderSlot,
) !void {
    while (true) {
        try drainOutputChunks(io, observer, output_chunks);
        if (stdout_slot.isReady() and stderr_slot.isReady()) return;

        wake.reset();
        try drainOutputChunks(io, observer, output_chunks);
        if (stdout_slot.isReady() and stderr_slot.isReady()) return;

        try wake.wait(io);
    }
}

fn terminateAndDrainProcess(
    io: std.Io,
    child: *std.process.Child,
    process_wait: *std.Io.Future(void),
    termination_grace_ms: u64,
    process_wait_state: *ProcessWaitState,
    stdout_reader: *std.Io.Future(void),
    stderr_reader: *std.Io.Future(void),
) !void {
    std.debug.assert(process_wait_state.* == .active);
    const process_id = child.id;
    requestChildTermination(process_id, .graceful);
    var kill_after_grace = try std.Io.concurrent(io, killAfterGrace, .{ io, process_id, termination_grace_ms });
    defer _ = kill_after_grace.cancel(io) catch {};
    process_wait.await(io);
    process_wait_state.* = .drained;
    stdout_reader.cancel(io);
    stderr_reader.cancel(io);
}

const TerminationMode = enum {
    graceful,
    forced,
};

fn killAfterGrace(io: std.Io, process_id: ?std.process.Child.Id, termination_grace_ms: u64) std.Io.Cancelable!void {
    try io.sleep(durationFromMilliseconds(termination_grace_ms), .awake);
    requestChildTermination(process_id, .forced);
}

fn durationFromMilliseconds(ms: u64) std.Io.Duration {
    return .fromMilliseconds(std.math.cast(i64, ms) orelse std.math.maxInt(i64));
}

fn requestChildTermination(process_id: ?std.process.Child.Id, mode: TerminationMode) void {
    const id = process_id orelse return;
    switch (builtin.os.tag) {
        .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
        else => {
            const signal: std.posix.SIG = switch (mode) {
                .graceful => .TERM,
                .forced => .KILL,
            };
            std.debug.assert(id > 1);
            _ = std.posix.system.kill(-id, signal);
        },
    }
}

fn readPipeToBuffer(
    done: *ReaderSlot,
    io: std.Io,
    file: std.Io.File,
    output: *OutputBuffer,
    stream: OutputStream,
    chunks: *OutputChunkQueue,
    wake: *WakeEvent,
) void {
    defer done.complete({});
    var owned_file = file;
    defer owned_file.close(io);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = owned_file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => return,
            error.WouldBlock => {
                async_runtime.yield() catch return;
                continue;
            },
            else => {
                output.err = err;
                output.fault();
                return;
            },
        };
        output.bytes.append(buffer[0..count]) catch |err| switch (err) {
            error.CapacityExceeded => {
                output.limit_exceeded = true;
                output.fault();
                return;
            },
            error.OutOfMemory => {
                output.err = err;
                output.fault();
                return;
            },
        };
        chunks.putOne(io, OutputChunk.init(stream, buffer[0..count])) catch return;
        wake.set(io);
    }
}

const OutputObserverCapture = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) OutputObserverCapture {
        return .{
            .stdout = .init(allocator),
            .stderr = .init(allocator),
        };
    }

    fn deinit(self: *OutputObserverCapture) void {
        self.stdout.deinit();
        self.stderr.deinit();
        self.* = undefined;
    }
};

fn captureProcessOutput(context: ?*anyopaque, stream: OutputStream, bytes: []const u8) anyerror!void {
    const capture: *OutputObserverCapture = @ptrCast(@alignCast(context.?));
    switch (stream) {
        .stdout => try capture.stdout.writer.writeAll(bytes),
        .stderr => try capture.stderr.writer.writeAll(bytes),
    }
}

test "process runner drains interleaved stdout and stderr" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf out-1; printf err-1 >&2; printf out-2; printf err-2 >&2",
    };

    const result = try run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .timeout_ms = 1_000,
        .max_stdout_bytes = 1024,
        .max_stderr_bytes = 1024,
    });
    defer freeRunResult(std.testing.allocator, result);

    try std.testing.expectEqualStrings("out-1out-2", result.stdout);
    try std.testing.expectEqualStrings("err-1err-2", result.stderr);
    const expected_term: std.process.Child.Term = .{ .exited = 0 };
    try std.testing.expectEqual(expected_term, result.term);
}

test "process runner applies stderr byte bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf 0123456789 >&2" };

    try std.testing.expectError(error.StreamTooLong, run(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 1_000,
            .max_stdout_bytes = 1024,
            .max_stderr_bytes = 4,
        },
    ));
}

test "process runner accepts output exactly at byte bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf 0123456789; printf abcdef >&2" };

    const result = try run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .timeout_ms = 1_000,
        .max_stdout_bytes = 10,
        .max_stderr_bytes = 6,
    });
    defer freeRunResult(std.testing.allocator, result);

    try std.testing.expectEqualStrings("0123456789", result.stdout);
    try std.testing.expectEqualStrings("abcdef", result.stderr);
    const expected_term: std.process.Child.Term = .{ .exited = 0 };
    try std.testing.expectEqual(expected_term, result.term);
}

test "process runner drains eof from quiet stream after child exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf only-stdout" };

    const result = try run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .timeout_ms = 1_000,
        .max_stdout_bytes = 1024,
        .max_stderr_bytes = 1024,
    });
    defer freeRunResult(std.testing.allocator, result);

    try std.testing.expectEqualStrings("only-stdout", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    const expected_term: std.process.Child.Term = .{ .exited = 0 };
    try std.testing.expectEqual(expected_term, result.term);
}

test "process runner drains stderr when stdout is quiet" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf only-stderr >&2" };

    const result = try run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .timeout_ms = 1_000,
        .max_stdout_bytes = 1024,
        .max_stderr_bytes = 1024,
    });
    defer freeRunResult(std.testing.allocator, result);

    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("only-stderr", result.stderr);
    const expected_term: std.process.Child.Term = .{ .exited = 0 };
    try std.testing.expectEqual(expected_term, result.term);
}

test "process runner drains larger stdout and stderr without truncation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "i=0; while [ $i -lt 2048 ]; do printf 0123456789abcdef; printf fedcba9876543210 >&2; i=$((i + 1)); done",
    };

    const result = try run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .timeout_ms = 1_000,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
    });
    defer freeRunResult(std.testing.allocator, result);

    try std.testing.expectEqual(@as(usize, 2048 * 16), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 2048 * 16), result.stderr.len);
    try std.testing.expectEqualStrings("0123456789abcdef", result.stdout[0..16]);
    try std.testing.expectEqualStrings("fedcba9876543210", result.stderr[0..16]);
    const expected_term: std.process.Child.Term = .{ .exited = 0 };
    try std.testing.expectEqual(expected_term, result.term);
}

test "process runner drains queued output to observer after fast process exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var capture = OutputObserverCapture.init(std.testing.allocator);
    defer capture.deinit();

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "i=0; while [ $i -lt 512 ]; do printf 0123456789abcdef; printf fedcba9876543210 >&2; i=$((i + 1)); done",
    };

    const result = try run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .timeout_ms = 1_000,
        .max_stdout_bytes = 16 * 1024,
        .max_stderr_bytes = 16 * 1024,
        .on_output = .{ .context = &capture, .call_fn = captureProcessOutput },
    });
    defer freeRunResult(std.testing.allocator, result);

    try std.testing.expectEqualStrings(result.stdout, capture.stdout.written());
    try std.testing.expectEqualStrings(result.stderr, capture.stderr.written());
    try std.testing.expectEqual(@as(usize, 512 * 16), capture.stdout.written().len);
    try std.testing.expectEqual(@as(usize, 512 * 16), capture.stderr.written().len);
}

test "process runner kills child when stdout bound is exceeded" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "trap '' PIPE; while :; do printf 0123456789abcdef; done",
    };

    try std.testing.expectError(error.StreamTooLong, run(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 5_000,
            .max_stdout_bytes = 1024,
            .max_stderr_bytes = 1024,
        },
    ));
}

test "process runner reports output bound after child exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf 0123456789" };

    try std.testing.expectError(error.StreamTooLong, run(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 1_000,
            .max_stdout_bytes = 4,
            .max_stderr_bytes = 1024,
        },
    ));
}

test "process runner kills child when output allocation fails" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "trap '' PIPE; while :; do printf 0123456789abcdef; done",
    };

    try std.testing.expectError(error.OutOfMemory, run(
        failing_allocator.allocator(),
        task_runtime.io(),
        task_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 5_000,
            .max_stdout_bytes = 1024 * 1024,
            .max_stderr_bytes = 1024,
        },
    ));
}

test "process runner times out while stdout is flowing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "while :; do printf x; sleep 1; done",
    };

    try std.testing.expectError(error.Timeout, run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .timeout_ms = 10,
        .max_stdout_bytes = 1024,
        .max_stderr_bytes = 1024,
    }));
}

test "process runner escalates timeout to process group kill" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(cwd);
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "trap '' TERM; (trap '' TERM; sleep 0.2; printf leaked > leaked)& wait",
    };

    try std.testing.expectError(error.Timeout, run(std.testing.allocator, task_runtime.io(), task_runtime, .{
        .argv = &argv,
        .cwd = cwd,
        .timeout_ms = 10,
        .termination_grace_ms = 10,
        .max_stdout_bytes = 1024,
        .max_stderr_bytes = 1024,
    }));
    try task_runtime.sleep(.fromMilliseconds(500));

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(task_runtime.io(), "leaked", .{}));
}

test "process runner cancellation terminates child through single wait owner" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var cancel_source = try cancel.CancelSource.init(std.testing.allocator, task_runtime.io());
    defer cancel_source.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "while :; do printf x; sleep 1; done" };

    cancel_source.request();

    try std.testing.expectError(error.OperationCancelled, run(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 5_000,
            .max_stdout_bytes = 1024,
            .max_stderr_bytes = 1024,
            .cancel_token = cancel_source.token(),
        },
    ));
}

test "process runner returns spawn errors before creating result ownership" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var task_runtime = try Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    const argv = [_][]const u8{"/definitely/not/a/zi/test/program"};

    try std.testing.expectError(error.FileNotFound, run(
        std.testing.allocator,
        task_runtime.io(),
        task_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 1_000,
            .max_stdout_bytes = 1024,
            .max_stderr_bytes = 1024,
        },
    ));
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}
