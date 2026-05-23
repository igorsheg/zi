const std = @import("std");
const message = @import("message.zig");
const message_memory = @import("message_memory.zig");
const failure = @import("failure.zig");

pub const OwnedRunTerminal = struct {
    arena: std.heap.ArenaAllocator,
    status: Status,

    pub const Status = union(enum) {
        completed: []const message.AgentMessage,
        failed: Failed,
        aborted: []const message.AgentMessage,
    };

    pub const Failed = struct {
        messages: []const message.AgentMessage,
        kind: failure.Kind,
    };

    pub fn completed(allocator: std.mem.Allocator, messages: []const message.AgentMessage) !OwnedRunTerminal {
        var self = OwnedRunTerminal{ .arena = std.heap.ArenaAllocator.init(allocator), .status = .{ .completed = &.{} } }; // ziglint-ignore: Z024, Z004
        errdefer self.deinit();
        self.status = .{ .completed = try message_memory.cloneMessages(self.arena.allocator(), messages) };
        return self;
    }

    pub fn failed(allocator: std.mem.Allocator, messages: []const message.AgentMessage, kind_value: failure.Kind) !OwnedRunTerminal { // ziglint-ignore: Z024
        var self = OwnedRunTerminal{ .arena = std.heap.ArenaAllocator.init(allocator), .status = .{ .failed = .{ .messages = &.{}, .kind = kind_value } } }; // ziglint-ignore: Z024, Z004
        errdefer self.deinit();
        self.status = .{ .failed = .{ .messages = try message_memory.cloneMessages(self.arena.allocator(), messages), .kind = kind_value } }; // ziglint-ignore: Z024
        return self;
    }

    pub fn aborted(allocator: std.mem.Allocator, messages: []const message.AgentMessage) !OwnedRunTerminal {
        var self = OwnedRunTerminal{ .arena = std.heap.ArenaAllocator.init(allocator), .status = .{ .aborted = &.{} } }; // ziglint-ignore: Z004, Z024
        errdefer self.deinit();
        self.status = .{ .aborted = try message_memory.cloneMessages(self.arena.allocator(), messages) };
        return self;
    }

    pub fn deinit(self: *OwnedRunTerminal) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
