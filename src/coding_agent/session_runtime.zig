const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const AgentSession = @import("AgentSession.zig");
const client_protocol = @import("client_protocol.zig");
const paths_mod = @import("paths.zig");
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");
const session_history_snapshot = @import("session_history_snapshot.zig");
const settings_mod = @import("settings.zig");

const CommonOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    current_date: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    task_runtime: ?*runtime.Runtime = null,
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
    command_capacity: usize = client_protocol.command_queue_capacity_default,
    event_capacity: usize = client_protocol.event_queue_capacity_default,
    retained_event_capacity: usize = client_protocol.retained_event_count_default,
    retained_event_bytes: usize = client_protocol.retained_event_bytes_default,
};

const OpenSessionCreate = struct {
    session_id: []const u8,
    timestamp: []const u8,
};

const OpenSessionResume = struct {
    session_file_name: []const u8,
};

const OpenSession = union(enum) {
    create: OpenSessionCreate,
    resume_existing: OpenSessionResume,
};

const CreateOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    current_date: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    task_runtime: ?*runtime.Runtime = null,
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
    command_capacity: usize = client_protocol.command_queue_capacity_default,
    event_capacity: usize = client_protocol.event_queue_capacity_default,
    retained_event_capacity: usize = client_protocol.retained_event_count_default,
    retained_event_bytes: usize = client_protocol.retained_event_bytes_default,
};

const ResumeOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    current_date: []const u8,
    session_file_name: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    task_runtime: ?*runtime.Runtime = null,
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
    command_capacity: usize = client_protocol.command_queue_capacity_default,
    event_capacity: usize = client_protocol.event_queue_capacity_default,
    retained_event_capacity: usize = client_protocol.retained_event_count_default,
    retained_event_bytes: usize = client_protocol.retained_event_bytes_default,
};

pub const WakeResult = enum { input, session, frame };

const RetainedEventLedger = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    start: usize = 0,
    count: usize = 0,
    total_bytes: usize = 0,
    max_bytes: usize,
    evicted_through_seq: client_protocol.EventSeq = 0,

    const Entry = struct {
        seq: client_protocol.EventSeq,
        json: []u8,
    };

    const ReplayResult = union(enum) {
        batch: client_protocol.ReplayBatch,
        gap: client_protocol.ReplayGap,
    };

    fn init(allocator: std.mem.Allocator, capacity: usize, max_bytes: usize) !RetainedEventLedger {
        if (capacity == 0) return error.RetainedEventCapacityZero;
        if (max_bytes == 0) return error.RetainedEventBytesZero;
        return .{
            .allocator = allocator,
            .entries = try allocator.alloc(Entry, capacity),
            .max_bytes = max_bytes,
        };
    }

    fn deinit(self: *RetainedEventLedger) void {
        while (self.count > 0) self.evictOldest();
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    fn append(self: *RetainedEventLedger, envelope: client_protocol.EventEnvelope) !void {
        if (envelope.event == .replay or envelope.event == .replay_gap) return;
        const json = try encodeEnvelopeJsonBounded(self.allocator, envelope, self.max_bytes) orelse {
            self.evictAllThrough(envelope.seq);
            return;
        };
        errdefer self.allocator.free(json);
        while (self.count == self.entries.len or self.total_bytes + json.len > self.max_bytes) self.evictOldest();
        const index = (self.start + self.count) % self.entries.len;
        self.entries[index] = .{ .seq = envelope.seq, .json = json };
        self.count += 1;
        self.total_bytes += json.len;
    }

    fn buildReplay(
        self: *const RetainedEventLedger,
        allocator: std.mem.Allocator,
        request: client_protocol.ReplayRequest,
    ) !client_protocol.EventEnvelope {
        const first = self.firstRetainedSeq();
        const last = self.lastRetainedSeq();
        if (request.after < self.evicted_through_seq) {
            return .{ .event = .{ .replay_gap = .{
                .requested_after = request.after,
                .first_retained_seq = first,
                .last_retained_seq = last,
            } } };
        }
        const max_events = @min(request.max_events, client_protocol.replay_event_count_max);
        var scratch = try allocator.alloc(client_protocol.RetainedEvent.Source, max_events);
        defer allocator.free(scratch);
        var out_count: usize = 0;
        var index: usize = 0;
        while (index < self.count and out_count < scratch.len) : (index += 1) {
            const entry = self.entryAt(index);
            if (entry.seq <= request.after) continue;
            scratch[out_count] = .{ .seq = entry.seq, .json = entry.json };
            out_count += 1;
        }
        return .{ .event = .{ .replay = try client_protocol.ReplayBatch.init(
            allocator,
            request.after,
            first,
            last,
            scratch[0..out_count],
        ) } };
    }

    fn firstRetainedSeq(self: *const RetainedEventLedger) client_protocol.EventSeq {
        if (self.count == 0) return self.evicted_through_seq + 1;
        return self.entries[self.start].seq;
    }

    fn lastRetainedSeq(self: *const RetainedEventLedger) client_protocol.EventSeq {
        if (self.count == 0) return self.evicted_through_seq;
        return self.entryAt(self.count - 1).seq;
    }

    fn entryAt(self: *const RetainedEventLedger, offset: usize) Entry {
        std.debug.assert(offset < self.count);
        return self.entries[(self.start + offset) % self.entries.len];
    }

    fn evictOldest(self: *RetainedEventLedger) void {
        std.debug.assert(self.count > 0);
        const entry = self.entries[self.start];
        self.evicted_through_seq = entry.seq;
        self.total_bytes -= entry.json.len;
        self.allocator.free(entry.json);
        self.start = (self.start + 1) % self.entries.len;
        self.count -= 1;
        if (self.count == 0) self.start = 0;
    }

    fn evictAllThrough(self: *RetainedEventLedger, seq: client_protocol.EventSeq) void {
        while (self.count > 0) self.evictOldest();
        self.evicted_through_seq = seq;
    }
};

