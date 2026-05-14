const std = @import("std");
const queue_mod = @import("queue.zig");
const task_mod = @import("task.zig");
const logging = @import("../logging.zig");

const log = std.log.scoped(.zio_worker);

pub fn Worker(
    comptime Request: type,
    comptime Handler: type,
    comptime config: queue_mod.Config,
) type {
    comptime {
        if (config.wakeup != .pipe) {
            @compileError("Worker requires queue wakeup=.pipe");
        }
        if (!@hasDecl(Handler, "handle")) {
            @compileError("Worker Handler must declare handle(self, request)");
        }
    }

    const Queue = queue_mod.Queue(Request, config);

    return struct {
        const Self = @This();
        pub const QueueType = Queue;

        allocator: std.mem.Allocator,
        io: std.Io,
        queue: Queue,
        handler: Handler,
        tasks: ?task_mod.Group = null,

        pub fn init(allocator: std.mem.Allocator, handler: Handler) !Self {
            return initIo(allocator, std.Options.debug_io, handler);
        }

        pub fn initIo(allocator: std.mem.Allocator, io: std.Io, handler: Handler) !Self {
            return .{
                .allocator = allocator,
                .io = io,
                .queue = try Queue.initIo(allocator, io),
                .handler = handler,
            };
        }

        pub fn deinit(self: *Self) void {
            self.stop();
            self.queue.deinit();
            if (@hasDecl(Handler, "deinit")) {
                self.handler.deinit();
            }
            self.* = undefined;
        }

        pub fn start(self: *Self) !void {
            if (self.tasks != null) return;
            var group = task_mod.Group.init(self.allocator);
            errdefer group.cancel();
            try group.spawnThread(run, .{self});
            self.tasks = group;
        }

        pub fn stop(self: *Self) void {
            self.queue.close();
            if (self.tasks) |*group| {
                const start_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
                group.join() catch |err| log.warn("worker task join failed: {}", .{err});
                const elapsed_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds() - start_ns;
                if (elapsed_ns > std.time.ns_per_s) {
                    log.warn("worker stop waited {d}ms for current handler to finish", .{@divFloor(elapsed_ns, std.time.ns_per_ms)});
                }
                self.tasks = null;
            }
        }

        pub fn trySend(self: *Self, request: Request) Queue.TrySendResult {
            return self.queue.trySend(request);
        }

        pub fn stats(self: *Self) Queue.Stats {
            return self.queue.stats();
        }

        fn run(self: *Self) void {
            if (@hasDecl(Handler, "thread_label")) {
                logging.setThreadLabel(Handler.thread_label);
            } else {
                logging.setThreadLabel(.zio_worker);
            }

            var batch: [8]Request = undefined;
            while (true) {
                _ = self.queue.waitReadable(-1) catch false;

                while (true) {
                    const count = self.queue.drainInto(&batch);
                    if (count == 0) break;

                    for (batch[0..count]) |*request| {
                        self.handler.handle(request);
                        cleanupDrained(request, self.allocator);
                    }
                }

                if (self.queue.isDrained()) return;
            }
        }

        fn cleanupDrained(request: *Request, allocator: std.mem.Allocator) void {
            if (@hasDecl(Request, "deinit")) {
                request.deinit(allocator);
            }
        }
    };
}

pub fn Pool(
    comptime Request: type,
    comptime Handler: type,
    comptime config: queue_mod.Config,
    comptime count: usize,
) type {
    comptime std.debug.assert(count > 0);
    const WorkerImpl = Worker(Request, Handler, config);

    return struct {
        const Self = @This();
        pub const QueueType = WorkerImpl.QueueType;

        allocator: std.mem.Allocator,
        workers: [count]WorkerImpl,
        next: usize = 0,

        pub fn init(allocator: std.mem.Allocator, handler: Handler) !Self {
            return initIo(allocator, std.Options.debug_io, handler);
        }

        pub fn initIo(allocator: std.mem.Allocator, io: std.Io, handler: Handler) !Self {
            var workers: [count]WorkerImpl = undefined;
            var initialized: usize = 0;
            errdefer {
                for (workers[0..initialized]) |*worker| worker.deinit();
            }
            while (initialized < count) : (initialized += 1) {
                workers[initialized] = try WorkerImpl.initIo(allocator, io, handler);
            }
            return .{ .allocator = allocator, .workers = workers };
        }

        pub fn deinit(self: *Self) void {
            for (&self.workers) |*worker| worker.deinit();
            self.* = undefined;
        }

        pub fn start(self: *Self) !void {
            var started: usize = 0;
            errdefer {
                for (self.workers[0..started]) |*worker| worker.stop();
            }
            for (&self.workers) |*worker| {
                try worker.start();
                started += 1;
            }
        }

        pub fn stop(self: *Self) void {
            for (&self.workers) |*worker| worker.stop();
        }

        pub fn trySend(self: *Self, request: Request) QueueType.TrySendResult {
            var current = request;
            var attempts: usize = 0;
            while (attempts < count) : (attempts += 1) {
                const index = (self.next + attempts) % count;
                switch (self.workers[index].trySend(current)) {
                    .ok => {
                        self.next = (index + 1) % count;
                        return .ok;
                    },
                    .dropped => {
                        self.next = (index + 1) % count;
                        return .dropped;
                    },
                    .full, .closed, .oom => |returned| current = returned,
                }
            }
            return .{ .full = current };
        }
    };
}
