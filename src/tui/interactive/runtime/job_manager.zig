const std = @import("std");

const extension_runner = @import("../../../coding_agent/extensions/runner.zig");
const extension_ui = @import("../../../coding_agent/extensions/ui.zig");
const request_mod = @import("../../../coding_agent/request.zig");
const zio_job = @import("../../../zio/root.zig").process.Jobs;
const json_root = @import("../../../json/root.zig");
const jsonl = json_root.jsonl;
const json_value = json_root.value;

pub const FrameSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, frame: extension_ui.UiFrame) bool,
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
        frame_sink: ?FrameSink = null,

        fn deinit(self: *State) void {
            var it = self.adapters.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
            self.adapters.deinit(self.allocator);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, request_queue: *request_mod.RequestQueue, frame_sink: ?FrameSink) !JobManager {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .request_queue = request_queue, .frame_sink = frame_sink };
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

    pub fn setFrameSink(self: *JobManager, sink: FrameSink) void {
        self.state.mutex.lockUncancelable(std.Options.debug_io);
        defer self.state.mutex.unlock(std.Options.debug_io);
        self.state.frame_sink = sink;
    }

    pub fn start(self: *JobManager, id: u64, request: extension_runner.JobStartRequest) !void {
        var stdout_owned = request.stdout;
        defer stdout_owned.deinit(self.allocator);
        var adapter: ?OutputAdapter = switch (request.stdout) {
            .events => null,
            .ui_frame => |frame| try OutputAdapter.initUiFrame(self.allocator, frame),
            .json_lines => |cfg| OutputAdapter.initJsonLines(self.allocator, cfg),
        };
        errdefer if (adapter) |*a| a.deinit(self.allocator);

        if (adapter) |a| {
            self.state.mutex.lockUncancelable(std.Options.debug_io);
            defer self.state.mutex.unlock(std.Options.debug_io);
            try self.state.adapters.put(self.allocator, id, a);
            adapter = null;
        }
        errdefer if (self.state.adapters.fetchRemove(id)) |entry| {
            var removed = entry.value;
            removed.deinit(self.allocator);
        };

        try self.manager.start(id, .{ .argv = request.argv, .cwd = request.cwd });
    }

    pub fn stop(self: *JobManager, id: u64) void {
        self.manager.stop(id);
    }

    pub fn write(self: *JobManager, id: u64, data: []const u8) !void {
        try self.manager.write(id, data);
    }

    fn submitEvent(ptr: *anyopaque, event: zio_job.Event) bool {
        const state: *State = @ptrCast(@alignCast(ptr));
        var owned = event;
        if (owned.kind == .stdout) {
            state.mutex.lockUncancelable(std.Options.debug_io);
            defer state.mutex.unlock(std.Options.debug_io);
            if (state.adapters.getPtr(owned.id)) |adapter| {
                if (owned.data) |data| adapter.accept(state, owned.id, data) catch return false;
                owned.deinit(state.allocator);
                return true;
            }
        }
        if (owned.kind == .exit) {
            state.mutex.lockUncancelable(std.Options.debug_io);
            if (state.adapters.fetchRemove(owned.id)) |entry| {
                var adapter = entry.value;
                adapter.finish(state, owned.id);
                adapter.deinit(state.allocator);
            }
            state.mutex.unlock(std.Options.debug_io);
        }
        if (!submitJobEvent(state, owned)) return false;
        owned.deinit(state.allocator);
        return true;
    }

    fn submitJobEvent(state: *State, event: zio_job.Event) bool {
        const ext_event = extension_ui.JobEvent{
            .id = event.id,
            .kind = switch (event.kind) {
                .stdout => .stdout,
                .stderr => .stderr,
                .exit => .exit,
            },
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

    fn submitUiFrame(state: *State, frame: extension_ui.UiFrame) bool {
        if (state.frame_sink) |sink| return sink.submit(sink.ptr, frame);
        var dropped = frame;
        dropped.deinit(state.allocator);
        return false;
    }
};

const OutputAdapter = union(enum) {
    ui_frame: FrameDecoder,
    json_lines: JsonLinesDecoder,

    fn initUiFrame(allocator: std.mem.Allocator, cfg: anytype) !OutputAdapter {
        return .{ .ui_frame = try FrameDecoder.init(allocator, cfg) };
    }

    fn initJsonLines(allocator: std.mem.Allocator, cfg: anytype) OutputAdapter {
        return .{ .json_lines = JsonLinesDecoder.init(allocator, cfg) };
    }

    fn deinit(self: *OutputAdapter, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ui_frame => |*decoder| decoder.deinit(allocator),
            .json_lines => |*decoder| decoder.deinit(allocator),
        }
        self.* = undefined;
    }

    fn accept(self: *OutputAdapter, state: *JobManager.State, id: u64, data: []const u8) !void {
        switch (self.*) {
            .ui_frame => |*decoder| try decoder.accept(state, id, data),
            .json_lines => |*decoder| try decoder.accept(state, id, data),
        }
    }

    fn finish(self: *OutputAdapter, state: *JobManager.State, id: u64) void {
        switch (self.*) {
            .ui_frame => {},
            .json_lines => |*decoder| decoder.finish(state, id),
        }
    }
};

