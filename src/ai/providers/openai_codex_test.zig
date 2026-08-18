const std = @import("std");
const codex = @import("openai_codex.zig");
const fake_api = @import("../transport/fake.zig");
const message = @import("../message.zig");
const openai_responses = @import("../protocol/openai_responses.zig");
const transport = @import("../transport.zig");

const Inspector = struct {
    saw_request: bool = false,

    fn inspect(context: *anyopaque, request: transport.Request) error{Rejected}!void {
        const self: *Inspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://chatgpt.com/backend-api/codex/responses")) return error.Rejected;
        var authorization = false;
        var account = false;
        var originator = false;
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization") and
                std.mem.startsWith(u8, header.value, "Bearer aaa.")) authorization = true;
            if (std.ascii.eqlIgnoreCase(header.name, "chatgpt-account-id") and
                std.mem.eql(u8, header.value, "acc_test")) account = true;
            if (std.ascii.eqlIgnoreCase(header.name, "originator") and
                std.mem.eql(u8, header.value, "zi")) originator = true;
        }
        if (!authorization or !account or !originator) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"include\":[\"reasoning.encrypted_content\"]") == null) {
            return error.Rejected;
        }
        if (std.mem.indexOf(u8, request.body, "\"parallel_tool_calls\":true") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"instructions\":\"You are concise.\\nUse read.\"") == null) {
            return error.Rejected;
        }
        self.saw_request = true;
    }
};

test "Codex Responses derives account identity and normalizes SSE" {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc_test\"}}";
    const encoded_size = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try std.testing.allocator.alloc(u8, encoded_size);
    defer std.testing.allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    const token = try std.fmt.allocPrint(std.testing.allocator, "aaa.{s}.bbb", .{encoded});
    defer std.testing.allocator.free(token);
    const response =
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}
        \\
        \\data: {"type":"response.reasoning_summary_text.delta","output_index":0,"delta":"why"}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"enc"}}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.content_part.added","output_index":1,"part":{"type":"output_text","text":""}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":1,"delta":"Hello"}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"Hello"}]}}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":5,"output_tokens":3,"input_tokens_details":{"cached_tokens":2}}}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{ .status = 200, .body = response, .chunk_bytes = 13 } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: Inspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = Inspector.inspect };
    var provider = codex.OpenAiCodex.init(fake.transport(), .{
        .model_id = "gpt-5.1-codex",
        .access_token = token,
    });
    const request_parts = [_]message.RequestPart{.{ .user = .{ .text = "Say hello" } }};
    const messages = [_]message.Message{.{ .request = .{ .parts = &request_parts } }};

    var result = try provider.modelView().complete(std.testing.allocator, std.testing.io, .{
        .messages = &messages,
        .instructions = &.{ "You are concise.", "Use read." },
        .settings = .{ .reasoning_effort = .medium },
    });
    defer result.deinit();

    try std.testing.expect(inspector.saw_request);
    try std.testing.expectEqual(@as(usize, 2), result.value.parts.len);
    try std.testing.expectEqualStrings("why", result.value.parts[0].thinking.text);
    const reasoning_state = result.value.parts[0].thinking.provider_state.?.value.object;
    try std.testing.expectEqualStrings("enc", reasoning_state.get("encrypted_content").?.string);
    try std.testing.expectEqualStrings("Hello", result.value.parts[1].text.text);
    const replay_messages = [_]message.Message{.{ .response = result.value }};
    const replay_body = try openai_responses.encodeCodexRequest(
        std.testing.allocator,
        "gpt-5.1-codex",
        .{ .messages = &replay_messages },
    );
    defer std.testing.allocator.free(replay_body);
    try std.testing.expect(std.mem.indexOf(u8, replay_body, "\"encrypted_content\":\"enc\"") != null);
    try std.testing.expectEqual(@as(u64, 2), result.value.usage.cached_input_tokens);
    try std.testing.expectEqual(.stop, result.value.finish.category);
}

test "Codex account ID parser rejects tokens without the auth claim" {
    const payload = "{}";
    const encoded_size = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try std.testing.allocator.alloc(u8, encoded_size);
    defer std.testing.allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    const token = try std.fmt.allocPrint(std.testing.allocator, "aaa.{s}.bbb", .{encoded});
    defer std.testing.allocator.free(token);
    try std.testing.expectError(error.InvalidRequest, codex.accountIdFromJwt(std.testing.allocator, token));
}

test "Codex Responses accumulates streamed tool arguments" {
    const response =
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read"}}
        \\
        \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":"}
        \\
        \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"\"src\"}"}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read","arguments":"{\"path\":\"src\"}"}}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{.{ .response = .{
        .status = 200,
        .body = response,
        .chunk_bytes = 11,
    } }};
    var fake = fake_api.FakeTransport.init(&exchanges);
    var provider = codex.OpenAiCodex.init(fake.transport(), .{
        .model_id = "gpt-5.1-codex",
        .access_token = "token",
        .account_id = "acc_test",
    });
    const tools = [_]message.ToolDefinition{.{
        .name = "read",
        .description = "Read a path",
        .parameters_json_schema = "{\"type\":\"object\"}",
    }};

    var result = try provider.modelView().complete(std.testing.allocator, std.testing.io, .{
        .messages = &.{},
        .tools = &tools,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.value.parts.len);
    try std.testing.expectEqualStrings("call_1", result.value.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("read", result.value.parts[0].tool_call.name);
    try std.testing.expectEqualStrings("{\"path\":\"src\"}", result.value.parts[0].tool_call.arguments_json);
    try std.testing.expectEqual(.tool_calls, result.value.finish.category);
}
