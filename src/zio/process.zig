const builtin = @import("builtin");
const std = @import("std");
pub const Token = @import("cancel.zig").Token;
const cancel = @import("cancel.zig");
const cancel_waiter = @import("cancel_waiter.zig");
const process_common = @import("process_common.zig");
const process_engine = @import("process_engine.zig");
const process_env = @import("process_env.zig");
const runtime_env = @import("env");
pub const Jobs = @import("job.zig");

pub const default_max_output_bytes: usize = 1024 * 1024;
pub const EnvPair = process_engine.EnvPair;
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
    signal: Token = Token.none,
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
    signal: Token = Token.none,
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
};

pub fn commandExists(allocator: std.mem.Allocator, io: std.Io, command: []const u8) bool {
    if (builtin.os.tag == .windows) return commandExistsByProbe(allocator, io, command);
    if (command.len == 0) return false;
    if (std.mem.indexOfAny(u8, command, "/\\") != null) return executablePathExists(allocator, io, command);

    const path_value = runtime_env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(allocator, &.{ dir, command }) catch continue;
        defer allocator.free(candidate);
        if (executablePathExists(allocator, io, candidate)) return true;
    }
    return false;
}

fn commandExistsByProbe(allocator: std.mem.Allocator, io: std.Io, command: []const u8) bool {
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
    return runEngine(allocator, io, .{
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
    return runEngine(allocator, io, options, false, false);
}

pub const InheritOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    stdin: Stdin = .inherit,
    kill_scope: KillScope = .process_group,
    signal: Token = Token.none,
};

pub fn runInherit(io: std.Io, options: InheritOptions) RunError!std.process.Child.Term {
    if (options.argv.len == 0) return error.EmptyArgv;
    if (options.stdin == .bytes) return error.InvalidStdio;
    var env_map_storage = process_env.buildMap(std.heap.smp_allocator, options.env, options.clear_env) catch return error.EnvironmentBuildFailed;
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

    var abort_ctx = InheritAbortCtx{
        .child_id = child.id.?,
        .process_group = options.kill_scope == .process_group,
    };
    var abort_waiter = cancel_waiter.Waiter.start(io, options.signal, .{ .ptr = @ptrCast(&abort_ctx), .call = InheritAbortCtx.abort }) catch {
        process_common.killChild(child.id.?, options.kill_scope == .process_group, .KILL);
        _ = child.wait(io) catch null;
        return error.SpawnFailed;
    };
    defer abort_waiter.stop();

    const term = child.wait(io) catch return error.WaitFailed;
    return term;
}

const InheritAbortCtx = struct {
    child_id: std.process.Child.Id,
    process_group: bool,

    fn abort(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        process_common.killChild(self.child_id, self.process_group, .TERM);
    }
};

fn runEngine(allocator: std.mem.Allocator, io: std.Io, options: StreamOptions, store_stdout: bool, store_stderr: bool) RunError!RunResult {
    if (options.argv.len == 0) return error.EmptyArgv;
    const cwd = switch (options.cwd) {
        .inherit => null,
        .path => |path| path,
        .dir => return error.InvalidStdio,
    };

    var capture = Capture.init(allocator, io, .{
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
        .store_stdout = store_stdout,
        .store_stderr = store_stderr,
        .on_chunk = options.on_chunk,
    });
    defer capture.deinit();

    var engine = process_engine.Engine.init(io, .{
        .argv = options.argv,
        .cwd = cwd,
        .env = options.env,
        .clear_env = options.clear_env,
        .process_group = options.kill_scope == .process_group,
        .stdin = options.stdin == .bytes,
        .stdout = true,
        .stderr = true,
        .close_stdin_before_wait = options.stdin == .bytes,
        .timeout_ms = options.timeout_ms,
        .signal = options.signal,
    }, .{ .ptr = @ptrCast(&capture), .submit = Capture.submit });
    capture.engine = &engine;

    engine.start() catch return error.SpawnFailed;
    if (options.stdin == .bytes) {
        if (!engine.waitReady(5000)) {
            engine.join();
            return error.SpawnFailed;
        }
        engine.write(options.stdin.bytes) catch {};
        engine.closeStdin();
    }

    engine.join();

    const outcome = capture.outcome();
    if (engine.didTimeout()) return capture.finishPartial(.timed_out, "timed out");
    if (engine.didAbort() or options.signal.isAborted()) return capture.finishPartial(.aborted, "aborted");
    if (outcome == .stdout_too_long) return capture.finishPartial(.stdout_too_long, "stdout exceeded output limit");
    if (outcome == .stderr_too_long) return capture.finishPartial(.stderr_too_long, "stderr exceeded output limit");
    if (outcome == .spawn_failed) return error.SpawnFailed;

    const term = capture.term orelse return error.WaitFailed;
    const stdout = try capture.takeStdout(store_stdout);
    errdefer allocator.free(stdout);
    const stderr = try capture.takeStderr(store_stderr);
    return .{ .completed = .{ .term = term, .stdout = stdout, .stderr = stderr } };
}

const CaptureOutcome = enum { none, spawn_failed, stdout_too_long, stderr_too_long };

const Capture = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_limit: std.Io.Limit,
    stderr_limit: std.Io.Limit,
    store_stdout: bool,
    store_stderr: bool,
    on_chunk: ?ChunkCallback,
    engine: ?*process_engine.Engine = null,
    term: ?std.process.Child.Term = null,
    failure: CaptureOutcome = .none,

    const Config = struct {
        stdout_limit: std.Io.Limit,
        stderr_limit: std.Io.Limit,
        store_stdout: bool,
        store_stderr: bool,
        on_chunk: ?ChunkCallback,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Capture {
        return .{
            .allocator = allocator,
            .io = io,
            .stdout_limit = config.stdout_limit,
            .stderr_limit = config.stderr_limit,
            .store_stdout = config.store_stdout,
            .store_stderr = config.store_stderr,
            .on_chunk = config.on_chunk,
        };
    }

    fn deinit(self: *Capture) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
    }

    fn submit(ptr: *anyopaque, event: process_engine.Event) bool {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (event) {
            .stdout => |bytes| self.append(.stdout, bytes),
            .stderr => |bytes| self.append(.stderr, bytes),
            .exit => |term| self.term = term,
            .spawn_failed => self.failure = .spawn_failed,
        }
        return true;
    }

    fn append(self: *Capture, kind: StreamKind, bytes: []const u8) void {
        if (self.on_chunk) |cb| cb.call(kind, bytes);
        if (kind == .stdout and !self.store_stdout and self.on_chunk == null) return;
        if (kind == .stderr and !self.store_stderr and self.on_chunk == null) return;
        const list = switch (kind) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        list.appendSlice(self.allocator, bytes) catch return;
        if (kind == .stdout and tooLong(list.items.len, self.stdout_limit)) {
            self.failure = .stdout_too_long;
            if (self.engine) |engine| engine.stop();
        }
        if (kind == .stderr and tooLong(list.items.len, self.stderr_limit)) {
            self.failure = .stderr_too_long;
            if (self.engine) |engine| engine.stop();
        }
    }

    fn outcome(self: *Capture) CaptureOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure;
    }

    fn takeStdout(self: *Capture, store: bool) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!store) return self.allocator.dupe(u8, "");
        const out = try self.stdout.toOwnedSlice(self.allocator);
        self.stdout = .empty;
        return out;
    }

    fn takeStderr(self: *Capture, store: bool) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!store) return self.allocator.dupe(u8, "");
        const out = try self.stderr.toOwnedSlice(self.allocator);
        self.stderr = .empty;
        return out;
    }

    fn finishPartial(self: *Capture, comptime tag: std.meta.Tag(RunResult), msg: []const u8) RunError!RunResult {
        const stdout = try self.takeStdout(true);
        errdefer self.allocator.free(stdout);
        const stderr = try self.takeStderr(true);
        errdefer self.allocator.free(stderr);
        const message = self.allocator.dupe(u8, msg) catch return error.OutOfMemory;
        const p = Partial{ .stdout = stdout, .stderr = stderr, .message = message };
        return switch (tag) {
            .timed_out => .{ .timed_out = p },
            .stdout_too_long => .{ .stdout_too_long = p },
            .stderr_too_long => .{ .stderr_too_long = p },
            .aborted => .{ .aborted = p },
            else => unreachable,
        };
    }
};

