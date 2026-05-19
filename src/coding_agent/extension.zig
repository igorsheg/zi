const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const json_value = @import("../json/value.zig");

pub const Host = union(enum) {
    disabled,
    registry: ToolRegistry,

    pub fn disabledHost() Host {
        return .disabled;
    }

    pub fn initTools(allocator: std.mem.Allocator, source: []const agent_mod.AgentTool) !Host {
        return .{ .registry = try ToolRegistry.init(allocator, source) };
    }

    pub fn tools(self: *const Host) []const agent_mod.AgentTool {
        return switch (self.*) {
            .disabled => &.{},
            .registry => |*registry| registry.tools,
        };
    }

    pub fn deinit(self: *Host) void {
        switch (self.*) {
            .disabled => {},
            .registry => |*registry| registry.deinit(),
        }
        self.* = undefined;
    }
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: []agent_mod.AgentTool,
    parameters: []json_value.OwnedValue,

    pub fn init(allocator: std.mem.Allocator, source: []const agent_mod.AgentTool) !ToolRegistry {
        const tools = try allocator.alloc(agent_mod.AgentTool, source.len);
        errdefer allocator.free(tools);
        const parameters = try allocator.alloc(json_value.OwnedValue, source.len);
        errdefer allocator.free(parameters);

        var initialized: usize = 0;
        errdefer {
            for (tools[0..initialized]) |tool| {
                allocator.free(tool.name);
                allocator.free(tool.description);
            }
            for (parameters[0..initialized]) |*params| params.deinit();
        }

        for (source, 0..) |tool, i| {
            const cloned = try cloneToolDescriptor(allocator, tool);
            parameters[i] = cloned.parameters;
            tools[i] = .{
                .name = cloned.name,
                .description = cloned.description,
                .parameters = cloned.parameters.borrowed(),
                .ctx = tool.ctx,
                .execute_fn = tool.execute_fn,
            };
            initialized += 1;
        }

        return .{ .allocator = allocator, .tools = tools, .parameters = parameters };
    }

    pub fn deinit(self: *ToolRegistry) void {
        for (self.tools) |tool| {
            self.allocator.free(tool.name);
            self.allocator.free(tool.description);
        }
        for (self.parameters) |*params| params.deinit();
        self.allocator.free(self.tools);
        self.allocator.free(self.parameters);
        self.* = undefined;
    }
};

const ClonedToolDescriptor = struct {
    name: []const u8,
    description: []const u8,
    parameters: json_value.OwnedValue,
};

fn cloneToolDescriptor(allocator: std.mem.Allocator, tool: agent_mod.AgentTool) !ClonedToolDescriptor {
    const name = try allocator.dupe(u8, tool.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, tool.description);
    errdefer allocator.free(description);
    var parameters = try json_value.OwnedValue.clone(allocator, tool.parameters);
    errdefer parameters.deinit();
    return .{ .name = name, .description = description, .parameters = parameters.move() };
}

fn noopTool(_: ?*anyopaque, _: std.mem.Allocator, _: agent_mod.tool.ToolInvocation, _: agent_mod.tool.ToolCompletionSink) void {}

test "extension host owns registered tool descriptors" {
    const source = [_]agent_mod.AgentTool{.{ .name = "read", .description = "read files", .parameters = .{ .string = "schema" }, .execute_fn = noopTool }};
    var host = try Host.initTools(std.testing.allocator, &source);
    defer host.deinit();

    const tools = host.tools();
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("read", tools[0].name);
    try std.testing.expectEqualStrings("read files", tools[0].description);
    try std.testing.expect(tools[0].name.ptr != source[0].name.ptr);
    try std.testing.expect(tools[0].description.ptr != source[0].description.ptr);
    try std.testing.expect(tools[0].parameters == .string);
    try std.testing.expectEqualStrings("schema", tools[0].parameters.string);
}
