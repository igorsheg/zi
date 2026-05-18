const std = @import("std");
const runtime_queue = @import("../runtime/queue.zig");
const message = @import("message.zig");

pub const max_commands: usize = 64;

pub const Command = union(enum) {
    prompt: message.AgentMessage,
    steering: message.AgentMessage,
    follow_up: message.AgentMessage,
    abort,
};

pub const Queue = struct {
    queue: runtime_queue.BoundedQueue(Command),
    dropped: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Queue {
        return .{ .queue = try runtime_queue.BoundedQueue(Command).init(allocator, max_commands) };
    }

    pub fn deinit(self: *Queue) void {
        self.queue.deinit();
        self.* = undefined;
    }

    pub fn submit(self: *Queue, command: Command) !void {
        try self.queue.push(command);
    }

    pub fn trySubmitLatest(self: *Queue, command: Command) void {
        self.queue.push(command) catch {
            self.dropped += 1;
        };
    }

    pub fn next(self: *Queue) ?Command {
        return self.queue.pop();
    }
};

test "command queue is bounded" {
    var queue = try Queue.init(std.testing.allocator);
    defer queue.deinit();
    for (0..max_commands) |_| try queue.submit(.abort);
    try std.testing.expectError(error.Full, queue.submit(.abort));
}
