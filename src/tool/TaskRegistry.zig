const std = @import("std");
const ToolContract = @import("Tool.zig");
const OutputCap = @import("OutputCap.zig");
const BashOutput = @import("BashOutput.zig");
const ai = @import("../ai/root.zig");
const text = @import("../text/root.zig");

pub const hard_output_bytes: usize = 16 * 1024 * 1024;
pub const maximum_running: usize = 64;
pub const poll_interval_ms: u64 = 20;

pub const Status = union(enum) {
    running,
    exited: u8,
    signaled: u8,
};

pub const Termination = enum { graceful, force };
pub const JobError = error{Unexpected};

/// A log path may be advertised only after the job confirms durable retention.
pub const RetainLogResult = enum { retained, unavailable, durability_uncertain };
pub const ReadOutcome = union(enum) {
    data: usize,
    would_block,
    eof: i64,
    unavailable,
};

pub const OutputSnapshot = struct {
    total_bytes: usize,
    stored_bytes: usize,
    binary: bool = false,
    overflow: bool = false,
    write_failed: bool = false,
    eof_ms: ?i64 = null,
    /// Borrowed and stable until Job deinit.
    saved_path: ?[]const u8 = null,
};

/// Owned erased job. Constructing a Job transfers ownership of its implementation to the
/// handle. A successful `adopt` moves the handle into the registry. This is intentionally not
/// tied to a process: Bash adoption and a process-output drainer are deferred.
pub const Job = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll: *const fn (*anyopaque) JobError!void,
        read_at: *const fn (*anyopaque, usize, []u8) JobError!ReadOutcome,
        output_snapshot: *const fn (*anyopaque) OutputSnapshot,
        /// Must return `.retained` only after the snapshot path is durable and
        /// will survive job deinit. Other outcomes must not advertise it.
        retain_log: *const fn (*anyopaque) JobError!RetainLogResult,
        status: *const fn (*anyopaque) Status,
        terminate: *const fn (*anyopaque, Termination) void,
        /// This is the registry allocator for callback/result context. An
        /// owned job must free itself with the allocator captured at creation.
        deinit: *const fn (std.mem.Allocator, *anyopaque) void,
    };

    pub fn from(implementation: anytype) Job {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("Job.from expects a single-item pointer");
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn poll(context: *anyopaque) JobError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.poll();
            }
            fn readAt(context: *anyopaque, offset: usize, buffer: []u8) JobError!ReadOutcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.readAt(offset, buffer);
            }
            fn outputSnapshot(context: *anyopaque) OutputSnapshot {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.outputSnapshot();
            }
            fn retainLog(context: *anyopaque) JobError!RetainLogResult {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.retainLog();
            }
            fn status(context: *anyopaque) Status {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.status();
            }
            fn terminate(context: *anyopaque, mode: Termination) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.terminate(mode);
            }
            fn deinitFn(allocator: std.mem.Allocator, context: *anyopaque) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.deinit(allocator);
            }
            const vtable: VTable = .{
                .poll = poll,
                .read_at = readAt,
                .output_snapshot = outputSnapshot,
                .retain_log = retainLog,
                .status = status,
                .terminate = terminate,
                .deinit = deinitFn,
            };
        };
        return .{ .context = implementation, .vtable = &Adapter.vtable };
    }

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        self.vtable.deinit(allocator, self.context);
        self.* = undefined;
    }
};

pub const Clock = struct {
    context: *anyopaque,
    now_ms_fn: *const fn (*anyopaque) i64,

    pub fn nowMs(self: Clock) i64 {
        return self.now_ms_fn(self.context);
    }
    pub fn from(implementation: anytype) Clock {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("Clock.from expects a single-item pointer");
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn nowMs(context: *anyopaque) i64 {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.nowMs();
            }
        };
        return .{ .context = implementation, .now_ms_fn = Adapter.nowMs };
    }
};

pub const Poller = struct {
    context: *anyopaque,
    wait_fn: *const fn (*anyopaque, u64) void,

    pub fn wait(self: Poller, milliseconds: u64) void {
        self.wait_fn(self.context, milliseconds);
    }
    pub fn from(implementation: anytype) Poller {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("Poller.from expects a single-item pointer");
        const Implementation = info.pointer.child;
        const Adapter = struct {
            fn wait(context: *anyopaque, milliseconds: u64) void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                self.wait(milliseconds);
            }
        };
        return .{ .context = implementation, .wait_fn = Adapter.wait };
    }
};

pub const Config = struct {
    max_running: usize = 32,
    wait_timeout_ms: u64 = 10 * 60 * 1000,
    termination_grace_ms: u64 = 2 * 1000,
    model_bytes: usize = OutputCap.default_output_bytes,
};

pub const InitError = error{InvalidConfig};
pub const Error = error{ OutOfMemory, InvalidJob, CapacityReached, InvalidName, Reentrant, Busy, OutputUnavailable };

pub const Note = struct {
    text: []u8,
    origin: ai.Item.UserOrigin = .task_note,
    pub fn deinit(self: *Note, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Report = struct {
    body: []u8,
    marker: ?[]u8 = null,
    next_cursor: usize = 0,
    advertised_log: bool = false,
    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.marker) |marker| allocator.free(marker);
        self.* = undefined;
    }
};

pub const WaitOptions = struct {
    timeout_ms: u64,
    kill_on_timeout: bool = false,
    display: ?ToolContract.DisplaySink = null,
    cancel: ?ToolContract.Cancellation = null,
};

const Entry = struct {
    id: []u8,
    command: []u8,
    job: Job,
    started_ms: i64,
    model_bytes: usize = OutputCap.default_output_bytes,
    termination_grace_ms: u64 = 2 * 1000,
    finished_ms: i64 = 0,
    status: Status = .running,
    terminal_status: ?Status = null,
    output_eof: bool = false,
    output_eof_ms: i64 = 0,
    total_bytes: usize = 0,
    stored_bytes: usize = 0,
    delivered_bytes: usize = 0,
    binary: bool = false,
    overflow: bool = false,
    write_failed: bool = false,
    log_advertised: bool = false,
    log_retained: bool = false,
    notified: bool = false,
    collected: bool = false,
};

