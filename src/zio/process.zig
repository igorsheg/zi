const builtin = @import("builtin");
const std = @import("std");
const guard_mod = @import("guard.zig");
const InterruptGuard = guard_mod.InterruptGuard;
pub const AbortSignal = @import("abort_signal.zig").AbortSignal;
const child_process = @import("child_process.zig");

pub const default_max_output_bytes: usize = 1024 * 1024;
pub const EnvPair = child_process.EnvPair;
pub const StreamKind = enum { stdout, stderr };

pub const KillScope = enum { child, process_group };
pub const Stdin = union(enum) { ignore, inherit, bytes: []const u8 };
pub const Output = enum { ignore, inherit, capture };

pub const ChunkCallback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, kind: StreamKind, bytes: []const u8) void,

    fn call(self: ChunkCallback, kind: StreamKind, bytes: []const u8) void {
        self.func(self.ctx, kind, bytes);
    }
};

pub const RunOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    stdin: Stdin = .ignore,
    stdout: Output = .capture,
    stderr: Output = .capture,
    stdout_limit: std.Io.Limit = .limited(default_max_output_bytes),
    stderr_limit: std.Io.Limit = .limited(default_max_output_bytes),
    timeout_ms: ?u64 = null,
    kill_scope: KillScope = .process_group,
    signal: AbortSignal = AbortSignal.none,
};

pub const StreamOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    stdin: Stdin = .ignore,
    stdout_limit: std.Io.Limit = .limited(default_max_output_bytes),
    stderr_limit: std.Io.Limit = .limited(default_max_output_bytes),
    timeout_ms: ?u64 = null,
    kill_scope: KillScope = .process_group,
    signal: AbortSignal = AbortSignal.none,
    on_chunk: ?ChunkCallback = null,
};

pub const Completed = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub const Partial = struct {
    stdout: []u8,
    stderr: []u8,
    message: []u8,
};

pub const RunResult = union(enum) {
    completed: Completed,
    timed_out: Partial,
    stdout_too_long: Partial,
    stderr_too_long: Partial,
    aborted: Partial,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |x| {
                allocator.free(x.stdout);
                allocator.free(x.stderr);
            },
            .timed_out, .stdout_too_long, .stderr_too_long, .aborted => |x| {
                allocator.free(x.stdout);
                allocator.free(x.stderr);
                allocator.free(x.message);
            },
        }
        self.* = undefined;
    }
};

pub const RunError = error{
    EmptyArgv,
    InvalidStdio,
    EnvironmentBuildFailed,
    SpawnFailed,
    WaitFailed,
    ReadFailed,
    OutOfMemory,
    InterruptGuardFailed,
};

pub fn commandExists(allocator: std.mem.Allocator, io: std.Io, command: []const u8) bool {
    var result = run(allocator, io, .{
        .argv = &.{ command, "--version" },
        .stdout = .ignore,
        .stderr = .ignore,
        .timeout_ms = 2000,
        .kill_scope = .child,
    }) catch return false;
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |completed| completed,
        else => return false,
    };
    return switch (completed.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: RunOptions) RunError!RunResult {
    if (options.stdout == .inherit or options.stderr == .inherit or options.stdin == .inherit) return runInheritCaptureUnsupported(allocator, io, options);
    return runStreamCapture(allocator, io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .env = options.env,
        .clear_env = options.clear_env,
        .stdin = options.stdin,
        .stdout_limit = if (options.stdout == .capture) options.stdout_limit else .limited(0),
        .stderr_limit = if (options.stderr == .capture) options.stderr_limit else .limited(0),
        .timeout_ms = options.timeout_ms,
        .kill_scope = options.kill_scope,
        .signal = options.signal,
        .on_chunk = null,
    }, options.stdout == .capture, options.stderr == .capture);
}

fn runInheritCaptureUnsupported(allocator: std.mem.Allocator, io: std.Io, options: RunOptions) RunError!RunResult {
    if (options.stdout != .inherit or options.stderr != .inherit or options.stdin == .bytes) return error.InvalidStdio;
    const term = try runInherit(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .env = options.env,
        .clear_env = options.clear_env,
        .stdin = options.stdin,
        .kill_scope = options.kill_scope,
        .signal = options.signal,
    });
    return .{ .completed = .{ .term = term, .stdout = try allocator.dupe(u8, ""), .stderr = try allocator.dupe(u8, "") } };
}

pub fn stream(allocator: std.mem.Allocator, io: std.Io, options: StreamOptions) RunError!RunResult {
    return runStreamCapture(allocator, io, options, false, false);
}

pub const InheritOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    stdin: Stdin = .inherit,
    kill_scope: KillScope = .process_group,
    signal: AbortSignal = AbortSignal.none,
};

