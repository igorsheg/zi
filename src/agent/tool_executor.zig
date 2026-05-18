const std = @import("std");
const cancel = @import("../runtime/cancel.zig");
const runtime_queue = @import("../runtime/queue.zig");
const protocol = @import("types.zig");
const json_value = @import("../json/value.zig");

pub const ToolOpId = u64;

pub const max_worker_ops: usize = 32;
pub const max_updates: usize = 128;

pub const ToolInvocation = struct {
    op_id: ToolOpId,
    source_index: usize,
    tool: protocol.AgentTool,
    tool_call_id: []u8,
    tool_name: []u8,
    args: json_value.OwnedValue,
    signal: cancel.Token,

    pub fn deinit(self: *ToolInvocation, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        self.args.deinit();
        self.* = undefined;
    }
};

pub const ToolUpdate = struct {
    op_id: ToolOpId,
    source_index: usize,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: json_value.OwnedValue,
    partial_result: protocol.AgentToolResult,

    pub fn deinit(self: *ToolUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.tool_name);
        self.args.deinit();
        self.partial_result.free(allocator);
        self.* = undefined;
    }
};

pub const ToolTerminalCompletion = struct {
    op_id: ToolOpId,
    source_index: usize,
    result: protocol.AgentToolResult,

    pub fn deinit(self: *ToolTerminalCompletion, allocator: std.mem.Allocator) void {
        self.result.free(allocator);
        self.* = undefined;
    }
};

pub const ToolCompletion = union(enum) {
    update: ToolUpdate,
    terminal: ToolTerminalCompletion,

    pub fn deinit(self: *ToolCompletion, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .update => |*update| update.deinit(allocator),
            .terminal => |*terminal| terminal.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ToolExecutor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    threads: std.ArrayList(std.Thread) = .empty,
    updates: runtime_queue.BoundedQueue(ToolUpdate),
    terminals: runtime_queue.BoundedQueue(ToolTerminalCompletion),

    next_op_id_value: ToolOpId = 1,
    live_workers: usize = 0,
    reserved_threads: usize = 0,
    terminal_slots_reserved: usize = 0,
    accepting_submissions: bool = true,
    accepting_updates: bool = true,
    dropped_updates: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ToolExecutor {
        return .{
            .allocator = allocator,
            .io = io,
            .updates = try runtime_queue.BoundedQueue(ToolUpdate).init(allocator, max_updates),
            .terminals = try runtime_queue.BoundedQueue(ToolTerminalCompletion).init(allocator, max_worker_ops),
        };
    }

    pub fn deinit(self: *ToolExecutor) void {
        self.closeSubmissions();
        self.closeUpdates();
        for (self.threads.items) |thread| thread.join();
        self.threads.deinit(self.allocator);
        while (self.updates.pop()) |update| {
            var mutable = update;
            mutable.deinit(self.allocator);
        }
        while (self.terminals.pop()) |terminal| {
            var mutable = terminal;
            mutable.deinit(self.allocator);
            self.terminal_slots_reserved -= 1;
        }
        self.updates.deinit();
        self.terminals.deinit();
        self.* = undefined;
    }

    pub fn nextOpId(self: *ToolExecutor) ToolOpId {
        const id = self.next_op_id_value;
        self.next_op_id_value += 1;
        return id;
    }

    pub fn submit(self: *ToolExecutor, invocation: ToolInvocation) !void {
        self.mutex.lockUncancelable(self.io);
        if (!self.accepting_submissions) {
            self.mutex.unlock(self.io);
            return error.ExecutorClosed;
        }
        if (self.threads.items.len + self.reserved_threads >= max_worker_ops or
            self.terminal_slots_reserved >= max_worker_ops)
        {
            self.mutex.unlock(self.io);
            return error.TooManyToolOperations;
        }
        self.threads.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        self.reserved_threads += 1;
        self.live_workers += 1;
        self.terminal_slots_reserved += 1;
        self.mutex.unlock(self.io);

        var worker = self.allocator.create(Worker) catch |err| {
            self.releaseReservationAfterSubmitFailure();
            return err;
        };
        worker.* = .{
            .allocator = self.allocator,
            .executor = self,
            .invocation = invocation,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };

        const thread = std.Thread.spawn(.{}, Worker.run, .{worker}) catch |err| {
            worker.arena.deinit();
            self.allocator.destroy(worker);
            self.releaseReservationAfterSubmitFailure();
            return err;
        };

        self.mutex.lockUncancelable(self.io);
        self.reserved_threads -= 1;
        self.threads.appendAssumeCapacity(thread);
        self.mutex.unlock(self.io);
    }

    pub fn next(self: *ToolExecutor) ?ToolCompletion {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.updates.pop()) |update| return .{ .update = update };
            if (self.terminals.pop()) |terminal| {
                self.terminal_slots_reserved -= 1;
                return .{ .terminal = terminal };
            }
            if (self.live_workers == 0 and self.reserved_threads == 0) return null;
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    pub fn closeSubmissions(self: *ToolExecutor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.accepting_submissions = false;
        self.condition.broadcast(self.io);
    }

    pub fn closeUpdates(self: *ToolExecutor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.accepting_updates = false;
        self.condition.broadcast(self.io);
    }

    fn releaseReservationAfterSubmitFailure(self: *ToolExecutor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reserved_threads -= 1;
        self.live_workers -= 1;
        self.terminal_slots_reserved -= 1;
        self.condition.broadcast(self.io);
    }

    fn pushUpdate(self: *ToolExecutor, update: ToolUpdate) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.accepting_updates or self.updates.push(update) == error.Full) {
            var mutable = update;
            mutable.deinit(self.allocator);
            self.dropped_updates += 1;
            return;
        }
        self.condition.signal(self.io);
    }

    fn pushTerminal(self: *ToolExecutor, terminal: ToolTerminalCompletion) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.terminals.push(terminal) catch unreachable;
        self.live_workers -= 1;
        self.condition.signal(self.io);
    }
};