const JsonLinesDecoder = struct {
    decoder: jsonl.Decoder,

    fn init(allocator: std.mem.Allocator, cfg: anytype) JsonLinesDecoder {
        return .{ .decoder = jsonl.Decoder.init(allocator, .{ .max_line_bytes = cfg.max_line_bytes }) };
    }

    fn deinit(self: *JsonLinesDecoder, allocator: std.mem.Allocator) void {
        self.decoder.deinit();
        _ = allocator;
    }

    fn accept(self: *JsonLinesDecoder, state: *JobManager.State, id: u64, data: []const u8) !void {
        var ctx = JsonLineCtx{ .state = state, .id = id };
        try self.decoder.feed(data, ctx.sink());
    }

    fn finish(self: *JsonLinesDecoder, state: *JobManager.State, id: u64) void {
        var ctx = JsonLineCtx{ .state = state, .id = id };
        self.decoder.flush(ctx.sink());
    }
};

const JsonLineCtx = struct {
    state: *JobManager.State,
    id: u64,

    fn sink(self: *@This()) jsonl.Sink {
        return .{ .ptr = self, .emit = emit, .err = err };
    }

    fn emit(ptr: *anyopaque, line: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const parsed = std.json.parseFromSlice(std.json.Value, self.state.allocator, line, .{ .allocate = .alloc_always }) catch |parse_err| {
            submitJsonError(self.state, self.id, line, @errorName(parse_err));
            return;
        };
        defer parsed.deinit();
        const value = json_value.cloneJsonValue(self.state.request_queue.allocator, parsed.value) catch return;
        const event = extension_ui.JobEvent{ .id = self.id, .kind = .json, .data = line, .value = value };
        const cloned = extension_ui.JobEvent.clone(self.state.request_queue.allocator, event) catch {
            json_value.freeJsonValue(self.state.request_queue.allocator, value);
            return;
        };
        json_value.freeJsonValue(self.state.request_queue.allocator, value);
        sendExtensionJobEvent(self.state, cloned);
    }

    fn err(ptr: *anyopaque, _: jsonl.ErrorKind, data: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        submitJsonError(self.state, self.id, data, "line too long");
    }

    fn submitJsonError(state: *JobManager.State, id: u64, data: []const u8, message: []const u8) void {
        const event = extension_ui.JobEvent{ .id = id, .kind = .json, .data = data, .is_error = true, .error_message = message };
        const cloned = extension_ui.JobEvent.clone(state.request_queue.allocator, event) catch return;
        sendExtensionJobEvent(state, cloned);
    }

    fn sendExtensionJobEvent(state: *JobManager.State, event: extension_ui.JobEvent) void {
        switch (state.request_queue.trySend(.{ .extension_job_event = event })) {
            .ok => {},
            .dropped => unreachable,
            .full, .closed, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(state.request_queue.allocator);
            },
        }
    }
};

