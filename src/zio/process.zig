const builtin = @import("builtin");
const std = @import("std");
const AbortGuard = @import("abort_guard.zig").AbortGuard;
const AbortSignal = @import("abort_signal.zig").AbortSignal;
const TaskGroup = @import("task_group.zig").TaskGroup;

pub const default_max_output_bytes: usize = 1024 * 1024;
const poll_interval_ms: u64 = 25;

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

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
        error.EnvironmentBuildFailed => return errorResult(allocator, "failed to build environment"),
    };
    defer ctx.deinit();
    return ctx.run();
}

const RunContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    request: Request,
    env_map_storage: ?std.process.Environ.Map = null,

    child: ?std.process.Child = null,
    child_id: ?std.process.Child.Id = null,
    abort_guard: ?AbortGuard = null,
    timeout_guard: ?TimeoutGuard = null,
    capture_tasks: CaptureTasks = .{},
    stdout_capture: Capture,
    stderr_capture: Capture,

    const InitError = error{ EmptyArgv, EnvironmentBuildFailed };

    fn init(allocator: std.mem.Allocator, io: std.Io, request: Request) InitError!RunContext {
        if (request.argv.len == 0) return error.EmptyArgv;

        var ctx = RunContext{
            .allocator = allocator,
            .io = io,
            .request = request,
            .stdout_capture = Capture.init(std.heap.smp_allocator, request.max_stdout_bytes, request.capture_stdout),
            .stderr_capture = Capture.init(std.heap.smp_allocator, request.max_stderr_bytes, request.capture_stderr),
        };
        errdefer ctx.deinit();

        if (request.env.len > 0 or request.clear_env) {
            ctx.env_map_storage = std.process.Environ.Map.init(allocator);
            for (request.env) |pair| {
                ctx.env_map_storage.?.put(pair.key, pair.value) catch return error.EnvironmentBuildFailed;
            }
        }
        return ctx;
    }

    fn deinit(ctx: *RunContext) void {
        if (ctx.abort_guard) |*guard| guard.stop();
        if (ctx.timeout_guard) |*guard| guard.stop();
        ctx.capture_tasks.join();
        ctx.stdout_capture.deinit();
        ctx.stderr_capture.deinit();
        if (ctx.env_map_storage) |*env_map| env_map.deinit();
    }

    fn run(ctx: *RunContext) Result {
        ctx.spawnChild() catch |err| return errorFmt(ctx.allocator, "spawn failed: {s}", .{@errorName(err)});
        ctx.startAbortGuard();
        ctx.startTimeoutGuard();
        ctx.startCaptureTasks() catch |err| {
            ctx.killChild(.KILL);
            return errorFmt(ctx.allocator, "capture setup failed: {s}", .{@errorName(err)});
        };
        ctx.writeStdin();

        ctx.pumpWhileCapturing();
        ctx.captureTasksJoin();
        if (ctx.request.on_wait) |callback| callback.call();

        const term = ctx.waitChild() catch |err| return errorFmt(ctx.allocator, "wait failed: {s}", .{@errorName(err)});
        if (ctx.timeout_guard) |*guard| guard.markExited();

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

    fn spawnChild(ctx: *RunContext) !void {
        ctx.child = try std.process.spawn(ctx.io, .{
            .argv = ctx.request.argv,
            .cwd = if (ctx.request.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (ctx.env_map_storage) |*env_map| env_map else null,
            .stdin = if (ctx.request.stdin != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (ctx.request.process_group and builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
        });
        ctx.child_id = ctx.child.?.id.?;
    }

    fn startAbortGuard(ctx: *RunContext) void {
        const child_id = ctx.child_id.?;
        ctx.abort_guard = if (ctx.request.signal) |signal|
            AbortGuard.start(ctx.io, signal, .{ .interrupt_process_group = if (ctx.request.process_group) child_id else null, .kill_pid = if (ctx.request.process_group) null else child_id })
        else
            AbortGuard.start(ctx.io, AbortSignal.none, .{});
    }

    fn startTimeoutGuard(ctx: *RunContext) void {
        ctx.timeout_guard = TimeoutGuard.start(ctx.io, ctx.request.timeout_ms, ctx.child_id.?, ctx.request.process_group);
    }

    fn startCaptureTasks(ctx: *RunContext) CaptureTasks.StartError!void {
        try ctx.capture_tasks.start(ctx.io, ctx.child.?, &ctx.stdout_capture, &ctx.stderr_capture, ctx.request.on_chunk);
    }

    fn killChild(ctx: *RunContext, sig: std.posix.SIG) void {
        const child_id = ctx.child_id orelse return;
        if (ctx.request.process_group) killProcessGroup(child_id, sig) else std.posix.kill(child_id, sig) catch {};
    }

    fn captureTasksJoin(ctx: *RunContext) void {
        ctx.capture_tasks.join();
    }

    fn writeStdin(ctx: *RunContext) void {
        const stdin_bytes = ctx.request.stdin orelse return;
        const child = if (ctx.child) |*child| child else return;
        const stdin_file = child.stdin orelse return;
        var write_buf: [4096]u8 = undefined;
        var stdin_writer = stdin_file.writer(ctx.io, &write_buf);
        stdin_writer.interface.writeAll(stdin_bytes) catch {};
        stdin_writer.interface.flush() catch {};
        stdin_file.close(ctx.io);
        child.stdin = null;
    }

    fn waitChild(ctx: *RunContext) std.process.Child.WaitError!std.process.Child.Term {
        return ctx.child.?.wait(ctx.io);
    }

    fn pumpWhileCapturing(ctx: *RunContext) void {
        while (!ctx.capture_tasks.done(&ctx.stdout_capture, &ctx.stderr_capture)) {
            if (ctx.request.on_wait) |callback| callback.call();
            ctx.io.sleep(.fromMilliseconds(poll_interval_ms), .awake) catch {};
        }
    }

    fn didTimeout(ctx: *const RunContext) bool {
        const guard = ctx.timeout_guard orelse return false;
        return guard.didTimeout();
    }
};

const CaptureTasks = struct {
    group: IoGroupCaptureTasks = .{},
    threads: ThreadCaptureTasks = .{},
    active: Active = .none,

    const Active = enum { none, group, threads };

    /// Child-pipe capture prefers the structured zio/std.Io path. It must use
    /// true concurrency: stdout and stderr have to drain simultaneously or a
    /// child can deadlock once either pipe fills. If the active backend cannot
    /// provide concurrency, fall back to dedicated blocking reader threads behind
    /// this same process primitive.
    const StartError = error{ConcurrencyUnavailable};

    fn start(
        self: *CaptureTasks,
        io: std.Io,
        child: std.process.Child,
        stdout_capture: *Capture,
        stderr_capture: *Capture,
        on_chunk: ?ChunkCallback,
    ) StartError!void {
        self.group.start(io, child, stdout_capture, stderr_capture, on_chunk) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                self.group.cancel();
                try self.threads.start(io, child, stdout_capture, stderr_capture, on_chunk);
                self.active = .threads;
                return;
            },
        };
        self.active = .group;
    }

    fn join(self: *CaptureTasks) void {
        switch (self.active) {
            .none => {},
            .group => self.group.join(),
            .threads => self.threads.join(),
        }
        self.active = .none;
    }

    fn done(_: *const CaptureTasks, stdout_capture: *const Capture, stderr_capture: *const Capture) bool {
        return stdout_capture.done.load(.acquire) and stderr_capture.done.load(.acquire);
    }
};

const IoGroupCaptureTasks = struct {
    group: TaskGroup = undefined,
    started: bool = false,

    fn start(
        self: *IoGroupCaptureTasks,
        io: std.Io,
        child: std.process.Child,
        stdout_capture: *Capture,
        stderr_capture: *Capture,
        on_chunk: ?ChunkCallback,
    ) CaptureTasks.StartError!void {
        self.group = TaskGroup.init(io);
        self.started = true;
        errdefer self.cancel();
        if (child.stdout) |stdout_file| {
            try self.group.concurrent(Capture.readAll, .{ stdout_capture, io, stdout_file, StreamKind.stdout, on_chunk });
        }
        if (child.stderr) |stderr_file| {
            try self.group.concurrent(Capture.readAll, .{ stderr_capture, io, stderr_file, StreamKind.stderr, on_chunk });
        }
    }

    fn join(self: *IoGroupCaptureTasks) void {
        if (!self.started) return;
        self.group.wait() catch {};
        self.started = false;
    }

    fn cancel(self: *IoGroupCaptureTasks) void {
        if (!self.started) return;
        self.group.cancel();
        self.started = false;
    }
};

const ThreadCaptureTasks = struct {
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,

    fn start(
        self: *ThreadCaptureTasks,
        io: std.Io,
        child: std.process.Child,
        stdout_capture: *Capture,
        stderr_capture: *Capture,
        on_chunk: ?ChunkCallback,
    ) CaptureTasks.StartError!void {
        errdefer self.join();
        if (child.stdout) |stdout_file| {
            self.stdout_thread = std.Thread.spawn(.{}, Capture.readAll, .{ stdout_capture, io, stdout_file, StreamKind.stdout, on_chunk }) catch return error.ConcurrencyUnavailable;
        }
        if (child.stderr) |stderr_file| {
            self.stderr_thread = std.Thread.spawn(.{}, Capture.readAll, .{ stderr_capture, io, stderr_file, StreamKind.stderr, on_chunk }) catch return error.ConcurrencyUnavailable;
        }
    }

    fn join(self: *ThreadCaptureTasks) void {
        if (self.stdout_thread) |thread| thread.join();
        if (self.stderr_thread) |thread| thread.join();
        self.stdout_thread = null;
        self.stderr_thread = null;
    }
};

const CaptureError = error{ OutputTooLarge, ReadFailed };

const Capture = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    err: ?CaptureError = null,
    done: std.atomic.Value(bool) = .init(false),

    store: bool,

    fn init(allocator: std.mem.Allocator, max_bytes: usize, store: bool) Capture {
        return .{ .allocator = allocator, .max_bytes = max_bytes, .store = store };
    }

    fn deinit(self: *Capture) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    fn readAllIo(self: *Capture, io: std.Io, file: std.Io.File, kind: StreamKind, on_chunk: ?ChunkCallback) void {
        defer self.done.store(true, .release);
        var local_buf: [4096]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&local_buf}) catch |err| switch (err) {
                error.EndOfStream => return,
                error.WouldBlock => {
                    io.sleep(.fromMilliseconds(1), .awake) catch {};
                    continue;
                },
                else => {
                    self.err = error.ReadFailed;
                    return;
                },
            };
            self.acceptChunk(kind, local_buf[0..n], on_chunk) catch |err| {
                self.err = err;
                return;
            };
        }
    }

    fn readAll(self: *Capture, io: std.Io, file: std.Io.File, kind: StreamKind, on_chunk: ?ChunkCallback) void {
        defer self.done.store(true, .release);
        // Fallback path: dedicated threads perform blocking OS pipe reads. This
        // stays isolated here so higher layers keep using zio.process while the
        // preferred TaskGroup/std.Io capture path matures across backends.
        var local_buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(file.handle, &local_buf) catch |err| switch (err) {
                error.WouldBlock => {
                    io.sleep(.fromMilliseconds(1), .awake) catch {};
                    continue;
                },
                else => {
                    self.err = error.ReadFailed;
                    return;
                },
            };
            if (n == 0) return;
            const chunk = local_buf[0..n];
            self.acceptChunk(kind, chunk, on_chunk) catch |err| {
                self.err = err;
                return;
            };
        }
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

