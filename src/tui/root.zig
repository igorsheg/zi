const std = @import("std");
const builtin = @import("builtin");
const app_info = @import("../app_info.zig");
const coding_agent = @import("../coding_agent/root.zig");
const paths_mod = @import("../coding_agent/paths.zig");
const runtime = @import("../runtime/root.zig");

const InputPumpMod = @import("InputPump.zig");
pub const Editor = @import("Editor.zig");
pub const FrameLoop = @import("FrameLoop.zig");
pub const InputDecoder = @import("InputDecoder.zig");
pub const InputPump = InputPumpMod.InputPump;
pub const Terminal = @import("Terminal.zig");
pub const blocks = @import("blocks.zig");
pub const chrome = @import("chrome.zig");
pub const input = @import("input.zig");
pub const layout = @import("layout.zig");
pub const markdown = @import("markdown.zig");
pub const loop = @import("Loop.zig");
pub const render_policy = @import("render_policy.zig");
pub const screen = @import("screen.zig");
pub const theme = @import("theme.zig");
pub const trace = @import("trace.zig");
pub const testing = @import("testing/pty_harness.zig");
pub const Transcript = @import("Transcript.zig");
pub const Loop = loop.Loop;

pub const Options = struct {
    initial_prompt: ?[]const u8,
    open: coding_agent.session_bootstrap.OpenSpec,
    resume_picker: bool,
    panic_test: bool = false,
};
pub const Runner = struct {
    loop: Loop,
    decoder: InputDecoder = .{},
    layout: theme.LayoutEpoch = .{ .width = 0, .height = 0 },
    open: coding_agent.session_bootstrap.OpenSpec,
    resume_picker: bool,
    observed_dropped_input_bytes: usize = 0,
    pending_input_read_ns: [InputPumpMod.stamp_capacity]u64 = undefined,
    pending_input_read_len: usize = 0,

    lone_escape_deadline_ns: ?u64 = null,
    pub fn init(allocator: std.mem.Allocator, options: Options) !Runner {
        return .{
            .loop = try Loop.init(allocator, options.initial_prompt),
            .open = options.open,
            .resume_picker = options.resume_picker,
        };
    }

    pub fn deinit(self: *Runner) void {
        self.loop.deinit();
    }

    pub fn composeInitialFrame(self: *Runner, width: u16, height: u16) anyerror!screen.Frame {
        return self.loop.composeFrame(width, height);
    }

    pub fn feedInputBytes(self: *Runner, bytes: []const u8) InputDecoder.Error!void {
        try self.decoder.feed(bytes);
    }

    pub fn drainInputActions(self: *Runner) !void {
        try self.drainInputActionsAt(0);
    }

    pub fn drainInputActionsAt(self: *Runner, now_ns: u64) !void {
        try self.drainInputActionsWithTerminal(null, now_ns);
    }

    fn drainInputActionsWithTerminal(self: *Runner, terminal: ?*Terminal, now_ns: u64) !void {
        while (try self.decoder.nextActionWithTerminal(terminal)) |action| {
            try self.loop.dispatchAt(action, now_ns);
        }
    }

    pub fn nextTimerDeadlineNs(self: *const Runner) ?u64 {
        var deadline = self.loop.nextTimerDeadlineNs();
        if (self.lone_escape_deadline_ns) |esc_deadline| {
            deadline = if (deadline) |current| @min(current, esc_deadline) else esc_deadline;
        }
        return deadline;
    }
    pub fn drainInputPump(self: *Runner, pump: *InputPump) !void {
        try self.drainInputPumpAt(pump, 0);
    }

    pub fn drainInputPumpAt(self: *Runner, pump: *InputPump, now_ns: u64) !void {
        const dropped = pump.droppedByteCount();
        if (dropped > self.observed_dropped_input_bytes) {
            self.loop.trace.addDroppedInputBytes(dropped - self.observed_dropped_input_bytes);
            self.observed_dropped_input_bytes = dropped;
        }

        var batch: [InputDecoder.drain_capacity]u8 = undefined;
        const len = pump.drainBytes(&batch);
        self.collectConsumedInputStamps(pump);
        if (len > 0) {
            self.loop.recordInputBytes(len);
            self.feedInputBytes(batch[0..len]) catch |err| switch (err) {
                error.DecoderFull, error.ActionTextTooLong => return self.dropOversizeInput(len),
            };
            self.drainInputActionsAt(now_ns) catch |err| switch (err) {
                error.DecoderFull, error.ActionTextTooLong => return self.dropOversizeInput(len),
                else => return err,
            };
        }
        self.updateLoneEscapeDeadline(now_ns);
    }

    fn drainInputPumpForTick(self: *Runner, pump: *InputPump, terminal: *Terminal, now_ns: u64) !void {
        const dropped = pump.droppedByteCount();
        if (dropped > self.observed_dropped_input_bytes) {
            self.loop.trace.addDroppedInputBytes(dropped - self.observed_dropped_input_bytes);
            self.observed_dropped_input_bytes = dropped;
        }

        var batch: [InputDecoder.drain_capacity]u8 = undefined;
        const len = pump.drainBytes(&batch);
        self.collectConsumedInputStamps(pump);
        if (len > 0) {
            self.loop.recordInputBytes(len);
            self.feedInputBytes(batch[0..len]) catch |err| switch (err) {
                error.DecoderFull, error.ActionTextTooLong => return self.dropOversizeInput(len),
            };
            self.drainInputActionsWithTerminal(terminal, now_ns) catch |err| switch (err) {
                error.DecoderFull, error.ActionTextTooLong => return self.dropOversizeInput(len),
                else => return err,
            };
        }
        self.updateLoneEscapeDeadline(now_ns);
    }

    fn dropOversizeInput(self: *Runner, count: usize) !void {
        self.decoder.reset();
        self.loop.trace.addDroppedInputBytes(count);
        try self.loop.notice(.warn, "input too large");
    }

    fn updateLoneEscapeDeadline(self: *Runner, now_ns: u64) void {
        if (self.decoder.needsEscapeDeadline()) {
            if (self.lone_escape_deadline_ns == null) self.lone_escape_deadline_ns = now_ns +| InputDecoder.lone_escape_timeout_ns;
        } else {
            self.lone_escape_deadline_ns = null;
        }
    }

    fn expireLoneEscapeIfDue(self: *Runner, now_ns: u64) !void {
        if (self.lone_escape_deadline_ns) |deadline| {
            if (now_ns >= deadline) {
                self.lone_escape_deadline_ns = null;
                try self.loop.dispatchAt(self.decoder.expireLoneEscape(), now_ns);
            }
        }
    }

    fn collectConsumedInputStamps(self: *Runner, pump: *InputPump) void {
        var stamps: [InputPumpMod.stamp_capacity]InputPumpMod.BatchStamp = undefined;
        const count = pump.drainConsumedStamps(&stamps);
        for (stamps[0..count]) |stamp| {
            if (self.pending_input_read_len == self.pending_input_read_ns.len) {
                std.mem.copyForwards(u64, self.pending_input_read_ns[0 .. self.pending_input_read_len - 1], self.pending_input_read_ns[1..self.pending_input_read_len]);
                self.pending_input_read_len -= 1;
            }
            self.pending_input_read_ns[self.pending_input_read_len] = stamp.read_ns;
            self.pending_input_read_len += 1;
        }
    }

    fn recordPendingInputLatencies(self: *Runner, flush_complete_ns: u64) void {
        for (self.pending_input_read_ns[0..self.pending_input_read_len]) |read_ns| {
            self.loop.trace.recordInputLatency(read_ns, flush_complete_ns);
        }
        self.pending_input_read_len = 0;
    }

    pub fn applyResize(self: *Runner, width: u16, height: u16) bool {
        const changed = self.layout.resize(width, height);
        if (changed) self.loop.dirty = true;
        return changed;
    }

    pub fn paintInitialFrame(self: *Runner, terminal: *Terminal, width: u16, height: u16) !void {
        const frame = try self.loop.composeFrame(width, height);
        try terminal.paint(frame);
        self.loop.markRendered(0, 0);
    }

    pub fn tick(
        self: *Runner,
        terminal: *Terminal,
        pump: *InputPump,
        now_ns: u64,
        width: u16,
        height: u16,
    ) !bool {
        const input_actions_before = self.loop.trace.input_actions;
        try self.drainInputPumpForTick(pump, terminal, now_ns);
        try self.expireLoneEscapeIfDue(now_ns);
        try self.loop.pumpDriver(now_ns);
        try self.loop.tick(now_ns);
        const had_input = self.loop.trace.input_actions != input_actions_before;
        var render_width = width;
        var render_height = height;
        var resized = false;
        if (pump.takeResize()) {
            try terminal.resizeFromTty();
            const resized_winsize = try terminal.winsize();
            render_width = resized_winsize.cols;
            render_height = resized_winsize.rows;
            resized = self.applyResize(render_width, render_height);
        }
        if (!had_input and !resized and !self.loop.shouldRender(now_ns)) return false;
        const start_ns = FrameLoop.nowNs(terminal.io);
        const frame = try self.loop.composeFrame(render_width, render_height);
        try terminal.paint(frame);
        const flush_complete_ns = FrameLoop.nowNs(terminal.io);
        self.recordPendingInputLatencies(flush_complete_ns);
        self.loop.markRendered(now_ns, flush_complete_ns -| start_ns);
        return true;
    }
};

