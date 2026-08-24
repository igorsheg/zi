const std = @import("std");
const builtin = @import("builtin");
const ToolContract = @import("Tool.zig");
const BashProcess = @import("BashProcess.zig");
const BashOutput = @import("BashOutput.zig");
const BashClassify = @import("BashClassify.zig");
const BashCdStrip = @import("BashCdStrip.zig");
const BashTaskJobModule = @import("BashTaskJob.zig");
const BashTaskJob = BashTaskJobModule.BashTaskJob;
const ProducerClock = BashTaskJobModule.ProducerClock;
const SpoolFactory = BashTaskJobModule.SpoolFactory;
const DirectorySpoolFactory = BashTaskJobModule.DirectorySpoolFactory;
const TaskRegistryModule = @import("TaskRegistry.zig");

const maximum_json_bytes: usize = 1024 * 1024;

pub const Config = struct {
    environment: std.process.Environ = .empty,
    shell: ?[]const u8 = null,
    timeout_ms: u64 = 120 * 1000,
    maximum_timeout_ms: u64 = 30 * 60 * 1000,
    termination_grace_ms: u64 = 2 * 1000,
    output: BashOutput.Options = .{},
    maximum_retained_spills: usize = 16,
    maximum_retained_spill_bytes: usize = 256 * 1024 * 1024,
    /// Borrowed. The owner must shut down the registry after Bash is deinitialized.
    task_registry: ?*TaskRegistryModule.TaskRegistry = null,
    background_yield_ms: u64 = 1000,
};

