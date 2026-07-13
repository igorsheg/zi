const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const runtime = @import("../runtime/root.zig");
const asset = @import("extension_host_asset.zig");
const paths_mod = @import("paths.zig");
const slash_commands = @import("slash_commands.zig");

const ExtensionHostGeneration = @This();

pub const load_plan_entries_max: usize = 128;
pub const module_path_bytes_max: usize = 16 * 1024;
pub const prompt_commands_max: usize = 32;
pub const prompt_command_name_bytes_max: usize = 32;
pub const prompt_command_description_bytes_max: usize = 96;
pub const prompt_command_args_bytes_max: usize = 4 * 1024;
pub const generated_prompt_bytes_max: usize = 4 * 1024;
pub const node_version_minimum: NodeVersion = .{ .major = 22, .minor = 19, .patch = 0 };

const protocol_major: u32 = 1;
const protocol_minor: u32 = 0;
const frame_header_bytes_max: usize = 1024;
const frame_body_bytes_max: usize = 8 * 1024 * 1024;
const json_depth_max: usize = 64;
const json_tokens_max: usize = 262_144;
const method_bytes_max: usize = 128;
const request_id_bytes_max: usize = 64;
const inbound_count_max: usize = 32;
const inbound_bytes_max: usize = 16 * 1024 * 1024;
const pending_requests_max: usize = 64;
const owner_transitions_per_poll: usize = 32;
const stderr_tail_bytes_max: usize = 256 * 1024;
const stderr_total_bytes_max: usize = 16 * 1024 * 1024;
const startup_timeout_ns: u64 = 5 * std.time.ns_per_s;
const shutdown_timeout_ns: u64 = std.time.ns_per_s;
const termination_grace_ns: u64 = 250 * std.time.ns_per_ms;

pub const Provenance = enum {
    global,
    explicit,
    package_managed,
    project,
};

pub const ExtensionSpec = struct {
    canonical_path: []const u8,
    provenance: Provenance,
};

