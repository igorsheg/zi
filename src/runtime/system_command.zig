const builtin = @import("builtin");
const std = @import("std");

pub const default_max_output_bytes: usize = 1024 * 1024;
const poll_interval_ms: u64 = 25;

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
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
    text: bool = true,
};

pub const Completed = struct {
    code: ?u32 = null,
    signal: ?u32 = null,
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

    pub fn clone(self: Result, allocator: std.mem.Allocator) !Result {
        return switch (self) {
            .completed => |completed| .{ .completed = .{
                .code = completed.code,
                .signal = completed.signal,
                .stdout = try allocator.dupe(u8, completed.stdout),
                .stderr = try allocator.dupe(u8, completed.stderr),
            } },
            .timeout => |timeout| .{ .timeout = .{
                .stdout = try allocator.dupe(u8, timeout.stdout),
                .stderr = try allocator.dupe(u8, timeout.stderr),
                .message = try allocator.dupe(u8, timeout.message),
            } },
            .err => |err| .{ .err = .{
                .message = try allocator.dupe(u8, err.message),
                .stdout = try allocator.dupe(u8, err.stdout),
                .stderr = try allocator.dupe(u8, err.stderr),
            } },
        };
    }

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

pub fn run(allocator: std.mem.Allocator, io: std.Io, request: Request) Result {
    if (request.argv.len == 0) return errorResult(allocator, "empty argv");

    var env_map_storage: ?std.process.Environ.Map = null;
    defer if (env_map_storage) |*env_map| env_map.deinit();
    if (request.env.len > 0 or request.clear_env) {
        env_map_storage = if (request.clear_env)
            std.process.Environ.Map.init(allocator)
        else
            std.process.Environ.Map.init(allocator);
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
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    }) catch |err| {
        return errorFmt(allocator, "spawn failed: {s}", .{@errorName(err)});
    };
    const child_id = child.id.?;

    var timeout_guard = TimeoutGuard.start(request.timeout_ms, child_id);
    defer timeout_guard.stop();

    const io_allocator = std.heap.smp_allocator;

    var stdout_capture = Capture.init(io_allocator, request.max_stdout_bytes);
    defer stdout_capture.deinit();
    var stderr_capture = Capture.init(io_allocator, request.max_stderr_bytes);
    defer stderr_capture.deinit();

    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;
    if (child.stdout) |stdout_file| {
        stdout_thread = std.Thread.spawn(.{}, Capture.readAll, .{ &stdout_capture, stdout_file }) catch null;
    }
    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, Capture.readAll, .{ &stderr_capture, stderr_file }) catch null;
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

    const term = child.wait(io) catch |err| {
        timeout_guard.markExited();
        if (stdout_thread) |thread| thread.join();
        if (stderr_thread) |thread| thread.join();
        return errorFmt(allocator, "wait failed: {s}", .{@errorName(err)});
    };
    timeout_guard.markExited();

    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();

    if (stdout_capture.err) |err| return errorFmt(allocator, "stdout read failed: {s}", .{@errorName(err)});
    if (stderr_capture.err) |err| return errorFmt(allocator, "stderr read failed: {s}", .{@errorName(err)});

    var stdout = stdout_capture.toOwnedParent(allocator) catch return errorResult(allocator, "failed to allocate stdout");
    errdefer allocator.free(stdout);
    var stderr = stderr_capture.toOwnedParent(allocator) catch return errorResult(allocator, "failed to allocate stderr");
    errdefer allocator.free(stderr);

    if (request.text) {
        const normalized_stdout = normalizeText(allocator, stdout) catch return errorResult(allocator, "failed to normalize stdout");
        allocator.free(stdout);
        stdout = normalized_stdout;
        const normalized_stderr = normalizeText(allocator, stderr) catch return errorResult(allocator, "failed to normalize stderr");
        allocator.free(stderr);
        stderr = normalized_stderr;
    }

    if (timeout_guard.did_timeout.load(.acquire)) {
        return .{ .timeout = .{
            .stdout = stdout,
            .stderr = stderr,
            .message = std.fmt.allocPrint(allocator, "timed out after {d}ms", .{request.timeout_ms orelse 0}) catch return errorResult(allocator, "timed out"),
        } };
    }

    return .{ .completed = .{
        .code = switch (term) {
            .exited => |code| code,
            else => null,
        },
        .signal = switch (term) {
            .signal => |sig| @intFromEnum(sig),
            .stopped => |sig| @intFromEnum(sig),
            .unknown => |sig| sig,
            else => null,
        },
        .stdout = stdout,
        .stderr = stderr,
    } };
}

const CaptureError = error{ OutputTooLarge, ReadFailed };