const TimeoutGuard = struct {
    io: std.Io,
    state: *TimeoutState,
    thread: ?std.Thread,

    const TimeoutState = struct {
        done: std.Io.Event = .unset,
        did_timeout: std.atomic.Value(bool) = .init(false),
    };

    fn start(io: std.Io, timeout_ms: ?u64, child_id: std.process.Child.Id, process_group: bool) TimeoutGuard {
        const ms = timeout_ms orelse return .{ .io = io, .state = &noop_state, .thread = null };
        const state = std.heap.page_allocator.create(TimeoutState) catch return .{ .io = io, .state = &noop_state, .thread = null };
        state.* = .{};
        const thread = std.Thread.spawn(.{}, watchdog, .{ io, ms, child_id, process_group, state }) catch null;
        if (thread == null) {
            std.heap.page_allocator.destroy(state);
            return .{ .io = io, .state = &noop_state, .thread = null };
        }
        return .{ .io = io, .state = state, .thread = thread };
    }

    fn markExited(self: *TimeoutGuard) void {
        self.state.done.set(self.io);
    }

    fn stop(self: *TimeoutGuard) void {
        self.state.done.set(self.io);
        if (self.thread) |thread| thread.join();
        if (self.state != &noop_state) std.heap.page_allocator.destroy(self.state);
        self.state = &noop_state;
        self.thread = null;
    }

    fn didTimeout(self: *const TimeoutGuard) bool {
        return self.state.did_timeout.load(.acquire);
    }

    fn watchdog(io: std.Io, timeout_ms: u64, child_id: std.process.Child.Id, process_group: bool, state: *TimeoutState) void {
        state.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .boot } }) catch |err| switch (err) {
            error.Timeout => {
                state.did_timeout.store(true, .release);
                if (process_group) killProcessGroup(child_id, std.posix.SIG.KILL) else std.posix.kill(child_id, std.posix.SIG.KILL) catch {};
            },
            error.Canceled => {},
        };
    }

    var noop_state: TimeoutState = .{ .done = .is_set };
};

