const std = @import("std");
const terminal_mod = @import("tui/terminal.zig");
const memory_debug = @import("debug/tracked_allocator.zig");
const logging = @import("logging.zig");
const cli = @import("coding_agent/cli/root.zig");

/// Restore terminal on panic (raw mode, cursor, keyboard protocol).
pub const panic = terminal_mod.panic;
pub const std_options: std.Options = .{
    .logFn = logging.logFn,
};

const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn main() !void {
    logging.setThreadLabel(.main);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var root_tracker = memory_debug.TrackedAllocator.init("root", gpa.allocator(), gpa.allocator());
    defer root_tracker.deinit();
    var agent_backing_tracker = memory_debug.TrackedAllocator.init("agent_backing", root_tracker.allocator(), root_tracker.allocator());
    defer agent_backing_tracker.deinit();
    var tui_backing_tracker = memory_debug.TrackedAllocator.init("tui_backing", root_tracker.allocator(), root_tracker.allocator());
    defer tui_backing_tracker.deinit();
    var msg_backing_tracker = memory_debug.TrackedAllocator.init("msg_backing", root_tracker.allocator(), root_tracker.allocator());
    defer msg_backing_tracker.deinit();

    // zi-wub.12: dedicated arena owned by the agent thread. Single
    // owner during steady state — TUI thread only touches it during
    // pre-spawn init (auth, settings, ca creation) and post-join
    // deinit, never concurrently with the agent thread. Cross-thread
    // payloads route through msg_allocator (zi-wub.9/.10), while the
    // TUI keeps local state on its own tracked allocator/backing
    // tracker (zi-wub.11), so the ThreadSafeAllocator band-aid (.13)
    // is no longer needed.
    var agent_arena = std.heap.ArenaAllocator.init(agent_backing_tracker.allocator());
    defer agent_arena.deinit();
    const allocator = agent_arena.allocator();

    // Dedicated thread-safe GPA for cross-thread mailbox payloads
    // and mailbox backing storage (event queue, request queue,
    // converted agent events, login callbacks). Wraps the
    // ROOT GPA directly — NOT the arena — so producer/consumer pairs
    // can free individually and we don't pin growing payloads in the
    // arena's lifetime. See `docs/runtime.md` for the ownership rule
    // behind this split.
    var ts_msg: std.heap.ThreadSafeAllocator = .{ .child_allocator = msg_backing_tracker.allocator() };
    const msg_allocator = ts_msg.allocator();

    var raw_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer raw_args.deinit(allocator);

    var process_args = std.process.args();
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
        .sink_mode = sinkModeForPlan(execution_plan),
    });
    defer log_session.deinit();

    var cli_runtime: ?cli.runtime.Runtime = null;
    defer if (cli_runtime) |*runtime| runtime.deinit();

    if (planRequiresRuntime(execution_plan)) {
        cli_runtime = switch (try cli.runtime.Runtime.init(allocator)) {
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
        .root_tracker = &root_tracker,
        .agent_backing_tracker = &agent_backing_tracker,
        .tui_backing_tracker = &tui_backing_tracker,
        .msg_backing_tracker = &msg_backing_tracker,
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
    var err_writer = stderr.writer(&err_buf);
    try cli.diagnostics.writeParseDiagnostic(&err_writer.interface, diag);
    try err_writer.end();
}

fn writePlanDiagnostic(diag: cli.plan.PlanDiagnostic) !void {
    var err_buf: [1024]u8 = undefined;
    var err_writer = stderr.writer(&err_buf);
    try cli.diagnostics.writePlanDiagnostic(&err_writer.interface, diag);
    try err_writer.end();
}

fn writeRuntimeInitDiagnostic(diag: cli.runtime.InitDiagnostic) !void {
    var err_buf: [1024]u8 = undefined;
    var err_writer = stderr.writer(&err_buf);
    try cli.diagnostics.writeRuntimeInitDiagnostic(&err_writer.interface, diag);
    try err_writer.end();
}

fn writeExecutionDiagnostic(diag: cli.result.ExecutionDiagnostic) !void {
    var err_buf: [1024]u8 = undefined;
    var err_writer = stderr.writer(&err_buf);
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
