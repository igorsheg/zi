const std = @import("std");
const theme_mod = @import("theme.zig");
const buffer_mod = @import("buffer.zig");
const Region = buffer_mod.Region;
const agent_protocol = @import("../agent/root.zig").protocol;
const AgentToolResult = agent_protocol.AgentToolResult;

pub const ToolRenderer = struct {
    render_call: ?*const fn (ctx: *const ToolRenderContext) void = null,
    render_result_slice: ?*const fn (ctx: *const ToolRenderContext, first_row: u32) void = null,
    measure_result: ?*const fn (ctx: *const ToolMeasureContext) u32 = null,
    init_state: ?*const fn (allocator: std.mem.Allocator) ?*anyopaque = null,
    deinit_state: ?*const fn (state: *anyopaque, allocator: std.mem.Allocator) void = null,
    args_changed: ?*const fn (ctx: *const ToolStateContext) void = null,
    result_changed: ?*const fn (ctx: *const ToolStateContext) void = null,
    expanded_changed: ?*const fn (ctx: *const ToolStateContext) void = null,
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

/// Static registration of a zig-native tool renderer (built-in tools
/// like bash, read, find — compiled into the binary, looked up by
/// name once at tool-call start).
pub const Registration = struct {
    tool_name: []const u8,
    renderer: ToolRenderer,
};

/// Resolver seam between tool names and renderers.
///
/// Two reasons this is a resolver and not a plain slice:
///
///   1. **dynamic sources**: Lua-registered tools live in the
///      runtime `ExtensionRunner` and only exist once the loader
///      has run. A static array can't see them.
///
///   2. **reload safety**: the Lua-renderer path (F1c) needs the
///      runner pointer so it can look up the handler ref for the
///      active generation, not a stale slice captured at startup.
///
/// `interactive.zig` builds a resolver with `ctx = extension_runner_ref`
/// and a `resolve_fn` that consults both built-in entries and the
/// runner's tool registry. Tests build one with a fixed slice and no
/// extension runner.
pub const ToolRendererResolver = struct {
    ctx: ?*anyopaque = null,
    resolve_fn: *const fn (ctx: ?*anyopaque, tool_name: []const u8) ToolRenderer,

    pub fn resolve(self: *const ToolRendererResolver, tool_name: []const u8) ToolRenderer {
        return self.resolve_fn(self.ctx, tool_name);
    }

    /// Build a resolver backed by a static `[]const Registration`
    /// slice. Matches the old `ToolRendererRegistry.get` behavior
    /// and is what tests use.
    pub fn fromStatic(entries: *const []const Registration) ToolRendererResolver {
        const S = struct {
            fn resolveStatic(ctx: ?*anyopaque, tool_name: []const u8) ToolRenderer {
                const slice_ptr: *const []const Registration = @ptrCast(@alignCast(ctx.?));
                for (slice_ptr.*) |entry| {
                    if (std.mem.eql(u8, entry.tool_name, tool_name)) {
                        return entry.renderer;
                    }
                }
                return .{};
            }
        };
        return .{ .ctx = @ptrCast(@constCast(entries)), .resolve_fn = S.resolveStatic };
    }
};

/// Empty resolver — resolves nothing, all tools use fallbacks.
pub const empty_resolver = ToolRendererResolver{
    .ctx = null,
    .resolve_fn = struct {
        fn resolveNone(_: ?*anyopaque, _: []const u8) ToolRenderer {
            return .{};
        }
    }.resolveNone,
};
