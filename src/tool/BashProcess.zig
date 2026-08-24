const std = @import("std");
const builtin = @import("builtin");
const ProcessSpawn = @import("../ProcessSpawn.zig");

const posix = std.posix;
const system = posix.system;
const capture_limit_bytes: usize = 16 * 1024 * 1024;
const poll_slice_ms: i32 = 10;
const dev_null_path: [:0]const u8 = "/dev/null";

/// All strings and both pointer arrays are borrowed and must remain valid until
/// `run` returns. The caller resolves the executable, argv, and environment
/// before this module forks; the child does not allocate or inspect ambient
/// process state.
pub const Invocation = struct {
    executable: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
};

/// A synchronous, allocation-free cancellation probe. It is called only by the
/// parent, roughly once per poll interval.
pub const Cancellation = struct {
    context: *const anyopaque,
    requested_fn: *const fn (*const anyopaque) bool,

    pub fn requested(self: Cancellation) bool {
        return self.requested_fn(self.context);
    }

    pub fn from(implementation: anytype) Cancellation {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Cancellation.from expects a single-item pointer");
        }
        const Adapter = struct {
            fn requested(context: *const anyopaque) bool {
                const self: *const pointer_info.pointer.child = @ptrCast(@alignCast(context));
                return self.isCancellationRequested();
            }
        };
        return .{ .context = implementation, .requested_fn = Adapter.requested };
    }
};

