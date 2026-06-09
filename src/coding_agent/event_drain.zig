const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const runtime = @import("../runtime/root.zig");
const message_policy = @import("message_policy.zig");
const queue_mirror_mod = @import("queue_mirror.zig");
const client_protocol = @import("client_protocol.zig");
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");

pub const PublicEventQueue = runtime.BoundedQueue(client_protocol.ClientEvent);

pub const EventDrain = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *session_manager.SessionManager,
    store: ?*session_store.SessionStore,
    public_event_buffer: []client_protocol.ClientEvent,
    public_events: PublicEventQueue,
    queue_mirror: queue_mirror_mod.QueueMirror = .{},
    public_event_wake: runtime.ResetEvent = .init,
    timestamp: []const u8,
    context_overflow_count: usize = 0,
    pending_public_event_overflow_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *session_manager.SessionManager,
        store: ?*session_store.SessionStore,
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
        try self.updateQueueMirror(event);
        try self.emitPublicEvent(event);
        var persist_error: ?anyerror = null;
        self.persistEvent(event) catch |err| {
            persist_error = err;
        };
        self.handleTerminalPolicy(event);
        if (persist_error) |err| return err;
    }

    pub fn emitQueueUpdate(self: *EventDrain) !void {
        self.enqueuePublicEvent(.{ .queue_changed = .{
            .steering_count = self.queue_mirror.steering.items.len,
            .follow_up_count = self.queue_mirror.follow_up.items.len,
            .revision = self.queue_mirror.revision,
        } });
    }

    pub fn enqueuePublicEvent(self: *EventDrain, event: client_protocol.ClientEvent) void {
        var owned_event = event;
        if (!self.public_events.pushOrDrop(owned_event)) {
            owned_event.deinit();
            std.debug.assert(self.pending_public_event_overflow_count < std.math.maxInt(usize));
            self.pending_public_event_overflow_count += 1;
        }
        self.public_event_wake.set();
    }

    pub fn enqueuePendingPublicEventOverflow(self: *EventDrain) void {
        if (self.pending_public_event_overflow_count == 0) return;
        const dropped_count = self.pending_public_event_overflow_count;
        if (!self.public_events.pushOrDrop(.{ .event_overflow = .{ .dropped_count = dropped_count } })) return;
        self.pending_public_event_overflow_count = 0;
        self.public_event_wake.set();
    }

    pub fn queueSnapshot(self: *const EventDrain, allocator: std.mem.Allocator) !client_protocol.QueueSnapshot {
        return self.queue_mirror.snapshot(allocator);
    }

    pub fn clearQueueMirror(self: *EventDrain) !void {
        if (self.queue_mirror.clear(self.allocator)) try self.emitQueueUpdate();
    }

    pub fn drainPublicEvent(self: *EventDrain) ?client_protocol.ClientEvent {
        const event = self.public_events.pop() orelse return null;
        self.enqueuePendingPublicEventOverflow();
        return event;
    }

    pub fn publicEventWake(self: *EventDrain) *runtime.ResetEvent {
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

    fn updateQueueMirror(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .message_start) return;
        if (event.message_start.message != .user) return;
        const text = message_policy.userText(event.message_start.message.user) orelse return;
        if (!self.queue_mirror.removeUserText(self.allocator, text)) return;
        try self.emitQueueUpdate();
    }

    fn emitPublicEvent(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        self.enqueuePublicEvent(.{ .agent_event = try client_protocol.OwnedAgentEvent.init(self.allocator, event) });
    }

    fn persistEvent(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .message_end) return;
        try self.manager.ensureAppendCapacity(1);
        const entry = try self.manager.prepareMessageEntry(event.message_end.message, self.timestamp);
        errdefer self.manager.deinitPreparedEntry(entry);
        if (self.store) |store| try store.appendEntry(self.allocator, self.io, entry);
        _ = self.manager.commitPreparedEntry(entry);
    }

    fn handleTerminalPolicy(self: *EventDrain, event: agent_mod.AgentEvent) void {
        switch (event) {
            .message_end => |payload| {
                if (payload.message == .assistant and
                    message_policy.isContextOverflowAssistant(payload.message.assistant))
                {
                    self.context_overflow_count += 1;
                }
            },
            else => {},
        }
    }
};
