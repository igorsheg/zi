const std = @import("std");
const json_value = @import("../json/value.zig");
const protocol = @import("protocol.zig");
const ai_provider = @import("provider.zig");
const ai_stream = @import("stream.zig");

const FAUX_API: protocol.Api = .{ .custom = "faux" };
const FAUX_PROVIDER: protocol.Provider = .{ .custom = "faux" };
const FAUX_MODEL_ID = "faux-1";

const DEFAULT_USAGE: protocol.Usage = .{
    .input = 0,
    .output = 0,
    .cache_read = 0,
    .cache_write = 0,
    .total_tokens = 0,
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
};

pub fn fauxModel() protocol.Model {
    return .{
        .id = FAUX_MODEL_ID,
        .name = "Faux Model",
        .api = FAUX_API,
        .provider = FAUX_PROVIDER,
        .base_url = "http://localhost:0",
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 16384,
    };
}

pub fn fauxText(text: []const u8) protocol.AssistantMessage.AssistantContentBlock {
    return .{ .text = .{ .text = text } };
}

pub fn fauxToolCall(name: []const u8, id: []const u8, arguments: json_value.OwnedValue) protocol.AssistantMessage.AssistantContentBlock {
    return .{ .tool_call = .{ .id = id, .name = name, .arguments = arguments } };
}

pub fn fauxAssistantMessage(
    allocator: std.mem.Allocator,
    content: []const protocol.AssistantMessage.AssistantContentBlock,
    stop_reason: protocol.StopReason,
) protocol.AssistantMessage {
    const owned = allocator.dupe(protocol.AssistantMessage.AssistantContentBlock, content) catch
        @panic("fauxAssistantMessage: allocation failed");
    return .{
        .content = owned,
        .api = FAUX_API,
        .provider = FAUX_PROVIDER,
        .model = FAUX_MODEL_ID,
        .usage = DEFAULT_USAGE,
        .stop_reason = stop_reason,
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    };
}

pub const FauxProvider = struct {
    responses: std.ArrayListUnmanaged(protocol.AssistantMessage),
    captured_contexts: std.ArrayListUnmanaged(protocol.Context),
    call_count: usize,
    allocator: std.mem.Allocator,
    block_until_cancel: bool = false,

    const vtable: ai_provider.Provider.VTable = .{
        .stream = streamImpl,
        .stream_simple = streamSimpleImpl,
        .get_name = getNameImpl,
        .deinit = deinitImpl,
    };

    pub fn init(allocator: std.mem.Allocator) FauxProvider {
        return .{
            .responses = .empty,
            .captured_contexts = .empty,
            .call_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FauxProvider) void {
        self.responses.deinit(self.allocator);
        self.captured_contexts.deinit(self.allocator);
    }

    pub fn setResponses(self: *FauxProvider, msgs: []const protocol.AssistantMessage) void {
        self.responses.clearRetainingCapacity();
        self.responses.appendSlice(self.allocator, msgs) catch
            @panic("FauxProvider.setResponses: allocation failed");
    }

    pub fn setBlockUntilCancel(self: *FauxProvider, value: bool) void {
        self.block_until_cancel = value;
    }

    pub fn provider(self: *FauxProvider) ai_provider.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn getSelf(ptr: *anyopaque) *FauxProvider {
        return @ptrCast(@alignCast(ptr));
    }

    fn streamImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        sink: ai_provider.StreamEventSink,
    ) void {
        const self = getSelf(ptr);
        self.call_count += 1;
        self.captured_contexts.append(self.allocator, context) catch {
            sink.emit(.{ .@"error" = .{ .reason = .@"error", .@"error" = .{
                .content = &.{},
                .api = FAUX_API,
                .provider = FAUX_PROVIDER,
                .model = FAUX_MODEL_ID,
                .usage = DEFAULT_USAGE,
                .stop_reason = .@"error",
                .error_message = "failed to capture faux context",
                .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
            } } });
            return;
        };

        if (self.block_until_cancel) {
            while (!options.signal.isAborted()) {
                std.Options.debug_io.sleep(.fromMilliseconds(10), .awake) catch {};
            }
            const err_msg: protocol.AssistantMessage = .{
                .content = &.{},
                .api = FAUX_API,
                .provider = FAUX_PROVIDER,
                .model = FAUX_MODEL_ID,
                .usage = DEFAULT_USAGE,
                .stop_reason = .aborted,
                .error_message = "aborted",
                .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
            };
            sink.emit(.{ .@"error" = .{ .reason = .aborted, .@"error" = err_msg } });
            return;
        }

        if (self.responses.items.len == 0) {
            const err_msg: protocol.AssistantMessage = .{
                .content = &.{},
                .api = FAUX_API,
                .provider = FAUX_PROVIDER,
                .model = FAUX_MODEL_ID,
                .usage = DEFAULT_USAGE,
                .stop_reason = .@"error",
                .error_message = "No more faux responses queued",
                .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
            };
            sink.emit(.{ .@"error" = .{ .reason = .@"error", .@"error" = err_msg } });
            return;
        }

        const message = self.responses.orderedRemove(0);

        _ = allocator;
        sink.emit(.start);

        for (message.content, 0..) |block, idx| {
            switch (block) {
                .text => |text_content| {
                    sink.emit(.{ .text_start = .{ .content_index = idx } });
                    sink.emit(.{ .text_delta = .{ .content_index = idx, .delta = text_content.text } });
                    sink.emit(.{ .text_end = .{ .content_index = idx, .content = text_content.text } });
                },
                .thinking => |thinking_content| {
                    sink.emit(.{ .thinking_start = .{ .content_index = idx } });
                    sink.emit(.{ .thinking_delta = .{ .content_index = idx, .delta = thinking_content.thinking } });
                    sink.emit(.{ .thinking_end = .{ .content_index = idx, .content = thinking_content.thinking } });
                },
                .tool_call => |tc| {
                    sink.emit(.{ .toolcall_start = .{ .content_index = idx } });
                    sink.emit(.{ .toolcall_delta = .{ .content_index = idx, .delta = "" } });
                    sink.emit(.{ .toolcall_end = .{ .content_index = idx, .tool_call = tc } });
                },
            }
        }

        if (message.stop_reason == .@"error" or message.stop_reason == .aborted) {
            const reason: protocol.AssistantMessageEvent.ErrorReason = if (message.stop_reason == .aborted) .aborted else .@"error";
            sink.emit(.{ .@"error" = .{ .reason = reason, .@"error" = message } });
        } else {
            const reason: protocol.AssistantMessageEvent.DoneReason = switch (message.stop_reason) {
                .stop => .stop,
                .length => .length,
                .toolUse => .toolUse,
                else => unreachable,
            };
            sink.emit(.{ .done = .{ .reason = reason, .message = message } });
        }
    }

    fn streamSimpleImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        sink: ai_provider.StreamEventSink,
    ) void {
        streamImpl(ptr, allocator, model, context, options.base, sink);
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "faux";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self = getSelf(ptr);
        self.deinit();
    }
};

