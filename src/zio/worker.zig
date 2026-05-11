const std = @import("std");
const queue_mod = @import("queue.zig");
const task_mod = @import("task.zig");

/// A tiny typed worker-thread wrapper around `zio.queue.Queue`.
///
/// This owns only mechanics: thread spawn/join, queue wait/drain, and
/// drained-request cleanup. Product semantics stay in the typed `Handler`.
///
/// Handler contract:
///
///   pub fn handle(self: *Handler, request: *Request) void
///
/// Request payloads that own memory should provide:
///
///   pub fn deinit(self: *Request, allocator: std.mem.Allocator) void
///
/// The queue also uses `.cleanup = .deinit` for undelivered queued items;
/// this wrapper cleans only requests that were transferred to the worker by
/// `drainInto`.
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
            var group = task_mod.Group.init(self.allocator, self.io);
            errdefer group.cancel();
            try group.spawnThread(run, .{self});
            self.tasks = group;
        }

        /// Ordered shutdown: stop accepting new requests, let the worker drain
        /// already queued requests, then join it.
        pub fn stop(self: *Self) void {
            self.queue.close();
            if (self.tasks) |*group| {
                group.join() catch {};
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
