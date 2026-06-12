const std = @import("std");
const protocol = @import("protocol.zig");

pub const ApiProvider = struct {
    api: protocol.Api,
    stream: protocol.StreamFunction,
    stream_simple: protocol.StreamFunction,
};

const RegisteredProvider = struct {
    provider: ApiProvider,
    source_id: ?[]const u8 = null,
};

pub const ProviderRegistry = struct {
    allocator: std.mem.Allocator,
    providers: std.StringHashMapUnmanaged(RegisteredProvider) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProviderRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProviderRegistry) void {
        self.providers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *ProviderRegistry, provider: ApiProvider, source_id: ?[]const u8) !void {
        try self.providers.put(self.allocator, provider.api, .{
            .provider = provider,
            .source_id = source_id,
        });
    }

    pub fn get(self: *const ProviderRegistry, api: protocol.Api) ?ApiProvider {
        return if (self.providers.get(api)) |registered| registered.provider else null;
    }

    pub fn unregisterSource(self: *ProviderRegistry, source_id: []const u8) void {
        // Removing while iterating invalidates std hashmap iterators, so
        // restart the scan after each removal. Provider counts are tiny.
        restart: while (true) {
            var iterator = self.providers.iterator();
            while (iterator.next()) |entry| {
                const registered_source_id = entry.value_ptr.source_id orelse continue;
                if (std.mem.eql(u8, registered_source_id, source_id)) {
                    _ = self.providers.remove(entry.key_ptr.*);
                    continue :restart;
                }
            }
            return;
        }
    }

    pub fn clear(self: *ProviderRegistry) void {
        self.providers.clearRetainingCapacity();
    }
};

test "provider registry returns registered provider by api" {
    var registry = ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var calls: usize = 0;
    const provider = testProvider(protocol.KnownApi.openai_responses, &calls);

    try registry.register(provider, null);

    const registered = registry.get(protocol.KnownApi.openai_responses).?;
    _ = registered.stream.call(testRequest(protocol.KnownApi.openai_responses));
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "registering same api routes future calls to replacement provider" {
    var registry = ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var first_calls: usize = 0;
    var second_calls: usize = 0;

    try registry.register(testProvider(protocol.KnownApi.openai_responses, &first_calls), "first");
    try registry.register(testProvider(protocol.KnownApi.openai_responses, &second_calls), "second");

    const registered = registry.get(protocol.KnownApi.openai_responses).?;
    _ = registered.stream.call(testRequest(protocol.KnownApi.openai_responses));
    try std.testing.expectEqual(@as(usize, 0), first_calls);
    try std.testing.expectEqual(@as(usize, 1), second_calls);
}

test "provider registry returns null for missing api" {
    var registry = ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(?ApiProvider, null), registry.get(protocol.KnownApi.anthropic_messages));
}

test "provider registry unregisters providers by source id" {
    var registry = ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var openai_calls: usize = 0;
    var anthropic_calls: usize = 0;
    try registry.register(testProvider(protocol.KnownApi.openai_responses, &openai_calls), "extension-a");
    try registry.register(testProvider(protocol.KnownApi.anthropic_messages, &anthropic_calls), "extension-b");

    registry.unregisterSource("extension-a");

    try std.testing.expectEqual(@as(?ApiProvider, null), registry.get(protocol.KnownApi.openai_responses));
    try std.testing.expect(registry.get(protocol.KnownApi.anthropic_messages) != null);
}

test "provider registry unregisters multiple providers from one source" {
    var registry = ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var calls: usize = 0;
    try registry.register(testProvider(protocol.KnownApi.openai_responses, &calls), "extension-a");
    try registry.register(testProvider(protocol.KnownApi.anthropic_messages, &calls), "extension-a");
    try registry.register(testProvider(protocol.KnownApi.openai_completions, &calls), "extension-b");

    registry.unregisterSource("extension-a");

    try std.testing.expectEqual(@as(?ApiProvider, null), registry.get(protocol.KnownApi.openai_responses));
    try std.testing.expectEqual(@as(?ApiProvider, null), registry.get(protocol.KnownApi.anthropic_messages));
    try std.testing.expect(registry.get(protocol.KnownApi.openai_completions) != null);
}

test "provider registry clear removes all providers" {
    var registry = ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var openai_calls: usize = 0;
    var anthropic_calls: usize = 0;
    try registry.register(testProvider(protocol.KnownApi.openai_responses, &openai_calls), null);
    try registry.register(testProvider(protocol.KnownApi.anthropic_messages, &anthropic_calls), null);

    registry.clear();

    try std.testing.expectEqual(@as(?ApiProvider, null), registry.get(protocol.KnownApi.openai_responses));
    try std.testing.expectEqual(@as(?ApiProvider, null), registry.get(protocol.KnownApi.anthropic_messages));
}

fn testProvider(api: protocol.Api, calls: *usize) ApiProvider {
    return .{
        .api = api,
        .stream = .{ .context = calls, .call_fn = testStreamFunction },
        .stream_simple = .{ .context = calls, .call_fn = testStreamFunction },
    };
}

fn testStreamFunction(context: ?*anyopaque, request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    const calls: *usize = @ptrCast(@alignCast(context.?));
    calls.* += 1;
    _ = request;
    return protocol.AssistantMessageEventStream.initBuffered();
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
