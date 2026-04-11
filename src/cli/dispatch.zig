const std = @import("std");
const args = @import("args.zig");
const help = @import("help.zig");
const list_models = @import("list_models.zig");
const run_batch = @import("run_batch.zig");
const run_interactive = @import("run_interactive.zig");
const context_mod = @import("context.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

pub const Context = context_mod.Context;

pub fn run(ctx: Context, command: args.Command) !void {
    switch (command) {
        .version => try stdout.writeAll("zi v0.0.1\n"),
        .help => {
            var out_buf: [2048]u8 = undefined;
            var out_writer = stdout.writer(&out_buf);
            try help.writeGeneralHelp(&out_writer.interface);
            try out_writer.end();
        },
        .list_models => try list_models.run(ctx.allocator),
        .run => |options| {
            const has_prompt = options.print_mode or options.mode == .json or options.prompt_text != null;
            const is_continue = options.continue_path != null;
            if (has_prompt or is_continue) {
                try run_batch.run(ctx.allocator, options);
            } else {
                try run_interactive.run(ctx, options);
            }
        },
    }
}