fn encodeEnvelopeJsonBounded(
    allocator: std.mem.Allocator,
    envelope: client_protocol.EventEnvelope,
    max_bytes: usize,
) !?[]u8 {
    var storage = try allocator.alloc(u8, max_bytes);
    defer allocator.free(storage);
    var writer = std.Io.Writer.fixed(storage);
    std.json.Stringify.value(envelope, .{}, &writer) catch |err| switch (err) {
        error.WriteFailed => return null,
    };
    return try allocator.dupe(u8, storage[0..writer.end]);
}

pub const AgentSessionRuntimeHost = struct {
    allocator: std.mem.Allocator,
    services: RuntimeServices,
    session: AgentSession,
    command_buffer: []client_protocol.CommandEnvelope,
    event_buffer: []client_protocol.EventEnvelope,
    commands: client_protocol.CommandQueue,
    events: client_protocol.EventQueue,
    retained_events: RetainedEventLedger,
    wake_event: runtime.ResetEvent = .init,
    active_run: ?*AgentSession.PromptRun = null,
    active_request_id: ?client_protocol.RequestId = null,
    active_operation_id: ?client_protocol.OperationId = null,
    next_operation_id: client_protocol.OperationId = 1,
    next_event_seq: client_protocol.EventSeq = 1,
    active_prompt_text: ?[]u8 = null,
    active_overflow_count_before: usize = 0,
    pending_event: ?client_protocol.EventEnvelope = null,

    pub fn submit(self: *AgentSessionRuntimeHost, envelope: client_protocol.CommandEnvelope) !void {
        try self.commands.push(envelope);
        self.wake_event.set();
    }

    pub fn drainEvent(self: *AgentSessionRuntimeHost) ?client_protocol.EventEnvelope {
        return self.events.pop();
    }

    pub fn hasPendingClientEvents(self: *const AgentSessionRuntimeHost) bool {
        return self.pending_event != null or self.events.count() > 0;
    }

    pub fn hasQueuedCommands(self: *const AgentSessionRuntimeHost) bool {
        return self.commands.count() > 0;
    }

    pub fn rejectClientCommand(
        self: *AgentSessionRuntimeHost,
        request_id: ?client_protocol.RequestId,
        code: client_protocol.Rejection.Code,
        message: []const u8,
    ) !void {
        try self.enqueueRejected(request_id, code, message);
    }

    pub fn waitForWake(self: *AgentSessionRuntimeHost, input_fd: std.posix.fd_t, frame_ms: u64) !WakeResult {
        const readable = runtime.ReadableFd.initBorrowed(input_fd);
        var input = readable.asyncReadable();
        var frame = runtime.Timeout.fromMilliseconds(frame_ms);
        var public_event_wake = self.session.publicEventWake();
        const command_wake = &self.wake_event;
        if (self.active_run) |run| {
            var progress = run.stream.asyncNext();
            switch (try runtime.select(.{ .input = &input, .prompt = &progress, .public_event = public_event_wake, .command = command_wake, .frame = &frame })) {
                .input => |result| {
                    result catch return .session;
                    return .input;
                },
                .prompt => |result| {
                    self.applyPromptProgressResult(run, result) catch |err| switch (err) {
                        error.EventQueueFull => return .session,
                        else => return err,
                    };
                    return .session;
                },
                .public_event => {
                    public_event_wake.reset();
                    self.drainSessionEvents(null) catch return .session;
                    return .session;
                },
                .command => {
                    self.wake_event.reset();
                    return .session;
                },
                .frame => return .frame,
            }
        }
        switch (try runtime.select(.{ .input = &input, .public_event = public_event_wake, .command = command_wake, .frame = &frame })) {
            .input => |result| {
                result catch return .session;
                return .input;
            },
            .public_event => {
                public_event_wake.reset();
                self.drainSessionEvents(null) catch return .session;
                return .session;
            },
            .command => {
                self.wake_event.reset();
                return .session;
            },
            .frame => return .frame,
        }
    }

    fn stepPromptProgressBounded(self: *AgentSessionRuntimeHost, limit: usize) !usize {
        const run = self.active_run orelse return 0;
        var count: usize = 0;
        while (count < limit and self.active_run != null) : (count += 1) {
            var progress = run.stream.asyncNext();
            var ready = runtime.Timeout.fromMilliseconds(0);
            switch (try runtime.select(.{ .prompt = &progress, .ready = &ready })) {
                .prompt => |result| try self.applyPromptProgressResult(run, result),
                .ready => return count,
            }
        }
        return count;
    }

    pub fn step(self: *AgentSessionRuntimeHost) !void {
        if (!self.flushPendingEvent()) return;
        while (self.hasEventCapacity()) {
            const envelope = self.commands.pop() orelse break;
            var command = envelope;
            defer command.deinit(self.allocator);
            self.applyCommand(command) catch |err| switch (err) {
                error.EventQueueFull => return,
                else => return err,
            };
            if (!self.flushPendingEvent()) return;
        }
        if (!self.hasEventCapacity()) return;
        _ = self.stepPromptProgressBounded(64) catch |err| switch (err) {
            error.EventQueueFull => return,
            else => return err,
        };
        if (!self.flushPendingEvent()) return;
        self.drainSessionEvents(null) catch return;
    }

    pub fn deinit(self: *AgentSessionRuntimeHost) void {
        if (self.active_run) |run| {
            self.session.destroyPromptRun(run);
            self.active_run = null;
        }
        self.clearActivePromptText();
        drainQueuedCommands(self);
        if (self.pending_event) |*event| event.deinit(self.allocator);
        self.pending_event = null;
        drainQueuedEvents(self);
        self.retained_events.deinit();
        shutdownAndDeinitSession(&self.session);
        self.services.deinit();
        self.allocator.free(self.event_buffer);
        self.allocator.free(self.command_buffer);
        self.* = undefined;
    }

    fn applyCommand(self: *AgentSessionRuntimeHost, envelope: client_protocol.CommandEnvelope) !void {
        switch (envelope.command) {
            .submit => |prompt| {
                if (self.active_run != null and prompt.mode != .start) {
                    const delivery: AgentSession.QueuePromptKind = switch (prompt.mode) {
                        .auto, .steer => .steer,
                        .enqueue => .follow_up,
                        .start => unreachable,
                    };
                    self.session.queuePrompt(prompt.text, &.{}, delivery) catch |err| {
                        try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                        return;
                    };
                    try self.drainSessionEvents(envelope.id);
                    return;
                }
                if (self.active_run != null) {
                    try self.enqueueRejected(envelope.id, .busy, "operation already active");
                    return;
                }
                self.active_prompt_text = self.allocator.dupe(u8, prompt.text) catch |err| {
                    try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                    return;
                };
                self.active_overflow_count_before = self.session.contextOverflowCount();
                const operation_id = self.nextOperationId();
                self.active_run = self.session.startPromptRun(prompt.text, &.{}) catch |err| {
                    self.clearActivePromptText();
                    try self.enqueueRejected(envelope.id, .invalid_command, @errorName(err));
                    return;
                };
                self.active_request_id = envelope.id;
                self.active_operation_id = operation_id;
                try self.enqueueEvent(.{ .request_id = envelope.id, .operation_id = operation_id, .event = .{ .operation_started = .{} } });
                try self.drainSessionEvents(envelope.id);
            },
            .cancel => |cancel| {
                if (!self.cancelTargetsActive(cancel)) {
                    try self.enqueueRejected(envelope.id, .invalid_command, "cancel target not active");
                    return;
                }
                const operation_id = self.active_operation_id;
                if (self.active_run) |run| {
                    self.session.cancelPromptRun(run) catch self.session.cancel();
                    self.session.destroyPromptRun(run);
                    self.active_run = null;
                    self.active_request_id = null;
                    self.active_operation_id = null;
                    self.clearActivePromptText();
                } else self.session.cancel();
                try self.drainSessionEvents(envelope.id);
                try self.enqueueEvent(.{ .request_id = envelope.id, .operation_id = operation_id, .event = .{ .operation_finished = .{ .reason = .canceled } } });
            },
            .queue => |queue_command| switch (queue_command) {
                .clear => {
                    try self.session.clearQueue();
                    try self.drainSessionEvents(null);
                    try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .operation_finished = .{ .reason = .queue_cleared } } });
                },
            },
            .snapshot => {
                const snapshot = try self.buildClientSnapshot();
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .{ .snapshot = snapshot } });
            },
            .replay => |request| {
                var replay = try self.retained_events.buildReplay(self.allocator, request);
                replay.request_id = envelope.id;
                try self.enqueueEvent(replay);
            },
            .shutdown => {
                self.session.requestShutdown();
                try self.enqueueEvent(.{ .request_id = envelope.id, .event = .shutdown_started });
            },
        }
    }

    fn applyPromptProgressResult(self: *AgentSessionRuntimeHost, run: *AgentSession.PromptRun, result: anytype) !void {
        if (self.active_run != run) return;
        const request_id = self.active_request_id;
        const more = try self.session.applyPromptRunProgress(run, result);
        try self.drainSessionEvents(request_id);
        if (!more) {
            self.session.destroyPromptRun(run);
            self.active_run = null;
            const prompt_text = self.active_prompt_text orelse "";
            const operation_id = self.active_operation_id;
            self.session.afterPromptRunFinished(
                self.active_overflow_count_before,
                prompt_text,
                &.{},
            ) catch |err| {
                self.clearActivePromptText();
                self.active_request_id = null;
                self.active_operation_id = null;
                try self.enqueueRejected(request_id, .invalid_command, @errorName(err));
                try self.enqueueEvent(.{ .request_id = request_id, .operation_id = operation_id, .event = .{ .operation_finished = .{ .reason = .failed } } });
                return;
            };
            self.clearActivePromptText();
            const reason: client_protocol.OperationFinished.Reason = if (self.session.agent.state.status == .failed) .failed else .completed;
            self.active_request_id = null;
            self.active_operation_id = null;
            try self.drainSessionEvents(request_id);
            try self.enqueueEvent(.{ .request_id = request_id, .operation_id = operation_id, .event = .{ .operation_finished = .{ .reason = reason } } });
        }
    }

    fn clearActivePromptText(self: *AgentSessionRuntimeHost) void {
        if (self.active_prompt_text) |text| self.allocator.free(text);
        self.active_prompt_text = null;
    }

    fn buildClientSnapshot(self: *AgentSessionRuntimeHost) !client_protocol.Snapshot {
        var queue = try self.session.queueSnapshot(self.allocator);
        errdefer queue.deinit();
        var history = try session_history_snapshot.build(self.allocator, self.session.manager);
        defer history.deinit(self.allocator);
        const history_items = try self.allocator.alloc(client_protocol.HistorySnapshotItem.Source, history.items.len);
        defer self.allocator.free(history_items);
        for (history.items, history_items) |item, *target| {
            target.* = .{
                .role = switch (item.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .system => .system,
                },
                .text = item.text,
            };
        }
        return client_protocol.Snapshot.init(
            self.allocator,
            self.session.manager.header,
            self.session.agent.state.model,
            queue,
            self.active_request_id,
            history_items,
        );
    }

    fn drainSessionEvents(self: *AgentSessionRuntimeHost, request_id: ?client_protocol.RequestId) !void {
        while (self.hasEventCapacity()) {
            const event = self.session.drainPublicEvent() orelse return;
            try self.enqueueEvent(.{ .request_id = request_id, .event = event });
        }
    }

    fn enqueueRejected(
        self: *AgentSessionRuntimeHost,
        request_id: ?client_protocol.RequestId,
        code: client_protocol.Rejection.Code,
        message: []const u8,
    ) !void {
        const owned_message = try client_protocol.EventText.init(self.allocator, message);
        try self.enqueueEvent(.{ .request_id = request_id, .event = .{ .rejected = .{ .code = code, .message = owned_message } } });
    }

    fn enqueueEvent(self: *AgentSessionRuntimeHost, envelope: client_protocol.EventEnvelope) !void {
        var sequenced = envelope;
        sequenced.seq = self.nextEventSeq();
        try self.retained_events.append(sequenced);
        if (self.events.pushOrDrop(sequenced)) return;
        if (self.pending_event == null) {
            self.pending_event = sequenced;
        } else {
            var owned_envelope = sequenced;
            owned_envelope.deinit(self.allocator);
        }
        return error.EventQueueFull;
    }

    fn nextOperationId(self: *AgentSessionRuntimeHost) client_protocol.OperationId {
        const id = self.next_operation_id;
        std.debug.assert(id != 0);
        self.next_operation_id += 1;
        return id;
    }

    fn nextEventSeq(self: *AgentSessionRuntimeHost) client_protocol.EventSeq {
        const seq = self.next_event_seq;
        std.debug.assert(seq != 0);
        self.next_event_seq += 1;
        return seq;
    }

    fn cancelTargetsActive(self: *const AgentSessionRuntimeHost, cancel: client_protocol.Cancel) bool {
        return switch (cancel.target) {
            .active => self.active_run != null,
            .request_id => |id| self.active_request_id == id,
            .operation_id => |id| self.active_operation_id == id,
        };
    }

    fn hasEventCapacity(self: *const AgentSessionRuntimeHost) bool {
        return self.pending_event == null and self.events.count() < self.events.capacity();
    }

    fn flushPendingEvent(self: *AgentSessionRuntimeHost) bool {
        const event = self.pending_event orelse return true;
        if (self.events.pushOrDrop(event)) {
            self.pending_event = null;
            return true;
        }
        return false;
    }
};

