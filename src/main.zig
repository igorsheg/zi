const std = @import("std");
const terminal_mod = @import("tui/terminal/mod.zig");
const logging = @import("logging.zig");
const cli = @import("coding_agent/cli/root.zig");
const runtime_app = @import("runtime/app.zig");
const env = @import("env");

/// Restore terminal on panic (raw mode, cursor, keyboard protocol).
pub const panic = terminal_mod.panic;
pub const std_options: std.Options = .{
    .logFn = logging.logFn,
};

const stderr: std.Io.File = .{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };

pub fn main(init: std.process.Init) !void {
    env.setProcessEnvironment(init.environ_map);
    logging.setThreadLabel(.main);

    var main_heap: runtime_app.MainHeap = .{};
    defer main_heap.deinit();

    const heap_allocator = main_heap.allocator();

    const allocator = heap_allocator;
    const msg_allocator = std.heap.smp_allocator;

    var raw_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer raw_args.deinit(allocator);

    var process_args = std.process.Args.Iterator.init(init.minimal.args);
    _ = process_args.next();
    while (process_args.next()) |arg| {
        try raw_args.append(allocator, arg);
    }

    const action = cli.action.Action.detect(raw_args.items);
    var raw_command = switch (try cli.parse.parse(allocator, action, raw_args.items)) {
        .ok => |cmd| cmd,
        .err => |diag| {
            try writeParseDiagnostic(diag);
            std.process.exit(1);
        },
    };
    defer raw_command.deinit(allocator);

    const piped_stdin = switch (raw_command) {
        .run => |run| if (run.print_mode or run.mode != null)
            try cli.stdin.readPipedStdin(allocator)
        else
            null,
        else => null,
    };

    const execution_plan = switch (try cli.plan.build(allocator, raw_command, .{ .piped_stdin = piped_stdin })) {
        .ok => |plan| plan,
        .err => |diag| {
            try writePlanDiagnostic(diag);
            std.process.exit(1);
        },
    };

    var log_session = try logging.init(allocator, .{
        .io = init.io,
        .sink_mode = sinkModeForPlan(execution_plan),
    });
    defer log_session.deinit();

    var cli_runtime: ?cli.runtime.Runtime = null;
    defer if (cli_runtime) |*runtime| runtime.deinit();

    if (planRequiresRuntime(execution_plan)) {
        cli_runtime = switch (try cli.runtime.Runtime.init(allocator, init.io)) {
            .ok => |runtime| runtime,
            .err => |diag| {
                try writeRuntimeInitDiagnostic(diag);
                std.process.exit(1);
            },
        };
    }

    const execution_result = try cli.dispatch.run(.{
        .allocator = allocator,
        .msg_allocator = msg_allocator,
    }, if (cli_runtime) |*runtime| runtime else null, execution_plan);
    switch (execution_result) {
        .ok => {},
        .err => |diag| {
            try writeExecutionDiagnostic(diag);
            std.process.exit(1);
        },
    }
}

fn writeParseDiagnostic(diag: cli.parse.ParseDiagnostic) !void {
    var err_buf: [1024]u8 = undefined;
    var err_writer = stderr.writer(std.Options.debug_io, &err_buf);
    try cli.diagnostics.writeParseDiagnostic(&err_writer.interface, diag);
    try err_writer.end();
}

fn writePlanDiagnostic(diag: cli.plan.PlanDiagnostic) !void {
    var err_buf: [1024]u8 = undefined;
    var err_writer = stderr.writer(std.Options.debug_io, &err_buf);
    try cli.diagnostics.writePlanDiagnostic(&err_writer.interface, diag);
    try err_writer.end();
}

fn writeRuntimeInitDiagnostic(diag: cli.runtime.InitDiagnostic) !void {
    var err_buf: [1024]u8 = undefined;
    var err_writer = stderr.writer(std.Options.debug_io, &err_buf);
    try cli.diagnostics.writeRuntimeInitDiagnostic(&err_writer.interface, diag);
    try err_writer.end();
}

fn writeExecutionDiagnostic(diag: cli.result.ExecutionDiagnostic) !void {
    var err_buf: [1024]u8 = undefined;
    var err_writer = stderr.writer(std.Options.debug_io, &err_buf);
    try cli.diagnostics.writeExecutionDiagnostic(&err_writer.interface, diag);
    try err_writer.end();
}

fn planRequiresRuntime(execution_plan: cli.plan.ExecutionPlan) bool {
    return switch (execution_plan) {
        .help, .version => false,
        .list_models, .run => true,
    };
}

fn sinkModeForPlan(execution_plan: cli.plan.ExecutionPlan) logging.SinkMode {
    return switch (execution_plan) {
        .help, .version, .list_models => .disabled,
        .run => .file_only,
    };
}
