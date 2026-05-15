const std = @import("std");
const zio = @import("../../zio/root.zig");
const blocking_worker_mod = zio.worker;
const queue_mod = zio.queue;
const system_command = @import("system_command.zig");
const extension_runner = @import("runner.zig");

const log = std.log.scoped(.system_worker);

pub const ResultSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, id: extension_runner.AsyncOpId, result: extension_runner.AsyncResult) bool,
};

pub const Request = struct {
    id: extension_runner.AsyncOpId,
    system: extension_runner.SystemRequest,

    pub fn workerLabel(self: *const Request) []const u8 {
        _ = self;
        return "system";
    }

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        self.system.deinit(allocator);
        self.* = undefined;
    }
};

const Handler = struct {
    pub const thread_label = .system_worker;

    allocator: std.mem.Allocator,
    io: std.Io,
    result_sink: ?ResultSink = null,
    mutex: std.Io.Mutex = .init,
    current_signal: zio.cancel.Token = zio.cancel.Token.none,

    pub fn handle(self: *Handler, request: *Request) void {
        self.setCurrentSignal(request.system.signal);
        defer self.setCurrentSignal(zio.cancel.Token.none);

        log.debug("starting system command id={d} argv0={s}", .{ request.id, if (request.system.argv.len > 0) request.system.argv[0] else "" });
        var result = extension_runner.AsyncResult{ .system = self.runSystem(request.system) };
        log.debug("finished system command id={d} status={s}", .{ request.id, @tagName(result.system) });
        const sink = self.result_sink orelse {
            log.warn("missing system result sink id={d}", .{request.id});
            result.deinit(self.allocator);
            return;
        };
        if (!sink.submit(sink.ptr, request.id, result)) {
            log.warn("failed to publish system result id={d}", .{request.id});
            result.deinit(self.allocator);
        }
    }

    pub fn cancelCurrent(self: *Handler) void {
        self.mutex.lockUncancelable(self.io);
        const signal = self.current_signal;
        self.mutex.unlock(self.io);
        signal.requestAbort();
    }

    fn setCurrentSignal(self: *Handler, signal: zio.cancel.Token) void {
        self.mutex.lockUncancelable(self.io);
        self.current_signal = signal;
        self.mutex.unlock(self.io);
    }

    fn runSystem(self: *Handler, request: extension_runner.SystemRequest) extension_runner.SystemResult {
        const env_pairs = self.allocator.alloc(system_command.EnvPair, request.env.len) catch {
            return .{ .err = .{ .message = self.allocator.dupe(u8, "failed to allocate env") catch &.{} } };
        };
        defer self.allocator.free(env_pairs);
        for (request.env, 0..) |pair, i| {
            env_pairs[i] = .{ .key = pair.key, .value = pair.value };
        }
        return system_command.run(self.allocator, self.io, .{
            .argv = request.argv,
            .cwd = request.cwd,
            .stdin = request.stdin,
            .env = env_pairs,
            .clear_env = request.clear_env,
            .timeout_ms = request.timeout_ms,
            .max_stdout_bytes = request.max_stdout_bytes,
            .max_stderr_bytes = request.max_stderr_bytes,
            .text = request.text,
            .stdio = switch (request.stdio) {
                .capture => .capture,
                .terminal => .terminal,
            },
            .signal = request.signal,
        });
    }
};

const WorkerPool = blocking_worker_mod.Pool(Request, Handler, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = 8, .on_full = .reject } },
    .wakeup = .pipe,
    .cross_thread = true,
}, 4);

pub const SystemWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    worker: WorkerPool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !SystemWorker {
        return .{
            .allocator = allocator,
            .io = io,
            .worker = try WorkerPool.initIo(allocator, io, .{ .allocator = allocator, .io = io }),
        };
    }

    pub fn setResultSink(self: *SystemWorker, result_sink: ResultSink) void {
        for (&self.worker.workers) |*worker| worker.handler.result_sink = result_sink;
    }

    pub fn deinit(self: *SystemWorker) void {
        self.worker.deinit();
    }

    pub fn start(self: *SystemWorker) !void {
        try self.worker.start();
    }

    pub fn submit(self: *SystemWorker, request: Request) !void {
        switch (self.worker.trySend(request)) {
            .ok => {},
            .full, .closed, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(self.allocator);
                return error.SystemWorkerUnavailable;
            },
            .dropped => unreachable,
        }
    }
};

test "system worker publishes command result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Sink = struct {
        result: ?extension_runner.AsyncResult = null,

        fn submit(ptr: *anyopaque, id: extension_runner.AsyncOpId, result: extension_runner.AsyncResult) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (id != 42) return false;
            self.result = result;
            return true;
        }
    };

    var sink = Sink{};
    var handler = Handler{
        .allocator = allocator,
        .io = std.Options.debug_io,
        .result_sink = .{ .ptr = @ptrCast(&sink), .submit = &Sink.submit },
    };
    var request = Request{
        .id = 42,
        .system = .{
            .argv = try allocator.dupe([]const u8, &.{ try allocator.dupe(u8, "/bin/sh"), try allocator.dupe(u8, "-c"), try allocator.dupe(u8, "printf worker") }),
        },
    };
    defer request.deinit(allocator);

    handler.handle(&request);

    var result = sink.result orelse return error.MissingSystemResult;
    defer result.deinit(allocator);
    try testing.expect(result == .system);
    try testing.expect(result.system == .completed);
    try testing.expectEqualStrings("worker", result.system.completed.stdout);
}
