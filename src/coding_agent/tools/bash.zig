const builtin = @import("builtin");
const std = @import("std");
const protocol = @import("../../agent/types.zig");
const json_util = @import("../../ai/json_util.zig");
const tool_def = @import("definition.zig");
const util = @import("util.zig");
const output_buffer = @import("output_buffer.zig");
const runtime_process = @import("../../zio/root.zig").process;
const lock_registry = @import("lock_registry.zig");

const HEAD_LINES: usize = 0;
const TAIL_LINES: usize = 2000;
const MAX_VISIBLE_BYTES: usize = 50 * 1024;
const MAX_ROLLING_BYTES: usize = MAX_VISIBLE_BYTES * 2;
const MAX_LINE_BYTES: usize = 50 * 1024;
const TRUNCATED_FMT = "... [{d} lines truncated] ...";
const STREAM_UPDATE_MIN_INTERVAL_MS: u64 = 500;

const bash_schema =
    \\{"type":"object","properties":{"cmd":{"type":"string","description":"The shell command to execute."},"cwd":{"type":"string","description":"Working directory for the command (absolute path). Defaults to workspace root."},"timeout":{"type":"number","description":"Timeout in seconds."}},"required":["cmd"]}
;

const DESCRIPTION =
    "Executes the given shell command using bash.\n\n" ++
    "- Do NOT chain commands with `;` or `&&` or use `&` for background processes; make separate tool calls instead\n" ++
    "- Do NOT use interactive commands (REPLs, editors, password prompts)\n" ++
    "- Output is truncated to the last 2000 lines or 50KB, whichever is hit first; large output is saved to a temp file\n" ++
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

    std.Io.Dir.accessAbsolute(ctx.io, effective_cwd, .{}) catch {
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
        return runCommand(allocator, ctx.io, final_command, effective_cwd, extractTimeout(args), signal, on_update, update_ctx);
    }

    return runCommand(allocator, ctx.io, final_command, effective_cwd, extractTimeout(args), signal, on_update, update_ctx);
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    cwd: []const u8,
    timeout_secs: ?u64,
    signal: protocol.AbortSignal,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolResult {
    const io_allocator = std.heap.smp_allocator;

    const shell_argv: []const []const u8 = if (std.Io.Dir.accessAbsolute(io, "/bin/bash", .{}))
        &.{ "/bin/bash", "-c", command }
    else |_|
        &.{ "/bin/sh", "-c", command };

    var capture = StreamingCapture.init(io_allocator, io);
    defer capture.deinit();
    var callback_ctx = BashChunkCtx{
        .allocator = allocator,
        .io = io,
        .capture = &capture,
        .command = command,
        .cb = on_update,
        .update_ctx = update_ctx,
    };

    var proc_result = runtime_process.run(allocator, io, .{
        .argv = shell_argv,
        .cwd = cwd,
        .timeout_ms = if (timeout_secs) |secs| secs * std.time.ms_per_s else null,
        .signal = signal,
        .capture_stdout = false,
        .capture_stderr = false,
        .on_chunk = .{ .ctx = @ptrCast(&callback_ctx), .func = &BashChunkCtx.onChunk },
    });
    defer proc_result.deinit(allocator);
    callback_ctx.emitFinal();

    if (proc_result == .err) {
        return util.errorf(allocator, "command error: {s}", .{proc_result.err.message});
    }

    const completed = CompletedOutput{ .output_text = capture.finishText(allocator) catch allocator.dupe(u8, "") catch &.{} };
    defer if (completed.output_text.len > 0) allocator.free(completed.output_text);

    const did_timeout = proc_result == .timeout;
    const term: ?std.process.Child.Term = switch (proc_result) {
        .completed => |completed_result| completed_result.term,
        .timeout => null,
        .err => null,
    };

    const result_text = formatCommandTranscript(allocator, command, completed.output_text) catch
        return util.errorResult(allocator, "bash tool: alloc failed");
    defer allocator.free(result_text);

    if (signal.isAborted()) {
        const aborted = appendTail(allocator, result_text, "\n\ncommand aborted") catch result_text;
        defer if (aborted.ptr != result_text.ptr) allocator.free(aborted);
        return .{ .content = oneText(allocator, aborted), .is_error = true };
    }

    if (did_timeout) {
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
        .exited => |code| {
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

const CompletedOutput = struct {
    output_text: []u8 = &.{},
};

const BashChunkCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    capture: *StreamingCapture,
    command: []const u8,
    cb: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
    mutex: std.Io.Mutex = .init,
    last_emit_ns: i128 = 0,
    last_emitted_hash: ?u64 = null,

    fn onChunk(raw_ctx: ?*anyopaque, _: runtime_process.StreamKind, bytes: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.capture.append(bytes);
        const cb = self.cb orelse return;
        const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(self.io, .awake).toNanoseconds()));
        if (self.last_emit_ns != 0 and now_ns - self.last_emit_ns < STREAM_UPDATE_MIN_INTERVAL_MS * std.time.ns_per_ms) return;
        if (self.capture.takeDirtySnapshot(self.allocator)) |snapshot| {
            defer if (snapshot.len > 0) self.allocator.free(snapshot);
            if (emitPartialTranscriptUpdate(self.allocator, self.command, snapshot, cb, self.update_ctx, self.last_emitted_hash)) |new_hash| {
                self.last_emitted_hash = new_hash;
                self.last_emit_ns = now_ns;
            }
        }
    }

    fn emitFinal(self: *@This()) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const cb = self.cb orelse return;
        if (self.capture.takeDirtySnapshot(self.allocator)) |snapshot| {
            defer if (snapshot.len > 0) self.allocator.free(snapshot);
            if (emitPartialTranscriptUpdate(self.allocator, self.command, snapshot, cb, self.update_ctx, self.last_emitted_hash)) |new_hash| {
                self.last_emitted_hash = new_hash;
            }
        }
    }
};

