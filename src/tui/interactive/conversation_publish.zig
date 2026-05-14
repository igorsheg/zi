const std = @import("std");
const agent_mod = @import("../../agent/root.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");
const deadline = @import("../../zio/root.zig").deadline;

const Interactive = @import("../interactive.zig").Interactive;
const AgentEvent = agent_mod.protocol.AgentEvent;
const SyncSnapshotSink = coding_agent_mod.SyncSnapshotSink;

const soft_conversation_publish_cadence_ns: u64 = 33 * std.time.ns_per_ms;

pub const Publisher = struct {
    runtime_host: *coding_agent_mod.RuntimeHost,
    publish_conversation: *const fn (ctx: ?*anyopaque, envelope: agent_mod.conversation_state.ConversationSnapshotEnvelope) bool,
    publish_queued: *const fn (ctx: ?*anyopaque, snapshot: coding_agent_mod.runtime_host.QueuedMessageSnapshot) bool,
    publish_ctx: ?*anyopaque,
    last_published_queued_version: *u64,
};

pub fn publisherForInteractive(self: *Interactive) Publisher {
    return .{
        .runtime_host = &self.runtime_host,
        .publish_conversation = &publishConversationSnapshotToInteractive,
        .publish_queued = &publishQueuedSnapshotToInteractive,
        .publish_ctx = @ptrCast(self),
        .last_published_queued_version = &self.last_published_queued_version,
    };
}

pub fn publishConversationStateWithPublisher(publisher: Publisher) bool {
    return publisher.runtime_host.publishConversationState(snapshotSink(publisher));
}

pub fn publishQueuedSnapshotWithPublisher(publisher: Publisher) bool {
    return publisher.runtime_host.publishQueuedSnapshot(snapshotSink(publisher));
}

pub fn publishQueuedSnapshotIfChangedWithPublisher(publisher: Publisher) void {
    const current_version = publisher.runtime_host.currentQueuedVersion();
    if (current_version == publisher.last_published_queued_version.*) return;
    if (publishQueuedSnapshotWithPublisher(publisher)) {
        publisher.last_published_queued_version.* = current_version;
    }
}

pub fn publishConversationState(self: *Interactive) bool {
    return publishConversationStateWithPublisher(publisherForInteractive(self));
}

pub fn publishQueuedSnapshot(self: *Interactive) bool {
    return publishQueuedSnapshotWithPublisher(publisherForInteractive(self));
}

pub fn publishQueuedSnapshotIfChanged(self: *Interactive) void {
    publishQueuedSnapshotIfChangedWithPublisher(publisherForInteractive(self));
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
    return @intCast(deadline.nowNs(std.Options.debug_io));
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

fn snapshotSink(publisher: Publisher) SyncSnapshotSink {
    return .{
        .ctx = publisher.publish_ctx,
        .publish_conversation = publisher.publish_conversation,
        .publish_queued = publisher.publish_queued,
    };
}

fn publishConversationSnapshotToInteractive(ctx: ?*anyopaque, envelope: agent_mod.conversation_state.ConversationSnapshotEnvelope) bool {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    return self.publishSnapshotUiEvent(.{ .conversation_snapshot = envelope });
}

fn publishQueuedSnapshotToInteractive(ctx: ?*anyopaque, snapshot: coding_agent_mod.runtime_host.QueuedMessageSnapshot) bool {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    return self.publishSnapshotUiEvent(.{ .queued_snapshot = snapshot });
}
