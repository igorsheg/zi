const std = @import("std");
const theme_mod = @import("../theme.zig");
const buffer_mod = @import("../primitives/surface.zig");
const Region = buffer_mod.Region;
const agent_protocol = @import("../../agent/root.zig").protocol;
const AgentToolResult = agent_protocol.AgentToolResult;

pub const ToolRenderer = struct {
    render_call: ?*const fn (ctx: *const ToolRenderContext) void = null,
    render_result_slice: ?*const fn (ctx: *const ToolRenderContext, first_row: u32) void = null,
    measure_result: ?*const fn (ctx: *const ToolMeasureContext) u32 = null,
    init_state: ?*const fn (allocator: std.mem.Allocator) ?*anyopaque = null,
    deinit_state: ?*const fn (state: *anyopaque, allocator: std.mem.Allocator) void = null,
    args_changed: ?*const fn (ctx: *const ToolStateContext) void = null,
    result_changed: ?*const fn (ctx: *const ToolStateContext) void = null,
};

pub const ToolStateContext = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    args: std.json.Value,
    result: ?AgentToolResult,
    is_partial: bool,
    is_error: bool,
    expanded: bool,
    execution_started: bool,
    args_complete: bool,
    allocator: std.mem.Allocator,
    state: ?*anyopaque,
};

pub const ToolMeasureContext = struct {
    tool_name: []const u8,
    tool_call_id: []const u8,
    args: std.json.Value,
    result: ?AgentToolResult,
    is_partial: bool,
    is_error: bool,
    expanded: bool,
    execution_started: bool,
    args_complete: bool,
    allocator: std.mem.Allocator,
    state: ?*anyopaque,
    width: u32,
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

pub const Registration = struct {
    tool_name: []const u8,
    renderer: ToolRenderer,
    label: ?[]const u8 = null,
    display_call: ?[]const u8 = null,
};

pub const ToolDisplay = struct {
    renderer: ToolRenderer = .{},
    label: ?[]const u8 = null,
    display_call: ?[]const u8 = null,
};

pub const ToolRendererResolver = struct {
    ctx: ?*anyopaque = null,
    resolve_fn: *const fn (ctx: ?*anyopaque, tool_name: []const u8) ToolDisplay,

    pub fn resolve(self: *const ToolRendererResolver, tool_name: []const u8) ToolRenderer {
        return self.resolveDisplay(tool_name).renderer;
    }

    pub fn resolveDisplay(self: *const ToolRendererResolver, tool_name: []const u8) ToolDisplay {
        return self.resolve_fn(self.ctx, tool_name);
    }

    pub fn fromStatic(entries: *const []const Registration) ToolRendererResolver {
        const S = struct {
            fn resolveStatic(ctx: ?*anyopaque, tool_name: []const u8) ToolDisplay {
                const slice_ptr: *const []const Registration = @ptrCast(@alignCast(ctx.?));
                for (slice_ptr.*) |entry| {
                    if (std.mem.eql(u8, entry.tool_name, tool_name)) {
                        return .{ .renderer = entry.renderer, .label = entry.label, .display_call = entry.display_call };
                    }
                }
                return .{};
            }
        };
        return .{ .ctx = @ptrCast(@constCast(entries)), .resolve_fn = S.resolveStatic };
    }
};

pub const empty_resolver = ToolRendererResolver{
    .ctx = null,
    .resolve_fn = struct {
        fn resolveNone(_: ?*anyopaque, _: []const u8) ToolDisplay {
            return .{};
        }
    }.resolveNone,
};