const StreamingCapture = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    output: output_buffer.LineOutputBuffer,
    total_bytes: usize = 0,
    full_output_path: ?[]u8 = null,
    full_output_file: ?std.Io.File = null,
    dirty: bool = false,

    fn init(allocator: std.mem.Allocator, io: std.Io) StreamingCapture {
        return .{
            .io = io,
            .output = blk: {
                var buf = output_buffer.LineOutputBuffer.init(allocator, HEAD_LINES, TAIL_LINES);
                buf.max_line_bytes = MAX_LINE_BYTES;
                buf.max_tail_bytes = MAX_ROLLING_BYTES;
                break :blk buf;
            },
        };
    }

    fn deinit(self: *StreamingCapture) void {
        if (self.full_output_file) |file| file.close(self.io);
        if (self.full_output_path) |path| {
            if (self.total_bytes <= MAX_VISIBLE_BYTES) std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};
            self.output.allocator.free(path);
        }
        self.output.deinit();
    }

    fn append(self: *StreamingCapture, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.total_bytes += bytes.len;
        self.writeFullOutput(bytes);
        self.output.addChunk(bytes) catch return;
        self.dirty = true;
    }

    fn writeFullOutput(self: *StreamingCapture, bytes: []const u8) void {
        if (self.full_output_file == null) {
            const path = std.fmt.allocPrint(
                self.output.allocator,
                "/tmp/zi-bash-{d}.log",
                .{@as(i128, @intCast(std.Io.Timestamp.now(self.io, .awake).toNanoseconds()))},
            ) catch return;
            const file = std.Io.Dir.createFileAbsolute(self.io, path, .{ .truncate = true }) catch {
                self.output.allocator.free(path);
                return;
            };
            self.full_output_path = path;
            self.full_output_file = file;
        }
        if (self.full_output_file) |file| file.writeStreamingAll(self.io, bytes) catch {};
    }

    fn takeDirtySnapshot(self: *StreamingCapture, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.dirty) return null;
        self.dirty = false;
        const snapshot = self.output.snapshotAlloc(allocator, TRUNCATED_FMT) catch return null;
        return capVisibleOutput(allocator, snapshot.text, snapshot.truncated_lines) catch snapshot.text;
    }

    fn finishText(self: *StreamingCapture, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const final = try self.output.finishAlloc(allocator, TRUNCATED_FMT);
        var text = try capVisibleOutput(allocator, final.text, final.truncated_lines);
        if (self.total_bytes > MAX_VISIBLE_BYTES) {
            text = try appendFullOutputNotice(allocator, text, self.full_output_path, self.total_bytes);
        }
        return text;
    }
};

fn appendFullOutputNotice(allocator: std.mem.Allocator, text: []u8, path: ?[]const u8, total_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text);
    if (path) |p| {
        const notice = try std.fmt.allocPrint(allocator, "\n\n[Full output: {s}. Total output: {d} bytes]", .{ p, total_bytes });
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    } else {
        const notice = try std.fmt.allocPrint(allocator, "\n\n[Output truncated. Total output: {d} bytes]", .{total_bytes});
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    }
    allocator.free(text);
    return out.toOwnedSlice(allocator);
}

fn capVisibleOutput(allocator: std.mem.Allocator, text: []u8, truncated_lines: usize) ![]u8 {
    if (text.len <= MAX_VISIBLE_BYTES) return text;

    const keep_budget = MAX_VISIBLE_BYTES -| 256;
    var start = text.len - @min(text.len, keep_budget);
    if (std.mem.indexOfScalar(u8, text[start..], '\n')) |newline_offset| {
        start += newline_offset + 1;
    }

    const marker = try std.fmt.allocPrint(
        allocator,
        "... [output truncated to last {d}KB; {d} earlier lines omitted] ...\n\n",
        .{ MAX_VISIBLE_BYTES / 1024, truncated_lines },
    );
    defer allocator.free(marker);

    var capped = std.ArrayList(u8).empty;
    errdefer capped.deinit(allocator);
    try capped.appendSlice(allocator, marker);
    try capped.appendSlice(allocator, text[start..]);
    allocator.free(text);
    return capped.toOwnedSlice(allocator);
}

