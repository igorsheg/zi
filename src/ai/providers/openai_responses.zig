const std = @import("std");
const env_api_keys = @import("../utils/env_api_keys.zig");
const http_utils = @import("../utils/http.zig");
const protocol = @import("../protocol.zig");
const provider_registry = @import("../provider_registry.zig");
const runtime = @import("../../runtime/root.zig");
const shared = @import("openai_responses_shared.zig");
const simple_options = @import("simple_options.zig");
const transform_messages = @import("transform_messages.zig");

pub const source_id = "openai-responses-provider";

const read_buffer_len = 8192;
const redirect_buffer_len = 0;
const max_error_body_bytes = 16 * 1024;

pub const Options = struct {
    environ: ?*const std.process.Environ.Map = null,
};

pub const Provider = struct {
    options: Options = .{},

    pub fn init(options: Options) Provider {
        return .{ .options = options };
    }

    pub fn register(self: *Provider, registry: *provider_registry.ProviderRegistry) !void {
        try registry.register(self.apiProvider(), source_id);
    }

    pub fn unregister(_: *Provider, registry: *provider_registry.ProviderRegistry) void {
        registry.unregisterSource(source_id);
    }

    pub fn apiProvider(self: *Provider) provider_registry.ApiProvider {
        return .{
            .api = protocol.KnownApi.openai_responses,
            .stream = .{ .context = self, .call_fn = streamFunction },
            .stream_simple = .{ .context = self, .call_fn = streamSimpleFunction },
        };
    }
};

fn streamSimpleFunction(context: ?*anyopaque, request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    const self: *Provider = @ptrCast(@alignCast(context.?));
    var normalized = request;
    normalized.options = simple_options.buildBaseOptions(
        request.model,
        .{ .stream = request.options },
        resolveApiKey(self, request),
    );
    return streamFunction(self, normalized);
}

fn streamFunction(context: ?*anyopaque, request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    const self: *Provider = @ptrCast(@alignCast(context.?));
    const state = createResponseStream(self, request) catch |err| return shared.errorStream(request, err);
    return state.stream();
}

const OpenAiResponseOwner = struct {
    pub fn deinit(self: *OpenAiResponseOwner, _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

const OpenAiResponseStream = shared.SsePullStream(OpenAiResponseOwner, .{
    .read_buffer_len = read_buffer_len,
    .redirect_buffer_len = redirect_buffer_len,
});

fn createResponseStream(provider: *Provider, request: protocol.StreamRequest) !*OpenAiResponseStream {
    const state = try request.allocator.create(OpenAiResponseStream);
    state.* = OpenAiResponseStream.init(request.allocator, request, .{});
    errdefer state.deinit();

    const api_key = request.options.api_key orelse resolveApiKey(provider, request) orelse return error.MissingApiKey;
    const body = try buildRequestBody(request.allocator, request);
    defer request.allocator.free(body);
    const url = try endpointUrl(request.allocator, request.model.base_url);
    defer request.allocator.free(url);
    const uri = try std.Uri.parse(url);
    const authorization = try http_utils.bearerHeader(request.allocator, api_key);
    defer request.allocator.free(authorization);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = authorization },
        .{ .name = "Accept", .value = "text/event-stream" },
    };

    try state.openRequest(uri, &headers, body);
    if (state.response.head.status != .ok) {
        const detail = readErrorBody(request.allocator, state.reader.?) catch try std.fmt.allocPrint(
            request.allocator,
            "HTTP {s}",
            .{@tagName(state.response.head.status)},
        );
        try state.emitError(detail);
    }
    return state;
}

fn readErrorBody(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const body = try http_utils.readBoundedBody(allocator, reader, max_error_body_bytes);
    if (body.len > 0) return body;
    allocator.free(body);
    return allocator.dupe(u8, "HTTP request failed");
}

fn resolveApiKey(self: *Provider, request: protocol.StreamRequest) ?[]const u8 {
    if (request.options.api_key) |api_key| if (api_key.len > 0) return api_key;
    const environ = self.options.environ orelse return null;
    return if (env_api_keys.getEnvApiKey(environ, request.model.provider)) |key| key.value else null;
}

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    return http_utils.appendPath(allocator, base_url, "responses");
}