/// Instance-owned, single-threaded task registry. All progress, time, sleeping, cancellation,
/// and display are injected. Do not copy a live registry; call `shutdown` then `deinit`.
pub const TaskRegistry = struct {
    allocator: std.mem.Allocator,
    clock: Clock,
    poller: Poller,
    config: Config,
    entries: std.ArrayList(Entry) = .empty,
    next_number: usize = 1,
    shut_down: bool = false,
    callback_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, clock: Clock, poller: Poller, config: Config) InitError!TaskRegistry {
        if (config.max_running == 0 or config.max_running > maximum_running or
            config.model_bytes == 0 or config.model_bytes > hard_output_bytes)
            return error.InvalidConfig;
        return .{ .allocator = allocator, .clock = clock, .poller = poller, .config = config };
    }

    /// Requires that no injected callback is active. Call `shutdown` explicitly when an error
    /// must be handled; deinitializing from a callback violates the ownership contract.
    pub fn deinit(self: *TaskRegistry) void {
        std.debug.assert(!self.callback_active);
        self.shutdown() catch unreachable;
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn ensurePublic(self: *const TaskRegistry) Error!void {
        if (self.callback_active) return error.Reentrant;
    }

    fn enterCallback(self: *TaskRegistry) Error!void {
        if (self.callback_active) return error.Reentrant;
        self.callback_active = true;
    }

    fn leaveCallback(self: *TaskRegistry) void {
        std.debug.assert(self.callback_active);
        self.callback_active = false;
    }

    fn clockNow(self: *TaskRegistry) Error!i64 {
        try self.enterCallback();
        defer self.leaveCallback();
        return self.clock.nowMs();
    }

    fn pollerWait(self: *TaskRegistry, milliseconds: u64) Error!void {
        try self.enterCallback();
        defer self.leaveCallback();
        self.poller.wait(milliseconds);
    }

    fn jobPoll(self: *TaskRegistry, index: usize) Error!void {
        try self.enterCallback();
        defer self.leaveCallback();
        self.entries.items[index].job.vtable.poll(
            self.entries.items[index].job.context,
        ) catch return error.InvalidJob;
    }

    fn jobReadAt(self: *TaskRegistry, index: usize, offset: usize, buffer: []u8) Error!ReadOutcome {
        try self.enterCallback();
        defer self.leaveCallback();
        return self.entries.items[index].job.vtable.read_at(
            self.entries.items[index].job.context,
            offset,
            buffer,
        ) catch error.InvalidJob;
    }

    fn jobOutputSnapshot(self: *TaskRegistry, index: usize) Error!OutputSnapshot {
        try self.enterCallback();
        defer self.leaveCallback();
        return self.entries.items[index].job.vtable.output_snapshot(
            self.entries.items[index].job.context,
        );
    }

    fn jobRetainLog(self: *TaskRegistry, index: usize) Error!RetainLogResult {
        try self.enterCallback();
        defer self.leaveCallback();
        return self.entries.items[index].job.vtable.retain_log(
            self.entries.items[index].job.context,
        ) catch error.InvalidJob;
    }

    fn jobStatus(self: *TaskRegistry, index: usize) Error!Status {
        try self.enterCallback();
        defer self.leaveCallback();
        return self.entries.items[index].job.vtable.status(
            self.entries.items[index].job.context,
        );
    }

    fn jobTerminate(self: *TaskRegistry, index: usize, mode: Termination) Error!void {
        try self.enterCallback();
        defer self.leaveCallback();
        self.entries.items[index].job.vtable.terminate(
            self.entries.items[index].job.context,
            mode,
        );
    }

    fn jobDeinit(self: *TaskRegistry, index: usize) Error!void {
        try self.enterCallback();
        defer self.leaveCallback();
        self.entries.items[index].job.vtable.deinit(
            self.allocator,
            self.entries.items[index].job.context,
        );
    }

    fn emitDisplay(self: *TaskRegistry, display: ToolContract.DisplaySink, bytes: []const u8) Error!void {
        try self.enterCallback();
        defer self.leaveCallback();
        display.emit(bytes) catch return error.OutOfMemory;
    }

    fn cancellationRequested(self: *TaskRegistry, cancellation: ToolContract.Cancellation) Error!bool {
        try self.enterCallback();
        defer self.leaveCallback();
        return cancellation.isRequested();
    }

    /// On success the registry takes `job` and sets it to undefined. On failure ownership stays
    /// with the caller. The automatic counter advances for named tasks too.
    pub fn adopt(
        self: *TaskRegistry,
        job: *Job,
        command: []const u8,
        name: ?[]const u8,
        started_ms: i64,
    ) Error![]const u8 {
        try self.ensurePublic();
        self.shut_down = false;
        try self.pollAll();
        if (self.runningCountRaw() >= self.config.max_running) return error.CapacityReached;
        if (name) |value| {
            if (try self.nameErrorRaw(self.allocator, value)) |message| {
                self.allocator.free(message);
                return error.InvalidName;
            }
        }

        const id = if (name) |value|
            try self.allocator.dupe(u8, value)
        else
            try std.fmt.allocPrint(self.allocator, "t{d}", .{self.next_number});
        errdefer self.allocator.free(id);
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        try self.entries.append(self.allocator, .{
            .id = id,
            .command = owned_command,
            .job = job.*,
            .started_ms = started_ms,
            .model_bytes = self.config.model_bytes,
            .termination_grace_ms = self.config.termination_grace_ms,
        });
        job.* = undefined;
        self.next_number += 1;
        return self.entries.items[self.entries.items.len - 1].id;
    }

    /// Returns an owned exact recoverable name error, or null when the name is usable.
    pub fn nameError(
        self: *TaskRegistry,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) Error!?[]u8 {
        try self.ensurePublic();
        return self.nameErrorRaw(allocator, name);
    }

    fn nameErrorRaw(
        self: *const TaskRegistry,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]u8 {
        if (name.len == 0) return @as(?[]u8, try allocator.dupe(u8, "'name' must not be empty"));
        if (name.len > 32)
            return @as(?[]u8, try allocator.dupe(u8, "'name' too long (max 32 characters)"));
        for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return @as(?[]u8, try allocator.dupe(
                u8,
                "'name' may contain only letters, digits, '-' and '_'",
            ));
        if (name[0] == 't' and name.len > 1) {
            var digits = true;
            for (name[1..]) |byte| digits = digits and std.ascii.isDigit(byte);
            if (digits) return @as(?[]u8, try allocator.dupe(
                u8,
                "'name' must not look like an automatic task id (t<number>)",
            ));
        }
        for (self.entries.items) |entry| {
            if (!entry.collected and std.mem.eql(u8, entry.id, name))
                return @as(?[]u8, try std.fmt.allocPrint(
                    allocator,
                    "task name '{s}' is already in use",
                    .{name},
                ));
        }
        return null;
    }

    pub fn runningCount(self: *TaskRegistry) Error!usize {
        try self.ensurePublic();
        try self.pollAll();
        return self.runningCountRaw();
    }

    fn runningCountRaw(self: *const TaskRegistry) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| if (entry.status == .running) {
            count += 1;
        };
        return count;
    }

    fn pollAll(self: *TaskRegistry) Error!void {
        var index: usize = 0;
        while (index < self.entries.items.len) : (index += 1) try self.pollEntry(index);
    }

    fn pollEntry(self: *TaskRegistry, index: usize) Error!void {
        if (self.entries.items[index].status != .running) return;
        try self.jobPoll(index);
        const snapshot = try self.jobOutputSnapshot(index);
        if (snapshot.stored_bytes > snapshot.total_bytes or
            snapshot.stored_bytes > hard_output_bytes or
            snapshot.total_bytes < self.entries.items[index].total_bytes or
            snapshot.stored_bytes < self.entries.items[index].stored_bytes)
            return error.InvalidJob;
        self.entries.items[index].total_bytes = snapshot.total_bytes;
        self.entries.items[index].stored_bytes = snapshot.stored_bytes;
        self.entries.items[index].binary = snapshot.binary;
        self.entries.items[index].overflow = snapshot.overflow;
        self.entries.items[index].write_failed = snapshot.write_failed;
        if (snapshot.eof_ms) |finished_ms| {
            self.entries.items[index].output_eof = true;
            self.entries.items[index].output_eof_ms = finished_ms;
        }
        if (self.entries.items[index].terminal_status == null) {
            const status = try self.jobStatus(index);
            if (status != .running) self.entries.items[index].terminal_status = status;
        }
        if (self.entries.items[index].terminal_status) |terminal| {
            if (self.entries.items[index].output_eof) {
                self.entries.items[index].status = terminal;
                self.entries.items[index].finished_ms = self.entries.items[index].output_eof_ms;
            }
        }
    }

    fn findIndex(self: *const TaskRegistry, id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.collected and std.mem.eql(u8, entry.id, id)) return index;
        }
        return null;
    }

    pub fn reportOutput(
        self: *TaskRegistry,
        result_allocator: std.mem.Allocator,
        id: []const u8,
    ) Error!?Report {
        try self.ensurePublic();
        try self.pollAll();
        const index = self.findIndex(id) orelse return null;
        var report = try self.collectOutput(result_allocator, index);
        errdefer report.deinit(result_allocator);
        try self.finalizeReport(result_allocator, index, &report);
        self.commitReport(index, report);
        return @as(?Report, report);
    }

    fn finalizeReport(
        self: *TaskRegistry,
        result_allocator: std.mem.Allocator,
        index: usize,
        report: *Report,
    ) Error!void {
        if (!report.advertised_log or self.entries.items[index].log_retained) return;
        // Allocate both outcomes before the irreversible durability request.
        // An OOM here leaves retention and the delivery cursor untouched.
        var failed = try retentionFailedReport(result_allocator, report.*);
        errdefer failed.deinit(result_allocator);
        const retained = try self.jobRetainLog(index);
        if (retained == .retained) {
            failed.deinit(result_allocator);
            self.entries.items[index].log_retained = true;
        } else {
            report.deinit(result_allocator);
            report.* = failed;
        }
    }

    fn commitReport(self: *TaskRegistry, index: usize, report: Report) void {
        self.entries.items[index].log_advertised =
            self.entries.items[index].log_advertised or report.advertised_log;
        self.entries.items[index].delivered_bytes = report.next_cursor;
    }

    fn collectOutput(
        self: *TaskRegistry,
        result_allocator: std.mem.Allocator,
        index: usize,
    ) Error!Report {
        const from = self.entries.items[index].delivered_bytes;
        const total_bytes = self.entries.items[index].total_bytes;
        if (total_bytes <= from)
            return .{ .body = try result_allocator.alloc(u8, 0), .next_cursor = from };
        const stored_bytes = self.entries.items[index].stored_bytes;
        const binary = self.entries.items[index].binary;
        const overflow = self.entries.items[index].overflow;
        const write_failed = self.entries.items[index].write_failed;
        const snapshot = try self.jobOutputSnapshot(index);
        const needs_log = binary or overflow or write_failed or stored_bytes > @min(from, stored_bytes);
        const clean_path = if (needs_log and snapshot.saved_path != null)
            try sanitizedPath(result_allocator, snapshot.saved_path.?)
        else
            null;
        defer if (clean_path) |path| result_allocator.free(path);

        if (binary) {
            const body = try result_allocator.alloc(u8, 0);
            errdefer result_allocator.free(body);
            const marker = if (clean_path) |path|
                try std.fmt.allocPrint(
                    result_allocator,
                    "[binary output suppressed: {d} bytes total; log: {s}]",
                    .{ total_bytes, path },
                )
            else
                try std.fmt.allocPrint(
                    result_allocator,
                    "[binary output suppressed: {d} bytes total]",
                    .{total_bytes},
                );
            return .{
                .body = body,
                .marker = marker,
                .next_cursor = total_bytes,
                .advertised_log = clean_path != null,
            };
        }
        if (write_failed) {
            const body = try result_allocator.alloc(u8, 0);
            errdefer result_allocator.free(body);
            const marker = if (clean_path) |path|
                try std.fmt.allocPrint(
                    result_allocator,
                    "[output unavailable: spool write failed; partial log: {s}]",
                    .{path},
                )
            else
                try result_allocator.dupe(u8, "[output unavailable: spool write failed]");
            return .{
                .body = body,
                .marker = marker,
                .next_cursor = total_bytes,
                .advertised_log = clean_path != null,
            };
        }

        const available_from = @min(from, stored_bytes);
        const stored_pending = stored_bytes - available_from;
        var body: []u8 = undefined;
        var body_omitted = false;
        var advertised_log = false;
        if (stored_pending == 0) {
            body = try result_allocator.alloc(u8, 0);
        } else if (stored_pending <= self.entries.items[index].model_bytes) {
            const raw = self.readRange(
                result_allocator,
                index,
                available_from,
                stored_pending,
            ) catch |err| switch (err) {
                error.OutputUnavailable => return unavailableReport(result_allocator, total_bytes, clean_path),
                else => return err,
            };
            defer result_allocator.free(raw);
            body_omitted = requiresShaping(raw, self.entries.items[index].model_bytes);
            body = try modelSlice(result_allocator, raw, self.entries.items[index].model_bytes);
        } else {
            body = self.readCappedRange(
                result_allocator,
                index,
                available_from,
                stored_bytes,
                clean_path,
            ) catch |err| switch (err) {
                error.OutputUnavailable => return unavailableReport(result_allocator, total_bytes, clean_path),
                else => return err,
            };
            advertised_log = if (clean_path) |path|
                "\n... [output truncated; full output: ".len + path.len + "] ...\n".len <
                    self.entries.items[index].model_bytes
            else
                false;
        }
        errdefer result_allocator.free(body);
        var marker_builder: std.ArrayList(u8) = .empty;
        defer marker_builder.deinit(result_allocator);
        if (body_omitted) {
            if (clean_path) |path| {
                try appendPrint(result_allocator, &marker_builder, "[output capped; full output: {s}]", .{path});
                advertised_log = true;
            }
        }
        if (overflow and total_bytes > stored_bytes) {
            if (marker_builder.items.len > 0) try marker_builder.append(result_allocator, '\n');
            if (clean_path) |path| {
                try appendPrint(
                    result_allocator,
                    &marker_builder,
                    "[output limit reached: {d} further bytes discarded, task stopped; log: {s}]",
                    .{ total_bytes - stored_bytes, path },
                );
                advertised_log = true;
            } else try appendPrint(
                result_allocator,
                &marker_builder,
                "[output limit reached: {d} further bytes discarded, task stopped]",
                .{total_bytes - stored_bytes},
            );
        }
        const marker = if (marker_builder.items.len > 0)
            try marker_builder.toOwnedSlice(result_allocator)
        else
            null;
        return .{
            .body = body,
            .marker = marker,
            .next_cursor = total_bytes,
            .advertised_log = advertised_log,
        };
    }

    fn readRange(
        self: *TaskRegistry,
        allocator: std.mem.Allocator,
        index: usize,
        offset: usize,
        length: usize,
    ) Error![]u8 {
        if (length > self.entries.items[index].model_bytes) return error.InvalidJob;
        const result = try allocator.alloc(u8, length);
        errdefer allocator.free(result);
        var filled: usize = 0;
        var calls: usize = 0;
        while (filled < length and calls < 64) : (calls += 1) {
            const outcome = try self.jobReadAt(index, offset + filled, result[filled..]);
            switch (outcome) {
                .data => |amount| {
                    if (amount == 0 or amount > length - filled) return error.InvalidJob;
                    filled += amount;
                },
                .would_block, .eof, .unavailable => return error.OutputUnavailable,
            }
        }
        if (filled != length) return error.OutputUnavailable;
        return result;
    }

    fn readCappedRange(
        self: *TaskRegistry,
        allocator: std.mem.Allocator,
        index: usize,
        from: usize,
        to: usize,
        clean_path: ?[]const u8,
    ) Error![]u8 {
        const maximum = self.entries.items[index].model_bytes;
        var marker_buffer: [2304]u8 = undefined;
        const marker = if (clean_path) |path|
            std.fmt.bufPrint(
                &marker_buffer,
                "\n... [output truncated; full output: {s}] ...\n",
                .{path},
            ) catch "\n... [output truncated] ...\n"
        else
            "\n... [output truncated; full output unavailable] ...\n";
        if (marker.len >= maximum)
            return self.readRange(allocator, index, from, maximum);
        const head_budget = (maximum - marker.len) / BashOutput.head_divisor;
        const tail_budget = maximum - marker.len - head_budget;
        const raw_head = try self.readRange(allocator, index, from, head_budget);
        defer allocator.free(raw_head);
        const raw_tail = try self.readRange(allocator, index, to - tail_budget, tail_budget);
        defer allocator.free(raw_tail);
        const head = headEnd(raw_head, raw_head.len, OutputCap.maximum_lines / 8 - 1);
        const tail = tailStart(
            raw_tail,
            raw_tail.len,
            OutputCap.maximum_lines - OutputCap.maximum_lines / 8 - 2,
        );
        var selected: std.ArrayList(u8) = .empty;
        defer selected.deinit(allocator);
        try selected.appendSlice(allocator, raw_head[0..head]);
        try selected.appendSlice(allocator, marker);
        try selected.appendSlice(allocator, raw_tail[tail..]);
        return formatPiece(allocator, selected.items, maximum);
    }

    pub fn wait(
        self: *TaskRegistry,
        result_allocator: std.mem.Allocator,
        id: []const u8,
        options: WaitOptions,
    ) Error![]u8 {
        try self.ensurePublic();
        try self.pollAll();
        const index = self.findIndex(id) orelse
            return unknownTask(result_allocator, id);
        var deadline = saturatingDeadline(try self.clockNow(), options.timeout_ms);
        var force_deadline: i64 = 0;
        var displayed_bytes = self.entries.items[index].delivered_bytes;
        var displayed_body = false;
        var stop: WaitStop = .target_done;
        var kill_sent = false;
        while (self.entries.items[index].status == .running) {
            try self.streamDisplay(index, options.display, &displayed_bytes, &displayed_body);
            const now = try self.clockNow();
            if (kill_sent and self.entries.items[index].status == .running and now >= force_deadline) {
                try self.jobTerminate(index, .force);
                force_deadline = std.math.maxInt(i64);
            }
            if (now >= deadline) {
                if (options.kill_on_timeout and !kill_sent) {
                    kill_sent = true;
                    if (self.entries.items[index].termination_grace_ms == 0) {
                        try self.jobTerminate(index, .force);
                        force_deadline = std.math.maxInt(i64);
                        deadline = saturatingDeadline(now, 3000);
                    } else {
                        try self.jobTerminate(index, .graceful);
                        force_deadline = saturatingDeadline(now, self.entries.items[index].termination_grace_ms);
                        deadline = saturatingDeadline(force_deadline, 3000);
                    }
                    try self.pollAll();
                    continue;
                } else {
                    stop = .timed_out;
                    break;
                }
            }
            if (!kill_sent and self.foreignFinished(index)) {
                stop = .other_done;
                break;
            }
            if (options.cancel) |cancel| if (try self.cancellationRequested(cancel)) {
                stop = .interrupted;
                break;
            };
            try self.pollerWait(poll_interval_ms);
            try self.pollAll();
        }
        try self.pollAll();
        try self.streamDisplay(index, options.display, &displayed_bytes, &displayed_body);
        var report = try self.collectOutput(result_allocator, index);
        defer report.deinit(result_allocator);
        const footer_text = try self.footer(
            result_allocator,
            index,
            stop,
            options.kill_on_timeout,
            report.body.len == 0 and report.marker == null,
        );
        defer result_allocator.free(footer_text);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(result_allocator);
        const current_marker_bytes = if (report.marker) |marker| marker.len else 0;
        const marker_bytes = @max(current_marker_bytes, retention_failure_marker.len);
        const reserved = std.math.add(usize, report.body.len, marker_bytes + footer_text.len + 2) catch
            return error.OutOfMemory;
        try out.ensureTotalCapacity(result_allocator, reserved);
        try self.finalizeReport(result_allocator, index, &report);
        if (report.body.len > 0) try out.appendSlice(result_allocator, report.body);
        if (report.marker) |marker| {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n')
                try out.append(result_allocator, '\n');
            try out.appendSlice(result_allocator, marker);
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n')
            try out.append(result_allocator, '\n');
        if (options.display) |display| {
            if (!displayed_body and report.body.len > 0) {
                try self.emitDisplay(display, report.body);
                displayed_body = true;
            }
            if (report.marker) |marker| {
                if (displayed_body) try self.emitDisplay(display, "\n");
                try self.emitDisplay(display, marker);
                displayed_body = true;
            }
        }
        try out.appendSlice(result_allocator, footer_text);
        if (options.display) |display| {
            if (displayed_body) try self.emitDisplay(display, "\n");
            try self.emitDisplay(display, footer_text);
        }
        const owned = try out.toOwnedSlice(result_allocator);
        errdefer result_allocator.free(owned);
        self.commitReport(index, report);
        if (self.entries.items[index].status != .running) {
            self.entries.items[index].notified = true;
            self.entries.items[index].collected = true;
        }
        try self.sweep();
        return owned;
    }

    fn streamDisplay(
        self: *TaskRegistry,
        index: usize,
        display: ?ToolContract.DisplaySink,
        cursor: *usize,
        displayed: *bool,
    ) Error!void {
        const sink = display orelse return;
        if (self.entries.items[index].binary) return;
        const end = self.entries.items[index].stored_bytes;
        var buffer: [8192]u8 = undefined;
        var calls: usize = 0;
        var forwarded: usize = 0;
        while (cursor.* < end and calls < 32 and forwarded < 256 * 1024) : (calls += 1) {
            const wanted = @min(buffer.len, @min(end - cursor.*, 256 * 1024 - forwarded));
            const outcome = try self.jobReadAt(index, cursor.*, buffer[0..wanted]);
            switch (outcome) {
                .data => |amount| {
                    if (amount == 0 or amount > wanted) return error.InvalidJob;
                    try self.emitDisplay(sink, buffer[0..amount]);
                    cursor.* += amount;
                    forwarded += amount;
                    displayed.* = true;
                },
                .would_block, .eof, .unavailable => break,
            }
        }
    }

    fn foreignFinished(self: *const TaskRegistry, target_index: usize) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (index != target_index and entry.status != .running and !entry.notified) return true;
        }
        return false;
    }

    fn footer(
        self: *TaskRegistry,
        allocator: std.mem.Allocator,
        index: usize,
        stop: WaitStop,
        kill: bool,
        no_output: bool,
    ) Error![]u8 {
        const now = if (self.entries.items[index].status == .running) try self.clockNow() else 0;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "[");
        try out.appendSlice(allocator, self.entries.items[index].id);
        try out.append(allocator, ' ');
        try appendStatus(allocator, &out, self.entries.items[index], now);
        if (kill and stop == .other_done) try out.appendSlice(allocator, "; not killed");
        if (no_output) try out.appendSlice(allocator, "; no new output");
        switch (stop) {
            .timed_out => try out.appendSlice(
                allocator,
                if (kill) " — did not exit after SIGKILL" else " — wait timed out",
            ),
            .interrupted => try out.appendSlice(allocator, " — wait interrupted"),
            .other_done => try out.appendSlice(allocator, " — another task finished"),
            .target_done => {},
        }
        try out.append(allocator, ']');
        return out.toOwnedSlice(allocator);
    }

    pub fn collectNotes(self: *TaskRegistry) Error!?Note {
        try self.ensurePublic();
        try self.pollAll();
        // Sweep older collected jobs before planning this notification. After
        // the note allocation succeeds, no fallible work may precede marking.
        try self.sweep();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var plan: std.ArrayList(usize) = .empty;
        defer plan.deinit(self.allocator);
        for (self.entries.items, 0..) |entry, index| {
            if (entry.notified or entry.status == .running) continue;
            try plan.append(self.allocator, index);
            if (out.items.len > 0) try out.append(self.allocator, '\n');
            try out.appendSlice(self.allocator, "[task ");
            try out.appendSlice(self.allocator, entry.id);
            try out.append(self.allocator, ' ');
            try appendStatus(self.allocator, &out, entry, 0);
            const pending = entry.total_bytes -| entry.delivered_bytes;
            if (entry.total_bytes == 0) {
                try out.appendSlice(self.allocator, "; no output]");
            } else if (pending == 0) {
                try out.appendSlice(self.allocator, "; no new output]");
            } else try appendPrint(self.allocator, &out, "; {f}{s} output]", .{
                BashOutput.formatByteSize(pending),
                if (entry.binary) " binary" else "",
            });
        }
        if (out.items.len == 0) {
            out.deinit(self.allocator);
            return null;
        }
        const owned = try out.toOwnedSlice(self.allocator);
        for (plan.items) |index| {
            self.entries.items[index].notified = true;
            if (self.entries.items[index].total_bytes == self.entries.items[index].delivered_bytes)
                self.entries.items[index].collected = true;
        }
        return .{ .text = owned };
    }

    pub fn exitNote(self: *TaskRegistry) Error!?Note {
        try self.ensurePublic();
        try self.pollAll();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        for (self.entries.items) |entry| {
            if (entry.collected) continue;
            if (out.items.len > 0) try out.append(self.allocator, '\n');
            try out.appendSlice(self.allocator, "[task ");
            try out.appendSlice(self.allocator, entry.id);
            try out.append(self.allocator, ' ');
            if (entry.status == .running) try out.appendSlice(self.allocator, "killed at exit]") else {
                try appendStatus(self.allocator, &out, entry, 0);
                const pending = entry.total_bytes -| entry.delivered_bytes;
                if (pending > 0) try appendPrint(self.allocator, &out, "; {f} output discarded", .{
                    BashOutput.formatByteSize(pending),
                });
                try out.append(self.allocator, ']');
            }
        }
        if (out.items.len == 0) {
            out.deinit(self.allocator);
            return null;
        }
        return .{ .text = try out.toOwnedSlice(self.allocator) };
    }

    fn sweep(self: *TaskRegistry) Error!void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (self.entries.items[index].collected and self.entries.items[index].status != .running) {
                try self.jobDeinit(index);
                const removed = self.entries.orderedRemove(index);
                self.allocator.free(removed.id);
                self.allocator.free(removed.command);
            } else index += 1;
        }
    }

    /// Idempotently force-terminates and destroys every owned job. Automatic ids restart at t1.
    /// Returns `error.Reentrant` without mutation when invoked by an injected callback.
    pub fn shutdown(self: *TaskRegistry) Error!void {
        try self.ensurePublic();
        if (self.shut_down) return;
        var index: usize = 0;
        while (index < self.entries.items.len) : (index += 1) {
            if (self.entries.items[index].status == .running)
                try self.jobTerminate(index, .force);
            try self.jobDeinit(index);
            self.allocator.free(self.entries.items[index].id);
            self.allocator.free(self.entries.items[index].command);
        }
        self.entries.clearRetainingCapacity();
        self.next_number = 1;
        self.shut_down = true;
    }
};