const FrameDecoder = struct {
    view: []const u8,
    node: []const u8,
    state_owner_id: []const u8,
    generation: u64,
    format: extension_ui.FrameFormat,
    max_frame_bytes: usize,
    buffer: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator, cfg: anytype) !FrameDecoder {
        return .{
            .view = try allocator.dupe(u8, cfg.view),
            .node = try allocator.dupe(u8, cfg.node),
            .state_owner_id = try allocator.dupe(u8, cfg.state_owner_id),
            .generation = cfg.generation,
            .format = cfg.format,
            .max_frame_bytes = cfg.max_frame_bytes,
        };
    }

    fn deinit(self: *FrameDecoder, allocator: std.mem.Allocator) void {
        allocator.free(self.view);
        allocator.free(self.node);
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
        const marker = switch (self.format) {
            .rgba8888 => "FRAME ",
            .halfblock_rgb => "HALFBLOCK ",
        };
        const start = std.mem.indexOf(u8, items, marker) orelse return false;
        if (start > 0) {
            std.mem.copyForwards(u8, self.buffer.items[0 .. self.buffer.items.len - start], self.buffer.items[start..]);
            self.buffer.shrinkRetainingCapacity(self.buffer.items.len - start);
        }
        const newline = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse return false;
        const header = self.buffer.items[0..newline];
        var parts = std.mem.tokenizeScalar(u8, header, ' ');
        const expected_header = switch (self.format) {
            .rgba8888 => "FRAME",
            .halfblock_rgb => "HALFBLOCK",
        };
        if (!std.mem.eql(u8, parts.next() orelse "", expected_header)) {
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
        const expected_len = frameBytes(width, height, self.format) orelse {
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
        const frame = extension_ui.UiFrame{
            .state_owner_id = try state.allocator.dupe(u8, self.state_owner_id),
            .generation = self.generation,
            .view = try state.allocator.dupe(u8, self.view),
            .node = try state.allocator.dupe(u8, self.node),
            .width = width,
            .height = height,
            .format = self.format,
            .data = try state.allocator.dupe(u8, payload),
        };
        _ = JobManager.submitUiFrame(state, frame);

        const consumed = payload_start + len;
        std.mem.copyForwards(u8, self.buffer.items[0 .. self.buffer.items.len - consumed], self.buffer.items[consumed..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - consumed);
        return true;
    }
};

fn frameBytes(width: u32, height: u32, format: extension_ui.FrameFormat) ?usize {
    if (width == 0 or height == 0) return null;
    const cells = std.math.mul(usize, @intCast(width), @intCast(height)) catch return null;
    return std.math.mul(usize, cells, switch (format) {
        .rgba8888 => 4,
        .halfblock_rgb => 6,
    }) catch null;
}

const testing = std.testing;

fn testFrameSinkAdapter(sink: *TestFrameSink) FrameSink {
    return .{ .ptr = @ptrCast(sink), .submit = &TestFrameSink.submit };
}

fn testFrameState(queue: *request_mod.RequestQueue, sink: *TestFrameSink) JobManager.State {
    return .{
        .allocator = testing.allocator,
        .request_queue = queue,
        .frame_sink = testFrameSinkAdapter(sink),
    };
}

fn testFrameDecoder() !FrameDecoder {
    return FrameDecoder.init(testing.allocator, .{
        .view = "doom-workbench",
        .node = "doom-demo",
        .state_owner_id = "extension.lua",
        .generation = 9,
        .format = .rgba8888,
        .max_frame_bytes = 32,
    });
}

fn expectFrame(frame: extension_ui.UiFrame, width: u32, height: u32, data: []const u8) !void {
    try testing.expectEqualStrings("doom-demo", frame.node);
    try testing.expectEqual(width, frame.width);
    try testing.expectEqual(height, frame.height);
    try testing.expectEqualStrings(data, frame.data);
}

fn expectFrameFormat(frame: extension_ui.UiFrame, format: extension_ui.FrameFormat, width: u32, height: u32, data: []const u8) !void {
    try expectFrame(frame, width, height, data);
    try testing.expectEqual(format, frame.format);
}

const TestFrameSink = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(extension_ui.UiFrame) = .empty,

    fn deinit(self: *TestFrameSink) void {
        for (self.frames.items) |*frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    fn submit(ptr: *anyopaque, frame: extension_ui.UiFrame) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.frames.append(self.allocator, frame) catch {
            var failed = frame;
            failed.deinit(self.allocator);
            return false;
        };
        return true;
    }
};

test "ui frame stdout adapter decodes halfblock cell frames" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestFrameSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var state = testFrameState(&queue, &sink);
    var decoder = try FrameDecoder.init(testing.allocator, .{
        .view = "doom-workbench",
        .node = "doom-demo",
        .state_owner_id = "extension.lua",
        .generation = 9,
        .format = .halfblock_rgb,
        .max_frame_bytes = 32,
    });
    defer decoder.deinit(testing.allocator);

    try decoder.accept(&state, 1, "HALFBLOCK 1 1 6\nabcdef");
    try testing.expectEqual(@as(usize, 1), sink.frames.items.len);
    try expectFrameFormat(sink.frames.items[0], .halfblock_rgb, 1, 1, "abcdef");
}