fn buildRequestBody(allocator: std.mem.Allocator, request: protocol.StreamRequest) ![]const u8 {
    var transformed = try transform_messages.transformMessages(
        allocator,
        request.context.messages,
        request.model,
        null,
    );
    defer transformed.deinit();
    const transformed_context: protocol.Context = .{
        .system_prompt = request.context.system_prompt,
        .messages = transformed.messages,
        .tools = request.context.tools,
    };

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model.id, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"store\":false,\"input\":[");
    try writeInputMessages(allocator, writer, transformed_context);
    try writer.writeByte(']');
    if (request.options.max_tokens) |max_tokens| try writer.print(",\"max_output_tokens\":{}", .{max_tokens});
    if (request.options.temperature) |temperature| try writer.print(",\"temperature\":{d}", .{temperature});
    if (request.options.session_id) |session_id| {
        if (request.options.cache_retention != .none) {
            try writer.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(session_id, .{}, writer);
        }
    }
    if (request.context.tools) |tools| if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"name\":");
            try std.json.Stringify.value(tool.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(tool.description, .{}, writer);
            try writer.writeAll(",\"parameters\":");
            try std.json.Stringify.value(tool.parameters, .{}, writer);
            try writer.writeAll(",\"strict\":false}");
        }
        try writer.writeByte(']');
    };
    if (request.model.reasoning) try writer.writeAll(",\"reasoning\":{\"effort\":\"none\"}");
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeInputMessages(allocator: std.mem.Allocator, writer: *std.Io.Writer, context: protocol.Context) !void {
    var wrote = false;
    if (context.system_prompt) |system_prompt| {
        try writeRoleTextMessage(writer, "system", system_prompt, &wrote);
    }
    for (context.messages) |message| {
        switch (message) {
            .user => |user| switch (user.content) {
                .string => |text| try writeRoleTextMessage(writer, "user", text, &wrote),
                .blocks => |blocks| for (blocks) |block| switch (block) {
                    .text => |text| try writeRoleTextMessage(writer, "user", text.text, &wrote),
                    .image => |image| try writeRoleImageMessage(writer, "user", image, &wrote),
                },
            },
            .assistant => |assistant| for (assistant.content) |block| switch (block) {
                .text => |text| try writeAssistantOutputText(writer, text.text, &wrote),
                .thinking => |thinking| if (thinking.thinking.len > 0) {
                    try writeAssistantOutputText(writer, thinking.thinking, &wrote);
                },
                .tool_call => |tool_call| try writeAssistantToolCall(allocator, writer, tool_call, &wrote),
            },
            .tool_result => |tool_result| try writeToolResult(allocator, writer, tool_result, &wrote),
        }
    }
}

fn writeRoleTextMessage(writer: *std.Io.Writer, role: []const u8, text: []const u8, wrote: *bool) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(role, .{}, writer);
    try writer.writeAll(",\"content\":[{\"type\":\"input_text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll("}]}");
}

fn writeRoleImageMessage(
    writer: *std.Io.Writer,
    role: []const u8,
    image: protocol.ImageContent,
    wrote: *bool,
) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(role, .{}, writer);
    try writer.writeAll(",\"content\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":");
    try writer.print("\"data:{s};base64,{s}\"", .{ image.mime_type, image.data });
    try writer.writeAll("}]}");
}

fn writeAssistantOutputText(writer: *std.Io.Writer, text: []const u8, wrote: *bool) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",");
    try writer.writeAll("\"content\":[{\"type\":\"output_text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll(",\"annotations\":[]}]}");
}

fn writeAssistantToolCall(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    call: protocol.ToolCall,
    wrote: *bool,
) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    const separator = std.mem.findScalar(u8, call.id, '|');
    const call_id = if (separator) |index| call.id[0..index] else call.id;
    const item_id = if (separator) |index| call.id[index + 1 ..] else null;
    try writer.writeAll("{\"type\":\"function_call\",");
    if (item_id) |id| {
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"call_id\":");
    try std.json.Stringify.value(call_id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"arguments\":");
    var arguments = std.Io.Writer.Allocating.init(allocator);
    defer arguments.deinit();
    try std.json.Stringify.value(call.arguments, .{}, &arguments.writer);
    try std.json.Stringify.value(arguments.written(), .{}, writer);
    try writer.writeByte('}');
}

