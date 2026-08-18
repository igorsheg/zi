const std = @import("std");
const Agent = @import("Agent.zig");
const agent_testing = @import("testing.zig");
const ai_stream = @import("../ai/stream.zig");
const compatible = @import("../ai/providers/openai_compatible.zig");
const codex = @import("../ai/providers/openai_codex.zig");
const fake_api = @import("../ai/transport/fake.zig");
const transport = @import("../ai/transport.zig");

const StreamRecorder = struct {
    count: usize = 0,
    last_request: usize = 0,
    saw_first: bool = false,
    saw_second: bool = false,
    ordered: bool = true,

    fn emit(context: *anyopaque, event: Agent.StreamEvent) ai_stream.StreamSinkError!void {
        const self: *StreamRecorder = @ptrCast(@alignCast(context));
        if (event.request_number < self.last_request) self.ordered = false;
        self.last_request = event.request_number;
        self.saw_first = self.saw_first or event.request_number == 1;
        self.saw_second = self.saw_second or event.request_number == 2;
        self.count += 1;
    }

    fn expectTwoRequests(self: StreamRecorder) !void {
        try std.testing.expect(self.count > 0);
        try std.testing.expect(self.ordered);
        try std.testing.expect(self.saw_first);
        try std.testing.expect(self.saw_second);
        try std.testing.expectEqual(@as(usize, 2), self.last_request);
    }
};

const OpenAiInspector = struct {
    requests: usize = 0,

    fn inspect(context: *anyopaque, request: transport.Request) error{Rejected}!void {
        const self: *OpenAiInspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://api.openai.com/v1/chat/completions")) return error.Rejected;
        if (!hasHeader(request, "authorization", "Bearer secret")) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"model\":\"gpt-4.1\"") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"stream\":true") == null) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"name\":\"read\"") == null) return error.Rejected;

        self.requests += 1;
        switch (self.requests) {
            1 => {
                if (std.mem.indexOf(u8, request.body, "\"content\":\"read src/main.zig\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"role\":\"tool\"") != null) return error.Rejected;
            },
            2 => {
                if (std.mem.indexOf(u8, request.body, "\"tool_calls\"") == null) return error.Rejected;
                if (std.mem.indexOf(u8, request.body, "\"role\":\"tool\"") == null) return error.Rejected;
                if (std.mem.indexOf(u8, request.body, "\"tool_call_id\":\"call_1\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"content\":\"file contents\"") == null) {
                    return error.Rejected;
                }
            },
            else => return error.Rejected,
        }
    }
};

const CodexInspector = struct {
    requests: usize = 0,

    fn inspect(context: *anyopaque, request: transport.Request) error{Rejected}!void {
        const self: *CodexInspector = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, request.url, "https://chatgpt.com/backend-api/codex/responses")) return error.Rejected;
        if (!hasHeader(request, "authorization", "Bearer token")) return error.Rejected;
        if (!hasHeader(request, "chatgpt-account-id", "acc_test")) return error.Rejected;
        if (!hasHeader(request, "originator", "zi")) return error.Rejected;
        if (std.mem.indexOf(u8, request.body, "\"include\":[\"reasoning.encrypted_content\"]") == null) {
            return error.Rejected;
        }
        if (std.mem.indexOf(u8, request.body, "\"name\":\"read\"") == null) return error.Rejected;

        self.requests += 1;
        switch (self.requests) {
            1 => {
                if (std.mem.indexOf(u8, request.body, "\"text\":\"read src/main.zig\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"type\":\"function_call_output\"") != null) {
                    return error.Rejected;
                }
            },
            2 => {
                if (std.mem.indexOf(u8, request.body, "\"type\":\"function_call\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"type\":\"function_call_output\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"call_id\":\"call_1\"") == null) {
                    return error.Rejected;
                }
                if (std.mem.indexOf(u8, request.body, "\"output\":\"file contents\"") == null) {
                    return error.Rejected;
                }
            },
            else => return error.Rejected,
        }
    }
};

fn hasHeader(request: transport.Request, name: []const u8, value: []const u8) bool {
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) return true;
    }
    return false;
}

