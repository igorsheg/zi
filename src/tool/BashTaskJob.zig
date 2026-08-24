const std = @import("std");
const BashProcess = @import("BashProcess.zig");
const TaskRegistry = @import("TaskRegistry.zig");
/// Clock used only by the producer thread. Callbacks must be thread-safe,
/// non-reentrant, monotonic, and remain valid until the drainer is joined.
/// This is deliberately separate from TaskRegistry.Clock, whose callbacks are
/// guarded for registry-thread use.
pub const ProducerClock = struct {
    context: ?*anyopaque,
    metadata: ?*const anyopaque = null,
    now_ms_fn: *const fn (?*anyopaque, ?*const anyopaque) i64,

    pub fn nowMs(self: ProducerClock) i64 {
        return self.now_ms_fn(self.context, self.metadata);
    }

    /// The returned clock owns no state. It preserves the explicit Io value's
    /// userdata/vtable pair, which must remain usable through the drainer join.
    pub fn fromIo(io: std.Io) ProducerClock {
        const Adapter = struct {
            fn nowMs(context: ?*anyopaque, metadata: ?*const anyopaque) i64 {
                const copied_io: std.Io = .{
                    .userdata = context,
                    .vtable = @ptrCast(@alignCast(metadata.?)),
                };
                const ns = std.Io.Clock.awake.now(copied_io).nanoseconds;
                return @intCast(@divTrunc(ns, std.time.ns_per_ms));
            }
        };
        return .{
            .context = io.userdata,
            .metadata = @ptrCast(io.vtable),
            .now_ms_fn = Adapter.nowMs,
        };
    }

    pub fn from(implementation: anytype) ProducerClock {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("ProducerClock.from expects a single-item pointer");
        const Adapter = struct {
            fn nowMs(context: ?*anyopaque, _: ?*const anyopaque) i64 {
                const self: Pointer = @ptrCast(@alignCast(context.?));
                return self.nowMs();
            }
        };
        return .{ .context = implementation, .now_ms_fn = Adapter.nowMs };
    }
};

/// Optional test seam for persistent wait/observation failures.
pub const ExitProbe = struct {
    context: *anyopaque,
    exited_fn: *const fn (*anyopaque, *BashProcess.Process) BashProcess.RunError!bool,

    pub fn exited(self: ExitProbe, process: *BashProcess.Process) BashProcess.RunError!bool {
        return self.exited_fn(self.context, process);
    }

    pub fn from(implementation: anytype) ExitProbe {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("ExitProbe.from expects a single-item pointer");
        const Adapter = struct {
            fn exited(context: *anyopaque, process: *BashProcess.Process) BashProcess.RunError!bool {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.exited(process);
            }
        };
        return .{ .context = implementation, .exited_fn = Adapter.exited };
    }
};

pub const OwnedSpool = struct {
    file: std.Io.File,
    path: []u8,
};

/// Synchronous spool creation seam. The returned path and file are transferred
/// to the job. Implementations must create an exclusive, owner-only regular
/// file and keep the path bounded and trustworthy.
pub const SpoolFactory = struct {
    context: *anyopaque,
    create_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io) error{ OutOfMemory, Unexpected }!OwnedSpool,

    pub fn create(self: SpoolFactory, allocator: std.mem.Allocator, io: std.Io) !OwnedSpool {
        return self.create_fn(self.context, allocator, io);
    }

    pub fn from(implementation: anytype) SpoolFactory {
        const Pointer = @TypeOf(implementation);
        const info = @typeInfo(Pointer);
        if (info != .pointer or info.pointer.size != .one)
            @compileError("SpoolFactory.from expects a single-item pointer");
        const Adapter = struct {
            // Erased callback order follows SpoolFactory.create_fn.
            // ziglint-ignore: Z023
            fn create(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !OwnedSpool {
                const self: Pointer = @ptrCast(@alignCast(context));
                return self.create(allocator, io);
            }
        };
        return .{ .context = implementation, .create_fn = Adapter.create };
    }
};

