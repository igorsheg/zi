const builtin = @import("builtin");
const std = @import("std");
const protocol = @import("../agent/protocol.zig");
const json_util = @import("../ai/json_util.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const output_buffer = @import("../lib/output_buffer.zig");
const AbortGuard = @import("../abort_guard.zig").AbortGuard;
const lock_registry = @import("../agent/lock_registry.zig");

const HEAD_LINES: usize = 50;
const TAIL_LINES: usize = 50;
const TRUNCATED_FMT = "... [{d} lines truncated] ...";
const STREAM_UPDATE_POLL_MS: u64 = 50;
const STREAM_UPDATE_MIN_INTERVAL_MS: u64 = 100;

const bash_schema =
    \\{"type":"object","properties":{"cmd":{"type":"string","description":"The shell command to execute."},"cwd":{"type":"string","description":"Working directory for the command (absolute path). Defaults to workspace root."},"timeout":{"type":"number","description":"Timeout in seconds."}},"required":["cmd"]}
;

const DESCRIPTION =
    "Executes the given shell command using bash.\n\n" ++
    "- Do NOT chain commands with `;` or `&&` or use `&` for background processes; make separate tool calls instead\n" ++
    "- Do NOT use interactive commands (REPLs, editors, password prompts)\n" ++
    "- Output shows first 50 and last 50 lines; middle is truncated for large outputs\n" ++
    "- Environment variables and `cd` do not persist between commands; use the `cwd` parameter instead\n" ++
    "- Commands run in the workspace root by default; only use `cwd` when you need a different directory\n" ++
    "- ALWAYS quote file paths: `cat \"path with spaces/file.txt\"`\n" ++
    "- Use the Grep tool instead of grep, the Read tool instead of cat\n" ++
    "- Only run `git commit` and `git push` if explicitly instructed by the user.";

pub fn definition(ctx: *util.BuiltinCtx) tool_def.ToolDefinition {
    return .{
        .name = "bash",
        .description = DESCRIPTION,
        .label = "Bash",
        .parameters = parseSchema(),
        .prompt_snippet = "Execute bash commands (ls, grep, find, etc.)",
        .impl = .{ .builtin = .{ .ctx = @ptrCast(ctx), .execute = &execute } },
        .source = .{ .kind = "builtin", .id = "bash" },
    };
}

fn parseSchema() std.json.Value {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        bash_schema,
        .{ .allocate = .alloc_if_needed },
    ) catch return .null;
    return parsed.value;
}

const PermissionAction = enum { allow, reject };

const PermissionRule = struct {
    tool: []const u8,
    cmd_patterns: []const []const u8 = &.{},
    action: PermissionAction,
    message: ?[]const u8 = null,
};

