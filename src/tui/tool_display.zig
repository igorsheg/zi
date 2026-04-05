const std = @import("std");
const theme_mod = @import("theme.zig");
const buffer_mod = @import("buffer.zig");
const Region = buffer_mod.Region;
const agent_protocol = @import("../agent/root.zig").protocol;
const AgentToolResult = agent_protocol.AgentToolResult;

pub const ToolRenderer = struct {
    render_call: ?*const fn (ctx: *const ToolRenderContext) void = null,
    render_result: ?*const fn (ctx: *const ToolRenderContext) void = null,
    measure_result: ?*const fn (ctx: *const ToolRenderContext) u32 = null,
    init_state: ?*const fn (allocator: std.mem.Allocator) ?*anyopaque = null,
    deinit_state: ?*const fn (state: *anyopaque, allocator: std.mem.Allocator) void = null,
};

pub const ToolRenderContext = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    args: std.json.Value,
    result: ?AgentToolResult,
    is_partial: bool,
    is_error: bool,
    expanded: bool,
    execution_started: bool,
    args_complete: bool,
    theme: *const theme_mod.Theme,
    allocator: std.mem.Allocator,
    state: ?*anyopaque,
    region: Region,
    width: u32,
};

pub const ToolRendererRegistry = struct {
    entries: []const Registration,

    pub const Registration = struct {
        tool_name: []const u8,
        renderer: ToolRenderer,
    };

    pub fn get(self: *const ToolRendererRegistry, tool_name: []const u8) ToolRenderer {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.tool_name, tool_name)) {
                return entry.renderer;
            }
        }
        return .{};
    }
};

pub const default_registry = ToolRendererRegistry{
    .entries = &.{},
};

// --- tests ---

const testing = std.testing;

test "ToolRendererRegistry returns empty renderer for unknown tool" {
    const registry = ToolRendererRegistry{ .entries = &.{} };
    const renderer = registry.get("unknown");
    try testing.expect(renderer.render_call == null);
    try testing.expect(renderer.render_result == null);
    try testing.expect(renderer.measure_result == null);
    try testing.expect(renderer.init_state == null);
    try testing.expect(renderer.deinit_state == null);
}

test "ToolRendererRegistry finds registered renderer" {
    const S = struct {
        fn renderCall(_: *const ToolRenderContext) void {}
    };
    const entries = [_]ToolRendererRegistry.Registration{
        .{ .tool_name = "bash", .renderer = .{ .render_call = &S.renderCall } },
    };
    const registry = ToolRendererRegistry{ .entries = &entries };
    const renderer = registry.get("bash");
    try testing.expect(renderer.render_call != null);
    try testing.expect(renderer.render_result == null);
}

test "default_registry has no entries" {
    try testing.expectEqual(@as(usize, 0), default_registry.entries.len);
}