const WaitStop = enum { target_done, other_done, timed_out, interrupted };

const retention_failure_marker =
    "[full output unavailable: log retention or durability could not be confirmed]";

fn retentionFailedReport(allocator: std.mem.Allocator, report: Report) Error!Report {
    const body = try allocator.dupe(u8, report.body);
    errdefer allocator.free(body);
    return .{
        .body = body,
        .marker = try allocator.dupe(u8, retention_failure_marker),
        .next_cursor = report.next_cursor,
    };
}

fn unavailableReport(
    allocator: std.mem.Allocator,
    next_cursor: usize,
    clean_path: ?[]const u8,
) Error!Report {
    const body = try allocator.alloc(u8, 0);
    errdefer allocator.free(body);
    const marker = if (clean_path) |path|
        try std.fmt.allocPrint(
            allocator,
            "[output unavailable: log read failed; log: {s}]",
            .{path},
        )
    else
        try allocator.dupe(u8, "[output unavailable: log read failed]");
    return .{
        .body = body,
        .marker = marker,
        .next_cursor = next_cursor,
        .advertised_log = clean_path != null,
    };
}

fn sanitizedPath(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    const bounded = path[0..@min(path.len, 1024)];
    const clean = text.Utf8.sanitize(allocator, bounded, 2048) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.InvalidJob,
    };
    for (clean) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
        byte.* = '?';
    };
    return clean;
}