fn execute(
    raw_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    args: std.json.Value,
    signal: protocol.AbortSignal,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolResult {
    const ctx: *util.BuiltinCtx = @ptrCast(@alignCast(raw_ctx orelse
        return util.errorResult(allocator, "bash tool: missing context")));

    var command = util.getString(args, "cmd") orelse
        return util.errorResult(allocator, "bash tool: missing 'cmd' argument");
    command = stripBackground(command);

    var effective_cwd = blk: {
        const cwd_arg = util.getString(args, "cwd") orelse break :blk allocator.dupe(u8, ctx.cwd) catch
            return util.errorResult(allocator, "bash tool: alloc failed");
        break :blk util.resolvePath(allocator, cwd_arg, ctx.cwd) catch
            return util.errorResult(allocator, "bash tool: failed to resolve cwd");
    };
    defer allocator.free(effective_cwd);

    if (splitCdCommand(command)) |cd_split| {
        const next_cwd = util.resolvePath(allocator, cd_split.cwd, effective_cwd) catch
            return util.errorResult(allocator, "bash tool: failed to resolve cwd");
        allocator.free(effective_cwd);
        effective_cwd = next_cwd;
        command = cd_split.command;
    }

    std.fs.accessAbsolute(effective_cwd, .{}) catch {
        return util.errorf(allocator, "working directory does not exist: {s}", .{effective_cwd});
    };

    const rules = loadPermissions(allocator) catch &.{};
    defer freePermissions(allocator, rules);
    const verdict = evaluatePermission(command, rules);
    if (verdict.action == .reject) {
        if (verdict.message) |message| {
            return util.errorf(allocator, "command rejected: {s}", .{message});
        }
        return util.errorf(allocator, "command rejected by permission rule. command: {s}", .{command});
    }

    const final_command = injectGitTrailers(allocator, command, ctx.session_id) catch allocator.dupe(u8, command) catch
        return util.errorResult(allocator, "bash tool: alloc failed");
    defer allocator.free(final_command);

    if (isGitCommand(final_command)) {
        const git_lock_key = std.fs.path.join(allocator, &.{ effective_cwd, ".git", "__zi_git_lock__" }) catch
            return util.errorResult(allocator, "bash tool: alloc failed");
        defer allocator.free(git_lock_key);
        const lock_entry = lock_registry.global().acquireKey(git_lock_key) catch
            return util.errorResult(allocator, "bash tool: failed to acquire git lock");
        defer lock_registry.global().release(lock_entry);
        return runCommand(allocator, final_command, effective_cwd, extractTimeout(args), signal, on_update, update_ctx);
    }

    return runCommand(allocator, final_command, effective_cwd, extractTimeout(args), signal, on_update, update_ctx);
}

fn runCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    cwd: []const u8,
    timeout_secs: ?u64,
    signal: protocol.AbortSignal,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolResult {
    var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{ .child_allocator = allocator };
    const io_allocator = thread_safe_allocator.allocator();

    const shell_argv: []const []const u8 = if (std.fs.accessAbsolute("/bin/bash", .{}))
        &.{ "/bin/bash", "-c", command }
    else |_|
        &.{ "/bin/sh", "-c", command };

    var child = std.process.Child.init(shell_argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        child.pgid = 0;
    }

    child.spawn() catch |err| {
        return util.errorf(allocator, "command error: {s}", .{@errorName(err)});
    };

    var abort_guard = AbortGuard.start(signal, .{ .interrupt_process_group = child.id });
    defer abort_guard.stop();

    var timeout_guard = TimeoutGuard.start(timeout_secs, child.id);
    defer timeout_guard.stop();

    const completed = if (on_update) |cb|
        runStreamingCapture(allocator, io_allocator, &child, command, cb, update_ctx)
    else
        runBufferedCapture(allocator, io_allocator, &child);
    defer if (completed.output_text.len > 0) allocator.free(completed.output_text);

    const term = child.wait() catch null;
    timeout_guard.markExited();

    const result_text = formatCommandTranscript(allocator, command, completed.output_text) catch
        return util.errorResult(allocator, "bash tool: alloc failed");
    defer allocator.free(result_text);

    if (signal.isAborted()) {
        const aborted = appendTail(allocator, result_text, "\n\ncommand aborted") catch result_text;
        defer if (aborted.ptr != result_text.ptr) allocator.free(aborted);
        return .{ .content = oneText(allocator, aborted), .is_error = true };
    }

    if (timeout_guard.did_timeout.load(.acquire)) {
        if (timeout_secs) |secs| {
            const tail = std.fmt.allocPrint(allocator, "\n\ncommand timed out after {d} seconds", .{secs}) catch "";
            defer if (tail.len > 0) allocator.free(tail);
            const timed_out = appendTail(allocator, result_text, tail) catch result_text;
            defer if (timed_out.ptr != result_text.ptr) allocator.free(timed_out);
            return .{ .content = oneText(allocator, timed_out), .is_error = true };
        }
        return .{ .content = oneText(allocator, result_text), .is_error = true };
    }

    if (term) |t| switch (t) {
        .Exited => |code| {
            if (code != 0) {
                const tail = std.fmt.allocPrint(allocator, "\n\nexit code {d}", .{code}) catch "";
                defer if (tail.len > 0) allocator.free(tail);
                const failed = appendTail(allocator, result_text, tail) catch result_text;
                defer if (failed.ptr != result_text.ptr) allocator.free(failed);
                return .{ .content = oneText(allocator, failed), .is_error = true };
            }
        },
        else => {
            return .{ .content = oneText(allocator, result_text), .is_error = true };
        },
    };

    return .{ .content = oneText(allocator, result_text) };
}

const TimeoutGuard = struct {
    done: *std.Thread.ResetEvent,
    did_timeout: *std.atomic.Value(bool),
    thread: ?std.Thread,

    fn start(timeout_secs: ?u64, process_group_id: std.process.Child.Id) TimeoutGuard {
        const secs = timeout_secs orelse return .{ .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        const done = std.heap.page_allocator.create(std.Thread.ResetEvent) catch return .{ .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        errdefer std.heap.page_allocator.destroy(done);
        const did_timeout = std.heap.page_allocator.create(std.atomic.Value(bool)) catch return .{ .done = &noop_done, .did_timeout = &noop_timeout, .thread = null };
        done.* = .{};
        did_timeout.* = std.atomic.Value(bool).init(false);
        const thread = std.Thread.spawn(.{}, watchdog, .{ secs, process_group_id, done, did_timeout }) catch null;
        return .{ .done = done, .did_timeout = did_timeout, .thread = thread };
    }

    fn markExited(self: *TimeoutGuard) void {
        self.done.set();
    }

    fn stop(self: *TimeoutGuard) void {
        self.done.set();
        if (self.thread) |t| t.join();
        if (self.done != &noop_done) std.heap.page_allocator.destroy(self.done);
        if (self.did_timeout != &noop_timeout) std.heap.page_allocator.destroy(self.did_timeout);
        self.thread = null;
    }

    var noop_done: std.Thread.ResetEvent = .{};
    var noop_timeout = std.atomic.Value(bool).init(false);

    fn watchdog(timeout_secs: u64, process_group_id: std.process.Child.Id, done: *std.Thread.ResetEvent, did_timeout: *std.atomic.Value(bool)) void {
        done.timedWait(timeout_secs * std.time.ns_per_s) catch |err| switch (err) {
            error.Timeout => {
                did_timeout.store(true, .release);
                killProcessGroup(process_group_id, std.posix.SIG.KILL);
            },
        };
    }
};

fn killProcessGroup(process_group_id: std.process.Child.Id, sig: u8) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        std.posix.kill(process_group_id, sig) catch {};
        return;
    }
    const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(process_group_id));
    std.posix.kill(group_pid, sig) catch {};
}

