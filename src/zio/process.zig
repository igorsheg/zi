const builtin = @import("builtin");
const std = @import("std");
pub const Token = @import("cancel.zig").Token;
const cancel = @import("cancel.zig");
const process_common = @import("process_common.zig");
const process_reactor = @import("process_reactor.zig");
const process_env = @import("process_env.zig");
const runtime_env = @import("env");
pub const Jobs = @import("job.zig");

pub const default_max_output_bytes: usize = 1024 * 1024;
pub const EnvPair = process_reactor.EnvPair;
pub const StreamKind = enum { stdout, stderr };

pub const KillScope = enum { child, process_group };
pub const Stdin = union(enum) { ignore, inherit, bytes: []const u8 };
pub const Output = enum { ignore, inherit, capture };
pub const OutputOverflow = enum { fail, truncate };

pub const ChunkCallback = struct {
    // Called by the process.run()/stream() owner loop after capture state is
    // updated. Reactor/process threads must not invoke this callback directly.
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
    stdout_overflow: OutputOverflow = .fail,
    stderr_overflow: OutputOverflow = .fail,
    timeout_ms: ?u64 = null,
    kill_scope: KillScope = .process_group,
    signal: Token = Token.none,
    on_chunk: ?ChunkCallback = null,
};

pub const StreamOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    stdin: Stdin = .ignore,
    stdout_limit: std.Io.Limit = .limited(default_max_output_bytes),
    stderr_limit: std.Io.Limit = .limited(default_max_output_bytes),
    stdout_overflow: OutputOverflow = .fail,
    stderr_overflow: OutputOverflow = .fail,
    timeout_ms: ?u64 = null,
    kill_scope: KillScope = .process_group,
    signal: Token = Token.none,
    on_chunk: ?ChunkCallback = null,
};

pub const CapturedStream = struct {
    bytes: []u8,
    total_bytes: usize = 0,
    truncated: bool = false,
};

pub const Completed = struct {
    term: std.process.Child.Term,
    stdout: CapturedStream,
    stderr: CapturedStream,
};

pub const Partial = struct {
    stdout: CapturedStream,
    stderr: CapturedStream,
    message: []u8,
};