fn expectTextBlockContains(result: protocol.AgentToolResult, needle_text: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(result.content[0] == .text);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, needle_text) != null);
}

test "command preprocessing is explicit about cd, background, and git trailers" {
    try std.testing.expectEqualStrings("sleep 1", stripBackground("sleep 1 &  "));
    try std.testing.expectEqualStrings("printf '&'", stripBackground("printf '&'"));

    const cd_split = splitCdCommand(" cd '/tmp/my dir' && printf ok ") orelse return error.ExpectedCdSplit;
    try std.testing.expectEqualStrings("/tmp/my dir", cd_split.cwd);
    try std.testing.expectEqualStrings("printf ok", cd_split.command);

    const injected = try injectGitTrailers(std.testing.allocator, "git commit -m hi", "session-123");
    defer std.testing.allocator.free(injected);
    try std.testing.expectEqualStrings("git commit --trailer \"Session-Id: session-123\" -m hi", injected);
}

test "permission evaluation uses the first matching Bash rule" {
    const reject_patterns = [_][]const u8{"rm *"};
    const rules = [_]PermissionRule{
        .{ .tool = "Read", .action = .reject },
        .{ .tool = "Bash", .cmd_patterns = &reject_patterns, .action = .reject, .message = "too destructive" },
        .{ .tool = "Bash", .action = .allow },
    };

    const rejected = evaluatePermission("rm -rf tmp", &rules);
    try std.testing.expectEqual(PermissionAction.reject, rejected.action);
    try std.testing.expectEqualStrings("too destructive", rejected.message.?);

    const allowed = evaluatePermission("printf safe", &rules);
    try std.testing.expectEqual(PermissionAction.allow, allowed.action);
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

test "runCommand handles concurrent mixed output without assuming cross-stream order" {
    const testing = std.testing;
    const cmd =
        \\i=0
        \\while [ "$i" -lt 1200 ]; do
        \\  printf 'out%04d\n' "$i"
        \\  printf 'err%04d\n' "$i" 1>&2
        \\  i=$((i + 1))
        \\done
    ;

    var iteration: usize = 0;
    while (iteration < 32) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const result = runCommand(arena.allocator(), std.Options.debug_io, cmd, "/tmp", 5, protocol.AbortSignal.none, null, null);

        try testing.expect(!result.is_error);
        try expectTextBlockContains(result, "out");
        try expectTextBlockContains(result, "err");
        try expectTextBlockContains(result, "lines truncated");
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
        std.Options.debug_io,
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
    try expectTextBlockContains(result, "second");
}

test "runCommand abort kills the spawned process group, not just the shell pid" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const testing = std.testing;
    const abort_signal = @import("../../zio/root.zig").abort;
    const pid_file = try std.fmt.allocPrint(testing.allocator, "/tmp/zi-bash-abort-{d}.pid", .{@as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()))});
    defer testing.allocator.free(pid_file);
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, pid_file) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, pid_file) catch {};

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
            std.Options.debug_io.sleep(.fromNanoseconds(@intCast(100 * std.time.ns_per_ms)), .awake) catch {};
            c.requestAbort();
        }
    };
    const aborter = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer aborter.join();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = runCommand(arena.allocator(), std.Options.debug_io, cmd, "/tmp", 5, signal, null, null);

    try testing.expect(result.is_error);
    try expectTextBlockContains(result, "command aborted");

    var file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, pid_file, .{});
    defer file.close(std.Options.debug_io);
    var read_buf: [64]u8 = undefined;
    var reader = file.reader(std.Options.debug_io, &read_buf);
    const pid_text = try reader.interface.allocRemaining(testing.allocator, .limited(64));
    defer testing.allocator.free(pid_text);
    const child_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \r\n\t"), 10);

    const deadline_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() + 1_000;
    while (true) {
        std.posix.kill(child_pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        if (std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() >= deadline_ms) {
            return error.TestUnexpectedBackgroundChildStillRunning;
        }
        std.Options.debug_io.sleep(.fromNanoseconds(@intCast(50 * std.time.ns_per_ms)), .awake) catch {};
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
    const trimmed = std.mem.trimEnd(u8, cmd, &std.ascii.whitespace);
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '&') {
        return std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], &std.ascii.whitespace);
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
    const home = @import("env").get("HOME") orelse return &.{};
    const permissions_path = try std.fs.path.join(allocator, &.{ home, ".pi", "agent", "permissions.json" });
    defer allocator.free(permissions_path);

    const raw = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, permissions_path, allocator, .limited(1024 * 1024)) catch return &.{};
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
