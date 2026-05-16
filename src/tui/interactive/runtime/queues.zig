const std = @import("std");
const posix = std.posix;

const queue_mod = @import("../../../zio/root.zig").queue;
const ui_event_mod = @import("../../ui_event.zig");
const extension_runner_mod = @import("../../../coding_agent/extensions/runner.zig");

const UiEvent = ui_event_mod.UiEvent;

pub const ui_snapshot_queue_capacity: usize = 64;
pub const ui_lifecycle_queue_capacity: usize = 64;

// Snapshot traffic is lossy. Lifecycle traffic rejects overload so callers keep ownership.
pub const UiSnapshotQueue = queue_mod.Queue(UiEvent, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = ui_snapshot_queue_capacity, .on_full = .drop_oldest } },
    .wakeup = .pipe,
    .cross_thread = true,
});

pub const UiLifecycleQueue = queue_mod.Queue(UiEvent, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = ui_lifecycle_queue_capacity, .on_full = .reject } },
    .wakeup = .pipe,
    .cross_thread = true,
});

pub const TerminalSystemRequest = struct {
    id: extension_runner_mod.AsyncOpId,
    system: extension_runner_mod.SystemRequest,

    pub fn deinit(self: *TerminalSystemRequest, allocator: std.mem.Allocator) void {
        self.system.deinit(allocator);
        self.* = undefined;
    }
};

pub const TerminalSystemQueue = queue_mod.Queue(TerminalSystemRequest, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = 8, .on_full = .reject } },
    .wakeup = .pipe,
    .cross_thread = true,
});

pub fn coalesceSnapshot(queue: *UiSnapshotQueue, event: UiEvent) usize {
    return switch (event) {
        .conversation_snapshot, .queued_snapshot, .status_snapshot => queue.dropMatching(sameSnapshotKind, @constCast(&event)),
        else => 0,
    };
}

fn sameSnapshotKind(item: *const UiEvent, ctx: ?*anyopaque) bool {
    const target: *const UiEvent = @ptrCast(@alignCast(ctx.?));
    return std.meta.activeTag(item.*) == std.meta.activeTag(target.*);
}

test "UiSnapshotQueue drops oldest snapshot traffic when bounded" {
    const themes_builtin = @import("../../../themes/builtin.zig");
    var q = try UiSnapshotQueue.init(std.testing.allocator);
    defer q.deinit();

    var sent: usize = 0;
    while (sent < ui_snapshot_queue_capacity) : (sent += 1) {
        try std.testing.expectEqual(.ok, q.trySend(.{ .theme_changed = themes_builtin.dark().* }));
    }
    try std.testing.expectEqual(.ok, q.trySend(.{ .theme_changed = themes_builtin.light().* }));

    const stats = q.stats();
    try std.testing.expectEqual(@as(usize, ui_snapshot_queue_capacity), stats.pending_depth);
    try std.testing.expectEqual(@as(usize, 1), stats.dropped_count);
    try std.testing.expectEqual(@as(usize, ui_snapshot_queue_capacity + 1), stats.send_count);
}

test "UiSnapshotQueue coalesces latest high-frequency snapshot kinds" {
    const testing = std.testing;
    var q = try UiSnapshotQueue.init(testing.allocator);
    defer q.deinit();

    const first = UiEvent{ .status_snapshot = .{
        .model_provider = try testing.allocator.dupe(u8, "provider-a"),
        .model_id = try testing.allocator.dupe(u8, "model-a"),
        .thinking_level = try testing.allocator.dupe(u8, "low"),
        .context_tokens = 1,
        .context_window = 100,
    } };
    const second = UiEvent{ .status_snapshot = .{
        .model_provider = try testing.allocator.dupe(u8, "provider-b"),
        .model_id = try testing.allocator.dupe(u8, "model-b"),
        .thinking_level = try testing.allocator.dupe(u8, "high"),
        .context_tokens = 2,
        .context_window = 200,
    } };

    try testing.expectEqual(.ok, q.trySend(first));
    try testing.expectEqual(@as(usize, 1), coalesceSnapshot(&q, second));
    try testing.expectEqual(.ok, q.trySend(second));

    var out: [2]UiEvent = undefined;
    const count = q.drainInto(&out);
    defer for (out[0..count]) |*event| event.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(out[0] == .status_snapshot);
    try testing.expectEqualStrings("provider-b", out[0].status_snapshot.model_provider);
}

test "UiSnapshotQueue coalescing leaves unrelated events queued" {
    const themes_builtin = @import("../../../themes/builtin.zig");
    const testing = std.testing;
    var q = try UiSnapshotQueue.init(testing.allocator);
    defer q.deinit();

    try testing.expectEqual(.ok, q.trySend(.{ .theme_changed = themes_builtin.dark().* }));
    const status = UiEvent{ .status_snapshot = .{
        .model_provider = try testing.allocator.dupe(u8, "provider"),
        .model_id = try testing.allocator.dupe(u8, "model"),
        .thinking_level = try testing.allocator.dupe(u8, "medium"),
        .context_tokens = null,
        .context_window = 100,
    } };
    try testing.expectEqual(@as(usize, 0), coalesceSnapshot(&q, status));
    try testing.expectEqual(.ok, q.trySend(status));

    var out: [2]UiEvent = undefined;
    const count = q.drainInto(&out);
    defer for (out[0..count]) |*event| event.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(out[0] == .theme_changed);
    try testing.expect(out[1] == .status_snapshot);
}

test "UiLifecycleQueue rejects overload and keeps wake semantics" {
    var q = try UiLifecycleQueue.init(std.testing.allocator);
    defer q.deinit();

    var sent: usize = 0;
    while (sent < ui_lifecycle_queue_capacity) : (sent += 1) {
        try std.testing.expectEqual(.ok, q.trySend(.{ .request_worker_finished = {} }));
    }
    switch (q.trySend(.{ .request_worker_finished = {} })) {
        .full => |rejected| {
            var failed = rejected;
            failed.deinit(std.testing.allocator);
        },
        else => return error.UnexpectedResult,
    }

    var pfd = [1]posix.pollfd{.{
        .fd = q.wakeReadFd().?,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pfd, 0);
    try std.testing.expectEqual(@as(usize, 1), ready);

    var out: [ui_lifecycle_queue_capacity]UiEvent = undefined;
    const count = q.drainInto(&out);
    try std.testing.expectEqual(ui_lifecycle_queue_capacity, count);
    for (out[0..count]) |*ev| ev.deinit(std.testing.allocator);

    const stats = q.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.rejected_count);
    try std.testing.expectEqual(ui_lifecycle_queue_capacity, stats.high_water_depth);
}