pub const RunResult = union(enum) {
    completed: Completed,
    timed_out: Partial,
    stdout_too_long: Partial,
    stderr_too_long: Partial,
    output_dropped: Partial,
    aborted: Partial,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |x| {
                allocator.free(x.stdout.bytes);
                allocator.free(x.stderr.bytes);
            },
            .timed_out, .stdout_too_long, .stderr_too_long, .output_dropped, .aborted => |x| {
                allocator.free(x.stdout.bytes);
                allocator.free(x.stderr.bytes);
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
        .stdout_overflow = options.stdout_overflow,
        .stderr_overflow = options.stderr_overflow,
        .timeout_ms = options.timeout_ms,
        .kill_scope = options.kill_scope,
        .signal = options.signal,
        .on_chunk = options.on_chunk,
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
    return .{ .completed = .{ .term = term, .stdout = try emptyCapturedStream(allocator), .stderr = try emptyCapturedStream(allocator) } };
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
    var abort_node: Token.CallbackNode = undefined;
    options.signal.registerCallback(&abort_node, .{ .ptr = @ptrCast(&abort_ctx), .call = InheritAbortCtx.abort });
    defer options.signal.unregisterCallback(&abort_node);

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

    var capture = Capture.init(allocator, .{
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
        .stdout_overflow = options.stdout_overflow,
        .stderr_overflow = options.stderr_overflow,
        .stdout_policy = streamCapturePolicy(store_stdout, options.on_chunk != null),
        .stderr_policy = streamCapturePolicy(store_stderr, options.on_chunk != null),
    });
    defer capture.deinit();

    var reactor = process_reactor.Reactor.initIo(allocator, io) catch return error.SpawnFailed;
    defer reactor.deinit();
    capture.reactor = &reactor;

    reactor.start() catch return error.SpawnFailed;
    reactor.spawn(.{
        .id = 1,
        .argv = options.argv,
        .cwd = cwd,
        .env = options.env,
        .clear_env = options.clear_env,
        .process_group = options.kill_scope == .process_group,
        .stdin = options.stdin == .bytes,
        .stdout = true,
        .stderr = true,
        .timeout_ms = options.timeout_ms,
        .signal = options.signal,
    }) catch return error.SpawnFailed;
    if (options.stdin == .bytes) {
        try waitProcessReady(allocator, &reactor, &capture, options.on_chunk);
        reactor.write(1, options.stdin.bytes) catch {};
        reactor.closeStdin(1) catch {};
    }

    while (!capture.isTerminal() or reactor.events.pendingDepth() > 0) {
        var batch: [16]process_reactor.Event = undefined;
        const count = reactor.drainEvents(&batch);
        if (count == 0) {
            _ = reactor.waitEvents(100) catch false;
            continue;
        }
        for (batch[0..count]) |*event| {
            defer event.deinit(allocator);
            if (capture.submitEvent(event.*)) |chunk| deliverChunk(options.on_chunk, chunk);
        }
    }

    const outcome = capture.outcome();
    if (capture.timed_out) return capture.finishPartial(.timed_out, "timed out");
    if (capture.aborted or options.signal.isAborted()) return capture.finishPartial(.aborted, "aborted");
    if (outcome == .stdout_too_long) return capture.finishPartial(.stdout_too_long, "stdout exceeded output limit");
    if (outcome == .stderr_too_long) return capture.finishPartial(.stderr_too_long, "stderr exceeded output limit");
    if (outcome == .output_dropped) return capture.finishPartial(.output_dropped, "process output events dropped");
    if (outcome == .spawn_failed) return error.SpawnFailed;

    const term = capture.term orelse return error.WaitFailed;
    const stdout = try capture.takeStdout();
    errdefer allocator.free(stdout.bytes);
    const stderr = try capture.takeStderr();
    return .{ .completed = .{ .term = term, .stdout = stdout, .stderr = stderr } };
}

fn emptyCapturedStream(allocator: std.mem.Allocator) !CapturedStream {
    return .{ .bytes = try allocator.dupe(u8, ""), .total_bytes = 0, .truncated = false };
}

const StreamCapturePolicy = enum {
    ignore,
    capture_bounded,
    stream_only,
    stream_and_capture_bounded,

    fn stores(self: StreamCapturePolicy) bool {
        return self == .capture_bounded or self == .stream_and_capture_bounded;
    }

    fn streams(self: StreamCapturePolicy) bool {
        return self == .stream_only or self == .stream_and_capture_bounded;
    }
};

fn streamCapturePolicy(store: bool, emit_chunks: bool) StreamCapturePolicy {
    if (store and emit_chunks) return .stream_and_capture_bounded;
    if (store) return .capture_bounded;
    if (emit_chunks) return .stream_only;
    return .ignore;
}

fn waitProcessReady(allocator: std.mem.Allocator, reactor: *process_reactor.Reactor, capture: *Capture, on_chunk: ?ChunkCallback) RunError!void {
    while (!capture.isTerminal()) {
        var batch: [16]process_reactor.Event = undefined;
        const count = reactor.drainEvents(&batch);
        if (count == 0) {
            _ = reactor.waitEvents(100) catch false;
            continue;
        }
        for (batch[0..count]) |*event| {
            defer event.deinit(allocator);
            if (event.* == .ready) return;
            if (capture.submitEvent(event.*)) |chunk| deliverChunk(on_chunk, chunk);
        }
    }
    return error.SpawnFailed;
}

const ChunkDelivery = struct {
    kind: StreamKind,
    bytes: []const u8,
};

fn deliverChunk(on_chunk: ?ChunkCallback, chunk: ChunkDelivery) void {
    const cb = on_chunk orelse return;
    cb.call(chunk.kind, chunk.bytes);
}

const CaptureOutcome = enum { none, spawn_failed, stdout_too_long, stderr_too_long, output_dropped };

const Capture = struct {
    allocator: std.mem.Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_total_bytes: usize = 0,
    stderr_total_bytes: usize = 0,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    stdout_limit: std.Io.Limit,
    stderr_limit: std.Io.Limit,
    stdout_overflow: OutputOverflow,
    stderr_overflow: OutputOverflow,
    stdout_policy: StreamCapturePolicy,
    stderr_policy: StreamCapturePolicy,
    reactor: ?*process_reactor.Reactor = null,
    term: ?std.process.Child.Term = null,
    timed_out: bool = false,
    aborted: bool = false,
    failure: CaptureOutcome = .none,

    const Config = struct {
        stdout_limit: std.Io.Limit,
        stderr_limit: std.Io.Limit,
        stdout_overflow: OutputOverflow,
        stderr_overflow: OutputOverflow,
        stdout_policy: StreamCapturePolicy,
        stderr_policy: StreamCapturePolicy,
    };

    fn init(allocator: std.mem.Allocator, config: Config) Capture {
        return .{
            .allocator = allocator,
            .stdout_limit = config.stdout_limit,
            .stderr_limit = config.stderr_limit,
            .stdout_overflow = config.stdout_overflow,
            .stderr_overflow = config.stderr_overflow,
            .stdout_policy = config.stdout_policy,
            .stderr_policy = config.stderr_policy,
        };
    }

    fn deinit(self: *Capture) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
    }

    fn submitEvent(self: *Capture, event: process_reactor.Event) ?ChunkDelivery {
        var delivery: ?ChunkDelivery = null;
        switch (event) {
            .stdout => |out| {
                self.appendCaptured(.stdout, out.bytes);
                if (self.stdout_policy.streams()) delivery = .{ .kind = .stdout, .bytes = out.bytes };
            },
            .stderr => |out| {
                self.appendCaptured(.stderr, out.bytes);
                if (self.stderr_policy.streams()) delivery = .{ .kind = .stderr, .bytes = out.bytes };
            },
            .ready => {},
            .output_dropped => |dropped| {
                _ = dropped;
                self.failure = .output_dropped;
                if (self.reactor) |reactor| reactor.kill(1) catch {};
            },
            .exit => |exit| {
                self.term = exit.term;
                self.timed_out = exit.timed_out;
                self.aborted = exit.aborted;
            },
            .spawn_failed => self.failure = .spawn_failed,
        }
        return delivery;
    }

    fn appendCaptured(self: *Capture, kind: StreamKind, bytes: []const u8) void {
        const capture_policy = self.policy(kind);
        switch (kind) {
            .stdout => self.stdout_total_bytes += bytes.len,
            .stderr => self.stderr_total_bytes += bytes.len,
        }
        if (!capture_policy.stores()) return;
        const list = switch (kind) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        const limit = switch (kind) {
            .stdout => self.stdout_limit,
            .stderr => self.stderr_limit,
        };
        const overflow = switch (kind) {
            .stdout => self.stdout_overflow,
            .stderr => self.stderr_overflow,
        };
        const limit_len = limit.toInt() orelse std.math.maxInt(usize);
        const allowed = remainingCapacity(list.items.len, limit);

        if (overflow == .truncate) {
            appendRollingTail(self.allocator, list, bytes, limit_len) catch return;
        } else {
            const clipped = bytes[0..@min(bytes.len, allowed)];
            if (clipped.len > 0) list.appendSlice(self.allocator, clipped) catch return;
        }

        if (bytes.len > allowed) {
            switch (kind) {
                .stdout => {
                    self.stdout_truncated = true;
                    if (self.stdout_overflow == .fail) {
                        self.failure = .stdout_too_long;
                        if (self.reactor) |reactor| reactor.kill(1) catch {};
                    }
                },
                .stderr => {
                    self.stderr_truncated = true;
                    if (self.stderr_overflow == .fail) {
                        self.failure = .stderr_too_long;
                        if (self.reactor) |reactor| reactor.kill(1) catch {};
                    }
                },
            }
        }
    }

    fn policy(self: *const Capture, kind: StreamKind) StreamCapturePolicy {
        return switch (kind) {
            .stdout => self.stdout_policy,
            .stderr => self.stderr_policy,
        };
    }

    fn outcome(self: *Capture) CaptureOutcome {
        return self.failure;
    }

    fn isTerminal(self: *Capture) bool {
        return self.term != null or self.failure == .spawn_failed;
    }

    fn takeStdout(self: *Capture) !CapturedStream {
        if (!self.stdout_policy.stores()) return emptyCapturedStream(self.allocator);
        const out = try self.stdout.toOwnedSlice(self.allocator);
        self.stdout = .empty;
        return .{ .bytes = out, .total_bytes = self.stdout_total_bytes, .truncated = self.stdout_truncated };
    }

    fn takeStderr(self: *Capture) !CapturedStream {
        if (!self.stderr_policy.stores()) return emptyCapturedStream(self.allocator);
        const out = try self.stderr.toOwnedSlice(self.allocator);
        self.stderr = .empty;
        return .{ .bytes = out, .total_bytes = self.stderr_total_bytes, .truncated = self.stderr_truncated };
    }

    fn finishPartial(self: *Capture, comptime tag: std.meta.Tag(RunResult), msg: []const u8) RunError!RunResult {
        const stdout = try self.takeStdout();
        errdefer self.allocator.free(stdout.bytes);
        const stderr = try self.takeStderr();
        errdefer self.allocator.free(stderr.bytes);
        const message = self.allocator.dupe(u8, msg) catch return error.OutOfMemory;
        const p = Partial{ .stdout = stdout, .stderr = stderr, .message = message };
        return switch (tag) {
            .timed_out => .{ .timed_out = p },
            .stdout_too_long => .{ .stdout_too_long = p },
            .stderr_too_long => .{ .stderr_too_long = p },
            .output_dropped => .{ .output_dropped = p },
            .aborted => .{ .aborted = p },
            else => unreachable,
        };
    }
};