pub const SessionRuntime = AgentSessionRuntimeHost;

pub fn createSessionRuntime(allocator: std.mem.Allocator, options: CreateOptions) !AgentSessionRuntimeHost {
    return openSessionRuntime(allocator, commonOptionsFromCreate(options), .{ .create = .{
        .session_id = options.session_id,
        .timestamp = options.timestamp,
    } });
}

pub fn resumeSessionRuntime(allocator: std.mem.Allocator, options: ResumeOptions) !AgentSessionRuntimeHost {
    return openSessionRuntime(allocator, commonOptionsFromResume(options), .{ .resume_existing = .{
        .session_file_name = options.session_file_name,
    } });
}

fn openSessionRuntime(
    allocator: std.mem.Allocator,
    options: CommonOptions,
    open: OpenSession,
) !AgentSessionRuntimeHost {
    var init_result = try initSessionRuntimeBase(allocator, options);
    errdefer init_result.services.deinit();

    var session = switch (open) {
        .create => |create| try createSession(allocator, options, &init_result, create),
        .resume_existing => |resume_open| try resumeSession(allocator, options, &init_result, resume_open),
    };
    errdefer shutdownAndDeinitSession(&session);

    return initWithSession(
        allocator,
        init_result.services,
        session,
        options.command_capacity,
        options.event_capacity,
        options.retained_event_capacity,
        options.retained_event_bytes,
    );
}

