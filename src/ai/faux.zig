const std = @import("std");
const protocol = @import("protocol.zig");
const ai_provider = @import("provider.zig");

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

pub fn fauxToolCall(name: []const u8, id: []const u8, arguments: std.json.Value) protocol.AssistantMessage.AssistantContentBlock {
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
        .timestamp = std.time.milliTimestamp(),
    };
}

pub const FauxProvider = struct {
    responses: std.ArrayListUnmanaged(protocol.AssistantMessage),
    captured_contexts: std.ArrayListUnmanaged(protocol.Context),
    call_count: usize,
    allocator: std.mem.Allocator,

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
        _: protocol.StreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        const self = getSelf(ptr);
        self.call_count += 1;
        self.captured_contexts.append(self.allocator, context) catch {};

        if (self.responses.items.len == 0) {
            const err_msg: protocol.AssistantMessage = .{
                .content = &.{},
                .api = FAUX_API,
                .provider = FAUX_PROVIDER,
                .model = FAUX_MODEL_ID,
                .usage = DEFAULT_USAGE,
                .stop_reason = .@"error",
                .error_message = "No more faux responses queued",
                .timestamp = std.time.milliTimestamp(),
            };
            callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = err_msg } }, callback_ctx);
            return;
        }

        const message = self.responses.orderedRemove(0);

        // Build a growing content slice for the partial message.
        var partial_content = std.ArrayListUnmanaged(protocol.AssistantMessage.AssistantContentBlock){};
        defer partial_content.deinit(allocator);

        var partial: protocol.AssistantMessage = .{
            .content = &.{},
            .api = message.api,
            .provider = message.provider,
            .model = message.model,
            .usage = message.usage,
            .stop_reason = message.stop_reason,
            .error_message = message.error_message,
            .response_id = message.response_id,
            .timestamp = message.timestamp,
        };

        // start event with empty content
        callback(.{ .start = .{ .partial = partial } }, callback_ctx);

        for (message.content, 0..) |block, idx| {
            switch (block) {
                .text => |text_content| {
                    // Add empty text block to partial
                    partial_content.append(allocator, .{ .text = .{ .text = "" } }) catch @panic("alloc failed");
                    partial.content = partial_content.items;
                    callback(.{ .text_start = .{ .content_index = idx, .partial = partial } }, callback_ctx);

                    // Update partial with full text
                    partial_content.items[idx] = .{ .text = .{ .text = text_content.text } };
                    partial.content = partial_content.items;
                    callback(.{ .text_delta = .{ .content_index = idx, .delta = text_content.text, .partial = partial } }, callback_ctx);

                    callback(.{ .text_end = .{ .content_index = idx, .content = text_content.text, .partial = partial } }, callback_ctx);
                },
                .thinking => |thinking_content| {
                    partial_content.append(allocator, .{ .thinking = .{ .thinking = "" } }) catch @panic("alloc failed");
                    partial.content = partial_content.items;
                    callback(.{ .thinking_start = .{ .content_index = idx, .partial = partial } }, callback_ctx);

                    partial_content.items[idx] = .{ .thinking = .{ .thinking = thinking_content.thinking } };
                    partial.content = partial_content.items;
                    callback(.{ .thinking_delta = .{ .content_index = idx, .delta = thinking_content.thinking, .partial = partial } }, callback_ctx);

                    callback(.{ .thinking_end = .{ .content_index = idx, .content = thinking_content.thinking, .partial = partial } }, callback_ctx);
                },
                .tool_call => |tc| {
                    partial_content.append(allocator, .{ .tool_call = .{ .id = tc.id, .name = tc.name, .arguments = .null } }) catch @panic("alloc failed");
                    partial.content = partial_content.items;
                    callback(.{ .toolcall_start = .{ .content_index = idx, .partial = partial } }, callback_ctx);

                    callback(.{ .toolcall_delta = .{ .content_index = idx, .delta = "", .partial = partial } }, callback_ctx);

                    partial_content.items[idx] = .{ .tool_call = tc };
                    partial.content = partial_content.items;
                    callback(.{ .toolcall_end = .{ .content_index = idx, .tool_call = tc, .partial = partial } }, callback_ctx);
                },
            }
        }

        // Terminal event
        if (message.stop_reason == .@"error" or message.stop_reason == .aborted) {
            const reason: protocol.AssistantMessageEvent.ErrorReason = if (message.stop_reason == .aborted) .aborted else .@"error";
            callback(.{ .@"error" = .{ .reason = reason, .@"error" = message } }, callback_ctx);
        } else {
            const reason: protocol.AssistantMessageEvent.DoneReason = switch (message.stop_reason) {
                .stop => .stop,
                .length => .length,
                .toolUse => .toolUse,
                else => unreachable,
            };
            callback(.{ .done = .{ .reason = reason, .message = message } }, callback_ctx);
        }
    }

    fn streamSimpleImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        streamImpl(ptr, allocator, model, context, options.base, callback, callback_ctx);
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

    const p = faux.provider();
    p.stream(allocator, fauxModel(), .{ .messages = &.{} }, .{}, Collector.callback, &collector);

    // Expected sequence: start, text_start, text_delta, text_end, done = 5 events
    try std.testing.expectEqual(@as(usize, 5), collector.events.items.len);

    // Verify event types
    try std.testing.expect(collector.events.items[0] == .start);
    try std.testing.expect(collector.events.items[1] == .text_start);
    try std.testing.expect(collector.events.items[2] == .text_delta);
    try std.testing.expect(collector.events.items[3] == .text_end);
    try std.testing.expect(collector.events.items[4] == .done);

    // Verify delta content
    try std.testing.expectEqualStrings("hello world", collector.events.items[2].text_delta.delta);
    // Verify text_end content
    try std.testing.expectEqualStrings("hello world", collector.events.items[3].text_end.content);
    // Verify call_count incremented
    try std.testing.expectEqual(@as(usize, 1), faux.call_count);
}
