const std = @import("std");
const ai = @import("../ai/root.zig");
const zio = @import("../zio/root.zig");

const log = std.log.scoped(.ai_completion);

pub const StreamEventCallback = *const fn (event: @import("extensions/runner.zig").AiCompleteStreamEvent, ctx: ?*anyopaque) void;

pub const PreparedTextCompletionRequest = struct {
    provider: ai.provider.Provider,
    model: ai.protocol.Model,
    prompt: []const u8,
    system_prompt: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    headers: ?[]const ai.protocol.Header = null,
    max_tokens: ?u64 = null,
    reasoning: ?ai.protocol.ThinkingLevel = null,
    signal: zio.cancel.Token = zio.cancel.Token.none,
    on_event: ?StreamEventCallback = null,
    on_event_ctx: ?*anyopaque = null,
};

pub const TextCompletionResult = union(enum) {
    completed: struct { text: []u8 },
    err: []u8,
    cancelled,

    pub fn deinit(self: *TextCompletionResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |completed| allocator.free(completed.text),
            .err => |msg| allocator.free(msg),
            .cancelled => {},
        }
        self.* = undefined;
    }
};

pub fn runPreparedTextCompletion(
    result_allocator: std.mem.Allocator,
    request: PreparedTextCompletionRequest,
) TextCompletionResult {
    var stream_arena = std.heap.ArenaAllocator.init(result_allocator);
    defer stream_arena.deinit();
    const stream_allocator = stream_arena.allocator();

    const messages = [_]ai.protocol.Message{.{ .user = .{
        .content = .{ .text = request.prompt },
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    } }};
    const context = ai.protocol.Context{
        .system_prompt = request.system_prompt,
        .messages = &messages,
    };

    var collector = CompletionCollector{ .allocator = result_allocator, .on_event = request.on_event, .on_event_ctx = request.on_event_ctx };
    request.provider.streamSimple(
        stream_allocator,
        request.model,
        context,
        .{
            .base = .{
                .api_key = request.api_key,
                .headers = request.headers,
                .max_tokens = request.max_tokens,
                .signal = request.signal,
            },
            .reasoning = request.reasoning,
        },
        &CompletionCollector.callback,
        @ptrCast(&collector),
    );

    if (collector.error_message) |msg| return .{ .err = msg };
    return .{ .completed = .{ .text = collector.text orelse result_allocator.dupe(u8, "") catch return .cancelled } };
}

const CompletionCollector = struct {
    allocator: std.mem.Allocator,
    text: ?[]u8 = null,
    error_message: ?[]u8 = null,
    on_event: ?StreamEventCallback = null,
    on_event_ctx: ?*anyopaque = null,

    fn emit(self: *CompletionCollector, event: @import("extensions/runner.zig").AiCompleteStreamEvent) void {
        if (self.on_event) |cb| cb(event, self.on_event_ctx);
    }

    fn callback(event: ai.protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *CompletionCollector = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .start => |start| {
                self.emit(.{ .agent_event = .{ .message_start = .{ .message = .{ .assistant = start.partial } } } });
            },
            .text_delta => |delta| {
                if (delta.delta.len > 0) self.emit(.{ .agent_event = .{ .message_update = .{
                    .message = .{ .assistant = delta.partial },
                    .assistant_message_event = event,
                } } });
            },
            .done => |done| {
                log.debug("provider done reason={s}", .{@tagName(done.reason)});
                self.text = collectText(self.allocator, done.message) catch null;
                self.emit(.{ .agent_event = .{ .message_end = .{ .message = .{ .assistant = done.message } } } });
            },
            .@"error" => |err| {
                log.debug("provider error reason={s}", .{@tagName(err.reason)});
                const msg = err.@"error".error_message orelse "provider error";
                self.error_message = self.allocator.dupe(u8, msg) catch null;
                self.emit(.{ .err = msg });
            },
            else => {},
        }
    }

    fn collectText(allocator: std.mem.Allocator, msg: ai.protocol.AssistantMessage) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (msg.content) |block| switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            else => {},
        };
        return out.toOwnedSlice(allocator);
    }
};

test "text completion emits stream callback events and final result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var faux_provider = ai.faux.FauxProvider.init(allocator);
    defer faux_provider.deinit();
    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{ai.faux.fauxText("hello")};
    const response = ai.faux.fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(response.content);
    faux_provider.setResponses(&.{response});

    const Collector = struct {
        events: std.ArrayList(@import("extensions/runner.zig").AiCompleteStreamEvent) = .empty,

        fn callback(event: @import("extensions/runner.zig").AiCompleteStreamEvent, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events.append(testing.allocator, event.clone(testing.allocator) catch return) catch return;
        }
    };

    var collector = Collector{};
    defer {
        for (collector.events.items) |*event| event.deinit(allocator);
        collector.events.deinit(allocator);
    }

    var result = runPreparedTextCompletion(allocator, .{
        .provider = faux_provider.provider(),
        .model = ai.faux.fauxModel(),
        .prompt = "prompt",
        .on_event = &Collector.callback,
        .on_event_ctx = @ptrCast(&collector),
    });
    defer result.deinit(allocator);

    try testing.expect(result == .completed);
    try testing.expectEqualStrings("hello", result.completed.text);
    try testing.expect(collector.events.items.len >= 3);
    try testing.expect(collector.events.items[0] == .agent_event);
    try testing.expect(collector.events.items[0].agent_event == .message_start);
    try testing.expect(collector.events.items[1] == .agent_event);
    try testing.expect(collector.events.items[1].agent_event == .message_update);
    try testing.expectEqualStrings("hello", collector.events.items[1].agent_event.message_update.assistant_message_event.text_delta.delta);
    try testing.expect(collector.events.items[collector.events.items.len - 1] == .agent_event);
    try testing.expect(collector.events.items[collector.events.items.len - 1].agent_event == .message_end);
}