const CompletedOutput = struct {
    output_text: []u8 = &.{},
};

const StreamKind = enum { stdout, stderr };

const StreamingCapture = struct {
    mutex: std.Thread.Mutex = .{},
    output: output_buffer.LineOutputBuffer,
    stdout_done: bool = false,
    stderr_done: bool = false,
    dirty: bool = false,

    fn init(allocator: std.mem.Allocator) StreamingCapture {
        return .{
            .output = output_buffer.LineOutputBuffer.init(allocator, HEAD_LINES, TAIL_LINES),
        };
    }

    fn deinit(self: *StreamingCapture) void {
        self.output.deinit();
    }

    fn append(self: *StreamingCapture, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.output.addChunk(bytes) catch return;
        self.dirty = true;
    }

    fn markDone(self: *StreamingCapture, kind: StreamKind) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (kind) {
            .stdout => self.stdout_done = true,
            .stderr => self.stderr_done = true,
        }
    }

    fn isComplete(self: *StreamingCapture) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stdout_done and self.stderr_done;
    }

    fn takeDirtySnapshot(self: *StreamingCapture, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.dirty) return null;
        self.dirty = false;
        const snapshot = self.output.snapshotAlloc(allocator, TRUNCATED_FMT) catch return null;
        return snapshot.text;
    }

    fn finishText(self: *StreamingCapture, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const final = try self.output.finishAlloc(allocator, TRUNCATED_FMT);
        return final.text;
    }
};

fn runBufferedCapture(
    allocator: std.mem.Allocator,
    io_allocator: std.mem.Allocator,
    child: *std.process.Child,
) CompletedOutput {
    var capture = StreamingCapture.init(io_allocator);
    defer capture.deinit();

    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, readStream, .{ stderr_file, &capture, StreamKind.stderr }) catch blk: {
            capture.markDone(.stderr);
            break :blk null;
        };
    } else capture.markDone(.stderr);

    if (child.stdout) |stdout_file| {
        readStream(stdout_file, &capture, StreamKind.stdout);
    } else capture.markDone(.stdout);

    if (stderr_thread) |t| t.join();

    return .{ .output_text = capture.finishText(allocator) catch allocator.dupe(u8, "") catch &.{} };
}