pub const ExtensionLoadPlan = struct {
    allocator: std.mem.Allocator,
    entries: []const ExtensionSpec,

    pub fn init(allocator: std.mem.Allocator, specs: []const ExtensionSpec) !ExtensionLoadPlan {
        if (specs.len > load_plan_entries_max) return error.TooManyExtensions;
        const entries = try allocator.alloc(ExtensionSpec, specs.len);
        errdefer allocator.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |entry| allocator.free(entry.canonical_path);

        for (specs, entries) |spec, *entry| {
            try validateCanonicalPath(spec.canonical_path);
            for (entries[0..initialized]) |previous| {
                if (std.mem.eql(u8, previous.canonical_path, spec.canonical_path)) {
                    return error.DuplicateExtension;
                }
            }
            entry.* = .{
                .canonical_path = try allocator.dupe(u8, spec.canonical_path),
                .provenance = spec.provenance,
            };
            initialized += 1;
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn disabled(allocator: std.mem.Allocator) ExtensionLoadPlan {
        return .{ .allocator = allocator, .entries = &.{} };
    }

    pub fn enabled(self: *const ExtensionLoadPlan) bool {
        return self.entries.len != 0;
    }

    pub fn deinit(self: *ExtensionLoadPlan) void {
        for (self.entries) |entry| self.allocator.free(entry.canonical_path);
        if (self.entries.len != 0) self.allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const NodeCommand = struct {
    executable: []const u8,

    pub fn resolve(environ: ?*const std.process.Environ.Map, explicit: ?[]const u8) !NodeCommand {
        const executable = explicit orelse if (environ) |env| env.get("ZI_NODE") orelse "node" else "node";
        if (executable.len == 0 or !std.unicode.utf8ValidateSlice(executable)) return error.InvalidNodeCommand;
        if (std.mem.indexOfScalar(u8, executable, 0) != null) return error.InvalidNodeCommand;
        return .{ .executable = executable };
    }
};

pub const NodeVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) !NodeVersion {
        var parts = std.mem.splitScalar(u8, text, '.');
        const major = try parseVersionPart(parts.next() orelse return error.InvalidNodeVersion);
        const minor = try parseVersionPart(parts.next() orelse return error.InvalidNodeVersion);
        const patch = try parseVersionPart(parts.next() orelse return error.InvalidNodeVersion);
        if (parts.next() != null) return error.InvalidNodeVersion;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn supported(self: NodeVersion) bool {
        if (self.major != node_version_minimum.major) return self.major > node_version_minimum.major;
        if (self.minor != node_version_minimum.minor) return self.minor > node_version_minimum.minor;
        return self.patch >= node_version_minimum.patch;
    }
};

pub const Failure = enum {
    busy,
    canceled,
    deadline,
    generation_failed,
    extension_error,
    replaced,
    protocol,
    unsupported_node,
    shutdown,
};

pub const PingHandle = struct {
    generation: u64,
    id: u64,
    released: bool = false,
};

pub const PingPoll = union(enum) {
    pending,
    success,
    failure: Failure,
};

pub const PromptCommand = struct {
    name_buffer: [prompt_command_name_bytes_max]u8 = undefined,
    name_len: u8 = 0,
    description_buffer: [prompt_command_description_bytes_max]u8 = undefined,
    description_len: u8 = 0,

    pub fn name(self: *const PromptCommand) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn description(self: *const PromptCommand) []const u8 {
        return self.description_buffer[0..self.description_len];
    }
};

pub const PromptCommandHandle = PingHandle;
pub const PromptCommandPoll = PingPoll;

pub const Diagnostic = struct {
    failure: Failure,
    stderr_tail: []const u8,
    term: ?std.process.Child.Term,
};

pub const Options = struct {
    task_runtime: *runtime.Runtime,
    cwd: []const u8,
    agent_dir: []const u8,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    node_executable: ?[]const u8 = null,
    generation: u64 = 1,
};

const Lifecycle = enum {
    disabled,
    idle,
    starting,
    active,
    shutting_down,
    terminating,
    draining,
    terminal,
};

const OperationKind = enum {
    ping,
    prompt_command,
    test_nested,
    test_spin,
};

const OperationState = union(enum) {
    pending,
    cancel_requested,
    success,
    failure: Failure,
};

const Pending = struct {
    active: bool = false,
    generation: u64 = 0,
    id: u64 = 0,
    kind: OperationKind = .ping,
    deadline_ns: u64 = 0,
    state: OperationState = .pending,
    prompt: ?[]u8 = null,
};

const IdOrigin = enum { zig, node };

const DecodedEnvelope = struct {
    body: []u8,
    origin: ?IdOrigin = null,
    id: ?u64 = null,
    method: [method_bytes_max]u8 = undefined,
    method_len: usize = 0,
    result: Result = .none,
    rpc_error: bool = false,
    prompt: ?[]u8 = null,
    commands: [prompt_commands_max]PromptCommand = undefined,
    command_len: u8 = 0,

    const Result = union(enum) {
        none,
        pong,
        stopped,
        initialize: Initialize,
        loaded,
        prompt,
        nested,
        other,
    };

    const Initialize = struct {
        protocol_major: u32,
        protocol_minor: u32,
        node_version: [32]u8,
        node_version_len: usize,
        host_sha: [asset.digest.len * 2]u8,
        generation_nonce: [32]u8,
        node_runtime: bool,
        host_version_valid: bool,
    };

    fn methodSlice(self: *const DecodedEnvelope) []const u8 {
        return self.method[0..self.method_len];
    }

    fn deinit(self: *DecodedEnvelope, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        allocator.free(self.body);
        self.* = undefined;
    }
};

const DecoderFault = enum(u8) {
    none,
    malformed_frame,
    malformed_json,
    capacity,
    out_of_memory,
};

const DecoderState = struct {
    const Queue = std.Io.Queue(DecodedEnvelope);

    allocator: std.mem.Allocator,
    io: std.Io,
    child: *runtime.DuplexChild,
    storage: [inbound_count_max]DecodedEnvelope = undefined,
    queue: Queue,
    charge_mutex: runtime.Mutex = .init,
    queued_bytes: usize = 0,
    space_wake: runtime.WakeEvent = .init,
    wake_mutex: runtime.Mutex = .init,
    owner_wake: ?*runtime.WakeEvent = null,
    fault: std.atomic.Value(DecoderFault) = .init(.none),

    fn init(self: *DecoderState, allocator: std.mem.Allocator, io: std.Io, child: *runtime.DuplexChild) void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .queue = .init(&self.storage),
        };
    }

    fn setWake(self: *DecoderState, wake: *runtime.WakeEvent) void {
        self.wake_mutex.lockUncancelable();
        defer self.wake_mutex.unlock();
        self.owner_wake = wake;
    }

    fn clearWake(self: *DecoderState) void {
        self.wake_mutex.lockUncancelable();
        defer self.wake_mutex.unlock();
        self.owner_wake = null;
    }

    fn wakeOwner(self: *DecoderState) void {
        self.wake_mutex.lockUncancelable();
        defer self.wake_mutex.unlock();
        if (self.owner_wake) |wake| wake.set(self.io);
    }

    fn reserveBytes(self: *DecoderState, byte_count: usize) !void {
        while (true) {
            self.charge_mutex.lockUncancelable();
            if (byte_count <= inbound_bytes_max - self.queued_bytes) {
                self.queued_bytes += byte_count;
                self.charge_mutex.unlock();
                return;
            }
            self.charge_mutex.unlock();
            self.space_wake.reset();
            self.charge_mutex.lockUncancelable();
            const has_capacity = byte_count <= inbound_bytes_max - self.queued_bytes;
            self.charge_mutex.unlock();
            if (has_capacity) continue;
            try self.space_wake.wait(self.io);
        }
    }

    fn releaseBytes(self: *DecoderState, byte_count: usize) void {
        self.charge_mutex.lockUncancelable();
        std.debug.assert(self.queued_bytes >= byte_count);
        self.queued_bytes -= byte_count;
        self.charge_mutex.unlock();
        self.space_wake.set(self.io);
    }

    fn publish(self: *DecoderState, envelope: DecodedEnvelope) !void {
        try self.reserveBytes(envelope.body.len);
        self.queue.putOne(self.io, envelope) catch |err| {
            self.releaseBytes(envelope.body.len);
            return err;
        };
        self.wakeOwner();
    }

    fn poll(self: *DecoderState) ?DecodedEnvelope {
        var item: [1]DecodedEnvelope = undefined;
        const count = self.queue.get(self.io, &item, 0) catch return null;
        return if (count == 1) item[0] else null;
    }

    fn recordFault(self: *DecoderState, fault: DecoderFault) void {
        _ = self.fault.cmpxchgStrong(.none, fault, .acq_rel, .acquire);
        self.queue.close(self.io);
        self.wakeOwner();
    }

    fn deinit(self: *DecoderState) void {
        while (self.poll()) |envelope_value| {
            var envelope = envelope_value;
            self.releaseBytes(envelope.body.len);
            envelope.deinit(self.allocator);
        }
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
io: std.Io,
task_runtime: *runtime.Runtime,
paths: paths_mod.PersistencePaths,
dir: std.Io.Dir,
environ: ?*const std.process.Environ.Map,
cwd: []const u8,
agent_dir: []const u8,
node_executable: []const u8,
load_plan: ExtensionLoadPlan,
lifecycle: Lifecycle,
generation: u64 = 1,
next_request_id: u64 = 1,
startup_deadline_ns: ?u64 = null,
shutdown_deadline_ns: ?u64 = null,
kill_deadline_ns: ?u64 = null,
last_now_ns: u64 = 0,
shutdown_id: ?u64 = null,
startup_load_id: ?u64 = null,
generation_nonce: [16]u8,
failure: ?Failure = null,
asset_lease: ?asset.Lease = null,
child: ?*runtime.DuplexChild = null,
decoder: ?*DecoderState = null,
decoder_task: ?runtime.Task(void) = null,
settle_task: ?runtime.Task(void) = null,
pending: [pending_requests_max]Pending = [_]Pending{.{}} ** pending_requests_max,
owner_wake: ?*runtime.WakeEvent = null,
stderr_tail: [stderr_tail_bytes_max]u8 = undefined,
stderr_tail_len: usize = 0,
stderr_total: usize = 0,
last_term: ?std.process.Child.Term = null,
prompt_commands: [prompt_commands_max]PromptCommand = undefined,
prompt_command_len: u8 = 0,

pub fn init(
    allocator: std.mem.Allocator,
    options: Options,
    load_plan: *const ExtensionLoadPlan,
) !ExtensionHostGeneration {
    const cwd = try allocator.dupe(u8, options.cwd);
    errdefer allocator.free(cwd);
    const agent_dir = try allocator.dupe(u8, options.agent_dir);
    errdefer allocator.free(agent_dir);
    const node = try NodeCommand.resolve(options.environ, options.node_executable);
    var generation_nonce: [16]u8 = undefined;
    options.task_runtime.io().random(&generation_nonce);
    const node_executable = try resolveNodeExecutable(
        allocator,
        options.task_runtime.io(),
        options.environ,
        node.executable,
    );
    errdefer allocator.free(node_executable);
    const owned_plan = try ExtensionLoadPlan.init(allocator, load_plan.entries);
    errdefer {
        var mutable_plan = owned_plan;
        mutable_plan.deinit();
    }

    return .{
        .allocator = allocator,
        .io = options.task_runtime.io(),
        .task_runtime = options.task_runtime,
        .paths = .{ .global_dir = agent_dir, .cwd = cwd },
        .dir = options.dir,
        .environ = options.environ,
        .cwd = cwd,
        .agent_dir = agent_dir,
        .node_executable = node_executable,
        .load_plan = owned_plan,
        .lifecycle = if (owned_plan.enabled()) .idle else .disabled,
        .generation = options.generation,
        .generation_nonce = generation_nonce,
    };
}

pub fn setWake(self: *ExtensionHostGeneration, wake: *runtime.WakeEvent) void {
    self.owner_wake = wake;
    if (self.child) |child| child.setWake(wake);
    if (self.decoder) |decoder| decoder.setWake(wake);
}

pub fn clearWake(self: *ExtensionHostGeneration) void {
    self.owner_wake = null;
    if (self.child) |child| child.clearWake();
    if (self.decoder) |decoder| decoder.clearWake();
}

pub fn start(self: *ExtensionHostGeneration, now_ns: u64) !void {
    if (self.lifecycle == .disabled) return;
    if (self.lifecycle != .idle) return error.InvalidLifecycle;

    var lease = try asset.materialize(self.allocator, self.io, self.dir, self.paths);
    const initialize = self.encodeInitializeRequest() catch |err| {
        lease.deinit();
        return err;
    };
    const argv = [_][]const u8{
        self.node_executable,
        "--max-old-space-size=512",
        "--enable-source-maps",
        lease.path,
    };
    const child = runtime.DuplexChild.spawn(self.allocator, self.io, self.task_runtime, .{
        .argv = &argv,
        .cwd = self.cwd,
        .environ = self.environ,
    }) catch |err| {
        self.allocator.free(initialize);
        lease.deinit();
        return err;
    };
    if (self.owner_wake) |wake| child.setWake(wake);

    const decoder = self.allocator.create(DecoderState) catch |err| {
        self.allocator.free(initialize);
        stopChildSynchronously(child, self.task_runtime);
        lease.deinit();
        return err;
    };
    decoder.init(self.allocator, self.io, child);
    if (self.owner_wake) |wake| decoder.setWake(wake);
    var decoder_task = self.task_runtime.spawn(decoderMain, .{decoder}) catch |err| {
        self.allocator.free(initialize);
        decoder.deinit();
        self.allocator.destroy(decoder);
        stopChildSynchronously(child, self.task_runtime);
        lease.deinit();
        return err;
    };
    child.enqueueControlOwned(initialize) catch |err| {
        self.allocator.free(initialize);
        stopDecoderAndChild(self.allocator, child, decoder, &decoder_task, self.task_runtime);
        lease.deinit();
        return err;
    };

    self.last_now_ns = now_ns;
    self.asset_lease = lease;
    self.child = child;
    self.decoder = decoder;
    self.decoder_task = decoder_task;
    self.lifecycle = .starting;
    self.startup_deadline_ns = now_ns +| startup_timeout_ns;
}

pub fn poll(self: *ExtensionHostGeneration, now_ns: u64) void {
    self.last_now_ns = now_ns;
    if (self.lifecycle == .disabled or self.lifecycle == .idle or self.lifecycle == .terminal) return;

    self.drainStderr(now_ns);
    var transitions: usize = 0;
    while (transitions < owner_transitions_per_poll) : (transitions += 1) {
        const decoder = self.decoder orelse break;
        const envelope_value = decoder.poll() orelse break;
        var envelope = envelope_value;
        decoder.releaseBytes(envelope.body.len);
        self.applyEnvelope(&envelope, now_ns);
        envelope.deinit(self.allocator);
        if (self.lifecycle == .terminating or self.lifecycle == .draining) break;
    }
    if (transitions == owner_transitions_per_poll) {
        if (self.owner_wake) |wake| wake.set(self.io);
    }

    self.expireOperations(now_ns);
    self.advanceDeadlines(now_ns);

    if (self.decoder) |decoder| {
        if (decoder.fault.load(.acquire) != .none and self.failure == null) {
            self.failGeneration(.protocol, now_ns);
        }
    }
    if (self.child) |child| {
        if (child.workerFault() != null and self.failure == null) self.failGeneration(.generation_failed, now_ns);
        if (child.processComplete()) self.observeProcessExit(now_ns);
    }
    self.finishDrain();
}

pub fn nextDeadline(self: *const ExtensionHostGeneration) ?u64 {
    var deadline: ?u64 = self.startup_deadline_ns;
    deadline = minDeadline(deadline, self.shutdown_deadline_ns);
    deadline = minDeadline(deadline, self.kill_deadline_ns);
    for (self.pending) |pending| {
        if (!pending.active) continue;
        switch (pending.state) {
            .pending, .cancel_requested => deadline = minDeadline(deadline, pending.deadline_ns),
            else => {},
        }
    }
    return deadline;
}

pub fn startPing(self: *ExtensionHostGeneration, deadline_ns: u64) !PingHandle {
    return self.startOperation(.ping, "host/ping", "{}", deadline_ns);
}

pub fn promptCommands(self: *const ExtensionHostGeneration) []const PromptCommand {
    return self.prompt_commands[0..self.prompt_command_len];
}

pub fn findPromptCommand(self: *const ExtensionHostGeneration, name: []const u8) ?*const PromptCommand {
    for (self.promptCommands()) |*command| {
        if (std.mem.eql(u8, command.name(), name)) return command;
    }
    return null;
}

pub fn startPromptCommand(
    self: *ExtensionHostGeneration,
    name: []const u8,
    args: []const u8,
    deadline_ns: u64,
) !PromptCommandHandle {
    if (self.findPromptCommand(name) == null) return error.UnknownPromptCommand;
    if (args.len > prompt_command_args_bytes_max or !std.unicode.utf8ValidateSlice(args)) {
        return error.InvalidPromptCommandArguments;
    }
    var params: std.Io.Writer.Allocating = .init(self.allocator);
    defer params.deinit();
    try params.writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, &params.writer);
    try params.writer.writeAll(",\"args\":");
    try std.json.Stringify.value(args, .{}, &params.writer);
    try params.writer.writeByte('}');
    return self.startOperation(
        .prompt_command,
        "host/runPromptCommand",
        params.written(),
        deadline_ns,
    );
}

pub fn pollPromptCommand(
    self: *ExtensionHostGeneration,
    handle: *const PromptCommandHandle,
) PromptCommandPoll {
    return self.pollPing(handle);
}

pub fn takePromptCommand(self: *ExtensionHostGeneration, handle: *const PromptCommandHandle) ![]u8 {
    if (handle.released or handle.generation != self.generation) return error.InvalidPromptCommandHandle;
    const pending = self.findPending(handle.id) orelse return error.InvalidPromptCommandHandle;
    if (pending.kind != .prompt_command or pending.state != .success) return error.PromptCommandNotReady;
    const prompt = pending.prompt orelse return error.PromptCommandNotReady;
    pending.prompt = null;
    return prompt;
}

pub fn deinitPromptCommand(self: *ExtensionHostGeneration, handle: *PromptCommandHandle) void {
    self.deinitPing(handle);
}

fn startTestNested(self: *ExtensionHostGeneration, deadline_ns: u64) !PingHandle {
    return self.startOperation(.test_nested, "host/testNested", "{\"value\":1}", deadline_ns);
}

pub fn startTestWait(self: *ExtensionHostGeneration, deadline_ns: u64) !PingHandle {
    return self.startOperation(.ping, "host/testWait", "{}", deadline_ns);
}

pub fn startTestSpin(self: *ExtensionHostGeneration, deadline_ns: u64) !PingHandle {
    if (!builtin.is_test) return error.TestProbeUnavailable;
    return self.startOperation(.test_spin, "host/testSpin", "{}", deadline_ns);
}

fn startTestCrash(self: *ExtensionHostGeneration, deadline_ns: u64) !PingHandle {
    return self.startOperation(.test_spin, "host/testCrash", "{}", deadline_ns);
}

fn startTestMalformed(self: *ExtensionHostGeneration, deadline_ns: u64) !PingHandle {
    return self.startOperation(.test_spin, "host/testMalformed", "{}", deadline_ns);
}

pub fn pollPing(self: *ExtensionHostGeneration, handle: *const PingHandle) PingPoll {
    if (handle.released or handle.generation != self.generation) return .{ .failure = .generation_failed };
    const pending = self.findPending(handle.id) orelse return .{ .failure = .generation_failed };
    return switch (pending.state) {
        .pending, .cancel_requested => .pending,
        .success => .success,
        .failure => |failure_value| .{ .failure = failure_value },
    };
}

pub fn cancel(self: *ExtensionHostGeneration, handle: *const PingHandle) void {
    if (handle.released or handle.generation != self.generation) return;
    const pending = self.findPending(handle.id) orelse return;
    if (pending.state != .pending) return;
    pending.state = .cancel_requested;
    const notification = self.encodeCancelNotification(handle.id) catch {
        self.failGeneration(.generation_failed, self.last_now_ns);
        return;
    };
    self.enqueueControlFrame(notification) catch {
        self.failGeneration(.generation_failed, self.last_now_ns);
    };
}

pub fn deinitPing(self: *ExtensionHostGeneration, handle: *PingHandle) void {
    if (handle.released) return;
    if (handle.generation == self.generation) {
        const pending = self.findPending(handle.id);
        if (pending) |operation| {
            std.debug.assert(switch (operation.state) {
                .pending, .cancel_requested => false,
                else => true,
            });
            if (operation.prompt) |prompt| self.allocator.free(prompt);
            operation.* = .{};
        }
    }
    handle.released = true;
}

pub fn markReplaced(self: *ExtensionHostGeneration, now_ns: u64) void {
    self.settlePendingForStop(.replaced);
    self.requestShutdown(now_ns);
}

pub fn requestShutdown(self: *ExtensionHostGeneration, now_ns: u64) void {
    self.last_now_ns = now_ns;
    switch (self.lifecycle) {
        .disabled, .terminal => return,
        .idle => {
            self.lifecycle = .terminal;
            return;
        },
        .starting, .active => {},
        .shutting_down, .terminating, .draining => return,
    }
    self.settlePendingForStop(.shutdown);
    const id = self.allocateRequestId() catch {
        self.failGeneration(.shutdown, now_ns);
        return;
    };
    const frame = encodeRequest(self.allocator, id, "host/shutdown", "{}") catch {
        self.failGeneration(.shutdown, now_ns);
        return;
    };
    self.enqueueControlFrame(frame) catch {
        self.failGeneration(.shutdown, now_ns);
        return;
    };
    self.shutdown_id = id;
    self.lifecycle = .shutting_down;
    self.shutdown_deadline_ns = now_ns +| shutdown_timeout_ns;
}

pub fn shutdownComplete(self: *const ExtensionHostGeneration) bool {
    return self.lifecycle == .disabled or self.lifecycle == .terminal;
}

pub fn available(self: *const ExtensionHostGeneration) bool {
    return self.lifecycle == .active;
}

pub fn generationId(self: *const ExtensionHostGeneration) u64 {
    return self.generation;
}

pub fn diagnostic(self: *const ExtensionHostGeneration) ?Diagnostic {
    const failure_value = self.failure orelse return null;
    return .{
        .failure = failure_value,
        .stderr_tail = self.stderr_tail[0..self.stderr_tail_len],
        .term = self.last_term,
    };
}

pub fn deinit(self: *ExtensionHostGeneration) void {
    std.debug.assert(self.shutdownComplete());
    if (self.decoder_task) |*task| {
        std.debug.assert(task.hasResult());
        _ = task.getResult();
    }
    if (self.settle_task) |*task| {
        std.debug.assert(task.hasResult());
        _ = task.getResult();
    }
    if (self.decoder) |decoder| {
        decoder.deinit();
        self.allocator.destroy(decoder);
    }
    if (self.child) |child| child.deinit();
    if (self.asset_lease) |*lease| lease.deinit();
    for (&self.pending) |*pending| {
        if (pending.prompt) |prompt| self.allocator.free(prompt);
        pending.* = .{};
    }
    self.load_plan.deinit();
    self.allocator.free(self.node_executable);
    self.allocator.free(self.agent_dir);
    self.allocator.free(self.cwd);
    self.* = undefined;
}

fn startOperation(
    self: *ExtensionHostGeneration,
    kind: OperationKind,
    method: []const u8,
    params_json: []const u8,
    deadline_ns: u64,
) !PingHandle {
    if (self.lifecycle != .active) return error.HostUnavailable;
    const slot = self.freePending() orelse return error.Busy;
    const id = try self.allocateRequestId();
    const frame = try encodeRequest(self.allocator, id, method, params_json);
    try self.enqueueControlFrame(frame);
    slot.* = .{
        .active = true,
        .generation = self.generation,
        .id = id,
        .kind = kind,
        .deadline_ns = deadline_ns,
        .state = .pending,
    };
    return .{ .generation = self.generation, .id = id };
}

fn applyEnvelope(self: *ExtensionHostGeneration, envelope: *DecodedEnvelope, now_ns: u64) void {
    if (envelope.method_len != 0) {
        if (envelope.origin != .node or envelope.id == null) {
            self.failGeneration(.protocol, now_ns);
            return;
        }
        if (std.mem.eql(u8, envelope.methodSlice(), "host/test/echo")) {
            const frame = encodeResult(self.allocator, .node, envelope.id.?, "{\"echo\":true}") catch {
                self.failGeneration(.generation_failed, now_ns);
                return;
            };
            self.enqueueControlFrame(frame) catch {
                self.failGeneration(.generation_failed, now_ns);
            };
            return;
        }
        const frame = encodeRpcError(self.allocator, .node, envelope.id.?, -32601, "method not found") catch {
            self.failGeneration(.generation_failed, now_ns);
            return;
        };
        self.enqueueControlFrame(frame) catch self.failGeneration(.generation_failed, now_ns);
        return;
    }
    if (envelope.origin != .zig or envelope.id == null) {
        self.failGeneration(.protocol, now_ns);
        return;
    }
    const id = envelope.id.?;
    if (id == 0) {
        if (self.lifecycle != .starting or self.startup_load_id != null) {
            self.failGeneration(.protocol, now_ns);
            return;
        }
        if (envelope.rpc_error or envelope.result != .initialize) {
            self.failGeneration(.protocol, now_ns);
            return;
        }
        const initialize = envelope.result.initialize;
        const version = NodeVersion.parse(initialize.node_version[0..initialize.node_version_len]) catch {
            self.failGeneration(.unsupported_node, now_ns);
            return;
        };
        const expected_sha = asset.digestHex();
        const expected_nonce = std.fmt.bytesToHex(self.generation_nonce, .lower);
        if (initialize.protocol_major != protocol_major or initialize.protocol_minor != protocol_minor or
            !initialize.node_runtime or !initialize.host_version_valid or !version.supported() or
            !std.mem.eql(u8, &initialize.host_sha, &expected_sha) or
            !std.mem.eql(u8, &initialize.generation_nonce, &expected_nonce))
        {
            self.failGeneration(if (!version.supported()) .unsupported_node else .protocol, now_ns);
            return;
        }
        const load_id = self.allocateRequestId() catch {
            self.failGeneration(.generation_failed, now_ns);
            return;
        };
        const load = self.encodeLoadExtensionsRequest(load_id) catch {
            self.failGeneration(.generation_failed, now_ns);
            return;
        };
        self.enqueueControlFrame(load) catch {
            self.failGeneration(.generation_failed, now_ns);
            return;
        };
        self.startup_load_id = load_id;
        return;
    }
    if (self.startup_load_id == id) {
        if (self.lifecycle != .starting) return;
        if (envelope.rpc_error) {
            self.failGeneration(.generation_failed, now_ns);
            return;
        }
        if (envelope.result != .loaded) {
            self.failGeneration(.protocol, now_ns);
            return;
        }
        self.startup_load_id = null;
        self.prompt_command_len = envelope.command_len;
        @memcpy(self.prompt_commands[0..envelope.command_len], envelope.commands[0..envelope.command_len]);
        const initialized = encodeNotification(self.allocator, "host/initialized", "{}") catch {
            self.failGeneration(.generation_failed, now_ns);
            return;
        };
        self.enqueueControlFrame(initialized) catch {
            self.failGeneration(.generation_failed, now_ns);
            return;
        };
        self.lifecycle = .active;
        self.startup_deadline_ns = null;
        return;
    }
    if (self.shutdown_id == id) {
        if (envelope.rpc_error or envelope.result != .stopped) {
            self.failGeneration(.shutdown, now_ns);
            return;
        }
        self.shutdown_id = null;
        if (self.child) |child| child.requestStop();
        return;
    }
    const pending = self.findPending(id) orelse {
        self.failGeneration(.protocol, now_ns);
        return;
    };
    switch (pending.state) {
        .success => {
            self.failGeneration(.protocol, now_ns);
            return;
        },
        .failure => |failure_value| {
            if (failure_value == .replaced or
                (failure_value == .shutdown and self.lifecycle == .shutting_down)) return;
            self.failGeneration(.protocol, now_ns);
            return;
        },
        .pending, .cancel_requested => {},
    }
    if (pending.state == .cancel_requested) {
        pending.state = .{ .failure = .canceled };
        return;
    }
    if (envelope.rpc_error) {
        pending.state = .{ .failure = .extension_error };
        return;
    }
    pending.state = switch (pending.kind) {
        .ping => if (envelope.result == .pong) .success else .{ .failure = .protocol },
        .prompt_command => success: {
            if (envelope.result != .prompt or envelope.prompt == null) break :success .{ .failure = .protocol };
            pending.prompt = envelope.prompt;
            envelope.prompt = null;
            break :success .success;
        },
        .test_nested => if (envelope.result == .nested) .success else .{ .failure = .protocol },
        .test_spin => .{ .failure = .protocol },
    };
}

fn settlePendingForStop(self: *ExtensionHostGeneration, failure_value: Failure) void {
    for (&self.pending) |*pending| {
        if (!pending.active) continue;
        switch (pending.state) {
            .pending, .cancel_requested => pending.state = .{ .failure = failure_value },
            else => {},
        }
    }
}

fn expireOperations(self: *ExtensionHostGeneration, now_ns: u64) void {
    for (&self.pending) |*pending| {
        if (!pending.active) continue;
        switch (pending.state) {
            .pending, .cancel_requested => if (now_ns >= pending.deadline_ns) {
                pending.state = .{ .failure = .deadline };
                self.failGeneration(.deadline, now_ns);
                return;
            },
            else => {},
        }
    }
}

fn advanceDeadlines(self: *ExtensionHostGeneration, now_ns: u64) void {
    if (self.startup_deadline_ns) |deadline| {
        if (now_ns >= deadline) self.failGeneration(.deadline, now_ns);
    }
    if (self.shutdown_deadline_ns) |deadline| {
        if (now_ns >= deadline) self.failGeneration(.shutdown, now_ns);
    }
    if (self.kill_deadline_ns) |deadline| {
        if (now_ns >= deadline) {
            self.kill_deadline_ns = null;
            if (self.child) |child| child.forceKill();
        }
    }
}

fn failGeneration(self: *ExtensionHostGeneration, failure_value: Failure, now_ns: u64) void {
    if (self.failure == null) self.failure = failure_value;
    self.startup_deadline_ns = null;
    self.shutdown_deadline_ns = null;
    for (&self.pending) |*pending| {
        if (!pending.active) continue;
        switch (pending.state) {
            .pending, .cancel_requested => pending.state = .{ .failure = failure_value },
            else => {},
        }
    }
    switch (self.lifecycle) {
        .disabled, .terminal, .draining, .terminating => return,
        else => {},
    }
    if (self.child == null) {
        self.lifecycle = .terminal;
        return;
    }
    self.lifecycle = .terminating;
    self.kill_deadline_ns = now_ns +| termination_grace_ns;
    if (self.child) |child| child.requestTermination();
}

fn observeProcessExit(self: *ExtensionHostGeneration, now_ns: u64) void {
    const child = self.child orelse return;
    if (self.last_term == null) self.last_term = child.processTerm();
    if (self.failure == null and self.lifecycle != .shutting_down) {
        self.failGeneration(.generation_failed, now_ns);
    }
    self.startup_deadline_ns = null;
    self.shutdown_deadline_ns = null;
    self.kill_deadline_ns = null;
    if (self.settle_task == null) {
        self.settle_task = self.task_runtime.spawn(settleChild, .{child}) catch {
            self.lifecycle = .draining;
            return;
        };
    }
    self.lifecycle = .draining;
}

fn finishDrain(self: *ExtensionHostGeneration) void {
    if (self.lifecycle != .draining) return;
    const settle_task = if (self.settle_task) |*task| task else return;
    const decoder_task = if (self.decoder_task) |*task| task else return;
    if (!settle_task.hasResult() or !decoder_task.hasResult()) return;
    _ = settle_task.getResult();
    _ = decoder_task.getResult();
    self.lifecycle = .terminal;
    if (self.owner_wake) |wake| wake.set(self.io);
}

fn drainStderr(self: *ExtensionHostGeneration, now_ns: u64) void {
    const child = self.child orelse return;
    var drained: usize = 0;
    while (drained < 256 * 1024) {
        const chunk = child.pollChunk(.stderr) orelse break;
        const data = chunk.slice();
        drained += data.len;
        self.recordStderr(data, now_ns);
        if (self.failure != null) return;
    }
}

fn recordStderr(self: *ExtensionHostGeneration, data: []const u8, now_ns: u64) void {
    self.stderr_total += data.len;
    appendTail(&self.stderr_tail, &self.stderr_tail_len, data);
    if (self.stderr_total > stderr_total_bytes_max) self.failGeneration(.generation_failed, now_ns);
}

fn enqueueFrame(self: *ExtensionHostGeneration, frame: []u8) !void {
    const child = self.child orelse {
        self.allocator.free(frame);
        return error.HostUnavailable;
    };
    child.enqueueOwned(frame) catch |err| {
        self.allocator.free(frame);
        return err;
    };
}

fn enqueueControlFrame(self: *ExtensionHostGeneration, frame: []u8) !void {
    const child = self.child orelse {
        self.allocator.free(frame);
        return error.HostUnavailable;
    };
    child.enqueueControlOwned(frame) catch |err| {
        self.allocator.free(frame);
        return err;
    };
}

fn encodeInitializeRequest(self: *ExtensionHostGeneration) ![]u8 {
    var params: std.Io.Writer.Allocating = .init(self.allocator);
    defer params.deinit();
    const digest_hex = asset.digestHex();
    try params.writer.writeAll("{\"protocol\":{\"major\":1,\"minor\":0},\"hostSha\":");
    try std.json.Stringify.value(&digest_hex, .{}, &params.writer);
    try params.writer.writeAll(",\"ziVersion\":");
    try std.json.Stringify.value(build_options.version, .{}, &params.writer);
    try params.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(self.cwd, .{}, &params.writer);
    try params.writer.writeAll(",\"generationNonce\":");
    const nonce_hex = std.fmt.bytesToHex(self.generation_nonce, .lower);
    try std.json.Stringify.value(&nonce_hex, .{}, &params.writer);
    try params.writer.writeByte('}');
    return encodeRequest(self.allocator, 0, "host/initialize", params.written());
}

fn encodeLoadExtensionsRequest(self: *ExtensionHostGeneration, id: u64) ![]u8 {
    var params: std.Io.Writer.Allocating = .init(self.allocator);
    defer params.deinit();
    try params.writer.writeAll("{\"extensions\":[");
    for (self.load_plan.entries, 0..) |entry, index| {
        if (index != 0) try params.writer.writeByte(',');
        try std.json.Stringify.value(entry.canonical_path, .{}, &params.writer);
    }
    try params.writer.writeAll("]}");
    return encodeRequest(self.allocator, id, "host/loadExtensions", params.written());
}

fn encodeCancelNotification(self: *ExtensionHostGeneration, id: u64) ![]u8 {
    var params_buffer: [96]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buffer, "{{\"id\":\"z:{d}\"}}", .{id});
    return encodeNotification(self.allocator, "host/cancel", params);
}

fn freePending(self: *ExtensionHostGeneration) ?*Pending {
    for (&self.pending) |*pending| if (!pending.active) return pending;
    return null;
}

fn findPending(self: *ExtensionHostGeneration, id: u64) ?*Pending {
    for (&self.pending) |*pending| {
        if (pending.active and pending.generation == self.generation and pending.id == id) return pending;
    }
    return null;
}

fn allocateRequestId(self: *ExtensionHostGeneration) !u64 {
    const id = self.next_request_id;
    self.next_request_id = std.math.add(u64, id, 1) catch return error.RequestIdExhausted;
    return id;
}

fn decoderMain(state: *DecoderState) void {
    var decoder: FrameDecoder = .{ .allocator = state.allocator };
    defer decoder.deinit();
    while (true) {
        const chunk = state.child.nextChunk(.stdout) catch return;
        if (chunk == null) {
            if (!decoder.complete()) state.recordFault(.malformed_frame);
            return;
        }
        decoder.push(state, chunk.?.slice()) catch |err| {
            state.recordFault(switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.CapacityExceeded => .capacity,
                error.InvalidJson => .malformed_json,
                else => .malformed_frame,
            });
            return;
        };
    }
}