fn expectCompletedToolLoop(agent: *const Agent, provider: []const u8, final_text: []const u8) !void {
    try std.testing.expect(agent.state() == .completed);
    try std.testing.expectEqual(@as(usize, 2), agent.modelRequests());
    try std.testing.expectEqual(@as(usize, 1), agent.toolCalls());
    try std.testing.expectEqual(@as(usize, 4), agent.messages().len);
    try std.testing.expectEqualStrings("read src/main.zig", agent.messages()[0].request.parts[0].user.text);
    try std.testing.expectEqualStrings(provider, agent.messages()[1].response.identity.provider);
    try std.testing.expectEqualStrings("call_1", agent.messages()[1].response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings(
        "{\"path\":\"src/main.zig\"}",
        agent.messages()[1].response.parts[0].tool_call.arguments_json,
    );
    try std.testing.expectEqualStrings(
        "file contents",
        agent.messages()[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings(provider, agent.messages()[3].response.identity.provider);
    try std.testing.expectEqualStrings(final_text, agent.messages()[3].response.parts[0].text.text);
}

test "Agent streams an OpenAI Chat tool loop through the production provider seam" {
    const tool_response =
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{\"path\":"}}]},"finish_reason":null}]}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"src/main.zig\"}"}}]},"finish_reason":"tool_calls"}]}
        \\
        \\data: [DONE]
        \\
    ;
    const final_response =
        \\data: {"choices":[{"delta":{"content":"OpenAI "},"finish_reason":null}]}
        \\
        \\data: {"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}
        \\
        \\data: [DONE]
        \\
    ;
    const exchanges = [_]fake_api.Exchange{
        .{ .response = .{ .status = 200, .body = tool_response, .chunk_bytes = 7 } },
        .{ .response = .{ .status = 200, .body = final_response, .chunk_bytes = 9 } },
    };
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: OpenAiInspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = OpenAiInspector.inspect };
    var provider = compatible.OpenAiCompatible.init(fake.transport(), .{
        .provider_id = "openai",
        .model_id = "gpt-4.1",
        .base_url = "https://api.openai.com/v1",
        .api_key = "secret",
    });
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "file contents" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "Read a file",
        .parameters_json_schema = "{\"type\":\"object\"}",
    });
    var agent = try Agent.init(std.testing.allocator, std.testing.io, provider.modelView(), &.{tool}, .{}, null);
    defer agent.deinit();
    var recorder: StreamRecorder = .{};

    const text = try agent.runStream("read src/main.zig", .{
        .context = &recorder,
        .emitFn = StreamRecorder.emit,
    });

    try std.testing.expectEqualStrings("OpenAI done", text);
    try std.testing.expectEqual(@as(usize, 1), scripted_tool.calls);
    try std.testing.expectEqual(@as(usize, 2), inspector.requests);
    try std.testing.expectEqual(@as(usize, 2), fake.next_index);
    try recorder.expectTwoRequests();
    try expectCompletedToolLoop(&agent, "openai", "OpenAI done");
}

test "Agent streams an OpenAI Codex Responses tool loop through the production provider seam" {
    const tool_response =
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read"}}
        \\
        \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":"}
        \\
        \\data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"\"src/main.zig\"}"}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read","arguments":"{\"path\":\"src/main.zig\"}"}}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const final_response =
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1","content":[]}}
        \\
        \\data: {"type":"response.content_part.added","output_index":0,"part":{"type":"output_text","text":""}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"Codex "}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"delta":"done"}
        \\
        // ziglint-ignore: Z024 -- compact wire fixture
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"Codex done"}]}}
        \\
        \\data: {"type":"response.completed","response":{"status":"completed"}}
        \\
    ;
    const exchanges = [_]fake_api.Exchange{
        .{ .response = .{ .status = 200, .body = tool_response, .chunk_bytes = 8 } },
        .{ .response = .{ .status = 200, .body = final_response, .chunk_bytes = 11 } },
    };
    var fake = fake_api.FakeTransport.init(&exchanges);
    var inspector: CodexInspector = .{};
    fake.inspector = .{ .context = &inspector, .inspect_fn = CodexInspector.inspect };
    var provider = codex.OpenAiCodex.init(fake.transport(), .{
        .model_id = "gpt-5.1-codex",
        .access_token = "token",
        .account_id = "acc_test",
    });
    var scripted_tool: agent_testing.ScriptedTool = .{ .result = "file contents" };
    const tool = scripted_tool.asTool(.{
        .name = "read",
        .description = "Read a file",
        .parameters_json_schema = "{\"type\":\"object\"}",
    });
    var agent = try Agent.init(std.testing.allocator, std.testing.io, provider.modelView(), &.{tool}, .{}, null);
    defer agent.deinit();
    var recorder: StreamRecorder = .{};

    const text = try agent.runStream("read src/main.zig", .{
        .context = &recorder,
        .emitFn = StreamRecorder.emit,
    });

    try std.testing.expectEqualStrings("Codex done", text);
    try std.testing.expectEqual(@as(usize, 1), scripted_tool.calls);
    try std.testing.expectEqual(@as(usize, 2), inspector.requests);
    try std.testing.expectEqual(@as(usize, 2), fake.next_index);
    try recorder.expectTwoRequests();
    try expectCompletedToolLoop(&agent, "openai-codex", "Codex done");
}