pub fn run(process: runtime.Process, options: Options) !void {
    if (builtin.is_test) return error.UnsupportedCliFeature;

    var task_runtime = try runtime.Runtime.init(process.gpa, .{});
    defer task_runtime.deinit();

    const agent_dir = try paths_mod.resolveGlobalAgentDirFromEnv(process.gpa, process.environ);
    defer process.gpa.free(agent_dir);

    var services = try coding_agent.runtime_services.RuntimeServices.init(process.gpa, .{
        .cwd = ".",
        .agent_dir = agent_dir,
        .environ = process.environ,
        .task_runtime = task_runtime,
    });
    defer services.deinit();

    const stamp = coding_agent.session_manager.SessionStamp.now(services.io);
    var session = try coding_agent.session_bootstrap.openSession(process.gpa, &services, stamp.date(), options.open, .{});

    var runner = try Runner.init(process.gpa, options);
    defer runner.deinit();
    _ = try session.agent.subscribe(.{ .context = &runner.loop.transcript, .call_fn = Transcript.applyListener });
    if (process.env("ZI_TUI_SYNTHETIC_ITEMS")) |value| {
        const count = std.fmt.parseInt(usize, value, 10) catch 0;
        try runner.loop.seedSyntheticItems(count);
    }
    if (process.env("ZI_TUI_SYNTHETIC_TOOLS")) |value| {
        const count = std.fmt.parseInt(usize, value, 10) catch 0;
        try runner.loop.seedSyntheticTools(services.io, count);
    }
    if (process.env("ZI_TUI_SYNTHETIC_FLOOD") != null) runner.loop.enableSyntheticFlood(FrameLoop.nowNs(services.io));
    defer writeTraceIfRequested(process, &runner.loop.trace) catch {};

    var terminal: Terminal = undefined;
    try terminal.init(process.gpa, services.io, process.environ);
    errdefer terminal.deinit();
    try terminal.setup();
    try terminal.setTitle("zi - " ++ app_info.version);

    var pump: InputPump = .{};
    var wake: runtime.WakeEvent = .init;
    runner.loop.bindSession(&session, services.io, &wake);
    defer shutdownSession(&session, &runner.loop, services.io, &wake);
    defer terminal.deinit();
    try pump.startTerminal(services.io, &terminal, &wake);
    defer pump.join();
    defer pump.requestStop();

    if (options.panic_test) {
        try runtime.sleep(services.io, .fromSeconds(1));
        @panic("zi --panic-test");
    }

    _ = try FrameLoop.run(&runner, &terminal, &pump, &wake, services.io);
}

