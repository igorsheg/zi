/// ziSpawn — spawn a child zi process in --mode json, parse JSONL events,
/// collect the last assistant text output and usage stats.
///
/// Zig equivalent of piSpawn() in pi-spawn.ts.
/// Reads stdout line-by-line, parses each as a JSON agent event.
/// On "message_end" with role=="assistant": extracts text, accumulates usage.
/// stderr is collected after stdout EOF.
const std = @import("std");
const types = @import("types.zig");
const runtime_process = @import("../zio/root.zig").process;

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
    const trace_file: ?std.Io.File = openTraceFile(config.io);
    defer if (trace_file) |f| f.close(config.io);

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
        if (tmp_file_path) |p| std.Io.Dir.deleteFileAbsolute(config.io, p) catch {};
        if (tmp_dir_path) |d| std.Io.Dir.deleteDirAbsolute(config.io, d) catch {};
    }
    if (config.argv_override == null) {
        if (config.append_system_prompt) |asp| {
            if (writeTempPrompt(config.io, allocator, asp)) |tmp| {
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

    if (trace_file) |f| {
        traceWrite(config.io, f, "--- spawn START task=\"{s}\"\n", .{config.task});
        traceWrite(config.io, f, "    argv:", .{});
        for (built.argv.items) |a| traceWrite(config.io, f, " {s}", .{a});
        traceWrite(config.io, f, "\n", .{});
    }

    var line_ctx = JsonlCtx{
        .allocator = allocator,
        .config = config,
        .result = &result,
        .trace_file = trace_file,
    };

    var proc_result = runtime_process.run(allocator, config.io, .{
        .argv = built.argv.items,
        .cwd = config.cwd,
        .signal = config.signal,
        .max_stdout_bytes = 0,
        .capture_stdout = false,
        .max_stderr_bytes = 1024 * 1024,
        .on_chunk = .{ .ctx = @ptrCast(&line_ctx), .func = &JsonlCtx.onChunk },
        .on_wait = if (config.on_wait) |cb| .{ .ctx = config.on_wait_ctx, .func = cb } else null,
    });
    defer proc_result.deinit(allocator);
    line_ctx.flushTail();

    switch (proc_result) {
        .completed => |completed| {
            result.exit_code = switch (completed.term) {
                .exited => |code| code,
                else => 1,
            };
            result.stderr_output.appendSlice(allocator, completed.stderr) catch {};
        },
        .timeout => |timeout| {
            result.exit_code = 1;
            result.stderr_output.appendSlice(allocator, timeout.stderr) catch {};
            result.error_message = allocator.dupe(u8, timeout.message) catch null;
        },
        .err => |err| {
            result.exit_code = 1;
            result.error_message = allocator.dupe(u8, err.message) catch null;
            if (trace_file) |f| traceWrite(config.io, f, "--- spawn FAILED to launch: {s}\n", .{err.message});
            return result;
        },
    }

    if (config.signal) |sig| {
        if (sig.isAborted()) result.cancelled = true;
    }

    if (trace_file) |f| {
        if (result.stderr_output.items.len > 0) {
            traceWrite(config.io, f, "--- stderr ({d} bytes):\n", .{result.stderr_output.items.len});
            var trace_buf: [4096]u8 = undefined;
            var trace_writer = f.writer(config.io, &trace_buf);
            trace_writer.interface.writeAll(result.stderr_output.items) catch {};
            trace_writer.interface.flush() catch {};
            traceWrite(config.io, f, "\n", .{});
        }
    }

    // normalize: processes killed after end_turn are intentional
    if (result.exit_code != 0) {
        if (result.stop_reason) |sr| {
            if (std.mem.eql(u8, sr, "stop") or std.mem.eql(u8, sr, "end_turn")) {
                result.exit_code = 0;
            }
        }
    }

    if (trace_file) |f| {
        traceWrite(config.io, f, "--- spawn END exit={d} stop_reason={?s} final_text_len={d}\n", .{
            result.exit_code,
            result.stop_reason,
            result.output.items.len,
        });
        traceWrite(config.io, f, "--- /spawn ---\n\n", .{});
    }

    return result;
}

// -- stdout processing --

const JsonlCtx = struct {
    allocator: std.mem.Allocator,
    config: types.SpawnConfig,
    result: *types.SpawnResult,
    trace_file: ?std.Io.File,
    line_buf: std.ArrayList(u8) = .empty,
    mutex: std.Io.Mutex = .init,

    fn onChunk(raw_ctx: ?*anyopaque, kind: runtime_process.StreamKind, bytes: []const u8) void {
        if (kind != .stdout) return;
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);
        self.feed(bytes);
    }

    fn feed(self: *@This(), chunk: []const u8) void {
        var start: usize = 0;
        for (0..chunk.len) |i| {
            if (chunk[i] == '\n') {
                const segment = chunk[start..i];
                if (self.line_buf.items.len > 0) {
                    self.line_buf.appendSlice(self.allocator, segment) catch {};
                    self.emitLine(self.line_buf.items);
                    self.line_buf.clearRetainingCapacity();
                } else {
                    self.emitLine(segment);
                }
                start = i + 1;
            }
        }
        if (start < chunk.len) self.line_buf.appendSlice(self.allocator, chunk[start..]) catch {};
    }

    fn flushTail(self: *@This()) void {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);
        defer self.line_buf.deinit(self.allocator);
        if (self.line_buf.items.len > 0) {
            self.emitLine(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
    }

    fn emitLine(self: *@This(), line: []const u8) void {
        if (self.trace_file) |f| traceLine(self.config.io, f, line);
        processLine(line, self.result, self.config);
    }
};

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

// -- trace file --

/// Open the file referenced by `ZI_SPAWN_TRACE` for append. Returns
/// null if the env var is unset, the path is invalid, or the file
/// can't be opened. All trace operations are best-effort: failures
/// silently disable tracing for the rest of this spawn.
fn openTraceFile(io: std.Io) ?std.Io.File {
    const path = @import("env").get("ZI_SPAWN_TRACE") orelse return null;
    if (path.len == 0) return null;
    return std.Io.Dir.cwd().createFile(io, path, .{
        .read = false,
        .truncate = false,
    }) catch return null;
}

fn traceWrite(io: std.Io, f: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    // Seek to end first so concurrent spawns don't clobber each
    // other. Append mode would be cleaner but createFile doesn't
    // expose O_APPEND directly; this is good enough for v1 since
    // we don't expect interleaved writes within a record.
    var buf: [4096]u8 = undefined;
    var writer = f.writer(io, &buf);
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch {};
}

fn traceLine(io: std.Io, f: std.Io.File, line: []const u8) void {
    var buf: [4096]u8 = undefined;
    var writer = f.writer(io, &buf);
    writer.interface.writeAll("    ") catch return;
    writer.interface.writeAll(line) catch return;
    writer.interface.writeAll("\n") catch return;
    writer.interface.flush() catch {};
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
    const self_exe_len = try std.process.executablePath(config.io, &self_exe_buf);
    const self_exe = self_exe_buf[0..self_exe_len];
    const self_exe_owned = try allocator.dupe(u8, self_exe);
    try built.owned_strings.append(allocator, self_exe_owned);

    try built.argv.appendSlice(allocator, &.{ self_exe_owned, "--mode", "json", "--no-session" });
    if (config.model) |m| {
        try built.argv.appendSlice(allocator, &.{ "--model", m });
    }
    if (config.tools) |t| {
        try built.argv.appendSlice(allocator, &.{ "--tools", t });
    }
    return built;
}

const TempFile = struct { dir: []const u8, path: []const u8 };

fn writeTempPrompt(io: std.Io, allocator: std.mem.Allocator, content: []const u8) !TempFile {
    var rand_buf: [8]u8 = undefined;
    io.randomSecure(&rand_buf) catch io.random(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const dir_name = try std.fmt.allocPrint(allocator, "/tmp/zi-spawn-{s}", .{&hex});
    try std.Io.Dir.cwd().createDirPath(io, dir_name);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/prompt.md", .{dir_name});
    errdefer allocator.free(file_path);

    const file = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o600));
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    try file_writer.interface.writeAll(content);
    try file_writer.interface.flush();

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
    try testing.expect(built.argv.items.len >= 8);
    try testing.expectEqualStrings("--mode", built.argv.items[1]);
    try testing.expectEqualStrings("json", built.argv.items[2]);
    try testing.expectEqualStrings("--no-session", built.argv.items[3]);
    try testing.expectEqualStrings("--model", built.argv.items[4]);
    try testing.expectEqualStrings("claude-sonnet-4-5", built.argv.items[5]);
    try testing.expectEqualStrings("--tools", built.argv.items[6]);
    try testing.expectEqualStrings("bash,read", built.argv.items[7]);
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
    var controller = @import("../zio/root.zig").AbortController{};
    const signal = controller.beginRun();

    const Aborter = struct {
        fn run(c: *@import("../zio/root.zig").AbortController) void {
            std.Options.debug_io.sleep(.fromNanoseconds(@intCast(100 * std.time.ns_per_ms)), .awake) catch {};
            c.requestAbort();
        }
    };
    const t = try std.Thread.spawn(.{}, Aborter.run, .{&controller});
    defer t.join();

    const start = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    var result = ziSpawn(.{
        .allocator = testing.allocator,
        .cwd = ".",
        .task = "unused",
        .argv_override = &override,
        .signal = signal,
    });
    defer result.deinit(testing.allocator);
    const elapsed_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - start;

    // Watchdog poll cadence is 100ms; killing + wait adds a little
    // overhead. 2s gives a generous ceiling that still proves we
    // didn't sit through the 30s sleep.
    try testing.expect(elapsed_ms < 2000);
    try testing.expect(result.exit_code != 0);
    try testing.expect(result.cancelled);
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