fn createSession(
    allocator: std.mem.Allocator,
    options: CommonOptions,
    init_result: *SessionRuntimeInit,
    create: OpenSessionCreate,
) !AgentSession {
    const sessions_dir = try (paths_mod.PersistencePaths{
        .global_dir = init_result.services.agent_dir,
        .cwd = init_result.services.cwd,
    }).sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);

    var store = try session_store.SessionStore.createInPath(
        allocator,
        init_result.services.io,
        options.dir,
        sessions_dir,
        init_result.services.cwd,
        create.session_id,
        create.timestamp,
    );
    errdefer store.deinit(allocator);

    var session_options = init_result.options;
    session_options.session_id = create.session_id;
    session_options.timestamp = create.timestamp;
    session_options.session_store = store;
    return AgentSession.init(allocator, init_result.services.io, session_options);
}

fn resumeSession(
    allocator: std.mem.Allocator,
    options: CommonOptions,
    init_result: *SessionRuntimeInit,
    resume_open: OpenSessionResume,
) !AgentSession {
    if (!std.mem.eql(u8, std.fs.path.basename(resume_open.session_file_name), resume_open.session_file_name)) {
        return error.InvalidSessionFileName;
    }

    const sessions_dir = try (paths_mod.PersistencePaths{
        .global_dir = init_result.services.agent_dir,
        .cwd = init_result.services.cwd,
    }).sessionsDirForCwd(allocator);
    defer allocator.free(sessions_dir);
    const file_name = try std.fs.path.join(allocator, &.{ sessions_dir, resume_open.session_file_name });
    errdefer allocator.free(file_name);

    var session_options = init_result.options;
    session_options.resume_session_store = .{ .dir = options.dir, .file_name = file_name };
    return AgentSession.init(allocator, init_result.services.io, session_options);
}