fn shutdownSession(session: *coding_agent.AgentSession, owner_loop: *Loop, io: std.Io, wake: *runtime.WakeEvent) void {
    owner_loop.shutdownDriver();
    session.requestShutdown();
    const start = FrameLoop.nowNs(io);
    while (!session.shutdownComplete() and FrameLoop.nowNs(io) -| start < loop.shutdown_cancel_bound_ns) {
        wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
        wake.reset();
    }
    session.deinit();
}

fn writeTraceIfRequested(process: runtime.Process, stats: *const trace.Stats) !void {
    const explicit_path = process.env("ZI_TUI_TRACE_FILE");
    if (explicit_path == null and process.env("ZI_TUI_TRACE") == null) return;
    const path = if (explicit_path) |value| value else blk: {
        const tmp_dir = process.env("TMPDIR") orelse "/tmp";
        const stamp = coding_agent.session_manager.SessionStamp.now(process.io);
        const file_name = try std.fmt.allocPrint(process.gpa, "zi-tui-trace-{d}.log", .{stamp.nanoseconds});
        defer process.gpa.free(file_name);
        break :blk try std.fs.path.join(process.gpa, &.{ tmp_dir, file_name });
    };
    defer if (explicit_path == null) process.gpa.free(path);

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try stats.writeReport(&writer);
    try std.Io.Dir.writeFile(.cwd(), process.io, .{ .sub_path = path, .data = writer.buffered() });
}