fn appendRollingTail(allocator: std.mem.Allocator, list: *std.ArrayList(u8), bytes: []const u8, limit: usize) !void {
    if (limit == 0) return;
    if (bytes.len >= limit) {
        try list.resize(allocator, limit);
        @memcpy(list.items, bytes[bytes.len - limit ..]);
        return;
    }
    try list.appendSlice(allocator, bytes);
    if (list.items.len > limit) {
        const excess = list.items.len - limit;
        std.mem.copyForwards(u8, list.items[0..limit], list.items[excess..]);
        try list.resize(allocator, limit);
    }
}

fn remainingCapacity(len: usize, limit: std.Io.Limit) usize {
    return if (limit.toInt()) |n| n -| len else std.math.maxInt(usize);
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
    try std.testing.expectEqualSlices(u8, "out", completed.stdout.bytes);
    try std.testing.expectEqualSlices(u8, "err", completed.stderr.bytes);
}

test "process.run streams chunks while preserving captured output" {
    try skipShellProcessTestsIfUnsupported();
    const Collector = struct {
        stdout_seen: bool = false,
        stderr_seen: bool = false,

        fn onChunk(raw: ?*anyopaque, kind: StreamKind, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            switch (kind) {
                .stdout => {
                    if (std.mem.indexOf(u8, bytes, "out") != null) self.stdout_seen = true;
                },
                .stderr => {
                    if (std.mem.indexOf(u8, bytes, "err") != null) self.stderr_seen = true;
                },
            }
        }
    };
    var collector = Collector{};
    var result = try runShell("printf out; printf err >&2", .{
        .argv = &.{},
        .on_chunk = .{ .ctx = @ptrCast(&collector), .func = Collector.onChunk },
    });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expect(collector.stdout_seen);
    try std.testing.expect(collector.stderr_seen);
    try std.testing.expectEqualSlices(u8, "out", completed.stdout.bytes);
    try std.testing.expectEqualSlices(u8, "err", completed.stderr.bytes);
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
    try std.testing.expect(std.mem.startsWith(u8, completed.stdout.bytes, "/"));
    try std.testing.expect(std.mem.endsWith(u8, completed.stdout.bytes, ":overlay"));
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
    try std.testing.expectEqualSlices(u8, "clear:explicit", completed.stdout.bytes);
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
    try std.testing.expectEqual(@as(usize, 2048 * 64), completed.stdout.bytes.len);
    try std.testing.expectEqual(@as(usize, 2048 * 64), completed.stderr.bytes.len);
}