/// Receives borrowed raw output bytes synchronously on the parent thread. The
/// bytes are valid only for the duration of `emit`.
pub const OutputSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, []const u8) error{OutOfMemory}!void,

    pub fn emit(self: OutputSink, bytes: []const u8) error{OutOfMemory}!void {
        return self.emit_fn(self.context, bytes);
    }

    pub fn from(implementation: anytype) OutputSink {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("OutputSink.from expects a single-item pointer");
        }
        const Adapter = struct {
            fn emit(context: *anyopaque, bytes: []const u8) error{OutOfMemory}!void {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.emit(bytes);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

pub const Options = struct {
    /// Zero disables the timeout.
    timeout_ms: u64 = 0,
    termination_grace_ms: u64 = 100,
    cancellation: ?Cancellation = null,
    /// When set, retained chunks are delivered serially and `Result.output` is
    /// an empty owned slice instead of a second copy of the stream.
    output_sink: ?OutputSink = null,
    /// This testable bound may only narrow the hard 16 MiB producer cap.
    maximum_output_bytes: usize = capture_limit_bytes,
};

pub const Status = union(enum) {
    exited: u8,
    signaled: u8,
    timed_out,
    interrupted,
    output_limit,
};

/// Owns `output`; call `deinit` exactly once.
pub const Result = struct {
    output: []u8,
    status: Status,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        self.* = undefined;
    }
};

pub const RunError = error{
    OutOfMemory,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

/// Owned process lifecycle returned by `spawn`. This value is move-only. The
/// owner must close the output descriptor and reap the leader exactly once.
pub const Process = struct {
    pid: posix.pid_t,
    output_fd: posix.fd_t,
    reaped: bool = false,

    pub fn read(self: *Process, buffer: []u8) RunError!ReadResult {
        return readNonblocking(self.output_fd, buffer);
    }

    /// Observes the leader without reaping it. Keeping the zombie reserves the
    /// process-group id until the owner has stopped and joined its drainer.
    pub fn exited(self: *const Process) RunError!bool {
        return observeExit(self.pid);
    }

    pub fn terminate(self: *const Process, force: bool) void {
        signalProcessTree(self.pid, if (force) .KILL else .TERM);
    }

    pub fn killDescendants(self: *const Process) void {
        signalProcessTree(self.pid, .KILL);
    }

    pub fn closeOutput(self: *Process) void {
        closeFd(self.output_fd);
        self.output_fd = -1;
    }

    pub fn reap(self: *Process) RunError!Status {
        if (self.reaped) return error.Unexpected;
        var wait_status: u32 = 0;
        try waitBlocking(self.pid, &wait_status);
        self.reaped = true;
        return decodeStatus(wait_status);
    }
};

const StopReason = enum {
    none,
    timed_out,
    interrupted,
    output_limit,
};

/// Runs one pre-resolved Unix process in a new session. stdout and stderr share
/// one pipe, preserving kernel write order. stdin is `/dev/null`. On timeout,
/// cancellation, or producer overflow the whole session is sent TERM and then
/// KILL after the configured grace period. The leader is always reaped before
/// return, including every error path after a successful fork.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    invocation: Invocation,
    options: Options,
) RunError!Result {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
        @compileError("BashProcess supports Unix targets only");
    if (options.maximum_output_bytes > capture_limit_bytes)
        return error.Unexpected;

    const process = try spawn(invocation, io);
    defer closeFd(process.output_fd);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var produced_bytes: usize = 0;

    const started_ns = monotonicNow(io);
    const timeout_deadline = if (options.timeout_ms == 0)
        null
    else
        deadlineAfter(started_ns, options.timeout_ms);
    var grace_deadline: ?i128 = null;
    var reason: StopReason = .none;
    var wait_status: u32 = 0;
    var leader_exited = false;
    var pipe_eof = false;
    var runtime_error: ?RunError = null;

    while (!pipe_eof or !leader_exited) {
        const now_ns = monotonicNow(io);

        // Observe completion before applying a signal sampled in this turn.
        // A command that has already exited keeps its actual status.
        if (!leader_exited) {
            const exited = observeExit(process.pid) catch {
                runtime_error = error.Unexpected;
                signalProcessTree(process.pid, .KILL);
                break;
            };
            if (exited) {
                leader_exited = true;
                // WNOWAIT leaves the zombie in place, reserving both pid and
                // session id until descendants have been signaled.
                signalProcessTree(process.pid, .KILL);
            }
        }

        // Cancellation wins a timeout observed in the same polling turn.
        if (!leader_exited and reason == .none and options.cancellation != null and
            options.cancellation.?.requested())
        {
            reason = .interrupted;
            grace_deadline = beginShutdown(process.pid, now_ns, options.termination_grace_ms);
        }
        if (!leader_exited and reason == .none and timeout_deadline != null and
            now_ns >= timeout_deadline.?)
        {
            reason = .timed_out;
            grace_deadline = beginShutdown(process.pid, now_ns, options.termination_grace_ms);
        }
        if (reason != .none and grace_deadline != null and now_ns >= grace_deadline.?) {
            signalProcessTree(process.pid, .KILL);
            grace_deadline = null;
        }

        if (!pipe_eof) {
            const wait_ms = pollWaitMilliseconds(
                now_ns,
                if (reason == .none) timeout_deadline else grace_deadline,
            );
            const readable = pollReadable(process.output_fd, wait_ms) catch {
                runtime_error = error.Unexpected;
                signalProcessTree(process.pid, .KILL);
                break;
            };
            if (readable) {
                while (true) {
                    var chunk: [4096]u8 = undefined;
                    const read_result = readNonblocking(process.output_fd, &chunk) catch {
                        runtime_error = error.Unexpected;
                        signalProcessTree(process.pid, .KILL);
                        break;
                    };
                    switch (read_result) {
                        .would_block => break,
                        .eof => {
                            pipe_eof = true;
                            break;
                        },
                        .bytes => |bytes| {
                            const available = options.maximum_output_bytes - produced_bytes;
                            const retained = @min(available, bytes.len);
                            if (retained != 0) {
                                if (options.output_sink) |sink| {
                                    sink.emit(bytes[0..retained]) catch {
                                        runtime_error = error.OutOfMemory;
                                        signalProcessTree(process.pid, .KILL);
                                        break;
                                    };
                                } else {
                                    output.appendSlice(allocator, bytes[0..retained]) catch {
                                        runtime_error = error.OutOfMemory;
                                        signalProcessTree(process.pid, .KILL);
                                        break;
                                    };
                                }
                                produced_bytes += retained;
                            }
                            // Filling the bound is allowed. Only evidence of a
                            // byte beyond it makes this a producer overflow.
                            if (retained != bytes.len) {
                                if (reason == .none) reason = .output_limit;
                                signalProcessTree(process.pid, .KILL);
                                grace_deadline = null;
                            }
                        },
                    }
                    if (runtime_error != null) break;
                }
            }
        } else if (!leader_exited) {
            // No descriptor remains to poll. Keep cancellation and deadlines
            // responsive without a busy loop.
            io.sleep(.fromMilliseconds(@intCast(poll_slice_ms)), .awake) catch {
                runtime_error = error.Unexpected;
                signalProcessTree(process.pid, .KILL);
                break;
            };
        }
        if (runtime_error != null) break;
    }

    // Cleanup is deliberately uncancelable. A successful fork always has one
    // matching wait, even when reading, polling, or allocating failed.
    if (!leader_exited) signalProcessTree(process.pid, .KILL);
    waitBlocking(process.pid, &wait_status) catch {
        runtime_error = error.Unexpected;
    };
    if (runtime_error) |err| return err;

    const status: Status = switch (reason) {
        .timed_out => .timed_out,
        .interrupted => .interrupted,
        .output_limit => .output_limit,
        .none => decodeStatus(wait_status),
    };
    const owned_output = if (options.output_sink == null)
        try output.toOwnedSlice(allocator)
    else
        try allocator.alloc(u8, 0);
    return .{ .output = owned_output, .status = status };
}

pub fn spawn(invocation: Invocation, io: std.Io) RunError!Process {
    var spawn_guard = ProcessSpawn.lock(io);
    defer spawn_guard.deinit();
    var pipe_fds = try createPipe();
    errdefer {
        closeFd(pipe_fds[0]);
        closeFd(pipe_fds[1]);
    }
    const dev_null = std.Io.Dir.openFile(.cwd(), io, dev_null_path, .{}) catch
        return error.Unexpected;
    defer dev_null.close(io);

    const parent_pid = system.getpid();
    const fork_result = system.fork();
    const pid: posix.pid_t = switch (posix.errno(fork_result)) {
        .SUCCESS => @intCast(fork_result),
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    };
    if (pid == 0) {
        // Only async-signal-safe syscalls occur between fork and execve.
        closeFd(pipe_fds[0]);
        _ = system.setsid();
        childDieWithParent(parent_pid);
        childDup(dev_null.handle, posix.STDIN_FILENO);
        childDup(pipe_fds[1], posix.STDOUT_FILENO);
        childDup(pipe_fds[1], posix.STDERR_FILENO);
        if (pipe_fds[1] > posix.STDERR_FILENO) closeFd(pipe_fds[1]);
        _ = system.execve(invocation.executable, invocation.argv, invocation.envp);
        childExit(127);
    }

    closeFd(pipe_fds[1]);
    pipe_fds[1] = -1;
    setNonblocking(pipe_fds[0]) catch {
        signalProcessTree(pid, .KILL);
        var ignored_status: u32 = 0;
        waitBlocking(pid, &ignored_status) catch return error.Unexpected;
        return error.Unexpected;
    };
    return .{ .pid = pid, .output_fd = pipe_fds[0] };
}

fn createPipe() RunError![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const result = if (builtin.os.tag == .linux) linux: {
        var flags: posix.O = .{};
        flags.CLOEXEC = true;
        break :linux system.pipe2(&fds, flags);
    } else system.pipe(&fds);
    switch (posix.errno(result)) {
        .SUCCESS => {},
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => return error.Unexpected,
    }
    if (builtin.os.tag != .linux) {
        errdefer {
            closeFd(fds[0]);
            closeFd(fds[1]);
        }
        try setCloseOnExec(fds[0]);
        try setCloseOnExec(fds[1]);
    }
    return fds;
}

fn setCloseOnExec(fd: posix.fd_t) RunError!void {
    switch (posix.errno(system.fcntl(fd, posix.F.SETFD, @as(u32, posix.FD_CLOEXEC)))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn setNonblocking(fd: posix.fd_t) RunError!void {
    var flags: posix.O = .{};
    flags.NONBLOCK = true;
    switch (posix.errno(system.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(flags))))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
}

fn childDup(old_fd: posix.fd_t, new_fd: posix.fd_t) void {
    if (old_fd == new_fd) {
        while (true) switch (posix.errno(system.fcntl(old_fd, posix.F.SETFD, @as(u32, 0)))) {
            .SUCCESS => return,
            .INTR => continue,
            else => childExit(127),
        };
    }
    while (true) switch (posix.errno(system.dup2(old_fd, new_fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => childExit(127),
    };
}

fn childExit(code: c_int) noreturn {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        std.os.linux.exit(code);
    } else {
        std.c._exit(code);
    }
}

fn childDieWithParent(parent_pid: posix.pid_t) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.KILL), 0, 0, 0);
    if (linux.getppid() != parent_pid) childExit(0);
}

