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

    const log_options = buildLoggingOptions(allocator, init.io, execution_plan);
    var log_session = try logging.init(allocator, log_options);
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
        .help, .version, .docs, .man => false,
        .list_models, .run => true,
    };
}

fn buildLoggingOptions(allocator: std.mem.Allocator, io: std.Io, execution_plan: cli.plan.ExecutionPlan) logging.InitOptions {
    var sinks = defaultSinksForPlan(execution_plan);
    var min_level: std.log.Level = .info;

    _ = allocator;
    if (env.get("ZI_LOG_LEVEL")) |value| {
        min_level = parseLogLevel(value) orelse min_level;
    }

    if (env.get("ZI_LOG_SINK")) |value| {
        sinks = parseLogSinks(value);
    }

    if (env.get("ZI_LOG_FILE")) |value| {
        sinks.file = true;
        sinks.file_path = value;
    }

    return .{
        .io = io,
        .sinks = sinks,
        .min_level = min_level,
    };
}

fn defaultSinksForPlan(execution_plan: cli.plan.ExecutionPlan) logging.SinkOptions {
    return switch (execution_plan) {
        .help, .version, .docs, .man, .list_models => .{},
        .run => .{ .file = true },
    };
}

fn parseLogLevel(value: []const u8) ?std.log.Level {
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
    return null;
}

fn parseLogSinks(value: []const u8) logging.SinkOptions {
    var sinks: logging.SinkOptions = .{};
    var it = std.mem.tokenizeScalar(u8, value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(part, "file")) sinks.file = true else if (std.ascii.eqlIgnoreCase(part, "stderr")) sinks.stderr = true else if (std.ascii.eqlIgnoreCase(part, "both")) {
            sinks.file = true;
            sinks.stderr = true;
        } else if (std.ascii.eqlIgnoreCase(part, "off") or std.ascii.eqlIgnoreCase(part, "disabled")) {
            sinks = .{};
        }
    }
    return sinks;
}