test "process.run writes stdin then closes the child pipe" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("cat", .{ .argv = &.{}, .stdin = .{ .bytes = "hello stdin" } });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expectEqualSlices(u8, "hello stdin", completed.stdout.bytes);
}

test "process.run timeout preserves output emitted before termination" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("printf before; sleep 5; printf after", .{ .argv = &.{}, .timeout_ms = 100 });
    defer result.deinit(std.testing.allocator);
    const timed_out = switch (result) {
        .timed_out => |x| x,
        else => return error.UnexpectedProcessCompletion,
    };
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout.bytes, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout.bytes, "after") == null);
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

test "process.run can truncate captured output without killing child" {
    try skipShellProcessTestsIfUnsupported();
    var result = try runShell("printf abcdef; exit 7", .{
        .argv = &.{},
        .stdout_limit = .limited(3),
        .stdout_overflow = .truncate,
    });
    defer result.deinit(std.testing.allocator);
    const completed = switch (result) {
        .completed => |x| x,
        else => return error.UnexpectedProcessError,
    };
    try std.testing.expectEqualSlices(u8, "def", completed.stdout.bytes);
    try std.testing.expectEqual(@as(usize, 6), completed.stdout.total_bytes);
    try std.testing.expect(completed.stdout.truncated);
    try std.testing.expectEqual(@as(u8, 7), completed.term.exited);
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
    try std.testing.expect(std.mem.indexOf(u8, timed_out.stdout.bytes, "done") != null);
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
    try std.testing.expectEqualSlices(u8, "done", completed.stdout.bytes);
    try std.testing.expect(elapsed < 500);
}
