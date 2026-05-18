const std = @import("std");
const message = @import("message.zig");
const message_memory = @import("message_memory.zig");

pub const History = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayListUnmanaged(message.AgentMessage) = .empty,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        for (self.messages.items) |msg| message_memory.freeMessage(self.allocator, msg);
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *History, msg: message.AgentMessage) !void {
        try self.messages.append(self.allocator, try message_memory.cloneMessage(self.allocator, msg));
    }

    pub fn appendSlice(self: *History, messages: []const message.AgentMessage) !void {
        try self.messages.ensureUnusedCapacity(self.allocator, messages.len);
        for (messages) |msg| self.messages.appendAssumeCapacity(try message_memory.cloneMessage(self.allocator, msg));
    }

    pub fn view(self: *const History) []const message.AgentMessage {
        return self.messages.items;
    }
};
