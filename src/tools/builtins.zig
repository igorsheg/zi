//! Built-in tool registry. Constructs the AgentTool slice the
//! AgentSession ships with by default: bash, read, write, edit, grep,
//! find, ls. The shared `BuiltinCtx` (cwd) is allocated once per
//! session and threaded into every tool's `ctx` slot.

const std = @import("std");
const protocol = @import("../agent/protocol.zig");
const util = @import("util.zig");

const bash_tool = @import("bash.zig");
const read_tool = @import("read.zig");
const write_tool = @import("write.zig");
const edit_tool = @import("edit.zig");
const grep_tool = @import("grep.zig");
const find_tool = @import("find.zig");
const ls_tool = @import("ls.zig");

pub const Bundle = struct {
    tools: []protocol.AgentTool,
    ctx: *util.BuiltinCtx,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Bundle) void {
        self.allocator.free(self.tools);
        self.allocator.destroy(self.ctx);
    }
};

/// Build the default tool set. Caller owns the returned `Bundle` and
/// must call `deinit` on session teardown. The `cwd` slice is borrowed,
/// not duped — the AgentSession's `options.cwd` outlives the bundle.
pub fn build(allocator: std.mem.Allocator, cwd: []const u8) !Bundle {
    const ctx = try allocator.create(util.BuiltinCtx);
    ctx.* = .{ .cwd = cwd };

    var tools = try allocator.alloc(protocol.AgentTool, 7);
    tools[0] = bash_tool.makeTool();
    tools[1] = read_tool.makeTool(ctx);
    tools[2] = write_tool.makeTool(ctx);
    tools[3] = edit_tool.makeTool(ctx);
    tools[4] = grep_tool.makeTool(ctx);
    tools[5] = find_tool.makeTool(ctx);
    tools[6] = ls_tool.makeTool(ctx);

    return .{ .tools = tools, .ctx = ctx, .allocator = allocator };
}
