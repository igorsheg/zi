const std = @import("std");
const queue_mod = @import("../zio/root.zig").queue;
const protocol = @import("types.zig");
const message_memory = @import("message_memory.zig");

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const QueueKind = enum {
    steering,
    follow_up,
};

pub const EnqueueResult = enum {
    ok,
    closed,
    oom,
};

pub const QueuedMessageText = struct {
    text: []u8,
};

pub const QueuedMessageSnapshot = struct {
    steering: []QueuedMessageText,
    follow_up: []QueuedMessageText,

    version: u64 = 0,

    pub fn deinit(self: *QueuedMessageSnapshot, allocator: std.mem.Allocator) void {
        for (self.steering) |entry| allocator.free(entry.text);
        for (self.follow_up) |entry| allocator.free(entry.text);
        allocator.free(self.steering);
        allocator.free(self.follow_up);
        self.* = undefined;
    }
};

const MessageStore = queue_mod.Queue(protocol.AgentMessage, .{
    .cleanup = .{ .custom = cleanupAgentMessage },
    .policy = .unbounded,
    .wakeup = .none,
});

pub const RunControl = struct {
    steering: MessageQueue,
    follow_up: MessageQueue,

    version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub const Options = struct {
        steering_mode: QueueMode = .one_at_a_time,
        follow_up_mode: QueueMode = .one_at_a_time,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !RunControl {
        var steering = try MessageQueue.init(allocator, options.steering_mode);
        errdefer steering.deinit();
        const follow_up = try MessageQueue.init(allocator, options.follow_up_mode);
        return .{
            .steering = steering,
            .follow_up = follow_up,
        };
    }

    pub fn deinit(self: *RunControl) void {
        self.steering.deinit();
        self.follow_up.deinit();
        self.* = undefined;
    }

    pub fn enqueue(self: *RunControl, kind: QueueKind, message: protocol.AgentMessage) EnqueueResult {
        const result = self.queueFor(kind).enqueue(message);
        if (result == .ok) self.bumpVersion();
        return result;
    }

    pub fn hasSteeringMessages(self: *RunControl) bool {
        return self.steering.hasItems();
    }

    pub fn hasFollowUpMessages(self: *RunControl) bool {
        return self.follow_up.hasItems();
    }

    pub fn hasQueuedMessages(self: *RunControl) bool {
        return self.hasSteeringMessages() or self.hasFollowUpMessages();
    }

    pub fn clearSteering(self: *RunControl) void {
        const had_items = self.steering.hasItems();
        self.steering.clear();
        if (had_items) self.bumpVersion();
    }

    pub fn clearFollowUp(self: *RunControl) void {
        const had_items = self.follow_up.hasItems();
        self.follow_up.clear();
        if (had_items) self.bumpVersion();
    }

    pub fn clearAll(self: *RunControl) void {
        self.clearSteering();
        self.clearFollowUp();
    }

    pub fn visitPending(
        self: *RunControl,
        kind: QueueKind,
        visitor: *const fn (item: *const protocol.AgentMessage, ctx: ?*anyopaque) anyerror!void,
        ctx: ?*anyopaque,
    ) !void {
        try self.queueFor(kind).visitPending(visitor, ctx);
    }

    pub fn snapshot(self: *RunControl, allocator: std.mem.Allocator) QueuedMessageSnapshot {
        return .{
            .steering = self.steering.snapshotTexts(allocator),
            .follow_up = self.follow_up.snapshotTexts(allocator),
            .version = self.currentVersion(),
        };
    }

    pub fn clearAndSnapshot(self: *RunControl, allocator: std.mem.Allocator) QueuedMessageSnapshot {
        const steering_texts = self.steering.takeSnapshotAndClear(allocator);
        const follow_up_texts = self.follow_up.takeSnapshotAndClear(allocator);
        if (steering_texts.len > 0 or follow_up_texts.len > 0) self.bumpVersion();
        return .{
            .steering = steering_texts,
            .follow_up = follow_up_texts,
            .version = self.currentVersion(),
        };
    }

    pub fn drainSteering(self: *RunControl, arena: std.mem.Allocator) []const protocol.AgentMessage {
        const drained = self.steering.drain(arena);
        if (drained.len > 0) self.bumpVersion();
        return drained;
    }

    pub fn drainFollowUp(self: *RunControl, arena: std.mem.Allocator) []const protocol.AgentMessage {
        const drained = self.follow_up.drain(arena);
        if (drained.len > 0) self.bumpVersion();
        return drained;
    }

    pub fn currentVersion(self: *const RunControl) u64 {
        return self.version.load(.acquire);
    }

    fn bumpVersion(self: *RunControl) void {
        _ = self.version.fetchAdd(1, .acq_rel);
    }

    fn queueFor(self: *RunControl, kind: QueueKind) *MessageQueue {
        return switch (kind) {
            .steering => &self.steering,
            .follow_up => &self.follow_up,
        };
    }
};

const MessageQueue = struct {
    queue: MessageStore,
    mode: QueueMode,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, mode: QueueMode) !MessageQueue {
        return .{
            .queue = try MessageStore.init(allocator),
            .mode = mode,
            .allocator = allocator,
        };
    }

    fn deinit(self: *MessageQueue) void {
        self.queue.deinit();
        self.* = undefined;
    }

    fn enqueue(self: *MessageQueue, message: protocol.AgentMessage) EnqueueResult {
        const owned = message_memory.cloneMessage(self.allocator, message) catch return .oom;
        switch (self.queue.trySend(owned)) {
            .ok => return .ok,
            .dropped, .full => unreachable,
            .closed => |returned| {
                var mutable = returned;
                message_memory.freeMessage(self.allocator, &mutable);
                return .closed;
            },
            .oom => |returned| {
                var mutable = returned;
                message_memory.freeMessage(self.allocator, &mutable);
                return .oom;
            },
        }
    }

    fn hasItems(self: *MessageQueue) bool {
        return self.queue.pendingDepth() > 0;
    }

    fn clear(self: *MessageQueue) void {
        self.queue.clear();
    }

    fn visitPending(
        self: *MessageQueue,
        visitor: *const fn (item: *const protocol.AgentMessage, ctx: ?*anyopaque) anyerror!void,
        ctx: ?*anyopaque,
    ) !void {
        try self.queue.visitPending(visitor, ctx);
    }

    fn drain(self: *MessageQueue, arena: std.mem.Allocator) []const protocol.AgentMessage {
        const target_count = switch (self.mode) {
            .all => self.queue.pendingDepth(),
            .one_at_a_time => @min(@as(usize, 1), self.queue.pendingDepth()),
        };
        if (target_count == 0) return &.{};

        const cloned = arena.alloc(protocol.AgentMessage, target_count) catch return &.{};
        var out_len: usize = 0;
        var remaining = target_count;
        var buf: [8]protocol.AgentMessage = undefined;

        while (remaining > 0) {
            const take = @min(remaining, buf.len);
            const drained = self.queue.drainInto(buf[0..take]);
            if (drained == 0) break;

            for (buf[0..drained]) |item| {
                cloned[out_len] = message_memory.cloneMessage(arena, item) catch {
                    var dropped = item;
                    message_memory.freeMessage(self.allocator, &dropped);
                    continue;
                };
                out_len += 1;
                var mutable = item;
                message_memory.freeMessage(self.allocator, &mutable);
            }
            remaining -= drained;
        }

        return cloned[0..out_len];
    }

    const SnapshotCtx = struct {
        allocator: std.mem.Allocator,
        out: *std.ArrayList(QueuedMessageText),
    };

    fn snapshotVisit(item: *const protocol.AgentMessage, raw_ctx: ?*anyopaque) !void {
        const ctx_ptr: *SnapshotCtx = @ptrCast(@alignCast(raw_ctx.?));
        const text = extractQueuedMessageText(item.*) orelse return;
        const owned = try ctx_ptr.allocator.dupe(u8, text);
        errdefer ctx_ptr.allocator.free(owned);
        try ctx_ptr.out.append(ctx_ptr.allocator, .{ .text = owned });
    }

    fn snapshotTexts(self: *MessageQueue, allocator: std.mem.Allocator) []QueuedMessageText {
        var out: std.ArrayList(QueuedMessageText) = .empty;
        var success = false;
        defer if (!success) {
            for (out.items) |entry| allocator.free(entry.text);
            out.deinit(allocator);
        };

        var ctx = SnapshotCtx{ .allocator = allocator, .out = &out };
        self.queue.visitPending(snapshotVisit, @ptrCast(&ctx)) catch return &.{};
        const snapshot = out.toOwnedSlice(allocator) catch return &.{};
        success = true;
        return snapshot;
    }

    fn takeSnapshotAndClear(self: *MessageQueue, allocator: std.mem.Allocator) []QueuedMessageText {
        var out: std.ArrayList(QueuedMessageText) = .empty;
        var success = false;
        defer if (!success) {
            for (out.items) |entry| allocator.free(entry.text);
            out.deinit(allocator);
        };

        var ctx = SnapshotCtx{ .allocator = allocator, .out = &out };
        self.queue.visitAndClear(snapshotVisit, @ptrCast(&ctx)) catch return &.{};
        const snapshot = out.toOwnedSlice(allocator) catch return &.{};
        success = true;
        return snapshot;
    }
};