const FrameDecoder = struct {
    allocator: std.mem.Allocator,
    header: [frame_header_bytes_max + 4]u8 = undefined,
    header_len: usize = 0,
    body: ?[]u8 = null,
    body_offset: usize = 0,

    fn deinit(self: *FrameDecoder) void {
        if (self.body) |body| self.allocator.free(body);
        self.* = undefined;
    }

    fn complete(self: *const FrameDecoder) bool {
        return self.header_len == 0 and self.body == null;
    }

    fn push(self: *FrameDecoder, state: *DecoderState, bytes_value: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes_value.len) {
            if (self.body) |body| {
                const count = @min(body.len - self.body_offset, bytes_value.len - offset);
                @memcpy(body[self.body_offset .. self.body_offset + count], bytes_value[offset .. offset + count]);
                self.body_offset += count;
                offset += count;
                if (self.body_offset == body.len) {
                    self.body = null;
                    self.body_offset = 0;
                    var envelope = decodeEnvelope(self.allocator, body) catch |err| {
                        self.allocator.free(body);
                        return err;
                    };
                    state.publish(envelope) catch |err| {
                        envelope.deinit(self.allocator);
                        return err;
                    };
                }
                continue;
            }
            self.header[self.header_len] = bytes_value[offset];
            self.header_len += 1;
            offset += 1;
            if (self.header_len >= 4 and std.mem.eql(
                u8,
                self.header[self.header_len - 4 .. self.header_len],
                "\r\n\r\n",
            )) {
                const body_len = try parseContentLength(self.header[0 .. self.header_len - 4]);
                self.header_len = 0;
                self.body = try self.allocator.alloc(u8, body_len);
                if (body_len == 0) return error.InvalidFrame;
            } else if (self.header_len > frame_header_bytes_max) {
                const delimiter_len = self.header_len - frame_header_bytes_max;
                if (delimiter_len > 4 or !std.mem.eql(
                    u8,
                    self.header[frame_header_bytes_max..self.header_len],
                    "\r\n\r\n"[0..delimiter_len],
                )) return error.InvalidFrame;
            }
        }
    }
};

