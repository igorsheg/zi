const std = @import("std");

const extension_runner = @import("../../coding_agent/extensions/runner.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const request_mod = @import("../../coding_agent/request.zig");
const zio_job = @import("../../zio/root.zig").job;

/// Interactive wiring for zio.job.Manager.
///
/// This layer translates extension-domain start requests/events to the generic
/// zio job supervisor. It intentionally owns no threads/process mechanics.
pub const SurfaceFrameSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, frame: extension_ui.SurfaceFrame) bool,
};

pub const JobManager = struct {
    allocator: std.mem.Allocator,
    state: *State,
    manager: zio_job.Manager,

    const State = struct {
        allocator: std.mem.Allocator,
        request_queue: *request_mod.RequestQueue,
        mutex: std.Io.Mutex = .init,
        adapters: std.AutoHashMapUnmanaged(u64, OutputAdapter) = .empty,
        surface_sink: ?SurfaceFrameSink = null,

        fn deinit(self: *State) void {
            var it = self.adapters.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
            self.adapters.deinit(self.allocator);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, request_queue: *request_mod.RequestQueue, surface_sink: ?SurfaceFrameSink) !JobManager {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .request_queue = request_queue, .surface_sink = surface_sink };
        return .{
            .allocator = allocator,
            .state = state,
            .manager = zio_job.Manager.init(allocator, io, .{ .ptr = @ptrCast(state), .submit = &submitEvent }),
        };
    }

    pub fn deinit(self: *JobManager) void {
        self.manager.deinit();
        self.state.deinit();
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn setSurfaceSink(self: *JobManager, sink: SurfaceFrameSink) void {
        self.state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.state.mutex.unlock(std.Options.debug_io);
        self.state.surface_sink = sink;
    }

    pub fn start(self: *JobManager, id: u64, request: extension_runner.JobStartRequest) !void {
        var stdout_owned = request.stdout;
        defer stdout_owned.deinit(self.allocator);
        var adapter: ?OutputAdapter = switch (request.stdout) {
            .events => null,
            .surface_frame => |frame| try OutputAdapter.initSurfaceFrame(self.allocator, frame),
        };
        errdefer if (adapter) |*a| a.deinit(self.allocator);

        try self.manager.start(id, .{ .argv = request.argv, .cwd = request.cwd });

        if (adapter) |a| {
            self.state.mutex.lockUncancelable(std.Options.debug_io);
            defer self.state.mutex.unlock(std.Options.debug_io);
            try self.state.adapters.put(self.allocator, id, a);
        }
    }

    pub fn stop(self: *JobManager, id: u64) void {
        self.manager.stop(id);
    }

    pub fn write(self: *JobManager, id: u64, data: []const u8) !void {
        try self.manager.write(id, data);
    }

    fn submitEvent(ptr: *anyopaque, event: zio_job.Event) bool {
        const state: *State = @ptrCast(@alignCast(ptr));
        if (event.kind == .stdout) {
            state.mutex.lockUncancelable(std.Options.debug_io);
            defer state.mutex.unlock(std.Options.debug_io);
            if (state.adapters.getPtr(event.id)) |adapter| {
                if (event.data) |data| adapter.accept(state, event.id, data) catch return false;
                return true;
            }
        }
        if (event.kind == .exit) {
            state.mutex.lockUncancelable(std.Options.debug_io);
            if (state.adapters.fetchRemove(event.id)) |entry| {
                var adapter = entry.value;
                adapter.deinit(state.allocator);
            }
            state.mutex.unlock(std.Options.debug_io);
        }
        return submitJobEvent(state, event);
    }

    fn submitJobEvent(state: *State, event: zio_job.Event) bool {
        const ext_event = extension_ui.JobEvent{
            .id = event.id,
            .kind = switch (event.kind) { .stdout => .stdout, .stderr => .stderr, .exit => .exit },
            .data = event.data,
            .code = event.code,
        };
        const cloned = extension_ui.JobEvent.clone(state.request_queue.allocator, ext_event) catch return false;
        switch (state.request_queue.trySend(.{ .extension_job_event = cloned })) {
            .ok => return true,
            .dropped => unreachable,
            .full, .closed, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(state.request_queue.allocator);
                return false;
            },
        }
    }

    fn submitSurfaceFrame(state: *State, frame: extension_ui.SurfaceFrame) bool {
        if (state.surface_sink) |sink| return sink.submit(sink.ptr, frame);
        var dropped = frame;
        dropped.deinit(state.allocator);
        return false;
    }
};

const OutputAdapter = union(enum) {
    surface_frame: FrameDecoder,

    fn initSurfaceFrame(allocator: std.mem.Allocator, cfg: anytype) !OutputAdapter {
        return .{ .surface_frame = try FrameDecoder.init(allocator, cfg) };
    }

    fn deinit(self: *OutputAdapter, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .surface_frame => |*decoder| decoder.deinit(allocator),
        }
        self.* = undefined;
    }

    fn accept(self: *OutputAdapter, state: *JobManager.State, id: u64, data: []const u8) !void {
        switch (self.*) {
            .surface_frame => |*decoder| try decoder.accept(state, id, data),
        }
    }
};