fn cleanupAgentMessage(item_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const message: *protocol.AgentMessage = @ptrCast(@alignCast(item_ptr));
    message_memory.freeMessage(allocator, message);
}

pub fn extractQueuedMessageText(msg: protocol.AgentMessage) ?[]const u8 {
    return switch (msg) {
        .user => |user| switch (user.content) {
            .text => |text| text,
            .blocks => |blocks| blk: {
                var first: ?[]const u8 = null;
                var total_len: usize = 0;
                var text_count: usize = 0;
                for (blocks) |block| {
                    switch (block) {
                        .text => |text_block| {
                            if (first == null) first = text_block.text;
                            total_len += text_block.text.len;
                            text_count += 1;
                        },
                        .image => {},
                    }
                }
                if (text_count == 0) break :blk null;
                if (text_count == 1 and first != null and total_len == first.?.len) break :blk first.?;
                break :blk null;
            },
        },
        .custom => |custom| switch (custom.content) {
            .text => |text| text,
            .blocks => null,
        },
        else => null,
    };
}

test "RunControl snapshots queued steering and follow-up messages" {
    var run_control = try RunControl.init(std.testing.allocator, .{});
    defer run_control.deinit();

    try std.testing.expectEqual(.ok, run_control.enqueue(.steering, .{ .user = .{
        .content = .{ .text = "steer" },
        .timestamp = 1,
    } }));
    try std.testing.expectEqual(.ok, run_control.enqueue(.follow_up, .{ .user = .{
        .content = .{ .text = "follow" },
        .timestamp = 2,
    } }));

    var snapshot = run_control.snapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), snapshot.steering.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.follow_up.len);
    try std.testing.expectEqualStrings("steer", snapshot.steering[0].text);
    try std.testing.expectEqualStrings("follow", snapshot.follow_up[0].text);
}