/// Owns the resolved shell, injected child environment, and a bounded cache of
/// temporary spill files. A later spill may evict an older advertised path.
pub const Bash = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    shell: [:0]u8,
    environment: std.process.Environ.PosixBlock,
    home: ?[]u8,
    timeout_ms: u64,
    maximum_timeout_ms: u64,
    termination_grace_ms: u64,
    output_options: BashOutput.Options,
    temp_directory: []u8,
    kept_outputs: std.ArrayList(BashOutput.BashOutput) = .empty,
    retained_spill_bytes: usize = 0,
    maximum_retained_spills: usize,
    maximum_retained_spill_bytes: usize,
    task_registry: ?*TaskRegistryModule.TaskRegistry,
    background_yield_ms: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) error{ OutOfMemory, InvalidConfig }!Bash {
        if (config.timeout_ms > @as(u64, std.math.maxInt(i64)) or
            config.maximum_timeout_ms > @as(u64, std.math.maxInt(i64)) or
            config.output.result_bytes == 0 or
            config.maximum_retained_spills == 0 or
            config.maximum_retained_spill_bytes < BashOutput.drain_limit or
            config.background_yield_ms > @as(u64, std.math.maxInt(i64)))
        {
            return error.InvalidConfig;
        }

        var map = config.environment.createMap(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidConfig,
        };
        defer map.deinit();
        try injectEnvironment(&map);

        const home = if (map.get("HOME")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (home) |value| allocator.free(value);
        const shell = try resolveShell(allocator, io, config.shell, map.get("PATH"));
        errdefer allocator.free(shell);
        _ = map.orderedRemove("ZIG_PROGRESS");
        const environment = try createEnvironment(allocator, &map);
        errdefer environment.deinit(allocator);

        const temp_directory = try createPrivateTempDirectory(
            allocator,
            io,
            config.output.temp_directory,
        );
        errdefer {
            deleteTempDirectory(io, temp_directory);
            allocator.free(temp_directory);
        }
        var output_options = config.output;
        output_options.temp_directory = temp_directory;
        return .{
            .allocator = allocator,
            .io = io,
            .shell = shell,
            .environment = environment,
            .home = home,
            .timeout_ms = config.timeout_ms,
            .maximum_timeout_ms = config.maximum_timeout_ms,
            .termination_grace_ms = config.termination_grace_ms,
            .output_options = output_options,
            .temp_directory = temp_directory,
            .maximum_retained_spills = config.maximum_retained_spills,
            .maximum_retained_spill_bytes = config.maximum_retained_spill_bytes,
            .task_registry = config.task_registry,
            .background_yield_ms = config.background_yield_ms,
        };
    }

    pub fn deinit(self: *Bash) void {
        for (self.kept_outputs.items) |*output| output.deinit();
        self.kept_outputs.deinit(self.allocator);
        self.environment.deinit(self.allocator);
        self.allocator.free(self.shell);
        if (self.home) |home| self.allocator.free(home);
        deleteTempDirectory(self.io, self.temp_directory);
        self.allocator.free(self.temp_directory);
        self.* = undefined;
    }

    pub fn tool(self: *Bash) ToolContract.Tool {
        const selected_definition = if (self.task_registry != null) definition else definition_no_tasks;
        return ToolContract.Tool.from(self, selected_definition, .{
            .arg_name = "command",
            .preview_mode = .head_tail,
            .header_rows = 3,
            .select_preview = selectPreview,
        });
    }

    pub fn run(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Bash,
        args_json: ?[]const u8,
        run_context: ToolContract.RunContext,
    ) ToolContract.RunError!ToolContract.Result {
        const input = args_json orelse "{}";
        if (input.len > maximum_json_bytes)
            return resultCopy(allocator, "invalid arguments: input exceeds 1048576 bytes");
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return resultFormat(allocator, "invalid arguments: {s}", .{@errorName(err)}),
        };
        defer parsed.deinit();
        if (parsed.value != .object) return resultCopy(allocator, "missing 'command' argument");
        const command_value = parsed.value.object.get("command") orelse
            return resultCopy(allocator, "missing 'command' argument");
        if (command_value != .string or command_value.string.len == 0)
            return resultCopy(allocator, "missing 'command' argument");
        const command = command_value.string;
        if (std.mem.findScalar(u8, command, 0) != null)
            return resultCopy(allocator, "'command' contains a NUL byte");

        var background = false;
        if (parsed.value.object.get("background")) |value| {
            if (value != .bool) return resultCopy(allocator, "'background' must be a boolean");
            background = value.bool;
        }
        var name: ?[]const u8 = null;
        if (self.task_registry != null) if (parsed.value.object.get("name")) |value| {
            if (value != .null) {
                if (value != .string) return resultCopy(allocator, "'name' must be a string");
                if (value.string.len != 0) name = value.string;
            }
        };
        if (background and self.task_registry == null)
            return resultCopy(
                allocator,
                "background tasks are disabled; run the command synchronously",
            );

        const timeout = resolveTimeout(
            parsed.value,
            self.timeout_ms,
            self.maximum_timeout_ms,
        ) catch |err| {
            return resultCopy(allocator, switch (err) {
                error.NotInteger => "'timeout_seconds' must be an integer",
                error.BelowOne => "'timeout_seconds' must be >= 1",
            });
        };
        if (self.task_registry) |registry| {
            const running = registry.runningCount() catch |err| return registryFailure(allocator, err);
            if (background and running >= registry.config.max_running)
                return resultFormat(
                    allocator,
                    "too many running tasks (max {d}): wait on or kill one first",
                    .{registry.config.max_running},
                );
            if (name) |task_name| {
                if (registry.nameError(allocator, task_name) catch |err|
                    return registryFailure(allocator, err)) |message|
                {
                    return .{ .output = message };
                }
            }
            return self.runManaged(
                allocator,
                command,
                timeout,
                background,
                name,
                run_context,
            );
        }

        const command_z = try allocator.dupeZ(u8, command);
        defer allocator.free(command_z);

        const argv0 = shellArgv0(self.shell);
        var argv: [4:null]?[*:0]const u8 = .{ argv0, "-c", command_z.ptr, null };
        var capture = BashOutput.BashOutput.init(allocator, io, self.output_options);
        var capture_owned = true;
        defer if (capture_owned) capture.deinit();
        var sink: CaptureSink = .{ .output = &capture, .display = run_context.display };
        const cancel_adapter: ?CancelAdapter = if (run_context.cancel) |cancel| .{ .cancel = cancel } else null;
        const cancellation = if (cancel_adapter) |*adapter| BashProcess.Cancellation.from(adapter) else null;
        var process_result = BashProcess.run(allocator, io, .{
            .executable = self.shell.ptr,
            .argv = &argv,
            .envp = @ptrCast(self.environment.slice.ptr),
        }, .{
            .timeout_ms = timeout,
            .termination_grace_ms = self.termination_grace_ms,
            .cancellation = cancellation,
            .output_sink = BashProcess.OutputSink.from(&sink),
            .maximum_output_bytes = BashOutput.drain_limit,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unexpected => return error.InvalidResult,
            error.SystemResources => return resultCopy(allocator, "unable to start command: system resource limit"),
            error.ProcessFdQuotaExceeded => return resultCopy(
                allocator,
                "unable to start command: process file descriptor limit",
            ),
            error.SystemFdQuotaExceeded => return resultCopy(
                allocator,
                "unable to start command: system file descriptor limit",
            ),
        };
        defer process_result.deinit(allocator);

        const finish_options = finishOptions(process_result.status, timeout);
        const output = capture.finish(finish_options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CaptureLimitExceeded, error.ResultTooLarge => return error.InvalidResult,
        };
        errdefer allocator.free(output);
        if (run_context.display) |display| try emitDisplayFinish(display, &sink, output, finish_options);

        if (capture.savedPath() != null) {
            const spill_bytes = capture.size();
            while (self.kept_outputs.items.len >= self.maximum_retained_spills or
                spill_bytes > self.maximum_retained_spill_bytes -| self.retained_spill_bytes)
            {
                var evicted = self.kept_outputs.orderedRemove(0);
                self.retained_spill_bytes -= evicted.size();
                evicted.deinit();
            }
            try self.kept_outputs.append(self.allocator, capture);
            self.retained_spill_bytes += spill_bytes;
            capture_owned = false;
        }
        return .{ .output = output };
    }

    fn runManaged(
        self: *Bash,
        allocator: std.mem.Allocator,
        command: []const u8,
        timeout_ms: u64,
        background: bool,
        name: ?[]const u8,
        run_context: ToolContract.RunContext,
    ) ToolContract.RunError!ToolContract.Result {
        const registry = self.task_registry.?;
        const started_ms = registry.clock.nowMs();
        const command_z = try allocator.dupeZ(u8, command);
        defer allocator.free(command_z);
        const argv0 = shellArgv0(self.shell);
        var argv: [4:null]?[*:0]const u8 = .{ argv0, "-c", command_z.ptr, null };
        var spool_factory: DirectorySpoolFactory = .{ .directory = self.temp_directory };
        const task = BashTaskJob.create(
            allocator,
            self.io,
            ProducerClock.fromIo(self.io),
            SpoolFactory.from(&spool_factory),
            .{
                .executable = self.shell.ptr,
                .argv = &argv,
                .envp = @ptrCast(self.environment.slice.ptr),
            },
            null,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SystemResources, error.ThreadQuotaExceeded => resultCopy(
                allocator,
                "unable to start command: system resource limit",
            ),
            error.ProcessFdQuotaExceeded => resultCopy(
                allocator,
                "unable to start command: process file descriptor limit",
            ),
            error.SystemFdQuotaExceeded => resultCopy(
                allocator,
                "unable to start command: system file descriptor limit",
            ),
            error.Unexpected, error.LockedMemoryLimitExceeded => error.InvalidResult,
        };
        var task_owned = true;
        defer if (task_owned) task.deinit(allocator);

        var capture = BashOutput.BashOutput.init(allocator, self.io, self.output_options);
        var capture_owned = true;
        defer if (capture_owned) capture.deinit();
        var sink: CaptureSink = .{ .output = &capture, .display = run_context.display };
        var captured_cursor: usize = 0;
        const wait_ms = if (background) self.background_yield_ms else timeout_ms;
        const deadline: ?i128 = if (!background and timeout_ms == 0)
            null
        else
            deadlineAfterMs(std.Io.Clock.awake.now(self.io).nanoseconds, wait_ms);
        while (true) {
            task.poll() catch return error.InvalidResult;
            try drainManaged(task, &sink, &captured_cursor);
            switch (task.status()) {
                .running => {},
                .exited => |code| return self.finishManaged(
                    allocator,
                    &capture,
                    &capture_owned,
                    &sink,
                    .{ .exited = code },
                    timeout_ms,
                    background,
                    name,
                    task.killedLaunchOrphans(),
                ),
                .signaled => |signal| return self.finishManaged(
                    allocator,
                    &capture,
                    &capture_owned,
                    &sink,
                    .{ .signaled = signal },
                    timeout_ms,
                    background,
                    name,
                    task.killedLaunchOrphans(),
                ),
            }
            if (run_context.cancel) |cancel| if (cancel.isRequested()) {
                task.terminate(.force);
                continue;
            };
            const now = std.Io.Clock.awake.now(self.io).nanoseconds;
            if (deadline) |limit| if (now >= limit and task.leaderRunning()) break;
            const remaining_ns: u64 = if (deadline) |limit|
                if (now >= limit)
                    5 * std.time.ns_per_ms
                else
                    @intCast(@min(@as(i128, 10 * std.time.ns_per_ms), limit - now))
            else
                10 * std.time.ns_per_ms;
            self.io.sleep(.fromNanoseconds(remaining_ns), .awake) catch return error.InvalidResult;
        }

        var erased = task.job();
        const id = registry.adopt(&erased, command, name, started_ms) catch |err| {
            if (background) return registryFailure(allocator, err);
            return self.finishManagedTimeout(
                allocator,
                task,
                &capture,
                &capture_owned,
                &sink,
                &captured_cursor,
                timeout_ms,
            );
        };
        task_owned = false;
        return detachedResult(
            allocator,
            registry,
            id,
            background,
            started_ms,
            &sink,
        );
    }

    fn finishManagedTimeout(
        self: *Bash,
        allocator: std.mem.Allocator,
        task: *BashTaskJob,
        capture: *BashOutput.BashOutput,
        capture_owned: *bool,
        sink: *CaptureSink,
        captured_cursor: *usize,
        timeout_ms: u64,
    ) ToolContract.RunError!ToolContract.Result {
        task.terminate(.graceful);
        const grace_deadline = deadlineAfterMs(
            std.Io.Clock.awake.now(self.io).nanoseconds,
            self.termination_grace_ms,
        );
        var forced = false;
        while (task.status() == .running) {
            task.poll() catch return error.InvalidResult;
            try drainManaged(task, sink, captured_cursor);
            const now = std.Io.Clock.awake.now(self.io).nanoseconds;
            if (!forced and now >= grace_deadline) {
                task.terminate(.force);
                forced = true;
            }
            self.io.sleep(.fromMilliseconds(5), .awake) catch return error.InvalidResult;
        }
        try drainManaged(task, sink, captured_cursor);
        const options: BashOutput.FinishOptions = .{
            .reason = .timeout,
            .timeout_ms = @intCast(@min(timeout_ms, @as(u64, std.math.maxInt(i64)))),
        };
        const output = capture.finish(options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CaptureLimitExceeded, error.ResultTooLarge => return error.InvalidResult,
        };
        errdefer allocator.free(output);
        if (sink.display) |display| try emitDisplayFinish(display, sink, output, options);
        if (capture.savedPath() != null) {
            const spill_bytes = capture.size();
            while (self.kept_outputs.items.len >= self.maximum_retained_spills or
                spill_bytes > self.maximum_retained_spill_bytes -| self.retained_spill_bytes)
            {
                var evicted = self.kept_outputs.orderedRemove(0);
                self.retained_spill_bytes -= evicted.size();
                evicted.deinit();
            }
            try self.kept_outputs.append(self.allocator, capture.*);
            self.retained_spill_bytes += spill_bytes;
            capture_owned.* = false;
        }
        return .{ .output = output };
    }

    fn finishManaged(
        self: *Bash,
        allocator: std.mem.Allocator,
        capture: *BashOutput.BashOutput,
        capture_owned: *bool,
        sink: *CaptureSink,
        status: BashOutput.Status,
        timeout_ms: u64,
        background: bool,
        name: ?[]const u8,
        orphaned: bool,
    ) ToolContract.RunError!ToolContract.Result {
        const options: BashOutput.FinishOptions = if (orphaned)
            .{ .status = status, .reason = .orphaned, .timeout_ms = @intCast(timeout_ms) }
        else
            .{ .status = status };
        const output = capture.finish(options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CaptureLimitExceeded, error.ResultTooLarge => return error.InvalidResult,
        };
        errdefer allocator.free(output);
        if (sink.display) |display| try emitDisplayFinish(display, sink, output, options);
        if (capture.savedPath() != null) {
            const spill_bytes = capture.size();
            while (self.kept_outputs.items.len >= self.maximum_retained_spills or
                spill_bytes > self.maximum_retained_spill_bytes -| self.retained_spill_bytes)
            {
                var evicted = self.kept_outputs.orderedRemove(0);
                self.retained_spill_bytes -= evicted.size();
                evicted.deinit();
            }
            try self.kept_outputs.append(self.allocator, capture.*);
            self.retained_spill_bytes += spill_bytes;
            capture_owned.* = false;
        }
        if (background and !orphaned) {
            const footer = if (name) |task_name|
                try std.fmt.allocPrint(
                    allocator,
                    "\n[finished during launch; task {s} not created]",
                    .{task_name},
                )
            else
                try allocator.dupe(u8, "\n[finished during launch; no task created]");
            defer allocator.free(footer);
            const combined = try std.mem.concat(allocator, u8, &.{ output, footer });
            allocator.free(output);
            return .{ .output = combined, .hidden_tail_bytes = footer.len };
        }
        return .{ .output = output };
    }

    pub fn preprocess(
        allocator: std.mem.Allocator,
        io: std.Io,
        self: *Bash,
        args_json: ?[]const u8,
    ) error{OutOfMemory}!?[]u8 {
        const input = args_json orelse return null;
        if (input.len > maximum_json_bytes) return null;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const value = parsed.value.object.getPtr("command") orelse return null;
        if (value.* != .string) return null;
        const cwd = std.process.currentPathAlloc(io, allocator) catch return null;
        defer allocator.free(cwd);
        const suffix = BashCdStrip.stripPrefix(value.string, cwd, self.home) orelse return null;
        value.* = .{ .string = suffix };
        const rewritten = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        return rewritten;
    }
};

