const std = @import("std");
const runtime_queue = @import("../runtime/queue.zig");
const tool = @import("tool.zig");

pub const max_tool_ops: usize = 32;
pub const max_tool_updates: usize = 128;

pub const Contract = struct {
    max_in_flight: usize,
    max_updates: usize,
    completion_delivery: CompletionDelivery,

    pub fn init(options: ContractOptions) Contract {
        if (options.max_in_flight == 0) @panic("tool executor max_in_flight must be greater than zero");
        if (options.max_updates == 0) @panic("tool executor max_updates must be greater than zero");
        if (options.completion_delivery == .bounded_queue) {
            if (options.completion_delivery.bounded_queue.terminals == 0) @panic("tool executor terminal queue capacity must be greater than zero");
            if (options.completion_delivery.bounded_queue.updates == 0) @panic("tool executor update queue capacity must be greater than zero");
        }
        return .{
            .max_in_flight = options.max_in_flight,
            .max_updates = options.max_updates,
            .completion_delivery = options.completion_delivery,
        };
    }
};

pub const ContractOptions = struct {
    max_in_flight: usize = max_tool_ops,
    max_updates: usize = max_tool_updates,
    completion_delivery: CompletionDelivery = .{ .bounded_queue = .{ .terminals = max_tool_ops, .updates = max_tool_updates } },
};

pub const CompletionDelivery = union(enum) {
    direct_owner_call,
    bounded_queue: QueueCapacity,
};

pub const QueueCapacity = struct {
    terminals: usize,
    updates: usize,
};

pub const InvocationContract = struct {
    pub const terminal_completion_required = true;
    pub const updates_are_optional = true;
    pub const cancellation_completion_is_terminal_aborted = true;
};

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

    pub fn contract(self: *const Executor) Contract {
        return Contract.init(.{
            .max_in_flight = self.terminals.capacity(),
            .max_updates = self.updates.capacity(),
            .completion_delivery = .{ .bounded_queue = .{ .terminals = self.terminals.capacity(), .updates = self.updates.capacity() } },
        });
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

test "tool executor contract names bounded completions and in flight capacity" {
    var executor = try Executor.init(std.testing.allocator);
    defer executor.deinit();

    const c = executor.contract();

    try std.testing.expectEqual(@as(usize, max_tool_ops), c.max_in_flight);
    try std.testing.expectEqual(@as(usize, max_tool_updates), c.max_updates);
    try std.testing.expectEqual(@as(usize, max_tool_ops), c.completion_delivery.bounded_queue.terminals);
    try std.testing.expectEqual(@as(usize, max_tool_updates), c.completion_delivery.bounded_queue.updates);
    try std.testing.expect(InvocationContract.terminal_completion_required);
    try std.testing.expect(InvocationContract.updates_are_optional);
    try std.testing.expect(InvocationContract.cancellation_completion_is_terminal_aborted);
}