fn closeFd(fd: posix.fd_t) void {
    if (fd < 0) return;
    _ = system.close(fd);
}

fn signalProcessTree(pid: posix.pid_t, signal: posix.SIG) void {
    if (posix.kill(-pid, signal)) |_| return else |err| switch (err) {
        error.ProcessNotFound => posix.kill(pid, signal) catch return,
        else => {},
    }
}

fn beginShutdown(pid: posix.pid_t, now_ns: i128, grace_ms: u64) ?i128 {
    if (grace_ms == 0) {
        signalProcessTree(pid, .KILL);
        return null;
    }
    signalProcessTree(pid, .TERM);
    return deadlineAfter(now_ns, grace_ms);
}

pub const ReadResult = union(enum) {
    bytes: []const u8,
    would_block,
    eof,
};

fn readNonblocking(fd: posix.fd_t, buffer: []u8) RunError!ReadResult {
    while (true) {
        const rc = system.read(fd, buffer.ptr, buffer.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                return if (count == 0) .eof else .{ .bytes = buffer[0..count] };
            },
            .INTR => continue,
            .AGAIN => return .would_block,
            else => return error.Unexpected,
        }
    }
}

fn pollReadable(fd: posix.fd_t, timeout_ms: i32) RunError!bool {
    var poll_fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    return poll_fds[0].revents != 0;
}

