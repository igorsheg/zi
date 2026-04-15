/// ziSpawn — spawn a child zi process in --mode json, parse JSONL events,
/// collect the last assistant text output and usage stats.
///
/// Zig equivalent of piSpawn() in pi-spawn.ts.
/// Reads stdout line-by-line, parses each as a JSON agent event.
/// On "message_end" with role=="assistant": extracts text, accumulates usage.
/// stderr is collected after stdout EOF.
const builtin = @import("builtin");
const std = @import("std");
const types = @import("types.zig");

const log = std.log.scoped(.zi_spawn);

pub fn ziSpawn(config: types.SpawnConfig) types.SpawnResult {
    var result = types.SpawnResult.init();
    const allocator = config.allocator;

    // -- optional trace file --
    //
    // When `ZI_SPAWN_TRACE` is set, ziSpawn appends a framed
    // record of every spawn to that file. Each record contains
    // lifecycle markers, the full argv, every JSONL event the
    // child emits, the captured stderr block, and the exit code.
    //
    // Multi-spawn safe: each record is framed with `--- spawn ---`
    // and `--- /spawn ---` markers, and writes are append-mode so
    // concurrent parents on the same file interleave at record
    // boundaries (the OS append guarantee covers our small writes).
    //
    // Run `tail -f $ZI_SPAWN_TRACE` in another terminal during a
    // hang to see what the child is doing in real time.
    const trace_file: ?std.fs.File = openTraceFile();
    defer if (trace_file) |f| f.close();

    // -- build argv --
    //
    // Production: self-exe + --mode json + flags + "Task: <task>".
    // Test: caller supplies `argv_override` and we run that verbatim.
    var built = buildChildArgv(allocator, config) catch {
        result.exit_code = 1;
        result.error_message = allocator.dupe(u8, "failed to build child argv") catch null;
        return result;
    };
    defer built.deinit(allocator);

    // -- temp file for append-system-prompt --
    // (only relevant when not overriding argv; the override path
    //  doesn't touch system prompts)
    var tmp_dir_path: ?[]const u8 = null;
    var tmp_file_path: ?[]const u8 = null;
    defer {
        if (tmp_file_path) |p| std.fs.deleteFileAbsolute(p) catch {};
        if (tmp_dir_path) |d| std.fs.deleteDirAbsolute(d) catch {};
    }
    if (config.argv_override == null) {
        if (config.append_system_prompt) |asp| {
            if (writeTempPrompt(allocator, asp)) |tmp| {
                tmp_dir_path = tmp.dir;
                tmp_file_path = tmp.path;
                built.argv.appendSlice(allocator, &.{ "--append-system-prompt", tmp.path }) catch {};
            } else |_| {}
        }
        // task as positional arg (pi-spawn convention prepends "Task: ")
        const task_arg = std.fmt.allocPrint(allocator, "Task: {s}", .{config.task}) catch {
            result.exit_code = 1;
            return result;
        };
        built.owned_strings.append(allocator, task_arg) catch {
            allocator.free(task_arg);
            result.exit_code = 1;
            return result;
        };
        built.argv.append(allocator, task_arg) catch {};
    }

    // -- spawn --
    var child = std.process.Child.init(built.argv.items, allocator);
    child.cwd = config.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        child.pgid = 0;
    }

    child.spawn() catch {
        result.exit_code = 1;
        result.error_message = allocator.dupe(u8, "failed to spawn zi process") catch null;
        if (trace_file) |f| traceWrite(f, "--- spawn FAILED to launch\n", .{});
        return result;
    };

    if (trace_file) |f| {
        traceWrite(f, "--- spawn START pid={d} task=\"{s}\"\n", .{ child.id, config.task });
        traceWrite(f, "    argv:", .{});
        for (built.argv.items) |a| traceWrite(f, " {s}", .{a});
        traceWrite(f, "\n", .{});
    }

    // -- read stdout line by line, parse events --
    //
    // A watchdog thread (spawned only when there is a signal to watch
    // and a stdout pipe to shut down) blocks on the abort signal. On
    // abort it `shutdown()`s the stdout fd, which unblocks the
    // parent's blocking `read()` mid-call, and interrupts the child
    // process group for good measure. The main thread sees the abort flag on
    // its next iteration and breaks the loop. Without this, a quiet
    // child (long LLM call, sleep) would never observe the abort
    // until it next wrote to stdout.
    var watchdog_done = std.atomic.Value(bool).init(false);
    var watchdog_thread: ?std.Thread = null;
    if (config.signal) |sig| {
        if (child.stdout) |stdout_file| {
            const ctx = WatchdogCtx{
                .signal = sig,
                .stdout_fd = stdout_file.handle,
                .child = &child,
                .done = &watchdog_done,
            };
            watchdog_thread = std.Thread.spawn(.{}, abortWatchdog, .{ctx}) catch null;
        }
    }
    defer {
        // Tell the watchdog to exit BEFORE we touch child.wait() or
        // close pipes; then join so we know the watchdog is no
        // longer poking the fd or the child handle.
        watchdog_done.store(true, .release);
        if (config.signal) |sig| sig.notifyWaiters();
        if (watchdog_thread) |t| t.join();
    }

    readAndProcess(&child, &result, config, trace_file);

    // -- collect stderr (small, buffered by OS pipe) --
    // NOTE: sequential drain after stdout EOF. safe as long as stderr < 64KB
    // (OS pipe buffer). zi sub-agents produce small stderr. if this assumption
    // breaks, switch to two threads or std.Io.poll.
    if (child.stderr) |stderr_file| {
        var stderr_buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr_file.read(&stderr_buf) catch break;
            if (n == 0) break;
            result.stderr_output.appendSlice(allocator, stderr_buf[0..n]) catch break;
        }
    }
    if (trace_file) |f| {
        if (result.stderr_output.items.len > 0) {
            traceWrite(f, "--- stderr ({d} bytes):\n", .{result.stderr_output.items.len});
            f.writeAll(result.stderr_output.items) catch {};
            traceWrite(f, "\n", .{});
        }
    }

    // -- wait for exit --
    const term = child.wait() catch {
        result.exit_code = 1;
        return result;
    };
    result.exit_code = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    // normalize: processes killed after end_turn are intentional
    if (result.exit_code != 0) {
        if (result.stop_reason) |sr| {
            if (std.mem.eql(u8, sr, "stop") or std.mem.eql(u8, sr, "end_turn")) {
                result.exit_code = 0;
            }
        }
    }

    if (trace_file) |f| {
        traceWrite(f, "--- spawn END exit={d} stop_reason={?s} final_text_len={d}\n", .{
            result.exit_code,
            result.stop_reason,
            result.output.items.len,
        });
        traceWrite(f, "--- /spawn ---\n\n", .{});
    }

    return result;
}

