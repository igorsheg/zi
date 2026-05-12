const std = @import("std");
const zio = @import("../zio/root.zig");
const protocol = @import("types.zig");
const json_util = @import("../ai/json_util.zig");

pub const ToolExecutionEvent = union(enum) {
    update: ToolUpdate,
    completed: ToolCompletion,

    pub fn deinit(self: *ToolExecutionEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .update => |*update| update.deinit(allocator),
            .completed => |*completed| completed.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ToolUpdate = struct {
    prepared_index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,
    partial_result: protocol.AgentToolResult,

    pub fn deinit(self: *ToolUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        json_util.freeJsonValue(allocator, self.args);
        self.partial_result.free(allocator);
        self.* = undefined;
    }
};

pub const ToolCompletion = struct {
    prepared_index: usize,
    result: protocol.AgentToolResult,

    pub fn deinit(self: *ToolCompletion, allocator: std.mem.Allocator) void {
        self.result.free(allocator);
        self.* = undefined;
    }
};

fn cleanupEvent(item: *anyopaque, allocator: std.mem.Allocator) void {
    const event: *ToolExecutionEvent = @ptrCast(@alignCast(item));
    event.deinit(allocator);
}

const EventQueue = zio.queue.Queue(ToolExecutionEvent, .{
    .cleanup = .{ .custom = cleanupEvent },
    .wakeup = .pipe,
});

pub const ToolExecutionGroup = struct {
    allocator: std.mem.Allocator,
    tasks: zio.task.Group,
    events: EventQueue,
    pending_workers: usize = 0,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ToolExecutionGroup {
        return .{
            .allocator = allocator,
            .tasks = zio.task.Group.init(allocator),
            .events = try EventQueue.initIo(allocator, io),
        };
    }

    pub fn deinit(self: *ToolExecutionGroup) void {
        self.cancel();
        self.events.deinit();
        self.* = undefined;
    }

    pub fn spawnThread(
        self: *ToolExecutionGroup,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) std.Io.ConcurrentError!void {
        std.debug.assert(!self.closed);
        try self.tasks.spawnThread(function, args);
        self.pending_workers += 1;
    }

    pub fn emit(self: *ToolExecutionGroup, event: ToolExecutionEvent) void {
        self.events.send(event);
    }

    pub fn next(self: *ToolExecutionGroup) !?ToolExecutionEvent {
        while (true) {
            var one: [1]ToolExecutionEvent = undefined;
            if (self.events.drainInto(&one) > 0) {
                if (one[0] == .completed and self.pending_workers > 0) self.pending_workers -= 1;
                return one[0];
            }
            if (self.pending_workers == 0) return null;
            _ = try self.events.waitReadable(100);
        }
    }

    pub fn cancel(self: *ToolExecutionGroup) void {
        if (self.closed) return;
        self.closed = true;
        self.tasks.cancel();
        self.events.closeMode(.immediate);
        self.pending_workers = 0;
    }
};
