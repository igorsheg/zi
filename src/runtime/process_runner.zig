const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const cancel = @import("cancel.zig");
const ByteBuilder = @import("byte_builder.zig").ByteBuilder;
const Runtime = zio.Runtime;

pub const RunOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
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
    output_fault: *zio.ResetEvent,
    limit_exceeded: bool = false,
    err: ?anyerror = null,

    fn deinit(self: *OutputBuffer) void {
        self.bytes.deinit();
        self.* = undefined;
    }
};

const process_wait_error = @typeInfo(@typeInfo(@TypeOf(waitForProcess)).@"fn".return_type.?)
    .error_union.error_set;
const ProcessWaitResult = process_wait_error!std.process.Child.Term;
const ProcessWaitState = enum {
    before_wait,
    active,
    drained,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    zio_runtime: *Runtime,
    options: RunOptions,
) !std.process.RunResult {
    std.debug.assert(options.argv.len > 0);
    std.debug.assert(options.timeout_ms > 0);
    std.debug.assert(options.termination_grace_ms > 0);
    std.debug.assert(options.max_stdout_bytes > 0);
    std.debug.assert(options.max_stderr_bytes > 0);

    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
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

    var output_fault: zio.ResetEvent = .init;
    var output_chunks_storage: [output_chunk_queue_capacity]OutputChunk = undefined;
    var output_chunks = zio.Channel(OutputChunk).init(&output_chunks_storage);
    defer output_chunks.close(.immediate);

    var stdout_buffer: OutputBuffer = .{
        .bytes = ByteBuilder.initBounded(allocator, options.max_stdout_bytes),
        .output_fault = &output_fault,
    };
    defer stdout_buffer.deinit();
    var stderr_buffer: OutputBuffer = .{
        .bytes = ByteBuilder.initBounded(allocator, options.max_stderr_bytes),
        .output_fault = &output_fault,
    };
    defer stderr_buffer.deinit();

    var stdout_reader = try zio_runtime.spawn(readPipeToBuffer, .{
        zio.Pipe.fromFd(stdout_file.handle),
        &stdout_buffer,
        OutputStream.stdout,
        &output_chunks,
    });
    defer stdout_reader.cancel();
    var stderr_reader = try zio_runtime.spawn(readPipeToBuffer, .{
        zio.Pipe.fromFd(stderr_file.handle),
        &stderr_buffer,
        OutputStream.stderr,
        &output_chunks,
    });
    defer stderr_reader.cancel();

    var process_wait = try zio_runtime.spawn(waitForProcess, .{ io, &child });
    process_wait_state = .active;
    defer if (process_wait_state == .active) process_wait.cancel();
    errdefer if (process_wait_state == .active) {
        terminateAndDrainProcess(
            zio_runtime,
            &child,
            &process_wait,
            options.termination_grace_ms,
            &process_wait_state,
            &stdout_reader,
            &stderr_reader,
        ) catch {
            process_wait.cancel();
            stdout_reader.cancel();
            stderr_reader.cancel();
            process_wait_state = .drained;
        };
    };
    var timeout_wait = try zio_runtime.spawn(waitForTimeout, .{options.timeout_ms});
    defer timeout_wait.cancel();

    const term = if (options.cancel_token) |cancel_token| blk: {
        var cancel_wait = try zio_runtime.spawn(waitForCancel, .{cancel_token});
        defer cancel_wait.cancel();
        while (true) {
            const output_receive = output_chunks.asyncReceive();
            switch (try zio.select(.{
                .process = &process_wait,
                .timeout = &timeout_wait,
                .cancel = &cancel_wait,
                .output_fault = &output_fault,
                .output = output_receive,
            })) {
                .process => |result| break :blk try completeProcessWait(result, &process_wait_state),
                .timeout => {
                    try terminateAndDrainProcess(
                        zio_runtime,
                        &child,
                        &process_wait,
                        options.termination_grace_ms,
                        &process_wait_state,
                        &stdout_reader,
                        &stderr_reader,
                    );
                    return error.Timeout;
                },
                .cancel => |result| {
                    result catch |err| switch (err) {
                        error.OperationCancelled => {
                            try terminateAndDrainProcess(
                                zio_runtime,
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
                    unreachable;
                },
                .output_fault => {
                    try terminateAndDrainProcess(
                        zio_runtime,
                        &child,
                        &process_wait,
                        options.termination_grace_ms,
                        &process_wait_state,
                        &stdout_reader,
                        &stderr_reader,
                    );
                    if (stdout_buffer.err) |err| return err;
                    if (stderr_buffer.err) |err| return err;
                    return error.StreamTooLong;
                },
                .output => |result| {
                    const chunk = result catch |err| switch (err) {
                        error.ChannelClosed => continue,
                    };
                    if (options.on_output) |observer| try observer.call(chunk.stream, chunk.slice());
                },
            }
        }
    } else blk: {
        while (true) {
            const output_receive = output_chunks.asyncReceive();
            switch (try zio.select(.{
                .process = &process_wait,
                .timeout = &timeout_wait,
                .output_fault = &output_fault,
                .output = output_receive,
            })) {
                .process => |result| break :blk try completeProcessWait(result, &process_wait_state),
                .timeout => {
                    try terminateAndDrainProcess(
                        zio_runtime,
                        &child,
                        &process_wait,
                        options.termination_grace_ms,
                        &process_wait_state,
                        &stdout_reader,
                        &stderr_reader,
                    );
                    return error.Timeout;
                },
                .output_fault => {
                    try terminateAndDrainProcess(
                        zio_runtime,
                        &child,
                        &process_wait,
                        options.termination_grace_ms,
                        &process_wait_state,
                        &stdout_reader,
                        &stderr_reader,
                    );
                    if (stdout_buffer.err) |err| return err;
                    if (stderr_buffer.err) |err| return err;
                    return error.StreamTooLong;
                },
                .output => |result| {
                    const chunk = result catch |err| switch (err) {
                        error.ChannelClosed => continue,
                    };
                    if (options.on_output) |observer| try observer.call(chunk.stream, chunk.slice());
                },
            }
        }
    };

    stdout_reader.join();
    stderr_reader.join();
    if (stdout_buffer.err) |err| return err;
    if (stderr_buffer.err) |err| return err;
    if (stdout_buffer.limit_exceeded or stderr_buffer.limit_exceeded) return error.StreamTooLong;

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

fn waitForTimeout(timeout_ms: u64) zio.Cancelable!void {
    try zio.sleep(.fromMilliseconds(timeout_ms));
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

fn terminateAndWaitForProcess(
    zio_runtime: *Runtime,
    child: *std.process.Child,
    process_wait: *zio.JoinHandle(ProcessWaitResult),
    termination_grace_ms: u64,
) !void {
    const process_id = child.id;
    requestChildTermination(process_id, .graceful);
    var kill_after_grace = try zio_runtime.spawn(killAfterGrace, .{ process_id, termination_grace_ms });
    defer kill_after_grace.cancel();
    _ = try process_wait.join();
}

fn terminateAndDrainProcess(
    zio_runtime: *Runtime,
    child: *std.process.Child,
    process_wait: *zio.JoinHandle(ProcessWaitResult),
    termination_grace_ms: u64,
    process_wait_state: *ProcessWaitState,
    stdout_reader: *zio.JoinHandle(void),
    stderr_reader: *zio.JoinHandle(void),
) !void {
    std.debug.assert(process_wait_state.* == .active);
    try terminateAndWaitForProcess(zio_runtime, child, process_wait, termination_grace_ms);
    process_wait_state.* = .drained;
    stdout_reader.cancel();
    stderr_reader.cancel();
}

const TerminationMode = enum {
    graceful,
    forced,
};

fn killAfterGrace(process_id: ?std.process.Child.Id, termination_grace_ms: u64) zio.Cancelable!void {
    try zio.sleep(.fromMilliseconds(termination_grace_ms));
    requestChildTermination(process_id, .forced);
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
    pipe: zio.Pipe,
    output: *OutputBuffer,
    stream: OutputStream,
    chunks: *zio.Channel(OutputChunk),
) void {
    defer pipe.close();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = pipe.read(&buffer, .none) catch |err| {
            if (err == error.BrokenPipe) return;
            output.err = err;
            output.output_fault.set();
            return;
        };
        if (count == 0) return;
        output.bytes.append(buffer[0..count]) catch |err| switch (err) {
            error.CapacityExceeded => {
                output.limit_exceeded = true;
                output.output_fault.set();
                return;
            },
            error.OutOfMemory => {
                output.err = err;
                output.output_fault.set();
                return;
            },
        };
        chunks.send(OutputChunk.init(stream, buffer[0..count])) catch return;
    }
}

test "zio process runner drains interleaved stdout and stderr" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf out-1; printf err-1 >&2; printf out-2; printf err-2 >&2",
    };

    const result = try run(std.testing.allocator, zio_runtime.io(), zio_runtime, .{
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

test "zio process runner applies stderr byte bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf 0123456789 >&2" };

    try std.testing.expectError(error.StreamTooLong, run(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 1_000,
            .max_stdout_bytes = 1024,
            .max_stderr_bytes = 4,
        },
    ));
}

test "zio process runner accepts output exactly at byte bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf 0123456789; printf abcdef >&2" };

    const result = try run(std.testing.allocator, zio_runtime.io(), zio_runtime, .{
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

test "zio process runner drains eof from quiet stream after child exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf only-stdout" };

    const result = try run(std.testing.allocator, zio_runtime.io(), zio_runtime, .{
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

test "zio process runner drains stderr when stdout is quiet" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf only-stderr >&2" };

    const result = try run(std.testing.allocator, zio_runtime.io(), zio_runtime, .{
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

test "zio process runner drains larger stdout and stderr without truncation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "i=0; while [ $i -lt 2048 ]; do printf 0123456789abcdef; printf fedcba9876543210 >&2; i=$((i + 1)); done",
    };

    const result = try run(std.testing.allocator, zio_runtime.io(), zio_runtime, .{
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

test "zio process runner kills child when stdout bound is exceeded" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "trap '' PIPE; while :; do printf 0123456789abcdef; done",
    };

    try std.testing.expectError(error.StreamTooLong, run(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 5_000,
            .max_stdout_bytes = 1024,
            .max_stderr_bytes = 1024,
        },
    ));
}

test "zio process runner reports output bound after child exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "printf 0123456789" };

    try std.testing.expectError(error.StreamTooLong, run(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 1_000,
            .max_stdout_bytes = 4,
            .max_stderr_bytes = 1024,
        },
    ));
}

test "zio process runner kills child when output allocation fails" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = std.math.maxInt(usize),
    });
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "trap '' PIPE; while :; do printf 0123456789abcdef; done",
    };

    try std.testing.expectError(error.OutOfMemory, run(
        failing_allocator.allocator(),
        zio_runtime.io(),
        zio_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 5_000,
            .max_stdout_bytes = 1024 * 1024,
            .max_stderr_bytes = 1024,
        },
    ));
}