fn detachedResult(
    allocator: std.mem.Allocator,
    registry: *TaskRegistryModule.TaskRegistry,
    id: []const u8,
    background: bool,
    started_ms: i64,
    sink: *CaptureSink,
) ToolContract.RunError!ToolContract.Result {
    var report = (registry.reportOutput(allocator, id) catch |err|
        return registryFailure(allocator, err)) orelse return error.InvalidResult;
    defer report.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, report.body);
    if (report.body.len != 0 and sink.displayed_bytes == 0) if (sink.display) |display|
        try display.emit(report.body);
    if (report.marker) |marker| {
        try out.appendSlice(allocator, marker);
        if (sink.display) |display| {
            if (sink.displayed_bytes != 0 and marker.len != 0 and marker[0] != '\n')
                try display.emit("\n");
            try display.emit(marker);
        }
    }
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n')
        try out.append(allocator, '\n');
    var footer_buffer: [128]u8 = undefined;
    const footer = if (background)
        std.fmt.bufPrint(&footer_buffer, "[detached as task {s}]", .{id}) catch
            return error.InvalidResult
    else footer: {
        var duration_buffer: [32]u8 = undefined;
        const elapsed = @max(0, registry.clock.nowMs() - started_ms);
        const duration = shortDuration(&duration_buffer, elapsed);
        break :footer std.fmt.bufPrint(
            &footer_buffer,
            "[detached as task {s} after {s} timeout]",
            .{ id, duration },
        ) catch return error.InvalidResult;
    };
    try out.appendSlice(allocator, footer);
    if (sink.display) |display| {
        if (sink.displayed_bytes != 0 or report.marker != null) try display.emit("\n");
        try display.emit(footer);
    }
    return .{ .output = try out.toOwnedSlice(allocator) };
}

