const std = @import("std");
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

pub const ToolExecutionGroup = struct {
    allocator: std.mem.Allocator,
    threads: std.ArrayList(std.Thread),
    events: std.ArrayList(ToolExecutionEvent),
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    io: std.Io,
    pending_workers: usize = 0,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ToolExecutionGroup {
        return .{
            .allocator = allocator,
            .threads = .empty,
            .events = .empty,
            .io = io,
        };
    }

    pub fn deinit(self: *ToolExecutionGroup) void {
        self.cancel();
        for (self.threads.items) |thread| thread.join();
        self.threads.deinit(self.allocator);
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn spawnThread(
        self: *ToolExecutionGroup,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) !void {
        std.debug.assert(!self.closed);
        const thread = try std.Thread.spawn(.{}, function, args);
        try self.threads.append(self.allocator, thread);
        self.pending_workers += 1;
    }

    pub fn emit(self: *ToolExecutionGroup, event: ToolExecutionEvent) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) {
            var mutable = event;
            mutable.deinit(self.allocator);
            return;
        }
        self.events.append(self.allocator, event) catch {
            var mutable = event;
            mutable.deinit(self.allocator);
            return;
        };
        self.condition.signal(self.io);
    }

    pub fn next(self: *ToolExecutionGroup) !?ToolExecutionEvent {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.events.items.len > 0) {
                const event = self.events.orderedRemove(0);
                if (event == .completed and self.pending_workers > 0) self.pending_workers -= 1;
                return event;
            }
            if (self.pending_workers == 0) return null;
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    pub fn cancel(self: *ToolExecutionGroup) void {
        if (self.closed) return;
        self.closed = true;
        self.pending_workers = 0;
        self.condition.broadcast(self.io);
    }
};
