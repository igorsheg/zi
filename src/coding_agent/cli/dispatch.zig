const std = @import("std");
const help = @import("help.zig");
const plan_mod = @import("plan.zig");
const run_batch = @import("run_batch.zig");
const result_mod = @import("result.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
};

pub fn run(ctx: Context, plan: plan_mod.ExecutionPlan) !result_mod.ExecutionResult {
    return switch (plan) {
        .help => blk: {
            var buf: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(ctx.io, &buf);
            try help.writeGeneral(&writer.interface);
            try writer.end();
            break :blk .ok;
        },
        .version => blk: {
            var buf: [128]u8 = undefined;
            var writer = std.Io.File.stdout().writer(ctx.io, &buf);
            try help.writeVersion(&writer.interface);
            try writer.end();
            break :blk .ok;
        },
        .run => |run_plan| try run_batch.run(.{ .allocator = ctx.allocator, .io = ctx.io }, run_plan),
    };
}