fn shortDuration(buffer: []u8, milliseconds: i64) []const u8 {
    const seconds = @divTrunc(@max(milliseconds, 0), 1000) +
        @intFromBool(@rem(@max(milliseconds, 0), 1000) >= 500);
    if (seconds < 60) return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
    if (seconds < 3600 and @rem(seconds, 60) == 0)
        return std.fmt.bufPrint(buffer, "{d}m", .{@divTrunc(seconds, 60)}) catch unreachable;
    if (seconds < 3600) return std.fmt.bufPrint(
        buffer,
        "{d}m {d:0>2}s",
        .{ @divTrunc(seconds, 60), @rem(seconds, 60) },
    ) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}h", .{@divTrunc(seconds, 3600)}) catch unreachable;
}

fn drainManaged(
    task: *BashTaskJob,
    sink: *CaptureSink,
    cursor: *usize,
) ToolContract.RunError!void {
    while (true) {
        var buffer: [8192]u8 = undefined;
        const outcome = task.readAt(cursor.*, &buffer) catch return error.InvalidResult;
        switch (outcome) {
            .data => |amount| {
                sink.emit(buffer[0..amount]) catch return error.OutOfMemory;
                cursor.* += amount;
            },
            .would_block, .eof => return,
            .unavailable => return error.InvalidResult,
        }
    }
}

fn deadlineAfterMs(now_ns: i128, milliseconds: u64) i128 {
    const duration = @as(i128, milliseconds) * std.time.ns_per_ms;
    return std.math.add(i128, now_ns, duration) catch std.math.maxInt(i128);
}

fn registryFailure(
    allocator: std.mem.Allocator,
    err: TaskRegistryModule.Error,
) ToolContract.RunError!ToolContract.Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CapacityReached => resultCopy(allocator, "background task capacity reached"),
        error.InvalidName => resultCopy(allocator, "invalid background task name"),
        error.InvalidJob, error.Reentrant, error.Busy, error.OutputUnavailable => error.InvalidResult,
    };
}

const TimeoutError = error{ NotInteger, BelowOne };