fn initWithSession(
    allocator: std.mem.Allocator,
    services: RuntimeServices,
    session: AgentSession,
    command_capacity: usize,
    event_capacity: usize,
    retained_event_capacity: usize,
    retained_event_bytes: usize,
) !AgentSessionRuntimeHost {
    if (command_capacity == 0) return error.CommandCapacityZero;
    if (event_capacity == 0) return error.EventCapacityZero;
    var retained_events = try RetainedEventLedger.init(allocator, retained_event_capacity, retained_event_bytes);
    errdefer retained_events.deinit();
    const command_buffer = try allocator.alloc(client_protocol.CommandEnvelope, command_capacity);
    errdefer allocator.free(command_buffer);
    const event_buffer = try allocator.alloc(client_protocol.EventEnvelope, event_capacity);
    errdefer allocator.free(event_buffer);
    return .{
        .allocator = allocator,
        .services = services,
        .session = session,
        .command_buffer = command_buffer,
        .event_buffer = event_buffer,
        .commands = client_protocol.CommandQueue.init(command_buffer),
        .events = client_protocol.EventQueue.init(event_buffer),
        .retained_events = retained_events,
    };
}

const SessionRuntimeInit = struct {
    services: RuntimeServices,
    options: AgentSession.Options,
};

fn commonOptionsFromCreate(options: CreateOptions) CommonOptions {
    return .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .current_date = options.current_date,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .stream = options.stream,
        .dir = options.dir,
        .environ = options.environ,
        .task_runtime = options.task_runtime,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
        .command_capacity = options.command_capacity,
        .event_capacity = options.event_capacity,
        .retained_event_capacity = options.retained_event_capacity,
        .retained_event_bytes = options.retained_event_bytes,
    };
}

fn commonOptionsFromResume(options: ResumeOptions) CommonOptions {
    return .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .current_date = options.current_date,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .stream = options.stream,
        .dir = options.dir,
        .environ = options.environ,
        .task_runtime = options.task_runtime,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
        .command_capacity = options.command_capacity,
        .event_capacity = options.event_capacity,
        .retained_event_capacity = options.retained_event_capacity,
        .retained_event_bytes = options.retained_event_bytes,
    };
}

fn initSessionRuntimeBase(allocator: std.mem.Allocator, options: CommonOptions) !SessionRuntimeInit {
    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    var services = try RuntimeServices.init(allocator, .{
        .cwd = options.cwd,
        .agent_dir = resolved_agent_dir,
        .dir = options.dir,
        .environ = options.environ,
        .task_runtime = options.task_runtime,
    });
    errdefer services.deinit();

    return .{ .services = services, .options = resolveSessionOptions(&services, .{
        .current_date = options.current_date,
        .model = options.model,
        .thinking_level = options.thinking_level,
        .stream = options.stream,
        .dir = options.dir,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    }) };
}

fn shutdownAndDeinitSession(session: *AgentSession) void {
    session.requestShutdown();
    while (session.drainPublicEvent()) |event| {
        var owned_event = event;
        owned_event.deinit();
    }
    session.deinit();
}

fn drainQueuedCommands(self: *AgentSessionRuntimeHost) void {
    while (self.commands.pop()) |envelope| {
        var owned_envelope = envelope;
        owned_envelope.deinit(self.allocator);
    }
}

fn drainQueuedEvents(self: *AgentSessionRuntimeHost) void {
    while (self.events.pop()) |envelope| {
        var owned_envelope = envelope;
        owned_envelope.deinit(self.allocator);
    }
}