// -- stdout processing --

fn readAndProcess(child: *std.process.Child, result: *types.SpawnResult, config: types.SpawnConfig, trace_file: ?std.fs.File) void {
    const allocator = config.allocator;
    const stdout_file = child.stdout orelse return;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var read_buf: [8192]u8 = undefined;

    while (true) {
        // The watchdog (started by ziSpawn when there's a signal)
        // is the only one allowed to send SIGKILL — it does so via
        // raw posix.kill so it doesn't reap the child. We must not
        // call std.process.Child.kill here because that internally
        // waitpids and would race the main wait() at the end.
        if (config.signal) |sig| {
            if (sig.isAborted()) break;
        }

        const n = stdout_file.read(&read_buf) catch break;
        if (n == 0) break;

        var start: usize = 0;
        for (0..n) |i| {
            if (read_buf[i] == '\n') {
                const segment = read_buf[start..i];
                if (line_buf.items.len > 0) {
                    line_buf.appendSlice(allocator, segment) catch {};
                    if (trace_file) |f| traceLine(f, line_buf.items);
                    processLine(line_buf.items, result, config);
                    line_buf.clearRetainingCapacity();
                } else {
                    if (trace_file) |f| traceLine(f, segment);
                    processLine(segment, result, config);
                }
                start = i + 1;
            }
        }

        if (start < n) {
            line_buf.appendSlice(allocator, read_buf[start..n]) catch {};
        }
    }

    // flush any trailing data without a final newline
    if (line_buf.items.len > 0) {
        if (trace_file) |f| traceLine(f, line_buf.items);
        processLine(line_buf.items, result, config);
    }
}