const Worker = struct {
    allocator: std.mem.Allocator,
    executor: *ToolExecutor,
    invocation: ToolInvocation,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *Worker) void {
        self.invocation.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *Worker) void {
        defer self.deinit();

        const execution = self.invocation.tool.start(
            self.arena.allocator(),
            self.invocation.tool_call_id,
            self.invocation.args.borrowed(),
            self.invocation.signal,
            &workerUpdateCallback,
            @ptrCast(self),
        );
        const result = resolveToolExecution(
            execution,
            self.arena.allocator(),
            self.invocation.signal,
            &workerUpdateCallback,
            @ptrCast(self),
        );
        const owned = result.clone(self.executor.allocator) catch makeAgentToolTextResult(self.executor.allocator, "Tool execution failed", true);
        self.executor.pushTerminal(.{
            .op_id = self.invocation.op_id,
            .source_index = self.invocation.source_index,
            .result = owned,
        });
    }
};

fn resolveToolExecution(
    execution: protocol.AgentToolExecution,
    allocator: std.mem.Allocator,
    signal: cancel.Token,
    on_update: ?protocol.AgentToolUpdateCallback,
    update_ctx: ?*anyopaque,
) protocol.AgentToolResult {
    return switch (execution) {
        .ready => |result| result,
        .pending => |pending| blk: {
            defer pending.free(allocator);
            if (signal.isAborted()) pending.requestCancel();
            break :blk pending.await(allocator, signal, on_update, update_ctx);
        },
    };
}

fn workerUpdateCallback(partial_result: protocol.AgentToolResult, ctx: ?*anyopaque) void {
    const worker: *Worker = @ptrCast(@alignCast(ctx.?));
    const allocator = worker.executor.allocator;

    const tool_call_id = allocator.dupe(u8, worker.invocation.tool_call_id) catch return;
    const tool_name = allocator.dupe(u8, worker.invocation.tool_name) catch {
        allocator.free(tool_call_id);
        return;
    };
    var args = json_value.OwnedValue.clone(allocator, worker.invocation.args.borrowed()) catch {
        allocator.free(tool_call_id);
        allocator.free(tool_name);
        return;
    };
    const owned = partial_result.clone(allocator) catch {
        allocator.free(tool_call_id);
        allocator.free(tool_name);
        args.deinit();
        return;
    };

    worker.executor.pushUpdate(.{
        .op_id = worker.invocation.op_id,
        .source_index = worker.invocation.source_index,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .args = args,
        .partial_result = owned,
    });
}

fn makeAgentToolTextResult(allocator: std.mem.Allocator, text: []const u8, is_error: bool) protocol.AgentToolResult {
    const owned_text = allocator.dupe(u8, text) catch return .{ .content = &.{}, .is_error = is_error };
    const content = allocator.alloc(protocol.AgentToolResult.ContentBlock, 1) catch {
        allocator.free(owned_text);
        return .{ .content = &.{}, .is_error = is_error };
    };
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = content, .is_error = is_error };
}