fn unknownTask(allocator: std.mem.Allocator, id: []const u8) Error![]u8 {
    const input_bytes = @min(id.len, 1024);
    const input_truncated = input_bytes != id.len;
    const clean = text.Utf8.sanitize(allocator, id[0..input_bytes], 4096) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.InvalidJob,
    };
    defer allocator.free(clean);
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(allocator);
    var previous_space = false;
    for (clean) |byte| {
        const ascii_space = byte <= 0x20 or byte == 0x7f;
        if (ascii_space) {
            if (!previous_space) try flat.append(allocator, ' ');
            previous_space = true;
        } else {
            try flat.append(allocator, byte);
            previous_space = false;
        }
    }
    const maximum_cells: usize = 60;
    var offset = displayPrefix(flat.items, maximum_cells);
    const truncated = input_truncated or offset < flat.items.len;
    if (truncated) offset = displayPrefix(flat.items, maximum_cells - 3);
    return if (truncated)
        std.fmt.allocPrint(allocator, "no such task: {s}...", .{flat.items[0..offset]})
    else
        std.fmt.allocPrint(allocator, "no such task: {s}", .{flat.items[0..offset]});
}

fn displayPrefix(bytes: []const u8, maximum_cells: usize) usize {
    var offset: usize = 0;
    var cells: usize = 0;
    while (offset < bytes.len) {
        const sequence = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch 1;
        if (offset + sequence > bytes.len) break;
        const codepoint: u21 = switch (sequence) {
            1 => bytes[offset],
            2 => std.unicode.utf8Decode2(bytes[offset..][0..2].*) catch bytes[offset],
            3 => std.unicode.utf8Decode3(bytes[offset..][0..3].*) catch bytes[offset],
            4 => std.unicode.utf8Decode4(bytes[offset..][0..4].*) catch bytes[offset],
            else => unreachable,
        };
        const width = codepointCells(codepoint);
        if (cells + width > maximum_cells) break;
        cells += width;
        offset += sequence;
    }
    return offset;
}