pub const DirectorySpoolFactory = struct {
    directory: []const u8,

    pub fn create(
        self: *DirectorySpoolFactory,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) error{ OutOfMemory, Unexpected }!OwnedSpool {
        var random: [12]u8 = undefined;
        var encoded: [48]u8 = undefined;
        for (0..32) |_| {
            io.random(&random);
            const name = std.fmt.bufPrint(&encoded, "task-{x}.log", .{random}) catch unreachable;
            const path = try std.fs.path.join(allocator, &.{ self.directory, name });
            errdefer allocator.free(path);
            const file = std.Io.Dir.cwd().createFile(io, path, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = @enumFromInt(0o600),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => return error.Unexpected,
            };
            return .{ .file = file, .path = path };
        }
        return error.Unexpected;
    }
};

/// A real Bash process adapted to TaskRegistry.Job. The joinable drainer runs
/// for the whole process lifetime, so a child cannot block merely because no
/// task_wait call is active.
pub const BashTaskJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    producer_clock: ProducerClock,
    exit_probe: ?ExitProbe,
    process: BashProcess.Process,
    thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    spool_file: std.Io.File,
    spool_path: []u8,
    total_bytes: usize = 0,
    stored_bytes: usize = 0,
    binary: bool = false,
    write_failed: bool = false,
    retain_log: bool = false,
    drain_done: bool = false,
    pipe_eof_seen: bool = false,
    finished_ms: i64 = 0,
    leader_exited: bool = false,
    failed: bool = false,
    overflow: bool = false,
    orphaned: bool = false,
    reaped: bool = false,
    final_status: TaskRegistry.Status = .running,

    pub const CreateError = BashProcess.RunError || std.Thread.SpawnError || error{OutOfMemory};

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        producer_clock: ProducerClock,
        spool_factory: SpoolFactory,
        invocation: BashProcess.Invocation,
        exit_probe: ?ExitProbe,
    ) CreateError!*BashTaskJob {
        const spool = try spool_factory.create(allocator, io);
        errdefer {
            spool.file.close(io);
            std.Io.Dir.cwd().deleteFile(io, spool.path) catch {};
            allocator.free(spool.path);
        }
        var process = try BashProcess.spawn(invocation, io);
        errdefer {
            process.terminate(true);
            process.closeOutput();
            _ = process.reap() catch {};
        }
        const self = try allocator.create(BashTaskJob);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .producer_clock = producer_clock,
            .exit_probe = exit_probe,
            .process = process,
            .spool_file = spool.file,
            .spool_path = spool.path,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, drainMain, .{self});
        return self;
    }

    pub fn job(self: *BashTaskJob) TaskRegistry.Job {
        return TaskRegistry.Job.from(self);
    }

    fn drainMain(self: *BashTaskJob) void {
        var leader_exited = false;
        var pipe_eof = false;
        drain_loop: while (!leader_exited or !pipe_eof) {
            if (!pipe_eof) {
                while (true) {
                    var bytes: [8192]u8 = undefined;
                    const result = self.process.read(&bytes) catch {
                        self.mutex.lockUncancelable(self.io);
                        self.failed = true;
                        self.mutex.unlock(self.io);
                        self.process.terminate(true);
                        pipe_eof = true;
                        self.mutex.lockUncancelable(self.io);
                        self.finished_ms = self.producer_clock.nowMs();
                        self.pipe_eof_seen = true;
                        self.mutex.unlock(self.io);
                        break;
                    };
                    switch (result) {
                        .would_block => break,
                        .eof => {
                            pipe_eof = true;
                            self.mutex.lockUncancelable(self.io);
                            self.finished_ms = self.producer_clock.nowMs();
                            self.pipe_eof_seen = true;
                            self.mutex.unlock(self.io);
                            break;
                        },
                        .bytes => |chunk| {
                            self.mutex.lockUncancelable(self.io);
                            self.total_bytes +|= chunk.len;
                            self.binary = self.binary or std.mem.findScalar(u8, chunk, 0) != null;
                            const crossed = self.total_bytes >= TaskRegistry.hard_output_bytes;
                            if (crossed) {
                                self.overflow = true;
                            } else if (!self.write_failed) {
                                self.spool_file.writePositionalAll(
                                    self.io,
                                    chunk,
                                    self.stored_bytes,
                                ) catch {
                                    self.write_failed = true;
                                };
                                if (!self.write_failed) self.stored_bytes += chunk.len;
                            }
                            const stop = crossed or self.write_failed;
                            self.mutex.unlock(self.io);
                            if (stop) self.process.terminate(true);
                        },
                    }
                }
            }
            if (!leader_exited) {
                leader_exited = (if (self.exit_probe) |probe|
                    probe.exited(&self.process)
                else
                    self.process.exited()) catch {
                    // Observation failure is terminal. Do not retry forever:
                    // force once, close the producer pipe, and leave a
                    // joinable drainer for bounded owner cleanup.
                    self.mutex.lockUncancelable(self.io);
                    self.failed = true;
                    self.mutex.unlock(self.io);
                    self.process.terminate(true);
                    self.process.closeOutput();
                    break :drain_loop;
                };
                // Close inherited writers held by descendants. The unreaped
                // leader reserves the process-group id while this happens.
                if (leader_exited) {
                    self.mutex.lockUncancelable(self.io);
                    self.leader_exited = true;
                    if (!pipe_eof) self.orphaned = true;
                    self.mutex.unlock(self.io);
                    self.process.killDescendants();
                }
            }
            if (!leader_exited or !pipe_eof)
                self.io.sleep(.fromMilliseconds(5), .awake) catch {
                    self.process.terminate(true);
                };
        }
        self.mutex.lockUncancelable(self.io);
        self.drain_done = true;
        self.mutex.unlock(self.io);
    }

    pub fn poll(self: *BashTaskJob) TaskRegistry.JobError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failed) return error.Unexpected;
        if (!self.drain_done or self.reaped) return;
        const process_status = self.process.reap() catch return error.Unexpected;
        self.reaped = true;
        self.final_status = switch (process_status) {
            .exited => |code| .{ .exited = code },
            .signaled => |signal| .{ .signaled = signal },
            .timed_out, .interrupted, .output_limit => .{ .signaled = 9 },
        };
    }

    pub fn readAt(
        self: *BashTaskJob,
        offset: usize,
        buffer: []u8,
    ) TaskRegistry.JobError!TaskRegistry.ReadOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.write_failed) return .unavailable;
        if (offset < self.stored_bytes) {
            const amount = @min(buffer.len, self.stored_bytes - offset);
            const read = self.spool_file.readPositionalAll(self.io, buffer[0..amount], offset) catch
                return error.Unexpected;
            if (read == 0) return error.Unexpected;
            return .{ .data = read };
        }
        return if (self.pipe_eof_seen) .{ .eof = self.finished_ms } else .would_block;
    }

    pub fn outputSnapshot(self: *BashTaskJob) TaskRegistry.OutputSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .total_bytes = self.total_bytes,
            .stored_bytes = self.stored_bytes,
            .binary = self.binary,
            .overflow = self.overflow,
            .write_failed = self.write_failed,
            .eof_ms = if (self.pipe_eof_seen) self.finished_ms else null,
            .saved_path = self.spool_path,
        };
    }

    pub fn retainLog(self: *BashTaskJob) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.retain_log = true;
    }

    /// Makes bytes sampled during the foreground yield visible again after the
    /// job is transferred to TaskRegistry.
    pub fn leaderRunning(self: *BashTaskJob) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return !self.leader_exited;
    }

    pub fn killedLaunchOrphans(self: *BashTaskJob) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.orphaned;
    }

    pub fn status(self: *BashTaskJob) TaskRegistry.Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.final_status;
    }

    pub fn terminate(self: *BashTaskJob, mode: TaskRegistry.Termination) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.reaped) self.process.terminate(mode == .force);
    }

    /// The allocator argument belongs to registry/result callback context; the
    /// moved job always frees itself with the allocator captured by `create`.
    pub fn deinit(self: *BashTaskJob, callback_allocator: std.mem.Allocator) void { // ziglint-ignore: Z030
        // Signal while the leader is known not to have been reaped. Then join
        // before the final reap, preventing a recycled pid/group from being
        // targeted by cleanup.
        self.terminate(.force);
        self.thread.join();
        self.mutex.lockUncancelable(self.io);
        if (!self.reaped) {
            _ = self.process.reap() catch null;
            self.reaped = true;
        }
        self.process.closeOutput();
        self.spool_file.close(self.io);
        const retain_log = self.retain_log;
        self.mutex.unlock(self.io);
        if (!retain_log) std.Io.Dir.cwd().deleteFile(self.io, self.spool_path) catch |err| {
            std.log.warn("unlinking bash task log: {s}", .{@errorName(err)});
        };
        self.allocator.free(self.spool_path);
        const owner_allocator = self.allocator;
        _ = callback_allocator;
        owner_allocator.destroy(self);
    }
};