fn resolveTimeout(
    value: std.json.Value,
    default_timeout_ms: u64,
    maximum_timeout_ms: u64,
) TimeoutError!u64 {
    const timeout_value = value.object.get("timeout_seconds") orelse return default_timeout_ms;
    if (timeout_value != .integer) return error.NotInteger;
    if (timeout_value.integer < 1) return error.BelowOne;
    const seconds: u64 = @intCast(timeout_value.integer);
    var milliseconds = std.math.mul(u64, seconds, 1000) catch std.math.maxInt(u64);
    milliseconds = @min(milliseconds, @as(u64, std.math.maxInt(i64)));
    if (maximum_timeout_ms > 0) milliseconds = @min(milliseconds, maximum_timeout_ms);
    return milliseconds;
}

const CancelAdapter = struct {
    cancel: ToolContract.Cancellation,

    pub fn isCancellationRequested(self: *const CancelAdapter) bool {
        return self.cancel.isRequested();
    }
};

const CaptureSink = struct {
    output: *BashOutput.BashOutput,
    display: ?ToolContract.DisplaySink,
    displayed_bytes: usize = 0,
    display_stopped: bool = false,

    pub fn emit(self: *CaptureSink, bytes: []const u8) error{OutOfMemory}!void {
        self.output.append(bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CaptureLimitExceeded, error.ResultTooLarge => unreachable,
        };
        if (self.display_stopped) return;
        if (std.mem.findScalar(u8, bytes, 0) != null) {
            self.display_stopped = true;
            return;
        }
        if (self.display) |display| {
            try display.emit(bytes);
            self.displayed_bytes += bytes.len;
        }
    }
};

fn finishOptions(status: BashProcess.Status, timeout_ms: u64) BashOutput.FinishOptions {
    const bounded_timeout: i64 = @intCast(@min(timeout_ms, @as(u64, std.math.maxInt(i64))));
    return switch (status) {
        .exited => |code| .{ .status = .{ .exited = code } },
        .signaled => |signal| .{ .status = .{ .signaled = signal } },
        .timed_out => .{ .reason = .timeout, .timeout_ms = bounded_timeout },
        .interrupted => .{ .reason = .interrupt },
        .output_limit => .{ .status = .{ .signaled = 9 } },
    };
}

fn emitDisplayFinish(
    display: ToolContract.DisplaySink,
    sink: *const CaptureSink,
    output: []const u8,
    options: BashOutput.FinishOptions,
) error{OutOfMemory}!void {
    if (sink.output.binary) {
        if (sink.displayed_bytes != 0) try display.emit("\n");
        return display.emit(output);
    }
    const marker = statusMarker(output, options, sink.output.size() != 0);
    if (marker.len != 0) try display.emit(marker);
}

fn statusMarker(output: []const u8, options: BashOutput.FinishOptions, had_output: bool) []const u8 {
    if (!had_output) return output;
    const needle: []const u8 = switch (options.reason) {
        .interrupt => "\n[interrupted]",
        .timeout => "\n[timed out after ",
        .none, .orphaned => switch (options.status) {
            .exited => |code| if (code == 0) return "" else "\n[exit ",
            .signaled => "\n[signal ",
        },
    };
    const offset = std.mem.lastIndexOf(u8, output, needle) orelse return "";
    return output[offset..];
}

fn createEnvironment(
    allocator: std.mem.Allocator,
    map: *const std.process.Environ.Map,
) error{OutOfMemory}!std.process.Environ.PosixBlock {
    const entries = try allocator.allocSentinel(?[*:0]u8, map.count(), null);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |entry| allocator.free(std.mem.span(entry.?));
        allocator.free(entries);
    }
    for (map.keys(), map.values()) |key, value| {
        entries[initialized] = (try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ key, value }, 0)).ptr;
        initialized += 1;
    }
    return .{ .slice = entries };
}

fn injectEnvironment(map: *std.process.Environ.Map) error{OutOfMemory}!void {
    const overrides = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "PAGER", .value = "cat" },
        .{ .name = "GIT_PAGER", .value = "cat" },
        .{ .name = "MANPAGER", .value = "cat" },
        .{ .name = "SYSTEMD_PAGER", .value = "cat" },
        .{ .name = "GH_PAGER", .value = "cat" },
        .{ .name = "GIT_EDITOR", .value = "false" },
        .{ .name = "GIT_SEQUENCE_EDITOR", .value = "false" },
        .{ .name = "VISUAL", .value = "false" },
        .{ .name = "EDITOR", .value = "false" },
        .{ .name = "TERM", .value = "dumb" },
        .{ .name = "COLORTERM", .value = "" },
        .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" },
        // Documented identity for agent-aware child programs.
        .{ .name = "AI_AGENT", .value = "zi" },
        .{ .name = "PYTHONUNBUFFERED", .value = "1" },
        .{ .name = "TQDM_DISABLE", .value = "1" },
        .{ .name = "HAX_TRACE", .value = "" },
        .{ .name = "HAX_TRANSCRIPT", .value = "" },
        .{ .name = "ZI_TRACE", .value = "" },
        .{ .name = "ZI_TRANSCRIPT", .value = "" },
    };
    for (overrides) |override| try map.put(override.name, override.value);
}

fn ensureTempBase(io: std.Io, path: []const u8) bool {
    const directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
        std.Io.Dir.cwd().createDirPath(io, path) catch return false;
        return true;
    };
    directory.close(io);
    return true;
}

fn deleteTempDirectory(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteDir(io, path) catch |err| {
        std.log.warn("removing private bash directory {s}: {s}", .{ path, @errorName(err) });
    };
}

fn createPrivateTempDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured_base: []const u8,
) error{ OutOfMemory, InvalidConfig }![]u8 {
    const usable_configured = configured_base.len != 0 and
        std.unicode.utf8ValidateSlice(configured_base) and
        std.mem.findScalar(u8, configured_base, 0) == null;
    if (usable_configured and ensureTempBase(io, configured_base)) {
        if (createPrivateDirectoryUnder(allocator, io, configured_base)) |path| {
            return path;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unavailable => {},
        }
    }
    if (!ensureTempBase(io, "/tmp")) return error.InvalidConfig;
    return createPrivateDirectoryUnder(allocator, io, "/tmp") catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unavailable => error.InvalidConfig,
    };
}

