//! The single writer for session state derived from agent events. Order per
//! event is fixed: queue mirror -> public event -> persistence -> terminal
//! policy. A persistence failure is reported to the caller after the terminal
//! policy has still run; the host converts it into a failed operation.

const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const message_policy = @import("message_policy.zig");
const queue_mirror_mod = @import("queue_mirror.zig");
const client_protocol = @import("client_protocol.zig");
const session_manager = @import("session_manager.zig");

pub const PublicEventQueue = runtime.BoundedQueue(client_protocol.ClientEvent);

pub const EventDrain = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *session_manager.SessionManager,
    store: ?*session_manager.SessionStore,
    public_event_buffer: []client_protocol.ClientEvent,
    public_events: PublicEventQueue,
    queue_mirror: queue_mirror_mod.QueueMirror = .{},
    public_event_wake: runtime.WakeEvent = .init,
    timestamp: []const u8,
    context_overflow_count: usize = 0,
    pending_public_event_overflow_count: usize = 0,
    /// Auto-retry attempt counter. The drain owns it so the success path is
    /// observed at the one place every event passes: the first non-error
    /// assistant message settles an in-flight retry mid-turn.
    retry_attempt: u8 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        store: ?*session_manager.SessionStore,
        timestamp: []const u8,
        public_event_capacity: usize,
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
            .timestamp = timestamp,
        };
    }

    pub fn deinit(self: *EventDrain) void {
        self.queue_mirror.deinit(self.allocator);
        self.allocator.free(self.public_event_buffer);
        self.* = undefined;
    }

    pub fn handle(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        // Queue mirror: a delivered user message leaves the mirrored queue.
        if (event == .message_start and event.message_start.message == .user) {
            if (message_policy.userText(event.message_start.message.user)) |text| {
                if (self.queue_mirror.removeUserText(self.allocator, text)) self.emitQueueUpdate();
            }
        }

        self.enqueuePublicEvent(.{ .agent_event = try client_protocol.OwnedAgentEvent.init(self.allocator, event) });

        // Persist message_end durably before it can be dropped from any
        // window; terminal policy still runs when persistence fails.
        var persist_error: ?anyerror = null;
        if (event == .message_end) {
            self.persistMessage(event.message_end.message) catch |err| {
                persist_error = err;
            };
        }

        if (event == .message_end and event.message_end.message == .assistant) {
            const assistant = event.message_end.message.assistant;
            if (message_policy.isContextOverflowAssistant(assistant)) {
                self.context_overflow_count += 1;
            }
            if (assistant.stop_reason != .error_ and self.retry_attempt > 0) {
                const attempt = self.retry_attempt;
                self.retry_attempt = 0;
                self.enqueuePublicEvent(.{ .auto_retry_end = .{ .success = true, .attempt = attempt } });
            }
        }
        if (persist_error) |err| return err;
    }

    /// Begin one auto-retry attempt; returns the 1-based attempt number.
    pub fn beginRetryAttempt(self: *EventDrain) u8 {
        std.debug.assert(self.retry_attempt < std.math.maxInt(u8));
        self.retry_attempt += 1;
        return self.retry_attempt;
    }

    /// Settle an in-flight retry as failed and report the terminal error.
    /// No-op when no retry is in flight.
    pub fn failRetry(self: *EventDrain, error_text: []const u8, failure: ?ai.OperationalFailure) void {
        if (self.retry_attempt == 0) return;
        const attempt = self.retry_attempt;
        self.retry_attempt = 0;
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

    fn persistMessage(self: *EventDrain, message: agent_mod.AgentMessage) !void {
        const entry = try self.manager.prepareMessageEntry(message, self.timestamp);
        errdefer self.manager.deinitPreparedEntry(entry);
        if (self.store) |store| {
            try store.appendEntry(self.io, entry, self.manager.lastEntryId());
        }
        _ = self.manager.commitPreparedEntry(entry);
    }

    pub fn emitQueueUpdate(self: *EventDrain) void {
        self.enqueuePublicEvent(.{ .queue_changed = self.queue_mirror.changed() });
    }

    pub fn enqueuePublicEvent(self: *EventDrain, event: client_protocol.ClientEvent) void {
        var owned_event = event;
        if (!self.public_events.pushOrDrop(owned_event)) {
            owned_event.deinit(self.allocator);
            std.debug.assert(self.pending_public_event_overflow_count < std.math.maxInt(usize));
            self.pending_public_event_overflow_count += 1;
        }
        self.public_event_wake.set(self.io);
    }

    pub fn queueSnapshot(self: *const EventDrain, allocator: std.mem.Allocator) !client_protocol.QueueSnapshot {
        return self.queue_mirror.snapshot(allocator);
    }

    pub fn appendSteering(self: *EventDrain, text: []const u8) !void {
        try self.queue_mirror.appendSteering(self.allocator, text);
    }

    pub fn appendFollowUp(self: *EventDrain, text: []const u8) !void {
        try self.queue_mirror.appendFollowUp(self.allocator, text);
    }

    pub fn removeQueuedText(self: *EventDrain, text: []const u8) void {
        _ = self.queue_mirror.removeUserText(self.allocator, text);
    }

    /// Always emits queue_changed, even when the queue was already empty:
    /// the clear command's only reply is this state fact, so it must be
    /// unconditional for request correlation.
    pub fn clearQueueMirror(self: *EventDrain) void {
        _ = self.queue_mirror.clear(self.allocator);
        self.emitQueueUpdate();
    }

    pub fn drainPublicEvent(self: *EventDrain) ?client_protocol.ClientEvent {
        const event = self.public_events.pop() orelse return null;
        // A drained slot makes room for the deferred overflow report.
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