const ClockThread = struct {
    clock: ProducerClock,
    monotonic: bool = true,

    fn run(self: *ClockThread) void {
        var previous = self.clock.nowMs();
        for (0..1000) |_| {
            const current = self.clock.nowMs();
            if (current < previous) self.monotonic = false;
            previous = current;
        }
    }
};

test "producer clock shares explicit Io epoch and is safe across drainer threads" {
    const clock = ProducerClock.fromIo(std.testing.io);
    const expected_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const expected_ms: i64 = @intCast(@divTrunc(expected_ns, std.time.ns_per_ms));
    try std.testing.expect(@abs(clock.nowMs() - expected_ms) <= 10);
    var workers: [4]ClockThread = @splat(.{ .clock = clock });
    var threads: [4]std.Thread = undefined;
    for (&threads, &workers) |*thread, *worker|
        thread.* = try std.Thread.spawn(.{}, ClockThread.run, .{worker});
    for (&threads) |*thread| thread.join();
    for (workers) |worker| try std.testing.expect(worker.monotonic);
}

const JobTestHarness = struct {
    io: std.Io,
    pub fn nowMs(self: *JobTestHarness) i64 {
        return ProducerClock.fromIo(self.io).nowMs();
    }
    pub fn wait(self: *JobTestHarness, milliseconds: u64) void {
        const bounded: i64 = @intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))));
        self.io.sleep(.fromMilliseconds(bounded), .awake) catch |err|
            std.debug.panic("job test sleep failed: {s}", .{@errorName(err)});
    }
};

