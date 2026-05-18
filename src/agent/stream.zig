const std = @import("std");
const runtime_queue = @import("../runtime/queue.zig");
const message = @import("message.zig");
const failure = @import("failure.zig");
const message_memory = @import("message_memory.zig");

pub const max_stream_completions: usize = 256;

pub const Completion = union(enum) {
    started,
    delta: message.AssistantMessageEvent,
    terminal: Terminal,
};

pub const Terminal = union(enum) {
    completed: message.AssistantMessage,
    failed: failure.Failure,
    aborted,
};

pub const Queue = struct {
    queue: runtime_queue.BoundedQueue(Completion),
    terminal_reserved: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Queue {
        return .{ .queue = try runtime_queue.BoundedQueue(Completion).init(allocator, max_stream_completions) };
    }

    pub fn deinit(self: *Queue) void {
        while (self.queue.pop()) |completion| deinitCompletion(self.queue.allocator, completion);
        self.queue.deinit();
        self.* = undefined;
    }

    pub fn reserveTerminal(self: *Queue) !void {
        if (self.terminal_reserved) return error.TerminalAlreadyReserved;
        if (self.queue.capacity() - self.queue.len == 0) return error.Full;
        self.terminal_reserved = true;
    }

    pub fn pushDelta(self: *Queue, delta: message.AssistantMessageEvent) void {
        if (self.terminal_reserved and self.queue.len >= self.queue.capacity() - 1) return;
        self.queue.push(.{ .delta = delta }) catch {};
    }

    pub fn pushTerminal(self: *Queue, terminal: Terminal) void {
        std.debug.assert(self.terminal_reserved);
        self.queue.push(.{ .terminal = terminal }) catch unreachable;
    }

    pub fn pop(self: *Queue) ?Completion {
        const completion = self.queue.pop() orelse return null;
        if (completion == .terminal) self.terminal_reserved = false;
        return completion;
    }
};

pub fn deinitCompletion(allocator: std.mem.Allocator, completion: Completion) void {
    switch (completion) {
        .terminal => |terminal| switch (terminal) {
            .completed => |assistant| message_memory.freeAssistant(allocator, assistant),
            .failed, .aborted => {},
        },
        else => {},
    }
}

test "stream queue drops deltas but preserves reserved terminal" {
    var queue = try Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.reserveTerminal();
    for (0..max_stream_completions + 10) |_| {
        queue.pushDelta(.start);
    }
    queue.pushTerminal(.aborted);

    var saw_terminal = false;
    while (queue.pop()) |completion| {
        switch (completion) {
            .terminal => |terminal| switch (terminal) {
                .aborted => saw_terminal = true,
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expect(saw_terminal);
    try std.testing.expect(!queue.terminal_reserved);
}