fn tooLong(len: usize, limit: std.Io.Limit) bool {
    return if (limit.toInt()) |n| len > n else false;
}

fn executablePathExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false }) catch return false;
        file.close(io);
    } else {
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch return false;
        file.close(io);
    }

    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);
    return std.c.access(path_z.ptr, std.c.X_OK) == 0;
}

fn childPgid(scope: KillScope) ?std.process.Child.Id {
    if (scope == .process_group and builtin.os.tag != .windows and builtin.os.tag != .wasi) return 0;
    return null;
}

fn skipShellProcessTestsIfUnsupported() !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
}
fn runShell(script: []const u8, options: RunOptions) !RunResult {
    var argv = [_][]const u8{ process_common.shell_argv[0], process_common.shell_argv[1], script };
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

test "process.run env overlays inherited environment" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("printf '%s:%s' \"$PATH\" \"$ZI_PROCESS_TEST_ENV\"", .{
        .argv = &.{},
        .env = &.{.{ .key = "ZI_PROCESS_TEST_ENV", .value = "overlay" }},
    });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expect(std.mem.startsWith(u8, completed.stdout, "/"));
    try std.testing.expect(std.mem.endsWith(u8, completed.stdout, ":overlay"));
}

test "process.run clear_env starts from empty environment" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("if [ -z \"${HOME+x}\" ]; then printf clear; else printf inherited; fi; printf ':%s' \"$ZI_PROCESS_TEST_ENV\"", .{
        .argv = &.{},
        .clear_env = true,
        .env = &.{.{ .key = "ZI_PROCESS_TEST_ENV", .value = "explicit" }},
    });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expectEqualSlices(u8, "clear:explicit", completed.stdout);
}