fn runStreamingCapture(
    allocator: std.mem.Allocator,
    io_allocator: std.mem.Allocator,
    child: *std.process.Child,
    command: []const u8,
    cb: protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) CompletedOutput {
    var capture = StreamingCapture.init(io_allocator);
    defer capture.deinit();

    var stdout_thread: ?std.Thread = null;
    var stderr_thread: ?std.Thread = null;

    if (child.stdout) |stdout_file| {
        stdout_thread = std.Thread.spawn(.{}, readStream, .{ stdout_file, &capture, StreamKind.stdout }) catch blk: {
            capture.markDone(.stdout);
            break :blk null;
        };
    } else capture.markDone(.stdout);

    if (child.stderr) |stderr_file| {
        stderr_thread = std.Thread.spawn(.{}, readStream, .{ stderr_file, &capture, StreamKind.stderr }) catch blk: {
            capture.markDone(.stderr);
            break :blk null;
        };
    } else capture.markDone(.stderr);

    var last_emit_ns: i128 = 0;
    var last_emitted_hash: ?u64 = null;

    while (!capture.isComplete()) {
        const now_ns = std.time.nanoTimestamp();
        if (last_emit_ns == 0 or now_ns - last_emit_ns >= STREAM_UPDATE_MIN_INTERVAL_MS * std.time.ns_per_ms) {
            if (capture.takeDirtySnapshot(allocator)) |snapshot| {
                defer if (snapshot.len > 0) allocator.free(snapshot);
                if (emitPartialTranscriptUpdate(allocator, command, snapshot, cb, update_ctx, last_emitted_hash)) |new_hash| {
                    last_emitted_hash = new_hash;
                    last_emit_ns = now_ns;
                }
            }
        }
        std.Thread.sleep(STREAM_UPDATE_POLL_MS * std.time.ns_per_ms);
    }

    if (capture.takeDirtySnapshot(allocator)) |snapshot| {
        defer if (snapshot.len > 0) allocator.free(snapshot);
        if (emitPartialTranscriptUpdate(allocator, command, snapshot, cb, update_ctx, last_emitted_hash)) |new_hash| {
            last_emitted_hash = new_hash;
        }
    }

    if (stdout_thread) |t| t.join();
    if (stderr_thread) |t| t.join();

    return .{ .output_text = capture.finishText(allocator) catch allocator.dupe(u8, "") catch &.{} };
}

fn readStream(file: std.fs.File, capture: *StreamingCapture, kind: StreamKind) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        capture.append(buf[0..n]);
    }
    capture.markDone(kind);
}

test "TimeoutGuard.stop does not wait for the full timeout after process exit" {
    const testing = std.testing;

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", "exit 0" }, testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var guard = TimeoutGuard.start(2, child.id);

    _ = try child.wait();
    try testing.expect(!guard.did_timeout.load(.acquire));
    guard.markExited();

    const start_ns = std.time.nanoTimestamp();
    guard.stop();
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;

    try testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);
}

test "oneText sanitizes invalid utf-8" {
    const allocator = std.testing.allocator;
    const blocks = oneText(allocator, "bad\xaa\xfftail");
    defer {
        allocator.free(blocks[0].text.text);
        allocator.free(blocks);
    }

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("bad��tail", blocks[0].text.text);
}

test "runCommand handles concurrent stdout and stderr" {
    const testing = std.testing;
    const cmd =
        \\i=0
        \\while [ "$i" -lt 400 ]; do
        \\  printf 'out%04d\n' "$i"
        \\  printf 'err%04d\n' "$i" 1>&2
        \\  i=$((i + 1))
        \\done
    ;

    var iteration: usize = 0;
    while (iteration < 32) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const result = runCommand(arena.allocator(), cmd, "/tmp", 5, protocol.AbortSignal.none, null, null);

        try testing.expect(!result.is_error);
        try testing.expectEqual(@as(usize, 1), result.content.len);
        try testing.expect(result.content[0] == .text);
        try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "out0000") != null);
        try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "err0399") != null);
        try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "lines truncated") != null);
    }
}

test "runCommand emits partial updates while command is still running" {
    const testing = std.testing;

    const CallbackState = struct {
        count: usize = 0,
        saw_partial: bool = false,

        const Self = @This();

        fn callback(partial_result: protocol.AgentToolResult, ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.count += 1;
            if (partial_result.content.len > 0 and partial_result.content[0] == .text) {
                if (std.mem.indexOf(u8, partial_result.content[0].text.text, "first") != null) {
                    self.saw_partial = true;
                }
            }
        }
    };

    const cmd =
        \\printf 'first\n'
        \\sleep 0.2
        \\printf 'second\n' 1>&2
        \\sleep 0.2
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var state = CallbackState{};
    const result = runCommand(
        arena.allocator(),
        cmd,
        "/tmp",
        5,
        protocol.AbortSignal.none,
        &CallbackState.callback,
        @ptrCast(&state),
    );

    try testing.expect(!result.is_error);
    try testing.expect(state.count >= 1);
    try testing.expect(state.saw_partial);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "second") != null);
}