fn parseContentLength(header: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    var length: ?usize = null;
    while (lines.next()) |line| {
        const prefix = "Content-Length:";
        if (!std.mem.startsWith(u8, line, prefix) or length != null) return error.InvalidFrame;
        const raw = std.mem.trim(u8, line[prefix.len..], " \t");
        if (raw.len == 0 or (raw.len > 1 and raw[0] == '0')) return error.InvalidFrame;
        for (raw) |char| if (!std.ascii.isDigit(char)) return error.InvalidFrame;
        const parsed = std.fmt.parseInt(usize, raw, 10) catch return error.InvalidFrame;
        if (parsed > frame_body_bytes_max) return error.CapacityExceeded;
        length = parsed;
    }
    return length orelse error.InvalidFrame;
}

const WireEnvelope = struct {
    jsonrpc: []const u8,
    id: ?[]const u8 = null,
    method: ?[]const u8 = null,
    result: ?WireResult = null,
    @"error": ?WireError = null,
};

const WirePromptCommand = struct {
    name: []const u8,
    description: []const u8,
};

const WireResult = struct {
    pong: ?bool = null,
    stopped: ?bool = null,
    initialized: ?bool = null,
    nested: ?struct { echo: ?bool = null } = null,
    protocol: ?struct { major: u32, minor: u32 } = null,
    nodeVersion: ?[]const u8 = null,
    runtimeName: ?[]const u8 = null,
    hostVersion: ?[]const u8 = null,
    hostSha: ?[]const u8 = null,
    generationNonce: ?[]const u8 = null,
    promptCommands: ?[]const WirePromptCommand = null,
    prompt: ?[]const u8 = null,
};