const FrameDecoder = struct {
    surface_id: []const u8,
    state_owner_id: []const u8,
    generation: u64,
    max_frame_bytes: usize,
    buffer: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator, cfg: anytype) !FrameDecoder {
        return .{
            .surface_id = try allocator.dupe(u8, cfg.surface_id),
            .state_owner_id = try allocator.dupe(u8, cfg.state_owner_id),
            .generation = cfg.generation,
            .max_frame_bytes = cfg.max_frame_bytes,
        };
    }

    fn deinit(self: *FrameDecoder, allocator: std.mem.Allocator) void {
        allocator.free(self.surface_id);
        allocator.free(self.state_owner_id);
        self.buffer.deinit(allocator);
        self.* = undefined;
    }

    fn accept(self: *FrameDecoder, state: *JobManager.State, _: u64, data: []const u8) !void {
        try self.buffer.appendSlice(state.allocator, data);
        while (try self.nextFrame(state)) {}
        if (self.buffer.items.len > self.max_frame_bytes + 4096) {
            const keep = @min(self.buffer.items.len, 4096);
            std.mem.copyForwards(u8, self.buffer.items[0..keep], self.buffer.items[self.buffer.items.len - keep ..]);
            self.buffer.shrinkRetainingCapacity(keep);
        }
    }

    fn nextFrame(self: *FrameDecoder, state: *JobManager.State) !bool {
        const items = self.buffer.items;
        const start = std.mem.indexOf(u8, items, "FRAME ") orelse return false;
        if (start > 0) {
            std.mem.copyForwards(u8, self.buffer.items[0 .. self.buffer.items.len - start], self.buffer.items[start..]);
            self.buffer.shrinkRetainingCapacity(self.buffer.items.len - start);
        }
        const newline = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse return false;
        const header = self.buffer.items[0..newline];
        var parts = std.mem.tokenizeScalar(u8, header, ' ');
        if (!std.mem.eql(u8, parts.next() orelse "", "FRAME")) {
            _ = self.buffer.orderedRemove(0);
            return true;
        }
        const width_text = parts.next() orelse {
            _ = self.buffer.orderedRemove(0);
            return true;
        };
        const width = std.fmt.parseInt(u32, width_text, 10) catch {
            _ = self.buffer.orderedRemove(0);
            return true;
        };
        const height_text = parts.next() orelse {
            _ = self.buffer.orderedRemove(0);
            return true;
        };
        const height = std.fmt.parseInt(u32, height_text, 10) catch {
            _ = self.buffer.orderedRemove(0);
            return true;
        };
        const len_text = parts.next() orelse {
            _ = self.buffer.orderedRemove(0);
            return true;
        };
        const len = std.fmt.parseInt(usize, len_text, 10) catch {
            _ = self.buffer.orderedRemove(0);
            return true;
        };
        const expected_len = rgbaFrameBytes(width, height) orelse {
            _ = self.buffer.orderedRemove(0);
            return true;
        };
        if (len != expected_len or len > self.max_frame_bytes) {
            _ = self.buffer.orderedRemove(0);
            return true;
        }
        if (self.buffer.items.len < newline + 1 + len) return false;

        const payload_start = newline + 1;
        const payload = self.buffer.items[payload_start .. payload_start + len];
        const frame = extension_ui.SurfaceFrame{
            .state_owner_id = try state.allocator.dupe(u8, self.state_owner_id),
            .generation = self.generation,
            .id = try state.allocator.dupe(u8, self.surface_id),
            .width = width,
            .height = height,
            .format = .rgba8888,
            .data = try state.allocator.dupe(u8, payload),
        };
        _ = JobManager.submitSurfaceFrame(state, frame);

        const consumed = payload_start + len;
        std.mem.copyForwards(u8, self.buffer.items[0 .. self.buffer.items.len - consumed], self.buffer.items[consumed..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - consumed);
        return true;
    }
};

fn rgbaFrameBytes(width: u32, height: u32) ?usize {
    if (width == 0 or height == 0) return null;
    const pixels = std.math.mul(usize, @intCast(width), @intCast(height)) catch return null;
    return std.math.mul(usize, pixels, 4) catch null;
}

const testing = std.testing;

const TestSurfaceSink = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(extension_ui.SurfaceFrame) = .empty,

    fn deinit(self: *TestSurfaceSink) void {
        for (self.frames.items) |*frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    fn submit(ptr: *anyopaque, frame: extension_ui.SurfaceFrame) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.frames.append(self.allocator, frame) catch {
            var failed = frame;
            failed.deinit(self.allocator);
            return false;
        };
        return true;
    }
};