fn codepointCells(codepoint: u21) usize {
    if ((codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f)) return 0;
    if (codepoint >= 0x1100 and
        (codepoint <= 0x115f or codepoint == 0x2329 or codepoint == 0x232a or
            (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
            (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
            (codepoint >= 0xf900 and codepoint <= 0xfaff) or
            (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
            (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
            (codepoint >= 0xff00 and codepoint <= 0xff60) or
            (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
            (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
            (codepoint >= 0x20000 and codepoint <= 0x3fffd))) return 2;
    return 1;
}

fn saturatingDeadline(now: i64, duration_ms: u64) i64 {
    if (duration_ms > @as(u64, @intCast(std.math.maxInt(i64) - @max(now, 0)))) return std.math.maxInt(i64);
    return now + @as(i64, @intCast(duration_ms));
}

fn appendStatus(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entry: Entry,
    now_ms: i64,
) error{OutOfMemory}!void {
    const end = if (entry.status == .running) now_ms else entry.finished_ms;
    const elapsed = if (end <= entry.started_ms) 0 else end -| entry.started_ms;
    switch (entry.status) {
        .running => try appendPrint(allocator, out, "still running ({f})", .{Duration{ .ms = elapsed }}),
        .exited => |code| try appendPrint(
            allocator,
            out,
            "finished (exit {d}) after {f}",
            .{ code, Duration{ .ms = elapsed } },
        ),
        .signaled => |signal| try appendPrint(
            allocator,
            out,
            "killed (signal {d}) after {f}",
            .{ signal, Duration{ .ms = elapsed } },
        ),
    }
}

pub const Duration = struct {
    ms: i64,
    pub fn format(self: Duration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const positive = @max(self.ms, 0);
        const seconds = @divTrunc(positive, 1000) + @intFromBool(@rem(positive, 1000) >= 500);
        if (seconds < 60) return writer.print("{d}s", .{seconds});
        if (seconds < 3600 and @rem(seconds, 60) == 0)
            return writer.print("{d}m", .{@divTrunc(seconds, 60)});
        if (seconds < 3600)
            return writer.print("{d}m {d:0>2}s", .{ @divTrunc(seconds, 60), @rem(seconds, 60) });
        if (@rem(seconds, 3600) == 0)
            return writer.print("{d}h", .{@divTrunc(seconds, 3600)});
        return writer.print("{d}h {d:0>2}m", .{
            @divTrunc(seconds, 3600),
            @divTrunc(@rem(seconds, 3600), 60),
        });
    }
};

fn appendPrint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime format: []const u8, // ziglint-ignore: Z023
    args: anytype,
) error{OutOfMemory}!void {
    const bytes = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(bytes);
    try out.appendSlice(allocator, bytes);
}

fn requiresShaping(raw: []const u8, maximum: usize) bool {
    if (raw.len > maximum or countLines(raw) > OutputCap.maximum_lines) return true;
    var line_bytes: usize = 0;
    for (raw) |byte| {
        if (byte == '\n') {
            line_bytes = 0;
        } else {
            line_bytes += 1;
            if (line_bytes > OutputCap.maximum_line_bytes) return true;
        }
    }
    return false;
}

fn modelSlice(allocator: std.mem.Allocator, raw: []const u8, maximum: usize) Error![]u8 {
    const line_count = countLines(raw);
    if (raw.len <= maximum and line_count <= OutputCap.maximum_lines)
        return formatPiece(allocator, raw, maximum);

    const head_budget = maximum / BashOutput.head_divisor;
    const provisional_head = headEnd(raw, head_budget, OutputCap.maximum_lines / 8 - 1);
    const provisional_tail = tailStart(
        raw,
        maximum -| head_budget,
        OutputCap.maximum_lines - OutputCap.maximum_lines / 8 - 2,
    );
    const omitted = provisional_tail -| provisional_head;
    var marker_buffer: [96]u8 = undefined;
    const marker = std.fmt.bufPrint(
        &marker_buffer,
        "\n... [output truncated: omitted {f}] ...\n",
        .{BashOutput.formatByteSize(omitted)},
    ) catch unreachable;
    if (marker.len + @min(head_budget, raw.len) > maximum)
        return formatPiece(allocator, raw[0..@min(raw.len, maximum)], maximum);

    const head = headEnd(raw, head_budget, OutputCap.maximum_lines / 8 - 1);
    const tail_budget = maximum -| head -| marker.len;
    const tail = tailStart(
        raw,
        tail_budget,
        OutputCap.maximum_lines - OutputCap.maximum_lines / 8 - 2,
    );
    var selected: std.ArrayList(u8) = .empty;
    defer selected.deinit(allocator);
    try selected.appendSlice(allocator, raw[0..head]);
    try selected.appendSlice(allocator, marker);
    try selected.appendSlice(allocator, raw[tail..]);
    return formatPiece(allocator, selected.items, maximum);
}

fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var lines: usize = @intFromBool(bytes[bytes.len - 1] != '\n');
    for (bytes) |byte| lines += @intFromBool(byte == '\n');
    return lines;
}

fn headEnd(bytes: []const u8, byte_limit: usize, line_limit: usize) usize {
    var offset: usize = 0;
    var lines: usize = 0;
    while (offset < bytes.len and offset < byte_limit and lines < line_limit) : (offset += 1)
        lines += @intFromBool(bytes[offset] == '\n');
    return offset;
}

fn tailStart(bytes: []const u8, byte_limit: usize, line_limit: usize) usize {
    var offset = bytes.len -| @min(bytes.len, byte_limit);
    var lines = countLines(bytes[offset..]);
    while (lines > line_limit and offset < bytes.len) : (offset += 1)
        lines -= @intFromBool(bytes[offset] == '\n');
    return offset;
}

fn formatPiece(allocator: std.mem.Allocator, bytes: []const u8, maximum: usize) Error![]u8 {
    const line_capped = OutputCap.capLineLengths(
        allocator,
        bytes,
        OutputCap.maximum_line_bytes,
        std.math.maxInt(usize),
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.InvalidJob,
    };
    defer allocator.free(line_capped);
    var end = @min(line_capped.len, maximum);
    while (true) {
        return text.Utf8.sanitize(allocator, line_capped[0..end], maximum) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResultTooLarge => {
                if (end == 0) return allocator.alloc(u8, 0);
                end -= 1;
                continue;
            },
        };
    }
}

const TestTime = struct {
    now_ms: i64 = 0,
    fn nowMs(self: *TestTime) i64 {
        return self.now_ms;
    }
    fn wait(self: *TestTime, milliseconds: u64) void {
        self.now_ms += @intCast(milliseconds);
    }
};

const ScriptedJob = struct {
    bytes: []const u8,
    offset: usize = 0,
    read_calls: usize = 0,
    polls: usize = 0,
    finish_after: usize,
    eof_ms: i64 = 0,
    total_override: ?usize = null,
    overflow: bool = false,
    write_failed: bool = false,
    unavailable: bool = false,
    saved_path: ?[]const u8 = null,
    retained: bool = false,
    retain_calls: usize = 0,
    retain_result: RetainLogResult = .retained,
    stopped: bool = false,
    force_stopped: bool = false,

    fn poll(self: *ScriptedJob) JobError!void {
        self.polls += 1;
    }
    fn readAt(self: *ScriptedJob, offset: usize, buffer: []u8) JobError!ReadOutcome {
        self.read_calls += 1;
        if (self.unavailable) return .unavailable;
        if (offset >= self.bytes.len) return .{ .eof = self.eof_ms };
        const amount = @min(buffer.len, self.bytes.len - offset);
        @memcpy(buffer[0..amount], self.bytes[offset..][0..amount]);
        return .{ .data = amount };
    }
    fn outputSnapshot(self: *ScriptedJob) OutputSnapshot {
        return .{
            .total_bytes = self.total_override orelse self.bytes.len,
            .stored_bytes = self.bytes.len,
            .binary = std.mem.findScalar(u8, self.bytes, 0) != null,
            .overflow = self.overflow,
            .write_failed = self.write_failed,
            .eof_ms = self.eof_ms,
            .saved_path = self.saved_path,
        };
    }
    fn retainLog(self: *ScriptedJob) JobError!RetainLogResult {
        self.retained = true;
        self.retain_calls += 1;
        return self.retain_result;
    }
    fn status(self: *ScriptedJob) Status {
        if (self.force_stopped) return .{ .signaled = 9 };
        if (self.stopped) return .{ .signaled = 15 };
        return if (self.polls >= self.finish_after) .{ .exited = 0 } else .running;
    }
    fn terminate(self: *ScriptedJob, mode: Termination) void {
        switch (mode) {
            .graceful => self.stopped = true,
            .force => self.force_stopped = true,
        }
    }
    fn deinit(self: *ScriptedJob, allocator: std.mem.Allocator) void { // ziglint-ignore: Z030
        allocator.destroy(self);
    }
};

fn scriptedJob(allocator: std.mem.Allocator, bytes: []const u8, finish_after: usize) !Job {
    const implementation = try allocator.create(ScriptedJob);
    implementation.* = .{ .bytes = bytes, .finish_after = finish_after };
    return Job.from(implementation);
}

test "registry owns jobs, assigns positional ids, advances cursor, and resets on shutdown" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    var first = try scriptedJob(std.testing.allocator, "one", 2);
    try std.testing.expectEqualStrings("t1", try registry.adopt(&first, "printf one", null, 0));
    registry.config.model_bytes = 777;
    registry.config.termination_grace_ms = 99;
    var second = try scriptedJob(std.testing.allocator, "two", 1);
    try std.testing.expectEqualStrings("named", try registry.adopt(&second, "printf two", "named", 0));
    try std.testing.expectEqual(OutputCap.default_output_bytes, registry.entries.items[0].model_bytes);
    try std.testing.expectEqual(@as(u64, 2 * 1000), registry.entries.items[0].termination_grace_ms);
    try std.testing.expectEqual(@as(usize, 777), registry.entries.items[1].model_bytes);
    try std.testing.expectEqual(@as(u64, 99), registry.entries.items[1].termination_grace_ms);
    var report = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("one", report.body);
    var again = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer again.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), again.body.len);
    var note = (try registry.collectNotes()).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai.Item.UserOrigin.task_note, note.origin);
    try std.testing.expectEqualStrings(
        "[task t1 finished (exit 0) after 0s; no new output]\n" ++
            "[task named finished (exit 0) after 0s; 3B output]",
        note.text,
    );
    registry.shutdown() catch unreachable;
    registry.shutdown() catch unreachable;
    var reset = try scriptedJob(std.testing.allocator, "", 1);
    try std.testing.expectEqualStrings("t1", try registry.adopt(&reset, "true", null, 0));
}

