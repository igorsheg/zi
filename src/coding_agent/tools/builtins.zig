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

pub fn build(allocator: std.mem.Allocator, cwd: []const u8, options: BuildOptions) !Bundle {
    const ctx = try allocator.create(util.BuiltinCtx);
    errdefer allocator.destroy(ctx);
    const owned_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(owned_cwd);
    const observations = @import("observations.zig");
    ctx.* = .{ .cwd = owned_cwd, .owns_cwd = true, .io = options.io, .image_auto_resize = options.image_auto_resize, .observations = observations.Store.init(allocator), .observation_events = observations.PendingEvents.init(allocator) };

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