test "surface frame stdout adapter preserves frames split across chunks" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestSurfaceSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var state = JobManager.State{
        .allocator = testing.allocator,
        .request_queue = &queue,
        .surface_sink = .{ .ptr = @ptrCast(&sink), .submit = &TestSurfaceSink.submit },
    };
    defer state.deinit();
    var decoder = try FrameDecoder.init(testing.allocator, .{
        .surface_id = "doom-demo",
        .state_owner_id = "extension.lua",
        .generation = 9,
        .max_frame_bytes = 32,
    });
    defer decoder.deinit(testing.allocator);

    try decoder.accept(&state, 1, "noiseFRAME 2 ");
    try decoder.accept(&state, 1, "1 8\n");
    try decoder.accept(&state, 1, "abcdefgh");

    try testing.expectEqual(@as(usize, 1), sink.frames.items.len);
    const frame = sink.frames.items[0];
    try testing.expectEqualStrings("doom-demo", frame.id);
    try testing.expectEqual(@as(u32, 2), frame.width);
    try testing.expectEqual(@as(u32, 1), frame.height);
    try testing.expectEqualStrings("abcdefgh", frame.data);
    try testing.expectEqual(@as(usize, 0), queue.pendingDepth());
}

test "surface frame stdout adapter validates rgba byte length and resyncs" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestSurfaceSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var state = JobManager.State{
        .allocator = testing.allocator,
        .request_queue = &queue,
        .surface_sink = .{ .ptr = @ptrCast(&sink), .submit = &TestSurfaceSink.submit },
    };
    defer state.deinit();
    var decoder = try FrameDecoder.init(testing.allocator, .{
        .surface_id = "doom-demo",
        .state_owner_id = "extension.lua",
        .generation = 9,
        .max_frame_bytes = 32,
    });
    defer decoder.deinit(testing.allocator);

    try decoder.accept(&state, 1, "FRAME 2 1 7\nbadbad!FRAME 1 1 4\ngood");

    try testing.expectEqual(@as(usize, 1), sink.frames.items.len);
    try testing.expectEqual(@as(u32, 1), sink.frames.items[0].width);
    try testing.expectEqual(@as(u32, 1), sink.frames.items[0].height);
    try testing.expectEqualStrings("good", sink.frames.items[0].data);
}

test "job manager routes configured stdout frames to the surface sink" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestSurfaceSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = try JobManager.init(testing.allocator, std.Options.debug_io, &queue, .{ .ptr = @ptrCast(&sink), .submit = &TestSurfaceSink.submit });
    defer manager.deinit();

    const script = "printf 'FRAME 1 1 4\\nabcd'";
    const argv = try testing.allocator.dupe([]const u8, &.{ try testing.allocator.dupe(u8, "/bin/sh"), try testing.allocator.dupe(u8, "-c"), try testing.allocator.dupe(u8, script) });
    try manager.start(55, .{
        .argv = argv,
        .stdout = .{ .surface_frame = .{
            .surface_id = try testing.allocator.dupe(u8, "doom-demo"),
            .state_owner_id = try testing.allocator.dupe(u8, "extension.lua"),
            .generation = 9,
            .max_frame_bytes = 32,
        } },
    });

    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (sink.frames.items.len > 0) {
            try testing.expectEqualStrings("abcd", sink.frames.items[0].data);
            var drained: [4]request_mod.AgentRequest = undefined;
            const n = queue.drainInto(&drained);
            defer for (drained[0..n]) |*req| req.deinit(testing.allocator);
            for (drained[0..n]) |req| switch (req) {
                .extension_job_event => |event| try testing.expect(event.kind != .stdout),
                else => return error.UnexpectedResult,
            };
            return;
        }
        std.Options.debug_io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.Timeout;
}

test "surface frame stdout adapter emits surface frames instead of job_stdout events" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestSurfaceSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var state = JobManager.State{
        .allocator = testing.allocator,
        .request_queue = &queue,
        .surface_sink = .{ .ptr = @ptrCast(&sink), .submit = &TestSurfaceSink.submit },
    };
    defer state.deinit();
    var decoder = try FrameDecoder.init(testing.allocator, .{
        .surface_id = "doom-demo",
        .state_owner_id = "extension.lua",
        .generation = 9,
        .max_frame_bytes = 32,
    });
    defer decoder.deinit(testing.allocator);

    try decoder.accept(&state, 1, "FRAME 1 1 4\none!FRAME 1 1 4\ntwo!");

    try testing.expectEqual(@as(usize, 2), sink.frames.items.len);
    try testing.expectEqualStrings("one!", sink.frames.items[0].data);
    try testing.expectEqualStrings("two!", sink.frames.items[1].data);
    try testing.expectEqual(@as(usize, 0), queue.pendingDepth());
}