test "runCommand abort kills the spawned process group, not just the shell pid" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const testing = std.testing;
    const abort_signal = @import("../abort_signal.zig");
    const pid_file = try std.fmt.allocPrint(testing.allocator, "/tmp/zi-bash-abort-{d}.pid", .{std.time.nanoTimestamp()});
    defer testing.allocator.free(pid_file);
    std.fs.deleteFileAbsolute(pid_file) catch {};
    defer std.fs.deleteFileAbsolute(pid_file) catch {};

    const cmd = try std.fmt.allocPrint(testing.allocator,
        \\sleep 30 &
        \\child=$!
        \\printf '%s\n' "$child" > '{s}'
        \\wait "$child"
    , .{pid_file});
    defer testing.allocator.free(cmd);

    var controller = abort_signal.AbortController{};
    const signal = controller.beginRun();
    const Aborter = struct {
        fn run(c: *abort_signal.AbortController) void {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            c.requestAbort();
        }
    };
    const aborter = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer aborter.join();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = runCommand(arena.allocator(), cmd, "/tmp", 5, signal, null, null);

    try testing.expect(result.is_error);
    try testing.expectEqual(@as(usize, 1), result.content.len);
    try testing.expect(result.content[0] == .text);
    try testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "command aborted") != null);

    var file = try std.fs.openFileAbsolute(pid_file, .{});
    defer file.close();
    const pid_text = try file.readToEndAlloc(testing.allocator, 64);
    defer testing.allocator.free(pid_text);
    const child_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \r\n\t"), 10);

    const deadline_ms = std.time.milliTimestamp() + 1_000;
    while (true) {
        std.posix.kill(child_pid, 0) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        if (std.time.milliTimestamp() >= deadline_ms) {
            return error.TestUnexpectedBackgroundChildStillRunning;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn oneText(allocator: std.mem.Allocator, text: []const u8) []protocol.AgentToolResult.ContentBlock {
    const owned = json_util.utf8LossyAlloc(allocator, text) catch allocator.dupe(u8, text) catch return &.{};
    errdefer allocator.free(owned);

    const blocks = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch return &.{};
    blocks[0] = .{ .text = .{ .text = owned } };
    return blocks;
}

fn formatCommandTranscript(allocator: std.mem.Allocator, command: []const u8, output: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, "$ ");
    try result.appendSlice(allocator, command);
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, if (output.len > 0) output else "(no output)");
    return result.toOwnedSlice(allocator);
}

fn appendTail(allocator: std.mem.Allocator, base: []const u8, tail: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, tail });
}

fn emitPartialTranscriptUpdate(
    allocator: std.mem.Allocator,
    command: []const u8,
    output_text: []const u8,
    cb: protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
    previous_hash: ?u64,
) ?u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const text = formatCommandTranscript(aa, command, output_text) catch return null;
    const hash = std.hash.Wyhash.hash(0, text);
    if (previous_hash) |prev| {
        if (prev == hash) return null;
    }
    cb(.{ .content = oneText(aa, text) }, update_ctx);
    return hash;
}

fn extractTimeout(args: std.json.Value) ?u64 {
    switch (args) {
        .object => |obj| {
            if (obj.get("timeout")) |value| switch (value) {
                .integer => |i| if (i > 0) return @intCast(i),
                .float => |f| if (f > 0) return @intFromFloat(@floor(f)),
                else => {},
            };
            return null;
        },
        else => return null,
    }
}

const CdSplit = struct {
    cwd: []const u8,
    command: []const u8,
};

fn splitCdCommand(cmd: []const u8) ?CdSplit {
    const trimmed = std.mem.trim(u8, cmd, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, trimmed, "cd ")) return null;

    const rest = trimmed[3..];
    var sep_idx: ?usize = null;
    var sep_len: usize = 0;
    if (std.mem.indexOf(u8, rest, "&&")) |idx| {
        sep_idx = idx;
        sep_len = 2;
    }
    if (std.mem.indexOfScalar(u8, rest, ';')) |idx| {
        if (sep_idx == null or idx < sep_idx.?) {
            sep_idx = idx;
            sep_len = 1;
        }
    }
    const idx = sep_idx orelse return null;

    const raw_dir = std.mem.trim(u8, rest[0..idx], &std.ascii.whitespace);
    const raw_command = std.mem.trim(u8, rest[idx + sep_len ..], &std.ascii.whitespace);
    if (raw_dir.len == 0 or raw_command.len == 0) return null;
    return .{ .cwd = unquote(raw_dir), .command = raw_command };
}

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or (text[0] == '\'' and text[text.len - 1] == '\''))) {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn stripBackground(cmd: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, cmd, &std.ascii.whitespace);
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '&') {
        return std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], &std.ascii.whitespace);
    }
    return trimmed;
}