pub const BoundedRunForTestResult = struct {
    result: FrameLoop.RunResult,
    render_count: usize,
    exit_requested: bool,
    trace_report: [1024]u8 = undefined,
    trace_report_len: usize = 0,

    pub fn traceReport(self: *const BoundedRunForTestResult) []const u8 {
        return self.trace_report[0..self.trace_report_len];
    }
};

fn boundedRunResult(runner: *const Runner, result: FrameLoop.RunResult) !BoundedRunForTestResult {
    var out: BoundedRunForTestResult = .{
        .result = result,
        .render_count = runner.loop.trace.renders.count,
        .exit_requested = runner.loop.exit_requested,
    };
    var writer = std.Io.Writer.fixed(&out.trace_report);
    try runner.loop.trace.writeReport(&writer);
    out.trace_report_len = writer.buffered().len;
    return out;
}

fn runBoundedForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    options: Options,
    input_bytes: []const u8,
    max_iterations: usize,
) !BoundedRunForTestResult {
    var terminal: Terminal = undefined;
    try terminal.init(allocator, io, env);
    defer terminal.deinit();

    var runner = try Runner.init(allocator, options);
    var pump: InputPump = .{};
    if (input_bytes.len > 0 and !pump.pushBatch(input_bytes, 0)) return error.InputTooLarge;

    const result = try FrameLoop.runBounded(&runner, &terminal, &pump, .{
        .now_ns = loop.frame_floor_ns,
        .width = 80,
        .height = 2,
    }, max_iterations);

    return try boundedRunResult(&runner, result);
}

fn runBoundedWithWorkerForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    options: Options,
    source_context: *anyopaque,
    read_fn: @import("InputPump.zig").ReadFn,
    max_iterations: usize,
) !BoundedRunForTestResult {
    var terminal: Terminal = undefined;
    try terminal.init(allocator, io, env);
    defer terminal.deinit();

    var runner = try Runner.init(allocator, options);
    var pump: InputPump = .{};
    var wake: runtime.WakeEvent = .init;
    try pump.start(.{
        .io = io,
        .wake = &wake,
        .source_context = source_context,
        .read_fn = read_fn,
    });
    defer pump.join();
    defer pump.requestStop();

    try wake.waitTimeout(io, .{ .duration = .{
        .raw = .fromMilliseconds(1000),
        .clock = .awake,
    } });
    wake.reset();

    const result = try FrameLoop.runBounded(&runner, &terminal, &pump, .{
        .now_ns = loop.frame_floor_ns,
        .width = 80,
        .height = 2,
    }, max_iterations);

    return try boundedRunResult(&runner, result);
}

test "run exposes the P1 TUI owner boundary" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expectError(error.UnsupportedCliFeature, run(.{
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = &environ,
    }, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    }));
}

test "runner seeds initial prompt and composes first frame" {
    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = "draft",
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    const frame = try runner.composeInitialFrame(80, 2);

    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("> draft", frame.rows()[1].copyText(&buffer));
    try std.testing.expectEqual(@as(usize, 0), runner.decoder.pendingBytes());
}

test "runner paints initial frame through terminal" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = "draft",
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    try runner.paintInitialFrame(&terminal, 80, 2);

    const vx = &terminal.vx.?;
    try std.testing.expectEqualStrings(">", vx.screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("d", vx.screen.readCell(2, 1).?.char.grapheme);
    try std.testing.expect(!runner.loop.dirty);
    try std.testing.expect(runner.loop.trace.renders.count >= 1);
}

test "runner drains decoded input bytes into loop" {
    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });

    try runner.feedInputBytes("ab\x1b[D\x7f");
    try runner.drainInputActions();

    try std.testing.expectEqualStrings("b", runner.loop.editor.text());
    try std.testing.expectEqual(@as(usize, 0), runner.decoder.pendingBytes());
}

test "runner decodes enter into a local submitted prompt" {
    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });

    try runner.feedInputBytes("hello\r");
    try runner.drainInputActions();

    try std.testing.expectEqualStrings("hello", runner.loop.submittedPrompt().?);
    try std.testing.expectEqualStrings("", runner.loop.editor.text());
}

test "runner degrades oversized bracketed paste without exiting" {
    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    defer runner.deinit();
    var pump: InputPump = .{};

    var paste: [4300]u8 = undefined;
    const start = "\x1b[200~";
    const end = "\x1b[201~";
    @memcpy(paste[0..start.len], start);
    @memset(paste[start.len .. paste.len - end.len], 'x');
    @memcpy(paste[paste.len - end.len ..], end);
    try std.testing.expect(pump.pushBatch(&paste, 1));

    try runner.drainInputPump(&pump);
    try runner.drainInputPump(&pump);

    try std.testing.expect(!runner.loop.exit_requested);
    try std.testing.expect(runner.loop.trace.dropped_input_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), runner.loop.transcript.items.items.len);
    try std.testing.expect(runner.loop.transcript.items.items[0].kind == .notice);
    try std.testing.expectEqualStrings("input too large", runner.loop.transcript.items.items[0].kind.notice.text);
}