test "faux provider streams text response" {
    const allocator = std.testing.allocator;

    var faux = FauxProvider.init(allocator);
    defer faux.deinit();

    const content = [_]protocol.AssistantMessage.AssistantContentBlock{fauxText("hello world")};
    const msg = fauxAssistantMessage(allocator, &content, .stop);
    defer allocator.free(msg.content);

    faux.setResponses(&.{msg});

    const Collector = struct {
        events: std.ArrayListUnmanaged(protocol.AssistantMessageEvent),
        alloc: std.mem.Allocator,

        fn callback(event: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events.append(self.alloc, event) catch @panic("alloc failed");
        }
    };

    var collector: Collector = .{ .events = .empty, .alloc = allocator };
    defer collector.events.deinit(allocator);
    var terminal_tracker: ai_stream.TerminalTracker = .{};
    var tracking_sink: ai_stream.TrackingSink = .{
        .tracker = &terminal_tracker,
        .inner = .{ .func = Collector.callback, .ctx = @ptrCast(&collector) },
    };

    const p = faux.provider();
    p.stream(allocator, fauxModel(), .{ .messages = &.{} }, .{}, tracking_sink.sink());

    try std.testing.expectEqual(@as(usize, 5), collector.events.items.len);

    try std.testing.expect(collector.events.items[0] == .start);
    try std.testing.expect(collector.events.items[1] == .text_start);
    try std.testing.expect(collector.events.items[2] == .text_delta);
    try std.testing.expect(collector.events.items[3] == .text_end);
    try std.testing.expect(collector.events.items[4] == .done);

    try std.testing.expectEqualStrings("hello world", collector.events.items[2].text_delta.delta);
    try std.testing.expectEqualStrings("hello world", collector.events.items[3].text_end.content);
    try std.testing.expectEqual(ai_stream.TerminalKind.completed, try terminal_tracker.finish());
    try std.testing.expectEqual(@as(usize, 1), faux.call_count);
}
