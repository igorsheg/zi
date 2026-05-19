const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const json_value = @import("../json/value.zig");

pub const Source = struct {
    tools_value: []const agent_mod.AgentTool,

    pub fn tools(self: Source) []const agent_mod.AgentTool {
        return self.tools_value;
    }
};

pub fn empty() Source {
    return .{ .tools_value = &.{} };
}

pub fn fromStatic(tools: []const agent_mod.AgentTool) Source {
    return .{ .tools_value = tools };
}

pub fn host(allocator: std.mem.Allocator, source: Source) !@import("extension.zig").Host {
    return @import("extension.zig").Host.initTools(allocator, source.tools());
}

fn noopTool(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.tool.ToolInvocation, _: agent_mod.tool.ToolCompletionSink) void {}

test "builtin tool source feeds extension host registry" {
    const builtin = [_]agent_mod.AgentTool{.{ .name = "read", .description = "read files", .parameters = json_value.OwnedValue.nullValue().borrowed(), .execute_fn = noopTool }};
    var h = try host(std.testing.allocator, fromStatic(&builtin));
    defer h.deinit();

    const registered = h.tools();
    try std.testing.expectEqual(@as(usize, 1), registered.len);
    try std.testing.expectEqualStrings("read", registered[0].name);
    try std.testing.expect(registered[0].name.ptr != builtin[0].name.ptr);
}

test "empty builtin tool source feeds empty host" {
    var h = try host(std.testing.allocator, empty());
    defer h.deinit();

    try std.testing.expectEqual(@as(usize, 0), h.tools().len);
}
