const std = @import("std");
const fake_api = @import("../transport/fake.zig");
const message = @import("../message.zig");
const model_catalog = @import("../model_catalog.zig");
const openai_responses = @import("../protocol/openai_responses.zig");
const protocol_api = @import("../protocol.zig");
const provider_api = @import("../provider.zig");
const responses = @import("openai_responses.zig");
const settings = @import("../settings.zig");
const transport = @import("../transport.zig");

const profile = profile: {
    var value: settings.ModelProfile = .{
        .context_window = 128_000,
        .max_output_tokens = 16_000,
    };
    value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
    value.settings = .initMany(&.{ .max_output_tokens, .reasoning_effort });
    value.reasoning_efforts = .initMany(&.{ .low, .medium, .high });
    break :profile value;
};
const catalog_entries = [_]model_catalog.Entry{.{
    .identity = .{ .provider = "openai", .model = "gpt-test" },
    .protocol_id = "openai-responses",
    .aliases = &.{"latest"},
    .profile = profile,
}};
const catalog: model_catalog.Catalog = .{ .entries = &catalog_entries };
const protocol_implementation: responses.OpenAiResponses = .{};
const protocols = [_]protocol_api.Protocol{protocol_implementation.protocol()};

fn makeProvider(transport_value: transport.Transport, api_key: ?[]const u8) provider_api.Configured {
    return .{
        .transport = transport_value,
        .protocols = protocol_api.Registry.init(&protocols) catch unreachable,
        .catalog = catalog,
        .definition = .{
            .id = "openai",
            .name = "OpenAI",
            .base_url = "https://api.openai.com/v1",
            .auth = .{ .api_key = .{}, .allow_unauthenticated = true },
        },
        .auth_inputs = .{ .explicit_api_key = api_key },
    };
}

const Inspector = struct {
    saw_request: bool = false,

    fn inspect(context: *anyopaque, request: transport.Request) error{Rejected}!void {
        const self: *Inspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://api.openai.com/v1/responses")) return error.Rejected;
        if (!hasHeader(request, "content-type", "application/json")) return error.Rejected;
        if (!hasHeader(request, "authorization", "Bearer secret")) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"model\":\"gpt-test\"") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"role\":\"developer\"") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"text\":\"Be concise.\"") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"max_output_tokens\":16") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"effort\":\"medium\"") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"include\":[\"reasoning.encrypted_content\"]") == null) {
            return error.Rejected;
        }
        if (std.mem.indexOf(u8, request.body, "\"name\":\"read\"") == null) return error.Rejected;
        self.saw_request = true;
    }
};

fn hasHeader(request: transport.Request, name: []const u8, value: []const u8) bool {
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) return true;
    }
    return false;
}

test "OpenAI Responses crosses catalog model protocol and transport seams" {
    const response =
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}
        \\
        \\data: {"type":"response.reasoning_summary_text.delta","output_index":0,"delta":"why"}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"enc"}}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_1","phase":"commentary","content":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":1,"delta":"Hello"}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_1","phase":"final_answer","content":[{"type":"output_text","text":"Hello"}]}}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":3,"input_tokens_details":{"cached_tokens":2,"cache_write_tokens":1}}}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response, .chunk_bytes = 13 } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: Inspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = Inspector.inspect };
    var provider = makeProvider(fake.transport(), "secret");
    const request_parts = [_]message.RequestPart{.{ .user = .{ .text = "hello" } }};
    const messages = [_]message.Message{.{ .request = .{ .parts = &request_parts } }};
    const tools = [_]message.ToolDefinition{.{
        .name = "read",
        .description = "Read a path",
        .parameters_json_schema = "{\"type\":\"object\"}",
    }};

    const model = provider.model("latest").?;
    try std.testing.expectEqualStrings("gpt-test", model.identity.model);
    var result = try model.complete(std.testing.allocator, std.testing.io, .{
        .messages = &messages,
        .instructions = &.{"Be concise."},
        .tools = &tools,
        .settings = .{ .max_output_tokens = 1, .reasoning_effort = .medium },
    });
    defer result.deinit();

    try std.testing.expect(inspector.saw_request);
    try std.testing.expectEqualStrings("why", result.value.parts[0].thinking.text);
    try std.testing.expectEqualStrings(
        "openai-responses",
        result.value.parts[0].thinking.provider_state.?.protocol,
    );
    try std.testing.expectEqualStrings("Hello", result.value.parts[1].text.text);
    try std.testing.expectEqual(@as(u64, 2), result.value.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), result.value.usage.cached_input_tokens);
    const replay_messages = [_]message.Message{.{ .response = result.value }};
    const replay_body = try openai_responses.encodeRequest(
        std.testing.allocator,
        model.identity,
        .{ .messages = &replay_messages },
    );
    defer std.testing.allocator.free(replay_body);
    try std.testing.expect(std.mem.indexOf(u8, replay_body, "\"encrypted_content\":\"enc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay_body, "\"id\":\"msg_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay_body, "\"phase\":\"final_answer\"") != null);
}