test "zio process runner times out while stdout is flowing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "while :; do printf x; sleep 1; done",
    };

    try std.testing.expectError(error.Timeout, run(std.testing.allocator, zio_runtime.io(), zio_runtime, .{
        .argv = &argv,
        .timeout_ms = 10,
        .max_stdout_bytes = 1024,
        .max_stderr_bytes = 1024,
    }));
}

test "zio process runner escalates timeout to process group kill" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
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

    try std.testing.expectError(error.Timeout, run(std.testing.allocator, zio_runtime.io(), zio_runtime, .{
        .argv = &argv,
        .cwd = cwd,
        .timeout_ms = 10,
        .termination_grace_ms = 10,
        .max_stdout_bytes = 1024,
        .max_stderr_bytes = 1024,
    }));
    try zio_runtime.sleep(.fromMilliseconds(500));

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(zio_runtime.io(), "leaked", .{}));
}

test "zio process runner cancellation terminates child through single wait owner" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var cancel_source = try cancel.CancelSource.init(std.testing.allocator);
    defer cancel_source.deinit();
    const argv = [_][]const u8{ "/bin/sh", "-c", "while :; do printf x; sleep 1; done" };

    cancel_source.request();

    try std.testing.expectError(error.OperationCancelled, run(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
        .{
            .argv = &argv,
            .timeout_ms = 5_000,
            .max_stdout_bytes = 1024,
            .max_stderr_bytes = 1024,
            .cancel_token = cancel_source.token(),
        },
    ));
}

test "zio process runner returns spawn errors before creating result ownership" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var zio_runtime = try Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    const argv = [_][]const u8{"/definitely/not/a/zi/test/program"};

    try std.testing.expectError(error.FileNotFound, run(
        std.testing.allocator,
        zio_runtime.io(),
        zio_runtime,
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
