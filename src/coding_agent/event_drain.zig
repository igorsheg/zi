//! The single writer for session state derived from agent events. Order per
//! event is fixed: queue mirror -> sink -> persistence -> terminal policy. A
//! persistence failure is reported to the caller after terminal policy still
//! runs; the host converts it into a failed operation.

const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const message_policy = @import("message_policy.zig");
const queue_mirror_mod = @import("queue_mirror.zig");
const client_protocol = @import("client_protocol.zig");
const engine_drain = @import("engine_drain.zig");
const session_manager = @import("session_manager.zig");

pub const PublicEventQueue = runtime.BoundedQueue(client_protocol.ClientEvent);

pub const Sink = union(enum) {
    client_events,
    view_model: *engine_drain.EngineDrain,
};

const QueuedEcho = struct {
    id: u64,
    kind: Kind,
    text: []u8,

    const Kind = enum { steering, follow_up };
};

pub const EventDrain = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *session_manager.SessionManager,
    store: ?*session_manager.SessionStore,
    public_event_buffer: []client_protocol.ClientEvent,
    public_events: PublicEventQueue,
    sink: Sink = .client_events,
    queue_mirror: queue_mirror_mod.QueueMirror = .{},
    queued_echoes: std.ArrayList(QueuedEcho) = .empty,
    next_queue_id: u64 = 1,
    public_event_wake: runtime.WakeEvent = .init,
    context_overflow_count: usize = 0,
    pending_public_event_overflow_count: usize = 0,
    retry_attempt: u8 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        store: ?*session_manager.SessionStore,
        public_event_capacity: usize,
    ) !EventDrain {
        return initWithSink(allocator, io, manager, store, public_event_capacity, .client_events);
    }

    pub fn initWithSink(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        store: ?*session_manager.SessionStore,
        public_event_capacity: usize,
        sink: Sink,
    ) !EventDrain {
        if (public_event_capacity == 0) return error.PublicEventCapacityZero;
        const buffer = try allocator.alloc(client_protocol.ClientEvent, public_event_capacity);
        return .{
            .allocator = allocator,
            .io = io,
            .manager = manager,
            .store = store,
            .public_event_buffer = buffer,
            .public_events = PublicEventQueue.init(buffer),
            .sink = sink,
        };
    }

    pub fn deinit(self: *EventDrain) void {
        for (self.queued_echoes.items) |entry| self.allocator.free(entry.text);
        self.queued_echoes.deinit(self.allocator);
        self.queue_mirror.deinit(self.allocator);
        self.allocator.free(self.public_event_buffer);
        self.* = undefined;
    }

    pub fn handle(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event == .message_start and event.message_start.message == .user) {
            if (message_policy.userText(event.message_start.message.user)) |text| {
                if (self.removeQueuedTextInternal(text)) self.emitQueueUpdate();
            }
        }

        try self.emitAgentEvent(event);

        var persist_error: ?anyerror = null;
        if (event == .message_end) {
            const entry_id = self.persistMessage(event.message_end.message) catch |err| blk: {
                persist_error = err;
                break :blk null;
            };
            if (entry_id) |id| try self.emitMessageCommitted(id, event.message_end.message);
        }

        if (event == .message_end and event.message_end.message == .assistant) {
            const assistant = event.message_end.message.assistant;
            if (message_policy.isContextOverflowAssistant(assistant, assistantContextWindow(assistant))) {
                self.context_overflow_count += 1;
            }
            if (assistant.stop_reason != .error_ and self.retry_attempt > 0) {
                const attempt = self.retry_attempt;
                self.retry_attempt = 0;
                self.emitRetryEnd(true, attempt, null, null);
            }
        }
        if (persist_error) |err| return err;
    }

    pub fn beginRetryAttempt(self: *EventDrain) u8 {
        std.debug.assert(self.retry_attempt < std.math.maxInt(u8));
        self.retry_attempt += 1;
        return self.retry_attempt;
    }

    pub fn failRetry(self: *EventDrain, error_text: []const u8, failure: ?ai.OperationalFailure) void {
        if (self.retry_attempt == 0) return;
        const attempt = self.retry_attempt;
        self.retry_attempt = 0;
        switch (self.sink) {
            .client_events => {
                const final_error = client_protocol.EventText.init(self.allocator, error_text) catch null;
                const owned_failure = if (failure) |value|
                    client_protocol.OperationalFailure.init(self.allocator, value) catch null
                else
                    null;
                self.enqueuePublicEvent(.{ .auto_retry_end = .{
                    .success = false,
                    .attempt = attempt,
                    .final_error = final_error,
                    .failure = owned_failure,
                } });
            },
            .view_model => |sink| sink.retryEnd(false, attempt, error_text, failure),
        }
    }

    fn assistantContextWindow(message: ai.AssistantMessage) u64 {
        if (ai.getModel(message.provider, message.model)) |model| return model.context_window;
        return 0;
    }

    fn persistMessage(self: *EventDrain, message: agent_mod.AgentMessage) !?[]const u8 {
        const timestamp = session_manager.timestampNow(self.io);
        const entry = try self.manager.prepareMessageEntry(message, &timestamp);
        errdefer self.manager.deinitPreparedEntry(entry);
        if (self.store) |store| try store.appendEntry(self.io, entry, self.manager.lastEntryId());
        return self.manager.commitPreparedEntry(entry);
    }

    fn emitAgentEvent(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        switch (self.sink) {
            .client_events => self.enqueuePublicEvent(.{ .agent_event = try client_protocol.OwnedAgentEvent.init(self.allocator, event) }),
            .view_model => |sink| try sink.agentEvent(event),
        }
    }

    fn emitMessageCommitted(self: *EventDrain, entry_id: []const u8, message: agent_mod.AgentMessage) !void {
        switch (self.sink) {
            .client_events => self.enqueuePublicEvent(.{
                .message_committed = try client_protocol.MessageCommitted.init(self.allocator, entry_id, message),
            }),
            .view_model => |sink| sink.messageCommitted(entry_id, message),
        }
    }

    fn emitRetryEnd(self: *EventDrain, success: bool, attempt: u8, final_error: ?[]const u8, failure: ?ai.OperationalFailure) void {
        switch (self.sink) {
            .client_events => {
                const final = if (final_error) |text| client_protocol.EventText.init(self.allocator, text) catch null else null;
                const owned_failure = if (failure) |value| client_protocol.OperationalFailure.init(self.allocator, value) catch null else null;
                self.enqueuePublicEvent(.{ .auto_retry_end = .{
                    .success = success,
                    .attempt = attempt,
                    .final_error = final,
                    .failure = owned_failure,
                } });
            },
            .view_model => |sink| sink.retryEnd(success, attempt, final_error, failure),
        }
    }

    pub fn emitQueueUpdate(self: *EventDrain) void {
        switch (self.sink) {
            .client_events => self.enqueuePublicEvent(.{ .queue_changed = self.queue_mirror.changed() }),
            .view_model => {},
        }
    }

    pub fn enqueuePublicEvent(self: *EventDrain, event: client_protocol.ClientEvent) void {
        switch (self.sink) {
            .client_events => self.enqueueClientEvent(event),
            .view_model => |sink| self.routeClientFactToViewSink(sink, event),
        }
    }

    fn enqueueClientEvent(self: *EventDrain, event: client_protocol.ClientEvent) void {
        var owned_event = event;
        if (!self.public_events.pushOrDrop(owned_event)) {
            owned_event.deinit(self.allocator);
            std.debug.assert(self.pending_public_event_overflow_count < std.math.maxInt(usize));
            self.pending_public_event_overflow_count += 1;
        }
        self.public_event_wake.set(self.io);
    }

    fn routeClientFactToViewSink(self: *EventDrain, sink: *engine_drain.EngineDrain, event: client_protocol.ClientEvent) void {
        switch (event) {
            .compaction_start => |start| sink.compactionStart(start.reason),
            .compaction_end => |end| sink.compactionEnd(end.aborted, if (end.error_message) |msg| msg.text else null),
            .auto_retry_start => |retry| sink.retryStart(retry.attempt, retry.delay_ms, retry.error_message.text, if (retry.failure) |f| f.category else null),
            .auto_retry_end => |retry| sink.retryEnd(retry.success, @intCast(retry.attempt), if (retry.final_error) |err| err.text else null, null),
            .rejected => |rejection| sink.notice(.warn, .operation_failed, rejection.message.text),
            .event_overflow => sink.notice(.warn, .notices_dropped, "events were dropped"),
            .prompt_command => |command| sink.notice(if (command.result == .failed) .warn else .info, .generic, command.message.text),
            .agent_event, .message_committed => {},
            .operation_started,
            .operation_finished,
            .shutdown_started,
            .queue_changed,
            .snapshot,
            .completion_snapshot,
            .file_completion,
            .replay,
            .replay_gap,
            .history_page,
            .session_changed,
            .session_chrome,
            => {},
        }
        var owned = event;
        owned.deinit(self.allocator);
    }

    pub fn queueSnapshot(self: *const EventDrain, allocator: std.mem.Allocator) !client_protocol.QueueSnapshot {
        return self.queue_mirror.snapshot(allocator);
    }

    pub fn appendSteering(self: *EventDrain, text: []const u8) !void {
        try self.appendQueueEcho(text, .steering);
    }

    pub fn appendFollowUp(self: *EventDrain, text: []const u8) !void {
        try self.appendQueueEcho(text, .follow_up);
    }

    fn appendQueueEcho(self: *EventDrain, text: []const u8, kind: QueuedEcho.Kind) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        switch (kind) {
            .steering => try self.queue_mirror.appendSteering(self.allocator, text),
            .follow_up => try self.queue_mirror.appendFollowUp(self.allocator, text),
        }
        errdefer _ = self.queue_mirror.removeUserText(self.allocator, text);
        const id = self.next_queue_id;
        self.next_queue_id +%= 1;
        try self.queued_echoes.append(self.allocator, .{ .id = id, .kind = kind, .text = owned });
        switch (self.sink) {
            .client_events => {},
            .view_model => |sink| sink.queueAdd(id, kind, text),
        }
    }

    pub fn removeQueuedText(self: *EventDrain, text: []const u8) void {
        _ = self.removeQueuedTextInternal(text);
    }

    fn removeQueuedTextInternal(self: *EventDrain, text: []const u8) bool {
        const mirror_removed = self.queue_mirror.removeUserText(self.allocator, text);
        var index: usize = 0;
        while (index < self.queued_echoes.items.len) : (index += 1) {
            if (!std.mem.eql(u8, self.queued_echoes.items[index].text, text)) continue;
            const entry = self.queued_echoes.orderedRemove(index);
            switch (self.sink) {
                .client_events => {},
                .view_model => |sink| sink.queueRemove(entry.id),
            }
            self.allocator.free(entry.text);
            return true;
        }
        return mirror_removed;
    }

    pub fn clearQueueMirror(self: *EventDrain) void {
        _ = self.queue_mirror.clear(self.allocator);
        switch (self.sink) {
            .client_events => {},
            .view_model => |sink| sink.queueClear(),
        }
        for (self.queued_echoes.items) |entry| self.allocator.free(entry.text);
        self.queued_echoes.clearRetainingCapacity();
        self.emitQueueUpdate();
    }

    pub fn drainPublicEvent(self: *EventDrain) ?client_protocol.ClientEvent {
        const event = self.public_events.pop() orelse return null;
        if (self.pending_public_event_overflow_count > 0) {
            const dropped_count = self.pending_public_event_overflow_count;
            if (self.public_events.pushOrDrop(.{ .event_overflow = .{ .dropped_count = dropped_count } })) {
                self.pending_public_event_overflow_count = 0;
                self.public_event_wake.set(self.io);
            }
        }
        return event;
    }

    pub fn publicEventWake(self: *EventDrain) *runtime.WakeEvent {
        return &self.public_event_wake;
    }

    pub fn publicEventCount(self: *const EventDrain) usize {
        return self.public_events.count();
    }

    pub fn droppedPublicEventCount(self: *const EventDrain) usize {
        return self.public_events.dropped();
    }

    pub fn publicEventsEmpty(self: *const EventDrain) bool {
        return switch (self.sink) {
            .client_events => self.public_events.empty(),
            .view_model => true,
        };
    }
};