fn writeToolResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: protocol.ToolResultMessage,
    wrote: *bool,
) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    var text = std.Io.Writer.Allocating.init(allocator);
    defer text.deinit();
    var has_image = false;
    for (result.content) |block| switch (block) {
        .text => |text_block| {
            if (text.written().len > 0) try text.writer.writeByte('\n');
            try text.writer.writeAll(text_block.text);
        },
        .image => has_image = true,
    };
    try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
    try std.json.Stringify.value(openaiCallId(result.tool_call_id), .{}, writer);
    try writer.writeAll(",\"output\":");
    if (!has_image) {
        try std.json.Stringify.value(text.written(), .{}, writer);
    } else {
        try writer.writeByte('[');
        var wrote_part = false;
        if (text.written().len > 0) {
            try writer.writeAll("{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.value(text.written(), .{}, writer);
            try writer.writeByte('}');
            wrote_part = true;
        }
        for (result.content) |block| if (block == .image) {
            if (wrote_part) try writer.writeByte(',');
            wrote_part = true;
            try writer.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":");
            try writer.print("\"data:{s};base64,{s}\"", .{ block.image.mime_type, block.image.data });
            try writer.writeByte('}');
        };
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn openaiCallId(id: []const u8) []const u8 {
    const separator = std.mem.findScalar(u8, id, '|');
    return if (separator) |index| id[0..index] else id;
}

test "provider registers openai responses api" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = Provider.init(.{});

    try provider.register(&registry);

    try std.testing.expect(registry.get(protocol.KnownApi.openai_responses) != null);
}

test "provider stream without auth emits missing api key error" {
    var provider = Provider.init(.{});
    var stream = provider.apiProvider().stream.call(testRequest());

    const err = (try stream.next(std.Io.failing)).?.@"error";
    try std.testing.expectEqual(protocol.ErrorReason.error_, err.reason);
    try std.testing.expectEqualStrings("MissingApiKey", err.@"error".error_message.?);
}

test "endpoint url appends responses path" {
    const url = try endpointUrl(std.testing.allocator, "https://api.openai.com/v1");
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", url);
}

test "request body includes model stream input and tools" {
    const request = testRequest();
    const body = try buildRequestBody(std.testing.allocator, request);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
}

test "request body writes OpenAI call id for tool results" {
    var request = testRequest();
    request.context.messages = &.{
        .{ .assistant = .{
            .content = &.{.{ .tool_call = .{
                .id = "call_123456789|fc_123456789",
                .name = "echo",
                .arguments = .{ .object = .empty },
            } }},
            .api = protocol.KnownApi.openai_responses,
            .provider = protocol.KnownProvider.openai,
            .model = "gpt-test",
            .usage = protocol.emptyUsage(),
            .stop_reason = .tool_use,
            .timestamp = 0,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call_123456789|fc_123456789",
            .tool_name = "echo",
            .content = &.{.{ .text = .{ .text = "ok" } }},
            .is_error = false,
            .timestamp = 0,
        } },
    };

    const body = try buildRequestBody(std.testing.allocator, request);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":\"call_123456789\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_id\":\"call_123456789|fc_123456789\"") == null);
}

fn testRequest() protocol.StreamRequest {
    return .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = .{
            .id = "gpt-test",
            .name = "GPT Test",
            .api = protocol.KnownApi.openai_responses,
            .provider = protocol.KnownProvider.openai,
            .base_url = "https://api.openai.com/v1",
            .reasoning = true,
            .input = &.{.text},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 1,
            .max_tokens = 1,
        },
        .context = .{
            .system_prompt = "system",
            .messages = &.{.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }},
            .tools = &.{.{ .name = "echo", .description = "Echo", .parameters = .{ .object = .empty } }},
        },
    };
}
