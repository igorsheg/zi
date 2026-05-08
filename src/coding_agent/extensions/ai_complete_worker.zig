const std = @import("std");
const ai = @import("../../ai/root.zig");
const zio = @import("../../zio/root.zig");
const blocking_worker_mod = zio.worker;
const mailbox_mod = zio.mailbox;
const extension_runner = @import("runner.zig");
const ai_completion = @import("../ai_completion.zig");

const log = std.log.scoped(.ai_complete_worker);

pub const ResultSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, id: extension_runner.AsyncOpId, result: extension_runner.AsyncResult) bool,
    submit_event: ?*const fn (ptr: *anyopaque, id: extension_runner.AsyncOpId, event: extension_runner.AiCompleteStreamEvent) bool = null,
};

pub const Request = struct {
    id: extension_runner.AsyncOpId,
    provider: ai.provider.Provider,
    model: ai.protocol.Model,
    prompt: []u8,
    system_prompt: ?[]u8 = null,
    api_key: ?[]u8 = null,
    headers: ?[]const ai.protocol.Header = null,
    max_tokens: ?u64 = null,
    reasoning: ?ai.protocol.ThinkingLevel = null,
    stream_events: bool = false,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        if (self.system_prompt) |value| allocator.free(value);
        if (self.api_key) |value| allocator.free(value);
        if (self.headers) |headers| {
            for (headers) |header| {
                allocator.free(header.key);
                allocator.free(header.value);
            }
            allocator.free(headers);
        }
        self.* = undefined;
    }
};

const Handler = struct {
    allocator: std.mem.Allocator,
    result_sink: ?ResultSink = null,

    pub fn handle(self: *Handler, request: *Request) void {
        log.debug("starting ai completion id={d} model={s}", .{ request.id, request.model.id });
        var result = extension_runner.AsyncResult{ .ai_complete = self.complete(request) };
        log.debug("finished ai completion id={d} status={s}", .{ request.id, @tagName(result.ai_complete) });
        const sink = self.result_sink orelse {
            log.warn("missing ai completion result sink id={d}", .{request.id});
            result.deinit(self.allocator);
            return;
        };
        if (!sink.submit(sink.ptr, request.id, result)) {
            log.warn("failed to publish ai completion result id={d}", .{request.id});
            result.deinit(self.allocator);
        }
    }

    const EventFanout = struct {
        handler: *Handler,
        request: *Request,

        fn callback(event: extension_runner.AiCompleteStreamEvent, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const sink = self.handler.result_sink orelse return;
            const submit = sink.submit_event orelse return;
            var owned = event.clone(self.handler.allocator) catch return;
            if (!submit(sink.ptr, self.request.id, owned)) owned.deinit(self.handler.allocator);
        }
    };

    fn complete(self: *Handler, request: *Request) extension_runner.AiCompleteResult {
        var fanout = EventFanout{ .handler = self, .request = request };
        const result = ai_completion.runPreparedTextCompletion(self.allocator, .{
            .provider = request.provider,
            .model = request.model,
            .prompt = request.prompt,
            .system_prompt = request.system_prompt,
            .api_key = request.api_key,
            .headers = request.headers,
            .max_tokens = request.max_tokens,
            .reasoning = request.reasoning,
            .on_event = if (request.stream_events) &EventFanout.callback else null,
            .on_event_ctx = if (request.stream_events) @ptrCast(&fanout) else null,
        });
        return switch (result) {
            .completed => |completed| .{ .completed = .{ .text = completed.text } },
            .err => |msg| .{ .err = msg },
            .cancelled => .cancelled,
        };
    }
};

const WorkerImpl = blocking_worker_mod.BlockingWorker(Request, Handler, .{
    .cleanup = .deinit,
    .policy = .{ .bounded = .{ .capacity = 8, .on_full = .reject } },
    .wakeup = .pipe,
});

pub const AiCompleteWorker = struct {
    allocator: std.mem.Allocator,
    worker: WorkerImpl,

    pub fn init(allocator: std.mem.Allocator) !AiCompleteWorker {
        return .{
            .allocator = allocator,
            .worker = try WorkerImpl.init(allocator, .{ .allocator = allocator }),
        };
    }

    pub fn setResultSink(self: *AiCompleteWorker, result_sink: ResultSink) void {
        self.worker.handler.result_sink = result_sink;
    }

    pub fn deinit(self: *AiCompleteWorker) void {
        self.worker.deinit();
    }

    pub fn start(self: *AiCompleteWorker) !void {
        try self.worker.start();
    }

    pub fn submit(self: *AiCompleteWorker, request: Request) !void {
        switch (self.worker.trySend(request)) {
            .ok => {},
            .full, .closed, .oom => |rejected| {
                var failed = rejected;
                failed.deinit(self.allocator);
                return error.AiCompleteWorkerUnavailable;
            },
            .dropped => unreachable,
        }
    }
};

test "ai completion worker thread enqueues faux provider result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var faux_provider = ai.faux.FauxProvider.init(allocator);
    defer faux_provider.deinit();
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{ai.faux.fauxText("worker summary")};
    const response = ai.faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(response.content);
    faux_provider.setResponses(&.{response});

    const Queue = mailbox_mod.Mailbox(extension_runner.AsyncResult, .{
        .cleanup = .deinit,
        .policy = .{ .bounded = .{ .capacity = 4, .on_full = .reject } },
        .wakeup = .pipe,
    });
    const Sink = struct {
        queue: *Queue,

        fn submit(ptr: *anyopaque, id: extension_runner.AsyncOpId, result: extension_runner.AsyncResult) bool {
            _ = id;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return switch (self.queue.trySend(result)) {
                .ok, .dropped => true,
                .full, .closed, .oom => |rejected| {
                    var failed = rejected;
                    failed.deinit(std.testing.allocator);
                    return false;
                },
            };
        }
    };

    var queue = try Queue.init(allocator);
    defer queue.deinit();
    var sink = Sink{ .queue = &queue };
    var worker = try AiCompleteWorker.init(allocator);
    defer worker.deinit();
    worker.setResultSink(.{ .ptr = @ptrCast(&sink), .submit = &Sink.submit });
    try worker.start();

    try worker.submit(.{
        .id = 7,
        .provider = faux_provider.provider(),
        .model = ai.faux.fauxModel(),
        .prompt = try allocator.dupe(u8, "please summarize"),
        .system_prompt = try allocator.dupe(u8, "system"),
        .api_key = try allocator.dupe(u8, "test-key"),
        .max_tokens = 128,
    });

    _ = try queue.waitReadable(5_000);
    var out: [1]extension_runner.AsyncResult = undefined;
    const count = queue.drainInto(&out);
    try testing.expectEqual(@as(usize, 1), count);
    var result = out[0];
    defer result.deinit(allocator);
    try testing.expect(result == .ai_complete);
    try testing.expect(result.ai_complete == .completed);
    try testing.expectEqualStrings("worker summary", result.ai_complete.completed.text);
}