test "runner drains input pump bytes into loop and records dropped bytes" {
    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    var pump: InputPump = .{};

    const typed = "ab\x1b[D\x7f";
    try std.testing.expect(pump.pushBatch(typed, 1));
    var full: [@import("InputPump.zig").byte_capacity]u8 = undefined;
    @memset(&full, 'x');
    try std.testing.expect(!pump.pushBatch(&full, 2));

    try runner.drainInputPump(&pump);

    try std.testing.expectEqualStrings("b", runner.loop.editor.text());
    try std.testing.expectEqual(@as(usize, full.len), runner.loop.trace.dropped_input_bytes);
    try std.testing.expectEqual(@as(?u8, null), pump.popByte());
    try std.testing.expectEqual(@as(usize, 0), runner.decoder.pendingBytes());
}

test "runner tick drains input and paints when due" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    var pump: InputPump = .{};
    try std.testing.expect(pump.pushBatch("hi", 1));

    try std.testing.expect(try runner.tick(&terminal, &pump, loop.frame_floor_ns, 80, 2));
    try std.testing.expectEqualStrings("hi", runner.loop.editor.text());
    try std.testing.expect(!runner.loop.dirty);
    var latency_count: usize = 0;
    for (runner.loop.trace.input_latency.buckets) |count| latency_count += count;
    try std.testing.expectEqual(@as(usize, 1), latency_count);
    try std.testing.expectEqualStrings("h", terminal.vx.?.screen.readCell(2, 1).?.char.grapheme);
}

test "runner tick skips paint before render deadline" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = "draft",
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    var pump: InputPump = .{};

    try std.testing.expect(!try runner.tick(&terminal, &pump, loop.frame_floor_ns - 1, 80, 2));
    try std.testing.expect(runner.loop.dirty);
    try std.testing.expectEqual(@as(usize, 0), runner.loop.trace.renders.count);
}

test "runner tick renders immediately on resize" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = "draft",
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    var pump: InputPump = .{};
    pump.markResize();

    try std.testing.expect(try runner.tick(&terminal, &pump, 0, 80, 2));
    try std.testing.expectEqual(@as(u64, 1), runner.layout.revision);
    try std.testing.expect(!runner.loop.dirty);
}

test "frame loop step exits through pumped ctrl-d input" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var terminal: Terminal = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, &env);
    defer terminal.deinit();

    var runner = try Runner.init(std.testing.allocator, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    });
    var pump: InputPump = .{};
    try std.testing.expect(pump.pushBatch("\x04", 1));

    const result = try FrameLoop.step(&runner, &terminal, &pump, .{
        .now_ns = loop.frame_floor_ns,
        .width = 80,
        .height = 2,
    });

    try std.testing.expect(result.exit_requested);
}

test "bounded test runner exits on seeded ctrl-d after rendering prompt" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const result = try runBoundedForTest(std.testing.allocator, std.testing.io, &env, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    }, "\x04", 4);

    try std.testing.expectEqual(FrameLoop.RunStatus.exit_requested, result.result.status);
    try std.testing.expect(result.exit_requested);
    try std.testing.expect(result.render_count >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.traceReport(), "zi tui trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.traceReport(), "renders count=") != null);
}

test "bounded worker runner exits on worker-fed ctrl-d" {
    const FakeSource = struct {
        bytes: []const u8,
        emitted: bool = false,

        fn read(context: *anyopaque, out: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.emitted) return error.EndOfStream;
            self.emitted = true;
            @memcpy(out[0..self.bytes.len], self.bytes);
            return self.bytes.len;
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var source: FakeSource = .{ .bytes = "\x04" };
    const result = try runBoundedWithWorkerForTest(std.testing.allocator, io, &env, .{
        .initial_prompt = null,
        .open = .{ .create = .{ .session_id = "tui-test", .timestamp = "2026-07-06T00:00:00Z" } },
        .resume_picker = false,
    }, &source, FakeSource.read, 4);

    try std.testing.expectEqual(FrameLoop.RunStatus.exit_requested, result.result.status);
    try std.testing.expect(result.exit_requested);
    try std.testing.expect(source.emitted);
}

test {
    std.testing.refAllDecls(@This());
}
