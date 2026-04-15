const std = @import("std");
const help = @import("help.zig");
const list_models = @import("list_models.zig");
const run_batch = @import("run_batch.zig");
const run_interactive = @import("run_interactive.zig");
const context_mod = @import("context.zig");
const plan = @import("plan.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

pub const Context = context_mod.Context;

pub fn run(ctx: Context, execution_plan: plan.ExecutionPlan) !void {
    switch (execution_plan) {
        .version => try stdout.writeAll("zi v0.0.1\n"),
        .help => {
            var out_buf: [2048]u8 = undefined;
            var out_writer = stdout.writer(&out_buf);
            try help.writeGeneralHelp(&out_writer.interface);
            try out_writer.end();
        },
        .list_models => try list_models.run(ctx.allocator),
        .run => |run_plan| switch (run_plan) {
            .batch => |batch| try run_batch.run(ctx.allocator, batch),
            .interactive => |interactive| try run_interactive.run(ctx, interactive),
        },
    }
}
