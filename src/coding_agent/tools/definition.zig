const std = @import("std");
const protocol = @import("../../agent3/types.zig");
const json_value = @import("../../json/value.zig");
const resource_types = @import("../resources/types.zig");

pub const RegistrationSource = struct {
    kind: []const u8,
    id: []const u8,
    provenance: ?resource_types.ExtensionProvenance = null,
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
    owned: bool = false,
};

pub fn cloneOwned(allocator: std.mem.Allocator, def: ToolDefinition) !ToolDefinition {
    const name = try allocator.dupe(u8, def.name);
    errdefer allocator.free(name);

    const label = try allocator.dupe(u8, def.label);
    errdefer allocator.free(label);

    const description = try allocator.dupe(u8, def.description);
    errdefer allocator.free(description);

    const parameters = try json_value.cloneJsonValue(allocator, def.parameters);
    errdefer json_value.freeJsonValue(allocator, parameters);

    const prompt_snippet = if (def.prompt_snippet) |snippet|
        try allocator.dupe(u8, snippet)
    else
        null;
    errdefer if (prompt_snippet) |snippet| allocator.free(snippet);

    const prompt_guidelines = if (def.prompt_guidelines.len == 0)
        &.{}
    else blk: {
        const owned = try allocator.alloc([]const u8, def.prompt_guidelines.len);
        errdefer allocator.free(owned);
        var i: usize = 0;
        errdefer {
            for (owned[0..i]) |guideline| allocator.free(guideline);
        }
        for (def.prompt_guidelines) |guideline| {
            owned[i] = try allocator.dupe(u8, guideline);
            i += 1;
        }
        break :blk owned;
    };

    return .{
        .name = name,
        .label = label,
        .description = description,
        .parameters = parameters,
        .prompt_snippet = prompt_snippet,
        .prompt_guidelines = prompt_guidelines,
        .impl = def.impl,
        .source = def.source,
        .render_result_ref = def.render_result_ref,
        .owned = true,
    };
}

pub fn freeOwned(allocator: std.mem.Allocator, def: *ToolDefinition) void {
    if (!def.owned) return;
    allocator.free(def.name);
    allocator.free(def.label);
    allocator.free(def.description);
    if (def.prompt_snippet) |snippet| allocator.free(snippet);
    for (def.prompt_guidelines) |guideline| allocator.free(guideline);
    if (def.prompt_guidelines.len > 0) allocator.free(def.prompt_guidelines);
    json_value.freeJsonValue(allocator, def.parameters);
    def.owned = false;
}

pub fn toAgentTool(def: ToolDefinition) protocol.AgentTool {
    return switch (def.impl) {
        .builtin => |impl| .{
            .name = def.name,
            .description = def.description,
            .label = def.label,
            .parameters = def.parameters,
            .ctx = impl.ctx,
            .affinity = .worker_thread,
            .prepare_arguments = impl.prepare_arguments,
            .execute = impl.execute,
        },
        .lua => unreachable,
    };
}
