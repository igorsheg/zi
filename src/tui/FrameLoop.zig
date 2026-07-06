const std = @import("std");
const runtime = @import("../runtime/root.zig");
const render_policy = @import("render_policy.zig");
const loop_mod = @import("Loop.zig");
const InputPump = @import("InputPump.zig").InputPump;
const Terminal = @import("Terminal.zig");

pub const StepInputs = struct {
    now_ns: u64,
    width: u16,
    height: u16,
};

pub const StepResult = struct {
    rendered: bool,
    exit_requested: bool,
};

pub const RunStatus = enum { exit_requested, exhausted };

pub const RunResult = struct {
    status: RunStatus,
    iterations: usize,
    rendered_count: usize,
};
pub fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

pub fn step(
    runner: anytype,
    terminal: *Terminal,
    pump: *InputPump,
    inputs: StepInputs,
) !StepResult {
    const rendered = try runner.tick(terminal, pump, inputs.now_ns, inputs.width, inputs.height);
    return .{
        .rendered = rendered,
        .exit_requested = runner.loop.exit_requested,
    };
}

pub fn runBounded(
    runner: anytype,
    terminal: *Terminal,
    pump: *InputPump,
    inputs: StepInputs,
    max_iterations: usize,
) !RunResult {
    var rendered_count: usize = 0;
    for (0..max_iterations) |index| {
        const result = try step(runner, terminal, pump, inputs);
        if (result.rendered) rendered_count += 1;
        if (result.exit_requested) return .{
            .status = .exit_requested,
            .iterations = index + 1,
            .rendered_count = rendered_count,
        };
    }
    return .{
        .status = .exhausted,
        .iterations = max_iterations,
        .rendered_count = rendered_count,
    };
}

pub fn run(
    runner: anytype,
    terminal: *Terminal,
    pump: *InputPump,
    wake: *runtime.WakeEvent,
    io: std.Io,
) !RunResult {
    var iterations: usize = 0;
    var rendered_count: usize = 0;
    while (true) {
        wake.waitTimeout(io, nextTimeout(runner, io)) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return .{
                .status = .exit_requested,
                .iterations = iterations,
                .rendered_count = rendered_count,
            },
        };
        wake.reset();

        const iteration_start_ns = nowNs(io);
        const winsize = try terminal.winsize();
        const result = try step(runner, terminal, pump, .{
            .now_ns = iteration_start_ns,
            .width = winsize.cols,
            .height = winsize.rows,
        });
        const iteration_end_ns = nowNs(io);
        runner.loop.trace.recordIteration(iteration_end_ns -| iteration_start_ns);
        iterations += 1;
        if (result.rendered) rendered_count += 1;
        if (result.exit_requested) return .{
            .status = .exit_requested,
            .iterations = iterations,
            .rendered_count = rendered_count,
        };
    }
}

fn nextTimeout(runner: anytype, io: std.Io) std.Io.Timeout {
    const now_ns = nowNs(io);
    var deadline_ns: ?u64 = null;
    if (runner.loop.dirty) {
        deadline_ns = render_policy.nextRenderDueNsWithFloor(runner.loop.last_flush_ns, runner.loop.trace.renders.max_ns, loop_mod.frame_floor_ns);
    }
    const RunnerType = @TypeOf(runner.*);
    const timer_deadline = if (@hasDecl(RunnerType, "nextTimerDeadlineNs"))
        runner.nextTimerDeadlineNs()
    else
        runner.loop.nextTimerDeadlineNs();
    if (timer_deadline) |timer_deadline_ns| {
        deadline_ns = if (deadline_ns) |current| @min(current, timer_deadline_ns) else timer_deadline_ns;
    }
    const due_ns = deadline_ns orelse return .none;
    return .{ .duration = .{
        .raw = .fromNanoseconds(@intCast(due_ns -| now_ns)),
        .clock = .awake,
    } };
}

test "step reports rendered and exit state from runner" {
    const FakeRunner = struct {
        const LoopState = struct { exit_requested: bool = false };

        loop: LoopState = .{},
        rendered: bool = false,

        fn tick(
            self: *@This(),
            terminal: *Terminal,
            pump: *InputPump,
            now_ns: u64,
            width: u16,
            height: u16,
        ) !bool {
            _ = terminal;
            _ = pump;
            _ = now_ns;
            _ = width;
            _ = height;
            return self.rendered;
        }
    };

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var pump: InputPump = .{};
    var runner: FakeRunner = .{ .rendered = true };
    const result = try step(&runner, &terminal, &pump, .{
        .now_ns = 1,
        .width = 80,
        .height = 2,
    });

    try std.testing.expect(result.rendered);
    try std.testing.expect(!result.exit_requested);
}

test "bounded loop stops when runner exits" {
    const FakeRunner = struct {
        const LoopState = struct { exit_requested: bool = false };

        loop: LoopState = .{},
        calls: usize = 0,

        fn tick(
            self: *@This(),
            terminal: *Terminal,
            pump: *InputPump,
            now_ns: u64,
            width: u16,
            height: u16,
        ) !bool {
            _ = terminal;
            _ = pump;
            _ = now_ns;
            _ = width;
            _ = height;
            self.calls += 1;
            if (self.calls == 2) self.loop.exit_requested = true;
            return true;
        }
    };

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var pump: InputPump = .{};
    var runner: FakeRunner = .{};
    const result = try runBounded(&runner, &terminal, &pump, .{
        .now_ns = 1,
        .width = 80,
        .height = 2,
    }, 5);

    try std.testing.expectEqual(RunStatus.exit_requested, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.iterations);
    try std.testing.expectEqual(@as(usize, 2), result.rendered_count);
}

test "bounded loop returns exhausted at max iterations" {
    const FakeRunner = struct {
        const LoopState = struct { exit_requested: bool = false };

        loop: LoopState = .{},

        fn tick(
            self: *@This(),
            terminal: *Terminal,
            pump: *InputPump,
            now_ns: u64,
            width: u16,
            height: u16,
        ) !bool {
            _ = self;
            _ = terminal;
            _ = pump;
            _ = now_ns;
            _ = width;
            _ = height;
            return false;
        }
    };

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var pump: InputPump = .{};
    var runner: FakeRunner = .{};
    const result = try runBounded(&runner, &terminal, &pump, .{
        .now_ns = 1,
        .width = 80,
        .height = 2,
    }, 3);

    try std.testing.expectEqual(RunStatus.exhausted, result.status);
    try std.testing.expectEqual(@as(usize, 3), result.iterations);
    try std.testing.expectEqual(@as(usize, 0), result.rendered_count);
}
