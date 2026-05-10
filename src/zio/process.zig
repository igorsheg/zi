const builtin = @import("builtin");
const std = @import("std");
const child_process = @import("child_process.zig");
const guard_mod = @import("guard.zig");
const AbortGuard = guard_mod.AbortGuard;
const AbortSignal = @import("abort_signal.zig").AbortSignal;
const TimeoutGuard = guard_mod.TimeoutGuard;

pub const default_max_output_bytes: usize = 1024 * 1024;
const poll_interval_ms: u64 = 25;

pub const EnvPair = child_process.EnvPair;

pub const StreamKind = enum { stdout, stderr };

pub const ChunkCallback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, kind: StreamKind, bytes: []const u8) void,

    fn call(self: ChunkCallback, kind: StreamKind, bytes: []const u8) void {
        self.func(self.ctx, kind, bytes);
    }
};

pub const WaitCallback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,

    fn call(self: WaitCallback) void {
        self.func(self.ctx);
    }
};

pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    stdin: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    timeout_ms: ?u64 = null,
    max_stdout_bytes: usize = default_max_output_bytes,
    max_stderr_bytes: usize = default_max_output_bytes,
    capture_stdout: bool = true,
    capture_stderr: bool = true,
    process_group: bool = true,
    signal: ?AbortSignal = null,
    on_chunk: ?ChunkCallback = null,
    /// Called from the thread that invoked run() while the child is alive.
    /// Use this to drain thread-safe event queues produced by on_chunk.
    on_wait: ?WaitCallback = null,
};

pub const Completed = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

pub const TimedOut = struct {
    stdout: []const u8,
    stderr: []const u8,
    message: []const u8,
};

pub const Failed = struct {
    message: []const u8,
    stdout: []const u8 = &.{},
    stderr: []const u8 = &.{},
};

pub const Result = union(enum) {
    completed: Completed,
    timeout: TimedOut,
    err: Failed,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |completed| {
                allocator.free(completed.stdout);
                allocator.free(completed.stderr);
            },
            .timeout => |timeout| {
                allocator.free(timeout.stdout);
                allocator.free(timeout.stderr);
                allocator.free(timeout.message);
            },
            .err => |err| {
                allocator.free(err.message);
                if (err.stdout.len > 0) allocator.free(err.stdout);
                if (err.stderr.len > 0) allocator.free(err.stderr);
            },
        }
        self.* = undefined;
    }
};

pub fn commandExists(allocator: std.mem.Allocator, io: std.Io, command: []const u8) bool {
    var result = run(allocator, io, .{
        .argv = &.{ command, "--version" },
        .capture_stdout = false,
        .capture_stderr = false,
        .timeout_ms = 2000,
        .process_group = false,
    });
    defer result.deinit(allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        .timeout, .err => return false,
    };
    return switch (completed.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, request: Request) Result {
    var ctx = RunContext.init(allocator, io, request) catch |err| switch (err) {
        error.EmptyArgv => return errorResult(allocator, "empty argv"),
    };
    defer ctx.deinit();
    return ctx.run();
}

pub const TerminalRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    process_group: bool = true,
    signal: ?AbortSignal = null,
};

