const std = @import("std");
const runtime_queue = @import("../runtime/queue.zig");
const tool = @import("tool.zig");

pub const max_tool_ops: usize = 32;
pub const max_tool_updates: usize = 128;

pub const Executor = struct {
    allocator: std.mem.Allocator,
    updates: runtime_queue.BoundedQueue(tool.ToolUpdate),
    terminals: runtime_queue.BoundedQueue(tool.ToolTerminalCompletion),
    terminal_slots_reserved: usize = 0,
    accepting: bool = true,
    dropped_updates: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Executor {
        return .{
            .allocator = allocator,
            .updates = try runtime_queue.BoundedQueue(tool.ToolUpdate).init(allocator, max_tool_updates),
            .terminals = try runtime_queue.BoundedQueue(tool.ToolTerminalCompletion).init(allocator, max_tool_ops),
        };
    }

    pub fn deinit(self: *Executor) void {
        while (self.updates.pop()) |update| update.deinit(self.allocator);
        while (self.terminals.pop()) |terminal| terminal.deinit(self.allocator);
        self.updates.deinit();
        self.terminals.deinit();
        self.* = undefined;
    }

    pub fn sink(self: *Executor) tool.ToolCompletionSink {
        return .{ .emit_fn = emitCompletion, .ctx = self };
    }

    pub fn reserveTerminal(self: *Executor) !void {
        if (!self.accepting) return error.ExecutorClosed;
        if (self.terminal_slots_reserved >= self.terminals.capacity()) return error.TooManyToolOperations;
        self.terminal_slots_reserved += 1;
    }

    pub fn close(self: *Executor) void {
        self.accepting = false;
    }

    pub fn next(self: *Executor) ?tool.ToolCompletion {
        if (self.updates.pop()) |update| return .{ .update = update };
        if (self.terminals.pop()) |terminal| {
            std.debug.assert(self.terminal_slots_reserved > 0);
            self.terminal_slots_reserved -= 1;
            return .{ .terminal = terminal };
        }
        return null;
    }

    fn emitCompletion(completion: *tool.ToolCompletion, ctx: ?*anyopaque) void {
        const self: *Executor = @ptrCast(@alignCast(ctx.?));
        switch (completion.*) {
            .update => |update| {
                if (self.updates.push(update)) |_| {} else |_| {
                    update.deinit(self.allocator);
                    self.dropped_updates += 1;
                }
            },
            .terminal => |terminal| {
                self.terminals.push(terminal) catch unreachable;
            },
        }
        completion.* = undefined;
    }
};

test "tool executor reserves terminal capacity for accepted ops" {
    var executor = try Executor.init(std.testing.allocator);
    defer executor.deinit();

    for (0..max_tool_ops) |_| try executor.reserveTerminal();
    try std.testing.expectError(error.TooManyToolOperations, executor.reserveTerminal());

    const sink = executor.sink();
    var emitted = tool.ToolCompletion{ .terminal = .{
        .op_id = 1,
        .source_index = 0,
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .terminal = .{ .completed = .{ .content = &.{} } },
    } };
    sink.emit(&emitted);
    const completion = executor.next().?;
    switch (completion) {
        .terminal => {},
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(@as(usize, max_tool_ops - 1), executor.terminal_slots_reserved);
}
