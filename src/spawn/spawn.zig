const std = @import("std");
const types = @import("types.zig");
const runtime_process = @import("../zio/root.zig").process;
const jsonl = @import("../json/root.zig").jsonl;

const log = std.log.scoped(.zi_spawn);

pub fn ziSpawn(config: types.SpawnConfig) types.SpawnResult {
    var result = types.SpawnResult.init();
    const allocator = config.allocator;

    const trace_file: ?std.Io.File = openTraceFile(config.io);
    defer if (trace_file) |f| f.close(config.io);

    var built = buildChildArgv(allocator, config) catch {
        result.exit_code = 1;
        result.error_message = allocator.dupe(u8, "failed to build child argv") catch null;
        return result;
    };
    defer built.deinit(allocator);

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
        .decoder = jsonl.Decoder.init(allocator, .{ .max_line_bytes = 16 * 1024 * 1024 }),
    };
    defer line_ctx.decoder.deinit();

    var proc_result = runtime_process.stream(allocator, config.io, .{
        .argv = built.argv.items,
        .cwd = .{ .path = config.cwd },
        .signal = config.signal,
        .stdout_limit = .unlimited,
        .stderr_limit = .limited(1024 * 1024),
        .on_chunk = .{ .ctx = @ptrCast(&line_ctx), .func = &JsonlCtx.onChunk },
    }) catch {
        result.exit_code = 1;
        result.error_message = allocator.dupe(u8, "failed to launch child process") catch null;
        return result;
    };
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
        .timed_out => |timeout| {
            result.exit_code = 1;
            result.stderr_output.appendSlice(allocator, timeout.stderr) catch {};
            result.error_message = allocator.dupe(u8, timeout.message) catch null;
        },
        .stdout_too_long, .stderr_too_long, .aborted => |err| {
            result.exit_code = 1;
            if (proc_result == .aborted) result.cancelled = true;
            result.error_message = allocator.dupe(u8, err.message) catch null;
            result.stderr_output.appendSlice(allocator, err.stderr) catch {};
            if (trace_file) |f| traceWrite(config.io, f, "--- spawn FAILED to launch: {s}\n", .{err.message});
            return result;
        },
    }

    if (config.signal.isAborted()) result.cancelled = true;

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

const JsonlCtx = struct {
    allocator: std.mem.Allocator,
    config: types.SpawnConfig,
    result: *types.SpawnResult,
    trace_file: ?std.Io.File,
    decoder: jsonl.Decoder,
    mutex: std.Io.Mutex = .init,

    fn onChunk(raw_ctx: ?*anyopaque, kind: runtime_process.StreamKind, bytes: []const u8) void {
        if (kind != .stdout) return;
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        {
            self.mutex.lockUncancelable(self.config.io);
            defer self.mutex.unlock(self.config.io);
            self.decoder.feed(bytes, self.sink()) catch {};
        }
        if (self.config.on_wait) |cb| cb(self.config.on_wait_ctx);
    }

    fn flushTail(self: *@This()) void {
        self.mutex.lockUncancelable(self.config.io);
        defer self.mutex.unlock(self.config.io);
        self.decoder.flush(self.sink());
    }

    fn sink(self: *@This()) jsonl.Sink {
        return .{ .ptr = self, .emit = emitLine, .err = jsonlError };
    }

    fn emitLine(ptr: *anyopaque, line: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.trace_file) |f| traceLine(self.config.io, f, line);
        processLine(line, self.result, self.config);
    }

    fn jsonlError(ptr: *anyopaque, _: jsonl.ErrorKind, _: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.result.error_message == null) self.result.error_message = self.allocator.dupe(u8, "child emitted an oversized JSONL line") catch null;
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

    if (msg_obj.get("stopReason")) |sr| {
        switch (sr) {
            .string => |s| {
                if (result.stop_reason) |old| allocator.free(old);
                result.stop_reason = allocator.dupe(u8, s) catch null;
            },
            else => {},
        }
    }

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

fn openTraceFile(io: std.Io) ?std.Io.File {
    const path = @import("env").get("ZI_SPAWN_TRACE") orelse return null;
    if (path.len == 0) return null;
    return std.Io.Dir.cwd().createFile(io, path, .{
        .read = false,
        .truncate = false,
    }) catch return null;
}

fn traceWrite(io: std.Io, f: std.Io.File, comptime fmt: []const u8, args: anytype) void {
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

const BuiltArgv = struct {
    argv: std.ArrayList([]const u8) = .empty,
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

const testing = std.testing;

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
    const override = [_][]const u8{ "sh", "-c", "sleep 30" };
    var controller = @import("../zio/root.zig").cancel.Source{};
    const signal = controller.beginRun();

    const Aborter = struct {
        fn run(c: *@import("../zio/root.zig").cancel.Source) void {
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

    try testing.expect(elapsed_ms < 2000);
    try testing.expect(result.exit_code != 0);
    try testing.expect(result.cancelled);
}

test "ziSpawn fires on_event for each parsed JSONL line via argv_override" {
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
    try testing.expectEqual(@as(usize, 2), counter.count);
    try testing.expectEqualStrings("hi", result.output.items);
}