const WireError = struct {
    code: i32,
    message: []const u8,
};

fn decodeEnvelope(allocator: std.mem.Allocator, body: []u8) !DecodedEnvelope {
    try validateJson(allocator, body);
    var parsed = std.json.parseFromSlice(WireEnvelope, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = frame_body_bytes_max,
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    const wire = parsed.value;
    if (!std.mem.eql(u8, wire.jsonrpc, "2.0")) return error.InvalidJson;

    var result: DecodedEnvelope = .{ .body = body };
    if (wire.id) |id| {
        if (id.len > request_id_bytes_max) return error.InvalidJson;
        const parsed_id = try parseWireId(id);
        result.origin = parsed_id.origin;
        result.id = parsed_id.value;
    }
    if (wire.method) |method| {
        if (method.len == 0 or method.len > method_bytes_max) return error.InvalidJson;
        if (wire.result != null or wire.@"error" != null) return error.InvalidJson;
        if (result.id == null or result.origin != .node) return error.InvalidJson;
        @memcpy(result.method[0..method.len], method);
        result.method_len = method.len;
    } else {
        if (result.id == null or result.origin != .zig) return error.InvalidJson;
        if (wire.result != null and wire.@"error" != null) return error.InvalidJson;
    }
    result.rpc_error = wire.@"error" != null;
    if (wire.result) |result_value| try decodeResult(allocator, result_value, &result);
    return result;
}

fn validateJson(allocator: std.mem.Allocator, body: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, body);
    defer scanner.deinit();
    try scanner.ensureTotalStackCapacity(json_depth_max);
    var count: usize = 0;
    while (true) {
        const token = scanner.next() catch return error.InvalidJson;
        count += 1;
        if (count > json_tokens_max or scanner.stackHeight() > json_depth_max) return error.InvalidJson;
        if (token == .end_of_document) break;
    }
}

