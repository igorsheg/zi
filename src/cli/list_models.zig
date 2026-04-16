const std = @import("std");
const ai = @import("../ai/root.zig");
const runtime_mod = @import("runtime.zig");
const result = @import("result.zig");
const plan = @import("plan.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };

pub fn run(
    allocator: std.mem.Allocator,
    runtime: *runtime_mod.Runtime,
    options: plan.ListModelsPlan,
) !result.ExecutionResult {
    const models = if (options.available_only)
        try runtime.model_registry.getAvailable(allocator)
    else
        &.{};
    defer if (options.available_only) allocator.free(models);

    const to_print = if (options.available_only) models else runtime.model_registry.getAll();
    for (to_print) |m| {
        stdout.writeAll(ai.provider.apiToString(m.api)) catch {};
        stdout.writeAll("\t") catch {};
        stdout.writeAll(m.id) catch {};
        stdout.writeAll("\t") catch {};
        stdout.writeAll(m.name) catch {};
        stdout.writeAll("\n") catch {};
    }

    return .ok;
}
