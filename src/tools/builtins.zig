//! Built-in tool definitions. Constructs the canonical product-layer
//! tool definitions the AgentSession ships with by default: bash,
//! read, write, edit, grep, find, ls. The shared `BuiltinCtx` (cwd) is
//! allocated once per session and threaded into each builtin impl.

const std = @import("std");
const tool_def = @import("definition.zig");
const util = @import("util.zig");

const bash_tool = @import("bash.zig");
const read_tool = @import("read.zig");
const write_tool = @import("write.zig");
const edit_tool = @import("edit.zig");
const grep_tool = @import("grep.zig");
const find_tool = @import("find.zig");
const ls_tool = @import("ls.zig");

pub const Bundle = struct {
    definitions: []tool_def.ToolDefinition,
    ctx: *util.BuiltinCtx,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Bundle) void {
        self.allocator.free(self.definitions);
        self.allocator.destroy(self.ctx);
    }
};

/// Build the default tool definitions. Caller owns the returned
/// `Bundle` and must call `deinit` on session teardown. The `cwd`
/// slice is borrowed, not duped — the AgentSession's `options.cwd`
/// outlives the bundle.
pub fn build(allocator: std.mem.Allocator, cwd: []const u8) !Bundle {
    const ctx = try allocator.create(util.BuiltinCtx);
    ctx.* = .{ .cwd = cwd };

    var definitions = try allocator.alloc(tool_def.ToolDefinition, 7);
    definitions[0] = bash_tool.definition(ctx);
    definitions[1] = read_tool.definition(ctx);
    definitions[2] = write_tool.definition(ctx);
    definitions[3] = edit_tool.definition(ctx);
    definitions[4] = grep_tool.definition(ctx);
    definitions[5] = find_tool.definition(ctx);
    definitions[6] = ls_tool.definition(ctx);

    return .{ .definitions = definitions, .ctx = ctx, .allocator = allocator };
}
