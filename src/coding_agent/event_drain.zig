//! Engine-owned drain from agent events into the ViewModel plus durable jsonl.

const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const message_policy = @import("message_policy.zig");
const client_protocol = @import("client_protocol.zig");
const engine_drain = @import("engine_drain.zig");
const session_manager = @import("session_manager.zig");

pub const Sink = ?*engine_drain.EngineDrain;

pub const PublicEventQueue = runtime.BoundedQueue(client_protocol.ClientEvent);

const DummyQueueMirror = struct {
    steering_count: usize = 0,
    follow_up_count: usize = 0,
    revision: u64 = 0,

    pub fn changed(self: *const DummyQueueMirror) client_protocol.QueueChanged {
        return .{ .steering_count = self.steering_count, .follow_up_count = self.follow_up_count, .revision = self.revision };
    }
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
    sink: Sink,
    public_event_buffer: []client_protocol.ClientEvent,
    public_events: PublicEventQueue,
    queue_mirror: DummyQueueMirror = .{},
    public_event_wake: runtime.WakeEvent = .init,
    pending_public_event_overflow_count: usize = 0,
    queued_echoes: std.ArrayList(QueuedEcho) = .empty,
    next_queue_id: u64 = 1,
    context_overflow_count: usize = 0,
    retry_attempt: u8 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        store: ?*session_manager.SessionStore,
        public_event_capacity: usize,
    ) !EventDrain {
        return initWithSink(allocator, io, manager, store, public_event_capacity, null);
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
            .sink = sink,
            .public_event_buffer = buffer,
            .public_events = PublicEventQueue.init(buffer),
        };
    }

    pub fn deinit(self: *EventDrain) void {
        for (self.queued_echoes.items) |entry| self.allocator.free(entry.text);
        self.queued_echoes.deinit(self.allocator);
        while (self.public_events.pop()) |event| {
            var owned = event;
            owned.deinit(self.allocator);
        }
        self.allocator.free(self.public_event_buffer);
        self.* = undefined;
    }

    pub fn handle(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event == .message_start and event.message_start.message == .user) {
            if (message_policy.userText(event.message_start.message.user)) |text| {
                _ = self.removeQueuedTextInternal(text);
            }
        }

        if (self.sink) |sink| {
            try sink.agentEvent(event);
        } else {
            self.enqueuePublicEvent(.{ .agent_event = try client_protocol.OwnedAgentEvent.init(self.allocator, event) });
        }

        var persist_error: ?anyerror = null;
        if (event == .message_end) {
            const entry_id = self.persistMessage(event.message_end.message) catch |err| blk: {
                persist_error = err;
                break :blk null;
            };
            if (entry_id) |id| {
                if (self.sink) |sink| {
                    sink.messageCommitted(id, event.message_end.message);
                } else {
                    self.enqueuePublicEvent(.{
                        .message_committed = try client_protocol.MessageCommitted.init(self.allocator, id, event.message_end.message),
                    });
                }
            }
        }

        if (event == .message_end and event.message_end.message == .assistant) {
            const assistant = event.message_end.message.assistant;
            if (message_policy.isContextOverflowAssistant(assistant, assistantContextWindow(assistant))) {
                self.context_overflow_count += 1;
            }
            if (assistant.stop_reason != .error_ and self.retry_attempt > 0) {
                const attempt = self.retry_attempt;
                self.retry_attempt = 0;
                if (self.sink) |sink| {
                    sink.retryEnd(true, attempt, null, null);
                } else {
                    self.enqueuePublicEvent(.{ .auto_retry_end = .{ .success = true, .attempt = attempt } });
                }
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
        if (self.sink) |sink| {
            sink.retryEnd(false, attempt, error_text, failure);
        } else {
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

    pub fn emitQueueUpdate(self: *EventDrain) void {
        self.enqueuePublicEvent(.{ .queue_changed = self.queue_mirror.changed() });
    }

    pub fn enqueuePublicEvent(self: *EventDrain, event: client_protocol.ClientEvent) void {
        if (self.sink) |sink| {
            routeClientFactToViewSink(self.allocator, sink, event);
        } else {
            self.enqueueClientEvent(event);
        }
    }

    fn enqueueClientEvent(self: *EventDrain, event: client_protocol.ClientEvent) void {
        var owned_event = event;
        if (!self.public_events.pushOrDrop(owned_event)) {
            owned_event.deinit(self.allocator);
            self.pending_public_event_overflow_count += 1;
        }
        self.public_event_wake.set(self.io);
    }

    fn routeClientFactToViewSink(
        allocator: std.mem.Allocator,
        sink: *engine_drain.EngineDrain,
        event: client_protocol.ClientEvent,
    ) void {
        switch (event) {
            .compaction_start => |start| sink.compactionStart(start.reason),
            .compaction_end => |end| sink.compactionEnd(end.aborted, if (end.error_message) |msg| msg.text else null),
            .auto_retry_start => |retry| sink.retryStart(
                retry.attempt,
                retry.delay_ms,
                retry.error_message.text,
                if (retry.failure) |failure| failure.category else null,
            ),
            .auto_retry_end => |retry| sink.retryEnd(
                retry.success,
                @intCast(retry.attempt),
                if (retry.final_error) |err| err.text else null,
                null,
            ),
            .rejected => |rejection| sink.notice(.warn, .operation_failed, rejection.message.text),
            .event_overflow => sink.notice(.warn, .notices_dropped, "events were dropped"),
            .prompt_command => |command| sink.notice(
                if (command.result == .failed) .warn else .info,
                .generic,
                command.message.text,
            ),
            else => {},
        }
        var owned = event;
        owned.deinit(allocator);
    }

    pub fn queueSnapshot(self: *const EventDrain, allocator: std.mem.Allocator) !client_protocol.QueueSnapshot {
        _ = self;
        return .{
            .revision = 0,
            .steering = try client_protocol.EventTextList.init(allocator, &.{}),
            .follow_up = try client_protocol.EventTextList.init(allocator, &.{}),
        };
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
            .steering => self.queue_mirror.steering_count += 1,
            .follow_up => self.queue_mirror.follow_up_count += 1,
        }
        self.queue_mirror.revision += 1;
        const id = self.next_queue_id;
        self.next_queue_id +%= 1;
        try self.queued_echoes.append(self.allocator, .{ .id = id, .kind = kind, .text = owned });
        if (self.sink) |sink| sink.queueAdd(id, kind, text);
    }

    pub fn removeQueuedText(self: *EventDrain, text: []const u8) void {
        _ = self.removeQueuedTextInternal(text);
    }

    fn removeQueuedTextInternal(self: *EventDrain, text: []const u8) bool {
        var index: usize = 0;
        while (index < self.queued_echoes.items.len) : (index += 1) {
            if (!std.mem.eql(u8, self.queued_echoes.items[index].text, text)) continue;
            const entry = self.queued_echoes.orderedRemove(index);
            if (self.sink) |sink| sink.queueRemove(entry.id);
            switch (entry.kind) {
                .steering => self.queue_mirror.steering_count -|= 1,
                .follow_up => self.queue_mirror.follow_up_count -|= 1,
            }
            self.queue_mirror.revision += 1;
            self.allocator.free(entry.text);
            return true;
        }
        return false;
    }

    pub fn clearQueueMirror(self: *EventDrain) void {
        if (self.sink) |sink| sink.queueClear();
        for (self.queued_echoes.items) |entry| self.allocator.free(entry.text);
        self.queued_echoes.clearRetainingCapacity();
        self.queue_mirror.steering_count = 0;
        self.queue_mirror.follow_up_count = 0;
        self.queue_mirror.revision += 1;
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
        return self.public_events.empty();
    }
};