const SessionOptionsInput = struct {
    current_date: []const u8,
    model: ?ai.Model = null,
    thinking_level: ?agent_mod.ThinkingLevel = null,
    stream: ?ai.StreamFunction = null,
    dir: std.Io.Dir = .cwd(),
    allow_paths_outside_cwd: bool = true,
    public_event_capacity: usize = AgentSession.public_event_capacity_default,
};

fn resolveSessionOptions(services: *RuntimeServices, options: SessionOptionsInput) AgentSession.Options {
    services.diagnostic_count = 0;
    const model = resolveModel(services, options.model);
    return .{
        .cwd = services.cwd,
        .agent_dir = services.agent_dir,
        .current_date = options.current_date,
        .session_id = "",
        .timestamp = "",
        .model = model,
        .thinking_level = resolveThinkingLevel(services.settings_manager.current(), options.thinking_level),
        .compaction_settings = resolveCompactionSettings(services.settings_manager.current()),
        .retry_settings = resolveRetrySettings(services.settings_manager.current()),
        .stream = resolveStream(services, options.stream, model),
        .get_api_key = services.auth_manager.hook(),
        .task_runtime = services.task_runtime,
        .dir = options.dir,
        .environ = services.environ,
        .allow_paths_outside_cwd = options.allow_paths_outside_cwd,
        .public_event_capacity = options.public_event_capacity,
    };
}

fn resolveStream(services: *RuntimeServices, explicit: ?ai.StreamFunction, model: ai.Model) ?ai.StreamFunction {
    if (explicit) |stream| return stream;
    const provider = services.provider_registry.get(model.api) orelse {
        if (!std.mem.eql(u8, model.api, "unknown") and services.diagnostic_count < services.diagnostics.len) {
            services.diagnostics[services.diagnostic_count] = .{ .unresolved_stream = .{ .api = model.api } };
            services.diagnostic_count += 1;
        }
        return null;
    };
    return provider.stream_simple;
}

fn resolveModel(services: *RuntimeServices, explicit: ?ai.Model) ai.Model {
    if (explicit) |model| return model;
    const snapshot = services.settings_manager.current();
    const project = fileSettings(snapshot.project);
    const global = fileSettings(snapshot.global);
    const provider = project.default_provider orelse global.default_provider;
    const model_id = project.default_model orelse global.default_model;
    if (provider != null or model_id != null) {
        if (provider) |provider_name| if (model_id) |id| {
            if (findAvailableModel(services, provider_name, id)) |model| return model;
        };
        if (services.diagnostic_count < services.diagnostics.len) {
            services.diagnostics[services.diagnostic_count] = .{ .unresolved_model_setting = .{ .provider = provider, .model = model_id } };
            services.diagnostic_count += 1;
        }
    }
    return firstAvailableModel(services) orelse agent_mod.Agent.defaultModel();
}

fn findAvailableModel(services: *const RuntimeServices, provider: ai.Provider, model_id: []const u8) ?ai.Model {
    const model = ai.getModel(provider, model_id) orelse return null;
    return if (services.auth_manager.hasAuth(model.provider)) model else null;
}

fn firstAvailableModel(services: *const RuntimeServices) ?ai.Model {
    for (ai.getProviders()) |provider| {
        for (ai.getModels(provider)) |model| {
            if (services.auth_manager.hasAuth(model.provider)) return model;
        }
    }
    return null;
}

fn resolveThinkingLevel(snapshot: *const settings_mod.SettingsSnapshot, explicit: ?agent_mod.ThinkingLevel) agent_mod.ThinkingLevel {
    if (explicit) |level| return level;
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    if (project.default_thinking_level orelse global.default_thinking_level) |level_text| {
        if (parseThinkingLevel(level_text)) |level| return level;
    }
    return .off;
}

fn resolveCompactionSettings(snapshot: *const settings_mod.SettingsSnapshot) session_manager.CompactionSettings {
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    var settings: session_manager.CompactionSettings = .{};
    if (global.compaction) |compaction| {
        if (compaction.keep_recent_tokens) |tokens| settings.keep_recent_tokens = tokens;
        if (compaction.enabled) |enabled| settings.auto_enabled = enabled;
    }
    if (project.compaction) |compaction| {
        if (compaction.keep_recent_tokens) |tokens| settings.keep_recent_tokens = tokens;
        if (compaction.enabled) |enabled| settings.auto_enabled = enabled;
    }
    return settings;
}