pub fn runInherit(io: std.Io, options: InheritOptions) RunError!std.process.Child.Term {
    if (options.argv.len == 0) return error.EmptyArgv;
    if (options.stdin == .bytes) return error.InvalidStdio;
    var env_map_storage = buildEnvMap(std.heap.smp_allocator, options.env, options.clear_env) catch return error.EnvironmentBuildFailed;
    defer if (env_map_storage) |*env_map| env_map.deinit();
    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = if (env_map_storage) |*env_map| env_map else null,
        .stdin = if (options.stdin == .inherit) .inherit else .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = childPgid(options.kill_scope),
    }) catch return error.SpawnFailed;
    const child_id = child.id.?;
    var guard = InterruptGuard.start(io, .{ .signal = options.signal, .actions = killActions(options.kill_scope, child_id) }) catch return error.InterruptGuardFailed;
    defer guard.stop();
    const term = child.wait(io) catch return error.WaitFailed;
    guard.markDone();
    return term;
}

fn runStreamCapture(allocator: std.mem.Allocator, io: std.Io, options: StreamOptions, store_stdout: bool, store_stderr: bool) RunError!RunResult {
    if (options.argv.len == 0) return error.EmptyArgv;
    var env_map_storage = buildEnvMap(allocator, options.env, options.clear_env) catch return error.EnvironmentBuildFailed;
    defer if (env_map_storage) |*env_map| env_map.deinit();

    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = if (env_map_storage) |*env_map| env_map else null,
        .stdin = if (options.stdin == .bytes) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = childPgid(options.kill_scope),
    }) catch return error.SpawnFailed;
    errdefer child.kill(io);
    const child_id = child.id.?;

    var guard = InterruptGuard.start(io, .{ .signal = options.signal, .timeout_ms = options.timeout_ms, .actions = killActions(options.kill_scope, child_id) }) catch return error.InterruptGuardFailed;
    defer guard.stop();

    if (options.stdin == .bytes) {
        const bytes = options.stdin.bytes;
        child.stdin.?.writeStreamingAll(io, bytes) catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    var stdout_seen: usize = 0;
    var stderr_seen: usize = 0;

    while (multi_reader.fill(64, .none)) |_| {
        emitNew(options.on_chunk, .stdout, stdout_reader.buffered(), &stdout_seen);
        emitNew(options.on_chunk, .stderr, stderr_reader.buffered(), &stderr_seen);
        if (tooLong(stdout_reader.buffered().len, options.stdout_limit)) {
            child.kill(io);
            return partial(allocator, &multi_reader, .stdout_too_long, "stdout exceeded output limit");
        }
        if (tooLong(stderr_reader.buffered().len, options.stderr_limit)) {
            child.kill(io);
            return partial(allocator, &multi_reader, .stderr_too_long, "stderr exceeded output limit");
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.ReadFailed,
    }
    emitNew(options.on_chunk, .stdout, stdout_reader.buffered(), &stdout_seen);
    emitNew(options.on_chunk, .stderr, stderr_reader.buffered(), &stderr_seen);
    multi_reader.checkAnyError() catch return error.ReadFailed;
    const term = child.wait(io) catch return error.WaitFailed;
    guard.markDone();

    if (guard.didTimeout()) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "timed out after {d}ms", .{options.timeout_ms orelse 0}) catch "timed out";
        return partial(allocator, &multi_reader, .timed_out, msg);
    }
    if (options.signal.isAborted()) return partial(allocator, &multi_reader, .aborted, "aborted");

    const stdout = if (store_stdout) multi_reader.toOwnedSlice(0) catch return error.OutOfMemory else allocator.dupe(u8, "") catch return error.OutOfMemory;
    errdefer allocator.free(stdout);
    const stderr = if (store_stderr) multi_reader.toOwnedSlice(1) catch return error.OutOfMemory else allocator.dupe(u8, "") catch return error.OutOfMemory;
    return .{ .completed = .{ .term = term, .stdout = stdout, .stderr = stderr } };
}

fn partial(allocator: std.mem.Allocator, multi_reader: *std.Io.File.MultiReader, comptime tag: std.meta.Tag(RunResult), msg: []const u8) RunError!RunResult {
    const stdout = multi_reader.toOwnedSlice(0) catch return error.OutOfMemory;
    errdefer allocator.free(stdout);
    const stderr = multi_reader.toOwnedSlice(1) catch return error.OutOfMemory;
    errdefer allocator.free(stderr);
    const message = allocator.dupe(u8, msg) catch return error.OutOfMemory;
    const p = Partial{ .stdout = stdout, .stderr = stderr, .message = message };
    return switch (tag) {
        .timed_out => .{ .timed_out = p },
        .stdout_too_long => .{ .stdout_too_long = p },
        .stderr_too_long => .{ .stderr_too_long = p },
        .aborted => .{ .aborted = p },
        else => unreachable,
    };
}