fn decodeResult(
    allocator: std.mem.Allocator,
    value: WireResult,
    envelope: *DecodedEnvelope,
) !void {
    if (value.pong orelse false) {
        envelope.result = .pong;
        return;
    }
    if (value.stopped orelse false) {
        envelope.result = .stopped;
        return;
    }
    if (value.initialized orelse false) {
        const commands = value.promptCommands orelse return error.InvalidJson;
        if (commands.len > prompt_commands_max) return error.InvalidJson;
        for (commands, 0..) |command, index| {
            if (!validPromptCommandName(command.name) or
                command.description.len == 0 or
                command.description.len > prompt_command_description_bytes_max or
                !std.unicode.utf8ValidateSlice(command.description) or
                slash_commands.lookup(command.name) != null)
            {
                return error.InvalidJson;
            }
            for (envelope.commands[0..index]) |previous| {
                if (std.mem.eql(u8, previous.name(), command.name)) return error.InvalidJson;
            }
            envelope.commands[index].name_len = @intCast(command.name.len);
            @memcpy(envelope.commands[index].name_buffer[0..command.name.len], command.name);
            envelope.commands[index].description_len = @intCast(command.description.len);
            @memcpy(envelope.commands[index].description_buffer[0..command.description.len], command.description);
        }
        envelope.command_len = @intCast(commands.len);
        envelope.result = .loaded;
        return;
    }
    if (value.prompt) |prompt| {
        if (prompt.len == 0 or prompt.len > generated_prompt_bytes_max or !std.unicode.utf8ValidateSlice(prompt)) {
            return error.InvalidJson;
        }
        envelope.prompt = try allocator.dupe(u8, prompt);
        envelope.result = .prompt;
        return;
    }
    if (value.nested != null) {
        envelope.result = .nested;
        return;
    }
    const protocol = value.protocol orelse {
        envelope.result = .other;
        return;
    };
    const node_version = value.nodeVersion orelse {
        envelope.result = .other;
        return;
    };
    const host_sha = value.hostSha orelse {
        envelope.result = .other;
        return;
    };
    const runtime_name = value.runtimeName orelse {
        envelope.result = .other;
        return;
    };
    const host_version = value.hostVersion orelse {
        envelope.result = .other;
        return;
    };
    const generation_nonce = value.generationNonce orelse {
        envelope.result = .other;
        return;
    };
    if (node_version.len > 32 or host_sha.len != asset.digest.len * 2 or generation_nonce.len != 32) {
        return error.InvalidJson;
    }
    var initialize: DecodedEnvelope.Initialize = .{
        .protocol_major = protocol.major,
        .protocol_minor = protocol.minor,
        .node_version = undefined,
        .node_version_len = node_version.len,
        .host_sha = undefined,
        .generation_nonce = undefined,
        .node_runtime = std.mem.eql(u8, runtime_name, "node"),
        .host_version_valid = std.mem.eql(u8, host_version, "1.0.0"),
    };
    @memcpy(initialize.node_version[0..node_version.len], node_version);
    @memcpy(&initialize.host_sha, host_sha);
    @memcpy(&initialize.generation_nonce, generation_nonce);
    envelope.result = .{ .initialize = initialize };
}

fn parseWireId(id: []const u8) !struct { origin: IdOrigin, value: u64 } {
    if (id.len < 3 or id[1] != ':') return error.InvalidJson;
    const origin: IdOrigin = switch (id[0]) {
        'z' => .zig,
        'n' => .node,
        else => return error.InvalidJson,
    };
    const raw = id[2..];
    if (raw.len == 0 or (raw.len > 1 and raw[0] == '0')) return error.InvalidJson;
    for (raw) |char| if (!std.ascii.isDigit(char)) return error.InvalidJson;
    return .{ .origin = origin, .value = std.fmt.parseInt(u64, raw, 10) catch return error.InvalidJson };
}

fn encodeRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":\"z:{d}\",\"method\":", .{id});
    try std.json.Stringify.value(method, .{}, &body.writer);
    try body.writer.writeAll(",\"params\":");
    try body.writer.writeAll(params_json);
    try body.writer.writeByte('}');
    return frameBody(allocator, body.written());
}

fn encodeNotification(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try std.json.Stringify.value(method, .{}, &body.writer);
    try body.writer.writeAll(",\"params\":");
    try body.writer.writeAll(params_json);
    try body.writer.writeByte('}');
    return frameBody(allocator, body.written());
}

fn encodeResult(
    allocator: std.mem.Allocator,
    origin: IdOrigin,
    id: u64,
    result_json: []const u8,
) ![]u8 {
    const prefix: u8 = if (origin == .zig) 'z' else 'n';
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"{c}:{d}\",\"result\":{s}}}",
        .{ prefix, id, result_json },
    );
    defer allocator.free(body);
    return frameBody(allocator, body);
}

fn encodeRpcError(
    allocator: std.mem.Allocator,
    origin: IdOrigin,
    id: u64,
    code: i32,
    message: []const u8,
) ![]u8 {
    const prefix: u8 = if (origin == .zig) 'z' else 'n';
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":\"{c}:{d}\",\"error\":{{\"code\":{d},\"message\":", .{
        prefix,
        id,
        code,
    });
    try std.json.Stringify.value(message, .{}, &body.writer);
    try body.writer.writeAll("}}");
    return frameBody(allocator, body.written());
}

fn frameBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len > frame_body_bytes_max) return error.CapacityExceeded;
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

fn appendTail(buffer: []u8, len: *usize, bytes_value: []const u8) void {
    if (bytes_value.len >= buffer.len) {
        @memcpy(buffer, bytes_value[bytes_value.len - buffer.len ..]);
        len.* = buffer.len;
        return;
    }
    const overflow = (len.* + bytes_value.len) -| buffer.len;
    if (overflow > 0) {
        @memmove(buffer[0 .. len.* - overflow], buffer[overflow..len.*]);
        len.* -= overflow;
    }
    @memcpy(buffer[len.* .. len.* + bytes_value.len], bytes_value);
    len.* += bytes_value.len;
}

fn settleChild(child: *runtime.DuplexChild) void {
    child.cancelIoAfterExit();
    std.debug.assert(child.readyToSettle());
    child.settle();
}

fn stopChildSynchronously(child: *runtime.DuplexChild, task_runtime: *runtime.Runtime) void {
    child.forceKill();
    while (!child.processComplete()) task_runtime.sleep(.fromMilliseconds(1)) catch break;
    settleChild(child);
    child.deinit();
}

fn stopDecoderAndChild(
    allocator: std.mem.Allocator,
    child: *runtime.DuplexChild,
    decoder: *DecoderState,
    decoder_task: *runtime.Task(void),
    task_runtime: *runtime.Runtime,
) void {
    child.forceKill();
    while (!child.processComplete()) task_runtime.sleep(.fromMilliseconds(1)) catch break;
    settleChild(child);
    while (!decoder_task.hasResult()) task_runtime.sleep(.fromMilliseconds(1)) catch break;
    _ = decoder_task.getResult();
    decoder.deinit();
    allocator.destroy(decoder);
    child.deinit();
}

fn minDeadline(current: ?u64, candidate: ?u64) ?u64 {
    const value = candidate orelse return current;
    return if (current) |existing| @min(existing, value) else value;
}

fn resolveNodeExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    executable: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(executable) or std.mem.findScalar(u8, executable, std.fs.path.sep) != null) {
        return allocator.dupe(u8, executable);
    }
    const path_value = if (environ) |env| env.get("PATH") else null;
    if (path_value) |path| {
        var entries = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
        while (entries.next()) |entry| {
            if (entry.len == 0) continue;
            const candidate = try std.fs.path.join(allocator, &.{ entry, executable });
            std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
                allocator.free(candidate);
                continue;
            };
            return candidate;
        }
    }
    return allocator.dupe(u8, executable);
}

fn currentNowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    if (raw <= 0) return 0;
    return @intCast(@min(raw, std.math.maxInt(u64)));
}