fn resolveRetrySettings(snapshot: *const settings_mod.SettingsSnapshot) AgentSession.RetrySettings {
    const global = fileSettings(snapshot.global);
    const project = fileSettings(snapshot.project);
    var settings: AgentSession.RetrySettings = .{};
    if (global.retry) |retry| {
        if (retry.enabled) |enabled| settings.enabled = enabled;
        if (retry.max_retries) |attempts| settings.max_attempts = if (attempts > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(attempts);
    }
    if (project.retry) |retry| {
        if (retry.enabled) |enabled| settings.enabled = enabled;
        if (retry.max_retries) |attempts| settings.max_attempts = if (attempts > std.math.maxInt(u8)) std.math.maxInt(u8) else @intCast(attempts);
    }
    return settings;
}

fn fileSettings(file: settings_mod.SettingsFile) settings_mod.Settings {
    return switch (file) {
        .missing => .{},
        .loaded => |settings| settings.value,
    };
}

fn parseThinkingLevel(text: []const u8) ?agent_mod.ThinkingLevel {
    if (std.ascii.eqlIgnoreCase(text, "minimal")) return .minimal;
    if (std.ascii.eqlIgnoreCase(text, "low")) return .low;
    if (std.ascii.eqlIgnoreCase(text, "medium")) return .medium;
    if (std.ascii.eqlIgnoreCase(text, "high")) return .high;
    if (std.ascii.eqlIgnoreCase(text, "xhigh")) return .xhigh;
    if (std.ascii.eqlIgnoreCase(text, "off")) return .off;
    return null;
}

test "session runtime owns services session and bounded mailboxes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .command_capacity = 2,
        .event_capacity = 2,
    });
    defer session_runtime.deinit();

    try std.testing.expectEqual(@as(usize, 2), session_runtime.commands.capacity());
    try std.testing.expectEqual(@as(usize, 2), session_runtime.events.capacity());
    try std.testing.expectEqualStrings("session", session_runtime.session.manager.header.id);
}

fn initTestRuntime(tmp: *std.testing.TmpDir, task_runtime: *runtime.Runtime) !AgentSessionRuntimeHost {
    return initTestRuntimeWithCaps(tmp, task_runtime, 4, 64);
}

fn initTestRuntimeWithCaps(
    tmp: *std.testing.TmpDir,
    task_runtime: *runtime.Runtime,
    command_capacity: usize,
    event_capacity: usize,
) !AgentSessionRuntimeHost {
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    return createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .command_capacity = command_capacity,
        .event_capacity = event_capacity,
    });
}

test "session runtime drains submitted command into operation event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 1), event.request_id);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.queue_cleared, event.event.operation_finished.reason);
}

test "session runtime replays retained event envelopes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var original = session_runtime.drainEvent().?;
    const original_seq = original.seq;
    original.deinit(std.testing.allocator);

    try session_runtime.submit(.{ .id = 2, .command = .{ .replay = .{ .after = 0 } } });
    try session_runtime.step();
    var replay = session_runtime.drainEvent().?;
    defer replay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 2), replay.request_id);
    try std.testing.expect(replay.event == .replay);
    try std.testing.expectEqual(@as(usize, 1), replay.event.replay.events.len);
    try std.testing.expectEqual(original_seq, replay.event.replay.events[0].seq);
    try std.testing.expect(std.mem.indexOf(u8, replay.event.replay.events[0].json.text, "\"queue_cleared\"") != null);
}

test "session runtime reports replay gap after retained ledger eviction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var session_runtime = try createSessionRuntime(std.testing.allocator, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .current_date = "2026-06-09",
        .session_id = "session",
        .timestamp = "2026-06-09T00:00:00Z",
        .dir = tmp.dir,
        .task_runtime = task_runtime,
        .retained_event_capacity = 1,
    });
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var first = session_runtime.drainEvent().?;
    first.deinit(std.testing.allocator);
    try session_runtime.submit(.{ .id = 2, .command = .{ .queue = .clear } });
    try session_runtime.step();
    var second = session_runtime.drainEvent().?;
    second.deinit(std.testing.allocator);

    try session_runtime.submit(.{ .id = 3, .command = .{ .replay = .{ .after = 0 } } });
    try session_runtime.step();
    var gap = session_runtime.drainEvent().?;
    defer gap.deinit(std.testing.allocator);
    try std.testing.expect(gap.event == .replay_gap);
    try std.testing.expectEqual(@as(client_protocol.EventSeq, 0), gap.event.replay_gap.requested_after);
}

test "session runtime request snapshot emits owned bounded snapshot event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 9, .command = .{ .snapshot = .{} } });
    try session_runtime.step();

    var event = session_runtime.drainEvent().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 9), event.request_id);
    try std.testing.expect(event.event == .snapshot);
    try std.testing.expectEqualStrings("session", event.event.snapshot.header.id.text);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, null), event.event.snapshot.active_request_id);
    try std.testing.expectEqual(@as(usize, 0), event.event.snapshot.history.items.len);
}

test "session runtime does not consume commands while event queue is full" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntimeWithCaps(&tmp, task_runtime, 4, 1);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    try session_runtime.submit(.{ .id = 2, .command = .{ .snapshot = .{} } });
    try session_runtime.step();

    var first = session_runtime.drainEvent().?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 1), first.request_id);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.queue_cleared, first.event.operation_finished.reason);

    try session_runtime.step();
    var second = session_runtime.drainEvent().?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 2), second.request_id);
    try std.testing.expect(second.event == .snapshot);
}

test "session runtime shutdown remains observable under event pressure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntimeWithCaps(&tmp, task_runtime, 4, 1);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try session_runtime.step();
    try session_runtime.submit(.{ .id = 2, .command = .shutdown });
    try session_runtime.step();

    var first = session_runtime.drainEvent().?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(client_protocol.OperationFinished.Reason.queue_cleared, first.event.operation_finished.reason);

    try session_runtime.step();
    var second = session_runtime.drainEvent().?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?client_protocol.RequestId, 2), second.request_id);
    try std.testing.expect(second.event == .shutdown_started);
}

