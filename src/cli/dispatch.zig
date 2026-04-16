const std = @import("std");
const help = @import("help.zig");
const list_models = @import("list_models.zig");
const run_batch = @import("run_batch.zig");
const run_interactive = @import("run_interactive.zig");
const context_mod = @import("context.zig");
const runtime_mod = @import("runtime.zig");
const result = @import("result.zig");
const plan = @import("plan.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

pub const Context = context_mod.Context;
pub const ExecutionResult = result.ExecutionResult;

pub fn run(ctx: Context, cli_runtime: ?*runtime_mod.Runtime, execution_plan: plan.ExecutionPlan) !ExecutionResult {
    switch (execution_plan) {
        .version => {
            var out_buf: [64]u8 = undefined;
            var out_writer = stdout.writer(&out_buf);
            try help.writeVersion(&out_writer.interface);
            try out_writer.end();
            return .ok;
        },
        .help => {
            var out_buf: [2048]u8 = undefined;
            var out_writer = stdout.writer(&out_buf);
            try help.writeGeneralHelp(&out_writer.interface);
            try out_writer.end();
            return .ok;
        },
        .list_models => |list_models_plan| return try list_models.run(ctx.allocator, requireRuntime(cli_runtime), list_models_plan),
        .run => |run_plan| switch (run_plan) {
            .batch => |batch| return try run_batch.run(requireRuntime(cli_runtime), batch),
            .interactive => |interactive| return try run_interactive.run(ctx, requireRuntime(cli_runtime), interactive),
        },
    }
}

fn requireRuntime(cli_runtime: ?*runtime_mod.Runtime) *runtime_mod.Runtime {
    return cli_runtime orelse unreachable;
}