fn killProcessGroup(pgid: std.process.Child.Id, sig: std.posix.SIG) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        std.posix.kill(pgid, sig) catch {};
        return;
    }
    const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pgid));
    std.posix.kill(group_pid, sig) catch {};
}

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
        errdefer allocator.free(stdout);
        const stderr = stderr_capture.toOwnedParent(allocator) catch return errorResult(allocator, "failed to allocate stderr");
        errdefer allocator.free(stderr);
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

test "process.run captures stdout and stderr concurrently" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ shell_argv[0], shell_argv[1], "printf out; printf err >&2" };

    var result = run(allocator, std.Options.debug_io, .{ .argv = &argv });
    defer result.deinit(allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqualSlices(u8, "out", completed.stdout);
    try std.testing.expectEqualSlices(u8, "err", completed.stderr);
}

test "process.run drains large stdout and stderr concurrently" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const script =
        "i=0; " ++
        "while [ $i -lt 2048 ]; do " ++
        "printf 'oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo'; " ++
        "printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' >&2; " ++
        "i=$((i+1)); " ++
        "done";
    const argv = [_][]const u8{ shell_argv[0], shell_argv[1], script };

    var result = run(allocator, std.Options.debug_io, .{ .argv = &argv, .timeout_ms = 5000 });
    defer result.deinit(allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2048 * 64), completed.stdout.len);
    try std.testing.expectEqual(@as(usize, 2048 * 64), completed.stderr.len);
}

test "process.run writes stdin and closes the pipe" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ shell_argv[0], shell_argv[1], "cat" };

    var result = run(allocator, std.Options.debug_io, .{ .argv = &argv, .stdin = "hello stdin" });
    defer result.deinit(allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqualSlices(u8, "hello stdin", completed.stdout);
}

test "process.run timeout returns partial output" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ shell_argv[0], shell_argv[1], "printf before; sleep 5; printf after" };

    var result = run(allocator, std.Options.debug_io, .{ .argv = &argv, .timeout_ms = 100 });
    defer result.deinit(allocator);

    const timed_out = switch (result) {
        .timeout => |timeout| timeout,
        else => return error.UnexpectedResult,
    };
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "after") == null);
}