test "session runtime command queue full rejects submit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntimeWithCaps(&tmp, task_runtime, 1, 4);
    defer session_runtime.deinit();

    try session_runtime.submit(.{ .id = 1, .command = .{ .queue = .clear } });
    try std.testing.expectError(error.Full, session_runtime.submit(.{ .id = 2, .command = .{ .queue = .clear } }));
}

test "session runtime cancels targeted active operation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var prompt = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "first");
    var prompt_owned = true;
    defer if (prompt_owned) prompt.deinit(std.testing.allocator);
    try session_runtime.submit(prompt);
    prompt_owned = false;
    try session_runtime.step();

    const operation_id = session_runtime.active_operation_id.?;
    try session_runtime.submit(.{ .id = 2, .command = .{ .cancel = .{ .target = .{ .operation_id = operation_id } } } });
    try session_runtime.step();

    var found_canceled = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event == .operation_finished and
            owned.event.operation_finished.reason == .canceled and
            owned.operation_id == operation_id)
        {
            found_canceled = true;
        }
    }
    try std.testing.expect(found_canceled);
}

test "session runtime queues prompt while active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var task_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
    defer task_runtime.deinit();
    var session_runtime = try initTestRuntime(&tmp, task_runtime);
    defer session_runtime.deinit();

    var first = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 1, "first");
    var first_owned = true;
    defer if (first_owned) first.deinit(std.testing.allocator);
    try session_runtime.submit(first);
    first_owned = false;
    try session_runtime.step();
    try std.testing.expect(session_runtime.active_run != null);

    var second = try client_protocol.CommandEnvelope.initSubmitPrompt(std.testing.allocator, 2, "second");
    var second_owned = true;
    defer if (second_owned) second.deinit(std.testing.allocator);
    try session_runtime.submit(second);
    second_owned = false;
    try session_runtime.step();

    var found_queue = false;
    while (session_runtime.drainEvent()) |event| {
        var owned = event;
        defer owned.deinit(std.testing.allocator);
        if (owned.event == .queue_changed and owned.event.queue_changed.steering_count == 1) found_queue = true;
    }
    try std.testing.expect(found_queue);
}

test "retained ledger skips envelope that exceeds byte cap without allocating encoded size" {
    var message = try client_protocol.EventText.init(std.testing.allocator, "0123456789abcdef");
    defer message.deinit();
    const envelope: client_protocol.EventEnvelope = .{
        .seq = 1,
        .event = .{ .rejected = .{ .code = .invalid_command, .message = message } },
    };

    const encoded = try encodeEnvelopeJsonBounded(std.testing.allocator, envelope, 8);
    try std.testing.expect(encoded == null);
}

test "retained ledger terminal agent events do not carry message payloads" {
    var ledger = try RetainedEventLedger.init(std.testing.allocator, 4, 256);
    defer ledger.deinit();

    var agent_end = try client_protocol.OwnedAgentEvent.init(std.testing.allocator, .agent_end);
    defer agent_end.deinit();
    try ledger.append(.{ .seq = 1, .event = .{ .agent_event = agent_end } });

    var turn_end = try client_protocol.OwnedAgentEvent.init(std.testing.allocator, .turn_end);
    defer turn_end.deinit();
    try ledger.append(.{ .seq = 2, .event = .{ .agent_event = turn_end } });

    try std.testing.expectEqual(@as(usize, 2), ledger.count);
    for (0..ledger.count) |index| {
        const entry = ledger.entryAt(index);
        try std.testing.expect(entry.json.len < 128);
        try std.testing.expect(std.mem.indexOf(u8, entry.json, "\"message\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, entry.json, "assistantMessageEvent") == null);
    }
}

test "retained ledger oversized encode evicts through seq and accepts later events" {
    var ledger = try RetainedEventLedger.init(std.testing.allocator, 2, 128);
    defer ledger.deinit();

    try ledger.append(.{
        .seq = 1,
        .event = .{ .operation_finished = .{ .reason = .queue_cleared } },
    });

    var message = try client_protocol.EventText.init(std.testing.allocator, "x" ** 512);
    defer message.deinit();
    try ledger.append(.{
        .seq = 2,
        .event = .{ .rejected = .{ .code = .invalid_command, .message = message } },
    });

    try std.testing.expectEqual(@as(usize, 0), ledger.count);
    try std.testing.expectEqual(@as(client_protocol.EventSeq, 2), ledger.evicted_through_seq);
    try std.testing.expectEqual(@as(usize, 0), ledger.total_bytes);

    try ledger.append(.{
        .seq = 3,
        .event = .{ .operation_finished = .{ .reason = .completed } },
    });

    var gap = try ledger.buildReplay(std.testing.allocator, .{ .after = 1 });
    defer gap.deinit(std.testing.allocator);
    try std.testing.expect(gap.event == .replay_gap);
    try std.testing.expectEqual(@as(client_protocol.EventSeq, 1), gap.event.replay_gap.requested_after);

    var replay = try ledger.buildReplay(std.testing.allocator, .{ .after = 2 });
    defer replay.deinit(std.testing.allocator);
    try std.testing.expect(replay.event == .replay);
    try std.testing.expectEqual(@as(usize, 1), replay.event.replay.events.len);
    try std.testing.expectEqual(@as(client_protocol.EventSeq, 3), replay.event.replay.events[0].seq);
}
