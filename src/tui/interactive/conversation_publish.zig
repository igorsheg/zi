const std = @import("std");
const agent_mod = @import("../../agent/root.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");

const Interactive = @import("../interactive.zig").Interactive;
const AgentEvent = agent_mod.protocol.AgentEvent;
const ConversationSnapshotPublisher = coding_agent_mod.ConversationSnapshotPublisher;

const soft_conversation_publish_cadence_ns: u64 = 33 * std.time.ns_per_ms;

pub fn publishConversationState(self: *Interactive) bool {
    return self.runtime_host.publishConversationState(conversationSnapshotPublisher(self));
}

pub fn publishQueuedSnapshot(self: *Interactive) bool {
    return self.runtime_host.publishQueuedSnapshot(queuedSnapshotPublisher(self));
}

pub fn publishQueuedSnapshotIfChanged(self: *Interactive) void {
    const current_version = self.runtime_host.currentQueuedVersion();
    if (current_version == self.last_published_queued_version) return;
    if (publishQueuedSnapshot(self)) {
        self.last_published_queued_version = current_version;
    }
}

pub fn publishForAgentEvent(self: *Interactive, event: AgentEvent) void {
    switch (event) {
        .message_start => |payload| switch (payload.message) {
            .assistant => flushPendingConversationPublish(self),
            else => {},
        },
        .message_update, .tool_execution_update => {
            maybePublishSoftConversation(self);
        },
        .message_end, .tool_execution_start, .tool_execution_end, .agent_end => {
            flushPendingConversationPublish(self);
        },
        .turn_end => |payload| {
            if (payload.message != .assistant) return;
            flushPendingConversationPublish(self);
        },
        .agent_start, .turn_start => {},
    }
}

fn monotonicNowNs() u64 {
    return @intCast(@as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())));
}

fn flushPendingConversationPublish(self: *Interactive) void {
    const published = publishConversationState(self);
    publishQueuedSnapshotIfChanged(self);
    if (published) {
        self.last_conversation_publish_ns = monotonicNowNs();
        self.conversation_publish_dirty = false;
    }
}

fn maybePublishSoftConversation(self: *Interactive) void {
    self.conversation_publish_dirty = true;
    const now = monotonicNowNs();
    const elapsed = now -% self.last_conversation_publish_ns;
    if (elapsed < soft_conversation_publish_cadence_ns) return;
    const published = publishConversationState(self);
    if (!published) return;
    self.last_conversation_publish_ns = now;
    self.conversation_publish_dirty = false;
}

fn conversationSnapshotPublisher(self: *Interactive) ConversationSnapshotPublisher {
    return .{
        .func = &publishConversationSnapshotToUi,
        .ctx = @ptrCast(self),
    };
}

fn queuedSnapshotPublisher(self: *Interactive) coding_agent_mod.runtime_host.QueuedSnapshotPublisher {
    return .{
        .func = &publishQueuedSnapshotToUi,
        .ctx = @ptrCast(self),
    };
}

fn publishConversationSnapshotToUi(envelope: agent_mod.conversation_state.ConversationSnapshotEnvelope, ctx: ?*anyopaque) bool {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    return self.publishSnapshotUiEvent(.{ .conversation_snapshot = envelope });
}

fn publishQueuedSnapshotToUi(snapshot: coding_agent_mod.runtime_host.QueuedMessageSnapshot, ctx: ?*anyopaque) bool {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    return self.publishSnapshotUiEvent(.{ .queued_snapshot = snapshot });
}
