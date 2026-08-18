const std = @import("std");
const message = @import("../ai/message.zig");
const tool = @import("Tool.zig");

pub const ScriptedTool = struct {
    result: []const u8,
    calls: usize = 0,
    recoverable_failure: bool = false,
    fatal: ?tool.ToolFatalError = null,

    pub fn execute(
        self: *ScriptedTool,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: tool.Tool.RunContext,
        _: []const u8,
    ) tool.ToolFatalError!tool.ToolExecution {
        self.calls += 1;
        if (self.fatal) |failure| return failure;
        if (self.recoverable_failure) return .{ .failure = self.result };
        const content = try allocator.alloc(message.Content, 1);
        content[0] = .{ .text = try allocator.dupe(u8, self.result) };
        return .{ .success = .{ .content = content } };
    }

    pub fn asTool(self: *ScriptedTool, definition: message.ToolDefinition) tool.Tool {
        return tool.Tool.from(self, definition);
    }
};
