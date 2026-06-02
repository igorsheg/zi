const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const runtime = @import("../runtime/root.zig");
const message_policy = @import("message_policy.zig");
const queue_mirror_mod = @import("queue_mirror.zig");
const session_events = @import("session_events.zig");
const session_manager = @import("session_manager.zig");
const session_store = @import("session_store.zig");

pub const PublicEventQueue = runtime.BoundedQueue(session_events.AgentSessionEvent);

pub const EventDrain = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *session_manager.SessionManager,
    store: ?*session_store.SessionStore,
    queue_mirror: *queue_mirror_mod.QueueMirror,
    public_events: *PublicEventQueue,
    public_event_wake: runtime.ResetEvent = .init,
    timestamp: []const u8,
    context_overflow_count: usize = 0,
    pending_public_event_overflow_count: usize = 0,

    pub fn handle(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        try self.updateQueueMirror(event);
        self.emitPublicEvent(event);
        var persist_error: ?anyerror = null;
        self.persistEvent(event) catch |err| {
            persist_error = err;
        };
        self.handleTerminalPolicy(event);
        if (persist_error) |err| return err;
    }

    pub fn emitQueueUpdate(self: *EventDrain) !void {
        var steering = try session_events.EventTextList.init(self.allocator, self.queue_mirror.steering.items);
        errdefer steering.deinit();
        var follow_up = try session_events.EventTextList.init(self.allocator, self.queue_mirror.follow_up.items);
        errdefer follow_up.deinit();
        self.enqueuePublicEvent(.{ .queue_update = .{
            .steering = steering,
            .follow_up = follow_up,
            .revision = self.queue_mirror.revision,
        } });
    }

    pub fn enqueuePublicEvent(self: *EventDrain, event: session_events.AgentSessionEvent) void {
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
        if (!self.public_events.pushOrDrop(.{ .public_event_overflow = .{ .dropped_count = dropped_count } })) return;
        self.pending_public_event_overflow_count = 0;
        self.public_event_wake.set();
    }

    fn updateQueueMirror(self: *EventDrain, event: agent_mod.AgentEvent) !void {
        if (event != .message_start) return;
        if (event.message_start.message != .user) return;
        const text = message_policy.userText(event.message_start.message.user) orelse return;
        if (!self.queue_mirror.removeUserText(self.allocator, text)) return;
        try self.emitQueueUpdate();
    }

    fn emitPublicEvent(self: *EventDrain, event: agent_mod.AgentEvent) void {
        self.enqueuePublicEvent(.{ .agent_event = event });
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