test "process.run returns immediately when command exits before timeout" {
    try skipShellProcessTestsIfUnsupported();
    const start = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds();
    var result = try runShell("true", .{ .argv = &.{}, .timeout_ms = 10_000 });
    defer result.deinit(std.testing.allocator);
    const elapsed = std.Io.Timestamp.now(std.Options.debug_io, .awake).toMilliseconds() - start;
    try std.testing.expect(elapsed < 500);
    switch (result) {
        .completed => {},
        else => return error.UnexpectedProcessError,
    }
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
    var controller = cancel.Source{};
    const signal = controller.beginRun();
    const Aborter = struct {
        fn run(ctrl: *cancel.Source) void {
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
    var controller = cancel.Source{};
    const signal = controller.beginRun();
    const Aborter = struct {
        fn run(ctrl: *cancel.Source) void {
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

test "process.run times out when background descendant inherits stdout" {
    try skipShellProcessTestsIfUnsupported();
    const start = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
    var result = try runShell("sleep 10 & printf done", .{ .argv = &.{}, .timeout_ms = 100, .kill_scope = .process_group });
    defer result.deinit(std.testing.allocator);
    const elapsed = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds() - start;
    const timed_out = switch (result) {
        .timed_out => |x| x,
        else => return error.UnexpectedProcessCompletion,
    };
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout, "done") != null);
    try std.testing.expect(elapsed < 1000);
}

test "process.run completes when background descendant redirects stdio" {
    try skipShellProcessTestsIfUnsupported();
    const start = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
    var result = try runShell("sleep 10 >/dev/null 2>&1 < /dev/null & printf done", .{ .argv = &.{}, .timeout_ms = 10_000, .kill_scope = .process_group });
    defer result.deinit(std.testing.allocator);
    const elapsed = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds() - start;
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expectEqualSlices(u8, "done", completed.stdout);
    try std.testing.expect(elapsed < 500);
}