fn emitNew(callback: ?ChunkCallback, kind: StreamKind, bytes: []const u8, seen: *usize) void {
    if (callback == null) return;
    if (bytes.len <= seen.*) return;
    callback.?.call(kind, bytes[seen.*..]);
    seen.* = bytes.len;
}

fn tooLong(len: usize, limit: std.Io.Limit) bool {
    return if (limit.toInt()) |n| len > n else false;
}

fn childPgid(scope: KillScope) ?std.process.Child.Id {
    if (scope == .process_group and builtin.os.tag != .windows and builtin.os.tag != .wasi) return 0;
    return null;
}

fn killActions(scope: KillScope, child_id: std.process.Child.Id) InterruptGuard.Actions {
    return switch (scope) {
        .child => .{ .kill_pid = child_id },
        .process_group => .{ .interrupt_process_group = child_id },
    };
}

fn buildEnvMap(allocator: std.mem.Allocator, env: []const EnvPair, clear_env: bool) !?std.process.Environ.Map {
    if (env.len == 0 and !clear_env) return null;
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    for (env) |pair| try map.put(pair.key, pair.value);
    return map;
}

const shell_argv: []const []const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/c" } else &.{ "/bin/sh", "-c" };
fn skipShellProcessTestsIfUnsupported() !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
}
fn runShell(script: []const u8, options: RunOptions) !RunResult {
    var argv = [_][]const u8{ shell_argv[0], shell_argv[1], script };
    var o = options;
    o.argv = &argv;
    return run(std.testing.allocator, std.Options.debug_io, o);
}

test "process.run captures both output streams without mixing them" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("printf out; printf err >&2", .{ .argv = &.{} });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expectEqualSlices(u8, "out", completed.stdout);
    try std.testing.expectEqualSlices(u8, "err", completed.stderr);
}

test "process.run drains large stdout and stderr concurrently" {
    try skipShellProcessTestsIfUnsupported();
    const script = "i=0; while [ $i -lt 2048 ]; do printf 'oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo'; printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' >&2; i=$((i+1)); done";
    var result = try runShell(script, .{ .argv = &.{}, .timeout_ms = 5000 });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expectEqual(@as(usize, 2048 * 64), completed.stdout.len);
    try std.testing.expectEqual(@as(usize, 2048 * 64), completed.stderr.len);
}

test "process.run writes stdin then closes the child pipe" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("cat", .{ .argv = &.{}, .stdin = .{ .bytes = "hello stdin" } });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expectEqualSlices(u8, "hello stdin", completed.stdout);
}

test "process.run timeout preserves output emitted before termination" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("printf before; sleep 5; printf after", .{ .argv = &.{}, .timeout_ms = 100 });
    defer result.deinit(std.testing.allocator);
    const timed_out = switch (result) {
        .timed_out => |x| x,
        else => return error.UnexpectedProcessCompletion,
    };
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "after") == null);
}

test "process.run reports output limit as typed partial" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("printf abcdef", .{ .argv = &.{}, .stdout_limit = .limited(3) });
    defer result.deinit(std.testing.allocator);
    const failed = switch (result) {
        .stdout_too_long => |x| x,
        else => return error.UnexpectedProcessCompletion,
    };
    try std.testing.expect(std.mem.indexOf(u8, failed.message, "stdout exceeded output limit") != null);
}

test "process.run aborts a blocked child promptly" {
    try skipShellProcessTestsIfUnsupported();
    var controller = guard_mod.AbortController{};
    const signal = controller.beginRun();
    const Aborter = struct {
        fn run(ctrl: *guard_mod.AbortController) void {
            std.Options.debug_io.sleep(.fromMilliseconds(50), .awake) catch {};
            ctrl.requestAbort();
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer thread.join();
    const start = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
    var result = try runShell("sleep 10", .{ .argv = &.{}, .signal = signal, .kill_scope = .process_group });
    defer result.deinit(std.testing.allocator);
    const elapsed = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds() - start;
    try std.testing.expect(result == .aborted);
    try std.testing.expect(elapsed < 1000);
}

test "process.run aborts a child process group promptly" {
    try skipShellProcessTestsIfUnsupported();
    var controller = guard_mod.AbortController{};
    const signal = controller.beginRun();
    const Aborter = struct {
        fn run(ctrl: *guard_mod.AbortController) void {
            std.Options.debug_io.sleep(.fromMilliseconds(50), .awake) catch {};
            ctrl.requestAbort();
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer thread.join();
    const start = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
    var result = try runShell("sleep 10 & wait", .{ .argv = &.{}, .signal = signal, .kill_scope = .process_group });
    defer result.deinit(std.testing.allocator);
    const elapsed = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds() - start;
    try std.testing.expect(result == .aborted);
    try std.testing.expect(elapsed < 1000);
}