const Capture = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    err: ?CaptureError = null,

    fn init(allocator: std.mem.Allocator, max_bytes: usize) Capture {
        return .{ .allocator = allocator, .max_bytes = max_bytes };
    }

    fn deinit(self: *Capture) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    fn readAll(self: *Capture, file: std.Io.File) void {
        var local_buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(file.handle, &local_buf) catch {
                self.err = error.ReadFailed;
                return;
            };
            if (n == 0) return;
            if (self.buf.items.len + n > self.max_bytes) {
                self.err = error.OutputTooLarge;
                return;
            }
            self.buf.appendSlice(self.allocator, local_buf[0..n]) catch {
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
    done: *std.Io.Event,
    did_timeout: *std.atomic.Value(bool),
    thread: ?std.Thread,

    fn start(timeout_ms: ?u64, process_group_id: std.process.Child.Id) TimeoutGuard {
        const ms = timeout_ms orelse return .{ .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        const done = std.heap.page_allocator.create(std.Io.Event) catch return .{ .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        errdefer std.heap.page_allocator.destroy(done);
        const did_timeout = std.heap.page_allocator.create(std.atomic.Value(bool)) catch return .{ .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        done.* = .unset;
        did_timeout.* = std.atomic.Value(bool).init(false);
        const thread = std.Thread.spawn(.{}, watchdog, .{ ms, process_group_id, done, did_timeout }) catch null;
        return .{ .done = done, .did_timeout = did_timeout, .thread = thread };
    }

    fn markExited(self: *TimeoutGuard) void {
        self.done.set(std.Options.debug_io);
    }

    fn stop(self: *TimeoutGuard) void {
        self.done.set(std.Options.debug_io);
        if (self.thread) |thread| thread.join();
        if (self.done != &noop_done) std.heap.page_allocator.destroy(self.done);
        if (self.did_timeout != &noop_timeout) std.heap.page_allocator.destroy(self.did_timeout);
        self.thread = null;
    }

    fn watchdog(timeout_ms: u64, process_group_id: std.process.Child.Id, done: *std.Io.Event, did_timeout: *std.atomic.Value(bool)) void {
        done.waitTimeout(std.Options.debug_io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(timeout_ms)), .clock = .boot } }) catch |err| switch (err) {
            error.Timeout => {
                did_timeout.store(true, .release);
                killProcessGroup(process_group_id, std.posix.SIG.KILL);
            },
            error.Canceled => {},
        };
    }

    var noop_done: std.Io.Event = .unset;
    var noop_timeout = std.atomic.Value(bool).init(false);
};

fn killProcessGroup(process_group_id: std.process.Child.Id, sig: std.posix.SIG) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        std.posix.kill(process_group_id, sig) catch {};
        return;
    }
    const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(process_group_id));
    std.posix.kill(group_pid, sig) catch {};
}

fn normalizeText(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            try out.append(allocator, '\n');
            i += 1;
        } else {
            try out.append(allocator, bytes[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn errorResult(allocator: std.mem.Allocator, msg: []const u8) Result {
    return .{ .err = .{ .message = allocator.dupe(u8, msg) catch &.{} } };
}

fn errorFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    return .{ .err = .{ .message = std.fmt.allocPrint(allocator, fmt, args) catch allocator.dupe(u8, "system command failed") catch &.{} } };
}

test "system command runs argv and captures stdout" {
    const allocator = std.testing.allocator;
    var result = run(allocator, std.Options.debug_io, .{ .argv = &.{ "/bin/sh", "-c", "printf hello" } });
    defer result.deinit(allocator);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqual(@as(?u32, 0), result.completed.code);
    try std.testing.expectEqualStrings("hello", result.completed.stdout);
    try std.testing.expectEqualStrings("", result.completed.stderr);
}

test "system command passes cwd env and stdin" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", allocator);
    defer allocator.free(cwd);

    var result = run(allocator, std.Options.debug_io, .{
        .argv = &.{ "/bin/sh", "-c", "printf \"$FOO:\"; pwd; printf ':'; cat" },
        .cwd = cwd,
        .stdin = "input",
        .env = &.{.{ .key = "FOO", .value = "bar" }},
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .completed);
    const expected = try std.fmt.allocPrint(allocator, "bar:{s}\n:input", .{cwd});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.completed.stdout);
}

test "system command reports nonzero exit as completed" {
    const allocator = std.testing.allocator;
    var result = run(allocator, std.Options.debug_io, .{ .argv = &.{ "/bin/sh", "-c", "printf nope >&2; exit 7" } });
    defer result.deinit(allocator);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqual(@as(?u32, 7), result.completed.code);
    try std.testing.expectEqualStrings("nope", result.completed.stderr);
}

test "system command reports timeout with partial output" {
    const allocator = std.testing.allocator;
    var result = run(allocator, std.Options.debug_io, .{
        .argv = &.{ "/bin/sh", "-c", "printf start; sleep 2" },
        .timeout_ms = 100,
    });
    defer result.deinit(allocator);
    try std.testing.expect(result == .timeout);
    try std.testing.expect(std.mem.indexOf(u8, result.timeout.stdout, "start") != null);
}
