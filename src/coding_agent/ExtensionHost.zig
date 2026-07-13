const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const runtime = @import("../runtime/root.zig");
const Generation = @import("ExtensionHostGeneration.zig");

const ExtensionHost = @This();

pub const load_plan_entries_max = Generation.load_plan_entries_max;
pub const module_path_bytes_max = Generation.module_path_bytes_max;
pub const node_version_minimum = Generation.node_version_minimum;
pub const Provenance = Generation.Provenance;
pub const ExtensionSpec = Generation.ExtensionSpec;
pub const ExtensionLoadPlan = Generation.ExtensionLoadPlan;
pub const NodeCommand = Generation.NodeCommand;
pub const NodeVersion = Generation.NodeVersion;
pub const Failure = Generation.Failure;
pub const PingHandle = Generation.PingHandle;
pub const PingPoll = Generation.PingPoll;
pub const Diagnostic = Generation.Diagnostic;

pub const Options = struct {
    task_runtime: *runtime.Runtime,
    cwd: []const u8,
    agent_dir: []const u8,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    node_executable: ?[]const u8 = null,
};

const replacement_stderr_bytes_max: usize = 256 * 1024;
const replacement_build_timeout_ns: u64 = 5 * std.time.ns_per_s;

pub const ReplacementHandle = struct {
    serial: u64,
    released: bool = false,
};

pub const ReplacementFailure = union(enum) {
    startup: []const u8,
    generation: Failure,
    shutdown,
};

pub const ReplacementDiagnostic = struct {
    failure: ReplacementFailure,
    stderr_tail: []const u8,
    term: ?std.process.Child.Term,
};

pub const ReplacementPoll = union(enum) {
    pending,
    success,
    failure: ReplacementDiagnostic,
};

const ReplacementPhase = enum {
    idle,
    building,
    starting,
    rolling_back,
    draining_old,
    settled,
};

const CandidateBuildResult = union(enum) {
    ready: *Generation,
    failure: []const u8,
};

const WakeRelay = struct {
    mutex: runtime.Mutex = .init,
    owner: ?*runtime.WakeEvent = null,

    fn set(self: *WakeRelay, wake: *runtime.WakeEvent) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.owner = wake;
    }

    fn clear(self: *WakeRelay) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.owner = null;
    }

    fn notify(self: *WakeRelay, io: std.Io) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        if (self.owner) |owner| owner.set(io);
    }
};

const CandidateBuildRequest = struct {
    allocator: std.mem.Allocator,
    options: Generation.Options,
    load_plan: ExtensionLoadPlan,
    wake: *WakeRelay,
};

allocator: std.mem.Allocator,
io: std.Io,
task_runtime: *runtime.Runtime,
options: Options,
active: *Generation,
secondary: ?*Generation = null,
owner_wake: ?*runtime.WakeEvent = null,
build_wake: *WakeRelay,
next_generation: u64,
shutdown_requested: bool = false,
replacement_phase: ReplacementPhase = .idle,
replacement_task: ?runtime.Task(CandidateBuildResult) = null,
replacement_serial: u64 = 0,
replacement_handle_live: bool = false,
replacement_build_deadline_ns: ?u64 = null,
replacement_outcome: ?union(enum) { success, failure: ReplacementFailure } = null,
replacement_stderr: [replacement_stderr_bytes_max]u8 = undefined,
replacement_stderr_len: usize = 0,
replacement_term: ?std.process.Child.Term = null,

pub fn init(allocator: std.mem.Allocator, options: Options, load_plan: *const ExtensionLoadPlan) !ExtensionHost {
    const build_wake = try allocator.create(WakeRelay);
    errdefer allocator.destroy(build_wake);
    build_wake.* = .{};
    const active = try allocator.create(Generation);
    errdefer allocator.destroy(active);
    active.* = try Generation.init(allocator, generationOptions(options, 1), load_plan);
    return .{
        .allocator = allocator,
        .io = options.task_runtime.io(),
        .task_runtime = options.task_runtime,
        .options = options,
        .active = active,
        .build_wake = build_wake,
        .next_generation = 2,
    };
}