fn processLine(line: []const u8, result: *types.SpawnResult, config: types.SpawnConfig) void {
    if (line.len == 0) return;
    const allocator = config.allocator;

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        line,
        .{ .allocate = .alloc_always },
    ) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const type_val = obj.get("type") orelse return;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return,
    };

    // Fire user observer FIRST, with the raw event. The callback
    // sees every JSONL line the child emits, not just message_end.
    // Lifetime contract: `parsed.value` is only valid for this call;
    // the callback must copy out anything it wants to retain. The
    // Lua trampoline does that via pushJsonValue, which deep-copies.
    if (config.on_event) |cb| {
        cb(type_str, parsed.value, config.on_event_ctx);
    }

    if (!std.mem.eql(u8, type_str, "message_end")) return;

    const msg_val = obj.get("message") orelse return;
    const msg_obj = switch (msg_val) {
        .object => |o| o,
        else => return,
    };

    const role_val = msg_obj.get("role") orelse return;
    const role = switch (role_val) {
        .string => |s| s,
        else => return,
    };

    if (!std.mem.eql(u8, role, "assistant")) return;

    result.usage.turns += 1;

    // extract text content (last assistant message's text wins)
    if (msg_obj.get("content")) |content_val| {
        switch (content_val) {
            .array => |arr| {
                for (arr.items) |block| {
                    const block_obj = switch (block) {
                        .object => |o| o,
                        else => continue,
                    };
                    const block_type = switch (block_obj.get("type") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, block_type, "text")) {
                        const text_val = block_obj.get("text") orelse continue;
                        switch (text_val) {
                            .string => |s| {
                                result.output.clearRetainingCapacity();
                                result.output.appendSlice(allocator, s) catch {};
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }

    // accumulate usage
    if (msg_obj.get("usage")) |usage_val| {
        switch (usage_val) {
            .object => |u| {
                result.usage.input += jsonToU64(u.get("input"));
                result.usage.output += jsonToU64(u.get("output"));
                result.usage.cache_read += jsonToU64(u.get("cacheRead"));
                result.usage.cache_write += jsonToU64(u.get("cacheWrite"));
                result.usage.context_tokens = jsonToU64(u.get("totalTokens"));

                if (u.get("cost")) |cost_val| {
                    switch (cost_val) {
                        .object => |c| {
                            result.usage.cost += jsonToF64(c.get("total"));
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    // model (first one wins, matching pi-spawn)
    if (result.model == null) {
        if (msg_obj.get("model")) |m| {
            switch (m) {
                .string => |s| {
                    result.model = allocator.dupe(u8, s) catch null;
                },
                else => {},
            }
        }
    }

    // stopReason (latest wins)
    if (msg_obj.get("stopReason")) |sr| {
        switch (sr) {
            .string => |s| {
                if (result.stop_reason) |old| allocator.free(old);
                result.stop_reason = allocator.dupe(u8, s) catch null;
            },
            else => {},
        }
    }

    // errorMessage
    if (msg_obj.get("errorMessage")) |em| {
        switch (em) {
            .string => |s| {
                if (result.error_message) |old| allocator.free(old);
                result.error_message = allocator.dupe(u8, s) catch null;
            },
            else => {},
        }
    }
}

// -- helpers --

fn jsonToU64(val: ?std.json.Value) u64 {
    const v = val orelse return 0;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn jsonToF64(val: ?std.json.Value) f64 {
    const v = val orelse return 0;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

fn killChild(child: *std.process.Child) void {
    _ = child.kill() catch {};
}

// -- trace file --

/// Open the file referenced by `ZI_SPAWN_TRACE` for append. Returns
/// null if the env var is unset, the path is invalid, or the file
/// can't be opened. All trace operations are best-effort: failures
/// silently disable tracing for the rest of this spawn.
fn openTraceFile() ?std.fs.File {
    const path = std.posix.getenv("ZI_SPAWN_TRACE") orelse return null;
    if (path.len == 0) return null;
    return std.fs.cwd().createFile(path, .{
        .read = false,
        .truncate = false,
    }) catch return null;
}

fn traceWrite(f: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    // Seek to end first so concurrent spawns don't clobber each
    // other. Append mode would be cleaner but createFile doesn't
    // expose O_APPEND directly; this is good enough for v1 since
    // we don't expect interleaved writes within a record.
    f.seekFromEnd(0) catch {};
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    f.writeAll(slice) catch {};
}

fn traceLine(f: std.fs.File, line: []const u8) void {
    f.seekFromEnd(0) catch {};
    f.writeAll("    ") catch {};
    f.writeAll(line) catch {};
    f.writeAll("\n") catch {};
}

const WatchdogCtx = struct {
    signal: @import("../abort_signal.zig").AbortSignal,
    stdout_fd: std.posix.fd_t,
    child: *std.process.Child,
    /// Set true by the main thread when readAndProcess returns,
    /// telling the watchdog to exit BEFORE we move on to wait()
    /// and pipe cleanup. Acquire fence ensures the watchdog sees
    /// the main thread's write.
    done: *std.atomic.Value(bool),
};

/// Blocks on `signal`. On abort: shuts down the child's stdout fd
/// (unblocks the parent's blocking read) and interrupts the child
/// process group (in case it was sleeping or hung). Idempotent — the
/// main thread also observes the abort and stop paths tolerate
/// repeated signals.
///
/// Why shutdown(SHUT_RDWR) instead of close: req.deinit / pipe
/// cleanup on the main thread will close the fd later, and double
/// closing a fd is a use-after-free hazard. shutdown leaves the fd
/// valid but causes pending and future reads to return.
fn abortWatchdog(ctx: WatchdogCtx) void {
    switch (ctx.signal.waitUntil(null, &watchdogDone, @ptrCast(ctx.done))) {
        .aborted => {},
        .predicate, .timeout, .none => return,
    }
    if (ctx.done.load(.acquire)) return;

    const SHUT_RDWR = 2;
    _ = std.posix.system.shutdown(ctx.stdout_fd, SHUT_RDWR);
    // Use raw posix.kill, NOT std.process.Child.kill — the latter
    // reaps via waitpid internally, which would race the main
    // thread's `child.wait()` and crash with ECHILD. Sending the
    // signal directly leaves reaping to the main thread.
    interruptProcessGroup(ctx.child.id);
}

fn watchdogDone(ctx: ?*anyopaque) bool {
    const done: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
    return done.load(.acquire);
}

fn interruptProcessGroup(pgid: std.process.Child.Id) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        std.posix.kill(pgid, std.posix.SIG.KILL) catch {};
        return;
    }
    signalProcessGroup(pgid, std.posix.SIG.INT);
    std.Thread.sleep(150 * std.time.ns_per_ms);
    signalProcessGroup(pgid, std.posix.SIG.KILL);
}

fn signalProcessGroup(pgid: std.process.Child.Id, sig: u8) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        std.posix.kill(pgid, sig) catch {};
        return;
    }
    const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pgid));
    std.posix.kill(group_pid, sig) catch {};
}

// -- argv construction --
//
// Pulled out so tests can verify the production argv shape without
// actually spawning, and so the override path is a single early
// return rather than a fork in the middle of ziSpawn.

const BuiltArgv = struct {
    /// Argv slices passed to std.process.Child.init. Some entries
    /// borrow from `config` (model, tools), some are owned by
    /// `owned_strings`.
    argv: std.ArrayList([]const u8) = .empty,
    /// Strings whose lifetime must match `argv`. Freed in deinit.
    /// Used for the dup'd self-exe path and the "Task: <task>"
    /// formatted positional.
    owned_strings: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *BuiltArgv, allocator: std.mem.Allocator) void {
        for (self.owned_strings.items) |s| allocator.free(s);
        self.owned_strings.deinit(allocator);
        self.argv.deinit(allocator);
    }
};

fn buildChildArgv(allocator: std.mem.Allocator, config: types.SpawnConfig) !BuiltArgv {
    var built: BuiltArgv = .{};
    errdefer built.deinit(allocator);

    if (config.argv_override) |override| {
        try built.argv.appendSlice(allocator, override);
        return built;
    }

    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = try std.fs.selfExePath(&self_exe_buf);
    const self_exe_owned = try allocator.dupe(u8, self_exe);
    try built.owned_strings.append(allocator, self_exe_owned);

    try built.argv.appendSlice(allocator, &.{ self_exe_owned, "--mode", "json", "-p", "--no-session" });
    if (config.model) |m| {
        try built.argv.appendSlice(allocator, &.{ "--model", m });
    }
    if (config.tools) |t| {
        try built.argv.appendSlice(allocator, &.{ "--tools", t });
    }
    return built;
}

const TempFile = struct { dir: []const u8, path: []const u8 };

fn writeTempPrompt(allocator: std.mem.Allocator, content: []const u8) !TempFile {
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const dir_name = try std.fmt.allocPrint(allocator, "/tmp/zi-spawn-{s}", .{&hex});
    try std.fs.makeDirAbsolute(dir_name);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/prompt.md", .{dir_name});
    errdefer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(content);

    return .{ .dir = dir_name, .path = file_path };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "buildChildArgv produces expected production shape" {
    const cfg = types.SpawnConfig{
        .allocator = testing.allocator,
        .cwd = ".",
        .task = "ignored — task is appended later by ziSpawn proper",
        .model = "claude-sonnet-4-5",
        .tools = "bash,read",
    };
    var built = try buildChildArgv(testing.allocator, cfg);
    defer built.deinit(testing.allocator);

    // self-exe path is dynamic; assert flag layout from index 1 onward.
    try testing.expect(built.argv.items.len >= 9);
    try testing.expectEqualStrings("--mode", built.argv.items[1]);
    try testing.expectEqualStrings("json", built.argv.items[2]);
    try testing.expectEqualStrings("-p", built.argv.items[3]);
    try testing.expectEqualStrings("--no-session", built.argv.items[4]);
    try testing.expectEqualStrings("--model", built.argv.items[5]);
    try testing.expectEqualStrings("claude-sonnet-4-5", built.argv.items[6]);
    try testing.expectEqualStrings("--tools", built.argv.items[7]);
    try testing.expectEqualStrings("bash,read", built.argv.items[8]);
}

test "buildChildArgv argv_override bypasses self-exe construction" {
    const override = [_][]const u8{ "sh", "-c", "echo hi" };
    const cfg = types.SpawnConfig{
        .allocator = testing.allocator,
        .cwd = ".",
        .task = "unused",
        .argv_override = &override,
    };
    var built = try buildChildArgv(testing.allocator, cfg);
    defer built.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), built.argv.items.len);
    try testing.expectEqualStrings("sh", built.argv.items[0]);
    try testing.expectEqualStrings("echo hi", built.argv.items[2]);
    // No owned strings: override slices are borrowed from the caller.
    try testing.expectEqual(@as(usize, 0), built.owned_strings.items.len);
}

const TestEventCounter = struct {
    count: usize = 0,
    last_kind: [64]u8 = undefined,
    last_kind_len: usize = 0,

    fn cb(kind: []const u8, event: std.json.Value, ctx: ?*anyopaque) void {
        _ = event;
        const self: *TestEventCounter = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        const n = @min(kind.len, self.last_kind.len);
        @memcpy(self.last_kind[0..n], kind[0..n]);
        self.last_kind_len = n;
    }
};

test "ziSpawn watchdog aborts a quiet child within ~200ms" {
    // Child sleeps for 30s with no stdout output. Without the
    // watchdog, the parent's blocking read would also wait 30s.
    // We fire the abort signal from a side thread after 100ms and
    // assert ziSpawn returns promptly.
    const override = [_][]const u8{ "sh", "-c", "sleep 30" };
    var controller = @import("../abort_signal.zig").AbortController{};
    const signal = controller.beginRun();

    const Aborter = struct {
        fn run(c: *@import("../abort_signal.zig").AbortController) void {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            c.requestAbort();
        }
    };
    const t = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer t.join();

    const start = std.time.milliTimestamp();
    var result = ziSpawn(.{
        .allocator = testing.allocator,
        .cwd = ".",
        .task = "unused",
        .argv_override = &override,
        .signal = signal,
    });
    defer result.deinit(testing.allocator);
    const elapsed_ms = std.time.milliTimestamp() - start;

    // Watchdog poll cadence is 100ms; killing + wait adds a little
    // overhead. 2s gives a generous ceiling that still proves we
    // didn't sit through the 30s sleep.
    try testing.expect(elapsed_ms < 2000);
    try testing.expect(result.exit_code != 0);
}

test "ziSpawn fires on_event for each parsed JSONL line via argv_override" {
    // Print three JSONL events. The first is shape garbage to verify
    // we skip non-object/non-typed lines. The second is a valid
    // message_end so the built-in extractor also runs. The third is
    // an arbitrary type the extractor ignores but the callback sees.
    const script =
        \\printf '%s\n' '"not an object"'
        \\printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}'
        \\printf '%s\n' '{"type":"tool_execution_start","tool_call_id":"x"}'
    ;
    const override = [_][]const u8{ "sh", "-c", script };

    var counter = TestEventCounter{};

    const cfg = types.SpawnConfig{
        .allocator = testing.allocator,
        .cwd = ".",
        .task = "unused",
        .argv_override = &override,
        .on_event = &TestEventCounter.cb,
        .on_event_ctx = @ptrCast(&counter),
    };

    var result = ziSpawn(cfg);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), result.exit_code);
    // Two events parsed as objects with a `type` field; the bare
    // string line is dropped before the callback fires.
    try testing.expectEqual(@as(usize, 2), counter.count);
    // Built-in extractor saw the message_end → final_text populated.
    try testing.expectEqualStrings("hi", result.output.items);
}