test "ui frame stdout adapter preserves frames split across chunks" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestFrameSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var state = testFrameState(&queue, &sink);
    defer state.deinit();
    var decoder = try testFrameDecoder();
    defer decoder.deinit(testing.allocator);

    try decoder.accept(&state, 1, "noiseFRAME 2 ");
    try decoder.accept(&state, 1, "1 8\n");
    try decoder.accept(&state, 1, "abcdefgh");

    try testing.expectEqual(@as(usize, 1), sink.frames.items.len);
    try expectFrame(sink.frames.items[0], 2, 1, "abcdefgh");
    try testing.expectEqual(@as(usize, 0), queue.pendingDepth());
}

test "ui frame stdout adapter validates rgba byte length and resyncs" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestFrameSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var state = testFrameState(&queue, &sink);
    defer state.deinit();
    var decoder = try testFrameDecoder();
    defer decoder.deinit(testing.allocator);

    try decoder.accept(&state, 1, "FRAME 2 1 7\nbadbad!FRAME 1 1 4\ngood");

    try testing.expectEqual(@as(usize, 1), sink.frames.items.len);
    try expectFrame(sink.frames.items[0], 1, 1, "good");
}

test "job manager routes configured stdout frames to the frame sink" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestFrameSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var manager = try JobManager.init(testing.allocator, std.Options.debug_io, &queue, testFrameSinkAdapter(&sink));
    defer manager.deinit();

    const script = "printf 'FRAME 1 1 4\\nabcd'";
    const argv = try testing.allocator.dupe([]const u8, &.{ try testing.allocator.dupe(u8, "/bin/sh"), try testing.allocator.dupe(u8, "-c"), try testing.allocator.dupe(u8, script) });
    try manager.start(55, .{
        .argv = argv,
        .stdout = .{ .ui_frame = .{
            .view = try testing.allocator.dupe(u8, "doom-workbench"),
            .node = try testing.allocator.dupe(u8, "doom-demo"),
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

test "ui frame stdout adapter emits UI frames instead of job_stdout events" {
    var queue = try request_mod.RequestQueue.init(testing.allocator);
    defer queue.deinit();
    var sink = TestFrameSink{ .allocator = testing.allocator };
    defer sink.deinit();
    var state = testFrameState(&queue, &sink);
    defer state.deinit();
    var decoder = try testFrameDecoder();
    defer decoder.deinit(testing.allocator);

    try decoder.accept(&state, 1, "FRAME 1 1 4\none!FRAME 1 1 4\ntwo!");

    try testing.expectEqual(@as(usize, 2), sink.frames.items.len);
    try expectFrame(sink.frames.items[0], 1, 1, "one!");
    try expectFrame(sink.frames.items[1], 1, 1, "two!");
    try testing.expectEqual(@as(usize, 0), queue.pendingDepth());
}