test "Responses encoder gives empty tool results explicit output" {
    const request_parts = [_]message.RequestPart{.{ .tool_result = .{
        .call_id = "call-1",
        .name = "read",
        .content = &.{},
        .outcome = .success,
    } }};
    const messages = [_]message.Message{.{ .request = .{ .parts = &request_parts } }};
    const body = try openai_responses.encodeRequest(
        std.testing.allocator,
        .{ .provider = "openai", .model = "gpt-test" },
        .{ .messages = &messages },
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output\":\"(no tool output)\"") != null);
}

test "Responses decoder accepts response done without misdirecting index-less deltas" {
    const response =
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.output_item.added","output_index":1,"item":{"type":"computer_call","id":"ignored"}}
        \\
        \\data: {"type":"response.output_text.delta","delta":"done"}
        \\
        \\data: {"type":"response.done","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var provider = makeProvider(fake.transport(), null);
    var result = try provider.model("gpt-test").?.complete(
        std.testing.allocator,
        std.testing.io,
        .{ .messages = &.{} },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.value.parts[0].text.text);
}

test "Responses decoder retains reasoning refusal and terminal encrypted state" {
    const response =
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}
        \\
        \\data: {"type":"response.reasoning_summary_text.delta","output_index":0,"delta":"summary"}
        \\
        \\data: {"type":"response.reasoning_summary_part.done","output_index":0}
        \\
        \\data: {"type":"response.reasoning_text.delta","output_index":0,"delta":"raw"}
        \\
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.refusal.delta","output_index":1,"delta":"refused"}
        \\
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","id":"rs_1","encrypted_content":"terminal-enc"}]}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var provider = makeProvider(fake.transport(), null);
    var result = try provider.model("gpt-test").?.complete(
        std.testing.allocator,
        std.testing.io,
        .{ .messages = &.{} },
    );
    defer result.deinit();
    try std.testing.expectEqualStrings("summary\n\nraw", result.value.parts[0].thinking.text);
    try std.testing.expectEqualStrings("refused", result.value.parts[1].text.text);
    try std.testing.expectEqualStrings(
        "terminal-enc",
        result.value.parts[0].thinking.provider_state.?.value.object.get("encrypted_content").?.string,
    );
}

test "Responses decoder rejects provider error events" {
    const failures = [_][]const u8{
        \\data: {"type":"error","code":"server_error","message":"failed"}
        \\
        ,
        // ziglint-ignore: Z024 -- compact provider wire fixture
        \\data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"failed"}}}
        \\
        ,
        \\data: {"type":"response.done","response":{"status":"failed"}}
        \\
        ,
    };
    for (failures) |response| {
        const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response } }};
        var fake = fake_api.FakeTransport.init(&exchanges);
        var provider = makeProvider(fake.transport(), null);
        try std.testing.expectError(
            error.InvalidProviderResponse,
            provider.model("gpt-test").?.complete(std.testing.allocator, std.testing.io, .{ .messages = &.{} }),
        );
    }

    const cancelled =
        \\data: {"type":"response.done","response":{"status":"cancelled"}}
        \\
    ;
    const cancelled_exchanges = [_]fake_api.Exchange{.{
        .response = .{ .status = 200, .body = cancelled },
    }};
    var fake = fake_api.FakeTransport.init(&cancelled_exchanges);
    var provider = makeProvider(fake.transport(), null);
    try std.testing.expectError(
        error.Cancelled,
        provider.model("gpt-test").?.complete(std.testing.allocator, std.testing.io, .{ .messages = &.{} }),
    );
}

test "Responses decoder rejects an output index reused with another part kind" {
    const response =
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}
        \\
        \\data: {"type":"response.content_part.added","output_index":0,"part":{"type":"output_text","text":""}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var provider = makeProvider(fake.transport(), null);

    try std.testing.expectError(
        error.InvalidProviderResponse,
        provider.model("gpt-test").?.complete(std.testing.allocator, std.testing.io, .{ .messages = &.{} }),
    );
}