fn parseVersionPart(text: []const u8) !u32 {
    if (text.len == 0) return error.InvalidNodeVersion;
    for (text) |char| if (!std.ascii.isDigit(char)) return error.InvalidNodeVersion;
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidNodeVersion;
}

fn validPromptCommandName(name: []const u8) bool {
    if (name.len == 0 or name.len > prompt_command_name_bytes_max or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |char| {
        if (!std.ascii.isLower(char) and !std.ascii.isDigit(char) and char != '-') return false;
    }
    return true;
}

fn validateCanonicalPath(path: []const u8) !void {
    if (path.len == 0 or path.len > module_path_bytes_max) return error.InvalidExtensionPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidExtensionPath;
    if (!std.fs.path.isAbsolute(path)) return error.ExtensionPathNotAbsolute;

    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.ExtensionPathNotCanonical;
        }
    }
}

fn testHostFixture() !struct {
    tmp: std.testing.TmpDir,
    task_runtime: *runtime.Runtime,
    environ: *std.process.Environ.Map,
    plan: ExtensionLoadPlan,
    host: ExtensionHostGeneration,
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const root_path = root_buffer[0..root_len];
    const agent_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "agent" });
    defer std.testing.allocator.free(agent_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "extension.ts",
        .data =
        \\export default function activate(zi) {
        \\  zi.commands.registerPrompt({
        \\    name: "fixture-review",
        \\    description: "Review a fixture",
        \\    run: ({ args }) => {
        \\      if (args === "fail") throw new Error("fixture failure");
        \\      return { prompt: `Review ${args}` };
        \\    },
        \\  });
        \\}
        ,
    });
    const extension_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "extension.ts" });
    defer std.testing.allocator.free(extension_path);
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
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
    const host = try ExtensionHostGeneration.init(std.testing.allocator, .{
        .task_runtime = task_runtime,
        .cwd = root_path,
        .agent_dir = agent_dir,
        .environ = environ,
        .node_executable = build_options.node_executable,
    }, &plan);
    return .{
        .tmp = tmp,
        .task_runtime = task_runtime,
        .environ = environ,
        .plan = plan,
        .host = host,
    };
}

test "extension load plan owns bounded canonical entries" {
    const source = try std.testing.allocator.dupe(u8, "/repo/extensions/one.ts");
    defer std.testing.allocator.free(source);
    var plan = try ExtensionLoadPlan.init(std.testing.allocator, &.{.{
        .canonical_path = source,
        .provenance = .project,
    }});
    defer plan.deinit();
    @memset(source, 'x');

    try std.testing.expect(plan.enabled());
    try std.testing.expectEqualStrings("/repo/extensions/one.ts", plan.entries[0].canonical_path);
    try std.testing.expectEqual(Provenance.project, plan.entries[0].provenance);
}

test "extension load plan rejects unbounded duplicate and noncanonical paths" {
    try std.testing.expectError(error.ExtensionPathNotAbsolute, ExtensionLoadPlan.init(
        std.testing.allocator,
        &.{.{ .canonical_path = "relative.ts", .provenance = .explicit }},
    ));
    try std.testing.expectError(error.ExtensionPathNotCanonical, ExtensionLoadPlan.init(
        std.testing.allocator,
        &.{.{ .canonical_path = "/repo/../extension.ts", .provenance = .explicit }},
    ));
    try std.testing.expectError(error.DuplicateExtension, ExtensionLoadPlan.init(
        std.testing.allocator,
        &.{
            .{ .canonical_path = "/extension.ts", .provenance = .explicit },
            .{ .canonical_path = "/extension.ts", .provenance = .global },
        },
    ));

    var specs: [load_plan_entries_max + 1]ExtensionSpec = undefined;
    for (&specs) |*spec| spec.* = .{ .canonical_path = "/extension.ts", .provenance = .explicit };
    try std.testing.expectError(error.TooManyExtensions, ExtensionLoadPlan.init(std.testing.allocator, &specs));
}

test "disabled load plan neither materializes nor spawns" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var plan = ExtensionLoadPlan.disabled(std.testing.allocator);
    defer plan.deinit();
    var host = try ExtensionHostGeneration.init(std.testing.allocator, .{
        .task_runtime = task_runtime,
        .cwd = "/repo",
        .agent_dir = "/agent",
    }, &plan);
    try host.start(0);
    try std.testing.expect(host.shutdownComplete());
    host.deinit();
}

test "node command resolution is explicit then environment then path" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("ZI_NODE", "/opt/node/bin/node");

    try std.testing.expectEqualStrings(
        "/explicit/node",
        (try NodeCommand.resolve(&environ, "/explicit/node")).executable,
    );
    try std.testing.expectEqualStrings("/opt/node/bin/node", (try NodeCommand.resolve(&environ, null)).executable);
    try std.testing.expectEqualStrings("node", (try NodeCommand.resolve(null, null)).executable);
}

test "node version enforces the minimum without accepting alternate runtimes" {
    try std.testing.expect(!(try NodeVersion.parse("22.18.9")).supported());
    try std.testing.expect((try NodeVersion.parse("22.19.0")).supported());
    try std.testing.expect((try NodeVersion.parse("23.0.0")).supported());
    try std.testing.expectError(error.InvalidNodeVersion, NodeVersion.parse("v22.19.0"));
}

test "real ExtensionHostGeneration handshakes pings wakes and shuts down" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    var wake: runtime.WakeEvent = .init;
    host.setWake(&wake);
    try host.start(0);

    var now: u64 = 0;
    while (!host.available() and host.diagnostic() == null and now < startup_timeout_ns) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(host.available());
    try std.testing.expect(wake.isSet());
    try std.testing.expectEqual(@as(usize, 1), host.promptCommands().len);
    try std.testing.expectEqualStrings("fixture-review", host.promptCommands()[0].name());
    try std.testing.expectEqualStrings("Review a fixture", host.promptCommands()[0].description());

    var command = try host.startPromptCommand("fixture-review", "concurrency", now + std.time.ns_per_s);
    while (host.pollPromptCommand(&command) == .pending) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(host.pollPromptCommand(&command) == .success);
    const generated_prompt = try host.takePromptCommand(&command);
    defer std.testing.allocator.free(generated_prompt);
    try std.testing.expectEqualStrings("Review concurrency", generated_prompt);
    host.deinitPromptCommand(&command);

    var failed_command = try host.startPromptCommand("fixture-review", "fail", now + std.time.ns_per_s);
    while (host.pollPromptCommand(&failed_command) == .pending) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    const extension_error: PromptCommandPoll = .{ .failure = .extension_error };
    try std.testing.expectEqual(extension_error, host.pollPromptCommand(&failed_command));
    host.deinitPromptCommand(&failed_command);
    try std.testing.expect(host.available());

    var ping = try host.startPing(now + std.time.ns_per_s);
    while (host.pollPing(&ping) == .pending) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(host.pollPing(&ping) == .success);
    host.deinitPing(&ping);

    var nested = try host.startTestNested(now + std.time.ns_per_s);
    while (host.pollPing(&nested) == .pending) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(host.pollPing(&nested) == .success);
    host.deinitPing(&nested);

    var canceled = try host.startTestWait(now + std.time.ns_per_s);
    host.cancel(&canceled);
    while (host.pollPing(&canceled) == .pending) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    const expected: PingPoll = .{ .failure = .canceled };
    try std.testing.expectEqual(expected, host.pollPing(&canceled));
    host.deinitPing(&canceled);

    host.requestShutdown(now);
    while (!host.shutdownComplete() and now < 10 * std.time.ns_per_s) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(host.shutdownComplete());
}

fn shutdownTestHost(host: *ExtensionHostGeneration, task_runtime: *runtime.Runtime) void {
    var now = currentNowNs(task_runtime.io());
    if (!host.shutdownComplete()) host.requestShutdown(now);
    var attempts: usize = 0;
    while (!host.shutdownComplete() and attempts < 10_000) : (attempts += 1) {
        now +|= std.time.ns_per_ms;
        host.poll(now);
        task_runtime.sleep(.fromMilliseconds(1)) catch break;
    }
    if (!host.shutdownComplete()) {
        host.failGeneration(.shutdown, now);
        while (!host.shutdownComplete() and attempts < 20_000) : (attempts += 1) {
            now +|= std.time.ns_per_ms;
            host.poll(now);
            task_runtime.sleep(.fromMilliseconds(1)) catch break;
        }
    }
    std.debug.assert(host.shutdownComplete());
    host.deinit();
}

test "handshake rejects an unsupported Node version before activation" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    try fixture.environ.put("ZI_EXTENSION_HOST_TEST_NODE_VERSION", "22.18.0");
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = fixture.plan.entries[0].canonical_path,
        .data = "throw new Error('must not load before handshake');\n",
    });
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    try host.start(0);

    var now: u64 = 0;
    while (host.diagnostic() == null and now < startup_timeout_ns) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expectEqual(Failure.unsupported_node, host.diagnostic().?.failure);
    try std.testing.expect(!host.available());
}