test "RunControl snapshots queued custom message text" {
    var run_control = try RunControl.init(std.testing.allocator, .{});
    defer run_control.deinit();

    try std.testing.expectEqual(.ok, run_control.enqueue(.steering, .{ .custom = .{
        .custom_type = "test.custom",
        .content = .{ .text = "custom steer" },
        .display = true,
        .timestamp = 1,
    } }));

    var snapshot = run_control.snapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), snapshot.steering.len);
    try std.testing.expectEqualStrings("custom steer", snapshot.steering[0].text);
}

test "RunControl one-at-a-time drain preserves later steering messages" {
    var run_control = try RunControl.init(std.testing.allocator, .{});
    defer run_control.deinit();

    try std.testing.expectEqual(.ok, run_control.enqueue(.steering, .{ .user = .{
        .content = .{ .text = "first" },
        .timestamp = 1,
    } }));
    try std.testing.expectEqual(.ok, run_control.enqueue(.steering, .{ .user = .{
        .content = .{ .text = "second" },
        .timestamp = 2,
    } }));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const drained = run_control.drainSteering(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), drained.len);
    switch (drained[0]) {
        .user => |user| switch (user.content) {
            .text => |text| try std.testing.expectEqualStrings("first", text),
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }

    var snapshot = run_control.snapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.steering.len);
    try std.testing.expectEqualStrings("second", snapshot.steering[0].text);
}

test "RunControl clearAndSnapshot returns queued texts and clears both queues" {
    var run_control = try RunControl.init(std.testing.allocator, .{});
    defer run_control.deinit();

    try std.testing.expectEqual(.ok, run_control.enqueue(.steering, .{ .user = .{
        .content = .{ .text = "steer" },
        .timestamp = 1,
    } }));
    try std.testing.expectEqual(.ok, run_control.enqueue(.follow_up, .{ .user = .{
        .content = .{ .text = "follow" },
        .timestamp = 2,
    } }));

    var snapshot = run_control.clearAndSnapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), snapshot.steering.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.follow_up.len);
    try std.testing.expect(!run_control.hasQueuedMessages());
}