pub fn runTerminal(allocator: std.mem.Allocator, io: std.Io, request: TerminalRequest) Result {
    if (request.argv.len == 0) return errorResult(allocator, "empty argv");

    var env_map_storage: ?std.process.Environ.Map = null;
    defer if (env_map_storage) |*env_map| env_map.deinit();
    if (request.env.len > 0 or request.clear_env) {
        env_map_storage = std.process.Environ.Map.init(allocator);
        for (request.env) |pair| {
            env_map_storage.?.put(pair.key, pair.value) catch return errorResult(allocator, "failed to build environment");
        }
    }

    var child = std.process.spawn(io, .{
        .argv = request.argv,
        .cwd = if (request.cwd) |cwd| .{ .path = cwd } else .inherit,
        .environ_map = if (env_map_storage) |*env_map| env_map else null,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = if (request.process_group and builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    }) catch |err| return errorFmt(allocator, "spawn failed: {s}", .{@errorName(err)});

    const child_id = child.id.?;
    var abort_guard = if (request.signal) |signal|
        AbortGuard.start(io, signal, .{ .interrupt_process_group = if (request.process_group) child_id else null, .kill_pid = if (request.process_group) null else child_id })
    else
        AbortGuard.start(io, AbortSignal.none, .{});
    defer abort_guard.stop();

    const term = child.wait(io) catch |err| return errorFmt(allocator, "wait failed: {s}", .{@errorName(err)});
    const stdout = allocator.dupe(u8, "") catch return errorResult(allocator, "failed to allocate stdout");
    const stderr = allocator.dupe(u8, "") catch {
        allocator.free(stdout);
        return errorResult(allocator, "failed to allocate stderr");
    };
    return .{ .completed = .{ .term = term, .stdout = stdout, .stderr = stderr } };
}

const RunContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
    child: child_process.ChildProcess = undefined,
    abort_guard: ?AbortGuard = null,
    timeout_guard: ?TimeoutGuard = null,
    stdout_capture: Capture,
    stderr_capture: Capture,
    term: ?std.process.Child.Term = null,
    spawn_failed: bool = false,

    const InitError = error{EmptyArgv};

    fn init(allocator: std.mem.Allocator, io: std.Io, request: Request) InitError!RunContext {
        if (request.argv.len == 0) return error.EmptyArgv;

        var ctx = RunContext{
            .allocator = allocator,
            .io = io,
            .request = request,
            .stdout_capture = Capture.init(std.heap.smp_allocator, request.max_stdout_bytes, request.capture_stdout),
            .stderr_capture = Capture.init(std.heap.smp_allocator, request.max_stderr_bytes, request.capture_stderr),
        };
        ctx.child = child_process.ChildProcess.init(io, .{
            .argv = request.argv,
            .cwd = request.cwd,
            .env = request.env,
            .clear_env = request.clear_env,
            .process_group = request.process_group,
            .stdin = request.stdin != null,
            .close_stdin_before_wait = request.stdin != null,
            .stdout = true,
            .stderr = true,
        }, .{ .ptr = @ptrCast(&ctx), .submit = RunContext.submitChildEvent });
        return ctx;
    }

    fn deinit(ctx: *RunContext) void {
        if (ctx.abort_guard) |*guard| guard.stop();
        if (ctx.timeout_guard) |*guard| guard.stop();
        ctx.child.wait();
        ctx.stdout_capture.deinit();
        ctx.stderr_capture.deinit();
    }

    fn run(ctx: *RunContext) Result {
        ctx.child.sink.ptr = @ptrCast(ctx);
        ctx.child.start() catch |err| return errorFmt(ctx.allocator, "spawn failed: {s}", .{@errorName(err)});
        if (!ctx.child.waitReady(5000)) return errorResult(ctx.allocator, "spawn failed");
        ctx.startAbortGuard();
        ctx.startTimeoutGuard();
        ctx.writeStdin();

        ctx.pumpWhileRunning();
        ctx.child.wait();
        if (ctx.request.on_wait) |callback| callback.call();
        if (ctx.timeout_guard) |*guard| guard.markExited();

        if (ctx.spawn_failed) return errorResult(ctx.allocator, "spawn failed");
        const term = ctx.term orelse return errorResult(ctx.allocator, "wait failed");
        if (ctx.stdout_capture.err) |err| return captureErrorResult(ctx.allocator, "stdout", err, term, &ctx.stdout_capture, &ctx.stderr_capture);
        if (ctx.stderr_capture.err) |err| return captureErrorResult(ctx.allocator, "stderr", err, term, &ctx.stdout_capture, &ctx.stderr_capture);

        const stdout = ctx.stdout_capture.toOwnedParent(ctx.allocator) catch return errorResult(ctx.allocator, "failed to allocate stdout");
        errdefer ctx.allocator.free(stdout);
        const stderr = ctx.stderr_capture.toOwnedParent(ctx.allocator) catch return errorResult(ctx.allocator, "failed to allocate stderr");
        errdefer ctx.allocator.free(stderr);

        if (ctx.didTimeout()) {
            return .{ .timeout = .{
                .stdout = stdout,
                .stderr = stderr,
                .message = std.fmt.allocPrint(ctx.allocator, "timed out after {d}ms", .{ctx.request.timeout_ms orelse 0}) catch return errorResult(ctx.allocator, "timed out"),
            } };
        }

        return .{ .completed = .{ .term = term, .stdout = stdout, .stderr = stderr } };
    }

    fn startAbortGuard(ctx: *RunContext) void {
        const child_id = ctx.child.childId() orelse return;
        ctx.abort_guard = if (ctx.request.signal) |signal|
            AbortGuard.start(ctx.io, signal, .{ .interrupt_process_group = if (ctx.request.process_group) child_id else null, .kill_pid = if (ctx.request.process_group) null else child_id })
        else
            AbortGuard.start(ctx.io, AbortSignal.none, .{});
    }

    fn startTimeoutGuard(ctx: *RunContext) void {
        const child_id = ctx.child.childId() orelse return;
        ctx.timeout_guard = TimeoutGuard.start(ctx.io, ctx.request.timeout_ms, child_id, ctx.request.process_group);
    }

    fn writeStdin(ctx: *RunContext) void {
        const stdin_bytes = ctx.request.stdin orelse return;
        ctx.child.write(stdin_bytes) catch {};
        ctx.child.closeStdin();
    }

    fn pumpWhileRunning(ctx: *RunContext) void {
        while (!ctx.child.isExited()) {
            if (ctx.request.on_wait) |callback| callback.call();
            ctx.io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch {};
        }
    }

    fn submitChildEvent(ptr: *anyopaque, event: child_process.Event) bool {
        const ctx: *RunContext = @ptrCast(@alignCast(ptr));
        switch (event) {
            .stdout => |bytes| ctx.stdout_capture.acceptChunk(.stdout, bytes, ctx.request.on_chunk) catch |err| {
                ctx.stdout_capture.err = err;
            },
            .stderr => |bytes| ctx.stderr_capture.acceptChunk(.stderr, bytes, ctx.request.on_chunk) catch |err| {
                ctx.stderr_capture.err = err;
            },
            .spawn_failed => ctx.spawn_failed = true,
            .exit => |term| ctx.term = term,
        }
        return true;
    }

    fn didTimeout(ctx: *const RunContext) bool {
        const guard = ctx.timeout_guard orelse return false;
        return guard.didTimeout();
    }
};

