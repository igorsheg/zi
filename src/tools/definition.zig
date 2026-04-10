const std = @import("std");
const protocol = @import("../agent/protocol.zig");

pub const RegistrationSource = struct {
    kind: []const u8,
    id: []const u8,
};

pub const BuiltinImpl = struct {
    ctx: ?*anyopaque = null,
    prepare_arguments: ?*const fn (allocator: std.mem.Allocator, args: std.json.Value) anyerror!std.json.Value = null,
    execute: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        args: std.json.Value,
        signal: protocol.AbortSignal,
        on_update: ?protocol.AgentToolUpdateCallback,
        update_ctx: ?*anyopaque,
    ) protocol.AgentToolResult,
};

pub const ToolImpl = union(enum) {
    builtin: BuiltinImpl,
    lua: c_int,
};

pub const ToolDefinition = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    prompt_snippet: ?[]const u8 = null,
    prompt_guidelines: []const []const u8 = &.{},
    impl: ToolImpl,
    source: RegistrationSource,
    render_result_ref: ?c_int = null,
};

pub fn toAgentTool(def: ToolDefinition) protocol.AgentTool {
    return switch (def.impl) {
        .builtin => |impl| .{
            .name = def.name,
            .description = def.description,
            .label = def.label,
            .parameters = def.parameters,
            .ctx = impl.ctx,
            .prepare_arguments = impl.prepare_arguments,
            .execute = impl.execute,
        },
        .lua => unreachable,
    };
}