pub fn setWake(self: *ExtensionHost, wake: *runtime.WakeEvent) void {
    self.owner_wake = wake;
    self.build_wake.set(wake);
    self.active.setWake(wake);
    if (self.secondary) |secondary| secondary.setWake(wake);
}

pub fn clearWake(self: *ExtensionHost) void {
    self.owner_wake = null;
    self.build_wake.clear();
    self.active.clearWake();
    if (self.secondary) |secondary| secondary.clearWake();
}

pub fn start(self: *ExtensionHost, now_ns: u64) !void {
    try self.active.start(now_ns);
}

pub fn startReplacementOwned(
    self: *ExtensionHost,
    load_plan: *ExtensionLoadPlan,
    now_ns: u64,
) !ReplacementHandle {
    if (self.shutdown_requested or !self.active.available()) return error.HostUnavailable;
    if (!load_plan.enabled()) return error.EmptyLoadPlan;
    if (self.replacement_phase != .idle or self.replacement_handle_live) return error.ReplacementBusy;
    std.debug.assert(self.secondary == null);
    std.debug.assert(self.replacement_task == null);
    if (self.next_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    if (self.replacement_serial == std.math.maxInt(u64)) return error.ReplacementIdExhausted;

    const request = try self.allocator.create(CandidateBuildRequest);
    errdefer self.allocator.destroy(request);
    request.* = .{
        .allocator = self.allocator,
        .options = generationOptions(self.options, self.next_generation),
        .load_plan = load_plan.*,
        .wake = self.build_wake,
    };
    errdefer load_plan.* = request.load_plan;
    self.replacement_task = try self.task_runtime.spawn(candidateBuildMain, .{request});
    load_plan.* = undefined;

    self.next_generation += 1;
    self.replacement_serial += 1;
    self.replacement_phase = .building;
    self.replacement_handle_live = true;
    self.replacement_build_deadline_ns = now_ns +| replacement_build_timeout_ns;
    self.replacement_outcome = null;
    self.replacement_stderr_len = 0;
    self.replacement_term = null;
    return .{ .serial = self.replacement_serial };
}

pub fn poll(self: *ExtensionHost, now_ns: u64) void {
    self.active.poll(now_ns);
    if (self.secondary) |secondary| secondary.poll(now_ns);
    self.pollReplacementState(now_ns);
    self.finishSecondary();
}

pub fn nextDeadline(self: *const ExtensionHost) ?u64 {
    var deadline = self.active.nextDeadline();
    if (self.secondary) |secondary| deadline = minDeadline(deadline, secondary.nextDeadline());
    if (self.replacement_phase == .building) deadline = minDeadline(deadline, self.replacement_build_deadline_ns);
    return deadline;
}

pub fn startPing(self: *ExtensionHost, deadline_ns: u64) !PingHandle {
    return self.active.startPing(deadline_ns);
}

pub fn startTestWait(self: *ExtensionHost, deadline_ns: u64) !PingHandle {
    if (!builtin.is_test) return error.TestProbeUnavailable;
    return self.active.startTestWait(deadline_ns);
}

pub fn startTestSpin(self: *ExtensionHost, deadline_ns: u64) !PingHandle {
    return self.active.startTestSpin(deadline_ns);
}

pub fn pollPing(self: *ExtensionHost, handle: *const PingHandle) PingPoll {
    if (handle.released) return .{ .failure = .generation_failed };
    if (handle.generation == self.active.generationId()) return self.active.pollPing(handle);
    if (self.secondary) |secondary| {
        if (handle.generation == secondary.generationId()) return secondary.pollPing(handle);
    }
    if (handle.generation < self.next_generation) return .{ .failure = .replaced };
    return .{ .failure = .generation_failed };
}

pub fn cancel(self: *ExtensionHost, handle: *const PingHandle) void {
    if (handle.released) return;
    if (handle.generation == self.active.generationId()) {
        self.active.cancel(handle);
        return;
    }
    if (self.secondary) |secondary| {
        if (handle.generation == secondary.generationId()) secondary.cancel(handle);
    }
}

pub fn deinitPing(self: *ExtensionHost, handle: *PingHandle) void {
    if (handle.released) return;
    if (handle.generation == self.active.generationId()) {
        self.active.deinitPing(handle);
        return;
    }
    if (self.secondary) |secondary| {
        if (handle.generation == secondary.generationId()) {
            secondary.deinitPing(handle);
            return;
        }
    }
    handle.released = true;
}

pub fn pollReplacement(self: *const ExtensionHost, handle: *const ReplacementHandle) ReplacementPoll {
    if (handle.released or !self.replacement_handle_live or handle.serial != self.replacement_serial) {
        return .{ .failure = .{
            .failure = .{ .startup = "InvalidReplacementHandle" },
            .stderr_tail = &.{},
            .term = null,
        } };
    }
    const outcome = self.replacement_outcome orelse return .pending;
    return switch (outcome) {
        .success => .success,
        .failure => |failure_value| .{ .failure = .{
            .failure = failure_value,
            .stderr_tail = self.replacement_stderr[0..self.replacement_stderr_len],
            .term = self.replacement_term,
        } },
    };
}

pub fn deinitReplacement(self: *ExtensionHost, handle: *ReplacementHandle) void {
    if (handle.released) return;
    std.debug.assert(handle.serial == self.replacement_serial);
    std.debug.assert(self.replacement_outcome != null);
    handle.released = true;
    self.replacement_handle_live = false;
    self.resetReplacementIfSettled();
}

pub fn requestShutdown(self: *ExtensionHost, now_ns: u64) void {
    if (self.shutdown_requested) return;
    self.shutdown_requested = true;
    self.active.requestShutdown(now_ns);
    if (self.secondary) |secondary| secondary.requestShutdown(now_ns);
    if (self.replacement_handle_live and self.replacement_outcome == null) {
        self.replacement_outcome = .{ .failure = .shutdown };
    }
}

pub fn shutdownComplete(self: *const ExtensionHost) bool {
    if (!self.shutdown_requested) return self.active.shutdownComplete() and self.secondary == null and
        self.replacement_task == null;
    return self.active.shutdownComplete() and self.secondary == null and self.replacement_task == null;
}

pub fn available(self: *const ExtensionHost) bool {
    return !self.shutdown_requested and self.active.available();
}

pub fn diagnostic(self: *const ExtensionHost) ?Diagnostic {
    return self.active.diagnostic();
}

fn liveGenerationCount(self: *const ExtensionHost) usize {
    std.debug.assert(!(self.secondary != null and self.replacement_task != null));
    const has_second = self.secondary != null or self.replacement_task != null;
    return 1 + @as(usize, @intFromBool(has_second));
}

pub fn deinit(self: *ExtensionHost) void {
    std.debug.assert(self.shutdownComplete());
    std.debug.assert(!self.replacement_handle_live);
    std.debug.assert(self.replacement_task == null);
    std.debug.assert(self.secondary == null);
    self.active.deinit();
    self.allocator.destroy(self.active);
    self.allocator.destroy(self.build_wake);
    self.* = undefined;
}

fn pollReplacementState(self: *ExtensionHost, now_ns: u64) void {
    switch (self.replacement_phase) {
        .idle, .settled, .draining_old, .rolling_back => {},
        .building => self.pollCandidateBuild(now_ns),
        .starting => self.pollCandidateStart(now_ns),
    }
}

fn pollCandidateBuild(self: *ExtensionHost, now_ns: u64) void {
    const task = if (self.replacement_task) |*value| value else return;
    if (!task.hasResult()) {
        if (self.replacement_build_deadline_ns) |deadline| {
            if (now_ns >= deadline and self.replacement_outcome == null) {
                self.replacement_outcome = .{ .failure = .{ .startup = "DeadlineExceeded" } };
            }
        }
        return;
    }
    const result = task.getResult();
    self.replacement_task = null;
    self.replacement_build_deadline_ns = null;
    switch (result) {
        .failure => |name| {
            if (self.replacement_outcome == null) self.replacement_outcome = .{ .failure = .{ .startup = name } };
            self.replacement_phase = .settled;
            self.resetReplacementIfSettled();
        },
        .ready => |candidate| {
            std.debug.assert(self.secondary == null);
            self.secondary = candidate;
            if (self.owner_wake) |wake| candidate.setWake(wake);
            if (self.shutdown_requested or self.replacement_outcome != null) {
                candidate.requestShutdown(now_ns);
                self.replacement_phase = .rolling_back;
            } else {
                self.replacement_phase = .starting;
                self.pollCandidateStart(now_ns);
            }
        },
    }
}

fn pollCandidateStart(self: *ExtensionHost, now_ns: u64) void {
    const candidate = self.secondary orelse return;
    if (candidate.available()) {
        if (self.shutdown_requested) {
            candidate.requestShutdown(now_ns);
            self.replacement_phase = .rolling_back;
            return;
        }
        const previous = self.active;
        self.active = candidate;
        self.secondary = previous;
        previous.markReplaced(now_ns);
        self.replacement_outcome = .success;
        self.replacement_phase = .draining_old;
        if (self.owner_wake) |wake| wake.set(self.io);
        return;
    }
    if (candidate.diagnostic()) |diagnostic_value| {
        self.recordReplacementDiagnostic(diagnostic_value);
        if (self.replacement_outcome == null) {
            self.replacement_outcome = .{ .failure = .{ .generation = diagnostic_value.failure } };
        }
        candidate.requestShutdown(now_ns);
        self.replacement_phase = .rolling_back;
    }
}

fn finishSecondary(self: *ExtensionHost) void {
    const secondary = self.secondary orelse return;
    if (!secondary.shutdownComplete()) return;
    if (self.replacement_phase == .rolling_back) {
        if (secondary.diagnostic()) |diagnostic_value| self.recordReplacementDiagnostic(diagnostic_value);
    }
    secondary.deinit();
    self.allocator.destroy(secondary);
    self.secondary = null;
    self.replacement_phase = .settled;
    self.resetReplacementIfSettled();
}

fn resetReplacementIfSettled(self: *ExtensionHost) void {
    if (self.replacement_phase != .settled or self.replacement_handle_live) return;
    self.replacement_phase = .idle;
    self.replacement_outcome = null;
    self.replacement_stderr_len = 0;
    self.replacement_term = null;
}

fn recordReplacementDiagnostic(self: *ExtensionHost, diagnostic_value: Diagnostic) void {
    const source = diagnostic_value.stderr_tail;
    const copy_len = @min(source.len, self.replacement_stderr.len);
    if (copy_len != 0) @memcpy(self.replacement_stderr[0..copy_len], source[source.len - copy_len ..]);
    self.replacement_stderr_len = copy_len;
    self.replacement_term = diagnostic_value.term;
}

fn candidateBuildMain(request: *CandidateBuildRequest) CandidateBuildResult {
    const allocator = request.allocator;
    const io = request.options.task_runtime.io();
    defer {
        request.load_plan.deinit();
        request.wake.notify(io);
        allocator.destroy(request);
    }
    const candidate = allocator.create(Generation) catch |err| return .{ .failure = @errorName(err) };
    candidate.* = Generation.init(allocator, request.options, &request.load_plan) catch |err| {
        allocator.destroy(candidate);
        return .{ .failure = @errorName(err) };
    };
    candidate.start(monotonicNowNs(io)) catch |err| {
        candidate.requestShutdown(monotonicNowNs(io));
        candidate.deinit();
        allocator.destroy(candidate);
        return .{ .failure = @errorName(err) };
    };
    return .{ .ready = candidate };
}

fn generationOptions(options: Options, generation: u64) Generation.Options {
    return .{
        .task_runtime = options.task_runtime,
        .cwd = options.cwd,
        .agent_dir = options.agent_dir,
        .dir = options.dir,
        .environ = options.environ,
        .node_executable = options.node_executable,
        .generation = generation,
    };
}

fn monotonicNowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

fn minDeadline(current: ?u64, candidate: ?u64) ?u64 {
    const value = candidate orelse return current;
    return if (current) |existing| @min(existing, value) else value;
}

test "atomic replacement commits a candidate and settles old handles as replaced" {
    var fixture = try ReplacementFixture.init();
    defer fixture.deinit();
    var now = monotonicNowNs(fixture.host.io);
    try fixture.host.start(now);
    try fixture.waitActive(&now);

    var old = try fixture.host.startTestWait(now + 10 * std.time.ns_per_s);
    var replacement_plan = try ExtensionLoadPlan.init(std.testing.allocator, &.{.{
        .canonical_path = fixture.extension_path,
        .provenance = .explicit,
    }});
    var replacement = try fixture.host.startReplacementOwned(&replacement_plan, now);
    var rejected_plan = try ExtensionLoadPlan.init(std.testing.allocator, &.{.{
        .canonical_path = fixture.extension_path,
        .provenance = .explicit,
    }});
    defer rejected_plan.deinit();
    try std.testing.expectError(
        error.ReplacementBusy,
        fixture.host.startReplacementOwned(&rejected_plan, now),
    );
    var max_live: usize = 0;
    while (fixture.host.pollReplacement(&replacement) == .pending) {
        fixture.host.poll(now);
        max_live = @max(max_live, fixture.host.liveGenerationCount());
        now = monotonicNowNs(fixture.host.io);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expectEqual(ReplacementPoll.success, fixture.host.pollReplacement(&replacement));
    const replaced: PingPoll = .{ .failure = .replaced };
    try std.testing.expectEqual(replaced, fixture.host.pollPing(&old));
    try std.testing.expect(max_live <= 2);

    var current = try fixture.host.startPing(now + std.time.ns_per_s);
    try std.testing.expect(current.generation != old.generation);
    while (fixture.host.pollPing(&current) == .pending) {
        fixture.host.poll(now);
        now = monotonicNowNs(fixture.host.io);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expectEqual(PingPoll.success, fixture.host.pollPing(&current));
    fixture.host.deinitPing(&current);
    fixture.host.deinitPing(&old);
    fixture.host.deinitReplacement(&replacement);
}

test "failed atomic replacement rolls back to the usable active generation" {
    var fixture = try ReplacementFixture.init();
    defer fixture.deinit();
    var now = monotonicNowNs(fixture.host.io);
    try fixture.host.start(now);
    try fixture.waitActive(&now);

    var existing = try fixture.host.startTestWait(now + 10 * std.time.ns_per_s);
    const broken_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.root_path, "broken.ts" });
    defer std.testing.allocator.free(broken_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = broken_path,
        .data = "throw new Error('replacement failed');\n",
    });
    var broken_plan = try ExtensionLoadPlan.init(std.testing.allocator, &.{.{
        .canonical_path = broken_path,
        .provenance = .explicit,
    }});
    var replacement = try fixture.host.startReplacementOwned(&broken_plan, now);
    while (fixture.host.pollReplacement(&replacement) == .pending) {
        fixture.host.poll(now);
        try std.testing.expect(fixture.host.liveGenerationCount() <= 2);
        now = monotonicNowNs(fixture.host.io);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(fixture.host.pollReplacement(&replacement) == .failure);
    try std.testing.expect(fixture.host.available());
    try std.testing.expectEqual(PingPoll.pending, fixture.host.pollPing(&existing));
    fixture.host.cancel(&existing);
    while (fixture.host.pollPing(&existing) == .pending) {
        fixture.host.poll(now);
        now = monotonicNowNs(fixture.host.io);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    const canceled: PingPoll = .{ .failure = .canceled };
    try std.testing.expectEqual(canceled, fixture.host.pollPing(&existing));
    fixture.host.deinitPing(&existing);

    var ping = try fixture.host.startPing(now + std.time.ns_per_s);
    while (fixture.host.pollPing(&ping) == .pending) {
        fixture.host.poll(now);
        now = monotonicNowNs(fixture.host.io);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expectEqual(PingPoll.success, fixture.host.pollPing(&ping));
    fixture.host.deinitPing(&ping);
    fixture.host.deinitReplacement(&replacement);
}

const ReplacementFixture = struct {
    tmp: std.testing.TmpDir,
    root_path: []u8,
    extension_path: []u8,
    agent_dir: []u8,
    task_runtime: *runtime.Runtime,
    environ: *std.process.Environ.Map,
    plan: ExtensionLoadPlan,
    host: ExtensionHost,

    fn init() !ReplacementFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
        const root_path = try std.testing.allocator.dupe(u8, root_buffer[0..root_len]);
        errdefer std.testing.allocator.free(root_path);
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "extension.ts",
            .data = "export const fixture = 'loaded';\n",
        });
        const extension_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "extension.ts" });
        errdefer std.testing.allocator.free(extension_path);
        const agent_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "agent" });
        errdefer std.testing.allocator.free(agent_dir);
        const task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
        errdefer task_runtime.deinit();
        const environ = try std.testing.allocator.create(std.process.Environ.Map);
        errdefer std.testing.allocator.destroy(environ);
        environ.* = std.process.Environ.Map.init(std.testing.allocator);
        errdefer environ.deinit();
        try environ.put("ZI_EXTENSION_HOST_TEST", "1");
        var plan = try ExtensionLoadPlan.init(std.testing.allocator, &.{.{
            .canonical_path = extension_path,
            .provenance = .explicit,
        }});
        errdefer plan.deinit();
        const host = try ExtensionHost.init(std.testing.allocator, .{
            .task_runtime = task_runtime,
            .cwd = root_path,
            .agent_dir = agent_dir,
            .environ = environ,
            .node_executable = build_options.node_executable,
        }, &plan);
        return .{
            .tmp = tmp,
            .root_path = root_path,
            .extension_path = extension_path,
            .agent_dir = agent_dir,
            .task_runtime = task_runtime,
            .environ = environ,
            .plan = plan,
            .host = host,
        };
    }

    fn waitActive(self: *ReplacementFixture, now: *u64) !void {
        while (!self.host.available() and self.host.diagnostic() == null) {
            self.host.poll(now.*);
            now.* = monotonicNowNs(self.host.io);
            self.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
        }
        try std.testing.expect(self.host.available());
    }

    fn deinit(self: *ReplacementFixture) void {
        var now = monotonicNowNs(self.host.io);
        self.host.requestShutdown(now);
        while (!self.host.shutdownComplete()) {
            self.host.poll(now);
            now = monotonicNowNs(self.host.io);
            self.task_runtime.sleep(.fromMilliseconds(1)) catch break;
        }
        std.debug.assert(self.host.shutdownComplete());
        self.host.deinit();
        self.plan.deinit();
        self.environ.deinit();
        std.testing.allocator.destroy(self.environ);
        self.task_runtime.deinit();
        std.testing.allocator.free(self.agent_dir);
        std.testing.allocator.free(self.extension_path);
        std.testing.allocator.free(self.root_path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};