test "handshake rejects a mismatched embedded host digest" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    try fixture.environ.put(
        "ZI_EXTENSION_HOST_TEST_HOST_SHA",
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    try host.start(0);

    var now: u64 = 0;
    while (host.diagnostic() == null and now < startup_timeout_ns) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expectEqual(Failure.protocol, host.diagnostic().?.failure);
    try std.testing.expect(!host.available());
}

test "handshake rejects a mismatched generation nonce" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    try fixture.environ.put("ZI_EXTENSION_HOST_TEST_NONCE", "ffffffffffffffffffffffffffffffff");
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    try host.start(0);

    var now: u64 = 0;
    while (host.diagnostic() == null and now < startup_timeout_ns) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expectEqual(Failure.protocol, host.diagnostic().?.failure);
    try std.testing.expect(!host.available());
}

test "infinite-loop host expires independently while owner work progresses" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    try host.start(0);

    var now: u64 = 0;
    try waitUntilActive(&host, fixture.task_runtime, &now);
    var spin = try host.startTestSpin(now + 20 * std.time.ns_per_ms);
    var owner_steps: usize = 0;
    while (host.pollPing(&spin) == .pending) : (now += std.time.ns_per_ms) {
        owner_steps += 1;
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(owner_steps > 1);
    const expected: PingPoll = .{ .failure = .deadline };
    try std.testing.expectEqual(expected, host.pollPing(&spin));
    host.deinitPing(&spin);
}

test "shutdown settles pending operations and preserves its exit deadline" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    try host.start(0);

    var now: u64 = 0;
    try waitUntilActive(&host, fixture.task_runtime, &now);
    var waiting = try host.startTestWait(now + 10 * std.time.ns_per_s);
    host.requestShutdown(now);
    const stopped: PingPoll = .{ .failure = .shutdown };
    try std.testing.expectEqual(stopped, host.pollPing(&waiting));
    host.deinitPing(&waiting);
    try std.testing.expect(host.nextDeadline() != null);
    while (!host.shutdownComplete() and now < 2 * std.time.ns_per_s) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(host.shutdownComplete());
}

test "host crash settles every pending operation with one generation failure" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    try host.start(0);

    var now: u64 = 0;
    try waitUntilActive(&host, fixture.task_runtime, &now);
    var ping = try host.startTestWait(now + std.time.ns_per_s);
    var crash = try host.startTestCrash(now + std.time.ns_per_s);
    while (host.pollPing(&crash) == .pending and now < 2 * std.time.ns_per_s) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expect(host.diagnostic() != null);
    try std.testing.expect(host.pollPing(&ping) != .pending);
    host.deinitPing(&ping);
    host.deinitPing(&crash);
}

test "malformed host stdout fails the generation without resynchronizing" {
    var fixture = try testHostFixture();
    defer fixture.tmp.cleanup();
    defer fixture.plan.deinit();
    defer {
        fixture.environ.deinit();
        std.testing.allocator.destroy(fixture.environ);
    }
    defer fixture.task_runtime.deinit();
    var host = fixture.host;
    defer shutdownTestHost(&host, fixture.task_runtime);
    try host.start(0);

    var now: u64 = 0;
    try waitUntilActive(&host, fixture.task_runtime, &now);
    var malformed = try host.startTestMalformed(now + std.time.ns_per_s);
    while (host.diagnostic() == null and now < 2 * std.time.ns_per_s) : (now += std.time.ns_per_ms) {
        host.poll(now);
        fixture.task_runtime.sleep(.fromMilliseconds(1)) catch return error.Canceled;
    }
    try std.testing.expectEqual(Failure.protocol, host.diagnostic().?.failure);
    try std.testing.expect(host.pollPing(&malformed) != .pending);
    host.deinitPing(&malformed);
}

fn waitUntilActive(host: *ExtensionHostGeneration, task_runtime: *runtime.Runtime, now: *u64) !void {
    while (!host.available() and
        host.diagnostic() == null and
        now.* < startup_timeout_ns) : (now.* += std.time.ns_per_ms)
    {
        host.poll(now.*);
        try task_runtime.sleep(.fromMilliseconds(1));
    }
    if (!host.available()) return error.HostUnavailable;
}

test "pending capacity is fixed and terminal generation failure settles every slot" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var plan = ExtensionLoadPlan.disabled(std.testing.allocator);
    defer plan.deinit();
    var host = try ExtensionHostGeneration.init(std.testing.allocator, .{
        .task_runtime = task_runtime,
        .cwd = "/repo",
        .agent_dir = "/agent",
    }, &plan);
    defer host.deinit();
    host.lifecycle = .active;
    for (&host.pending, 0..) |*pending, index| {
        pending.* = .{
            .active = true,
            .generation = host.generation,
            .id = index + 1,
            .deadline_ns = 100,
        };
    }
    try std.testing.expect(host.freePending() == null);
    host.failGeneration(.generation_failed, 0);
    const expected: OperationState = .{ .failure = .generation_failed };
    for (host.pending) |pending| try std.testing.expectEqual(expected, pending.state);
    try std.testing.expect(host.shutdownComplete());
}

test "nearest operation deadline settles and fails an unresponsive generation" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var plan = ExtensionLoadPlan.disabled(std.testing.allocator);
    defer plan.deinit();
    var host = try ExtensionHostGeneration.init(std.testing.allocator, .{
        .task_runtime = task_runtime,
        .cwd = "/repo",
        .agent_dir = "/agent",
    }, &plan);
    defer host.deinit();
    host.lifecycle = .active;
    host.pending[0] = .{
        .active = true,
        .generation = host.generation,
        .id = 1,
        .deadline_ns = 25,
    };
    host.pending[1] = .{
        .active = true,
        .generation = host.generation,
        .id = 2,
        .deadline_ns = 10,
    };
    try std.testing.expectEqual(@as(?u64, 10), host.nextDeadline());
    host.poll(10);
    const expected: OperationState = .{ .failure = .deadline };
    try std.testing.expectEqual(expected, host.pending[1].state);
    try std.testing.expectEqual(Failure.deadline, host.diagnostic().?.failure);
    try std.testing.expect(host.shutdownComplete());
}

test "duplicate terminal response is a protocol failure" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var plan = ExtensionLoadPlan.disabled(std.testing.allocator);
    defer plan.deinit();
    var host = try ExtensionHostGeneration.init(std.testing.allocator, .{
        .task_runtime = task_runtime,
        .cwd = "/repo",
        .agent_dir = "/agent",
    }, &plan);
    defer host.deinit();
    host.lifecycle = .active;
    host.pending[0] = .{
        .active = true,
        .generation = host.generation,
        .id = 1,
        .state = .success,
    };
    const body = try std.testing.allocator.dupe(u8, "{}");
    var envelope: DecodedEnvelope = .{
        .body = body,
        .origin = .zig,
        .id = 1,
        .result = .pong,
    };
    defer envelope.deinit(std.testing.allocator);
    host.applyEnvelope(&envelope, 0);
    try std.testing.expectEqual(Failure.protocol, host.diagnostic().?.failure);
    try std.testing.expect(host.shutdownComplete());
}

test "frame decoder rejects malformed and oversized input" {
    try std.testing.expectError(error.InvalidFrame, parseContentLength("Other: 2"));
    try std.testing.expectError(error.InvalidFrame, parseContentLength("Content-Length: 2\r\nContent-Length: 2"));
    var oversized_buffer: [32]u8 = undefined;
    const oversized = try std.fmt.bufPrint(&oversized_buffer, "Content-Length: {d}", .{frame_body_bytes_max + 1});
    try std.testing.expectError(error.CapacityExceeded, parseContentLength(oversized));
}

test "stderr tail evicts oldest bytes" {
    var buffer: [8]u8 = undefined;
    var len: usize = 0;
    appendTail(&buffer, &len, "12345");
    appendTail(&buffer, &len, "67890");
    try std.testing.expectEqualStrings("34567890", buffer[0..len]);
}

test "stderr total cap fails a generation while retaining a bounded tail" {
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var plan = ExtensionLoadPlan.disabled(std.testing.allocator);
    defer plan.deinit();
    var host = try ExtensionHostGeneration.init(std.testing.allocator, .{
        .task_runtime = task_runtime,
        .cwd = "/repo",
        .agent_dir = "/agent",
    }, &plan);
    defer host.deinit();
    host.lifecycle = .active;
    host.stderr_total = stderr_total_bytes_max;
    host.recordStderr("overflow", 0);
    try std.testing.expectEqual(Failure.generation_failed, host.diagnostic().?.failure);
    try std.testing.expectEqualStrings("overflow", host.diagnostic().?.stderr_tail);
}
