const std = @import("std");
const compatible = @import("openai_compatible.zig");
const fake_api = @import("../transport/fake.zig");
const stream = @import("../stream.zig");
const transport = @import("../transport.zig");
const message = @import("../message.zig");
const model_catalog = @import("../model_catalog.zig");
const settings = @import("../settings.zig");

const profile = profile: {
    var value: settings.ModelProfile = .{};
    value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
    value.settings = .initMany(&.{ .temperature, .top_p, .max_output_tokens, .stop_sequences, .seed });
    break :profile value;
};
const catalog_entries = [_]model_catalog.Entry{.{
    .identity = .{ .provider = "openai-compatible", .model = "local-model" },
    .profile = profile,
}};
const catalog: model_catalog.Catalog = .{ .entries = &catalog_entries };

const RequestInspector = struct {
    saw_request: bool = false,

    fn inspect(context: *anyopaque, request: transport.Request) error{Rejected}!void {
        const self: *RequestInspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://example.test/v1/chat/completions")) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"model\":\"local-model\"") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"role\":\"system\",\"content\":\"Inspect before acting.\"") == null) {
            return error.Rejected;
        }
        if (std.mem.indexOf(u8, request.body, "\"content\":\"hello\"") == null) return error.Rejected;
        var authorized = false;
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization") and
                std.mem.eql(u8, header.value, "Bearer secret")) authorized = true;
        }
        if (!authorized) return error.Rejected;
        self.saw_request = true;
    }
};

test "OpenAI-compatible buffered invocation crosses model and transport seams" {
    const response =
        \\{"choices":[{"message":{"content":"world"},"finish_reason":"stop"}],
        \\ "usage":{"prompt_tokens":3,"completion_tokens":2}}
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: RequestInspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = RequestInspector.inspect };
    var provider = compatible.OpenAiCompatible.init(fake.transport(), .{
        .provider_id = "openai-compatible",
        .catalog = catalog,
        .base_url = "https://example.test/v1",
        .api_key = "secret",
    });
    const request_parts = [_]message.RequestPart{.{ .user = .{ .text = "hello" } }};
    const messages = [_]message.Message{.{ .request = .{ .parts = &request_parts } }};

    var result = try provider.model("local-model").?.complete(std.testing.allocator, std.testing.io, .{
        .messages = &messages,
        .instructions = &.{"Inspect before acting."},
    });
    defer result.deinit();

    try std.testing.expect(inspector.saw_request);
    try std.testing.expectEqualStrings("world", result.value.parts[0].text.text);
    try std.testing.expectEqual(@as(u64, 3), result.value.usage.input_tokens);
    try std.testing.expectEqual(.stop, result.value.finish.category);
}

const EventCollector = struct {
    events: usize = 0,
    text: std.ArrayList(u8) = .empty,
    tool_arguments: std.ArrayList(u8) = .empty,

    fn emit(context: *anyopaque, event: stream.StreamEvent) stream.StreamSinkError!void {
        const self: *EventCollector = @ptrCast(@alignCast(context));
        self.events += 1;
        switch (event) {
            .part_delta => |delta| switch (delta.delta) {
                .text => |text| self.text.appendSlice(std.testing.allocator, text) catch return error.OutOfMemory,
                .tool_call => |tool| self.tool_arguments.appendSlice(
                    std.testing.allocator,
                    tool.arguments_delta,
                ) catch return error.OutOfMemory,
                else => {},
            },
            else => {},
        }
    }
};

test "OpenAI-compatible SSE preserves text and indexed tool calls" {
    const body =
        \\data: {"choices":[{"delta":{"content":"hel"},"finish_reason":null}]}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"choices":[{"delta":{"content":"lo","tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{\"path\":"}}]},"finish_reason":null}]}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a\"}"}}]},"finish_reason":"tool_calls"}]}
        \\
        \\data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":4}}
        \\
        \\data: [DONE]
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = body, .chunk_bytes = 17 } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var provider = compatible.OpenAiCompatible.init(fake.transport(), .{
        .provider_id = "openai-compatible",
        .catalog = catalog,
        .base_url = "https://example.test/v1",
    });
    var collector: EventCollector = .{};
    defer collector.text.deinit(std.testing.allocator);
    defer collector.tool_arguments.deinit(std.testing.allocator);
    const sink: stream.StreamSink = .{ .context = &collector, .emitFn = EventCollector.emit };

    var result = try provider.model("local-model").?.stream(
        std.testing.allocator,
        std.testing.io,
        .{ .messages = &.{} },
        sink,
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("hello", collector.text.items);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", collector.tool_arguments.items);
    try std.testing.expectEqual(@as(usize, 2), result.value.parts.len);
    try std.testing.expectEqualStrings("hello", result.value.parts[0].text.text);
    try std.testing.expectEqualStrings("read", result.value.parts[1].tool_call.name);
    try std.testing.expectEqual(.tool_calls, result.value.finish.category);
    try std.testing.expect(collector.events >= 7);
}

test "OpenAI-compatible preserves application stream stop" {
    const body =
        \\data: {"choices":[{"delta":{"content":"stop"},"finish_reason":null}]}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{
        .status = 200,
        .body = body,
    } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var provider = compatible.OpenAiCompatible.init(fake.transport(), .{
        .provider_id = "openai-compatible",
        .catalog = catalog,
        .base_url = "https://example.test/v1",
    });
    const StopSink = struct {
        fn emit(_: *anyopaque, _: stream.StreamEvent) stream.StreamSinkError!void {
            return error.ConsumerStopped;
        }
    };
    var context: u8 = 0;
    const sink: stream.StreamSink = .{ .context = &context, .emitFn = StopSink.emit };

    try std.testing.expectError(error.StreamConsumerStopped, provider.model("local-model").?.stream(
        std.testing.allocator,
        std.testing.io,
        .{ .messages = &.{} },
        sink,
    ));
}

test "OpenAI-compatible rejects foreign provider state before transport" {
    const exchanges: [0]fake_api.Exchange = .{};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var provider = compatible.OpenAiCompatible.init(fake.transport(), .{
        .provider_id = "openai-compatible",
        .catalog = catalog,
        .base_url = "https://example.test/v1",
    });
    const response_parts = [_]message.ResponsePart{.{ .thinking = .{
        .text = "thought",
        .provider_state = .{
            .provider = "openai-codex",
            .protocol = "openai-codex-responses",
            .value = .{ .string = "opaque" },
        },
    } }};
    const messages = [_]message.Message{.{ .response = .{
        .parts = &response_parts,
        .identity = .{ .provider = "openai-codex", .model = "codex" },
    } }};

    try std.testing.expectError(error.HandoffRejected, provider.model("local-model").?.complete(
        std.testing.allocator,
        std.testing.io,
        .{ .messages = &messages, .handoff = .reject_foreign_state },
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.next_index);
}