fn pollWaitMilliseconds(now_ns: i128, deadline_ns: ?i128) i32 {
    const deadline = deadline_ns orelse return poll_slice_ms;
    if (deadline <= now_ns) return 0;
    const remaining_ms = @divTrunc(deadline - now_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(@min(remaining_ms, poll_slice_ms));
}

fn monotonicNow(io: std.Io) i128 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn deadlineAfter(now_ns: i128, duration_ms: u64) i128 {
    const duration_ns = @as(i128, duration_ms) * std.time.ns_per_ms;
    return std.math.add(i128, now_ns, duration_ns) catch std.math.maxInt(i128);
}

const WaitStatus = if (builtin.link_libc or builtin.os.tag != .linux) c_int else u32;

const DarwinWait = struct {
    extern "c" fn waitid(
        id_type: c_uint,
        id: posix.pid_t,
        info: *std.c.siginfo_t,
        options: c_int,
    ) c_int;
};

fn observeExit(pid: posix.pid_t) RunError!bool {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
        while (true) switch (linux.errno(linux.waitid(
            .PID,
            pid,
            &info,
            linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT,
            null,
        ))) {
            .SUCCESS => return info.fields.common.first.piduid.pid == pid,
            .INTR => continue,
            else => return error.Unexpected,
        };
    }

    var info: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
    while (true) switch (posix.errno(DarwinWait.waitid(
        1, // P_PID
        pid,
        &info,
        0x00000004 | posix.W.NOHANG | 0x00000020,
    ))) {
        .SUCCESS => return info.pid == pid,
        .INTR => continue,
        else => return error.Unexpected,
    };
}