fn testInvocation(command: [*:0]const u8, argv: *[4:null]?[*:0]const u8) BashProcess.Invocation {
    argv.* = .{ "/bin/sh", "-c", command, null };
    const Environment = struct {
        const empty: [1:null]?[*:0]const u8 = .{null};
    };
    return .{ .executable = "/bin/sh", .argv = argv, .envp = &Environment.empty };
}

test "adopted job shutdown frees through its owner allocator" {
    var owner_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(owner_allocator.deinit() == .ok);
    var harness: JobTestHarness = .{ .io = std.testing.io };
    var registry = try TaskRegistry.TaskRegistry.init(
        std.testing.allocator,
        TaskRegistry.Clock.from(&harness),
        TaskRegistry.Poller.from(&harness),
        .{},
    );
    defer registry.deinit();
    var argv: [4:null]?[*:0]const u8 = undefined;
    var spool_factory: DirectorySpoolFactory = .{ .directory = ".zig-cache/tmp" };
    const implementation = try BashTaskJob.create(
        owner_allocator.allocator(),
        std.testing.io,
        ProducerClock.fromIo(std.testing.io),
        SpoolFactory.from(&spool_factory),
        testInvocation("sleep 10", &argv),
        null,
    );
    const spool_path = try std.testing.allocator.dupe(u8, implementation.outputSnapshot().saved_path.?);
    defer std.testing.allocator.free(spool_path);
    const spool_stat = try std.Io.Dir.cwd().statFile(std.testing.io, spool_path, .{});
    try std.testing.expectEqual(@as(u16, 0o600), @intFromEnum(spool_stat.permissions) & 0o777);
    var job = implementation.job();
    _ = try registry.adopt(&job, "sleep 10", "owned", harness.nowMs());
    try registry.shutdown();
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, spool_path, .{}),
    );
}

const FailingExitProbe = struct {
    fn exited(_: *FailingExitProbe, _: *BashProcess.Process) BashProcess.RunError!bool {
        return error.Unexpected;
    }
};

test "persistent exit observation failure leaves a bounded joinable job" {
    var probe: FailingExitProbe = .{};
    var argv: [4:null]?[*:0]const u8 = undefined;
    var spool_factory: DirectorySpoolFactory = .{ .directory = ".zig-cache/tmp" };
    const implementation = try BashTaskJob.create(
        std.testing.allocator,
        std.testing.io,
        ProducerClock.fromIo(std.testing.io),
        SpoolFactory.from(&spool_factory),
        testInvocation("sleep 10", &argv),
        ExitProbe.from(&probe),
    );
    defer implementation.deinit(std.heap.page_allocator);
    var saw_failure = false;
    for (0..100) |_| {
        implementation.poll() catch {
            saw_failure = true;
            break;
        };
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch |err|
            std.debug.panic("fault wait failed: {s}", .{@errorName(err)});
    }
    try std.testing.expect(saw_failure);
}
