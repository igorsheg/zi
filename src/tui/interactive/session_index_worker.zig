const std = @import("std");
const zio = @import("../../zio/root.zig");
const blocking_worker_mod = zio.worker;
const queue_mod = zio.queue;
const session_store = @import("../../coding_agent/session/store.zig");
const ui_event_mod = @import("../ui_event.zig");

const UiEvent = ui_event_mod.UiEvent;

pub const PublishFn = *const fn (ctx: ?*anyopaque, event: UiEvent) bool;

pub const Request = union(enum) {
    warm_resume_sessions: struct {
        cwd: []u8,
    },
    list_resume_sessions: struct {
        generation: u64,
        cwd: []u8,
    },

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .warm_resume_sessions => |r| allocator.free(r.cwd),
            .list_resume_sessions => |r| allocator.free(r.cwd),
        }
    }
};

const Handler = struct {
    pub const thread_label = .session_index;

    allocator: std.mem.Allocator,
    publish_fn: ?PublishFn = null,
    publish_ctx: ?*anyopaque = null,
    cached_cwd: ?[]u8 = null,
    cached_sessions: []session_store.SessionInfo = &.{},

    pub fn deinit(self: *Handler) void {
        self.clearCache();
    }

    pub fn handle(self: *Handler, request: *Request) void {
        switch (request.*) {
            .warm_resume_sessions => |r| self.warmResumeSessions(r.cwd),
            .list_resume_sessions => |r| self.listResumeSessions(r.generation, r.cwd),
        }
    }

    fn warmResumeSessions(self: *Handler, cwd: []const u8) void {
        const sessions = session_store.listSessions(self.allocator, cwd) catch return;
        const cwd_copy = self.allocator.dupe(u8, cwd) catch {
            session_store.freeSessionInfos(self.allocator, sessions);
            return;
        };
        self.replaceCache(cwd_copy, sessions);
    }

    fn listResumeSessions(self: *Handler, generation: u64, cwd: []const u8) void {
        if (self.cached_cwd) |cached_cwd| {
            if (std.mem.eql(u8, cached_cwd, cwd)) {
                const sessions = self.cloneSessionInfos(self.cached_sessions) catch |err| {
                    self.publishFailure(generation, err);
                    return;
                };
                self.publishOrFree(.{ .resume_sessions_loaded = .{
                    .generation = generation,
                    .sessions = sessions,
                } });
            }
        }

        const sessions = session_store.listSessions(self.allocator, cwd) catch |err| {
            self.publishFailure(generation, err);
            return;
        };

        const event_sessions = self.cloneSessionInfos(sessions) catch |err| {
            session_store.freeSessionInfos(self.allocator, sessions);
            self.publishFailure(generation, err);
            return;
        };
        const cwd_copy = self.allocator.dupe(u8, cwd) catch {
            session_store.freeSessionInfos(self.allocator, sessions);
            session_store.freeSessionInfos(self.allocator, event_sessions);
            self.publishFailure(generation, error.OutOfMemory);
            return;
        };
        self.replaceCache(cwd_copy, sessions);

        self.publishOrFree(.{ .resume_sessions_loaded = .{
            .generation = generation,
            .sessions = event_sessions,
        } });
    }

    fn publishFailure(self: *Handler, generation: u64, err: anyerror) void {
        const message = std.fmt.allocPrint(
            self.allocator,
            "failed to list sessions: {s}",
            .{@errorName(err)},
        ) catch return;
        self.publishOrFree(.{ .resume_sessions_failed = .{
            .generation = generation,
            .message = message,
        } });
    }

    fn replaceCache(self: *Handler, cwd: []u8, sessions: []session_store.SessionInfo) void {
        self.clearCache();
        self.cached_cwd = cwd;
        self.cached_sessions = sessions;
    }

    fn clearCache(self: *Handler) void {
        if (self.cached_cwd) |cwd| {
            self.allocator.free(cwd);
            self.cached_cwd = null;
        }
        session_store.freeSessionInfos(self.allocator, self.cached_sessions);
        self.cached_sessions = &.{};
    }

    fn cloneSessionInfos(self: *Handler, sessions: []const session_store.SessionInfo) ![]session_store.SessionInfo {
        const cloned = try self.allocator.alloc(session_store.SessionInfo, sessions.len);
        errdefer self.allocator.free(cloned);
        var built: usize = 0;
        errdefer {
            for (cloned[0..built]) |info| {
                self.allocator.free(info.path);
                self.allocator.free(info.session_id);
                self.allocator.free(info.cwd);
                self.allocator.free(info.timestamp);
                self.allocator.free(info.first_message);
            }
        }

        for (sessions) |info| {
            cloned[built] = .{
                .path = try self.allocator.dupe(u8, info.path),
                .session_id = try self.allocator.dupe(u8, info.session_id),
                .cwd = try self.allocator.dupe(u8, info.cwd),
                .timestamp = try self.allocator.dupe(u8, info.timestamp),
                .modified_at = info.modified_at,
                .first_message = try self.allocator.dupe(u8, info.first_message),
                .message_count = info.message_count,
            };
            built += 1;
        }
        return cloned;
    }

    fn publishOrFree(self: *Handler, event: UiEvent) void {
        if (self.publish_fn) |publish| {
            if (publish(self.publish_ctx, event)) return;
        }
        var failed = event;
        failed.deinit(self.allocator);
    }
};

const WorkerImpl = blocking_worker_mod.Worker(Request, Handler, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = 8, .on_full = .reject } },
    .wakeup = .pipe,
    .cross_thread = true,
});

pub const SessionIndexWorker = struct {
    allocator: std.mem.Allocator,
    worker: WorkerImpl,

    pub fn init(allocator: std.mem.Allocator) !SessionIndexWorker {
        return .{
            .allocator = allocator,
            .worker = try WorkerImpl.init(allocator, .{ .allocator = allocator }),
        };
    }

    pub fn deinit(self: *SessionIndexWorker) void {
        self.worker.deinit();
    }

    pub fn setPublisher(self: *SessionIndexWorker, publish_fn: PublishFn, publish_ctx: ?*anyopaque) void {
        self.worker.handler.publish_fn = publish_fn;
        self.worker.handler.publish_ctx = publish_ctx;
    }

    pub fn start(self: *SessionIndexWorker) !void {
        try self.worker.start();
    }

    pub fn stop(self: *SessionIndexWorker) void {
        self.worker.stop();
    }

    pub fn warmResumeSessions(self: *SessionIndexWorker, cwd: []const u8) !void {
        const cwd_copy = try self.allocator.dupe(u8, cwd);
        try self.send(.{ .warm_resume_sessions = .{ .cwd = cwd_copy } });
    }

    pub fn listResumeSessions(self: *SessionIndexWorker, generation: u64, cwd: []const u8) !void {
        const cwd_copy = try self.allocator.dupe(u8, cwd);

        try self.send(.{ .list_resume_sessions = .{
            .generation = generation,
            .cwd = cwd_copy,
        } });
    }

    fn send(self: *SessionIndexWorker, request: Request) !void {
        switch (self.worker.trySend(request)) {
            .ok => {},
            .dropped => return error.QueueUnavailable,
            .closed, .full, .oom => |returned| {
                var failed = returned;
                failed.deinit(self.allocator);
                return error.QueueUnavailable;
            },
        }
    }

    pub fn stats(self: *SessionIndexWorker) @TypeOf(self.worker.stats()) {
        return self.worker.stats();
    }
};