const CaptureError = error{ OutputTooLarge, ReadFailed };

const Capture = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    err: ?CaptureError = null,

    store: bool,

    fn init(allocator: std.mem.Allocator, max_bytes: usize, store: bool) Capture {
        return .{ .allocator = allocator, .max_bytes = max_bytes, .store = store };
    }

    fn deinit(self: *Capture) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }


    fn acceptChunk(self: *Capture, kind: StreamKind, chunk: []const u8, on_chunk: ?ChunkCallback) CaptureError!void {
        if (on_chunk) |callback| callback.call(kind, chunk);
        if (!self.store) return;
        if (self.buf.items.len + chunk.len > self.max_bytes) return error.OutputTooLarge;
        self.buf.appendSlice(self.allocator, chunk) catch return error.ReadFailed;
    }

    fn toOwnedParent(self: *Capture, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.buf.items);
    }
};


fn captureErrorResult(
    allocator: std.mem.Allocator,
    stream: []const u8,
    err: CaptureError,
    term: std.process.Child.Term,
    stdout_capture: *Capture,
    stderr_capture: *Capture,
) Result {
    if (err == error.OutputTooLarge) {
        const stdout = stdout_capture.toOwnedParent(allocator) catch return errorResult(allocator, "failed to allocate stdout");
        const stderr = stderr_capture.toOwnedParent(allocator) catch {
            allocator.free(stdout);
            return errorResult(allocator, "failed to allocate stderr");
        };
        return .{ .completed = .{ .term = term, .stdout = stdout, .stderr = stderr } };
    }
    return errorFmt(allocator, "{s} read failed: {s}", .{ stream, @errorName(err) });
}

fn errorResult(allocator: std.mem.Allocator, message: []const u8) Result {
    return .{ .err = .{ .message = allocator.dupe(u8, message) catch &.{} } };
}

fn errorFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return errorResult(allocator, "command failed");
    return .{ .err = .{ .message = msg } };
}

const shell_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/c" }
else
    &.{ "/bin/sh", "-c" };

fn skipShellProcessTestsIfUnsupported() !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
}

fn runShell(script: []const u8, request: Request) Result {
    var argv = [_][]const u8{ shell_argv[0], shell_argv[1], script };
    var with_argv = request;
    with_argv.argv = &argv;
    return run(std.testing.allocator, std.Options.debug_io, with_argv);
}

fn expectCompleted(result: Result) !Completed {
    return switch (result) {
        .completed => |completed| completed,
        .timeout => error.UnexpectedTimeout,
        .err => error.UnexpectedProcessError,
    };
}

fn expectTimeout(result: Result) !TimedOut {
    return switch (result) {
        .timeout => |timeout| timeout,
        .completed => error.UnexpectedProcessCompletion,
        .err => error.UnexpectedProcessError,
    };
}

test "process.run captures both output streams without mixing them" {
    try skipShellProcessTestsIfUnsupported();

    var result = runShell("printf out; printf err >&2", .{ .argv = &.{} });
    defer result.deinit(std.testing.allocator);

    const completed = try expectCompleted(result);
    try std.testing.expectEqualSlices(u8, "out", completed.stdout);
    try std.testing.expectEqualSlices(u8, "err", completed.stderr);
}

test "process.run drains large stdout and stderr concurrently" {
    try skipShellProcessTestsIfUnsupported();
    const repeats = 2048;
    const chunk_len = 64;
    const script =
        "i=0; " ++
        "while [ $i -lt 2048 ]; do " ++
        "printf 'oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo'; " ++
        "printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' >&2; " ++
        "i=$((i+1)); " ++
        "done";

    var result = runShell(script, .{ .argv = &.{}, .timeout_ms = 5000 });
    defer result.deinit(std.testing.allocator);

    const completed = try expectCompleted(result);
    try std.testing.expectEqual(@as(usize, repeats * chunk_len), completed.stdout.len);
    try std.testing.expectEqual(@as(usize, repeats * chunk_len), completed.stderr.len);
}

test "process.run writes stdin then closes the child pipe" {
    try skipShellProcessTestsIfUnsupported();

    var result = runShell("cat", .{ .argv = &.{}, .stdin = "hello stdin" });
    defer result.deinit(std.testing.allocator);

    const completed = try expectCompleted(result);
    try std.testing.expectEqualSlices(u8, "hello stdin", completed.stdout);
}

test "process.run timeout preserves output emitted before termination" {
    try skipShellProcessTestsIfUnsupported();

    var result = runShell("printf before; sleep 5; printf after", .{ .argv = &.{}, .timeout_ms = 100 });
    defer result.deinit(std.testing.allocator);

    const timed_out = try expectTimeout(result);
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "after") == null);
}