test "name rules and immediate kill use exact recoverable text" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    const cases = [_]struct { name: []const u8, message: []const u8 }{
        .{ .name = "", .message = "'name' must not be empty" },
        .{ .name = "bad name", .message = "'name' may contain only letters, digits, '-' and '_'" },
        .{ .name = "t42", .message = "'name' must not look like an automatic task id (t<number>)" },
    };
    for (cases) |case| {
        const message = (try registry.nameError(std.testing.allocator, case.name)).?;
        defer std.testing.allocator.free(message);
        try std.testing.expectEqualStrings(case.message, message);
    }
    var job = try scriptedJob(std.testing.allocator, "partial", std.math.maxInt(usize));
    _ = try registry.adopt(&job, "long", "build", 0);
    const duplicate = (try registry.nameError(std.testing.allocator, "build")).?;
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectEqualStrings("task name 'build' is already in use", duplicate);
    const result = try registry.wait(std.testing.allocator, "build", .{ .timeout_ms = 0, .kill_on_timeout = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("partial\n[build killed (signal 15) after 0s]", result);
}

test "binary output is suppressed and finished output remains collectable after its note" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    var job = try scriptedJob(std.testing.allocator, "a\x00b", 1);
    _ = try registry.adopt(&job, "binary", null, 0);
    var note = (try registry.collectNotes()).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[task t1 finished (exit 0) after 0s; 3B binary output]", note.text);
    const result = try registry.wait(std.testing.allocator, "t1", .{ .timeout_ms = 0 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "[binary output suppressed: 3 bytes total]\n[t1 finished (exit 0) after 0s]",
        result,
    );
    const missing = try registry.wait(std.testing.allocator, "t1", .{ .timeout_ms = 0 });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("no such task: t1", missing);
}

const CallbackCounts = struct {
    terminate: usize = 0,
    deinit: usize = 0,
    reentrant: usize = 0,
};

const ReentrantJob = struct {
    registry: *TaskRegistry,
    counts: *CallbackCounts,
    finished: bool = false,

    fn poll(self: *ReentrantJob) JobError!void {
        if (self.registry.shutdown()) |_| return error.Unexpected else |err| {
            if (err == error.Reentrant) self.counts.reentrant += 1 else return error.Unexpected;
        }
        self.finished = true;
    }
    fn readAt(_: *ReentrantJob, _: usize, _: []u8) JobError!ReadOutcome {
        return .{ .eof = 0 };
    }
    fn outputSnapshot(_: *ReentrantJob) OutputSnapshot {
        return .{ .total_bytes = 0, .stored_bytes = 0, .eof_ms = 0 };
    }
    fn retainLog(_: *ReentrantJob) JobError!RetainLogResult {
        return .unavailable;
    }
    fn status(self: *ReentrantJob) Status {
        return if (self.finished) .{ .exited = 0 } else .running;
    }
    fn terminate(self: *ReentrantJob, _: Termination) void {
        self.counts.terminate += 1;
    }
    fn deinit(self: *ReentrantJob, allocator: std.mem.Allocator) void { // ziglint-ignore: Z030
        self.counts.deinit += 1;
        allocator.destroy(self);
    }
};

test "result allocator is distinct and OOM never advances the delivery cursor" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    var job = try scriptedJob(std.testing.allocator, "retry me", 1);
    _ = try registry.adopt(&job, "echo", null, 0);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        registry.reportOutput(failing.allocator(), "t1"),
    );
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var report = (try registry.reportOutput(fixed.allocator(), "t1")).?;
    defer report.deinit(fixed.allocator());
    try std.testing.expectEqualStrings("retry me", report.body);
}