fn waitBlocking(pid: posix.pid_t, status: *u32) RunError!void {
    var native_status: WaitStatus = 0;
    while (true) {
        const rc = system.waitpid(pid, &native_status, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                status.* = @bitCast(native_status);
                return;
            },
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn decodeStatus(status: u32) Status {
    if (posix.W.IFEXITED(status)) return .{ .exited = posix.W.EXITSTATUS(status) };
    if (posix.W.IFSIGNALED(status)) {
        return .{ .signaled = @intCast(@intFromEnum(posix.W.TERMSIG(status))) };
    }
    return .{ .signaled = 0 };
}

fn shellInvocation(command: [*:0]const u8) Invocation {
    const Holder = struct {
        var argv: [4:null]?[*:0]const u8 = .{ "/bin/sh", "-c", undefined, null };
        const envp: [1:null]?[*:0]const u8 = .{null};
    };
    Holder.argv[2] = command;
    return .{ .executable = "/bin/sh", .argv = &Holder.argv, .envp = &Holder.envp };
}

test "merged stdout stderr retain write order and stdin is dev null" {
    const allocator = std.testing.allocator;
    var result = try run(allocator, std.testing.io, shellInvocation(
        "printf out; printf err >&2; if read x; then printf bad; else printf eof; fi",
    ), .{});
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("outerreof", result.output);
    try std.testing.expectEqual(@as(Status, .{ .exited = 0 }), result.status);
}

test "new session has no controlling tty" {
    const allocator = std.testing.allocator;
    var result = try run(
        allocator,
        std.testing.io,
        shellInvocation("if test -t 0 || test -t 1 || test -t 2; then exit 9; fi"),
        .{},
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(Status, .{ .exited = 0 }), result.status);
}

test "timeout kills descendants and returns their final output" {
    const allocator = std.testing.allocator;
    var result = try run(allocator, std.testing.io, shellInvocation(
        "trap 'printf term' TERM; (trap '' TERM; while :; do :; done) & wait",
    ), .{ .timeout_ms = 30, .termination_grace_ms = 30 });
    defer result.deinit(allocator);
    try std.testing.expectEqual(.timed_out, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "term") != null);
}

const CancelAfter = struct {
    started_ns: i128,
    io: std.Io,
    after_ms: u64,

    fn isCancellationRequested(self: *const CancelAfter) bool {
        return monotonicNow(self.io) >= deadlineAfter(self.started_ns, self.after_ms);
    }
};

test "cancellation is ordinary interrupted status" {
    const allocator = std.testing.allocator;
    const cancel: CancelAfter = .{
        .started_ns = monotonicNow(std.testing.io),
        .io = std.testing.io,
        .after_ms = 20,
    };
    var result = try run(
        allocator,
        std.testing.io,
        shellInvocation("while :; do :; done"),
        .{ .cancellation = Cancellation.from(&cancel), .termination_grace_ms = 0 },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(.interrupted, result.status);
}

const CollectSink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    calls: usize = 0,

    fn emit(self: *CollectSink, bytes: []const u8) error{OutOfMemory}!void {
        self.calls += 1;
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    fn deinit(self: *CollectSink) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }
};

test "sink streams retained bytes without also returning them" {
    const allocator = std.testing.allocator;
    var sink: CollectSink = .{ .allocator = allocator };
    defer sink.deinit();
    var result = try run(
        allocator,
        std.testing.io,
        shellInvocation("printf one; printf two >&2"),
        .{ .output_sink = OutputSink.from(&sink) },
    );
    defer result.deinit(allocator);
    try std.testing.expect(sink.calls > 0);
    try std.testing.expectEqualStrings("onetwo", sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expectEqual(@as(Status, .{ .exited = 0 }), result.status);
}

test "exact producer boundary is an ordinary exit" {
    const allocator = std.testing.allocator;
    var result = try run(
        allocator,
        std.testing.io,
        shellInvocation("printf 12345678"),
        .{ .maximum_output_bytes = 8 },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("12345678", result.output);
    try std.testing.expectEqual(@as(Status, .{ .exited = 0 }), result.status);
}

const FailingSink = struct {
    calls: usize = 0,

    fn emit(self: *FailingSink, bytes: []const u8) error{OutOfMemory}!void {
        self.calls += 1;
        _ = bytes;
        return error.OutOfMemory;
    }
};

test "sink allocation failure still kills descendants and reaps" {
    var sink: FailingSink = .{};
    try std.testing.expectError(
        error.OutOfMemory,
        run(
            std.testing.allocator,
            std.testing.io,
            shellInvocation("printf x; sleep 10 & wait"),
            .{ .output_sink = OutputSink.from(&sink) },
        ),
    );
}

test "producer cap kills the process tree" {
    const allocator = std.testing.allocator;
    var result = try run(
        allocator,
        std.testing.io,
        shellInvocation("while :; do printf 12345678; done"),
        .{ .maximum_output_bytes = 64 },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 64), result.output.len);
    try std.testing.expectEqual(.output_limit, result.status);
}

test "normal leader exit cleans descendants that inherited the pipe" {
    const allocator = std.testing.allocator;
    var result = try run(
        allocator,
        std.testing.io,
        shellInvocation("sleep 10 & printf done"),
        .{ .timeout_ms = 1000 },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("done", result.output);
    try std.testing.expectEqual(@as(Status, .{ .exited = 0 }), result.status);
}

test "ordinary signal is reported" {
    const allocator = std.testing.allocator;
    var result = try run(
        allocator,
        std.testing.io,
        shellInvocation("kill -KILL $$"),
        .{},
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(Status, .{ .signaled = 9 }), result.status);
}

test "pipe endpoints are close-on-exec" {
    const fds = try createPipe();
    defer closeFd(fds[0]);
    defer closeFd(fds[1]);
    for (fds) |fd| {
        const flags = system.fcntl(fd, posix.F.GETFD, @as(u32, 0));
        try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(flags));
        try std.testing.expect((flags & posix.FD_CLOEXEC) != 0);
    }
}

test "same-fd child duplication clears close-on-exec" {
    const fds = try createPipe();
    defer closeFd(fds[0]);
    defer closeFd(fds[1]);
    childDup(fds[1], fds[1]);
    const flags = system.fcntl(fds[1], posix.F.GETFD, @as(u32, 0));
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(flags));
    try std.testing.expect((flags & posix.FD_CLOEXEC) == 0);
}
