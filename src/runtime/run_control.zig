const std = @import("std");
const mailbox_mod = @import("mailbox.zig");
const protocol = @import("../agent/protocol.zig");
const message_memory = @import("../agent/message_memory.zig");

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

    pub fn deinit(self: *QueuedMessageSnapshot, allocator: std.mem.Allocator) void {
        for (self.steering) |entry| allocator.free(entry.text);
        for (self.follow_up) |entry| allocator.free(entry.text);
        allocator.free(self.steering);
        allocator.free(self.follow_up);
        self.* = undefined;
    }
};

const MessageMailbox = mailbox_mod.Mailbox(protocol.AgentMessage, .{
    .cleanup = .{ .custom = cleanupAgentMessage },
    .policy = .unbounded,
    .wakeup = .none,
});

pub const RunControl = struct {
    steering: MessageQueue,
    follow_up: MessageQueue,

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
        return self.queueFor(kind).enqueue(message);
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
        self.steering.clear();
    }

    pub fn clearFollowUp(self: *RunControl) void {
        self.follow_up.clear();
    }

    pub fn clearAll(self: *RunControl) void {
        self.clearSteering();
        self.clearFollowUp();
    }

    pub fn snapshot(self: *RunControl, allocator: std.mem.Allocator) QueuedMessageSnapshot {
        return .{
            .steering = self.steering.snapshotTexts(allocator),
            .follow_up = self.follow_up.snapshotTexts(allocator),
        };
    }

    pub fn clearAndSnapshot(self: *RunControl, allocator: std.mem.Allocator) QueuedMessageSnapshot {
        return .{
            .steering = self.steering.takeSnapshotAndClear(allocator),
            .follow_up = self.follow_up.takeSnapshotAndClear(allocator),
        };
    }

    pub fn drainSteering(self: *RunControl, arena: std.mem.Allocator) []const protocol.AgentMessage {
        return self.steering.drain(arena);
    }

    pub fn drainFollowUp(self: *RunControl, arena: std.mem.Allocator) []const protocol.AgentMessage {
        return self.follow_up.drain(arena);
    }

    fn queueFor(self: *RunControl, kind: QueueKind) *MessageQueue {
        return switch (kind) {
            .steering => &self.steering,
            .follow_up => &self.follow_up,
        };
    }
};

const MessageQueue = struct {
    mailbox: MessageMailbox,
    mode: QueueMode,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, mode: QueueMode) !MessageQueue {
        return .{
            .mailbox = try MessageMailbox.init(allocator),
            .mode = mode,
            .allocator = allocator,
        };
    }

    fn deinit(self: *MessageQueue) void {
        self.mailbox.deinit();
        self.* = undefined;
    }

    fn enqueue(self: *MessageQueue, message: protocol.AgentMessage) EnqueueResult {
        const owned = message_memory.cloneMessage(self.allocator, message) catch return .oom;
        switch (self.mailbox.trySend(owned)) {
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
        return self.mailbox.pendingDepth() > 0;
    }

    fn clear(self: *MessageQueue) void {
        self.mailbox.clear();
    }

    fn drain(self: *MessageQueue, arena: std.mem.Allocator) []const protocol.AgentMessage {
        const target_count = switch (self.mode) {
            .all => self.mailbox.pendingDepth(),
            .one_at_a_time => @min(@as(usize, 1), self.mailbox.pendingDepth()),
        };
        if (target_count == 0) return &.{};

        const cloned = arena.alloc(protocol.AgentMessage, target_count) catch return &.{};
        var out_len: usize = 0;
        var remaining = target_count;
        var buf: [8]protocol.AgentMessage = undefined;

        while (remaining > 0) {
            const take = @min(remaining, buf.len);
            const drained = self.mailbox.drainInto(buf[0..take]);
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

    fn snapshotTexts(self: *MessageQueue, allocator: std.mem.Allocator) []QueuedMessageText {
        var out: std.ArrayList(QueuedMessageText) = .empty;
        var success = false;
        defer if (!success) {
            for (out.items) |entry| allocator.free(entry.text);
            out.deinit(allocator);
        };

        const SnapshotCtx = struct {
            allocator: std.mem.Allocator,
            out: *std.ArrayList(QueuedMessageText),
        };
        var ctx = SnapshotCtx{ .allocator = allocator, .out = &out };

        const Visitor = struct {
            fn visit(item: *const protocol.AgentMessage, raw_ctx: ?*anyopaque) !void {
                const ctx_ptr: *SnapshotCtx = @ptrCast(@alignCast(raw_ctx.?));
                const text = extractQueuedMessageText(item.*) orelse return;
                const owned = try ctx_ptr.allocator.dupe(u8, text);
                errdefer ctx_ptr.allocator.free(owned);
                try ctx_ptr.out.append(ctx_ptr.allocator, .{ .text = owned });
            }
        };

        self.mailbox.visitPending(Visitor.visit, @ptrCast(&ctx)) catch return &.{};
        const snapshot = out.toOwnedSlice(allocator) catch return &.{};
        success = true;
        return snapshot;
    }

    fn takeSnapshotAndClear(self: *MessageQueue, allocator: std.mem.Allocator) []QueuedMessageText {
        const snapshot = self.snapshotTexts(allocator);
        self.clear();
        return snapshot;
    }
};

fn cleanupAgentMessage(item_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const message: *protocol.AgentMessage = @ptrCast(@alignCast(item_ptr));
    message_memory.freeMessage(allocator, message);
}

fn extractQueuedMessageText(msg: protocol.AgentMessage) ?[]const u8 {
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
