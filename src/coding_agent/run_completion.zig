const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const state_mod = @import("state.zig");
const command_mod = @import("command.zig");
const message_memory = @import("../agent/message_memory.zig");

pub const OwnedRunTerminal = struct {
    arena: std.heap.ArenaAllocator,
    status: Status,

    pub const Status = union(enum) {
        completed: []const agent_mod.AgentMessage,
        failed: Failed,
        aborted: []const agent_mod.AgentMessage,
    };

    pub const Failed = struct {
        messages: []const agent_mod.AgentMessage,
        kind: state_mod.FailureKind,
    };

    pub fn completed(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) !OwnedRunTerminal {
        var self = OwnedRunTerminal{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .status = .{ .completed = &.{} },
        };
        errdefer self.deinit();
        self.status = .{ .completed = try message_memory.cloneMessages(self.arena.allocator(), messages) };
        return self;
    }

    pub fn failed(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage, kind: state_mod.FailureKind) !OwnedRunTerminal {
        var self = OwnedRunTerminal{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .status = .{ .failed = .{ .messages = &.{}, .kind = kind } },
        };
        errdefer self.deinit();
        self.status = .{ .failed = .{ .messages = try message_memory.cloneMessages(self.arena.allocator(), messages), .kind = kind } };
        return self;
    }

    pub fn aborted(allocator: std.mem.Allocator, messages: []const agent_mod.AgentMessage) !OwnedRunTerminal {
        var self = OwnedRunTerminal{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .status = .{ .aborted = &.{} },
        };
        errdefer self.deinit();
        self.status = .{ .aborted = try message_memory.cloneMessages(self.arena.allocator(), messages) };
        return self;
    }

    pub fn deinit(self: *OwnedRunTerminal) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const RunCompletion = struct {
    command_id: command_mod.CommandId,
    terminal: OwnedRunTerminal,

    pub fn deinit(self: *RunCompletion) void {
        self.terminal.deinit();
        self.* = undefined;
    }
};

fn testUserMessage(text: []const u8) agent_mod.AgentMessage {
    return .{ .user = .{ .content = .{ .text = text }, .timestamp = 1 } };
}

test "owned run terminal owns completed messages" {
    const messages = [_]agent_mod.AgentMessage{testUserMessage("done")};
    var terminal = try OwnedRunTerminal.completed(std.testing.allocator, &messages);
    defer terminal.deinit();

    try std.testing.expectEqual(@as(usize, 1), terminal.status.completed.len);
    try std.testing.expectEqualStrings("done", terminal.status.completed[0].user.content.text);
    try std.testing.expect(terminal.status.completed[0].user.content.text.ptr != messages[0].user.content.text.ptr);
}

test "owned run terminal owns failed messages and kind" {
    const messages = [_]agent_mod.AgentMessage{testUserMessage("failed")};
    var terminal = try OwnedRunTerminal.failed(std.testing.allocator, &messages, .invalid_context);
    defer terminal.deinit();

    try std.testing.expectEqual(state_mod.FailureKind.invalid_context, terminal.status.failed.kind);
    try std.testing.expectEqual(@as(usize, 1), terminal.status.failed.messages.len);
    try std.testing.expectEqualStrings("failed", terminal.status.failed.messages[0].user.content.text);
    try std.testing.expect(terminal.status.failed.messages[0].user.content.text.ptr != messages[0].user.content.text.ptr);
}

test "owned run terminal owns aborted messages" {
    const messages = [_]agent_mod.AgentMessage{testUserMessage("aborted")};
    var terminal = try OwnedRunTerminal.aborted(std.testing.allocator, &messages);
    defer terminal.deinit();

    try std.testing.expectEqual(@as(usize, 1), terminal.status.aborted.len);
    try std.testing.expectEqualStrings("aborted", terminal.status.aborted[0].user.content.text);
    try std.testing.expect(terminal.status.aborted[0].user.content.text.ptr != messages[0].user.content.text.ptr);
}
