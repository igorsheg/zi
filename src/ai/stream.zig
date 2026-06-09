const std = @import("std");
const protocol = @import("protocol.zig");
const provider_registry = @import("provider_registry.zig");
const runtime = @import("../runtime/root.zig");

pub const StreamError = error{
    NoApiProvider,
    MismatchedApi,
};

pub fn stream(
    registry: *const provider_registry.ProviderRegistry,
    request: protocol.StreamRequest,
) StreamError!protocol.AssistantMessageEventStream {
    const provider = registry.get(request.model.api) orelse return error.NoApiProvider;
    if (!std.mem.eql(u8, provider.api, request.model.api)) return error.MismatchedApi;
    return provider.stream.call(request);
}

pub fn streamSimple(
    registry: *const provider_registry.ProviderRegistry,
    request: protocol.StreamRequest,
) StreamError!protocol.AssistantMessageEventStream {
    const provider = registry.get(request.model.api) orelse return error.NoApiProvider;
    if (!std.mem.eql(u8, provider.api, request.model.api)) return error.MismatchedApi;
    return provider.stream_simple.call(request);
}

pub fn complete(
    registry: *const provider_registry.ProviderRegistry,
    request: protocol.StreamRequest,
) anyerror!protocol.AssistantMessage {
    var assistant_stream = try stream(registry, request);
    var handler: IgnoreEvents = .{};
    return protocol.AssistantMessageEventStream.drain(IgnoreEvents, request.io, &assistant_stream, &handler);
}

pub fn completeSimple(
    registry: *const provider_registry.ProviderRegistry,
    request: protocol.StreamRequest,
) anyerror!protocol.AssistantMessage {
    var assistant_stream = try streamSimple(registry, request);
    var handler: IgnoreEvents = .{};
    return protocol.AssistantMessageEventStream.drain(IgnoreEvents, request.io, &assistant_stream, &handler);
}

const IgnoreEvents = struct {
    pub fn onAssistantMessageEvent(_: *IgnoreEvents, _: protocol.AssistantMessageEvent) !void {}
};

test "stream dispatches request to provider registered for model api" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var calls: usize = 0;
    try registry.register(testProvider(protocol.KnownApi.openai_responses, &calls), null);

    var assistant_stream = try stream(&registry, testRequest(protocol.KnownApi.openai_responses));

    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(assistant_stream.result() != null);
}

test "stream reports missing api provider" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectError(
        error.NoApiProvider,
        stream(&registry, testRequest(protocol.KnownApi.openai_responses)),
    );
}

test "complete drains stream and returns assistant result" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var calls: usize = 0;
    try registry.register(testProvider(protocol.KnownApi.openai_responses, &calls), null);

    const message = try complete(&registry, testRequest(protocol.KnownApi.openai_responses));

    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(protocol.StopReason.stop, message.stop_reason);
}

test "stream simple dispatches request to provider simple function" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var calls: usize = 0;
    try registry.register(testProvider(protocol.KnownApi.openai_responses, &calls), null);

    var assistant_stream = try streamSimple(&registry, testRequest(protocol.KnownApi.openai_responses));

    try std.testing.expectEqual(@as(usize, 10), calls);
    try std.testing.expect(assistant_stream.result() != null);
}

fn testProvider(api: protocol.Api, calls: *usize) provider_registry.ApiProvider {
    return .{
        .api = api,
        .stream = .{ .context = calls, .call_fn = testStreamFunction },
        .stream_simple = .{ .context = calls, .call_fn = testStreamSimpleFunction },
    };
}

fn testStreamFunction(context: ?*anyopaque, request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    return streamWithResult(request);
}

fn testStreamSimpleFunction(
    context: ?*anyopaque,
    request: protocol.StreamRequest,
) protocol.AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 10;
    return streamWithResult(request);
}

fn streamWithResult(request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    var assistant_stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = assistant_stream.sink();
    sink.emit(request.io, .{ .done = .{ .reason = .stop, .message = emptyAssistantMessage() } }) catch unreachable;
    return assistant_stream;
}

fn testRequest(api: protocol.Api) protocol.StreamRequest {
    return .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = .{
            .id = "test-model",
            .name = "Test Model",
            .api = api,
            .provider = protocol.KnownProvider.openai,
            .base_url = "https://example.test",
            .reasoning = false,
            .input = &.{.text},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 1,
            .max_tokens = 1,
        },
        .context = .{ .messages = &.{} },
    };
}

fn emptyAssistantMessage() protocol.AssistantMessage {
    return .{
        .content = &.{},
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}