fn createPrivateDirectoryUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
) error{ OutOfMemory, Unavailable }![]u8 {
    var random: [12]u8 = undefined;
    var name_buffer: [64]u8 = undefined;
    for (0..32) |_| {
        io.random(&random);
        const name = std.fmt.bufPrint(&name_buffer, "zi-bash-{x}", .{random}) catch unreachable;
        const path = try std.fs.path.join(allocator, &.{ base, name });
        errdefer allocator.free(path);
        std.Io.Dir.cwd().createDir(io, path, @enumFromInt(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return error.Unavailable,
        };
        return path;
    }
    return error.Unavailable;
}

fn resolveShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: ?[]const u8,
    path_env: ?[]const u8,
) error{OutOfMemory}![:0]u8 {
    if (configured) |name| if (name.len != 0) {
        if (try findExecutable(allocator, io, name, path_env)) |path| return path;
    };
    if (try findExecutable(allocator, io, "bash", path_env)) |path| return path;
    if (isExecutable(io, "/bin/bash")) return allocator.dupeZ(u8, "/bin/bash");
    return allocator.dupeZ(u8, "/bin/sh");
}

fn shellArgv0(shell: [:0]const u8) [*:0]const u8 {
    const basename = std.fs.path.basename(shell);
    return @ptrCast(basename.ptr);
}

fn findExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    path_env: ?[]const u8,
) error{OutOfMemory}!?[:0]u8 {
    if (name.len == 0 or std.mem.findScalar(u8, name, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (!isExecutable(io, name)) return null;
        const result = try allocator.dupeZ(u8, name);
        return result;
    }
    var paths = std.mem.splitScalar(u8, path_env orelse "", ':');
    while (paths.next()) |directory| {
        const candidate = try std.fs.path.join(allocator, &.{ if (directory.len == 0) "." else directory, name });
        defer allocator.free(candidate);
        if (isExecutable(io, candidate)) {
            const result = try allocator.dupeZ(u8, candidate);
            return result;
        }
    }
    return null;
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn selectPreview(args_json: ?[]const u8) ToolContract.PreviewMode {
    const input = args_json orelse return .head_tail;
    if (input.len > maximum_json_bytes) return .head_tail;
    var storage: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), input, .{}) catch return .head_tail;
    defer parsed.deinit();
    if (parsed.value != .object) return .head_tail;
    const value = parsed.value.object.get("command") orelse return .head_tail;
    if (value != .string) return .head_tail;
    return if (BashClassify.isExploration(value.string)) .collapsed else .head_tail;
}

fn resultCopy(allocator: std.mem.Allocator, output: []const u8) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try allocator.dupe(u8, output) };
}

fn resultFormat(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!ToolContract.Result {
    return .{ .output = try std.fmt.allocPrint(allocator, format, args) };
}

const parameters = [_]ToolContract.Parameter{
    .{
        .name = "command",
        .type = .string,
        .required = true,
        .description = "Shell command to run.",
    },
    .{
        .name = "timeout_seconds",
        .type = .integer,
        .minimum = 1,
        .description = "Optional override of the default timeout. Use a higher value for slow builds " ++
            "or test suites; the harness clamps to a configured maximum.",
    },
    .{
        .name = "background",
        .type = .boolean,
        .description = "Run as a background task: return after a brief initial-output window while " ++
            "the command keeps running; `timeout_seconds` is ignored. A command that finishes " ++
            "within the window returns synchronously and creates no task.",
    },
    .{
        .name = "name",
        .type = .string,
        .description = "Optional short task name used instead of the automatic id if the command " ++
            "detaches (letters/digits/-/_, max 32 chars, e.g. \"tests\").",
    },
};

const no_task_parameters = parameters[0..2].*;

pub const definition: ToolContract.Definition = .{
    .name = "bash",
    .description = "Run a shell command via bash -c (POSIX sh -c where bash is unavailable). Returns combined " ++
        "stdout+stderr plus exit code.\n\nRules:\n" ++
        "- Each call starts in the working directory listed under `# Environment`; `cd` does not " ++
        "persist across calls.\n" ++
        "- Follow the command preferences under `# Environment` when present.\n" ++
        "- Usually omit `timeout_seconds`: a command that outlives the default timeout (120s) is " ++
        "not killed — it detaches into a background task and you will be notified when it finishes.\n" ++
        "- Set `background` for commands meant to run alongside other work: the call returns after " ++
        "a brief initial-output window and the command continues as a task. No trailing `&`.",
    .parameters = &parameters,
};

const definition_no_tasks: ToolContract.Definition = .{
    .name = "bash",
    .description = "Run a shell command via bash -c (POSIX sh -c where bash is unavailable). Returns combined " ++
        "stdout+stderr plus exit code.\n\nRules:\n" ++
        "- Each call starts in the working directory listed under `# Environment`; `cd` does not " ++
        "persist across calls.\n" ++
        "- Follow the command preferences under `# Environment` when present.\n" ++
        "- Default timeout is 120s; pass `timeout_seconds` for slow commands. On timeout the command " ++
        "is terminated; background tasks are unavailable.",
    .parameters = &no_task_parameters,
};

test "bash definition is synchronous hax contract" {
    try std.testing.expectEqualStrings("bash", definition.name);
    try std.testing.expectEqual(@as(usize, 4), definition.parameters.len);
    try std.testing.expectEqualStrings("command", definition.parameters[0].name);
    try std.testing.expectEqualStrings("timeout_seconds", definition.parameters[1].name);
}

test "bash validates arguments and runs with owned environment" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .timeout_ms = 1000,
    });
    defer bash.deinit();
    const cases = [_]struct { args: ?[]const u8, expected: []const u8 }{
        .{ .args = null, .expected = "missing 'command' argument" },
        .{ .args = "{", .expected = "invalid arguments: UnexpectedEndOfInput" },
        .{ .args = "{\"command\":\"true\",\"timeout_seconds\":0}", .expected = "'timeout_seconds' must be >= 1" },
        .{
            .args = "{\"command\":\"true\",\"timeout_seconds\":\"x\"}",
            .expected = "'timeout_seconds' must be an integer",
        },
    };
    for (cases) |case| {
        var result = try bash.tool().run(std.testing.allocator, std.testing.io, case.args, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.output);
    }
    var result = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf '%s\\n' \\\"$AI_AGENT:$PAGER:$TERM\\\"\"}",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zi:cat:dumb\n", result.output);
}

