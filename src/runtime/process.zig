const builtin = @import("builtin");
const std = @import("std");
const AbortGuard = @import("../abort_guard.zig").AbortGuard;
const AbortSignal = @import("../abort_signal.zig").AbortSignal;

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
        .stdin = if (request.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (request.process_group and builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    }) catch |err| {
        return errorFmt(allocator, "spawn failed: {s}", .{@errorName(err)});
    };
    const child_id = child.id.?;

    var abort_guard = if (request.signal) |signal|
        AbortGuard.startWithIo(io, signal, .{ .interrupt_process_group = if (request.process_group) child_id else null, .kill_pid = if (request.process_group) null else child_id })
    else
        AbortGuard.startWithIo(io, AbortSignal.none, .{});
    defer abort_guard.stop();

    var timeout_guard = TimeoutGuard.start(io, request.timeout_ms, child_id, request.process_group);
    defer timeout_guard.stop();

    const io_allocator = std.heap.smp_allocator;
    var stdout_capture = Capture.init(io_allocator, request.max_stdout_bytes, request.capture_stdout);
    defer stdout_capture.deinit();
    var stderr_capture = Capture.init(io_allocator, request.max_stderr_bytes, request.capture_stderr);
    defer stderr_capture.deinit();

    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;
    if (child.stdout) |stdout_file| {
        stdout_thread = std.Thread.spawn(.{}, Capture.readAll, .{ &stdout_capture, io, stdout_file, StreamKind.stdout, request.on_chunk }) catch null;
    }
    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, Capture.readAll, .{ &stderr_capture, io, stderr_file, StreamKind.stderr, request.on_chunk }) catch null;
    }

    if (request.stdin) |stdin_bytes| {
        if (child.stdin) |stdin_file| {
            var write_buf: [4096]u8 = undefined;
            var stdin_writer = stdin_file.writer(io, &write_buf);
            stdin_writer.interface.writeAll(stdin_bytes) catch {};
            stdin_writer.interface.flush() catch {};
            stdin_file.close(io);
            child.stdin = null;
        }
    }

    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();

    const term = child.wait(io) catch |err| {
        timeout_guard.markExited();
        return errorFmt(allocator, "wait failed: {s}", .{@errorName(err)});
    };
    timeout_guard.markExited();

    if (stdout_capture.err) |err| return captureErrorResult(allocator, "stdout", err, term, &stdout_capture, &stderr_capture);
    if (stderr_capture.err) |err| return captureErrorResult(allocator, "stderr", err, term, &stdout_capture, &stderr_capture);

    const stdout = stdout_capture.toOwnedParent(allocator) catch return errorResult(allocator, "failed to allocate stdout");
    errdefer allocator.free(stdout);
    const stderr = stderr_capture.toOwnedParent(allocator) catch return errorResult(allocator, "failed to allocate stderr");
    errdefer allocator.free(stderr);

    if (timeout_guard.did_timeout.load(.acquire)) {
        return .{ .timeout = .{
            .stdout = stdout,
            .stderr = stderr,
            .message = std.fmt.allocPrint(allocator, "timed out after {d}ms", .{request.timeout_ms orelse 0}) catch return errorResult(allocator, "timed out"),
        } };
    }

    return .{ .completed = .{ .term = term, .stdout = stdout, .stderr = stderr } };
}

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

    fn readAll(self: *Capture, io: std.Io, file: std.Io.File, kind: StreamKind, on_chunk: ?ChunkCallback) void {
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
            if (on_chunk) |callback| callback.call(kind, chunk);
            if (!self.store) continue;
            if (self.buf.items.len + n > self.max_bytes) {
                self.err = error.OutputTooLarge;
                return;
            }
            self.buf.appendSlice(self.allocator, chunk) catch {
                self.err = error.ReadFailed;
                return;
            };
        }
    }

    fn toOwnedParent(self: *Capture, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.buf.items);
    }
};

const TimeoutGuard = struct {
    io: std.Io,
    done: *std.Io.Event,
    did_timeout: *std.atomic.Value(bool),
    thread: ?std.Thread,

    fn start(io: std.Io, timeout_ms: ?u64, child_id: std.process.Child.Id, process_group: bool) TimeoutGuard {
        const ms = timeout_ms orelse return .{ .io = io, .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        const done = std.heap.page_allocator.create(std.Io.Event) catch return .{ .io = io, .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        errdefer std.heap.page_allocator.destroy(done);
        const did_timeout = std.heap.page_allocator.create(std.atomic.Value(bool)) catch return .{ .io = io, .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        done.* = .unset;
        did_timeout.* = std.atomic.Value(bool).init(false);
        const thread = std.Thread.spawn(.{}, watchdog, .{ io, ms, child_id, process_group, done, did_timeout }) catch null;
        return .{ .io = io, .done = done, .did_timeout = did_timeout, .thread = thread };
    }

    fn markExited(self: *TimeoutGuard) void {
        self.done.set(self.io);
    }

    fn stop(self: *TimeoutGuard) void {
        self.done.set(self.io);
        if (self.thread) |thread| thread.join();
        if (self.done != &noop_done) std.heap.page_allocator.destroy(self.done);
        if (self.did_timeout != &noop_timeout) std.heap.page_allocator.destroy(self.did_timeout);
        self.thread = null;
    }

    fn watchdog(io: std.Io, timeout_ms: u64, child_id: std.process.Child.Id, process_group: bool, done: *std.Io.Event, did_timeout: *std.atomic.Value(bool)) void {
        done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .boot } }) catch |err| switch (err) {
            error.Timeout => {
                did_timeout.store(true, .release);
                if (process_group) killProcessGroup(child_id, std.posix.SIG.KILL) else std.posix.kill(child_id, std.posix.SIG.KILL) catch {};
            },
            error.Canceled => {},
        };
    }

    var noop_done: std.Io.Event = .unset;
    var noop_timeout = std.atomic.Value(bool).init(false);
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
