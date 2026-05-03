const std = @import("std");
const ui_event_mod = @import("../ui_event.zig");

const Interactive = @import("../interactive.zig").Interactive;
const UiEvent = ui_event_mod.UiEvent;
const log = std.log.scoped(.tui_interactive);

pub fn drain(self: *Interactive) void {
    drainQueue(self, &self.snapshot_event_queue);
    drainQueue(self, &self.lifecycle_event_queue);
}

pub fn publish(self: *Interactive, event: UiEvent) bool {
    return if (event.isSnapshotEvent())
        publishSnapshot(self, event)
    else
        publishLifecycle(self, event);
}

pub fn publishSnapshot(self: *Interactive, event: UiEvent) bool {
    coalescePendingSnapshot(self, event);
    switch (self.snapshot_event_queue.trySend(event)) {
        .ok => return true,
        .dropped => return false,
        .closed, .full, .oom => |rejected| {
            var failed = rejected;
            failed.deinit(self.msg_allocator);
            return false;
        },
    }
}

pub fn publishLifecycle(self: *Interactive, event: UiEvent) bool {
    switch (self.lifecycle_event_queue.trySend(event)) {
        .ok => return true,
        .dropped => unreachable,
        .closed, .full, .oom => |rejected| {
            var failed = rejected;
            defer failed.deinit(self.msg_allocator);
            log.warn("lifecycle queue rejected ui event", .{});
            return false;
        },
    }
}

fn coalescePendingSnapshot(self: *Interactive, event: UiEvent) void {
    const dropped = switch (event) {
        .conversation_snapshot => self.snapshot_event_queue.dropMatching(isConversationSnapshot, null),
        .queued_snapshot => self.snapshot_event_queue.dropMatching(isQueuedSnapshot, null),
        .status_snapshot => self.snapshot_event_queue.dropMatching(isStatusSnapshot, null),
        else => 0,
    };
    self.snapshot_coalesced_dropped += dropped;
}

fn isConversationSnapshot(item: *const UiEvent, _: ?*anyopaque) bool {
    return item.* == .conversation_snapshot;
}

fn isQueuedSnapshot(item: *const UiEvent, _: ?*anyopaque) bool {
    return item.* == .queued_snapshot;
}

fn isStatusSnapshot(item: *const UiEvent, _: ?*anyopaque) bool {
    return item.* == .status_snapshot;
}

pub fn logStats(comptime label: []const u8, stats: anytype) void {
    log.info(
        "{s} queue stats pending={d} high_water={d} sends={d} wakes={d} rejected={d} dropped={d} state={s}",
        .{
            label,
            stats.pending_depth,
            stats.high_water_depth,
            stats.send_count,
            stats.wake_count,
            stats.rejected_count,
            stats.dropped_count,
            @tagName(stats.state),
        },
    );
}

fn drainQueue(self: *Interactive, queue: anytype) void {
    var event_buf: [64]UiEvent = undefined;
    while (true) {
        const count = queue.drainInto(&event_buf);
        if (count == 0) break;
        for (event_buf[0..count]) |*ev| {
            self.handleUiEvent(ev);
            ev.deinit(self.msg_allocator);
        }
    }
}