test "bash status binary timeout and command NUL are ordinary results" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .timeout_ms = 100,
        .termination_grace_ms = 0,
    });
    defer bash.deinit();
    const cases = [_]struct { args: []const u8, needle: []const u8 }{
        .{ .args = "{\"command\":\"false\"}", .needle = "[exit 1]" },
        .{ .args = "{\"command\":\"printf 'a\\\\0b'\"}", .needle = "[binary output suppressed: 3B]" },
        .{ .args = "{\"command\":\"sleep 30\"}", .needle = "[timed out after 100ms]" },
        .{ .args = "{\"command\":\"a\\u0000b\"}", .needle = "'command' contains a NUL byte" },
    };
    for (cases) |case| {
        var result = try bash.tool().run(std.testing.allocator, std.testing.io, case.args, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, result.output, case.needle) != null);
    }
}

test "bash preprocess strips only a proven no-op cd and preview classifies exploration" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{ .environment = std.testing.environ });
    defer bash.deinit();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"command\":\"cd {s} && rg foo\"}}", .{cwd});
    defer std.testing.allocator.free(args);
    const processed = (try bash.tool().preprocess(std.testing.allocator, std.testing.io, args)).?;
    defer std.testing.allocator.free(processed);
    try std.testing.expectEqualStrings("{\"command\":\"rg foo\"}", processed);
    try std.testing.expectEqual(.collapsed, bash.tool().display.preview("{\"command\":\"rg foo .\"}"));
    try std.testing.expectEqual(.head_tail, bash.tool().display.preview("{\"command\":\"make test\"}"));
}

fn exerciseBashAllocations(allocator: std.mem.Allocator) !void {
    var bash = try Bash.init(allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .timeout_ms = 1000,
        .output = .{ .memory_cap = 1, .temp_directory = ".zig-cache/tmp" },
    });
    defer bash.deinit();
    var result = try bash.tool().run(allocator, std.testing.io, "{\"command\":\"printf hello\"}", .{});
    result.deinit(allocator);
}

test "bash init run and spill cleanup are OOM safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseBashAllocations, .{});
}

test "bash passes shell basename as argv zero and clears inherited hax tracing" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .timeout_ms = 1000,
    });
    defer bash.deinit();
    var result = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf '%s:%s:%s' \\\"$0\\\" \\\"$HAX_TRACE\\\" \\\"$HAX_TRANSCRIPT\\\"\"}",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}::",
        .{std.fs.path.basename(bash.shell)},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.output);
}

test "bash live display repeats output rather than marking it summarized" {
    const Sink = struct {
        const Self = @This();
        bytes: [32]u8 = undefined,
        length: usize = 0,
        pub fn emit(self: *Self, bytes: []const u8) error{OutOfMemory}!void {
            @memcpy(self.bytes[self.length .. self.length + bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var sink: Sink = .{};
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .timeout_ms = 1000,
    });
    defer bash.deinit();
    var result = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf shown\"}",
        .{ .display = ToolContract.DisplaySink.from(&sink) },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("shown", result.output);
    try std.testing.expectEqualStrings("shown", sink.bytes[0..sink.length]);
    try std.testing.expect(!result.summarizes_display);
    try std.testing.expectEqual(@as(usize, 0), result.hidden_tail_bytes);
}

test "bash defaults pin hax timeout ceiling and termination grace" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
    });
    defer bash.deinit();
    try std.testing.expectEqual(@as(u64, 120 * 1000), bash.timeout_ms);
    try std.testing.expectEqual(@as(u64, 30 * 60 * 1000), bash.maximum_timeout_ms);
    try std.testing.expectEqual(@as(u64, 2 * 1000), bash.termination_grace_ms);
}

test "bash child environment overrides inherited hax tracing" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HAX_TRACE", "enabled");
    try environment.put("HAX_TRANSCRIPT", "enabled");
    try injectEnvironment(&environment);
    try std.testing.expectEqualStrings("", environment.get("HAX_TRACE").?);
    try std.testing.expectEqualStrings("", environment.get("HAX_TRANSCRIPT").?);
}

test "bash no-tasks mode validates and refuses background before execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "side-effect" },
    );
    defer std.testing.allocator.free(path);
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
    });
    defer bash.deinit();
    try std.testing.expectEqual(@as(usize, 2), bash.tool().definition.parameters.len);
    try std.testing.expect(std.mem.indexOf(u8, bash.tool().definition.description, "terminated") != null);
    const cases = [_]struct { value: []const u8, expected: []const u8 }{
        .{ .value = "1", .expected = "'background' must be a boolean" },
        .{
            .value = "true",
            .expected = "background tasks are disabled; run the command synchronously",
        },
    };
    for (cases) |case| {
        const args = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"command\":\"touch {s}\",\"background\":{s}}}",
            .{ path, case.value },
        );
        defer std.testing.allocator.free(args);
        var result = try bash.tool().run(std.testing.allocator, std.testing.io, args, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.output);
    }
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, path, .{}),
    );
}

