const std = @import("std");
const agent_mod = @import("../../agent/root.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");

const Interactive = @import("../interactive.zig").Interactive;
const AgentEvent = agent_mod.protocol.AgentEvent;
const ConversationSnapshotPublisher = coding_agent_mod.ConversationSnapshotPublisher;

const soft_conversation_publish_cadence_ns: u64 = 33 * std.time.ns_per_ms;

pub const Publisher = struct {
    runtime_host: *coding_agent_mod.RuntimeHost,
    publish_snapshot: *const fn (ctx: ?*anyopaque, event: UiSnapshot) bool,
    publish_ctx: ?*anyopaque,
    last_published_queued_version: *u64,

    pub const UiSnapshot = union(enum) {
        conversation: agent_mod.conversation_state.ConversationSnapshotEnvelope,
        queued: coding_agent_mod.runtime_host.QueuedMessageSnapshot,
    };
};

pub fn publisherForInteractive(self: *Interactive) Publisher {
    return .{
        .runtime_host = &self.runtime_host,
        .publish_snapshot = &publishSnapshotToInteractive,
        .publish_ctx = @ptrCast(self),
        .last_published_queued_version = &self.last_published_queued_version,
    };
}

pub fn publishConversationStateWithPublisher(publisher: Publisher) bool {
    var stable = publisher;
    return stable.runtime_host.publishConversationState(conversationSnapshotPublisher(&stable));
}

pub fn publishQueuedSnapshotWithPublisher(publisher: Publisher) bool {
    var stable = publisher;
    return stable.runtime_host.publishQueuedSnapshot(queuedSnapshotPublisher(&stable));
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

fn conversationSnapshotPublisher(publisher: *const Publisher) ConversationSnapshotPublisher {
    return .{
        .func = &publishConversationSnapshotToUi,
        .ctx = @ptrCast(@constCast(publisher)),
    };
}

fn queuedSnapshotPublisher(publisher: *const Publisher) coding_agent_mod.runtime_host.QueuedSnapshotPublisher {
    return .{
        .func = &publishQueuedSnapshotToUi,
        .ctx = @ptrCast(@constCast(publisher)),
    };
}

fn publishConversationSnapshotToUi(envelope: agent_mod.conversation_state.ConversationSnapshotEnvelope, ctx: ?*anyopaque) bool {
    const publisher: *const Publisher = @ptrCast(@alignCast(ctx.?));
    return publisher.publish_snapshot(publisher.publish_ctx, .{ .conversation = envelope });
}

fn publishQueuedSnapshotToUi(snapshot: coding_agent_mod.runtime_host.QueuedMessageSnapshot, ctx: ?*anyopaque) bool {
    const publisher: *const Publisher = @ptrCast(@alignCast(ctx.?));
    return publisher.publish_snapshot(publisher.publish_ctx, .{ .queued = snapshot });
}

fn publishSnapshotToInteractive(ctx: ?*anyopaque, event: Publisher.UiSnapshot) bool {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    return switch (event) {
        .conversation => |snapshot| self.publishSnapshotUiEvent(.{ .conversation_snapshot = snapshot }),
        .queued => |snapshot| self.publishSnapshotUiEvent(.{ .queued_snapshot = snapshot }),
    };
}