test "job callback reentry is rejected without mutation and teardown runs once" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    var counts: CallbackCounts = .{};
    const implementation = try std.testing.allocator.create(ReentrantJob);
    implementation.* = .{ .registry = &registry, .counts = &counts };
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "callback", null, 0);
    _ = try registry.runningCount();
    try std.testing.expectEqual(@as(usize, 1), counts.reentrant);
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    registry.entries.items[0].collected = true;
    try registry.sweep();
    try std.testing.expectEqual(@as(usize, 1), counts.deinit);
    try std.testing.expectEqual(@as(usize, 0), counts.terminate);
}

test "adopt allocation failure retains job ownership and shutdown destroys once" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    var job = try scriptedJob(std.testing.allocator, "", 100);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    registry.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, registry.adopt(&job, "x", null, 0));
    registry.allocator = std.testing.allocator;
    job.deinit(std.testing.allocator);

    var counts: CallbackCounts = .{};
    const implementation = try std.testing.allocator.create(ReentrantJob);
    implementation.* = .{ .registry = &registry, .counts = &counts };
    var owned = Job.from(implementation);
    _ = try registry.adopt(&owned, "running", null, 0);
    implementation.finished = false;
    try registry.shutdown();
    try registry.shutdown();
    try std.testing.expectEqual(@as(usize, 1), counts.terminate);
    try std.testing.expectEqual(@as(usize, 1), counts.deinit);
}

test "note OOM is retryable without losing announcement state" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    var job = try scriptedJob(std.testing.allocator, "note", 1);
    _ = try registry.adopt(&job, "note", null, 0);
    _ = try registry.runningCount();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    registry.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, registry.collectNotes());
    registry.allocator = std.testing.allocator;
    var note = (try registry.collectNotes()).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[task t1 finished (exit 0) after 0s; 4B output]", note.text);
}

test "model formatter obeys every small byte boundary and line cap" {
    const raw = "abcdefghijklmnopqrstuvwxyz\n0123456789\n" ** 100;
    var maximum: usize = 1;
    while (maximum <= 128) : (maximum += 1) {
        const output = try modelSlice(std.testing.allocator, raw, maximum);
        defer std.testing.allocator.free(output);
        try std.testing.expect(output.len <= maximum);
        try std.testing.expect(countLines(output) <= OutputCap.maximum_lines);
    }
    const many_lines = "x\n" ** 3000;
    const output = try modelSlice(std.testing.allocator, many_lines, OutputCap.default_output_bytes);
    defer std.testing.allocator.free(output);
    try std.testing.expect(countLines(output) <= OutputCap.maximum_lines);
    try std.testing.expect(std.mem.indexOf(u8, output, "output truncated") != null);
}

test "random-access report bounds calls bytes and retained scratch" {
    const bytes = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    const implementation = try std.testing.allocator.create(ScriptedJob);
    implementation.* = .{ .bytes = bytes, .finish_after = std.math.maxInt(usize) };
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "producer", null, 0);
    var report = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.body.len <= OutputCap.default_output_bytes);
    try std.testing.expect(implementation.read_calls <= 64);
    try std.testing.expectEqual(bytes.len, registry.entries.items[0].stored_bytes);
}

test "wait OOM keeps output for retry and unknown ids are one-line bounded" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    var job = try scriptedJob(std.testing.allocator, "wait retry", 1);
    _ = try registry.adopt(&job, "echo", null, 0);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        registry.wait(failing.allocator(), "t1", .{ .timeout_ms = 0 }),
    );
    const output = try registry.wait(std.testing.allocator, "t1", .{ .timeout_ms = 0 });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("wait retry\n[t1 finished (exit 0) after 0s]", output);
    const unknown = try registry.wait(
        std.testing.allocator,
        "bad\n\x01identifier-that-is-deliberately-longer-than-sixty-display-cells-remaining",
        .{ .timeout_ms = 0 },
    );
    defer std.testing.allocator.free(unknown);
    try std.testing.expect(std.mem.findScalar(u8, unknown, '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, unknown, 1) == null);
    try std.testing.expect(unknown.len <= "no such task: ".len + 60);
}

test "duration formatting rounds like hax" {
    const cases = [_]struct { milliseconds: i64, expected: []const u8 }{
        .{ .milliseconds = 0, .expected = "0s" },
        .{ .milliseconds = 1499, .expected = "1s" },
        .{ .milliseconds = 1500, .expected = "2s" },
        .{ .milliseconds = 90 * 1000, .expected = "1m 30s" },
        .{ .milliseconds = 3600 * 1000, .expected = "1h" },
    };
    for (cases) |case| {
        const output = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{Duration{ .ms = case.milliseconds }});
        defer std.testing.allocator.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
    }
}

test "unavailable retention never advertises a generic job path and is called once" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    const implementation = try std.testing.allocator.create(ScriptedJob);
    implementation.* = .{
        .bytes = "binary\x00",
        .finish_after = 1,
        .saved_path = "/untrusted/job.log",
        .retain_result = .unavailable,
    };
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "binary", null, 0);
    var report = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), implementation.retain_calls);
    try std.testing.expect(!report.advertised_log);
    try std.testing.expect(report.marker != null);
    try std.testing.expect(std.mem.indexOf(u8, report.marker.?, "/untrusted/job.log") == null);
    try std.testing.expect(std.mem.indexOf(u8, report.marker.?, "durability") != null);
}

test "overflow marker retains only the recoverable saved log" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{
        .model_bytes = 1024,
    });
    defer registry.deinit();
    const implementation = try std.testing.allocator.create(ScriptedJob);
    implementation.* = .{
        .bytes = "stored",
        .finish_after = 1,
        .total_override = "stored".len + 8,
        .overflow = true,
        .saved_path = "/tmp/task-t1.log",
    };
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "producer", null, 0);
    var report = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("stored", report.body);
    try std.testing.expect(report.marker != null);
    try std.testing.expect(std.mem.indexOf(u8, report.marker.?, "8 further bytes discarded") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.marker.?, "/tmp/task-t1.log") != null);
    try std.testing.expect(implementation.retained);
}

test "every wait allocation failure preserves output for a successful retry" {
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var time: TestTime = .{};
        var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
        defer registry.deinit();
        var job = try scriptedJob(std.testing.allocator, "all wait output", 1);
        _ = try registry.adopt(&job, "echo", null, 0);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (registry.wait(failing.allocator(), "t1", .{ .timeout_ms = 0 })) |output| {
            failing.allocator().free(output);
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const retry = try registry.wait(std.testing.allocator, "t1", .{ .timeout_ms = 0 });
            defer std.testing.allocator.free(retry);
            try std.testing.expectEqualStrings(
                "all wait output\n[t1 finished (exit 0) after 0s]",
                retry,
            );
        }
    }
    try std.testing.expect(reached_success);
}

test "every note allocation failure preserves the complete announcement" {
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var time: TestTime = .{};
        var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
        defer registry.deinit();
        var job = try scriptedJob(std.testing.allocator, "note", 1);
        _ = try registry.adopt(&job, "note", null, 0);
        _ = try registry.runningCount();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        registry.allocator = failing.allocator();
        if (registry.collectNotes()) |maybe_note| {
            if (maybe_note) |value| {
                var note = value;
                note.deinit(failing.allocator());
            }
            registry.allocator = std.testing.allocator;
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            registry.allocator = std.testing.allocator;
            var note = (try registry.collectNotes()).?;
            defer note.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(
                "[task t1 finished (exit 0) after 0s; 4B output]",
                note.text,
            );
        }
    }
    try std.testing.expect(reached_success);
}

test "report allocation OOM happens before random read and retry loses no bytes" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    const implementation = try std.testing.allocator.create(ScriptedJob);
    implementation.* = .{ .bytes = "reserved", .finish_after = 2 };
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "producer", null, 0);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        registry.reportOutput(failing.allocator(), "t1"),
    );
    try std.testing.expectEqual(@as(usize, 0), implementation.read_calls);
    try std.testing.expectEqual(@as(usize, 0), registry.entries.items[0].delivered_bytes);
    var report = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("reserved", report.body);
}