test "bash spills use a private directory and owner-only files" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .output = .{ .memory_cap = 1, .temp_directory = ".zig-cache/tmp" },
    });
    defer bash.deinit();
    const directory_stat = try std.Io.Dir.cwd().statFile(
        std.testing.io,
        bash.temp_directory,
        .{},
    );
    try std.testing.expectEqual(@as(u16, 0o700), @intFromEnum(directory_stat.permissions) & 0o777);
    var result = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf private\"}",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), bash.kept_outputs.items.len);
    const path = bash.kept_outputs.items[0].savedPath().?;
    const file_stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u16, 0o600), @intFromEnum(file_stat.permissions) & 0o777);
}

test "bash bounds retained spill files and evicts the oldest" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .maximum_retained_spills = 1,
        .output = .{ .memory_cap = 1, .temp_directory = ".zig-cache/tmp" },
    });
    defer bash.deinit();
    var first = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf first\"}",
        .{},
    );
    defer first.deinit(std.testing.allocator);
    const first_path = try std.testing.allocator.dupe(
        u8,
        bash.kept_outputs.items[0].savedPath().?,
    );
    defer std.testing.allocator.free(first_path);
    var second = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf second\"}",
        .{},
    );
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), bash.kept_outputs.items.len);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, first_path, .{}),
    );
    try std.testing.expect(bash.retained_spill_bytes <= bash.maximum_retained_spill_bytes);
}

test "invalid UTF-8 spill root falls back to a usable private directory" {
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .output = .{ .temp_directory = "\xff" },
    });
    defer bash.deinit();
    try std.testing.expect(std.unicode.utf8ValidateSlice(bash.temp_directory));
    try std.testing.expect(std.mem.startsWith(u8, bash.temp_directory, "/tmp/"));
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, bash.temp_directory, .{});
    try std.testing.expectEqual(@as(u16, 0o700), @intFromEnum(stat.permissions) & 0o777);
}

test "unwritable configured spill root falls back to tmp" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "locked", .default_dir);
    const locked = try tmp.dir.openDir(std.testing.io, "locked", .{});
    defer locked.close(std.testing.io);
    try locked.setPermissions(std.testing.io, @enumFromInt(0o555));
    defer locked.setPermissions(std.testing.io, @enumFromInt(0o755)) catch {};
    const base = try std.fs.path.join(
        std.testing.allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path, "locked" },
    );
    defer std.testing.allocator.free(base);
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .output = .{ .temp_directory = base },
    });
    defer bash.deinit();
    if (std.mem.startsWith(u8, bash.temp_directory, base)) return error.SkipZigTest;
    try std.testing.expect(std.mem.startsWith(u8, bash.temp_directory, "/tmp/"));
}

const RealTaskHarness = struct {
    io: std.Io,

    pub fn nowMs(self: *RealTaskHarness) i64 {
        const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    pub fn wait(self: *RealTaskHarness, milliseconds: u64) void {
        self.io.sleep(
            .fromMilliseconds(@intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))))),
            .awake,
        ) catch |err| std.debug.panic("real task poller sleep failed: {s}", .{@errorName(err)});
    }
};

test "background fast finish stays synchronous and slow command is adopted" {
    var harness: RealTaskHarness = .{ .io = std.testing.io };
    var registry = try TaskRegistryModule.TaskRegistry.init(
        std.testing.allocator,
        TaskRegistryModule.Clock.from(&harness),
        TaskRegistryModule.Poller.from(&harness),
        .{},
    );
    defer registry.deinit();
    var bash = try Bash.init(std.testing.allocator, std.testing.io, .{
        .environment = std.testing.environ,
        .task_registry = &registry,
        .background_yield_ms = 1000,
        .timeout_ms = 20,
    });
    defer bash.deinit();

    var fast = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf fast\",\"background\":true}",
        .{},
    );
    defer fast.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fast\n[finished during launch; no task created]", fast.output);
    try std.testing.expectEqual(@as(usize, 42), fast.hidden_tail_bytes);
    try std.testing.expectEqual(@as(usize, 0), try registry.runningCount());
    // Keep the real detach branch fast after giving process startup a generous
    // window for the fast-finish assertion above.
    bash.background_yield_ms = 20;

    var detached = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf one; sleep 0.1; printf two\",\"background\":true,\"name\":\"slow\"}",
        .{},
    );
    defer detached.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, detached.output, "one") != null);
    try std.testing.expect(std.mem.endsWith(u8, detached.output, "[detached as task slow]"));
    const waited = try registry.wait(std.testing.allocator, "slow", .{ .timeout_ms = 2000 });
    defer std.testing.allocator.free(waited);
    try std.testing.expect(std.mem.indexOf(u8, waited, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, waited, "finished (exit 0)") != null);

    var timed = try bash.tool().run(
        std.testing.allocator,
        std.testing.io,
        "{\"command\":\"printf timeout-start; sleep 0.1; printf timeout-end\"}",
        .{},
    );
    defer timed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, timed.output, "timeout-start") != null);
    try std.testing.expect(std.mem.endsWith(u8, timed.output, "[detached as task t2 after 0s timeout]"));
    const timed_wait = try registry.wait(std.testing.allocator, "t2", .{ .timeout_ms = 2000 });
    defer std.testing.allocator.free(timed_wait);
    try std.testing.expect(std.mem.indexOf(u8, timed_wait, "timeout-end") != null);
}
