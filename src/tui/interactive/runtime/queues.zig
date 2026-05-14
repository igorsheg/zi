const std = @import("std");
const posix = std.posix;

const queue_mod = @import("../../../zio/root.zig").queue;
const ui_event_mod = @import("../../ui_event.zig");

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