const DelayedEofJob = struct {
    polls: usize = 0,
    fn poll(self: *DelayedEofJob) JobError!void {
        self.polls += 1;
    }
    fn readAt(self: *DelayedEofJob, _: usize, _: []u8) JobError!ReadOutcome {
        return if (self.polls < 2) .would_block else .{ .eof = 1000 };
    }
    fn outputSnapshot(self: *DelayedEofJob) OutputSnapshot {
        return .{
            .total_bytes = 0,
            .stored_bytes = 0,
            .eof_ms = if (self.polls < 2) null else 1000,
        };
    }
    fn retainLog(_: *DelayedEofJob) JobError!RetainLogResult {
        return .unavailable;
    }
    fn status(_: *DelayedEofJob) Status {
        return .{ .exited = 7 };
    }
    fn terminate(_: *DelayedEofJob, _: Termination) void {}
    fn deinit(self: *DelayedEofJob, allocator: std.mem.Allocator) void { // ziglint-ignore: Z030
        allocator.destroy(self);
    }
};

const TerminationTraceJob = struct {
    modes: *[2]?Termination,
    count: *usize,
    stopped: bool = false,
    fn poll(_: *TerminationTraceJob) JobError!void {}
    fn readAt(_: *TerminationTraceJob, _: usize, _: []u8) JobError!ReadOutcome {
        return .{ .eof = 0 };
    }
    fn outputSnapshot(_: *TerminationTraceJob) OutputSnapshot {
        return .{ .total_bytes = 0, .stored_bytes = 0, .eof_ms = 0 };
    }
    fn retainLog(_: *TerminationTraceJob) JobError!RetainLogResult {
        return .unavailable;
    }
    fn status(self: *TerminationTraceJob) Status {
        return if (self.stopped) .{ .signaled = 9 } else .running;
    }
    fn terminate(self: *TerminationTraceJob, mode: Termination) void {
        if (self.count.* < self.modes.len) self.modes[self.count.*] = mode;
        self.count.* += 1;
        self.stopped = true;
    }
    fn deinit(self: *TerminationTraceJob, allocator: std.mem.Allocator) void { // ziglint-ignore: Z030
        allocator.destroy(self);
    }
};

test "terminal random-access output over 256 KiB is model-capped without a mirror" {
    const bytes = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @intCast(index % 251 + 1);
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    const implementation = try std.testing.allocator.create(ScriptedJob);
    implementation.* = .{ .bytes = bytes, .finish_after = 1 };
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "large", null, 0);
    try std.testing.expectEqual(@as(usize, 0), try registry.runningCount());
    try std.testing.expectEqual(bytes.len, registry.entries.items[0].total_bytes);
    try std.testing.expectEqual(bytes.len, registry.entries.items[0].stored_bytes);
    var report = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.body.len <= OutputCap.default_output_bytes);
    try std.testing.expect(implementation.read_calls <= 64);
}

test "terminal would-block remains running until a later EOF" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    const implementation = try std.testing.allocator.create(DelayedEofJob);
    implementation.* = .{};
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "delayed eof", null, 0);
    try std.testing.expectEqual(@as(usize, 1), try registry.runningCount());
    try std.testing.expect(registry.entries.items[0].terminal_status != null);
    try std.testing.expect(!registry.entries.items[0].output_eof);
    time.now_ms = 10 * 60 * 1000;
    try std.testing.expectEqual(@as(usize, 0), try registry.runningCount());
    try std.testing.expect(registry.entries.items[0].output_eof);
    const expected_status: Status = .{ .exited = 7 };
    try std.testing.expectEqual(expected_status, registry.entries.items[0].status);
    var note = (try registry.collectNotes()).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "[task t1 finished (exit 7) after 1s; no output]",
        note.text,
    );
}

test "zero termination grace sends force without graceful first" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{
        .termination_grace_ms = 0,
    });
    defer registry.deinit();
    var modes: [2]?Termination = .{ null, null };
    var count: usize = 0;
    const implementation = try std.testing.allocator.create(TerminationTraceJob);
    implementation.* = .{ .modes = &modes, .count = &count };
    var job = Job.from(implementation);
    _ = try registry.adopt(&job, "kill", null, 0);
    const output = try registry.wait(std.testing.allocator, "t1", .{
        .timeout_ms = 0,
        .kill_on_timeout = true,
    });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(Termination.force, modes[0].?);
}

test "elapsed duration handles reversed and extreme i64 clocks" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const reversed: Entry = .{
        .id = @constCast("t1"),
        .command = @constCast(""),
        .job = undefined,
        .started_ms = std.math.maxInt(i64),
        .finished_ms = std.math.minInt(i64),
        .status = .{ .exited = 0 },
    };
    try appendStatus(std.testing.allocator, &out, reversed, 0);
    try std.testing.expectEqualStrings("finished (exit 0) after 0s", out.items);
    out.clearRetainingCapacity();
    var extreme = reversed;
    extreme.started_ms = std.math.minInt(i64);
    extreme.finished_ms = std.math.maxInt(i64);
    try appendStatus(std.testing.allocator, &out, extreme, 0);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "finished (exit 0) after "));
}

test "write and read failures advertise sanitized retained source paths" {
    var time: TestTime = .{};
    var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
    defer registry.deinit();
    const write_job = try std.testing.allocator.create(ScriptedJob);
    write_job.* = .{
        .bytes = "partial",
        .finish_after = std.math.maxInt(usize),
        .write_failed = true,
        .saved_path = "/tmp/write\x01failed.log",
    };
    var first = Job.from(write_job);
    _ = try registry.adopt(&first, "write failure", null, 0);
    var write_report = (try registry.reportOutput(std.testing.allocator, "t1")).?;
    defer write_report.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, write_report.marker.?, "spool write failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_report.marker.?, "partial log:") != null);
    try std.testing.expect(std.mem.findScalar(u8, write_report.marker.?, 1) == null);
    try std.testing.expect(write_job.retained);

    const read_job = try std.testing.allocator.create(ScriptedJob);
    read_job.* = .{
        .bytes = "unreadable",
        .finish_after = std.math.maxInt(usize),
        .unavailable = true,
        .saved_path = "/tmp/read-failed.log",
    };
    var second = Job.from(read_job);
    _ = try registry.adopt(&second, "read failure", null, 0);
    var read_report = (try registry.reportOutput(std.testing.allocator, "t2")).?;
    defer read_report.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, read_report.marker.?, "log read failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_report.marker.?, "/tmp/read-failed.log") != null);
    try std.testing.expect(read_job.retained);
}

test "wait allocates retained and failed forms before calling retain once" {
    const bytes = try std.testing.allocator.alloc(u8, 80 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'w');
    var reached_success = false;
    for (0..96) |fail_index| {
        var time: TestTime = .{};
        var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
        defer registry.deinit();
        const implementation = try std.testing.allocator.create(ScriptedJob);
        implementation.* = .{
            .bytes = bytes,
            .finish_after = std.math.maxInt(usize),
            .saved_path = "/tmp/wait-oom.log",
        };
        var job = Job.from(implementation);
        _ = try registry.adopt(&job, "large", null, 0);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (registry.wait(failing.allocator(), "t1", .{ .timeout_ms = 0 })) |output| {
            failing.allocator().free(output);
            try std.testing.expectEqual(@as(usize, 1), implementation.retain_calls);
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), implementation.retain_calls);
            try std.testing.expectEqual(@as(usize, 0), registry.entries.items[0].delivered_bytes);
        }
    }
    try std.testing.expect(reached_success);
}

test "report OOM never advances cursor or prematurely retains an omitted log" {
    const bytes = try std.testing.allocator.alloc(u8, 80 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'z');
    var reached_success = false;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var time: TestTime = .{};
        var registry = try TaskRegistry.init(std.testing.allocator, Clock.from(&time), Poller.from(&time), .{});
        defer registry.deinit();
        const implementation = try std.testing.allocator.create(ScriptedJob);
        implementation.* = .{
            .bytes = bytes,
            .finish_after = std.math.maxInt(usize),
            .saved_path = "/tmp/oom-retry.log",
        };
        var job = Job.from(implementation);
        _ = try registry.adopt(&job, "large", null, 0);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (registry.reportOutput(failing.allocator(), "t1")) |maybe_report| {
            var report = maybe_report.?;
            report.deinit(failing.allocator());
            try std.testing.expect(implementation.retained);
            reached_success = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!implementation.retained);
            try std.testing.expectEqual(@as(usize, 0), registry.entries.items[0].delivered_bytes);
            var retry = (try registry.reportOutput(std.testing.allocator, "t1")).?;
            defer retry.deinit(std.testing.allocator);
            try std.testing.expect(implementation.retained);
        }
    }
    try std.testing.expect(reached_success);
}
