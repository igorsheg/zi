//! Built-in tool definitions. Constructs the canonical product-layer
//! tool definitions the AgentSession ships with by default: bash,
//! read, write, edit, patch, grep, find, ls. The shared `BuiltinCtx` (cwd) is
//! allocated once per session and threaded into each builtin impl.

const std = @import("std");
const tool_def = @import("definition.zig");
const util = @import("util.zig");

const bash_tool = @import("bash.zig");
const read_tool = @import("read.zig");
const write_tool = @import("write.zig");
const edit_tool = @import("edit.zig");
const patch_tool = @import("patch.zig");
const grep_tool = @import("grep.zig");
const find_tool = @import("find.zig");
const ls_tool = @import("ls.zig");

pub const Bundle = struct {
    definitions: []tool_def.ToolDefinition,
    ctx: *util.BuiltinCtx,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Bundle) void {
        self.allocator.free(self.definitions);
        self.ctx.deinit(self.allocator);
        self.allocator.destroy(self.ctx);
    }
};

pub const BuildOptions = struct {
    io: std.Io = std.Options.debug_io,
    image_auto_resize: bool = true,
};

/// Build the default tool definitions. Caller owns the returned
/// `Bundle` and must call `deinit` on session teardown. The `cwd`
/// is copied so worker-thread tool executions never depend on a borrowed
/// session/bootstrap path slice staying alive.
pub fn build(allocator: std.mem.Allocator, cwd: []const u8, options: BuildOptions) !Bundle {
    const ctx = try allocator.create(util.BuiltinCtx);
    errdefer allocator.destroy(ctx);
    const owned_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(owned_cwd);
    ctx.* = .{ .cwd = owned_cwd, .owns_cwd = true, .io = options.io, .image_auto_resize = options.image_auto_resize };

    var definitions = try allocator.alloc(tool_def.ToolDefinition, 8);
    definitions[0] = bash_tool.definition(ctx);
    definitions[1] = read_tool.definition(ctx);
    definitions[2] = write_tool.definition(ctx);
    definitions[3] = edit_tool.definition(ctx);
    definitions[4] = patch_tool.definition(ctx);
    definitions[5] = grep_tool.definition(ctx);
    definitions[6] = find_tool.definition(ctx);
    definitions[7] = ls_tool.definition(ctx);

    return .{ .definitions = definitions, .ctx = ctx, .allocator = allocator };
}
