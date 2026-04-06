/// ziSpawn — spawn a child zi process in --mode json, parse JSONL events,
/// collect the last assistant text output and usage stats.
///
/// Zig equivalent of piSpawn() in pi-spawn.ts.
/// Reads stdout line-by-line, parses each as a JSON agent event.
/// On "message_end" with role=="assistant": extracts text, accumulates usage.
/// stderr is collected after stdout EOF.
const std = @import("std");
const types = @import("types.zig");

const log = std.log.scoped(.zi_spawn);

pub fn ziSpawn(config: types.SpawnConfig) types.SpawnResult {
    var result = types.SpawnResult.init();
    const allocator = config.allocator;

    // -- build argv --
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.selfExePath(&self_exe_buf) catch {
        result.exit_code = 1;
        result.error_message = allocator.dupe(u8, "failed to resolve self exe path") catch null;
        return result;
    };
    const self_exe_owned = allocator.dupe(u8, self_exe) catch {
        result.exit_code = 1;
        return result;
    };
    defer allocator.free(self_exe_owned);

    argv_list.appendSlice(allocator, &.{ self_exe_owned, "--mode", "json", "-p", "--no-session" }) catch {
        result.exit_code = 1;
        return result;
    };
    if (config.model) |m| {
        argv_list.appendSlice(allocator, &.{ "--model", m }) catch {};
    }
    if (config.tools) |t| {
        argv_list.appendSlice(allocator, &.{ "--tools", t }) catch {};
    }

    // -- temp file for append-system-prompt --
    var tmp_dir_path: ?[]const u8 = null;
    var tmp_file_path: ?[]const u8 = null;
    defer {
        if (tmp_file_path) |p| std.fs.deleteFileAbsolute(p) catch {};
        if (tmp_dir_path) |d| std.fs.deleteDirAbsolute(d) catch {};
    }

    if (config.append_system_prompt) |asp| {
        if (writeTempPrompt(allocator, asp)) |tmp| {
            tmp_dir_path = tmp.dir;
            tmp_file_path = tmp.path;
            argv_list.appendSlice(allocator, &.{ "--append-system-prompt", tmp.path }) catch {};
        } else |_| {}
    }

    // task as positional arg (pi-spawn prepends "Task: ")
    const task_arg = std.fmt.allocPrint(allocator, "Task: {s}", .{config.task}) catch {
        result.exit_code = 1;
        return result;
    };
    defer allocator.free(task_arg);
    argv_list.append(allocator, task_arg) catch {};

    // -- spawn --
    var child = std.process.Child.init(argv_list.items, allocator);
    child.cwd = config.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        result.exit_code = 1;
        result.error_message = allocator.dupe(u8, "failed to spawn zi process") catch null;
        return result;
    };

    // -- read stdout line by line, parse events --
    readAndProcess(&child, &result, config);

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

    return result;
}

// -- stdout processing --

fn readAndProcess(child: *std.process.Child, result: *types.SpawnResult, config: types.SpawnConfig) void {
    const allocator = config.allocator;
    const stdout_file = child.stdout orelse return;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(allocator);

    var read_buf: [8192]u8 = undefined;

    while (true) {
        if (config.signal) |sig| {
            if (sig.load(.acquire)) {
                killChild(child);
                break;
            }
        }

        const n = stdout_file.read(&read_buf) catch break;
        if (n == 0) break;

        var start: usize = 0;
        for (0..n) |i| {
            if (read_buf[i] == '\n') {
                const segment = read_buf[start..i];
                if (line_buf.items.len > 0) {
                    line_buf.appendSlice(allocator, segment) catch {};
                    processLine(line_buf.items, result, allocator);
                    line_buf.clearRetainingCapacity();
                } else {
                    processLine(segment, result, allocator);
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
        processLine(line_buf.items, result, allocator);
    }
}

fn processLine(line: []const u8, result: *types.SpawnResult, allocator: std.mem.Allocator) void {
    if (line.len == 0) return;

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
