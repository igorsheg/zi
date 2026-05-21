const std = @import("std");
const help = @import("help.zig");
const plan_mod = @import("plan.zig");
const run_batch = @import("run_batch.zig");
const cli_runtime = @import("runtime.zig");
const result_mod = @import("result.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: ?*cli_runtime.Runtime = null,
};

pub fn run(ctx: Context, plan: plan_mod.ExecutionPlan) !result_mod.ExecutionResult {
    return switch (plan) {
        .help => blk: {
            var buf: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
            try help.writeGeneral(&writer.interface);
            try writer.interface.flush();
            break :blk .ok;
        },
        .version => blk: {
            var buf: [128]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
            try help.writeVersion(&writer.interface);
            try writer.interface.flush();
            break :blk .ok;
        },
        .tui => .{ .err = .tui_unavailable },
        .run => |run_plan| try run_batch.run(.{ .allocator = ctx.allocator, .io = ctx.io, .runtime = ctx.runtime }, run_plan),
    };
}