fn isGitCommand(cmd: []const u8) bool {
    return std.mem.indexOf(u8, cmd, "git ") != null;
}

fn injectGitTrailers(allocator: std.mem.Allocator, cmd: []const u8, session_id: []const u8) ![]u8 {
    if (session_id.len == 0) return allocator.dupe(u8, cmd);
    if (std.mem.indexOf(u8, cmd, "git commit") == null) return allocator.dupe(u8, cmd);
    if (std.mem.indexOf(u8, cmd, "--trailer") != null) return allocator.dupe(u8, cmd);
    const needle = "git commit";
    const idx = std.mem.indexOf(u8, cmd, needle) orelse return allocator.dupe(u8, cmd);
    return std.fmt.allocPrint(allocator, "{s}git commit --trailer \"Session-Id: {s}\"{s}", .{
        cmd[0..idx],
        session_id,
        cmd[idx + needle.len ..],
    });
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '*') {
        if (globMatches(pattern[1..], text)) return true;
        return text.len > 0 and globMatches(pattern, text[1..]);
    }
    if (text.len == 0) return false;
    return std.ascii.toLower(pattern[0]) == std.ascii.toLower(text[0]) and globMatches(pattern[1..], text[1..]);
}

fn evaluatePermission(cmd: []const u8, rules: []const PermissionRule) PermissionRule {
    for (rules) |rule| {
        if (!globMatches(rule.tool, "Bash")) continue;
        if (rule.cmd_patterns.len > 0) {
            var matched = false;
            for (rule.cmd_patterns) |pattern| {
                if (globMatches(pattern, cmd)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }
        return rule;
    }
    return .{ .tool = "Bash", .action = .allow };
}

fn loadPermissions(allocator: std.mem.Allocator) ![]PermissionRule {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return &.{};
    defer allocator.free(home);
    const permissions_path = try std.fs.path.join(allocator, &.{ home, ".pi", "agent", "permissions.json" });
    defer allocator.free(permissions_path);

    const raw = std.fs.cwd().readFileAlloc(allocator, permissions_path, 1024 * 1024) catch return &.{};
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .array) return &.{};

    var rules = std.ArrayList(PermissionRule).empty;
    errdefer {
        freePermissions(allocator, rules.items);
        rules.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const tool = switch (obj.get("tool") orelse continue) {
            .string => |s| try allocator.dupe(u8, s),
            else => continue,
        };
        errdefer allocator.free(tool);

        const action = switch (obj.get("action") orelse continue) {
            .string => |s| if (std.mem.eql(u8, s, "reject")) PermissionAction.reject else PermissionAction.allow,
            else => PermissionAction.allow,
        };
        const message = switch (obj.get("message") orelse .null) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
        errdefer if (message) |m| allocator.free(m);

        var cmd_patterns = std.ArrayList([]const u8).empty;
        errdefer {
            for (cmd_patterns.items) |p| allocator.free(p);
            cmd_patterns.deinit(allocator);
        }
        if (obj.get("matches")) |matches_val| {
            if (matches_val == .object) {
                if (matches_val.object.get("cmd")) |cmd_val| switch (cmd_val) {
                    .string => |s| try cmd_patterns.append(allocator, try allocator.dupe(u8, s)),
                    .array => |arr| for (arr.items) |entry| if (entry == .string) try cmd_patterns.append(allocator, try allocator.dupe(u8, entry.string)),
                    else => {},
                };
            }
        }

        try rules.append(allocator, .{
            .tool = tool,
            .cmd_patterns = try cmd_patterns.toOwnedSlice(allocator),
            .action = action,
            .message = message,
        });
    }

    return rules.toOwnedSlice(allocator);
}

fn freePermissions(allocator: std.mem.Allocator, rules: []const PermissionRule) void {
    for (rules) |rule| {
        allocator.free(rule.tool);
        for (rule.cmd_patterns) |pattern| allocator.free(pattern);
        if (rule.cmd_patterns.len > 0) allocator.free(rule.cmd_patterns);
        if (rule.message) |message| allocator.free(message);
    }
    if (rules.len > 0) allocator.free(rules);
}
